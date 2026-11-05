import Foundation
import TachoKit

// tacho-cli: what Tacho reads, on the command line, to check its figures against the CLIs' own.
//
// It writes only its own database. It never calls `Engine.start`, the one thing that could start the Anthropic fetch, and it never
// makes a fetcher: `quota` polls the local caches once, which reads two files and touches neither the network nor the Keychain.

let usage = """
    usage: tacho-cli <command> [--db <path>] [--home <path>]

      scan                        backfill every source; print events, skipped counts and both times
      stats --day YYYY-MM-DD      per source: tokens by category, total and cost for that local day
      rate                        the dashboard's rate, and how long the dashboard took to compute
      quota                       the dashboard's quota projections
      speeds [--hours 24]         generation speed per model
      reconcile claudebar [--days 3]
      reconcile omp | opencode | grok | codex
      export [--output <path>]        this machine's batch, to stdout when no path is given
      import [--input <path>]         merge a batch from stdin, or from a path

    --home defaults to your home directory, --db to <home>/Library/Application Support/Tacho/cli.sqlite.
    export and import never scan logs and never open a connection. ssh host tacho-cli export | tacho-cli import
    """

/// A wrong command line, as against a command that failed.
struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// The command line: words, and the options that take a value.
struct Arguments {
    private static let options: Set<String> = ["--db", "--home", "--day", "--days", "--hours", "--output", "--input"]

    private(set) var words: [String] = []
    private var values: [String: String] = [:]

    init(_ arguments: some Sequence<String>) throws {
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            guard argument.hasPrefix("--") else {
                words.append(argument)
                continue
            }
            guard Self.options.contains(argument) else { throw UsageError("unknown option \(argument)") }
            guard let value = rest.next() else { throw UsageError("\(argument) needs a value") }
            values[argument] = value
        }
    }

    func value(_ option: String) -> String? {
        values[option]
    }

    func path(_ option: String) -> URL? {
        values[option].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    func positiveInt(_ option: String, default fallback: Int) throws -> Int {
        guard let text = values[option] else { return fallback }
        guard let number = Int(text), number > 0 else { throw UsageError("\(option) needs a positive whole number, not \(text)") }
        return number
    }
}

/// Where a run reads and writes.
struct Context {
    let home: URL
    let database: URL
    let arguments: Arguments
    var calendar = Calendar.current

    init(_ arguments: Arguments) {
        self.arguments = arguments
        home = arguments.path("--home") ?? FileManager.default.homeDirectoryForCurrentUser
        database = arguments.path("--db") ?? home.appendingPathComponent("Library/Application Support/Tacho/cli.sqlite")
    }

    var roots: SourceRoots { .defaults(home: home) }

    func ingestor(on store: EventStore) -> Ingestor {
        Ingestor(store: store, readers: Ingestor.defaultReaders(), roots: roots, enabled: Set(Source.allCases))
    }

    /// The store, brought up to date. With a store already scanned this reads only what is new.
    func currentStore() async throws -> EventStore {
        let store = try EventStore(url: database)
        await ingestor(on: store).backfill()
        return store
    }

    /// An Engine on the same database, with the default preferences. `anthropicQueryEnabled` is false in them,
    /// and `start` is not called, so nothing polls and nothing is fetched.
    func engine() throws -> Engine {
        try Engine(databaseURL: database, home: home, preferences: .defaults(home: home))
    }
}

/// `text` padded on the left to `width`, for columns of figures.
func right(_ text: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - text.count)) + text
}

/// `text` padded on the right to `width`.
func left(_ text: String, _ width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - text.count))
}

func seconds(_ duration: Duration) -> Double {
    let (whole, attoseconds) = duration.components
    return Double(whole) + Double(attoseconds) / 1e18
}

extension Calendar {
    /// The local day named `key`, "YYYY-MM-DD"; nil when it is no date.
    func day(_ key: String) -> TimeRange? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(calendar: self, timeZone: timeZone, year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: self), let start = date(from: components), let end = date(byAdding: .day, value: 1, to: start) else { return nil }
        return TimeRange(start: start, end: end)
    }
}

/// Backfills, timing the recent phase by watching `progress`, which can lag the phase's end by one file's read.
func scan(_ context: Context) async throws -> Int32 {
    let store = try EventStore(url: context.database)
    let before = try store.eventCount(source: nil)
    let ingestor = context.ingestor(on: store)
    let clock = ContinuousClock()
    let started = clock.now
    let backfill = Task { await ingestor.backfill() }
    var recentEnded: Duration?
    while true {
        let phase = await ingestor.progress.phase
        if recentEnded == nil, phase == .history || phase == .live {
            recentEnded = clock.now - started
        }
        if phase == .live { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    await backfill.value
    let total = clock.now - started

    print("\(left("source", 12))\(right("files", 8))\(right("events", 10))\(right("skipped", 9))")
    for status in await ingestor.statuses() {
        print("\(left(status.source.rawValue, 12))\(right("\(status.files)", 8))\(right("\(status.events)", 10))\(right("\(status.skipped)", 9))")
    }
    let progress = await ingestor.progress
    print("files read: \(progress.filesDone) of \(progress.filesTotal); events in the store before this scan: \(before)")
    print(String(format: "recent phase: %.2f s (budget 15 s)", seconds(recentEnded ?? total)))
    print(String(format: "total: %.2f s (budget 180 s)", seconds(total)))
    return 0
}

func stats(_ context: Context) async throws -> Int32 {
    guard let key = context.arguments.value("--day") else { throw UsageError("stats needs --day YYYY-MM-DD") }
    guard let day = context.calendar.day(key) else { throw UsageError("not a date: \(key)") }
    let store = try await context.currentStore()
    let prices = try PriceTable.bundled()
    let columns = ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "total", "cost"]
    print(left("source", 12) + columns.map { right($0, 14) }.joined())
    var unpriced: [String] = []
    for source in Source.allCases {
        let filter = EventFilter(sources: [source])
        let tokens = try store.tokens(in: day, filter: filter)
        let cost = prices.cost(of: try store.pricingGroups(in: day, filter: filter, thresholds: prices.longContextThresholds))
        let figures = [tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite5m, tokens.cacheWrite1h, tokens.total].map { right("\($0)", 14) }
        print(left(source.rawValue, 12) + figures.joined() + right(String(format: "$%.2f", cost.usd), 14))
        if cost.unpricedTokens > 0 {
            unpriced.append("\(source.rawValue): \(cost.unpricedTokens) tokens have no price (\(cost.unpricedModels.joined(separator: ", ")))")
        }
    }
    unpriced.forEach { print($0) }
    return 0
}

func rate(_ context: Context) async throws -> Int32 {
    _ = try await context.currentStore()
    let engine = try context.engine()
    let clock = ContinuousClock()
    let started = clock.now
    let dashboard = try await engine.dashboard(now: Date())
    let took = clock.now - started
    print("per minute: \(dashboard.perMinute) (\(TokenFormat.rate(perMinute: dashboard.perMinute, unit: .perMinute)))")
    print(String(format: "per second: %.2f", dashboard.perSecond))
    let last = dashboard.lastMinute
    print("last minute: input \(last.input), output \(last.output), cacheRead \(last.cacheRead), cacheWrite5m \(last.cacheWrite5m), cacheWrite1h \(last.cacheWrite1h)")
    print("idle: \(dashboard.isIdle)")
    for row in dashboard.sources {
        print("\(left(row.source.rawValue, 12))\(right("\(row.perMinute)/min", 14))  active: \(row.isActive)")
    }
    print(String(format: "dashboard computed in %.1f ms (budget 100 ms)", seconds(took) * 1000))
    return 0
}

func quota(_ context: Context) async throws -> Int32 {
    let store = try await context.currentStore()
    // Nothing else polls here, and Claude's and omp's limits come only from their local caches.
    await QuotaPoller(store: store, home: context.home, fetcher: nil).pollOnce()
    let dashboard = try await context.engine().dashboard(now: Date())
    if dashboard.quotas.isEmpty {
        print("no quota snapshots")
    }
    for projection in dashboard.quotas {
        let snapshot = projection.snapshot
        let scope = snapshot.scope.map { " \($0)" } ?? ""
        let name = "\(snapshot.provider.rawValue) \(snapshot.window.rawValue)\(scope)"
        guard projection.hasRecentData else {
            print("\(name): no recent quota data")
            continue
        }
        print("\(name): \(String(format: "%.1f", snapshot.usedPercent))% used, resets \(snapshot.resetsAt), \(projection.outcome)")
    }
    print("alert: \(dashboard.alert)")
    return 0
}

func speeds(_ context: Context) async throws -> Int32 {
    let hours = try context.arguments.positiveInt("--hours", default: 24)
    _ = try await context.currentStore()
    let now = Date()
    let range = TimeRange(start: now.addingTimeInterval(-Double(hours) * 3600), end: now)
    let overview = try await context.engine().overview(range: range)
    print("\(left("model", 28))\(right("tok/s", 10))\(right("samples", 9))")
    for speed in overview.speeds {
        print("\(left(speed.model, 28))\(right(String(format: "%@%.1f", speed.approximate ? "~" : "", speed.tokensPerSecond), 10))\(right("\(speed.samples)", 9))")
    }
    return 0
}

/// The store as it stands. No scan: export must not read a CLI directory on the way out.
func exportSync(_ context: Context) throws -> Int32 {
    let store = try EventStore(url: context.database)
    let data = try SyncFormat.export(from: store)
    if let url = context.arguments.path("--output") {
        try data.write(to: url, options: .atomic)
    } else {
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    return 0
}

/// Merges a batch into the store. No scan, and no connection: the bytes come from a file or from stdin.
func importSync(_ context: Context) throws -> Int32 {
    let data: Data
    if let url = context.arguments.path("--input") {
        data = try Data(contentsOf: url)
    } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    let store = try EventStore(url: context.database)
    try SyncFormat.apply(data, to: store)
    return 0
}

func run(_ arguments: Arguments) async throws -> Int32 {
    let context = Context(arguments)
    switch arguments.words.first {
    case "scan": return try await scan(context)
    case "stats": return try await stats(context)
    case "rate": return try await rate(context)
    case "quota": return try await quota(context)
    case "speeds": return try await speeds(context)
    case "reconcile":
        guard arguments.words.count == 2 else { throw UsageError("reconcile needs one of claudebar, omp, opencode, grok, codex") }
        return try await Reconcile(context).run(arguments.words[1])
    case "export": return try exportSync(context)
    case "import": return try importSync(context)
    case let command?: throw UsageError("unknown command \(command)")
    case nil: throw UsageError("no command")
    }
}

do {
    exit(try await run(try Arguments(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    FileHandle.standardError.write(Data("tacho-cli: \(error.message)\n\n\(usage)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("tacho-cli: \(error)\n".utf8))
    exit(1)
}

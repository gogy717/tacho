import Foundation

/// Keeps the store's quota snapshots up to date from the local caches, and from Anthropic when the user has turned that on.
public actor QuotaPoller {
    private static let pollInterval: Duration = .seconds(30)
    private static let fetchInterval: TimeInterval = 300

    private let store: EventStore
    private let home: URL
    private let now: @Sendable () -> Date
    private var fetcher: AnthropicUsageFetcher?
    private var enabled: Set<Source>
    /// The modification times the last complete read saw. A file left unread has none, so switching its source on is a change.
    private var seen: [Date?] = []
    private var lastFetch: Date?
    private var loop: Task<Void, Never>?

    public init(
        store: EventStore,
        home: URL,
        fetcher: AnthropicUsageFetcher?,
        enabled: Set<Source> = Set(Source.allCases),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.home = home
        self.fetcher = fetcher
        self.enabled = enabled
        self.now = now
    }

    /// Polls now and every 30 s, and fetches every 300 s when there is a fetcher, until `stop`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let poller = self else { return }
                await poller.pollOnce()
                await poller.fetchIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Takes effect at the next fetch, which keeps to the interval: turning the fetcher off and on again buys no extra request.
    public func setFetcher(_ fetcher: AnthropicUsageFetcher?) {
        self.fetcher = fetcher
    }

    /// The sources whose files may be read, from the next poll on.
    public func setEnabled(_ sources: Set<Source>) {
        enabled = sources
    }

    /// Reads `~/.claude.json` if Claude Code is on and `~/.omp/agent/agent.db` if omp is, when either changed.
    ///
    /// Both are read together because the first names the account the second is filtered by: with Claude Code off there is no
    /// account, so oh-my-pi's Anthropic reports match nothing. A write to `agent.db` lands in its `-wal`, leaving the database's
    /// own mtime alone until a checkpoint, so that file is watched too.
    public func pollOnce() async {
        let claudeFile = enabled.contains(.claudeCode) ? home.appendingPathComponent(".claude.json") : nil
        let agentDB = enabled.contains(.omp) ? home.appendingPathComponent(".omp/agent/agent.db") : nil
        let journal = agentDB.map { URL(fileURLWithPath: $0.path + "-wal") }
        let times = [claudeFile, agentDB, journal].map { $0.flatMap(Self.modificationTime(of:)) }
        guard times != seen else { return }
        if read(claudeFile: claudeFile, agentDB: agentDB) {
            seen = times
        }
    }

    /// Records what the files hold, leaving out a nil one. false when either could not be read: they are other apps', and the next
    /// poll tries again.
    private func read(claudeFile: URL?, agentDB: URL?) -> Bool {
        var complete = true
        var account: String?
        if let claudeFile, FileManager.default.fileExists(atPath: claudeFile.path) {
            // Half a file is no JSON, and the writer may be done before the next poll, leaving the mtime this one saw.
            if let config = (try? Data(contentsOf: claudeFile)).flatMap({ JSONObject($0) }) {
                account = ClaudeCacheQuota.accountUuid(in: config)
                complete = record { ClaudeCacheQuota.snapshots(in: config) }
            } else {
                complete = false
            }
        }
        // Whatever became of that file: only Anthropic's reports need the account it names.
        if let agentDB, FileManager.default.fileExists(atPath: agentDB.path) {
            let recorded = record { try OmpQuotaCache.snapshots(agentDB: agentDB, anthropicAccount: account) }
            complete = complete && recorded
        }
        return complete
    }

    /// Stores what `snapshots` reads; false when it could not be read or stored.
    private func record(_ snapshots: () throws -> [QuotaSnapshot]) -> Bool {
        do {
            try store.record(snapshots())
            return true
        } catch {
            return false
        }
    }

    /// Asks Anthropic if there is a fetcher and the last request, failed or not, was long enough ago.
    func fetchIfDue() async {
        guard let fetcher else { return }
        let started = now()
        if let lastFetch, started.timeIntervalSince(lastFetch) < Self.fetchInterval { return }
        lastFetch = started
        if case .snapshots(let snapshots) = await fetcher.fetch() {
            // A write that fails costs one observation; the next fetch brings a newer one.
            try? store.record(snapshots)
        }
    }

    private static func modificationTime(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}

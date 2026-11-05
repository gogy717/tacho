import CryptoKit
import Foundation
import GRDB

/// The batch one machine hands to another.
///
/// Version 1 is one JSON object, so a later mailbox can encrypt the bytes whole. Nothing in it is a project, a path, a prompt,
/// a file name or a session id: this type has no such field, and `dedupKey` is a one-way hash scoped to the machine. The raw key
/// stays in the local store, where the logs can still be merged.
public enum SyncFormat {
    public static let version = 1

    /// SHA-256 of the machine id, a NUL, and the raw dedup key, as 64 lowercase hex digits.
    static func digest(machine: String, dedupKey: String) -> String {
        var data = Data(machine.utf8)
        data.append(0)
        data.append(contentsOf: dedupKey.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// This install's rows and its latest quota snapshots. Foreign rows are not included: each machine exports itself.
    public static func export(from store: EventStore) throws -> Data {
        let events = try store.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source, client, dedupKey, isSubagent, provider, model, time, startTime, generationMs, speed,
                       input, output, reasoning, cacheRead, cacheWrite5m, cacheWrite1h
                FROM event
                WHERE machine = ?
                ORDER BY time, dedupKey
                """, arguments: [store.machineId])
        }.map { row in
            WireEvent(
                source: row["source"],
                client: row["client"],
                dedupKey: digest(machine: store.machineId, dedupKey: row["dedupKey"]),
                isSubagent: row["isSubagent"],
                provider: row["provider"],
                model: row["model"],
                time: row["time"],
                startTime: row["startTime"],
                generationMs: row["generationMs"],
                speed: row["speed"],
                input: row["input"],
                output: row["output"],
                reasoning: row["reasoning"],
                cacheRead: row["cacheRead"],
                cacheWrite5m: row["cacheWrite5m"],
                cacheWrite1h: row["cacheWrite1h"]
            )
        }
        let quotas = try store.latestSnapshots().map { snapshot in
            WireQuota(
                provider: snapshot.provider.rawValue,
                window: snapshot.window.rawValue,
                scope: snapshot.scope ?? "",
                usedPercent: snapshot.usedPercent,
                resetsAt: snapshot.resetsAt.timeIntervalSince1970,
                observedAt: snapshot.observedAt.timeIntervalSince1970,
                origin: snapshot.origin.rawValue,
                plan: snapshot.plan
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(Batch(version: version, machine: store.machineId, events: events, quotas: quotas))
        data.append(0x0A)
        return data
    }

    /// Merges `data` into `store`. The same batch a second time changes nothing. A row replaces one only when its output is larger,
    /// or equal and later, which is the store's own rule. Quota snapshots: the newest `observedAt` wins, and an older one is kept
    /// but does not become the latest. This install's own batch is not applied as events: the hash cannot be matched back to the
    /// raw key, so applying it would count the machine twice.
    public static func apply(_ data: Data, to store: EventStore) throws {
        let batch = try JSONDecoder().decode(Batch.self, from: data)
        guard batch.version == version else {
            throw SyncFormatError(message: "unsupported sync batch version \(batch.version)")
        }
        guard !batch.machine.isEmpty else { throw SyncFormatError(message: "sync batch has no machine") }
        if batch.machine != store.machineId {
            try store.importForeign(machine: batch.machine, events: batch.events.map { event in
                ForeignUsage(
                    source: event.source,
                    client: event.client,
                    dedupKey: event.dedupKey,
                    isSubagent: event.isSubagent,
                    provider: event.provider,
                    model: event.model,
                    time: event.time,
                    startTime: event.startTime,
                    generationMs: event.generationMs,
                    speed: event.speed,
                    input: event.input,
                    output: event.output,
                    reasoning: event.reasoning,
                    cacheRead: event.cacheRead,
                    cacheWrite5m: event.cacheWrite5m,
                    cacheWrite1h: event.cacheWrite1h
                )
            })
        }
        let snapshots = batch.quotas.compactMap { quota -> QuotaSnapshot? in
            guard
                let provider = QuotaProvider(rawValue: quota.provider),
                let window = QuotaWindow(rawValue: quota.window),
                let origin = QuotaOrigin(rawValue: quota.origin)
            else { return nil }
            return QuotaSnapshot(
                provider: provider,
                window: window,
                scope: quota.scope.isEmpty ? nil : quota.scope,
                usedPercent: quota.usedPercent,
                resetsAt: Date(timeIntervalSince1970: quota.resetsAt),
                observedAt: Date(timeIntervalSince1970: quota.observedAt),
                origin: origin,
                plan: quota.plan
            )
        }
        try store.record(snapshots)
    }
}

public struct SyncFormatError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

/// One imported request. It has nowhere to put a project, a path, a prompt, a file name or a session id.
struct ForeignUsage: Sendable {
    var source: String
    var client: String?
    var dedupKey: String
    var isSubagent: Bool
    var provider: String?
    var model: String?
    var time: Double
    var startTime: Double?
    var generationMs: Double?
    var speed: String?
    var input: Int
    var output: Int
    var reasoning: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
}

/// The versioned document. Codable will not invent a key this type does not have.
private struct Batch: Codable {
    var version: Int
    var machine: String
    var events: [WireEvent]
    var quotas: [WireQuota]
}

private struct WireEvent: Codable {
    var source: String
    var client: String?
    var dedupKey: String
    var isSubagent: Bool
    var provider: String?
    var model: String?
    var time: Double
    var startTime: Double?
    var generationMs: Double?
    var speed: String?
    var input: Int
    var output: Int
    var reasoning: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
}

private struct WireQuota: Codable {
    var provider: String
    var window: String
    var scope: String
    var usedPercent: Double
    var resetsAt: Double
    var observedAt: Double
    var origin: String
    var plan: String?
}

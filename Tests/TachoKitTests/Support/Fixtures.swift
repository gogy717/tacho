import Foundation

/// One JSON object as a compact single line with sorted keys, without the trailing newline.
func jsonLine(_ object: [String: Any]) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch {
        fatalError("jsonLine: not serializable as JSON: \(error)")
    }
}

/// A fresh, empty directory under the system temporary directory.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tacho-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Replaces the file's content with `lines`, each terminated by "\n". Missing parent directories are created.
func write(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
}

/// Appends `text` verbatim to an existing file.
func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// An ISO-8601 timestamp with or without fractional seconds, ending in "Z" or a ±hh:mm offset.
func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    let attempts: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
    for options in attempts {
        formatter.formatOptions = options
        if let parsed = formatter.date(from: iso) { return parsed }
    }
    fatalError("date: not an ISO-8601 timestamp: \(iso)")
}

/// The date `epochMillis` milliseconds after the Unix epoch.
func ms(_ epochMillis: Double) -> Date {
    Date(timeIntervalSince1970: epochMillis / 1000)
}

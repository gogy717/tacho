import Foundation

/// Where each source keeps its files, as absolute paths. A source can have several roots.
public struct SourceRoots: Codable, Equatable, Sendable {
    public var roots: [Source: [String]]

    public init(roots: [Source: [String]]) {
        self.roots = roots
    }

    /// Each CLI's standard location under `home`. A menu bar app does not see a shell's `CLAUDE_CONFIG_DIR` or `CODEX_HOME`,
    /// so any other location is set in Settings. OpenCode's root is its database file, the others are directories.
    public static func defaults(home: URL) -> SourceRoots {
        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
        return SourceRoots(roots: [
            .claudeCode: [path(".claude")],
            .codex: [path(".codex")],
            .omp: [path(".omp")],
            .pi: [path(".pi")],
            .copilot: [path(".copilot")],
            .opencode: [path(".local/share/opencode/opencode.db")],
            .grok: [path(".grok")],
        ])
    }

    /// The CLIs installed under `home` that keep no local token data, by name: only those whose directory exists.
    public static func unsupportedDetected(home: URL) -> [String] {
        [("Gemini CLI", ".gemini"), ("Qwen Code", ".qwen"), ("Cursor", ".cursor")].compactMap { name, directory in
            var isDirectory: ObjCBool = false
            let path = home.appendingPathComponent(directory).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? name : nil
        }
    }
}

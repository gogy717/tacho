import Foundation
import Testing
@testable import TachoKit

/// What every reader's `discover` owes the person looking at Settings: a source it cannot walk is not an empty one.
struct SourceWalkTests {
    /// A reader, the tree it walks under its root, and a file of its own inside that tree.
    struct Tree: Sendable, CustomTestStringConvertible {
        var reader: any SourceReader
        var path: String
        var file: String
        var testDescription: String { "\(reader.source.rawValue) \(path)" }
    }

    static let trees: [Tree] = [
        Tree(reader: ClaudeCodeReader(), path: "projects", file: "p/s.jsonl"),
        Tree(reader: CodexReader(), path: "sessions", file: "2026/11/01/rollout-x.jsonl"),
        Tree(reader: CodexReader(), path: "archived_sessions", file: "rollout-y.jsonl"),
        Tree(reader: PiFamilyReader(source: .omp), path: "agent/sessions", file: "p/s.jsonl"),
        Tree(reader: PiFamilyReader(source: .pi), path: "agent/sessions", file: "p/s.jsonl"),
        Tree(reader: CopilotReader(), path: "session-state", file: "id/events.jsonl"),
        Tree(reader: GrokReader(), path: "sessions", file: "p/s/usage.json"),
    ]

    private func place(_ file: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    /// `body` with `url` closed to this process, opened again after, so that the temporary directory can go.
    private func denying(_ url: URL, _ body: () throws -> Void) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        try body()
    }

    @Test(arguments: trees)
    func aTreeInItsPlaceIsFound(tree: Tree) throws {
        let root = try makeTempDir()
        try place(tree.file, in: root.appendingPathComponent(tree.path))
        #expect(try tree.reader.discover(root: root).map(\.lastPathComponent) == [(tree.file as NSString).lastPathComponent])
    }

    @Test(arguments: trees)
    func aTreeMovedBehindALinkIsStillFound(tree: Tree) throws {
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        try place(tree.file, in: elsewhere)
        let link = root.appendingPathComponent(tree.path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(try tree.reader.discover(root: root).map(\.lastPathComponent) == [(tree.file as NSString).lastPathComponent])
    }

    @Test(arguments: trees)
    func aTreeThatIsNotThereIsNoProblem(tree: Tree) throws {
        #expect(try tree.reader.discover(root: try makeTempDir()).isEmpty)
        #expect(try tree.reader.discover(root: try makeTempDir().appendingPathComponent("gone")).isEmpty)
    }

    @Test(arguments: trees)
    func aTreeThatCannotBeListedThrows(tree: Tree) throws {
        let root = try makeTempDir()
        let directory = root.appendingPathComponent(tree.path)
        try place(tree.file, in: directory)
        try denying(directory) {
            #expect(throws: (any Error).self) { try tree.reader.discover(root: root) }
        }
    }

    @Test(arguments: trees)
    func aTreeBehindADirectoryThatCannotBeEnteredThrows(tree: Tree) throws {
        let root = try makeTempDir()
        try place(tree.file, in: root.appendingPathComponent(tree.path))
        try denying(root) {
            #expect(throws: (any Error).self) { try tree.reader.discover(root: root) }
        }
    }

    /// What `discover` found beside a tree it could not list, which it has to say by throwing.
    private func foundBeside(_ reader: any SourceReader, root: URL) throws -> [String] {
        do {
            _ = try reader.discover(root: root)
            Issue.record("expected discover to throw")
            return []
        } catch let partly as PartlyWalked {
            return partly.found.map(\.lastPathComponent)
        }
    }

    @Test func oneCodexTreeThatCannotBeListedLeavesTheOther() throws {
        let root = try makeTempDir()
        try place("2026/11/01/rollout-x.jsonl", in: root.appendingPathComponent("sessions"))
        let archived = root.appendingPathComponent("archived_sessions")
        try place("rollout-y.jsonl", in: archived)
        try denying(archived) {
            let found = try foundBeside(CodexReader(), root: root)
            #expect(found == ["rollout-x.jsonl"])
        }
    }

    @Test func grokSessionsThatCannotBeListedLeaveTheLog() throws {
        let root = try makeTempDir()
        try place("logs/unified.jsonl", in: root)
        let sessions = root.appendingPathComponent("sessions")
        try place("p/s/usage.json", in: sessions)
        try denying(sessions) {
            let found = try foundBeside(GrokReader(), root: root)
            #expect(found == ["unified.jsonl"])
        }
    }

    @Test(arguments: trees)
    func aLinkToNothingThrows(tree: Tree) throws {
        let root = try makeTempDir()
        let link = root.appendingPathComponent(tree.path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("gone"))
        #expect(throws: (any Error).self) { try tree.reader.discover(root: root) }
    }

    /// A project folder the process cannot enter is not the same as a project that was never there: the sessions beside it still count,
    /// and Settings has to be able to say that something was skipped.
    @Test func aDirectoryInsideATreeThatCannotBeListedDoesNotPassForEmpty() throws {
        let root = try makeTempDir()
        let projects = root.appendingPathComponent("projects")
        try place("visible/s.jsonl", in: projects)
        let hidden = projects.appendingPathComponent("hidden")
        try place("t.jsonl", in: hidden)
        try denying(hidden) {
            let found = try foundBeside(ClaudeCodeReader(), root: root)
            #expect(found == ["s.jsonl"])
        }
    }

    @Test func oneUnreadableCodexDirectoryLeavesTheRolloutsBesideIt() throws {
        let root = try makeTempDir()
        try place("2026/11/01/rollout-visible.jsonl", in: root.appendingPathComponent("sessions"))
        let hidden = root.appendingPathComponent("sessions/hidden")
        try place("rollout-hidden.jsonl", in: hidden)
        try denying(hidden) {
            let found = try foundBeside(CodexReader(), root: root)
            #expect(found == ["rollout-visible.jsonl"])
        }
    }

    @Test func anUnreadableCopilotSessionLeavesTheOthers() throws {
        let root = try makeTempDir()
        try place("session-state/open/events.jsonl", in: root)
        let hidden = root.appendingPathComponent("session-state/shut")
        try place("events.jsonl", in: hidden)
        try denying(hidden) {
            let found = try foundBeside(CopilotReader(), root: root)
            #expect(found == ["events.jsonl"])
        }
    }

    @Test func anUnreadableGrokSessionLeavesTheOtherSessions() throws {
        let root = try makeTempDir()
        try place("sessions/open/a/usage.json", in: root)
        try place("sessions/open/z/usage.json", in: root)
        let hidden = root.appendingPathComponent("sessions/open/m")
        try place("usage.json", in: hidden)
        try denying(hidden) {
            let found = try foundBeside(GrokReader(), root: root)
            #expect(found == ["usage.json", "usage.json"])
        }
    }

    @Test func anUnreadableGrokProjectLeavesTheOtherSessions() throws {
        let root = try makeTempDir()
        try place("sessions/open/s/usage.json", in: root)
        let hidden = root.appendingPathComponent("sessions/shut")
        try place("t/usage.json", in: hidden)
        try denying(hidden) {
            let found = try foundBeside(GrokReader(), root: root)
            #expect(found == ["usage.json"])
        }
    }
}

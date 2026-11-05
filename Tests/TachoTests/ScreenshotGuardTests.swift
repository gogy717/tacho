import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What stands between the README's screenshots and anything real. A real project name in a public image cannot be taken back, so these run on every
/// `swift test`, though the render they guard does not. Only that render needs XCTest, for its launch argument.
@MainActor
struct ScreenshotGuardTests {
    private typealias Refusal = ReadmeScreenshots.OutsideTheSandbox

    /// Launches counted on the main actor, where `AppModel.start` queues them.
    @MainActor private final class Launches {
        var count = 0
    }

    private var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// A sandbox the engine can open in, with the first-launch answers given.
    private func answered() throws -> Sandbox {
        let sandbox = try Sandbox()
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Tacho", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try sandbox.seed { $0.askedAboutSources = true }
        return sandbox
    }

    private func refuse(_ roots: SourceRoots, in sandbox: URL) throws {
        try ReadmeScreenshots.refuseAnythingReal(roots, sandbox: sandbox)
    }

    @Test func theSandboxsOwnRootsPass() throws {
        let sandbox = try Sandbox()
        try refuse(.defaults(home: sandbox.home), in: sandbox.home)
    }

    @Test func theRealHomeIsRefused() throws {
        let sandbox = try Sandbox()
        #expect(throws: Refusal.self) { try refuse(.defaults(home: realHome), in: sandbox.home) }
        #expect(throws: Refusal.self) { try refuse(SourceRoots(roots: [.claudeCode: [realHome.path]]), in: sandbox.home) }
    }

    @Test(arguments: [".claude", ".codex", ".omp", ".pi", ".copilot", ".grok", ".local/share/opencode", ".claudebar"])
    func everyCLIsDirectoryIsRefused(directory: String) throws {
        let sandbox = try Sandbox()
        let roots = SourceRoots(roots: [.pi: [realHome.appendingPathComponent(directory).path]])
        #expect(throws: Refusal.self) { try refuse(roots, in: sandbox.home) }
    }

    /// One bad root among good ones is enough.
    @Test func aRealRootBesideGoodOnesIsRefused() throws {
        let sandbox = try Sandbox()
        var roots = SourceRoots.defaults(home: sandbox.home)
        roots.roots[.grok, default: []].append(realHome.appendingPathComponent(".grok").path)
        #expect(throws: Refusal.self) { try refuse(roots, in: sandbox.home) }
    }

    /// Inside the sandbox by name, outside it in fact.
    @Test func aLinkOutOfTheSandboxIsRefused() throws {
        let sandbox = try Sandbox()
        let link = sandbox.home.appendingPathComponent(".claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realHome)
        let roots = SourceRoots(roots: [.claudeCode: [link.appendingPathComponent("projects").path]])
        #expect(throws: Refusal.self) { try refuse(roots, in: sandbox.home) }
    }

    @Test func aPathThatClimbsOutIsRefused() throws {
        let sandbox = try Sandbox()
        let roots = SourceRoots(roots: [.pi: [sandbox.home.path + "/.pi/../../../etc"]])
        #expect(throws: Refusal.self) { try refuse(roots, in: sandbox.home) }
    }

    /// Its name starts the same, and that is all.
    @Test func aFolderBesideTheSandboxIsRefused() throws {
        let sandbox = try Sandbox()
        let roots = SourceRoots(roots: [.pi: [sandbox.home.path + "-beside/.pi"]])
        #expect(throws: Refusal.self) { try refuse(roots, in: sandbox.home) }
    }

    @Test func aSandboxThatIsTheRealHomeIsRefused() {
        #expect(throws: Refusal.self) { try refuse(.defaults(home: realHome), in: realHome) }
    }

    @Test func aSandboxInsideTheRealHomeIsRefused() {
        let inside = realHome.appendingPathComponent("tacho-sandbox-that-does-not-exist")
        #expect(throws: Refusal.self) { try refuse(.defaults(home: inside), in: inside) }
    }

    /// The route itself, through the one way the generator has to a model: roots that fail to decode come back as the real home's, and it must not start.
    @Test func aModelOnRootsThatFellBackToTheRealHomeNeverStarts() async throws {
        let sandbox = try answered()
        let seeded = try #require(sandbox.defaults.data(forKey: "preferences"))
        var stored = try #require(try JSONSerialization.jsonObject(with: seeded) as? [String: Any])
        stored["roots"] = 7
        sandbox.defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: "preferences")
        let launches = Launches()
        #expect(throws: Refusal.self) {
            _ = try ReadmeScreenshots.startedModel(sandbox) { @MainActor _ in launches.count += 1 }
        }
        // Nothing to wait on when nothing should happen. On a model nothing has saved to, a launch that had been asked for has no earlier work to
        // wait behind, so it is queued on the main actor before this wait ends and is counted first, however long that actor stalls. Counted
        // anywhere else, or behind a save, it could arrive after the check, and a stall would hide it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(launches.count == 0)
    }

    /// Without this, a helper that never started anything would pass the test above.
    @Test func aModelOnTheSandboxsRootsStarts() async throws {
        let sandbox = try answered()
        let log = LaunchLog()
        let model = try ReadmeScreenshots.startedModel(sandbox) { await log.record($0) }
        await model.settled()
        #expect(await log.count == 1)
    }
}

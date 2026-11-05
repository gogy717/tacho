import Foundation
import Testing

/// `scripts/bundle.sh`, run for real from a scratch copy with stand-ins on `PATH`: no build, nothing signed, and `build/` left alone.
struct BundleScriptTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Run {
        var status: Int32
        /// How many times `hdiutil` was called.
        var attempts: Int
        /// What `sleep` was asked for, in order.
        var naps: [String]
        var output: String
        /// The third-party notices reached the app's Resources.
        var shipsNotices: Bool
    }

    private func script(_ text: String, named name: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(name)
        try ("#!/bin/bash\n" + text).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `hdiutil` fails `failures` times with `status`, as "Resource busy" does, then succeeds.
    private func run(failures: Int, status: Int32 = 36) throws -> Run {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tacho-bundle-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let stubs = root.appendingPathComponent("stubs")
        let products = root.appendingPathComponent("products")
        for folder in ["scripts", "stubs", "products/Tacho_TachoKit.bundle", "products/Tacho_Tacho.bundle"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try manager.copyItem(at: Self.repository.appendingPathComponent("scripts/bundle.sh"), to: root.appendingPathComponent("scripts/bundle.sh"))
        try manager.copyItem(at: Self.repository.appendingPathComponent("packaging"), to: root.appendingPathComponent("packaging"))
        manager.createFile(atPath: root.appendingPathComponent("THIRD-PARTY-NOTICES.md").path, contents: Data("notices".utf8))
        manager.createFile(atPath: products.appendingPathComponent("Tacho").path, contents: Data())

        let calls = root.appendingPathComponent("hdiutil-calls")
        let naps = root.appendingPathComponent("naps")
        try script(#"if [[ " $* " == *" --show-bin-path "* ]]; then echo "\#(products.path)"; fi"#, named: "swift", in: stubs)
        try script("exit 0", named: "codesign", in: stubs)
        try script("exit 0", named: "shasum", in: stubs)
        try script(#"echo "$1" >> "\#(naps.path)""#, named: "sleep", in: stubs)
        try script(#"""
            echo called >> "\#(calls.path)"
            if [ "$(wc -l < "\#(calls.path)")" -le \#(failures) ]; then
                echo "hdiutil: create failed - Resource busy" >&2
                exit \#(status)
            fi
            """#, named: "hdiutil", in: stubs)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/bundle.sh").path, "9.9.9"]
        process.environment = ["PATH": "\(stubs.path):/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let notices = root.appendingPathComponent("build/Tacho.app/Contents/Resources/THIRD-PARTY-NOTICES.md")
        return Run(
            status: process.terminationStatus,
            attempts: lines(calls).count,
            naps: lines(naps),
            output: text,
            shipsNotices: manager.fileExists(atPath: notices.path)
        )
    }

    @Test func theLicencesOfWhatItIncludesShipInTheApp() throws {
        #expect(try run(failures: 0).shipsNotices)
    }

    @Test func aGoodImageTakesOneGo() throws {
        let run = try run(failures: 0)
        #expect(run.status == 0)
        #expect(run.attempts == 1)
        #expect(run.naps.isEmpty)
    }

    /// "Resource busy" is gone a moment later, here and on CI runners.
    @Test func aBusyImageIsTriedAgainAfterAPause() throws {
        let run = try run(failures: 2)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.attempts == 3)
        #expect(run.naps == ["1", "2"])
    }

    @Test func theLastTryCanStillWork() throws {
        let run = try run(failures: 4)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.attempts == 5)
    }

    /// It stops, and says what `hdiutil` said: a release must not go out without its image.
    @Test func anImageThatNeverWorksFailsTheScriptWithItsOwnCode() throws {
        let run = try run(failures: .max, status: 36)
        #expect(run.status == 36)
        #expect(run.attempts == 5)
        #expect(run.naps == ["1", "2", "3", "4"])
        #expect(run.output.contains("Resource busy"))
    }
}

import Foundation
import Testing

/// What the app ships from others, and the licences that come with it.
struct ThirdPartyNoticesTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repository.appendingPathComponent(path), encoding: .utf8)
    }

    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { var version: String? }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    private func pins() throws -> [Resolved.Pin] {
        try JSONDecoder().decode(Resolved.self, from: Data(try text("Package.resolved").utf8)).pins
    }

    /// A new dependency fails here until its licence is in the notices.
    @Test func everyDependencyIsOneTheNoticesCover() throws {
        #expect(Set(try pins().map(\.identity)) == ["grdb.swift", "zstd"])
    }

    @Test func theNoticesNameTheVersionsInUse() throws {
        let notices = try text("THIRD-PARTY-NOTICES.md")
        for pin in try pins() {
            let version = try #require(pin.state.version)
            #expect(notices.contains(version), "\(pin.identity) \(version)")
        }
    }

    @Test(arguments: [
        "Copyright (C) 2015-2025 Gwendal Roué",
        "Permission is hereby granted, free of charge, to any person obtaining a copy of this software",
        "Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.",
        "Redistribution and use in source and binary forms, with or without modification,",
        // zstd's dictionary builder is compiled in, and this file of it is MIT, not zstd's BSD.
        "Copyright (c) 2003-2008 Yuta Mori All Rights Reserved.",
    ]) func theNoticesHoldTheLicences(line: String) throws {
        #expect(try text("THIRD-PARTY-NOTICES.md").contains(line))
    }

    @Test(arguments: ["README.md", "README.zh-CN.md"]) func theReadmesLinkTheNotices(readme: String) throws {
        #expect(try text(readme).contains("(THIRD-PARTY-NOTICES.md)"))
    }
}

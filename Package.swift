// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tacho",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TachoKit", targets: ["TachoKit"]),
        .executable(name: "Tacho", targets: ["Tacho"]),
        .executable(name: "tacho-cli", targets: ["tacho-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
        .package(url: "https://github.com/facebook/zstd", from: "1.5.7"),
    ],
    targets: [
        .target(
            name: "TachoKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "libzstd", package: "zstd"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Tacho",
            dependencies: ["TachoKit"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "tacho-cli",
            dependencies: [
                "TachoKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TachoTests",
            dependencies: ["Tacho", "TachoKit"]
        ),
        .testTarget(
            name: "TachoKitTests",
            dependencies: [
                "TachoKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "libzstd", package: "zstd"),
            ]
        ),
    ]
)

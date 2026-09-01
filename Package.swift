// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Tailreg",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "tailreg",
            targets: ["tailreg"]
        ),
        .library(
            name: "TailregCore",
            targets: ["TailregCore"]
        ),
        .library(
            name: "TailregMultiplexer",
            targets: ["TailregMultiplexer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.25.0"
        ),
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            from: "1.30.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/sqlite-data.git",
            from: "1.11.0"
        ),
        .package(
            url: "https://github.com/mhayes853/swift-uuidv7.git",
            from: "0.6.2",
            traits: ["SwiftUUIDV7SQLiteData"]
        ),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            from: "1.1.5"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-clocks",
            from: "1.1.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.8.2"
        ),
        .package(
            url: "https://github.com/mattt/swift-toml.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/mhayes853/swift-edge-tools.git",
            revision: "8a866e2e4dda952d9989d17e409d511d2a7a2f21",
            traits: ["Needle2"]
        )
    ],
    targets: [
        .target(
            name: "TailregCore",
            dependencies: [
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "EdgeTools", package: "swift-edge-tools"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "UUIDV7", package: "swift-uuidv7")
            ]
        ),
        .target(
            name: "TailregMultiplexer",
            dependencies: [
                "TailregCore",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),
        .target(
            name: "TailregCLI",
            dependencies: [
                "TailregCore",
                "TailregMultiplexer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "UUIDV7", package: "swift-uuidv7")
            ]
        ),
        .executableTarget(
            name: "tailreg",
            dependencies: ["TailregCLI"]
        ),
        .executableTarget(
            name: "TailregMultiplexerE2EFixture",
            dependencies: [
                "TailregCore",
                "TailregMultiplexer",
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),
        .testTarget(
            name: "TailregCoreTests",
            dependencies: [
                "TailregCore",
                .product(name: "Clocks", package: "swift-clocks")
            ]
        ),
        .testTarget(
            name: "TailregMultiplexerTests",
            dependencies: [
                "TailregCore",
                "TailregMultiplexer",
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "UUIDV7", package: "swift-uuidv7"),
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        ),
        .testTarget(
            name: "TailregCLITests",
            dependencies: [
                "TailregCLI",
                "TailregCore",
                "TailregMultiplexer"
            ]
        )
    ]
)

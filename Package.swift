// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Tailreg",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Tailreg",
            targets: ["Tailreg"]
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
        )
    ],
    targets: [
        .target(
            name: "Tailreg",
            dependencies: [
                "TailregCore",
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),
        .target(
            name: "TailregCore",
            dependencies: [
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "UUIDV7", package: "swift-uuidv7")
            ]
        ),
        .target(
            name: "TailregMultiplexer",
            dependencies: [
                "TailregCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),
        .executableTarget(
            name: "TailregMultiplexerE2EFixture",
            dependencies: [
                "TailregMultiplexer",
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
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        )
    ]
)

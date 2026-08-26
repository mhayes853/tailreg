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
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.25.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/sqlite-data.git",
            from: "1.11.0"
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
                .product(name: "SQLiteData", package: "sqlite-data")
            ]
        ),
        .testTarget(
            name: "TailregCoreTests",
            dependencies: ["TailregCore"]
        )
    ]
)

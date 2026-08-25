// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tailreg",
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
            name: "TailregCore"
        ),
        .testTarget(
            name: "TailregCoreTests",
            dependencies: ["TailregCore"]
        )
    ]
)

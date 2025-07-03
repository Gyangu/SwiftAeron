// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAeronClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SwiftAeronClient",
            targets: ["SwiftAeronClient"]
        ),
        .executable(
            name: "AeronSwiftTest",
            targets: ["AeronSwiftTest"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftAeronClient",
            dependencies: []
        ),
        .executableTarget(
            name: "AeronSwiftTest",
            dependencies: ["SwiftAeronClient"]
        ),
        .testTarget(
            name: "SwiftAeronClientTests",
            dependencies: ["SwiftAeronClient"]
        )
    ]
)
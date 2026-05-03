// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-persistence",
    platforms: [
        .iOS("13.4"),
        .tvOS("13.4"),
        .macOS("10.15.4"),
        .watchOS("6.2"),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LoggerPersistence",
            targets: ["LoggerPersistence"]
        )
    ],
    dependencies: [
        // Pre-1.0 dependency: pin to the `0.1.x` patch range so a
        // future `0.2.0` does not auto-resolve through SwiftPM's
        // `from:` (up-to-next-major) semantics. The
        // `up-to-next-minor` requirement keeps consumer builds
        // stable until a deliberate bump.
        .package(
            url: "https://github.com/swift-loggers/swift-logger.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "LoggerPersistence",
            dependencies: [
                .product(name: "Loggers", package: "swift-logger")
            ]
        ),
        .testTarget(
            name: "LoggerPersistenceTests",
            dependencies: [
                "LoggerPersistence",
                .product(name: "Loggers", package: "swift-logger")
            ]
        )
    ]
)

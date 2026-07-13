// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EventKitMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "eventkit-mcp-server",
            targets: ["EventKitMCP"]
        ),
        .library(
            name: "EventKitService",
            targets: ["EventKitService"]
        )
    ],
    dependencies: [
        // Official MCP Swift SDK
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Argument parsing for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // JSON Schema generation with @Schemable macro
        .package(url: "https://github.com/ajevans99/swift-json-schema.git", from: "0.11.0")
    ],
    targets: [
        // MARK: - Main Executable
        .executableTarget(
            name: "EventKitMCP",
            dependencies: [
                "EventKitService",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema")
            ],
            path: "Sources/EventKitMCP",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),

        // MARK: - EventKit Service Layer
        .target(
            name: "EventKitService",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/EventKitService"
        ),

        // MARK: - Tests
        .testTarget(
            name: "EventKitServiceTests",
            dependencies: ["EventKitService"],
            path: "Tests/EventKitServiceTests"
        ),
        .testTarget(
            name: "EventKitMCPTests",
            dependencies: [
                "EventKitMCP",
                "EventKitService",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/EventKitMCPTests"
        )
    ]
)

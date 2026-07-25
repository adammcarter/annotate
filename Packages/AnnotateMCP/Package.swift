// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotateMCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotateMCPKit", targets: ["AnnotateMCPKit"]),
        .executable(name: "annotate-mcp", targets: ["annotate-mcp"]),
    ],
    dependencies: [
        .package(path: "../AnnotateCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "AnnotateMCPKit",
            dependencies: [
                .product(name: "AnnotateCore", package: "AnnotateCore"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "annotate-mcp",
            dependencies: ["AnnotateMCPKit"]
        ),
        .testTarget(
            name: "AnnotateMCPKitTests",
            dependencies: [
                "AnnotateMCPKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "AnnotateCore", package: "AnnotateCore"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotateCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotateCore", targets: ["AnnotateCore"]),
    ],
    targets: [
        .target(name: "AnnotateCore"),
        .testTarget(name: "AnnotateCoreTests", dependencies: ["AnnotateCore"]),
    ]
)

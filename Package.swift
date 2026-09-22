// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "afm-agent-harness",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "afm-harness",
            targets: ["afm-harness"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "afm-harness",
            dependencies: [],
            path: "Sources/afm-harness"
        )
    ]
)

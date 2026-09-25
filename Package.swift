// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-cua",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CUACore",
            path: "Sources/CUACore"
        ),
        .executableTarget(
            name: "agent-cua",
            dependencies: ["CUACore"],
            path: "Sources/dsh-cua"
        ),
        .executableTarget(
            name: "cua-selftest",
            dependencies: ["CUACore"],
            path: "Sources/cua-selftest"
        ),
    ]
)

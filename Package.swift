// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dsh-cua",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CUACore",
            path: "Sources/CUACore"
        ),
        .executableTarget(
            name: "dsh-cua",
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

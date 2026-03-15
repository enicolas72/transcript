// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeakerTool",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "SpeakerTool",
            dependencies: ["FluidAudio"]
        ),
    ]
)

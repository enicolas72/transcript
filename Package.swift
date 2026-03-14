// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcript",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transcript",
            path: "Sources"
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Murmur",
            path: "Sources/Murmur",
            resources: [
                .copy("Resources/cleanup_prompt.txt"),
                .copy("Resources/styles.json"),
            ]
        )
    ]
)

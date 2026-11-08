// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Murmur",
            resources: [
                .copy("Resources/cleanup_prompt.txt"),
                .copy("Resources/styles.json"),
                .copy("Resources/fewshot.json"),
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "parakeet_bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3")],
    targets: [.executableTarget(name: "parakeet_bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)

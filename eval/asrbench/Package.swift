// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "asrbench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../.build/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "asrbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)

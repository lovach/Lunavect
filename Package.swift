// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Weekleft", platforms: [.macOS(.v14)], products: [.executable(name: "Weekleft", targets: ["Weekleft"])], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
], targets: [
    .target(name: "WeekleftCore", resources: [.process("Resources")]),
    .target(name: "AwakeService"),
    .executableTarget(name: "LunavectAwakeHelper", dependencies: ["AwakeService"]),
    .executableTarget(name: "LunavectHook", dependencies: ["WeekleftCore"]),
    .executableTarget(name: "Weekleft", dependencies: ["WeekleftCore", "AwakeService", .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")]),
    .testTarget(name: "AwakeServiceTests", dependencies: ["AwakeService"]),
    .testTarget(name: "WeekleftCoreTests", dependencies: ["WeekleftCore"]),
    .testTarget(name: "WeekleftUITests", dependencies: ["Weekleft", "WeekleftCore", "AwakeService"])
])

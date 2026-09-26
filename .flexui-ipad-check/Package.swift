// swift-tools-version:6.0
// Throwaway compile gate for FlexUI's iPad App-target Aether engine (client/ios/App/App/
// AetherVideoEngine.swift) against this engine revision. FlexuiNative mirrors the pod's
// FlexVideoEngine.swift. Swift 5 language mode matches the App target (SWIFT_VERSION = 5.0).
import PackageDescription

let package = Package(
    name: "FlexUIiPadCheck",
    platforms: [.iOS(.v18)],
    products: [.library(name: "AppCheck", targets: ["AppCheck"])],
    dependencies: [.package(name: "AetherEngine", path: "..")],
    targets: [
        .target(name: "FlexuiNative", path: "FlexuiNative",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AppCheck",
                dependencies: ["FlexuiNative", .product(name: "AetherEngine", package: "AetherEngine")],
                path: "AppCheck",
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

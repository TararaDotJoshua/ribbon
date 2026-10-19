// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ribbon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ribbon", targets: ["Ribbon"]),
    ],
    targets: [
        // Pure layout math: the strip, navigation, paging, widths. No AppKit.
        .target(name: "RibbonCore"),
        // The window manager: AX bridge, event tap, menu bar item.
        .executableTarget(name: "Ribbon", dependencies: ["RibbonCore"]),
        // A throwaway app that opens numbered windows, for safe live testing.
        .executableTarget(name: "RibbonTestWindows", path: "Tools/RibbonTestWindows"),
        .testTarget(name: "RibbonCoreTests", dependencies: ["RibbonCore"]),
    ],
    swiftLanguageModes: [.v5]
)

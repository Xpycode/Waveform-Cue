// swift-tools-version: 6.2
import PackageDescription

// Models, rendering, analysis and export for Waveform Cue. Kept apart from the app target so
// `swift test` runs them headlessly; `xcodebuild test` would launch the app on the desktop.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "CueCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CueCore", targets: ["CueCore"])],
    dependencies: [
        // House packages, beside this project's folder (`1-macOS/zPackages`). Agent worktrees reach
        // them through an ignored `.claude/worktrees/zPackages` symlink.
        .package(path: "../../../../zPackages")
    ],
    targets: [
        .target(name: "CueCore", dependencies: [.product(name: "ProcessKit", package: "zPackages")], swiftSettings: v5),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"], swiftSettings: v5)
    ]
)

// swift-tools-version: 6.2
import PackageDescription

// Models, rendering, analysis and export for Waveform Cue. Kept apart from the app target so
// `swift test` runs them headlessly; `xcodebuild test` would launch the app on the desktop.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "CueCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CueCore", targets: ["CueCore"])],
    targets: [
        .target(name: "CueCore", swiftSettings: v5),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"], swiftSettings: v5)
    ]
)

import XCTest
@testable import CueCore

/// Spec performance target: a 3-minute AVC-Intra 100 cue exports in under 3 minutes.
/// Opt in with `CUE_BENCH=1` and `FFMPEG_EXECUTABLE`; each export takes tens of seconds.
final class PerformanceTests: XCTestCase {

    static let seconds = 180.0
    static let limit: TimeInterval = 180

    func testThreeMinuteAVCIntraExportsFinishInUnderThreeMinutes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CUE_BENCH"] == "1",
                          "Set CUE_BENCH=1 to run the 3-minute export benchmark.")
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("performance")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("three-minutes.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)*(0.6+0.4*sin(PI*t/9))", right: "0.3*sin(2*PI*220*t)",
                               seconds: Self.seconds, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)

        for preset in [ExportPreset.avcIntra1080p25, .avcIntra1080i50] {
            let timeline = MXFExport.timeline(for: track, preset: preset)
            let output = dir.appendingPathComponent(preset.id.rawValue + ".mxf")
            let began = Date()
            try MXFExport.run(snapshot: MXFExport.Snapshot(track: track, label: CueLabel(text: "Performance"), layout: .four),
                              preset: preset, timeline: timeline, encoder: ffmpeg, destination: output, progress: { _ in })
            let elapsed = Date().timeIntervalSince(began)
            print(String(format: "[6.1 perf] %@: %.0f s clip, %d images in %.1f s (%.1f× real time)",
                         preset.id.rawValue, Self.seconds, timeline.positionCount, elapsed, Self.seconds / elapsed))
            XCTAssertLessThan(elapsed, Self.limit, "\(preset.id.rawValue) took \(elapsed) s")
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 1_000_000_000, "\(preset.id.rawValue): a 3-minute AVC-I 100 file is over 1 GB")
            try? FileManager.default.removeItem(at: output)
        }
    }
}

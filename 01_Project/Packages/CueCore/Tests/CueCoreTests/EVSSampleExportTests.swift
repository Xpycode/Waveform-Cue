import XCTest
@testable import CueCore

/// Writes the gate X2 sample set for an EVS ingest test with the app's own export engine.
/// Opt in with `CUE_X2_DIR=/folder` and `FFMPEG_EXECUTABLE`. Left is a 440 Hz tone and right a
/// 660 Hz tone, so the operator can hear which track carries which channel; tracks 3 and up
/// should be silent. The music fades out at 15 s and is followed by 5 s of silence.
final class EVSSampleExportTests: XCTestCase {

    struct Sample {
        let name: String
        let preset: ExportPreset
        let layout: AudioLayout
        var start = "10:00:00:00"
        var trim = TrimSettings.none
        var safeZones = false
    }

    static let samples: [Sample] = [
        Sample(name: "X2-01 AVC-I 1080i50 2 mono TC 10-00-00-00", preset: .avcIntra1080i50, layout: .two),
        Sample(name: "X2-02 AVC-I 1080i50 4 mono TC 10-00-00-00", preset: .avcIntra1080i50, layout: .four),
        Sample(name: "X2-03 AVC-I 1080i50 8 mono TC 10-00-00-00", preset: .avcIntra1080i50, layout: .eight),
        Sample(name: "X2-04 AVC-I 1080p25 4 mono TC 10-00-00-00", preset: .avcIntra1080p25, layout: .four),
        Sample(name: "X2-05 AVC-I 1080p50 Experimental 4 mono TC 10-00-00-00", preset: .avcIntra1080p50, layout: .four),
        Sample(name: "X2-06 AVC-I 1080i50 4 mono pre-roll 5 s, music at 00-00-00-00 (file TC 23-59-55-00)",
               preset: .avcIntra1080i50, layout: .four, start: "00:00:00:00", trim: TrimSettings(preRoll: 5)),
        Sample(name: "X2-07 AVC-I 1080i50 4 mono EVS OSD safe zones", preset: .avcIntra1080i50, layout: .four,
               safeZones: true),
        Sample(name: "X2-08 MPEG-2 1080p25 legacy 2 mono TC 10-00-00-00", preset: .mpeg2_1080p25, layout: .two),
    ]

    func testWriteEVSSamples() throws {
        guard let path = ProcessInfo.processInfo.environment["CUE_X2_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CUE_X2_DIR to write the EVS sample set.")
        }
        let ffmpeg = try TestAudio.ffmpeg()
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = try TestAudio.temporaryDirectory("evs-samples")
        defer { try? FileManager.default.removeItem(at: work) }
        let wav = work.appendingPathComponent("X2 sample.wav")
        let envelope = #"if(lt(t\,12)\,1\,max(0\,(15-t)/3))"#  // commas escaped for the lavfi graph
        try FFmpegRun.generate(left: "0.4*sin(2*PI*440*t)*" + envelope, right: "0.4*sin(2*PI*660*t)*" + envelope,
                               seconds: 20, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)

        for sample in Self.samples {
            var appearance = CueAppearance()
            if sample.safeZones { appearance.safeZones = SafeZones(preset: .evsOSD) }
            let start = try XCTUnwrap(Timecode(sample.start), sample.name)
            let timeline = MXFExport.timeline(for: track, preset: sample.preset, trim: sample.trim)
            let destination = folder.appendingPathComponent(sample.name + ".mxf")
            try MXFExport.run(snapshot: MXFExport.Snapshot(track: track, label: CueLabel(text: "EVS test " + String(sample.name.prefix(5))),
                                                           appearance: appearance, layout: sample.layout,
                                                           startTimecode: start),
                              preset: sample.preset, timeline: timeline, encoder: ffmpeg,
                              destination: destination, progress: { _ in })
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), sample.name)
        }
    }
}

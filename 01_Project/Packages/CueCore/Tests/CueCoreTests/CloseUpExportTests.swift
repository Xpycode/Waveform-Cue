import XCTest
import CoreGraphics
@testable import CueCore

final class CloseUpExportTests: XCTestCase {
    func testDecodedEndZoomFieldsFollowWindowAndWholeFramesMatchPreview() throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("close-up-fields")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)", right: "0.25*sin(2*PI*660*t)",
                               seconds: 7, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        let trim = TrimSettings(inPoint: 1, outPoint: 6)
        let marker = 4.8
        let markers = MusicMarkers(editedMusicEnd: marker)
        let label = CueLabel(text: "Field check")
        let preset = ExportPreset.avcIntra1080i50
        let export = MXFExport.timeline(for: track, preset: preset, trim: trim, markers: markers)

        for mode in PlayheadMode.allCases {
            var look = CueAppearance()
            look.zoom = .five
            look.endZoom = .two
            look.playheadMode = mode
            let detail = try XCTUnwrap(look.layout.detail)
            let preview = CuePicture.timeline(for: track, appearance: look, markers: markers, trim: trim)
            let file = dir.appendingPathComponent(mode.rawValue + ".mxf")
            try MXFExport.run(snapshot: .init(track: track, label: label, appearance: look), preset: preset,
                              timeline: export, encoder: ffmpeg, destination: file, progress: { _ in })

            // Three consecutive edit units in the easing interval. Inspect the yellow marker
            // in the actual woven raster independently of the draw path used by both clients.
            for frame in 70...72 {
                let decoded = try FFmpegRun.decodeFrame(file, index: frame, ffmpeg: ffmpeg)
                let first = Preview.render(track, timeline: preview, position: frame, label: label, appearance: look)
                let second = Preview.render(track, timeline: export, position: frame * 2 + 1, label: label, appearance: look)
                let expected = Preview.weave(top: first, bottom: second)
                XCTAssertLessThan(Preview.meanError(decoded, expected), 1, "\(mode), frame \(frame)")
                for field in 0...1 {
                    let sourceTime = 1 + Double(frame * 2 + field) / 50
                    let window = CloseUpWindow.interval(playhead: sourceTime, clip: 1...6, target: 6,
                                                        startingWidth: 5, mode: mode, endZoom: .two).visible
                    let x = detail.minX + detail.width * (marker - window.lowerBound)
                        / (window.upperBound - window.lowerBound)
                    let row = Int(1080 - detail.midY) / 2 * 2 + field
                    let pixels = (Int(detail.minX)..<Int(detail.maxX)).filter { column in
                        let i = (row * 1920 + column) * 4
                        return decoded[i + 2] > 185 && decoded[i + 1] > 140 && decoded[i] < 115
                    }
                    let left = try XCTUnwrap(pixels.first, "\(mode), frame \(frame), field \(field)")
                    let right = try XCTUnwrap(pixels.last)
                    XCTAssertLessThanOrEqual(right - left, 4)
                    XCTAssertEqual(Double(left + right + 1) / 2, x, accuracy: 1.5,
                                   "\(mode), frame \(frame), field \(field)")
                }
            }
        }
    }
}

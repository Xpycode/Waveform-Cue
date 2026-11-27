import XCTest
import CoreGraphics
import CryptoKit
@testable import CueCore

/// Build 10 behaviour, captured before the batch round. Later render tasks must keep these
/// hashes unchanged whenever their new settings are at their defaults (safe zones None,
/// countdown target File end, no markers, no trim, no pre-roll).
///
/// Hashes depend on Core Text and Core Graphics output, so they are pinned to this macOS
/// release. To re-record after an OS update, run with `CUE_RECORD_BASELINE=1` and check the
/// printed values against a visual comparison before replacing them.
final class BaselineTests: XCTestCase {

    // MARK: - Fixtures

    /// A 30-second synthetic track: a swelling tone with a fade and a quiet tail.
    static func syntheticTrack(seconds: Double = 30) -> AudioTrack {
        let count = Int(seconds * 200)
        let detail: [Float] = (0..<count).map { i in
            let t = Double(i) / 200
            let envelope = t < seconds - 6 ? 0.35 + 0.6 * abs(sin(t * 0.9)) : max(0, (seconds - 2 - t) / 4) * 0.8
            let ripple = 0.08 * sin(t * 37)
            return Float(max(0, min(1, envelope + ripple)))
        }
        let pcm = PreparedAudio(url: URL(fileURLWithPath: "/nonexistent/baseline.caf"))
        return AudioTrack(url: URL(fileURLWithPath: "/tmp/Baseline Track.wav"), pcm: pcm, seconds: seconds,
                          detailPeaks: detail, peaks: AudioTrack.reducePeaks(detail[...], columns: 1600))
    }

    static func render(_ track: AudioTrack, frame: Int, label: CueLabel, appearance: CueAppearance) -> Data {
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let bitmap = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 7680,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
        let path = CuePicture.waveform(track.peaks, in: CuePicture.overviewRect(for: appearance.zoom))
        CuePicture.draw(in: bitmap, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                        path: path, frame: frame, label: label, appearance: appearance)
        return Data(bytes: bitmap.data!, count: bitmap.bytesPerRow * bitmap.height)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Case {
        let name: String
        let label: CueLabel
        let appearance: CueAppearance
    }

    static var cases: [Case] {
        var zoomOff = CueAppearance()
        zoomOff.zoom = .off
        var warning = CueAppearance()
        warning.warning = .ten
        warning.solidRedAt = .oneSecond
        warning.fadeFullTrack = true
        return [
            Case(name: "default", label: CueLabel(text: "Baseline Track"), appearance: CueAppearance()),
            Case(name: "zoomOff", label: CueLabel(text: "Baseline Track"), appearance: zoomOff),
            Case(name: "customTitle", label: CueLabel(text: "A Much Longer Cue Title For Position",
                                                      position: CGPoint(x: 0.3, y: 0.6)),
                 appearance: CueAppearance()),
            Case(name: "warning", label: CueLabel(text: "Baseline Track"), appearance: warning),
        ]
    }

    /// First, middle, 5 s left, 1 s left, last.
    static func frames(for track: AudioTrack) -> [Int] {
        [0, track.frames / 2, track.frames - 5 * AudioTrack.fps, track.frames - AudioTrack.fps, track.frames]
    }

    static let expected: [String: String] = [
        "default@0": "f44853a073dcd58a41e174fffc2e950f645408fded14b19cfd16489e7a030a3d",
        "default@375": "c77fe66913eaefc4b9b61897e97e2041d599726d5c7e0224bbe9b0e8f6055b6d",
        "default@625": "5f9376abc008fcd5a1d621f467c74c1d3ed0417118db4fc9a0301fb227b157b8",
        "default@725": "2aa702edefb03d4fe9dea41bda079f616cea85fa00480e9856c253ad98f4480e",
        "default@750": "efe5243e533274205b1e94e748949a44ef0694ea4aa8f3c2ae8f9c6dfc32b78d",
        "zoomOff@0": "2bbc80b473124cb3f6c8436fab2305bb09de29aee4be3091408cf8875d522cbd",
        "zoomOff@375": "876cafaf3e0f3517f3ef9926e3e24bbd8114516b725627f624ce80ea256fd730",
        "zoomOff@625": "03a6ef5001f5c75e801d7703addeb01fa004fd13f52fb123e71b5672346fa5f7",
        "zoomOff@725": "993a7a67021584ad04906e7e2446665b3b799df3bbedef6ee48228d0198a3179",
        "zoomOff@750": "de63cbe1c9551532c96e0a4a5ea41abd7626ef2922e068cc4eb05c996c5da663",
        "customTitle@0": "f42068101676d78cbd554a4cd288d05bc393e431887bb27e2d3de66037bcb5c8",
        "customTitle@375": "9cc68b3fb9c84bd1f04f971b38bc304b004892ede64fbaf06bf0c2e1c1853ff8",
        "customTitle@625": "faa2d3e30ab24b706784d8cb3656294f306181de34fb0ee66f397b03a41ac5ee",
        "customTitle@725": "5028f721a9af0789f97110de5a56e4d5bcce5cea728d58a90449e9d16369ed36",
        "customTitle@750": "0865f1b05e339c8e2f8018e17c8733034309e7d6ab2957e1ae0ca6d3f9ae2b6a",
        "warning@0": "f44853a073dcd58a41e174fffc2e950f645408fded14b19cfd16489e7a030a3d",
        "warning@375": "c77fe66913eaefc4b9b61897e97e2041d599726d5c7e0224bbe9b0e8f6055b6d",
        "warning@625": "d80efe2e3df48644d6b19a2bfdcbce68ba475caeb6f55780eb10e3d9eb709ae0",
        "warning@725": "63dd877109a582bf616f5141731543d93f2ed401fabb3742f809e71c9c876ca9",
        "warning@750": "f208fe3f4c131416dcdfc299ce3e71610a9652e3a686331bffca9d3b27d1d549",
    ]

    // MARK: - Render baseline

    func testRenderHashesMatchBuild10() throws {
        let track = Self.syntheticTrack()
        let record = ProcessInfo.processInfo.environment["CUE_RECORD_BASELINE"] == "1"
        var recorded: [String] = []
        for item in Self.cases {
            for frame in Self.frames(for: track) {
                let key = "\(item.name)@\(frame)"
                let value = Self.hash(Self.render(track, frame: frame, label: item.label, appearance: item.appearance))
                recorded.append("        \"\(key)\": \"\(value)\",")
                if !record {
                    let expected = try XCTUnwrap(Self.expected[key], "No baseline recorded for \(key)")
                    XCTAssertEqual(value, expected, "Render changed for \(key)")
                }
            }
        }
        if record { print("BASELINE\n" + recorded.joined(separator: "\n")) }
    }

    func testRenderIsDeterministic() {
        let track = Self.syntheticTrack()
        let a = Self.render(track, frame: 100, label: CueLabel(text: "x"), appearance: CueAppearance())
        let b = Self.render(track, frame: 100, label: CueLabel(text: "x"), appearance: CueAppearance())
        XCTAssertEqual(a, b)
    }

    // MARK: - Clock, frames, countdown, close-up

    func testClock() {
        XCTAssertEqual(AudioTrack.clock(0), "00:00:00")
        XCTAssertEqual(AudioTrack.clock(24), "00:00:24")
        XCTAssertEqual(AudioTrack.clock(25), "00:01:00")
        XCTAssertEqual(AudioTrack.clock(25 * 61 + 3), "01:01:03")
        XCTAssertEqual(AudioTrack.clock(-5), "00:00:00")
        XCTAssertEqual(AudioTrack.clock(25 * 3600), "60:00:00")
    }

    func testFrameRounding() {
        XCTAssertEqual(Self.syntheticTrack(seconds: 10).frames, 250)
        XCTAssertEqual(Self.syntheticTrack(seconds: 10.001).frames, 251)
        XCTAssertEqual(Self.syntheticTrack(seconds: 10.04).frames, 251)
        XCTAssertEqual(Self.syntheticTrack(seconds: 0.01).frames, 1)
        XCTAssertEqual(Self.syntheticTrack(seconds: 30).frames, 750)
    }

    func testCountdownFraction() {
        XCTAssertEqual(CountdownWarning.off.fraction(framesLeft: 1, solidAt: .lastFrame), 0)
        XCTAssertEqual(CountdownWarning.five.fraction(framesLeft: 125, solidAt: .lastFrame), 0)
        XCTAssertEqual(CountdownWarning.five.fraction(framesLeft: 124, solidAt: .lastFrame), 1.0 / 124, accuracy: 1e-12)
        XCTAssertEqual(CountdownWarning.five.fraction(framesLeft: 1, solidAt: .lastFrame), 1)
        XCTAssertEqual(CountdownWarning.ten.fraction(framesLeft: 25, solidAt: .oneSecond), 1)
        XCTAssertEqual(CountdownWarning.ten.fraction(framesLeft: 26, solidAt: .oneSecond), 224.0 / 225, accuracy: 1e-12)
        XCTAssertEqual(CountdownWarning.ten.fraction(framesLeft: 0, solidAt: .lastFrame), 1)
    }

    func testCloseUpWindow() {
        XCTAssertEqual(CuePicture.closeUp(frame: 0, total: 750, zoom: .auto), 0..<250)
        XCTAssertEqual(CuePicture.closeUp(frame: 375, total: 750, zoom: .auto), 250..<500)
        XCTAssertEqual(CuePicture.closeUp(frame: 750, total: 750, zoom: .auto), 500..<750)
        XCTAssertEqual(CuePicture.closeUp(frame: 10, total: 100, zoom: .auto), 0..<50)
        XCTAssertEqual(CuePicture.closeUp(frame: 300, total: 750, zoom: .two), 275..<325)
        XCTAssertEqual(CuePicture.closeUp(frame: 300, total: 750, zoom: .off), 0..<750)
        XCTAssertEqual(CuePicture.closeUp(frame: 5, total: 20, zoom: .sixty), 0..<20)
    }

    // MARK: - Benchmark

    func testRenderBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CUE_BENCH"] == "1", "Set CUE_BENCH=1 to run the benchmark.")
        let track = Self.syntheticTrack(seconds: 180)
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let bitmap = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 7680,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
        let appearance = CueAppearance()
        let path = CuePicture.waveform(track.peaks, in: CuePicture.overviewRect(for: appearance.zoom))
        let count = 500
        let start = Date()
        for frame in 0..<count {
            autoreleasepool {
                CuePicture.draw(in: bitmap, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                                path: path, frame: frame * 9, label: CueLabel(text: "Benchmark"), appearance: appearance)
            }
        }
        let fps = Double(count) / Date().timeIntervalSince(start)
        print(String(format: "BENCH CuePicture.draw 1920x1080: %.1f frames/s", fps))
    }
}

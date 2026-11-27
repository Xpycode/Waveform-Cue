import XCTest
import CoreGraphics
import CryptoKit
@testable import CueCore

/// Build 10 behaviour, captured before the batch round. Later render tasks must keep these
/// hashes unchanged whenever their new settings are at their defaults (safe zones None,
/// countdown target File end, no markers, no trim, no pre-roll).
///
/// Hashes depend on Core Text and Core Graphics output, so they are pinned per macOS
/// release (see `expected`). To re-record after an OS update, run with `CUE_RECORD_BASELINE=1` and check the
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
        var zoomOff = CueAppearance.build10
        zoomOff.zoom = .off
        var warning = CueAppearance.build10
        warning.warning = .ten
        warning.solidRedAt = .oneSecond
        warning.fadeFullTrack = true
        return [
            Case(name: "default", label: CueLabel(text: "Baseline Track"), appearance: .build10),
            Case(name: "zoomOff", label: CueLabel(text: "Baseline Track"), appearance: zoomOff),
            Case(name: "customTitle", label: CueLabel(text: "A Much Longer Cue Title For Position",
                                                      position: CGPoint(x: 0.3, y: 0.6)),
                 appearance: .build10),
            Case(name: "warning", label: CueLabel(text: "Baseline Track"), appearance: warning),
        ]
    }

    /// First, middle, 5 s left, 1 s left, last.
    static func frames(for track: AudioTrack) -> [Int] {
        [0, track.frames / 2, track.frames - 5 * AudioTrack.fps, track.frames - AudioTrack.fps, track.frames]
    }

    /// The baseline for the running macOS release. Core Text and Core Graphics output differs
    /// between major releases, so each release keeps its own table.
    static var expected: [String: String] {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? expectedMacOS27 : expectedOriginal
    }

    /// Recorded on macOS 27.2 (M1 Max, 2026-11-27). The task 0.2 code (`4e41e75`) and the code at
    /// task 6.0 give exactly these hashes there, so the render is unchanged since the baseline.
    static let expectedMacOS27: [String: String] = [
        "default@0": "55f4d3ac7fedaec956e2d065f0d6e4589dd041b3e6c52a5a6575f0f2f9ba925c",
        "default@375": "5078ff3869fe7ea7d42490a41f36de3dbbcd323e21b763991a0f6a8de5477cd2",
        "default@625": "a53c11ce4399fa829455d5665575e7f3ce99c1aadea6058db20e6bbd8364acb2",
        "default@725": "fb337e7a9cbb4b1c0f9f9cde438710607f98ef32854bc8015af3ceb0a17d1a4a",
        "default@750": "72a2c834d29b181f5e618131585dd4285b496124e724d122b12f9540492ec44a",
        "zoomOff@0": "65d6acde477c30d3e86a1a7281ebb0714ed3fd22280c22282aaf58ea04910730",
        "zoomOff@375": "3c5a44c92795ef86527eb8dfc9dffdfd40c2035c27cb28537e717971454ddec6",
        "zoomOff@625": "60ea14c27c1d758ea973019fb3f8cde3070728b1e3462905a9ff45b42c83a74a",
        "zoomOff@725": "02a5605c36b4937a4b985e3da44b56fb02993486e27833eb1269ac2213c02e80",
        "zoomOff@750": "7a383a22ea8a434b56c965dc002829888e179898ed64fc6a10200b46961eadb7",
        "customTitle@0": "02f34483f04e06bb98e1fb40a6d80567a1fbce2b0488ad0c94c0b7ee612c4ec4",
        "customTitle@375": "3ffe6900ed44bc4446c6f84d2d681121448750f13f5748dfa8657113136f98ad",
        "customTitle@625": "85c3c7d91f2945c969a5a7d49cce00d3b04fa6be881ec0151807e18edc5e6dd6",
        "customTitle@725": "302315b0c6c5a8c0d8da78bcbd2ba3a57e2f94035800f7a6cf3c28de6daeb95e",
        "customTitle@750": "3495457494fe1d29dce9efa3794404902b989f67eee467e7366dd23b5b6fcf74",
        "warning@0": "55f4d3ac7fedaec956e2d065f0d6e4589dd041b3e6c52a5a6575f0f2f9ba925c",
        "warning@375": "5078ff3869fe7ea7d42490a41f36de3dbbcd323e21b763991a0f6a8de5477cd2",
        "warning@625": "1de6d9a7ff550aa37f48e1a976dfcfb2c6c75b4b3acf64c0edda638a158cc06d",
        "warning@725": "463e03d869072f01c7da9e1a462844d1b8e9aec6c9f9bf27a9a570806c37c7aa",
        "warning@750": "6c7f15b206d0c06a9313e3dd51509243cdfa18d2f7fe1ad5cc598f460c6e2b64",
    ]

    /// Recorded at task 0.2 on the M4 Pro, where it matched build 10.
    static let expectedOriginal: [String: String] = [
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

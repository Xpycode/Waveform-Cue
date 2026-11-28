import XCTest
import AVFoundation
@testable import CueCore

/// Shared fixtures for tests that need FFmpeg or generated audio.
enum TestAudio {
    /// FFmpeg from `FFMPEG_EXECUTABLE`, or an explicit skip.
    static func ffmpeg() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FFMPEG_EXECUTABLE"], !path.isEmpty else {
            throw XCTSkip("Set FFMPEG_EXECUTABLE to an ffmpeg binary to run this test.")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("FFMPEG_EXECUTABLE (\(path)) is not executable.")
        }
        return URL(fileURLWithPath: path)
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueCoreTests-" + name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a stereo WAV from an `aevalsrc` expression (in `t`, seconds) with FFmpeg.
    static func generate(_ expression: String, seconds: Double, to url: URL, ffmpeg: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                             "-i", "aevalsrc=\(expression)|\(expression):s=48000:d=\(seconds)",
                             "-c:a", "pcm_s24le", url.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CueError("FFmpeg could not generate the fixture.") }
    }

    /// A stand-in for FFmpeg that never finishes: it records its PID in `<dir>/slow.pid`, writes a
    /// byte to its last argument when that is a `.caf` (a decode's output path), then sleeps.
    /// Lets cancellation tests run deterministically without FFmpeg.
    static func slowTool(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("slow-tool.sh")
        let pid = dir.appendingPathComponent("slow.pid").path
        let script = "#!/bin/sh\nfor last; do :; done\necho $$ > '\(pid)'\ncase \"$last\" in *.caf) printf x > \"$last\";; esac\nexec sleep 60\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// PID the slow tool recorded, once it has started.
    static func slowToolPID(in dir: URL, timeout: TimeInterval = 10) async throws -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        let path = dir.appendingPathComponent("slow.pid")
        while Date() < deadline {
            if let text = try? String(contentsOf: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// Waits until `pid` no longer exists (or is a zombie nobody has reaped); true when gone.
    static func waitForExit(_ pid: pid_t, timeout: TimeInterval = 10) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// 0.5-amplitude 440 Hz tone; full level to 6 s, linear fade to silence at 8 s, silent to 10 s.
    static let fadeExpression = "0.5*sin(2*PI*440*t)*clip((8-t)/2\\,0\\,1)"

    /// Writes a 48 kHz stereo float CAF directly (no FFmpeg) from a per-sample amplitude function.
    static func writeCAF(seconds: Double, to url: URL, sample: (Double) -> Float) throws -> PreparedAudio {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * 48000)
        let chunk = 48000
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                let value = sample(Double(written + i) / 48000)
                buffer.floatChannelData![0][i] = value
                buffer.floatChannelData![1][i] = -value
            }
            try file.write(from: buffer)
            written += n
        }
        return PreparedAudio(url: url)
    }
}

final class AudioTrackTests: XCTestCase {

    /// The FFmpeg-generated fade-and-tail WAV through the full `read` path.
    func testReadFindsMusicEndAndFadeStartOnGeneratedWAV() throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("fade.wav")
        try TestAudio.generate(TestAudio.fadeExpression, seconds: 10, to: wav, ffmpeg: ffmpeg)

        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        XCTAssertTrue(track.isDecoded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: track.pcm.url.path))
        XCTAssertEqual(track.seconds, 10, accuracy: 0.001)
        XCTAssertEqual(Double(track.absolutePeak), 0.5, accuracy: 0.01)
        XCTAssertFalse(track.markers.noMusic)
        // −60 dBFS crossing: 0.25·(8 − t) = 0.001 → t ≈ 7.996 s.
        XCTAssertEqual(try XCTUnwrap(track.markers.musicEnd), 8.0, accuracy: 0.02)
        // Peak −6 dBFS, fade level −46 dBFS (0.005): 0.25·(8 − t) = 0.005 → t ≈ 7.98 s.
        let fade = try XCTUnwrap(track.markers.fadeStart)
        XCTAssertEqual(fade, 7.98, accuracy: 0.02)
        XCTAssertLessThanOrEqual(fade, try XCTUnwrap(track.markers.musicEnd))
        XCTAssertEqual(track.detailPeaks.max(), 1)
        XCTAssertEqual(track.peaks.count, 1600)
    }

    /// A track with no silent tail reports music to the file end (whole-frame padding is not a tail).
    func testNoTailMeansFileEnd() throws {
        let dir = try TestAudio.temporaryDirectory("notail")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 3.01 s is not a whole number of 25 fps frames, so the analysis pads 0.03 s.
        let pcm = try TestAudio.writeCAF(seconds: 3.01, to: dir.appendingPathComponent("a.caf")) { t in
            Float(0.4 * sin(2 * .pi * 220 * t))
        }
        let track = try AudioTrack.analyse(dir.appendingPathComponent("a.wav"), audio: pcm)
        XCTAssertEqual(track.markers.musicEnd, track.seconds)
        XCTAssertEqual(track.markers.fadeStart, track.seconds)
    }

    func testSilentTrackHasNoMusic() throws {
        let dir = try TestAudio.temporaryDirectory("silent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm = try TestAudio.writeCAF(seconds: 2, to: dir.appendingPathComponent("s.caf")) { _ in 0.0005 }
        let track = try AudioTrack.analyse(dir.appendingPathComponent("s.wav"), audio: pcm)
        XCTAssertTrue(track.markers.noMusic)
        XCTAssertNil(track.markers.musicEnd)
        XCTAssertEqual(Double(track.absolutePeak), 0.0005, accuracy: 1e-6)
    }

    /// The fade-and-tail shape without FFmpeg, and the peaks keep build 10's normalisation.
    func testAnalyseFadeAndTailWithoutFFmpeg() throws {
        let dir = try TestAudio.temporaryDirectory("analyse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm = try TestAudio.writeCAF(seconds: 10, to: dir.appendingPathComponent("f.caf")) { t in
            Float(0.5 * sin(2 * .pi * 440 * t) * min(1, max(0, (8 - t) / 2)))
        }
        let track = try AudioTrack.analyse(dir.appendingPathComponent("f.wav"), audio: pcm)
        XCTAssertEqual(try XCTUnwrap(track.markers.musicEnd), 8.0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(track.markers.fadeStart), 7.98, accuracy: 0.02)
        XCTAssertEqual(track.detailPeaks.count, 2000)
        XCTAssertEqual(track.detailPeaks.max(), 1)
        // Normalised peaks are the absolute ones divided by the absolute peak.
        XCTAssertEqual(Double(track.detailPeaks[100] * track.absolutePeak), 0.5, accuracy: 0.001)
        XCTAssertEqual(track.detailPeaks.last, 0)
    }

    // MARK: - Restored tracks

    func testRestoredTrackMatchesAnalysedTrackWithoutAudio() throws {
        let dir = try TestAudio.temporaryDirectory("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("r.wav")
        let pcm = try TestAudio.writeCAF(seconds: 4.3, to: dir.appendingPathComponent("r.caf")) { t in
            Float(0.3 * sin(2 * .pi * 330 * t) * (t < 3 ? 1 : 0))
        }
        let analysed = try AudioTrack.analyse(source, audio: pcm)

        let stored = try JSONEncoder().encode(analysed.analysis)
        let analysis = try JSONDecoder().decode(TrackAnalysis.self, from: stored)
        XCTAssertEqual(analysis, analysed.analysis)

        let restored = AudioTrack(url: source, analysis: analysis)
        XCTAssertFalse(restored.isDecoded)
        XCTAssertNil(restored.audio)
        XCTAssertEqual(restored.detailPeaks, analysed.detailPeaks)
        XCTAssertEqual(restored.peaks, analysed.peaks)
        XCTAssertEqual(restored.seconds, analysed.seconds)
        XCTAssertEqual(restored.frames, analysed.frames)
        XCTAssertEqual(restored.markers, analysed.markers)
        XCTAssertEqual(restored.absolutePeak, analysed.absolutePeak)
        XCTAssertEqual(restored.peaks(in: 1..<2, columns: 50), analysed.peaks(in: 1..<2, columns: 50))

        let attached = try restored.attaching(pcm)
        XCTAssertTrue(attached.isDecoded)
        XCTAssertTrue(attached.pcm === pcm)
        XCTAssertEqual(attached.peaks, analysed.peaks)
    }

    func testStoredPeaksAreBitExact() throws {
        let odd: [Float] = [0, 1, 0.1, 1e-30, .leastNonzeroMagnitude, 0.3333333, 0.99999994]
        let analysis = TrackAnalysis(seconds: 0.035, detailPeaks: odd,
                                     markers: MusicMarkers(detectedMusicEnd: 0.03, detectedFadeStart: 0.02),
                                     absolutePeak: 0.7)
        let decoded = try JSONDecoder().decode(TrackAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(decoded.detailPeaks.map(\.bitPattern), odd.map(\.bitPattern))
        XCTAssertEqual(decoded, analysis)
    }

    func testCorruptStoredPeaksAreRejected() {
        let json = #"{"seconds": 3, "detailPeaks": "AAA=", "markers": {}, "absolutePeak": 1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TrackAnalysis.self, from: Data(json.utf8)))
        let zero = #"{"seconds": 0, "detailPeaks": "AACAPw==", "absolutePeak": 1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TrackAnalysis.self, from: Data(zero.utf8)))
    }

    func testLegacyInitializerDefaults() {
        let track = AudioTrack(url: URL(fileURLWithPath: "/tmp/x.wav"), pcm: nil, seconds: 1,
                               detailPeaks: [0.5], peaks: [0.5])
        XCTAssertEqual(track.markers, .none)
        XCTAssertEqual(track.absolutePeak, 0)
        XCTAssertFalse(track.isDecoded)
    }

    func testAttachingAudioOfADifferentLengthThrows() throws {
        let dir = try TestAudio.temporaryDirectory("changed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("c.wav")
        let original = try TestAudio.writeCAF(seconds: 4, to: dir.appendingPathComponent("a.caf")) { _ in 0.2 }
        let analysis = try AudioTrack.analyse(source, audio: original).analysis
        let longer = try TestAudio.writeCAF(seconds: 5, to: dir.appendingPathComponent("b.caf")) { _ in 0.2 }
        let nearly = try TestAudio.writeCAF(seconds: 4.02, to: dir.appendingPathComponent("c.caf")) { _ in 0.2 }

        XCTAssertThrowsError(try AudioTrack(url: source, analysis: analysis, audio: longer)) {
            XCTAssertTrue(($0 as? CueError)?.message.contains("remove") == true
                          || ($0 as? CueError)?.message.contains("Remove") == true)
        }
        XCTAssertThrowsError(try AudioTrack(url: source, analysis: analysis).attaching(longer))
        XCTAssertNoThrow(try AudioTrack(url: source, analysis: analysis, audio: nearly))
        XCTAssertNoThrow(try AudioTrack(url: source, analysis: analysis, audio: original))
    }

    func testRemoveStaleSessionDirectoriesKeepsEverythingElse() throws {
        let base = try TestAudio.temporaryDirectory("stale")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        func directory(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let stale = try directory("WaveformCue-" + UUID().uuidString)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        let current = try directory("WaveformCue-" + UUID().uuidString)
        let live = try directory("WaveformCue-" + UUID().uuidString)
        try JobWorkspace.claimSessionDirectory(live, pid: getppid())
        let samePrefix = try directory("WaveformCue-recordings")
        let other = try directory("OtherApp-AAAA")
        let nearMiss = try directory("WaveformCue")
        let file = base.appendingPathComponent("WaveformCue-file")
        fm.createFile(atPath: file.path, contents: Data())

        PreparedAudio.removeStaleSessionDirectories(in: base, keeping: current)

        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        for kept in [current, live, samePrefix, other, nearMiss, file] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
    }
}

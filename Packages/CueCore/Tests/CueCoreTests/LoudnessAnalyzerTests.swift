import XCTest
@testable import CueCore

final class LoudnessAnalyzerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestAudio.temporaryDirectory("loudness")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// EBU Tech 3341 reference: a 1 kHz stereo sine at −23 dBFS per channel reads −23.0 LUFS.
    func testReferenceToneMeasuresMinus23LUFS() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let wav = directory.appendingPathComponent("reference.wav")
        let amplitude = pow(10, -23.0 / 20)
        try TestAudio.generate("\(amplitude)*sin(2*PI*1000*t)", seconds: 20, to: wav, ffmpeg: ffmpeg)

        let m = try await LoudnessAnalyzer.measure(wav, encoder: ffmpeg)
        let lufs = try XCTUnwrap(m.integratedLUFS)
        XCTAssertEqual(lufs, -23, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(m.truePeakDBTP), -23, accuracy: 0.5)
        XCTAssertEqual(m.rangeLU, 0, accuracy: 0.5)
        XCTAssertFalse(Loudness.isFlagged(m))
    }

    /// Also on a decoded CAF, the file the app actually measures.
    func testMeasuresDecodedCAF() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let wav = directory.appendingPathComponent("quiet.wav")
        let amplitude = pow(10, -33.0 / 20)
        try TestAudio.generate("\(amplitude)*sin(2*PI*1000*t)", seconds: 10, to: wav, ffmpeg: ffmpeg)
        let pcm = try PreparedAudio.decode(wav, encoder: ffmpeg, into: directory.appendingPathComponent("cafs"))
        let m = try await LoudnessAnalyzer.measure(pcm.url, encoder: ffmpeg)
        XCTAssertEqual(try XCTUnwrap(m.integratedLUFS), -33, accuracy: 0.5)
        XCTAssertTrue(Loudness.isFlagged(m))
    }

    func testSilenceMeasuresAsSilent() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let wav = directory.appendingPathComponent("silence.wav")
        try TestAudio.generate("0", seconds: 3, to: wav, ffmpeg: ffmpeg)
        let m = try await LoudnessAnalyzer.measure(wav, encoder: ffmpeg)
        XCTAssertTrue(m.isSilent)
    }

    func testUnreadableInputThrows() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let bogus = directory.appendingPathComponent("bogus.wav")
        try Data("not audio".utf8).write(to: bogus)
        do {
            _ = try await LoudnessAnalyzer.measure(bogus, encoder: ffmpeg)
            XCTFail("garbage input should throw")
        } catch is CancellationError {
            XCTFail("not a cancellation")
        } catch {}
    }

    /// Without FFmpeg: a tool that never finishes is terminated when the task is cancelled.
    func testCancellationTerminatesTheProcess() async throws {
        let tool = try TestAudio.slowTool(in: directory)
        let task = Task { try await LoudnessAnalyzer.measure(directory.appendingPathComponent("x.caf"), encoder: tool) }
        let started = try await TestAudio.slowToolPID(in: directory)
        let pid = try XCTUnwrap(started, "the tool started")
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let gone = try await TestAudio.waitForExit(pid)
        XCTAssertTrue(gone, "cancelling terminates the process")
    }

    /// With real FFmpeg blocked on a FIFO that never gets a writer: cancel ends it.
    func testCancellationTerminatesFFmpeg() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let fifo = directory.appendingPathComponent("blocked-\(UUID().uuidString).wav")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let task = Task { try await LoudnessAnalyzer.measure(fifo, encoder: ffmpeg) }
        let started = try await Self.pid(matching: fifo.path)
        let pid = try XCTUnwrap(started, "FFmpeg started")
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let gone = try await TestAudio.waitForExit(pid)
        if !gone { kill(pid, SIGKILL) }
        XCTAssertTrue(gone, "cancelling terminates FFmpeg")
    }

    func testMissingEncoderThrows() async {
        do {
            _ = try await LoudnessAnalyzer.measure(URL(fileURLWithPath: "/tmp/x.caf"),
                                                   encoder: URL(fileURLWithPath: "/nonexistent/ffmpeg"))
            XCTFail("a missing encoder should throw")
        } catch {}
    }

    /// The PID of the process whose command line contains `text`, via `pgrep -f`.
    static func pid(matching text: String, timeout: TimeInterval = 10) async throws -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-f", text]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let first = output.split(whereSeparator: \.isNewline).first, let pid = pid_t(first) { return pid }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

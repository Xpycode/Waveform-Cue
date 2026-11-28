import XCTest
@testable import CueCore

final class JobWorkspaceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestAudio.temporaryDirectory("workspace")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var cafs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("cafs").path)) ?? [])
            .filter { $0.hasSuffix(".caf") }
    }

    private func makeWorkspace(_ ffmpeg: URL) -> JobWorkspace {
        JobWorkspace(directory: directory.appendingPathComponent("cafs"), encoder: ffmpeg)
    }

    private func source(seconds: Double = 1, name: String = "s.wav", ffmpeg: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try TestAudio.generate("0.3*sin(2*PI*440*t)", seconds: seconds, to: url, ffmpeg: ffmpeg)
        return url
    }

    func testAcquireCreatesCAFAndReleaseDeletesIt() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let workspace = makeWorkspace(ffmpeg)
        let wav = try source(ffmpeg: ffmpeg)
        let job = UUID()

        let audio = try await workspace.acquire(for: job, source: wav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        XCTAssertEqual(cafs.count, 1)
        let live = await workspace.liveCount
        let ready = await workspace.isReady(job)
        XCTAssertEqual(live, 1)
        XCTAssertTrue(ready)

        // A second acquire reuses the same CAF.
        let again = try await workspace.acquire(for: job, source: wav)
        XCTAssertTrue(again === audio)
        XCTAssertEqual(cafs.count, 1)

        // The decoded CAF is analysable and matches the source length.
        let track = try AudioTrack.analyse(wav, audio: audio)
        XCTAssertEqual(track.seconds, 1, accuracy: 0.001)

        await workspace.release(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path), "release deletes the CAF")
        XCTAssertEqual(cafs.count, 0)
        let after = await workspace.liveCount
        XCTAssertEqual(after, 0)
    }

    func testConcurrentAcquiresShareOneDecode() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let workspace = makeWorkspace(ffmpeg)
        let wav = try source(seconds: 5, ffmpeg: ffmpeg)
        let job = UUID()
        async let a = workspace.acquire(for: job, source: wav)
        async let b = workspace.acquire(for: job, source: wav)
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second)
        XCTAssertEqual(cafs.count, 1)
        let peak = await workspace.peakLiveCount
        XCTAssertEqual(peak, 1)
        await workspace.releaseAll()
        XCTAssertEqual(cafs.count, 0)
    }

    /// The queue's pattern: selected plus running job, many jobs in turn, never more than two CAFs.
    func testCountersTrackLiveCAFs() async throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let workspace = makeWorkspace(ffmpeg)
        let wav = try source(seconds: 0.5, ffmpeg: ffmpeg)
        let jobs = (0..<6).map { _ in UUID() }
        var running: UUID?
        for job in jobs {
            _ = try await workspace.acquire(for: job, source: wav)
            XCTAssertLessThanOrEqual(cafs.count, 2)
            if let running { await workspace.release(running) }
            running = job
        }
        let peak = await workspace.peakLiveCount
        let live = await workspace.liveJobs
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(live, [jobs.last!])
        XCTAssertEqual(cafs.count, 1)
        await workspace.releaseAll()
        XCTAssertEqual(cafs.count, 0)
    }

    func testReleaseDuringDecodeCancelsAndLeavesNoFile() async throws {
        let workspace = makeWorkspace(try TestAudio.slowTool(in: directory))
        let wav = directory.appendingPathComponent("long.wav")
        let job = UUID()
        let acquiring = Task { try await workspace.acquire(for: job, source: wav) }
        // The stand-in decoder writes its output and then never finishes.
        let deadline = Date().addingTimeInterval(10)
        while cafs.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(cafs.count, 1, "the decode has started writing its CAF")
        let pid = try await TestAudio.slowToolPID(in: directory)
        await workspace.release(job)
        // Release returns only once the decoder has stopped and its partial file is gone, so the
        // next decode can never coexist with it (task 6.1 cap on disk).
        XCTAssertEqual(cafs, [], "release waits for the partial CAF to be deleted")
        if let pid { XCTAssertTrue(kill(pid, 0) != 0 && errno == ESRCH, "release waits for the decoder to exit") }
        do {
            _ = try await acquiring.value
            XCTFail("acquire should throw after release")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let live = await workspace.liveCount
        XCTAssertEqual(live, 0)
        try await waitUntilNoCAFs()
        let gone = try await TestAudio.waitForExit(try XCTUnwrap(pid))
        XCTAssertTrue(gone, "release terminates the decoder")
    }

    func testCancellingTheAcquiringTaskReleasesTheJob() async throws {
        let workspace = makeWorkspace(try TestAudio.slowTool(in: directory))
        let wav = directory.appendingPathComponent("long.wav")
        let job = UUID()
        let acquiring = Task { try await workspace.acquire(for: job, source: wav) }
        let deadline = Date().addingTimeInterval(10)
        while cafs.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(cafs.count, 1, "the decode has started writing its CAF")
        let pid = try await TestAudio.slowToolPID(in: directory)
        acquiring.cancel()
        let result = await acquiring.result
        XCTAssertThrowsError(try result.get())
        try await waitUntilNoCAFs()
        let live = await workspace.liveCount
        XCTAssertEqual(live, 0)
        let gone = try await TestAudio.waitForExit(try XCTUnwrap(pid))
        XCTAssertTrue(gone, "cancelling terminates the decoder")
    }

    /// No FFmpeg needed: a missing encoder fails the acquire and leaves nothing behind.
    func testFailedDecodeLeavesNoSlot() async throws {
        let workspace = JobWorkspace(directory: directory.appendingPathComponent("cafs"),
                                     encoder: URL(fileURLWithPath: "/nonexistent/ffmpeg"))
        let job = UUID()
        do {
            _ = try await workspace.acquire(for: job, source: directory.appendingPathComponent("none.wav"))
            XCTFail("acquire should fail without an encoder")
        } catch {}
        let live = await workspace.liveCount
        let ready = await workspace.isReady(job)
        XCTAssertEqual(live, 0)
        XCTAssertFalse(ready)
        XCTAssertEqual(cafs.count, 0)
        await workspace.release(job)   // releasing an empty job is harmless
    }

    // MARK: Leftovers from earlier launches

    func testStaleSessionFoldersAreRemovedButCurrentAndLiveOwnersKept() throws {
        let fm = FileManager.default
        let root = directory.appendingPathComponent("tmp", isDirectory: true)
        func folder(_ name: String, owner: Int32? = nil) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("x.caf"))
            if let owner { try JobWorkspace.claimSessionDirectory(url, pid: owner) }
            return url
        }
        let current = try folder("WaveformCue-current")
        let crashed = try folder("WaveformCue-crashed")
        let deadOwner = try folder("WaveformCue-dead", owner: 111)
        let liveOwner = try folder("WaveformCue-live", owner: 222)
        let unrelated = try folder("SomethingElse-1")
        let file = root.appendingPathComponent("WaveformCue-file")
        try Data([1]).write(to: file)

        let removed = JobWorkspace.removeStaleSessionDirectories(in: root, keeping: current, isRunning: { $0 == 222 })
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), [crashed.lastPathComponent, deadOwner.lastPathComponent])
        for kept in [current, liveOwner, unrelated, file] { XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent) }
        for gone in [crashed, deadOwner] { XCTAssertFalse(fm.fileExists(atPath: gone.path), gone.lastPathComponent) }
        XCTAssertEqual(JobWorkspace.removeStaleSessionDirectories(in: root.appendingPathComponent("missing"), keeping: current), [])
    }

    /// The real process check: a folder claimed by a running process (here this test's parent,
    /// standing in for a second instance) stays; one claimed by this process but not current is
    /// left over from an earlier launch whose PID was reused, and goes.
    func testSessionFolderOfARunningProcessIsKept() throws {
        let root = directory.appendingPathComponent("tmp2", isDirectory: true)
        let other = root.appendingPathComponent("WaveformCue-other", isDirectory: true)
        let reused = root.appendingPathComponent("WaveformCue-reused", isDirectory: true)
        try JobWorkspace.claimSessionDirectory(other, pid: getppid())
        try JobWorkspace.claimSessionDirectory(reused)
        XCTAssertTrue(JobWorkspace.processIsRunning(getppid()))
        XCTAssertFalse(JobWorkspace.processIsRunning(0))
        let removed = JobWorkspace.removeStaleSessionDirectories(in: root, keeping: root.appendingPathComponent("WaveformCue-current"))
        XCTAssertEqual(removed.map(\.lastPathComponent), [reused.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testStaleExportTempsOlderThanTenMinutesAreRemoved() throws {
        let fm = FileManager.default
        let a = directory.appendingPathComponent("outA", isDirectory: true)
        let b = directory.appendingPathComponent("outB", isDirectory: true)
        for folder in [a, b] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let now = Date()
        func file(_ folder: URL, _ name: String, age: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let oldA = try file(a, ".waveform-cue-\(UUID().uuidString).mxf", age: 3600)
        let fresh = try file(a, ".waveform-cue-\(UUID().uuidString).mxf", age: 60)
        let finished = try file(a, "Cue.mxf", age: 3600)
        let oldB = try file(b, ".waveform-cue-\(UUID().uuidString).mxf", age: 601)
        let removed = JobWorkspace.removeStaleExportTemps(in: [a, b, a, directory.appendingPathComponent("missing")],
                                                          now: now)
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), [oldA.lastPathComponent, oldB.lastPathComponent])
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "an export still writing is left alone")
        XCTAssertTrue(fm.fileExists(atPath: finished.path), "finished files are never touched")
        XCTAssertFalse(fm.fileExists(atPath: oldA.path))
        XCTAssertFalse(fm.fileExists(atPath: oldB.path))
    }

    private func waitUntilNoCAFs() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !cafs.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(cafs, [], "the partial CAF is deleted")
    }
}

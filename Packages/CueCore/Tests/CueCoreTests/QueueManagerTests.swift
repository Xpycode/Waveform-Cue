import CueCore
import XCTest

// MARK: - Fakes

/// An exporter the test drives by hand: each call waits until the test finishes it.
/// With `finishOnCancel` off, a cancelled call keeps running until the test ends it, which
/// proves the queue waits for the producer's end before starting the next job.
final class ControlledExporter: JobExporting, @unchecked Sendable {
    final class Call: @unchecked Sendable {
        let job: CueJob
        let progress: @Sendable (Double) -> Void
        fileprivate var continuation: CheckedContinuation<URL, Error>?
        fileprivate var result: Result<URL, Error>?
        fileprivate(set) var sawCancel = false
        init(job: CueJob, progress: @escaping @Sendable (Double) -> Void) {
            self.job = job
            self.progress = progress
        }
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    private let finishOnCancel: Bool

    init(finishOnCancel: Bool = true) { self.finishOnCancel = finishOnCancel }

    var calls: [Call] { lock.withLock { storedCalls } }
    func sawCancel(_ index: Int) -> Bool { lock.withLock { storedCalls[index].sawCancel } }

    func export(_ job: CueJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let call = Call(job: job, progress: progress)
        lock.withLock { storedCalls.append(call) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<URL, Error>? = lock.withLock {
                    if let result = call.result { return result }
                    call.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            lock.withLock { call.sawCancel = true }
            if finishOnCancel { finish(call, .failure(CancellationError())) }
        }
    }

    func succeed(_ index: Int) {
        let call = calls[index]
        finish(call, .success(call.job.outputURL ?? URL(fileURLWithPath: "/dev/null")))
    }

    func fail(_ index: Int, _ error: Error) { finish(calls[index], .failure(error)) }

    private func finish(_ call: Call, _ result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>?? = lock.withLock {
            guard call.result == nil else { return .none }
            call.result = result
            defer { call.continuation = nil }
            return .some(call.continuation)
        }
        if case .some(let waiting?) = continuation { waiting.resume(with: result) }
    }
}

final class CountingSleep: SleepPreventing {
    private(set) var begins = 0
    private(set) var ends = 0
    func begin(reason: String) { begins += 1 }
    func end() { ends += 1 }
}

/// Paths the fake file system reports as present.
final class FakeFiles {
    var existing: Set<String> = []
    var exists: (URL) -> Bool { { [unowned self] in self.existing.contains($0.standardizedFileURL.path) } }
}

// MARK: - Tests

@MainActor
final class QueueManagerTests: XCTestCase {
    private var directory: URL!
    private var files: FakeFiles!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueManagerTests-\(UUID().uuidString)")
        files = FakeFiles()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(_ exporter: JobExporting, sleep: SleepPreventing = NoSleepPrevention(),
                             coalescer: @escaping () -> ProgressCoalescer = { ProgressCoalescer() }) -> QueueManager {
        QueueManager(storageDirectory: directory, exporter: exporter, sleep: sleep,
                     fileExists: files.exists, progressCoalescer: coalescer)
    }

    /// A job whose source exists in the fake file system.
    private func job(_ name: String, folder: String = "/Volumes/Media", status: JobStatus = .pending) -> CueJob {
        let source = URL(fileURLWithPath: "\(folder)/\(name).wav")
        files.existing.insert(source.path)
        return CueJob(source: source, presetID: "mpeg2-50", status: status)
    }

    /// Waits for a condition the queue reaches asynchronously. Polls; never assumes a timing.
    private func eventually(_ what: String, timeout: TimeInterval = 5,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)", file: file, line: line); return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Lets every ready task run without the state being allowed to advance on its own.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000)
        }
    }

    private func status(_ manager: QueueManager, _ id: UUID) -> JobStatus? { manager.job(id)?.status }

    // MARK: Running

    func testJobsExportOneAtATimeInListOrder() async {
        let exporter = ControlledExporter()
        let sleep = CountingSleep()
        let manager = makeManager(exporter, sleep: sleep)
        let jobs = [job("A"), job("B"), job("C")]
        manager.add(jobs)
        manager.start()
        XCTAssertTrue(manager.isRunning)
        XCTAssertEqual(sleep.begins, 1)

        for (index, job) in jobs.enumerated() {
            await eventually("call \(index)") { exporter.calls.count == index + 1 }
            XCTAssertEqual(exporter.calls[index].job.id, job.id)
            XCTAssertEqual(manager.currentJobID, job.id)
            XCTAssertEqual(status(manager, job.id), .preparing)
            for later in jobs.dropFirst(index + 1) { XCTAssertEqual(status(manager, later.id), .pending) }
            await settle()
            XCTAssertEqual(exporter.calls.count, index + 1, "only one export runs at a time")

            exporter.calls[index].progress(0.5)
            await eventually("progress") { self.status(manager, job.id) == .exporting(progress: 0.5) }
            XCTAssertEqual(manager.overallProgress ?? -1, (Double(index) + 0.5) / 3, accuracy: 1e-9)
            exporter.succeed(index)
            await eventually("done") { if case .done = self.status(manager, job.id) { return true }; return false }
        }
        await manager.waitUntilIdle()
        XCTAssertFalse(manager.isRunning)
        XCTAssertNil(manager.currentJobID)
        XCTAssertNil(manager.overallProgress)
        XCTAssertEqual(sleep.begins, 1)
        XCTAssertEqual(sleep.ends, 1)
        for job in jobs {
            let output = manager.job(job.id)?.outputURL
            XCTAssertEqual(status(manager, job.id), output.map { .done(output: $0) })
            XCTAssertEqual(output?.lastPathComponent, "\(job.sourceName) - Cue.mxf")
        }
    }

    func testLateProgressNeverOverwritesDone() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A")
        manager.add(a)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        exporter.succeed(0)
        await manager.waitUntilIdle()
        exporter.calls[0].progress(0.9)
        await settle()
        if case .done = status(manager, a.id) {} else { XCTFail("Done was overwritten by late progress") }
    }

    func testCancelWaitsForTheProducerBeforeTheNextJob() async {
        let exporter = ControlledExporter(finishOnCancel: false)
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        manager.add([a, b])
        manager.start()
        await eventually("first call") { exporter.calls.count == 1 }

        manager.cancel(a.id)
        await eventually("cancel reaches the exporter") { exporter.sawCancel(0) }
        await settle()
        XCTAssertEqual(exporter.calls.count, 1, "the next job must wait for the cancelled one to end")
        XCTAssertEqual(status(manager, a.id), .preparing)

        exporter.fail(0, CancellationError())
        await eventually("next call") { exporter.calls.count == 2 }
        XCTAssertEqual(status(manager, a.id), .cancelled)
        XCTAssertEqual(exporter.calls[1].job.id, b.id)
        exporter.succeed(1)
        await manager.waitUntilIdle()
        if case .done = status(manager, b.id) {} else { XCTFail("B should be done") }
    }

    func testCancelledEvenIfExporterThrowsSomethingElse() async {
        let exporter = ControlledExporter(finishOnCancel: false)
        let manager = makeManager(exporter)
        let a = job("A")
        manager.add(a)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        manager.cancel(a.id)
        await eventually("cancel seen") { exporter.sawCancel(0) }
        exporter.fail(0, JobExportError.failed(reason: "Broken pipe", log: ""))
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .cancelled)
    }

    func testCancelPendingJobSkipsIt() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B"), c = job("C")
        manager.add([a, b, c])
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        manager.cancel(b.id)
        XCTAssertEqual(status(manager, b.id), .cancelled)
        exporter.succeed(0)
        await eventually("C runs next") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.id, c.id)
        exporter.succeed(1)
        await manager.waitUntilIdle()
    }

    func testStopQueueCancelsCurrentAndLeavesRestPending() async {
        let exporter = ControlledExporter(finishOnCancel: false)
        let sleep = CountingSleep()
        let manager = makeManager(exporter, sleep: sleep)
        let a = job("A"), b = job("B"), c = job("C")
        manager.add([a, b, c])
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }

        manager.stopQueue()
        XCTAssertTrue(manager.isStopping)
        XCTAssertTrue(manager.isRunning, "still running until the current job has wound down")
        await eventually("cancel seen") { exporter.sawCancel(0) }
        exporter.fail(0, CancellationError())
        await manager.waitUntilIdle()

        XCTAssertFalse(manager.isRunning)
        XCTAssertFalse(manager.isStopping)
        XCTAssertEqual(exporter.calls.count, 1)
        XCTAssertEqual(status(manager, a.id), .cancelled)
        XCTAssertEqual(status(manager, b.id), .pending)
        XCTAssertEqual(status(manager, c.id), .pending)
        XCTAssertEqual(sleep.ends, 1)

        // The queue can be started again afterwards.
        manager.start()
        await eventually("restart") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.id, b.id)
        XCTAssertEqual(sleep.begins, 2)
        manager.stopQueue()
        exporter.fail(1, CancellationError())
        await manager.waitUntilIdle()
    }

    func testFailureRecordsReasonAndLogAndQueueContinues() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        manager.add([a, b])
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        exporter.fail(0, JobExportError.failed(reason: "Encoder exited with status 1", log: "x264 [error]: …"))
        await eventually("next") { exporter.calls.count == 2 }
        XCTAssertEqual(status(manager, a.id), .failed(reason: "Encoder exited with status 1", log: "x264 [error]: …"))

        struct Other: LocalizedError { var errorDescription: String? { "Something else" } }
        exporter.fail(1, Other())
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, b.id), .failed(reason: "Something else", log: ""))
    }

    func testMissingSourceAtRunTimeFails() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        files.existing.remove(a.sourcePath)
        manager.add([a, b])
        manager.start()
        await eventually("B runs") { exporter.calls.count == 1 }
        XCTAssertEqual(exporter.calls[0].job.id, b.id)
        XCTAssertEqual(status(manager, a.id), .failed(reason: QueueManager.sourceNotFound, log: ""))
        exporter.succeed(0)
        await manager.waitUntilIdle()
    }

    func testStartQueueFailsJobsThatCannotBeExported() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        var cramped = job("Cramped")
        var appearance = CueAppearance()
        appearance.safeZones = SafeZones(preset: .custom, custom: .init(top: 30, bottom: 30))
        cramped.appearance = appearance
        XCTAssertFalse(cramped.appearance.layout.fits)
        var badTimecode = job("BadTC")
        badTimecode.startTimecode = "10:00:00:25"
        let fine = job("Fine")
        XCTAssertNil(QueueManager.blockingReason(for: fine))
        manager.add([cramped, badTimecode, fine])
        manager.start()
        await eventually("Fine runs") { exporter.calls.count == 1 }
        XCTAssertEqual(exporter.calls[0].job.id, fine.id, "only the exportable job reaches the exporter")
        XCTAssertEqual(status(manager, cramped.id), .failed(reason: QueueManager.tooLittleRoom, log: ""))
        guard case .failed(let reason, _)? = status(manager, badTimecode.id) else {
            return XCTFail("an invalid start timecode fails the job")
        }
        XCTAssertTrue(reason.contains("10:00:00:25"))
        exporter.succeed(0)
        await manager.waitUntilIdle()

        // Fixed and retried, the job exports.
        manager.update(cramped.id) { $0.appearance = CueAppearance() }
        XCTAssertTrue(manager.retry(cramped.id))
        manager.start()
        await eventually("Cramped runs after the fix") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.id, cramped.id)
        exporter.succeed(1)
        await manager.waitUntilIdle()
    }

    func testStartQueueFailsJobWithTrimUnderOneSecond() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        var short = job("Short")
        short.peaks = PeaksSummary(seconds: 10, overview: [0.5])
        short.trim = TrimSettings(inPoint: 4, outPoint: 4.6)
        XCTAssertEqual(QueueManager.blockingReason(for: short), ClipTimeline.trimTooShortMessage)
        // Without a known duration the in and out points alone decide.
        var unknown = job("Unknown")
        unknown.trim = TrimSettings(inPoint: 1, outPoint: 1.5)
        XCTAssertEqual(QueueManager.blockingReason(for: unknown), "Trim range too short")
        // Exactly one second, an in point near the end of a long source, fades and pre-roll pass.
        var oneSecond = job("OneSecond")
        oneSecond.peaks = PeaksSummary(seconds: 10, overview: [0.5])
        oneSecond.trim = TrimSettings(inPoint: 4, outPoint: 5, fadeIn: 2, preRoll: 10)
        XCTAssertNil(QueueManager.blockingReason(for: oneSecond))
        var tail = job("Tail")
        tail.peaks = PeaksSummary(seconds: 10, overview: [0.5])
        tail.trim = TrimSettings(inPoint: 9.5)
        XCTAssertEqual(QueueManager.blockingReason(for: tail), ClipTimeline.trimTooShortMessage)
        // An untrimmed source shorter than a second still exports, as in build 10.
        var tiny = job("Tiny")
        tiny.peaks = PeaksSummary(seconds: 0.4, overview: [0.5])
        tiny.trim = TrimSettings(preRoll: 2)
        XCTAssertNil(QueueManager.blockingReason(for: tiny))

        manager.add([short, oneSecond])
        manager.start()
        await eventually("OneSecond runs") { exporter.calls.count == 1 }
        XCTAssertEqual(exporter.calls[0].job.id, oneSecond.id)
        XCTAssertEqual(status(manager, short.id), .failed(reason: ClipTimeline.trimTooShortMessage, log: ""))
        exporter.succeed(0)
        await manager.waitUntilIdle()
    }

    func testExportSelectedRunsOnlyThoseJobs() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B"), c = job("C")
        manager.add([a, b, c])
        manager.start(only: [b.id])
        await eventually("call") { exporter.calls.count == 1 }
        XCTAssertEqual(exporter.calls[0].job.id, b.id)
        exporter.succeed(0)
        await manager.waitUntilIdle()
        XCTAssertEqual(exporter.calls.count, 1)
        XCTAssertEqual(status(manager, a.id), .pending)
        XCTAssertEqual(status(manager, c.id), .pending)
    }

    func testJobsAddedDuringARunAreExported() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        manager.add(a)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        manager.add(b)
        exporter.succeed(0)
        await eventually("B") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.id, b.id)
        exporter.succeed(1)
        await manager.waitUntilIdle()
    }

    func testStartWithNothingPendingDoesNothing() {
        let sleep = CountingSleep()
        let manager = makeManager(ControlledExporter(), sleep: sleep)
        manager.add(job("A", status: .cancelled))
        manager.start()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(sleep.begins, 0)
    }

    // MARK: Retry and naming

    func testRetryReusesTheNameAFailedAttemptLeftFree() async throws {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A")
        manager.add(a)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        let first = try XCTUnwrap(exporter.calls[0].job.outputURL)
        XCTAssertEqual(first.path, "/Volumes/Media/A - Cue.mxf")
        exporter.fail(0, JobExportError.failed(reason: "boom", log: ""))
        await manager.waitUntilIdle()

        files.existing.insert("/Volumes/Media/A - Cue 2.mxf")   // someone else's file
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(status(manager, a.id), .pending)
        XCTAssertEqual(manager.job(a.id)?.outputPath, "/Volumes/Media/A - Cue.mxf", "the failed attempt left nothing")

        manager.start()
        await eventually("retry call") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.outputPath, "/Volumes/Media/A - Cue.mxf")
        exporter.succeed(1)
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .done(output: URL(fileURLWithPath: "/Volumes/Media/A - Cue.mxf")))
        XCTAssertFalse(manager.retry(a.id), "Done jobs are not retried")
    }

    func testRetryOfCancelledJob() {
        let manager = makeManager(ControlledExporter())
        let a = job("A", status: .cancelled)
        manager.add(a)
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(status(manager, a.id), .pending)
        XCTAssertEqual(manager.job(a.id)?.outputPath, "/Volumes/Media/A - Cue.mxf")
        XCTAssertFalse(manager.retry(a.id), "Pending jobs are not retried")
    }

    /// Real files in a temporary folder: Retry keeps the name only while nothing is there.
    func testRetryNamingAgainstFilesOnDisk() async throws {
        let folder = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = QueueManager(storageDirectory: directory, exporter: ControlledExporter())
        let source = folder.appendingPathComponent("Song.wav")
        try Data().write(to: source)
        let a = CueJob(source: source, presetID: "mpeg2-50")
        manager.add(a)

        // Cancelled during export: the attempt wrote nothing, so Retry reuses its name.
        manager.start()
        await eventually("exporting") { manager.job(a.id)?.status.isActive == true }
        let name = try XCTUnwrap(manager.job(a.id)?.outputPath)
        XCTAssertEqual(name, folder.appendingPathComponent("Song - Cue.mxf").path)
        manager.cancel(a.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .cancelled)
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(manager.job(a.id)?.outputPath, name)

        // A file has since appeared at that name: Retry picks the next free one.
        manager.cancel(a.id)
        try Data("x".utf8).write(to: URL(fileURLWithPath: name))
        try Data("x".utf8).write(to: folder.appendingPathComponent("Song - Cue 2.mxf"))
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(manager.job(a.id)?.outputPath, folder.appendingPathComponent("Song - Cue 3.mxf").path)
        XCTAssertEqual(try String(contentsOfFile: name, encoding: .utf8), "x")
    }

    func testRetryAvoidsANameAnotherJobClaims() {
        let manager = makeManager(ControlledExporter())
        let claimed = URL(fileURLWithPath: "/Volumes/Media/A - Cue.mxf")
        var other = job("A", status: .done(output: claimed))
        other.outputPath = claimed.path
        var a = CueJob(source: other.sourceURL, presetID: "mpeg2-50", status: .cancelled)
        a.outputPath = claimed.path
        manager.add([other, a])
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(manager.job(a.id)?.outputPath, "/Volumes/Media/A - Cue 2.mxf")
    }

    func testRetryChoosesAgainWhenTheNamingChanged() {
        let manager = makeManager(ControlledExporter())
        var a = job("A", status: .failed(reason: "x", log: ""))
        a.outputPath = "/Volumes/Media/A - Cue.mxf"
        manager.add(a)
        manager.update(a.id) { $0.filenameTemplate = "{name} v2" }
        XCTAssertTrue(manager.retry(a.id))
        XCTAssertEqual(manager.job(a.id)?.outputPath, "/Volumes/Media/A v2.mxf")
    }

    // MARK: Re-export of Done jobs

    func testReexportOfDoneJobGetsAFreshNameAndNeverOverwrites() async throws {
        let folder = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exporter = ControlledExporter()
        let manager = QueueManager(storageDirectory: directory, exporter: exporter)
        let source = folder.appendingPathComponent("Song.wav")
        try Data().write(to: source)
        let a = CueJob(source: source, presetID: "mpeg2-50")
        manager.add(a)
        XCTAssertFalse(manager.reexport(a.id), "only Done jobs are re-exported")

        manager.start()
        await eventually("first call") { exporter.calls.count == 1 }
        let first = try XCTUnwrap(exporter.calls[0].job.outputURL)
        XCTAssertEqual(first.lastPathComponent, "Song - Cue.mxf")
        try Data("first".utf8).write(to: first)   // the file the exporter wrote
        exporter.succeed(0)
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .done(output: first))

        XCTAssertTrue(manager.reexport(a.id))
        XCTAssertEqual(status(manager, a.id), .pending)
        let second = folder.appendingPathComponent("Song - Cue 2.mxf")
        XCTAssertEqual(manager.job(a.id)?.outputPath, second.path)
        manager.start(only: [a.id])
        await eventually("second call") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.outputPath, second.path)
        exporter.succeed(1)
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .done(output: second))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first", "the first file is left intact")
    }

    func testReexportAvoidsThePreviousFileEvenWhenItIsGone() {
        let manager = makeManager(ControlledExporter())
        let written = URL(fileURLWithPath: "/Volumes/Media/A - Cue.mxf")
        var a = job("A", status: .done(output: written))
        a.outputPath = written.path
        manager.add(a)
        XCTAssertTrue(manager.reexport(a.id))
        XCTAssertEqual(manager.job(a.id)?.outputPath, "/Volumes/Media/A - Cue 2.mxf")
        XCTAssertFalse(manager.reexport(a.id), "a Pending job is not re-exported")
    }

    func testTwoJobsFromSameSourceGetDistinctNames() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A")
        let a2 = CueJob(source: a.sourceURL, presetID: "mpeg2-50")
        manager.add([a, a2])
        manager.start()
        await eventually("first") { exporter.calls.count == 1 }
        files.existing.insert(exporter.calls[0].job.outputPath!)   // the file the exporter wrote
        exporter.succeed(0)
        await eventually("second") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.outputPath, "/Volumes/Media/A - Cue 2.mxf")
        exporter.succeed(1)
        await manager.waitUntilIdle()
    }

    func testDefaultOutputNameExpandsTokensAndStripsSeparators() {
        var job = CueJob(source: URL(fileURLWithPath: "/a/Song.wav"), presetID: "avci", filenameTemplate: "{name}/{preset}:x")
        let url = QueueManager.defaultOutputName(for: job, in: URL(fileURLWithPath: "/out"), isTaken: { _ in false })
        XCTAssertEqual(url.path, "/out/Song-avci-x.mxf")
        job.filenameTemplate = "  "
        XCTAssertEqual(QueueManager.defaultOutputName(for: job, in: URL(fileURLWithPath: "/out"), isTaken: { _ in false }).path,
                       "/out/Song.mxf")
    }

    func testDestinationOverrideWins() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A")
        manager.add(a)
        manager.setDestinationOverride(URL(fileURLWithPath: "/Volumes/Out"))
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        XCTAssertEqual(exporter.calls[0].job.outputPath, "/Volumes/Out/A - Cue.mxf")
        exporter.succeed(0)
        await manager.waitUntilIdle()
    }

    // MARK: Editing

    func testApplyToAllCopiesAppearanceAndPresetToPendingJobsOnly() {
        let manager = makeManager(ControlledExporter())
        let source = job("Source")
        let pending = job("Pending")
        let done = job("Done", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/Done - Cue.mxf")))
        let failed = job("Failed", status: .failed(reason: "x", log: ""))
        let cancelled = job("Cancelled", status: .cancelled)
        manager.add([source, pending, done, failed, cancelled])

        var look = CueAppearance()
        look.warning = .ten
        look.remaining.size = .extraLarge
        manager.update(source.id) {
            $0.appearance = look
            $0.presetID = "avci100-1080i50"
            $0.labelText = "Only on the source"
            $0.trim.preRoll = 5
        }

        XCTAssertEqual(manager.applyToAll(from: source.id), 1)
        let updated = manager.job(pending.id)!
        XCTAssertEqual(updated.appearanceSnapshot, AppearanceSnapshot(look))
        XCTAssertEqual(updated.presetID, "avci100-1080i50")
        XCTAssertEqual(updated.labelText, "Pending", "the label is not copied")
        XCTAssertEqual(updated.trim, .none, "trim is not copied")
        for untouched in [done, failed, cancelled] {
            XCTAssertEqual(manager.job(untouched.id), untouched)
        }
    }

    func testRunningJobIsLockedOthersStayEditable() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        manager.add([a, b])
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }

        XCTAssertTrue(manager.isLocked(a.id))
        XCTAssertFalse(manager.update(a.id) { $0.labelText = "changed" })
        XCTAssertEqual(manager.job(a.id)?.labelText, "A")
        XCTAssertFalse(manager.remove(a.id), "the running job cannot be removed")

        XCTAssertFalse(manager.isLocked(b.id))
        XCTAssertTrue(manager.update(b.id) { $0.labelText = "B edited"; $0.status = .done(output: URL(fileURLWithPath: "/x")) })
        XCTAssertEqual(manager.job(b.id)?.labelText, "B edited")
        XCTAssertEqual(status(manager, b.id), .pending, "status cannot be edited")
        XCTAssertEqual(manager.job(a.id)?.labelText, "A", "editing B changed only B")

        exporter.succeed(0)
        await eventually("B") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.labelText, "B edited")
        exporter.succeed(1)
        await manager.waitUntilIdle()
    }

    func testSelectRemoveAndMove() {
        let manager = makeManager(ControlledExporter())
        let a = job("A"), b = job("B"), c = job("C")
        manager.add([a, b, c])
        manager.select(b.id)
        XCTAssertEqual(manager.selectedJob?.id, b.id)
        manager.select(UUID())
        XCTAssertNil(manager.selectedJobID, "selecting an unknown job clears the selection")

        manager.select(b.id)
        XCTAssertTrue(manager.remove(b.id))
        XCTAssertNil(manager.selectedJobID)
        XCTAssertEqual(manager.jobs.map(\.id), [a.id, c.id])

        manager.move(fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(manager.jobs.map(\.id), [c.id, a.id])
        manager.add(a)   // duplicate IDs are ignored
        XCTAssertEqual(manager.jobs.count, 2)
    }

    func testAddResetsActiveStatusAndKeepsFailed() {
        let manager = makeManager(ControlledExporter())
        let running = job("Running", status: .exporting(progress: 0.3))
        let failed = job("Broken", status: .failed(reason: "The audio decoder returned no samples.", log: ""))
        manager.add([running, failed])
        XCTAssertEqual(status(manager, running.id), .pending)
        XCTAssertEqual(status(manager, failed.id), failed.status)
    }

    // MARK: Persistence

    func testSaveThenReload() {
        let manager = makeManager(ControlledExporter())
        var a = job("A")
        a.markers = MusicMarkers(detectedMusicEnd: 12)
        a.peaks = PeaksSummary(seconds: 14, overview: [0.1, 0.9])
        let b = job("B", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/B - Cue.mxf")))
        manager.add([a, b])
        manager.update(a.id) { $0.startTimecode = "10:00:00:00" }
        manager.setDestinationOverride(URL(fileURLWithPath: "/Volumes/Out"))

        let reloaded = makeManager(ControlledExporter())
        XCTAssertEqual(reloaded.jobs, manager.jobs)
        XCTAssertEqual(reloaded.job(a.id)?.peaks, a.peaks)
        XCTAssertEqual(reloaded.job(a.id)?.startTimecode, "10:00:00:00")
        XCTAssertEqual(reloaded.destinationOverride?.path, "/Volumes/Out")
        XCTAssertNil(reloaded.persistenceProblem)
    }

    func testEveryChangeIsSaved() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A")
        manager.add(a)
        XCTAssertEqual(makeManager(ControlledExporter()).jobs.count, 1)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        exporter.succeed(0)
        await manager.waitUntilIdle()
        if case .done = makeManager(ControlledExporter()).job(a.id)?.status {} else { XCTFail("Done was not saved") }
        manager.remove(a.id)
        XCTAssertEqual(makeManager(ControlledExporter()).jobs.count, 0)
    }

    func testRestoreRules() throws {
        let interrupted = job("Interrupted")
        let paused = job("Paused", status: .paused)
        let done = job("Done", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/Done - Cue.mxf")))
        let missing = job("Missing")
        let doneMissing = job("DoneMissing", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/DM.mxf")))
        files.existing.remove(missing.sourcePath)
        files.existing.remove(doneMissing.sourcePath)

        // Write the file an app killed mid-export would leave: Interrupted saved as Preparing.
        var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            QueueDocument(jobs: [interrupted, paused, done, missing, doneMissing]))) as! [String: Any]
        var jobs = document["jobs"] as! [[String: Any]]
        jobs[0]["status"] = ["state": "preparing"]
        document["jobs"] = jobs
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent(QueueStore.fileName))

        let manager = makeManager(ControlledExporter())
        XCTAssertEqual(manager.jobs.map(\.id), [interrupted, paused, done, missing, doneMissing].map(\.id))
        XCTAssertEqual(status(manager, interrupted.id), .pending)
        XCTAssertEqual(status(manager, paused.id), .pending)
        XCTAssertEqual(status(manager, done.id), done.status)
        XCTAssertEqual(status(manager, missing.id), .failed(reason: "Source not found", log: ""))
        XCTAssertEqual(status(manager, doneMissing.id), doneMissing.status, "a Done job keeps its result")
        XCTAssertNil(manager.persistenceProblem)

        // The restored state is written back.
        let again = makeManager(ControlledExporter())
        XCTAssertEqual(again.jobs, manager.jobs)
    }

    func testCorruptQueueFileIsRecoveredOnLaunch() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(QueueStore.fileName)
        try Data("not json at all".utf8).write(to: file)

        let manager = makeManager(ControlledExporter())
        XCTAssertEqual(manager.jobs, [])
        XCTAssertNotNil(manager.persistenceProblem)
        let recovery = try XCTUnwrap(manager.recoveryFile)
        XCTAssertEqual(try String(contentsOf: recovery, encoding: .utf8), "not json at all")
        XCTAssertFalse(manager.isWriteBlocked)

        manager.add(job("A"))
        XCTAssertEqual(makeManager(ControlledExporter()).jobs.count, 1)
    }

    func testBlockedWritesKeepTheOriginalFile() throws {
        struct CopyFailed: Error {}
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(QueueStore.fileName)
        try Data("{broken".utf8).write(to: file)

        let store = QueueStore(directory: directory, copyItem: { _, _ in throw CopyFailed() })
        let manager = QueueManager(store: store, exporter: ControlledExporter(), fileExists: files.exists)
        XCTAssertTrue(manager.isWriteBlocked)
        manager.add(job("A"))
        XCTAssertEqual(manager.jobs.count, 1, "the queue still works in memory")
        XCTAssertNotNil(manager.persistenceProblem)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
    }

    // MARK: Pause on an unwritable folder

    func testUnwritableFolderPausesJobsSharingIt() async throws {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A", folder: "/Volumes/X"), b = job("B", folder: "/Volumes/X")
        let c = job("C", folder: "/Volumes/Y"), d = job("D", folder: "/Volumes/X")
        manager.add([a, b, c, d])
        manager.start()
        await eventually("A") { exporter.calls.count == 1 }
        exporter.fail(0, JobExportError.destinationUnwritable(folder: URL(fileURLWithPath: "/Volumes/X"),
                                                               reason: "Permission denied"))
        await eventually("C runs next") { exporter.calls.count == 2 }
        XCTAssertEqual(exporter.calls[1].job.id, c.id)
        XCTAssertEqual(status(manager, a.id), .paused)
        XCTAssertEqual(status(manager, b.id), .paused)
        XCTAssertEqual(status(manager, d.id), .paused)
        XCTAssertEqual(manager.unwritableFolders.map(\.path), ["/Volumes/X"])
        exporter.succeed(1)
        await manager.waitUntilIdle()
        XCTAssertEqual(exporter.calls.count, 2, "paused jobs do not run")

        manager.resumePaused(in: URL(fileURLWithPath: "/Volumes/X"), newFolder: URL(fileURLWithPath: "/Volumes/Z"))
        XCTAssertEqual(manager.unwritableFolders, [])
        for id in [a.id, b.id, d.id] {
            XCTAssertEqual(status(manager, id), .pending)
            XCTAssertEqual(manager.job(id)?.destinationFolder, "/Volumes/Z")
        }
        XCTAssertNil(manager.job(c.id)?.destinationFolder, "other folders are untouched")

        manager.start()
        await eventually("A again") { exporter.calls.count == 3 }
        guard exporter.calls.count == 3 else { return }
        XCTAssertEqual(exporter.calls[2].job.outputPath, "/Volumes/Z/A - Cue.mxf")
        manager.stopQueue()
        await manager.waitUntilIdle()
    }

    func testUnwritableOverrideIsReplacedOnResume() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A"), b = job("B")
        manager.add([a, b])
        manager.setDestinationOverride(URL(fileURLWithPath: "/Volumes/Out"))
        manager.start()
        await eventually("A") { exporter.calls.count == 1 }
        exporter.fail(0, JobExportError.destinationUnwritable(folder: URL(fileURLWithPath: "/Volumes/Out"), reason: "Read-only"))
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, b.id), .paused)

        manager.resumePaused(in: URL(fileURLWithPath: "/Volumes/Out"), newFolder: URL(fileURLWithPath: "/Volumes/New"))
        XCTAssertEqual(manager.destinationOverride?.path, "/Volumes/New")
        XCTAssertNil(manager.job(a.id)?.destinationFolder)
        XCTAssertEqual(status(manager, a.id), .pending)
        XCTAssertEqual(status(manager, b.id), .pending)
    }

    // MARK: Progress coalescing

    func testManagerCoalescesProgress() async {
        let exporter = ControlledExporter()
        // A clock that never moves: only the first tick and 100 % may pass.
        let manager = makeManager(exporter, coalescer: { ProgressCoalescer(interval: 0.1, now: { 0 }) })
        let a = job("A")
        manager.add(a)
        manager.start()
        await eventually("call") { exporter.calls.count == 1 }
        let progress = exporter.calls[0].progress
        progress(0.01)
        await eventually("first tick") { self.status(manager, a.id) == .exporting(progress: 0.01) }
        for step in 2...99 { progress(Double(step) / 100) }
        await settle()
        XCTAssertEqual(status(manager, a.id), .exporting(progress: 0.01), "ticks inside the interval are swallowed")
        progress(1)
        await eventually("100 %") { self.status(manager, a.id) == .exporting(progress: 1) }
        exporter.succeed(0)
        await manager.waitUntilIdle()
    }

    final class Clock: @unchecked Sendable {
        var nanos: UInt64 = 0
    }

    func testCoalescerRateIsAboutTenPerSecond() {
        let clock = Clock()
        let coalescer = ProgressCoalescer(interval: 0.1, now: { clock.nanos })
        var emitted: [Double] = []
        // 1,000 ticks one millisecond apart: one second of a hot callback.
        for tick in 1...1000 {
            clock.nanos = UInt64(tick) * 1_000_000
            if let value = coalescer.offer(Double(tick) / 1000) { emitted.append(value) }
        }
        XCTAssertEqual(emitted.first, 0.001, "the first tick passes")
        XCTAssertEqual(emitted.last, 1, "100 % always passes")
        XCTAssertGreaterThanOrEqual(emitted.count, 10)
        XCTAssertLessThanOrEqual(emitted.count, 12)
    }

    func testCoalescerIgnoresBackwardsAndInvalidValues() {
        let clock = Clock()
        let coalescer = ProgressCoalescer(interval: 0.1, now: { clock.nanos })
        XCTAssertEqual(coalescer.offer(0.5), 0.5)
        clock.nanos = 1_000_000_000
        XCTAssertNil(coalescer.offer(0.4), "progress never goes back")
        XCTAssertNil(coalescer.offer(.nan))
        XCTAssertEqual(coalescer.offer(7), 1, "clamped to 100 %")
        XCTAssertNil(coalescer.offer(1), "100 % is published once")
    }

    func testCoalescerBackwardsClockDoesNotTrap() {
        let clock = Clock()
        clock.nanos = 5_000_000_000
        let coalescer = ProgressCoalescer(interval: 0.1, now: { clock.nanos })
        XCTAssertNotNil(coalescer.offer(0.1))
        clock.nanos = 1
        _ = coalescer.offer(0.2)
    }

    // MARK: Task 3.3: stored analysis, deferred saves, paused-folder resume

    private func analysis(seconds: Double = 2) -> TrackAnalysis {
        TrackAnalysis(seconds: seconds, detailPeaks: (0..<400).map { Float($0 % 17) / 16 },
                      markers: MusicMarkers(detectedMusicEnd: 1.5, detectedFadeStart: 1.2), absolutePeak: 0.7)
    }

    func testStoredAnalysisSurvivesRelaunch() throws {
        let manager = makeManager(ControlledExporter())
        var a = job("A")
        a.analysis = analysis()
        let b = job("B", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/B - Cue.mxf")))
        manager.add([a, b])

        let reloaded = makeManager(ControlledExporter())
        XCTAssertEqual(reloaded.job(a.id)?.analysis, a.analysis, "peaks and markers come back bit-identical")
        XCTAssertNil(reloaded.job(b.id)?.analysis)
        // A restored job draws from its analysis without any audio.
        let stored = try XCTUnwrap(reloaded.job(a.id)?.analysis)
        let track = AudioTrack(url: a.sourceURL, analysis: stored)
        XCTAssertFalse(track.isDecoded)
        XCTAssertEqual(track.markers, a.analysis?.markers)
    }

    func testUnreadableStoredAnalysisDropsOnlyTheAnalysis() throws {
        var a = job("A")
        a.analysis = analysis()
        var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(QueueDocument(jobs: [a]))) as! [String: Any]
        var jobs = document["jobs"] as! [[String: Any]]
        var stored = jobs[0]["analysis"] as! [String: Any]
        stored["detailPeaks"] = "AAA="   // two bytes: not whole Float32s
        jobs[0]["analysis"] = stored
        document["jobs"] = jobs
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent(QueueStore.fileName))

        let manager = makeManager(ControlledExporter())
        XCTAssertEqual(manager.jobs.map(\.id), [a.id])
        XCTAssertNil(manager.job(a.id)?.analysis)
        XCTAssertEqual(status(manager, a.id), .pending)
    }

    /// Quit with pending and done jobs and relaunch: the queue is restored, a missing source
    /// reads "Source not found", and the queue-wide destination is kept.
    func testRelaunchWithPendingAndDoneJobs() {
        let first = makeManager(ControlledExporter())
        let pending = job("Pending"), gone = job("Gone")
        let done = job("Done", status: .done(output: URL(fileURLWithPath: "/Volumes/Media/Done - Cue.mxf")))
        first.add([pending, done, gone])
        first.setDestinationOverride(URL(fileURLWithPath: "/Volumes/Out"))
        files.existing.remove(gone.sourcePath)

        let second = makeManager(ControlledExporter())
        XCTAssertEqual(second.jobs.map(\.id), [pending.id, done.id, gone.id])
        XCTAssertEqual(status(second, pending.id), .pending)
        XCTAssertEqual(status(second, done.id), done.status)
        XCTAssertEqual(status(second, gone.id), .failed(reason: QueueManager.sourceNotFound, log: ""))
        XCTAssertEqual(second.destinationOverride?.path, "/Volumes/Out")
    }

    func testDeferredSaveWaitsAndFlushes() async {
        let manager = makeManager(ControlledExporter())
        manager.deferredSaveDelay = 60
        let a = job("A")
        manager.add(a)
        manager.update(a.id, deferringSave: true) { $0.labelText = "Typed" }
        XCTAssertEqual(manager.job(a.id)?.labelText, "Typed")
        XCTAssertTrue(manager.hasPendingSave)
        XCTAssertEqual(makeManager(ControlledExporter()).job(a.id)?.labelText, "A", "not written yet")

        manager.flushPendingSave()
        XCTAssertFalse(manager.hasPendingSave)
        XCTAssertEqual(makeManager(ControlledExporter()).job(a.id)?.labelText, "Typed")

        // An ordinary save writes a waiting deferred edit too.
        manager.update(a.id, deferringSave: true) { $0.labelText = "Typed more" }
        manager.update(a.id) { $0.startTimecode = "10:00:00:00" }
        XCTAssertFalse(manager.hasPendingSave)
        XCTAssertEqual(makeManager(ControlledExporter()).job(a.id)?.labelText, "Typed more")

        // And the delay alone writes it.
        manager.deferredSaveDelay = 0.01
        manager.update(a.id, deferringSave: true) { $0.labelText = "Later" }
        await eventually("deferred save") { !manager.hasPendingSave }
        XCTAssertEqual(makeManager(ControlledExporter()).job(a.id)?.labelText, "Later")
    }

    /// A Paused job is still owed to the run: it does not count as finished, so resuming it never
    /// moves the bar back, and a job paused in an earlier run is counted once it is resumed.
    func testPausedJobsCountAsOwedAndResumedJobsJoinTheRunProgress() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A", folder: "/Volumes/X"), b = job("B", folder: "/Volumes/Y"), c = job("C", folder: "/Volumes/X")
        manager.add([a, b, c])
        manager.start()
        await eventually("A") { exporter.calls.count == 1 }
        exporter.fail(0, JobExportError.destinationUnwritable(folder: URL(fileURLWithPath: "/Volumes/X"), reason: "Ejected"))
        await eventually("B") { exporter.calls.count == 2 }
        XCTAssertEqual(status(manager, c.id), .paused)
        exporter.calls[1].progress(0.5)
        await eventually("progress") { self.status(manager, b.id) == .exporting(progress: 0.5) }
        XCTAssertEqual(manager.overallProgress ?? -1, 0.5 / 3, accuracy: 1e-9, "paused jobs are not finished")
        exporter.succeed(1)
        await eventually("B done") { if case .done = self.status(manager, b.id) { return true }; return false }
        await manager.waitUntilIdle()
        XCTAssertEqual(status(manager, a.id), .paused)

        // A new run; the folder comes back while it exports D.
        let d = job("D", folder: "/Volumes/Y")
        manager.add(d)
        manager.start()
        await eventually("D") { exporter.calls.count == 3 }
        exporter.calls[2].progress(0.5)
        await eventually("D progress") { self.status(manager, d.id) == .exporting(progress: 0.5) }
        XCTAssertEqual(manager.overallProgress ?? -1, 0.5, accuracy: 1e-9)
        let resumed = manager.resumePaused(in: URL(fileURLWithPath: "/Volumes/X"))
        XCTAssertEqual(resumed, [a.id, c.id])
        XCTAssertEqual(manager.overallProgress ?? -1, 0.5 / 3, accuracy: 1e-9, "resumed jobs join the run's progress")
        var last = manager.overallProgress ?? 0
        exporter.succeed(2)
        for index in 3..<5 {
            await eventually("call \(index)") { exporter.calls.count == index + 1 }
            let now = manager.overallProgress ?? 0
            XCTAssertGreaterThanOrEqual(now, last, "progress never goes back")
            XCTAssertLessThan(now, 1, "a resumed job is still to be exported")
            last = now
            exporter.succeed(index)
        }
        await manager.waitUntilIdle()
        XCTAssertEqual(exporter.calls.map(\.job.id), [a.id, b.id, d.id, a.id, c.id])
    }

    func testPausedJobsAreListedAndResumeReportsThem() async {
        let exporter = ControlledExporter()
        let manager = makeManager(exporter)
        let a = job("A", folder: "/Volumes/X"), b = job("B", folder: "/Volumes/X"), c = job("C", folder: "/Volumes/Y")
        manager.add([a, b, c])
        manager.start()
        await eventually("A") { exporter.calls.count == 1 }
        exporter.fail(0, JobExportError.destinationUnwritable(folder: URL(fileURLWithPath: "/Volumes/X"), reason: "Ejected"))
        await eventually("C") { exporter.calls.count == 2 }
        exporter.succeed(1)
        await manager.waitUntilIdle()

        let folder = URL(fileURLWithPath: "/Volumes/X")
        XCTAssertEqual(manager.pausedJobs(in: folder), [a.id, b.id])
        XCTAssertEqual(manager.pausedJobs(in: URL(fileURLWithPath: "/Volumes/X/")), [a.id, b.id], "trailing slash matches")
        XCTAssertEqual(manager.pausedJobs(in: URL(fileURLWithPath: "/Volumes/Y")), [])
        let resumed = manager.resumePaused(in: folder, newFolder: URL(fileURLWithPath: "/Volumes/Z"))
        XCTAssertEqual(resumed, [a.id, b.id])
        XCTAssertEqual(manager.pausedJobs(in: folder), [])

        // The caller restarts just those jobs when the queue has already ended.
        manager.start(only: Set(resumed))
        await eventually("A again") { exporter.calls.count == 3 }
        guard exporter.calls.count == 3 else { return }
        XCTAssertEqual(exporter.calls[2].job.id, a.id)
        XCTAssertEqual(exporter.calls[2].job.outputURL?.deletingLastPathComponent().path, "/Volumes/Z")
        manager.stopQueue()
        await manager.waitUntilIdle()
    }

    func testSleepIsPreventedForTheWholeBatch() async {
        let exporter = ControlledExporter()
        let sleep = CountingSleep()
        let manager = makeManager(exporter, sleep: sleep)
        manager.add([job("A"), job("B"), job("C")])
        manager.start()
        for index in 0..<3 {
            await eventually("job \(index)") { exporter.calls.count == index + 1 }
            XCTAssertEqual(sleep.begins, 1)
            XCTAssertEqual(sleep.ends, 0, "held between jobs")
            if exporter.calls.count == index + 1 { exporter.succeed(index) }
        }
        await manager.waitUntilIdle()
        XCTAssertEqual(sleep.begins, 1)
        XCTAssertEqual(sleep.ends, 1)
    }
}

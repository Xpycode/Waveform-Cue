import XCTest
@testable import CueCore

/// Task 6.1: the full-length export timing and the 50-job audio cap driven through the queue.
@MainActor
final class PerformanceTests: XCTestCase {
    // MARK: - 3-minute export

    /// A 3-minute synthetic clip exports to AVC-Intra 100 in less than real time at 1080p25 and
    /// 1080i50. Opt in with `CUE_BENCH=1` (and FFmpeg).
    func testThreeMinuteAVCIntraExportFinishesInRealTime() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CUE_BENCH"] == "1",
                          "Set CUE_BENCH=1 to run the 3-minute export benchmark.")
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("perf-3min")
        defer { try? FileManager.default.removeItem(at: dir) }
        let seconds = 180.0
        let wav = dir.appendingPathComponent("three-minutes.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)*sin(PI*t/7)", right: "0.3*sin(2*PI*220*t)",
                               seconds: seconds, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        XCTAssertEqual(track.seconds, seconds, accuracy: 0.01)

        for preset in [ExportPreset.avcIntra1080p25, .avcIntra1080i50] {
            let timeline = MXFExport.timeline(for: track, preset: preset)
            let output = dir.appendingPathComponent(preset.id.rawValue + ".mxf")
            let began = Date()
            try MXFExport.run(snapshot: MXFExport.Snapshot(track: track, label: CueLabel(text: "Three Minutes"), layout: .four),
                              preset: preset, timeline: timeline, encoder: ffmpeg,
                              destination: output, progress: { _ in })
            let elapsed = Date().timeIntervalSince(began)
            print(String(format: "[6.1 perf] %@: 180 s clip, %d frames, %d images in %.2f s = %.0f images/s, %.1f× real time",
                         preset.id.rawValue, timeline.outputFrames, timeline.positionCount, elapsed,
                         Double(timeline.positionCount) / elapsed, seconds / elapsed))
            XCTAssertLessThan(elapsed, seconds, "\(preset.id.rawValue): a 3-minute export must finish in under 3 minutes")

            // The file exists, is not empty, and holds the full clip.
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 0, preset.id.rawValue)
            XCTAssertEqual(timeline.outputFrames, Int(seconds) * preset.video.encodeRate, preset.id.rawValue)
            XCTAssertEqual(try FFmpegRun.videoPackets(output, ffmpeg: ffmpeg), timeline.outputFrames, preset.id.rawValue)
            if let duration = try Self.formatDuration(output, ffmpeg: ffmpeg) {
                XCTAssertEqual(duration, seconds, accuracy: 0.05, preset.id.rawValue)
            } else {
                print("[6.1 perf] ffprobe not beside FFMPEG_EXECUTABLE; duration checked from the frame count only")
            }
        }
    }

    /// Container duration in seconds from an `ffprobe` beside the FFmpeg under test, else nil.
    private static func formatDuration(_ file: URL, ffmpeg: URL) throws -> Double? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return nil }
        let result = try FFmpegRun.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                                 "-of", "default=noprint_wrappers=1:nokey=1", file.path])
        return Double(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 50 jobs through the queue

    /// An exporter that takes its audio the way `MXFJobExporter` does (the running role of a
    /// `JobAudioLifetime`, given up when the export ends) and writes a placeholder output.
    private struct LifetimeExporter: JobExporting {
        let lifetime: JobAudioLifetime

        func export(_ job: CueJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            guard let destination = job.outputURL else { throw CueError("no output") }
            let lifetime = self.lifetime
            defer { Task { @MainActor in lifetime.exportEnded(job.id) } }
            let audio = try await lifetime.exportAudio(for: job.id, source: job.sourceURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path), "the running job's CAF exists")
            progress(0.5)
            try await Task.sleep(nanoseconds: 2_000_000)
            try Data("mxf".utf8).write(to: destination)
            progress(1)
            return destination
        }
    }

    /// Samples the CAF folder on its own thread, as often as it can, and keeps the peak.
    private final class CAFSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak = 0
        private var samples = 0
        let directory: URL

        init(directory: URL) { self.directory = directory }

        static func count(in directory: URL) -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".caf") }.count
        }

        func start() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let n = Self.count(in: directory)
                    lock.withLock { peak = max(peak, n); samples += 1 }
                }
            }
        }

        func stop() -> (peak: Int, samples: Int) {
            lock.withLock { running = false; return (peak, samples) }
        }
    }

    private struct CapRun {
        var hops = 0
        var workspacePeak = 0
        var diskPeak = 0
        var samples = 0
    }

    /// Runs 50 queued jobs through a real `QueueManager`, `JobAudioLifetime` and `JobWorkspace`
    /// (a stand-in decoder, no FFmpeg) while the operator hops the selection and now and then
    /// adds a file, each asking for audio like the monitor and the ingest pass. With `racing`,
    /// a hop does not wait for the previous selection's decode (so decodes are cancelled in
    /// flight); without it, each selection's audio arrives before the next hop. Checks that
    /// every job exports and nothing is left behind; returns the peaks.
    private func runFiftyJobs(racing: Bool, file: StaticString = #filePath, line: UInt = #line) async throws -> CapRun {
        let dir = try TestAudio.temporaryDirectory("perf-50jobs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cafs = dir.appendingPathComponent("cafs", isDirectory: true)
        let sources = dir.appendingPathComponent("sources", isDirectory: true)
        let outputs = dir.appendingPathComponent("outputs", isDirectory: true)
        for folder in [cafs, sources, outputs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A stand-in decoder: writes the CAF named by its last argument after a short pause.
        let tool = dir.appendingPathComponent("quick-tool.sh")
        try "#!/bin/sh\nfor last; do :; done\nsleep 0.01\ncase \"$last\" in *.caf) printf x > \"$last\";; esac\nexit 0\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let lifetime = JobAudioLifetime(workspace: JobWorkspace(directory: cafs, encoder: tool))
        let manager = QueueManager(storageDirectory: dir.appendingPathComponent("store"),
                                   exporter: LifetimeExporter(lifetime: lifetime))
        manager.setDestinationOverride(outputs)
        let jobs: [CueJob] = try (0..<50).map { index in
            let source = sources.appendingPathComponent("job-\(index).wav")
            try Data().write(to: source)
            return CueJob(source: source, presetID: "avci100-1080i50")
        }
        manager.add(jobs)
        XCTAssertEqual(manager.jobs.count, 50, file: file, line: line)

        let sampler = CAFSampler(directory: cafs)
        sampler.start()
        manager.start()

        var run = CapRun()
        var previews: [Task<Void, Never>] = []
        while manager.isRunning {
            let target = jobs[(run.hops * 7 + 3) % jobs.count]
            manager.select(target.id)
            lifetime.assign(.selected, to: target.id)
            let preview = Task { @MainActor in
                _ = try? await lifetime.audio(for: target.id, source: target.sourceURL, as: .selected)
            }
            if racing { previews.append(preview) } else { await preview.value }
            if run.hops % 5 == 0 {
                let adding = UUID()
                lifetime.assign(.ingest, to: adding)
                _ = try? await lifetime.audio(for: adding, source: sources.appendingPathComponent("adding-\(run.hops).wav"),
                                              as: .ingest)
                lifetime.assign(.ingest, to: nil)
            }
            run.hops += 1
            let live = await lifetime.workspace.liveCount
            XCTAssertLessThanOrEqual(live, 2, file: file, line: line)
            try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...8_000_000))
        }
        await manager.waitUntilIdle()
        for preview in previews { await preview.value }

        let done = manager.jobs.filter { if case .done = $0.status { return true } else { return false } }.count
        XCTAssertEqual(done, 50, "every queued job exported: \(manager.jobs.map(\.status))", file: file, line: line)

        // Only the last selection may still hold audio; deselecting deletes it.
        await lifetime.settle()
        let liveJobs = await lifetime.workspace.liveJobs
        XCTAssertTrue(liveJobs.isSubset(of: Set([lifetime.roles[.selected]].compactMap { $0 })), file: file, line: line)
        lifetime.assign(.selected, to: nil)
        await lifetime.settle()
        let deadline = Date().addingTimeInterval(10)
        while CAFSampler.count(in: cafs) > 0, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let sampled = sampler.stop()
        run.diskPeak = sampled.peak
        run.samples = sampled.samples
        run.workspacePeak = await lifetime.workspace.peakLiveCount
        let left = await lifetime.workspace.liveCount
        XCTAssertEqual(left, 0, file: file, line: line)
        XCTAssertEqual(CAFSampler.count(in: cafs), 0, "no CAFs left behind", file: file, line: line)
        XCTAssertGreaterThan(run.hops, racing ? 50 : 20, "the selection hopped throughout the run", file: file, line: line)
        XCTAssertGreaterThan(run.samples, 100, "the sampler watched the folder", file: file, line: line)
        print("[6.1 cap] 50 jobs, racing \(racing), \(run.hops) selection hops: workspace peak \(run.workspacePeak), "
              + "on-disk peak \(run.diskPeak) over \(run.samples) samples")
        return run
    }

    /// Spec B edge case: with 50 jobs queued and the queue running, the operator moving between
    /// jobs and files being added, never more than two decoded CAFs exist at once, counted on
    /// disk by a sampler thread and by the workspace.
    func testFiftyQueuedJobsNeverHoldMoreThanTwoCAFs() async throws {
        let run = try await runFiftyJobs(racing: false)
        XCTAssertEqual(run.workspacePeak, 2, "running plus selected held audio together, never more")
        XCTAssertLessThanOrEqual(run.diskPeak, 2, "never more than two CAFs on disk at once")
    }

    /// The same with the selection hopping faster than a decode finishes, so decodes are cancelled
    /// in flight. `JobWorkspace.release` keeps a cancelled decode counted until its decoder has
    /// stopped and its partial CAF is deleted, and the lifetime's release chain waits for that
    /// before the next decode starts, so the cap holds on disk too.
    func testFiftyQueuedJobsWithRacingSelectionKeepTheEntitlementCap() async throws {
        let run = try await runFiftyJobs(racing: true)
        XCTAssertEqual(run.workspacePeak, 2, "the workspace never tracks more than two CAFs")
        XCTAssertLessThanOrEqual(run.diskPeak, 2, "never more than two CAFs on disk at once")
    }
}

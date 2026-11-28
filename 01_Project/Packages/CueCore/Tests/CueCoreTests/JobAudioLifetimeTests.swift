import XCTest
@testable import CueCore

/// The audio-lifetime policy: only the selected job, the running job and a file being added hold
/// a decoded CAF, never more than two at once. Decodes use a stand-in tool (no FFmpeg needed)
/// that writes a placeholder CAF, so the files on disk can be counted.
@MainActor
final class JobAudioLifetimeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestAudio.temporaryDirectory("lifetime")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var cafDirectory: URL { directory.appendingPathComponent("cafs") }

    private var cafs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cafDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".caf") }
    }

    /// Writes the CAF named by its last argument after a short pause, then exits successfully.
    private func quickTool() throws -> URL {
        let url = directory.appendingPathComponent("quick-tool.sh")
        let script = "#!/bin/sh\nfor last; do :; done\nsleep 0.01\ncase \"$last\" in *.caf) printf x > \"$last\";; esac\nexit 0\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeLifetime(tool: URL) -> JobAudioLifetime {
        JobAudioLifetime(workspace: JobWorkspace(directory: cafDirectory, encoder: tool))
    }

    private func source(_ index: Int) -> URL { directory.appendingPathComponent("job-\(index).wav") }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Policy

    func testEntitlementOrderAndCap() {
        let r = UUID(), i = UUID(), s = UUID()
        XCTAssertEqual(JobAudioLifetime.entitled(running: nil, ingest: nil, selected: nil), [])
        XCTAssertEqual(JobAudioLifetime.entitled(running: nil, ingest: nil, selected: s), [s])
        XCTAssertEqual(JobAudioLifetime.entitled(running: r, ingest: nil, selected: s), [r, s])
        XCTAssertEqual(JobAudioLifetime.entitled(running: r, ingest: i, selected: s), [r, i],
                       "a file being added squeezes out the selected job while a queue runs")
        XCTAssertEqual(JobAudioLifetime.entitled(running: nil, ingest: i, selected: s), [i, s])
        XCTAssertEqual(JobAudioLifetime.entitled(running: s, ingest: nil, selected: s), [s],
                       "the selected job that is running needs one CAF")
        XCTAssertEqual(JobAudioLifetime.entitled(running: r, ingest: s, selected: s), [r, s])
    }

    // MARK: Workspace cap

    /// 50 jobs run in turn while the operator hops between jobs (often faster than a decode
    /// finishes); never more than two CAFs exist, and none are left at the end.
    func testFiftyJobsNeverHoldMoreThanTwoCAFs() async throws {
        let lifetime = makeLifetime(tool: try quickTool())
        let jobs = (0..<50).map { _ in UUID() }
        var maxOnDisk = 0
        var exported = 0

        for (index, job) in jobs.enumerated() {
            // The export of this job and three quick selections race each other.
            let export = Task { @MainActor in
                defer { lifetime.exportEnded(job) }
                _ = try await lifetime.exportAudio(for: job, source: self.source(index))
            }
            var previews: [Task<Void, Error>] = []
            for hop in 1...3 {
                let target = jobs[(index * 7 + hop * 13) % jobs.count]
                lifetime.assign(.selected, to: target)
                previews.append(Task { @MainActor in
                    _ = try await lifetime.audio(for: target, source: self.source(hop), as: .selected)
                })
                if hop == 2 { await Task.yield() }
                maxOnDisk = max(maxOnDisk, cafs.count)
            }
            if (try? await export.value) != nil { exported += 1 }
            for preview in previews { _ = await preview.result }
            maxOnDisk = max(maxOnDisk, cafs.count)
            let live = await lifetime.workspace.liveCount
            XCTAssertLessThanOrEqual(live, 2)
            XCTAssertLessThanOrEqual(cafs.count, 2)
        }
        XCTAssertEqual(exported, 50, "every running job got its audio")

        let peak = await lifetime.workspace.peakLiveCount
        XCTAssertLessThanOrEqual(peak, 2, "never more than two CAFs at once")
        XCTAssertGreaterThanOrEqual(peak, 1)
        XCTAssertLessThanOrEqual(maxOnDisk, 2)

        // Only the last selection still holds audio; deselecting deletes it.
        await lifetime.settle()
        let selected = try XCTUnwrap(lifetime.roles[.selected])
        let liveJobs = await lifetime.workspace.liveJobs
        XCTAssertTrue(liveJobs.isSubset(of: [selected]))
        lifetime.assign(.selected, to: nil)
        await lifetime.settle()
        let left = await lifetime.workspace.liveCount
        XCTAssertEqual(left, 0)
        await waitUntil("no CAFs") { self.cafs.isEmpty }
    }

    func testSelectedAndRunningShareOneCAF() async throws {
        let lifetime = makeLifetime(tool: try quickTool())
        let job = UUID()
        lifetime.assign(.selected, to: job)
        let preview = try await lifetime.audio(for: job, source: source(0), as: .selected)
        let export = try await lifetime.exportAudio(for: job, source: source(0))
        XCTAssertTrue(preview === export)
        XCTAssertEqual(cafs.count, 1)

        lifetime.exportEnded(job)
        await lifetime.settle()
        XCTAssertEqual(cafs.count, 1, "the selected job keeps its audio after its export")
        lifetime.assign(.selected, to: nil)
        await lifetime.settle()
        XCTAssertEqual(cafs.count, 0)
    }

    func testAddingFilesDuringARunSqueezesTheSelectedJobAndGivesItBack() async throws {
        let lifetime = makeLifetime(tool: try quickTool())
        var changes = 0
        lifetime.onChange = { changes += 1 }
        let running = UUID(), selected = UUID(), adding = UUID()
        _ = try await lifetime.exportAudio(for: running, source: source(0))
        lifetime.assign(.selected, to: selected)
        _ = try await lifetime.audio(for: selected, source: source(1), as: .selected)
        XCTAssertEqual(cafs.count, 2)

        changes = 0
        lifetime.assign(.ingest, to: adding)
        XCTAssertFalse(lifetime.isEntitled(selected))
        XCTAssertEqual(changes, 1, "the app is told the selected job lost its audio")
        _ = try await lifetime.audio(for: adding, source: source(2), as: .ingest)
        let live = await lifetime.workspace.liveJobs
        XCTAssertEqual(live, [running, adding])
        XCTAssertEqual(cafs.count, 2)

        // A squeezed-out job cannot get audio until a slot frees.
        do {
            _ = try await lifetime.audio(for: selected, source: source(1), as: .selected)
            XCTFail("the selected job is not entitled while two others hold audio")
        } catch is CancellationError {}

        lifetime.assign(.ingest, to: nil)
        XCTAssertTrue(lifetime.isEntitled(selected))
        _ = try await lifetime.audio(for: selected, source: source(1), as: .selected)
        let after = await lifetime.workspace.liveJobs
        XCTAssertEqual(after, [running, selected])
        let peak = await lifetime.workspace.peakLiveCount
        XCTAssertEqual(peak, 2)

        await lifetime.releaseAll()
        XCTAssertEqual(cafs.count, 0)
    }

    func testDeselectingDuringADecodeCancelsIt() async throws {
        let lifetime = makeLifetime(tool: try TestAudio.slowTool(in: directory))
        let a = UUID(), b = UUID()
        lifetime.assign(.selected, to: a)
        let loading = Task { @MainActor in try await lifetime.audio(for: a, source: self.source(0), as: .selected) }
        await waitUntil("decode started") { !self.cafs.isEmpty }
        let pid = try await TestAudio.slowToolPID(in: directory)

        lifetime.assign(.selected, to: b)
        let result = await loading.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        await lifetime.settle()
        let live = await lifetime.workspace.liveCount
        XCTAssertEqual(live, 0)
        await waitUntil("partial CAF deleted") { self.cafs.isEmpty }
        let gone = try await TestAudio.waitForExit(try XCTUnwrap(pid))
        XCTAssertTrue(gone, "the decoder is stopped")
    }

    /// The selected job is also running: the preview giving up must not cancel the export's decode.
    func testCancellingOneCallerKeepsTheDecodeForAnotherRole() async throws {
        let lifetime = makeLifetime(tool: try TestAudio.slowTool(in: directory))
        let job = UUID()
        lifetime.assign(.selected, to: job)
        lifetime.assign(.running, to: job)
        let preview = Task { @MainActor in try await lifetime.audio(for: job, source: self.source(0), as: .selected) }
        let export = Task { @MainActor in try await lifetime.audio(for: job, source: self.source(0), as: .running) }
        await waitUntil("decode started") { !self.cafs.isEmpty }

        preview.cancel()
        await waitUntil("selected role given up") { lifetime.roles[.selected] == nil }
        let live = await lifetime.workspace.liveJobs
        XCTAssertEqual(live, [job], "the running job still decodes")

        // Ending the export releases the job and cancels the decode for both waiters.
        lifetime.exportEnded(job)
        let exportResult = await export.result
        XCTAssertThrowsError(try exportResult.get())
        let previewResult = await preview.result
        XCTAssertThrowsError(try previewResult.get())
        await lifetime.settle()
        await waitUntil("partial CAF deleted") { self.cafs.isEmpty }
    }

    func testUnentitledJobGetsNoAudio() async throws {
        let lifetime = makeLifetime(tool: try quickTool())
        do {
            _ = try await lifetime.audio(for: UUID(), source: source(0))
            XCTFail("a job without a role gets no audio")
        } catch is CancellationError {}
        XCTAssertEqual(cafs.count, 0)
    }
}

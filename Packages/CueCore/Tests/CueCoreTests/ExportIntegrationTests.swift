import XCTest
import CoreGraphics
@testable import CueCore

/// Task 3.1: the preset-driven export engine. The first group needs no FFmpeg (argument shape,
/// preflight, cancellation and failure paths with stand-in encoders); the second exports a real
/// 4-second signal with every preset and inspects the files with `ffmpeg -i` and small decodes.
final class ExportIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    /// A track that draws like a real one, with a placeholder PCM file (for runs whose encoder
    /// is a stand-in and never reads the audio).
    static func fakeTrack(seconds: Double, in dir: URL) throws -> AudioTrack {
        let caf = dir.appendingPathComponent("fake.caf")
        try Data([0]).write(to: caf)
        let detail = (0..<Int(seconds * 200)).map { Float(0.3 + 0.6 * abs(sin(Double($0) / 37))) }
        return AudioTrack(url: dir.appendingPathComponent("fake.wav"), pcm: PreparedAudio(url: caf),
                          seconds: seconds, detailPeaks: detail, peaks: AudioTrack.reducePeaks(detail[...], columns: 1600))
    }

    /// A shell script standing in for FFmpeg.
    static func script(_ body: String, in dir: URL, name: String = "tool.sh") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static let roomy: (URL) throws -> DiskSpace.Volume = { _ in DiskSpace.Volume(name: "Test", availableBytes: 1 << 50) }

    static func hiddenFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".waveform-cue") }
    }

    // MARK: - Rate bridge and command shape (no FFmpeg)

    func testVideoStandardTimelineRates() {
        XCTAssertEqual(VideoStandard.hd1080i50.timelineRate, .fields50)
        XCTAssertEqual(VideoStandard.hd1080p25.timelineRate, .fps25)
        XCTAssertEqual(VideoStandard.hd1080p50.timelineRate, .fps50)
        let i50 = ClipTimeline(duration: 4, standard: VideoStandard.hd1080i50.timelineRate)
        XCTAssertEqual(i50.outputFrames, 100)
        XCTAssertEqual(i50.positionCount, 200, "1080i50 renders one image per field")
        XCTAssertEqual(i50.totalSamples, 100 * 1920)
        let p50 = ClipTimeline(duration: 4.013, standard: VideoStandard.hd1080p50.timelineRate)
        XCTAssertEqual(p50.outputFrames, 201)
        XCTAssertEqual(p50.totalSamples, 201 * 960)
    }

    func testFinalCommandHasOneResamplePadAndEndTrim() throws {
        let dir = try TestAudio.temporaryDirectory("export-args")
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Self.fakeTrack(seconds: 30, in: dir)
        let trims: [TrimSettings] = [.none, TrimSettings(inPoint: 2, outPoint: 20, fadeIn: 1, fadeOut: 2, preRoll: 3)]
        for preset in ExportPreset.builtIn {
            for trim in trims {
                let timeline = MXFExport.timeline(for: track, preset: preset, trim: trim)
                let snapshot = MXFExport.Snapshot(track: track, label: CueLabel(text: "T"), layout: .four, gainDB: -3)
                let args = MXFExport.arguments(snapshot: snapshot, preset: preset, timeline: timeline,
                                               audioPath: "/tmp/a.caf", output: "/tmp/o.mxf")
                let graph = try XCTUnwrap(args.firstIndex(of: "-filter_complex").map { args[$0 + 1] })
                func count(_ needle: String) -> Int { graph.components(separatedBy: needle).count - 1 }
                XCTAssertEqual(count("aresample"), 1, graph)
                XCTAssertEqual(count("apad"), 1, graph)
                XCTAssertEqual(count("atrim=end_sample=\(timeline.totalSamples)"), 1, graph)
                XCTAssertEqual(count("atrim=end_sample="), 1, graph)  // the out point is part of atrim=start_sample
                XCTAssertEqual(count("volume=-3dB"), 1, graph)
                XCTAssertEqual(args[args.firstIndex(of: "-framerate")! + 1], "\(preset.video.renderRate)")
                XCTAssertFalse(args.contains("-af"))
            }
        }
        // The exact chain for a trimmed 1080i50 job with fades and a 3 s pre-roll.
        let timeline = MXFExport.timeline(for: track, preset: .avcIntra1080i50, trim: trims[1])
        let args = MXFExport.arguments(snapshot: MXFExport.Snapshot(track: track, label: CueLabel(), layout: .two),
                                       preset: .avcIntra1080i50, timeline: timeline, audioPath: "/a.caf", output: "/o.mxf")
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertEqual(timeline.totalSamples, (75 + 450) * 1920)
        XCTAssertTrue(graph.hasPrefix("[1:a]aresample=48000,atrim=start_sample=96000:end_sample=960000,asetpts=PTS-STARTPTS,"
            + "afade=t=in:start_sample=0:nb_samples=48000,afade=t=out:start_sample=768000:nb_samples=96000,"
            + "adelay=delays=144000S:all=1,apad,atrim=end_sample=1008000,asplit=2[s0][s1];"), graph)
    }

    func testFileTimecodeMovesEarlierByPreRoll() throws {
        let dir = try TestAudio.temporaryDirectory("export-tc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Self.fakeTrack(seconds: 10, in: dir)
        let start = try XCTUnwrap(Timecode("10:00:00:00"))
        let preRoll = TrimSettings(preRoll: 5)
        func tc(_ preset: ExportPreset, _ start: Timecode, _ trim: TrimSettings) -> String {
            MXFExport.fileStartTimecode(start, preset: preset,
                                        timeline: MXFExport.timeline(for: track, preset: preset, trim: trim)).formatted
        }
        XCTAssertEqual(tc(.avcIntra1080i50, start, .none), "10:00:00:00")
        XCTAssertEqual(tc(.avcIntra1080i50, start, preRoll), "09:59:55:00")
        XCTAssertEqual(tc(.avcIntra1080p50, try XCTUnwrap(Timecode("10:00:00:12")), preRoll), "09:59:55:24")
        XCTAssertEqual(tc(.mpeg2_1080p25, .start, preRoll), "23:59:55:00")
    }

    // MARK: - Preflight (no FFmpeg)

    func testDiskSpaceMessageNamesVolumeFreeAndRequired() {
        let message = DiskSpace.message(volume: DiskSpace.Volume(name: "Cues", availableBytes: 1_200_000_000),
                                        required: 3_400_000_000)
        // Sizes follow the user's locale ("1.2 GB" or "1,2 GB").
        XCTAssertEqual(message, "Not enough space on “Cues”: \(DiskSpace.format(1_200_000_000)) free, "
                       + "\(DiskSpace.format(3_400_000_000)) needed.")
        XCTAssertTrue(["1.2 GB", "1,2 GB"].contains(DiskSpace.format(1_200_000_000)), DiskSpace.format(1_200_000_000))
    }

    func testRequiredBytesCoverVideoAudioAndCAF() throws {
        let dir = try TestAudio.temporaryDirectory("export-bytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Self.fakeTrack(seconds: 180, in: dir)
        let timeline = MXFExport.timeline(for: track, preset: .avcIntra1080i50)
        let mxf = DiskSpace.requiredBytes(preset: .avcIntra1080i50, timeline: timeline, layout: .four)
        // 3 minutes at 115 Mb/s plus four 1.152 Mb/s tracks, plus 2 %.
        XCTAssertEqual(Double(mxf), (115_000_000 + 4 * 1_152_000) * 180 * 1.02 / 8, accuracy: 1)
        let caf = DiskSpace.cafBytes(seconds: 180)
        XCTAssertEqual(caf, 180 * 288_000 + 4096)
        XCTAssertEqual(DiskSpace.requiredBytes(preset: .avcIntra1080i50, timeline: timeline, layout: .four,
                                               pendingCAFBytes: caf), mxf + caf)
    }

    func testLowDiskSpaceFailsBeforeEncoderStarts() throws {
        let dir = try TestAudio.temporaryDirectory("export-space")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = dir.appendingPathComponent("started")
        let tool = try Self.script("touch '\(started.path)'; cat > /dev/null", in: dir)
        let track = try Self.fakeTrack(seconds: 4, in: dir)
        let tiny: (URL) throws -> DiskSpace.Volume = { _ in DiskSpace.Volume(name: "Tiny", availableBytes: 1000) }
        XCTAssertThrowsError(try MXFExport.run(
            snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .avcIntra1080i50,
            timeline: MXFExport.timeline(for: track, preset: .avcIntra1080i50), encoder: tool,
            destination: dir.appendingPathComponent("out.mxf"), volume: tiny, progress: { _ in })) { error in
            guard case JobExportError.failed(let reason, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.hasPrefix("Not enough space on “Tiny”: 1 KB free,"), reason)
            XCTAssertTrue(reason.hasSuffix("needed."), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path), "FFmpeg must not start")
    }

    func testUnwritableOrMissingFolderThrowsDestinationUnwritable() throws {
        let dir = try TestAudio.temporaryDirectory("export-unwritable")
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let track = try Self.fakeTrack(seconds: 2, in: dir)
        let tool = try Self.script("cat > /dev/null", in: dir)
        for folder in [locked, dir.appendingPathComponent("missing", isDirectory: true)] {
            XCTAssertThrowsError(try MXFExport.run(
                snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .mpeg2_1080p25,
                timeline: MXFExport.timeline(for: track, preset: .mpeg2_1080p25), encoder: tool,
                destination: folder.appendingPathComponent("out.mxf"), volume: Self.roomy, progress: { _ in })) { error in
                guard case JobExportError.destinationUnwritable(let reported, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(reported.standardizedFileURL.path, folder.standardizedFileURL.path)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), [])
    }

    // MARK: - Process handling with stand-in encoders (no FFmpeg)

    func testEncoderFailureKeepsLast1500CharactersOfLog() throws {
        let dir = try TestAudio.temporaryDirectory("export-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1,000 'a' then 2,000 'b' on stderr, then fail without reading the frames.
        let tool = try Self.script("printf '%1000s' | tr ' ' a >&2; printf '%2000s' | tr ' ' b >&2; exit 3", in: dir)
        let track = try Self.fakeTrack(seconds: 2, in: dir)
        let destination = dir.appendingPathComponent("out.mxf")
        XCTAssertThrowsError(try MXFExport.run(
            snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .avcIntra1080p25,
            timeline: MXFExport.timeline(for: track, preset: .avcIntra1080p25), encoder: tool,
            destination: destination, volume: Self.roomy, progress: { _ in })) { error in
            guard case JobExportError.failed(let reason, let log) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, "MXF encoding failed.")
            XCTAssertEqual(log, String(repeating: "b", count: 1500))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(Self.hiddenFiles(in: dir), [])
        // Build 10's entry point keeps its single message with the log.
        XCTAssertThrowsError(try MXFExport.run(track: track, label: CueLabel(), encoder: tool, destination: destination,
                                               progress: { _ in })) { error in
            XCTAssertTrue(error is CueError, "\(error)")
            XCTAssertTrue(error.localizedDescription.hasPrefix("MXF encoding failed. bbbb"))
        }
    }

    func testCollisionLeavesBothFilesIntact() throws {
        let dir = try TestAudio.temporaryDirectory("export-collision")
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Self.fakeTrack(seconds: 1, in: dir)
        let destination = dir.appendingPathComponent("out.mxf")
        // A second instance creates the destination while this export is encoding.
        let tool = try Self.script("""
            for last; do :; done
            cat > /dev/null
            printf ours > "$last"
            printf theirs > '\(destination.path)'
            """, in: dir)
        XCTAssertThrowsError(try MXFExport.run(
            snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .mpeg2_1080p25,
            timeline: MXFExport.timeline(for: track, preset: .mpeg2_1080p25), encoder: tool,
            destination: destination, volume: Self.roomy, progress: { _ in })) { error in
            guard case JobExportError.failed(let reason, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("already exists"), reason)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "theirs")
        // An existing destination is refused before encoding, and stays untouched.
        XCTAssertThrowsError(try MXFExport.run(
            snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .mpeg2_1080p25,
            timeline: MXFExport.timeline(for: track, preset: .mpeg2_1080p25), encoder: tool,
            destination: destination, volume: Self.roomy, progress: { _ in }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "theirs")
        XCTAssertEqual(Self.hiddenFiles(in: dir), [])
    }

    func testCancellationStopsEncoderAndLeavesNoFile() async throws {
        let dir = try TestAudio.temporaryDirectory("export-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Self.fakeTrack(seconds: 120, in: dir)
        let pidFile = dir.appendingPathComponent("pid")
        let tool = try Self.script("echo $$ > '\(pidFile.path)'; exec cat > /dev/null", in: dir)
        let destination = dir.appendingPathComponent("out.mxf")
        let started = expectation(description: "frames flowing")
        started.assertForOverFulfill = false
        let task = Task.detached {
            try MXFExport.run(snapshot: MXFExport.Snapshot(track: track, label: CueLabel()), preset: .avcIntra1080i50,
                              timeline: MXFExport.timeline(for: track, preset: .avcIntra1080i50), encoder: tool,
                              destination: destination, volume: Self.roomy) { value in
                if value > 0.001 { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 30)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(Self.hiddenFiles(in: dir), [])
        let pid = try XCTUnwrap(pid_t(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "the encoder process must have exited")
    }

    // MARK: - Real exports (FFmpeg)

    struct Case {
        var preset: ExportPreset
        var layout: AudioLayout
        var start: String
        var trim: TrimSettings = .none
        var gainDB: Double = 0
        /// Expected `timecode` in the file.
        var fileTimecode: String
        /// Expected RP2027 coding label tail, or nil for MPEG-2.
        var label: [UInt8]?
        var videoCodec: String
        var pixelFormat: String
    }

    static let seconds = 4.013   // not a whole frame at 25 or 50, so padding is exercised

    static let cases: [Case] = [
        Case(preset: .avcIntra1080i50, layout: .four, start: "10:00:00:00", trim: TrimSettings(preRoll: 2),
             fileTimecode: "09:59:58:00", label: [0x32, 0x31, 0x02], videoCodec: "h264 (High 4:2:2 Intra)",
             pixelFormat: "yuv422p10le(tv, bt709, top first)"),
        Case(preset: .avcIntra1080p25, layout: .two, start: "01:00:00:00", gainDB: -20 * log10(2.0),
             fileTimecode: "01:00:00:00", label: [0x32, 0x31, 0x04], videoCodec: "h264 (High 4:2:2 Intra)",
             pixelFormat: "yuv422p10le(tv, bt709, progressive)"),
        // FFmpeg labels 1080p50 as 25p (Planning findings); asserted so a change is noticed.
        Case(preset: .avcIntra1080p50, layout: .eight, start: "00:00:10:00",
             fileTimecode: "00:00:10:00", label: [0x32, 0x31, 0x04], videoCodec: "h264 (High 4:2:2 Intra)",
             pixelFormat: "yuv422p10le(tv, bt709, progressive)"),
        Case(preset: .mpeg2_1080p25, layout: .two, start: "00:00:00:00",
             fileTimecode: "00:00:00:00", label: nil, videoCodec: "mpeg2video (4:2:2)",
             pixelFormat: "yuv422p(tv, bt709/unknown/unknown, progressive)"),
    ]

    func testExportEachPreset() throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("export-real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("signal.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)", right: "0.25*sin(2*PI*660*t)",
                               seconds: Self.seconds, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        for c in Self.cases {
            try check(c, track: track, ffmpeg: ffmpeg, dir: dir)
        }
    }

    private func check(_ c: Case, track: AudioTrack, ffmpeg: URL, dir: URL) throws {
        let name = c.preset.id.rawValue
        let label = CueLabel(text: "Integration " + name)
        let appearance = CueAppearance()
        let timeline = MXFExport.timeline(for: track, preset: c.preset, trim: c.trim)
        let snapshot = MXFExport.Snapshot(track: track, label: label, appearance: appearance, layout: c.layout,
                                          startTimecode: try XCTUnwrap(Timecode(c.start)), gainDB: c.gainDB)
        let output = dir.appendingPathComponent(name + ".mxf")
        let command = MXFExport.arguments(snapshot: snapshot, preset: c.preset, timeline: timeline,
                                          audioPath: "<caf>", output: "<out>")
        print("[3.1] \(name) command: ffmpeg " + command.map { $0.contains(" ") || $0.contains("|") ? "'\($0)'" : $0 }
            .joined(separator: " "))
        var reported: [Double] = []
        let began = Date()
        try MXFExport.run(snapshot: snapshot, preset: c.preset, timeline: timeline, encoder: ffmpeg,
                          destination: output) { reported.append($0) }
        print("[3.1] \(name): \(timeline.positionCount) images in \(String(format: "%.2f", Date().timeIntervalSince(began))) s")
        XCTAssertEqual(reported.last, 1, name)
        XCTAssertEqual(Self.hiddenFiles(in: dir), [], name)

        // Container, video and timecode from `ffmpeg -i`.
        let info = try FFmpegRun.info(output, ffmpeg: ffmpeg)
        let video = try XCTUnwrap(info.lines.first { $0.contains("Video:") }, name)
        XCTAssertTrue(video.contains("Video: \(c.videoCodec), \(c.pixelFormat), 1920x1080"), "\(name): \(video)")
        XCTAssertTrue(video.contains(" \(c.preset.video.encodeRate) fps"), "\(name): \(video)")
        XCTAssertEqual(info.timecode, c.fileTimecode, name)
        XCTAssertTrue(info.text.contains("product_name    : OP1a Muxer"), name)
        if c.preset.codec == .avcIntra100 {
            let probe = try FFmpegRun.probe(output, ffmpeg: ffmpeg)
            if let probe {
                XCTAssertEqual(probe["profile"], "High 4:2:2 Intra", name)
                XCTAssertEqual(probe["pix_fmt"], "yuv422p10le", name)
                XCTAssertEqual(probe["field_order"], c.preset.video.interlaced ? "tt" : "progressive", name)
                XCTAssertEqual(probe["color_space"], "bt709", name)
                XCTAssertEqual(probe["color_primaries"], "bt709", name)
                XCTAssertEqual(probe["color_transfer"], "bt709", name)
                XCTAssertEqual(probe["color_range"], "tv", name)
            } else {
                print("[3.1] ffprobe not beside FFMPEG_EXECUTABLE; field order and colour checked from `ffmpeg -i` only")
            }
        }

        // Bytes: RP2027 label and partitions.
        let bytes = try Data(contentsOf: output)
        if let tail = c.label {
            let ul: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01] + tail
            XCTAssertTrue(bytes.range(of: Data(ul)) != nil, "\(name): RP2027 label …\(tail.map { String(format: "%02x", $0) }.joined())")
            let other: UInt8 = tail[2] == 0x02 ? 0x04 : 0x02
            XCTAssertNil(bytes.range(of: Data(ul.dropLast() + [other])), "\(name): wrong scan label present")
            let body: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x03]
            XCTAssertNil(bytes.range(of: Data(body)), "\(name): AVC-I must have no body partition")
        }

        // Frames: whole-frame clip length.
        XCTAssertEqual(try FFmpegRun.videoPackets(output, ffmpeg: ffmpeg), timeline.outputFrames, name)

        // Audio: N mono 24-bit 48 kHz tracks, identical length, left, right, then digital silence.
        let audio = info.lines.filter { $0.contains("Audio:") }
        XCTAssertEqual(audio.count, c.layout.trackCount, name)
        for line in audio { XCTAssertTrue(line.contains("Audio: pcm_s24le, 48000 Hz, mono, s32 (24 bit)"), "\(name): \(line)") }
        let gain = pow(10, c.gainDB / 20)
        let preRollSamples = timeline.preRollSamples
        for index in 0..<c.layout.trackCount {
            let samples = try FFmpegRun.samples(output, track: index, ffmpeg: ffmpeg)
            XCTAssertEqual(samples.count, timeline.totalSamples, "\(name) track \(index + 1)")
            let peak = Double(samples.map { $0.magnitude }.max() ?? 0) / Double(Int32.max)
            switch index {
            case 0: XCTAssertEqual(peak, 0.5 * gain, accuracy: 0.01, "\(name) track 1 is left")
            case 1: XCTAssertEqual(peak, 0.25 * gain, accuracy: 0.01, "\(name) track 2 is right")
            default: XCTAssertEqual(peak, 0, "\(name) track \(index + 1) is digital silence")
            }
            if index < 2 {
                if preRollSamples > 0 {
                    XCTAssertEqual(samples[..<preRollSamples].map(\.magnitude).max(), 0, "\(name): silent pre-roll")
                }
                // The padding after the music is silent.
                let musicEnd = preRollSamples + Int((Self.seconds * 48_000).rounded())
                XCTAssertGreaterThan(timeline.totalSamples, musicEnd + 100, name)
                XCTAssertEqual(samples[(musicEnd + 10)...].map(\.magnitude).max(), 0, "\(name): padding is silent")
            }
        }

        // A decoded frame equals the preview bitmap within codec tolerance.
        let frame = timeline.outputFrames / 2
        let decoded = try FFmpegRun.decodeFrame(output, index: frame, ffmpeg: ffmpeg)
        let perFrame = timeline.positionsPerFrame
        let first = Preview.render(track, timeline: timeline, position: frame * perFrame, label: label, appearance: appearance)
        let expected: [UInt8]
        if perFrame == 2 {
            // Woven fields: even rows from the first image, odd rows from the second.
            let second = Preview.render(track, timeline: timeline, position: frame * perFrame + 1, label: label,
                                        appearance: appearance)
            XCTAssertGreaterThan(Preview.maxBlockError(first, second), 8, "\(name): the two fields must differ")
            expected = Preview.weave(top: first, bottom: second)
            // Field order: the other weave must not match (top field first is asserted, not assumed).
            XCTAssertGreaterThan(Preview.maxBlockError(try FFmpegRun.decodeFrame(output, index: frame, ffmpeg: ffmpeg),
                                                       Preview.weave(top: second, bottom: first)), 9,
                                 "\(name): bottom-field-first weave must not match")
        } else {
            expected = first
        }
        let error = Preview.maxBlockError(decoded, expected)
        let mean = Preview.meanError(decoded, expected)
        print("[3.1] \(name): frame \(frame) mean error \(String(format: "%.3f", mean)), worst 16×16 block \(String(format: "%.2f", error))")
        XCTAssertLessThan(mean, 1, name)
        // Interlaced coding of the moving playhead costs a little more at the field edges.
        XCTAssertLessThan(error, perFrame == 2 ? 9 : 6, name)
        // Control: one second later differs (clocks, playhead), so the check can fail.
        let later = Preview.render(track, timeline: timeline, position: (frame + c.preset.video.encodeRate) * perFrame,
                                   label: label, appearance: appearance)
        let control = Preview.maxBlockError(decoded, later)
        print("[3.1] \(name): control (one second later) worst block \(String(format: "%.2f", control))")
        XCTAssertGreaterThan(control, 20, "\(name): control frame must differ")
    }

    /// Measures the export rate. Opt in with `CUE_EXPORT_BENCH=1` (and FFmpeg); 30 s at 1080i50.
    func testExportRateBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CUE_EXPORT_BENCH"] == "1" else {
            throw XCTSkip("Set CUE_EXPORT_BENCH=1 to measure the export rate.")
        }
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("export-bench")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("bench.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)*sin(PI*t/7)", right: "0.3*sin(2*PI*220*t)",
                               seconds: 30, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        for preset in [ExportPreset.avcIntra1080i50, .avcIntra1080p25] {
            let timeline = MXFExport.timeline(for: track, preset: preset)
            let began = Date()
            try MXFExport.run(snapshot: MXFExport.Snapshot(track: track, label: CueLabel(text: "Benchmark"), layout: .four),
                              preset: preset, timeline: timeline, encoder: ffmpeg,
                              destination: dir.appendingPathComponent(preset.id.rawValue + ".mxf"), progress: { _ in })
            let elapsed = Date().timeIntervalSince(began)
            print(String(format: "[3.1 bench] %@: 30 s clip, %d images in %.2f s = %.0f images/s, %.1f× real time",
                         preset.id.rawValue, timeline.positionCount, elapsed, Double(timeline.positionCount) / elapsed, 30 / elapsed))
        }
    }
}

// MARK: - Preview comparison

enum Preview {
    static func render(_ track: AudioTrack, timeline: ClipTimeline, position: Int, label: CueLabel,
                       appearance: CueAppearance) -> [UInt8] {
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 7680,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
        let layout = appearance.layout
        CuePicture.draw(in: ctx, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                        path: CuePicture.overviewPath(track, layout: layout), timeline: timeline,
                        layout: layout, position: position, label: label, appearance: appearance)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 7680 * 1080))
    }

    static func weave(top: [UInt8], bottom: [UInt8]) -> [UInt8] {
        var out = top
        for row in stride(from: 1, to: 1080, by: 2) {
            out.replaceSubrange(row * 7680..<(row + 1) * 7680, with: bottom[row * 7680..<(row + 1) * 7680])
        }
        return out
    }

    /// Mean absolute difference over B, G, R (both buffers are B, G, R, X rows of 1920).
    static func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
        }
        return Double(total) / Double(a.count / 4 * 3)
    }

    /// Largest mean absolute difference of any 16 × 16 block. Codec noise averages out inside a
    /// block; a wrong clock digit or playhead does not.
    static func maxBlockError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var worst = 0.0
        for by in stride(from: 0, to: 1080, by: 16) {
            for bx in stride(from: 0, to: 1920, by: 16) {
                var total = 0, n = 0
                for y in by..<min(1080, by + 16) {
                    for x in bx..<bx + 16 {
                        let i = (y * 1920 + x) * 4
                        total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                        n += 3
                    }
                }
                worst = max(worst, Double(total) / Double(n))
            }
        }
        return worst
    }
}

// MARK: - FFmpeg inspection

enum FFmpegRun {
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes concurrently so a full stderr cannot block a large stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }

    static func generate(left: String, right: String, seconds: Double, to url: URL, ffmpeg: URL) throws {
        let result = try run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                      "-i", "aevalsrc=\(left)|\(right):s=48000:d=\(seconds)", "-c:a", "pcm_s24le", url.path])
        guard result.status == 0 else { throw CueError("Fixture failed: " + result.stderr) }
    }

    struct Info {
        var text: String
        var lines: [String] { text.components(separatedBy: "\n") }
        var timecode: String? {
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("timecode ") }
                .flatMap { $0.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) }
        }
    }

    static func info(_ file: URL, ffmpeg: URL) throws -> Info {
        Info(text: try run(ffmpeg, ["-hide_banner", "-nostdin", "-i", file.path]).stderr)
    }

    /// `ffprobe` stream fields when an `ffprobe` sits beside the FFmpeg under test, else nil.
    static func probe(_ file: URL, ffmpeg: URL) throws -> [String: String]? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return nil }
        let result = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                       "stream=codec_name,profile,pix_fmt,field_order,color_space,color_primaries,color_transfer,color_range",
                                       "-of", "default=noprint_wrappers=1", file.path])
        var fields: [String: String] = [:]
        for line in String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    static func videoPackets(_ file: URL, ffmpeg: URL) throws -> Int {
        let result = try run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-i", file.path,
                                      "-map", "0:v:0", "-c", "copy", "-f", "framecrc", "-"])
        return String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.count
    }

    /// One audio track as 32-bit samples (24-bit values in the top bytes).
    static func samples(_ file: URL, track: Int, ffmpeg: URL) throws -> [Int32] {
        let result = try run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-i", file.path,
                                      "-map", "0:a:\(track)", "-c:a", "pcm_s32le", "-f", "s32le", "-"])
        guard result.status == 0 else { throw CueError("Audio decode failed: " + result.stderr) }
        return result.stdout.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    }

    /// Frame `index` as B, G, R, A rows (no deinterlacing: a 1080i50 frame stays woven).
    static func decodeFrame(_ file: URL, index: Int, ffmpeg: URL) throws -> [UInt8] {
        let result = try run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-i", file.path, "-map", "0:v:0",
                                      // The default 10-bit-to-RGB path is off by 1–2 levels; the encode is exact.
                                      "-sws_flags", "accurate_rnd+full_chroma_int",
                                      "-vf", "select=eq(n\\,\(index)),scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=bgra",
                                      "-frames:v", "1", "-f", "rawvideo", "-"])
        guard result.status == 0, result.stdout.count == 7680 * 1080 else {
            throw CueError("Frame decode failed (\(result.stdout.count) bytes): " + result.stderr)
        }
        return [UInt8](result.stdout)
    }
}

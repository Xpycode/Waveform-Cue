import XCTest
@testable import CueCore

final class ExportPresetTests: XCTestCase {
    private let colour = "scale=out_color_matrix=bt709:out_range=tv"
    private let tags = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]

    private func head(rate: Int, trackMaps: Int) -> [String] {
        var a = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                 "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "1920x1080",
                 "-framerate", "\(rate)", "-i", "pipe:0", "-i", "/tmp/a.caf", "-map", "0:v:0"]
        for t in 0..<trackMaps { a += ["-map", "[t\(t)]"] }
        return a + ["-map_metadata", "-1"]
    }

    private func graph(samples: Int, tracks: Int, pre: String = "aresample=48000") -> String {
        let split = (0..<tracks).map { "[s\($0)]" }.joined()
        var parts = ["[1:a]\(pre),apad,atrim=end_sample=\(samples),asplit=\(tracks)\(split)"]
        for t in 0..<tracks {
            let c = t == 0 ? "c0=c0" : t == 1 ? "c0=c1" : "c0=0*c0"
            parts.append("[s\(t)]pan=mono|\(c)[t\(t)]")
        }
        return parts.joined(separator: ";")
    }

    private func tail(graph: String, tc: String) -> [String] {
        tags + ["-c:a", "pcm_s24le", "-ar", "48000", "-filter_complex", graph, "-timecode", tc,
                "-f", "mxf", "/tmp/out.mxf"]
    }

    // MARK: Catalogue

    func testBuiltInIDsAndOrder() {
        XCTAssertEqual(ExportPreset.builtIn.map(\.id.rawValue),
                       ["avci100-1080i50", "avci100-1080p25", "avci100-1080p50", "mpeg2-50-1080p25"])
        XCTAssertEqual(Set(ExportPreset.builtIn.map(\.id)).count, 4)
        XCTAssertEqual(ExportPreset.preset(for: "avci100-1080p50")?.isExperimental, true)
        XCTAssertEqual(ExportPreset.preset(for: "mpeg2-50-1080p25")?.isLegacy, true)
        XCTAssertNil(ExportPreset.preset(for: "nope"))
        XCTAssertEqual(ExportPreset.default.id, "avci100-1080i50")
    }

    func testVideoStandards() {
        XCTAssertEqual(VideoStandard.hd1080i50.samplesPerFrame, 1920)
        XCTAssertEqual(VideoStandard.hd1080p25.samplesPerFrame, 1920)
        XCTAssertEqual(VideoStandard.hd1080p50.samplesPerFrame, 960)
        XCTAssertEqual(VideoStandard.hd1080i50.renderRate, 50)
        XCTAssertEqual(VideoStandard.hd1080i50.imagesPerFrame, 2)
        XCTAssertEqual(VideoStandard.hd1080p25.imagesPerFrame, 1)
        XCTAssertTrue(VideoStandard.hd1080i50.interlaced)
        XCTAssertTrue(VideoStandard.hd1080i50.topFieldFirst)
        XCTAssertEqual(VideoStandard.hd1080i50.shortName, "1080i50")
        XCTAssertEqual(VideoStandard.hd1080p25.shortName, "1080p25")
        XCTAssertEqual(VideoStandard.hd1080p50.shortName, "1080p50")
    }

    func testReadoutAndEstimates() {
        XCTAssertEqual(ExportPreset.mpeg2_1080p25.formatReadout, "1080p25 · MXF")
        XCTAssertEqual(ExportPreset.avcIntra1080i50.formatReadout, "1080i50 · MXF")
        XCTAssertEqual(ExportPreset.avcIntra1080i50.detailedReadout(layout: .four),
                       "AVC-Intra 100 · 1080i50 · 115 Mb/s · 4 mono")
        // 10 s of 25p AVC-I with 2 mono tracks: (115 M + 2 x 1.152 M) x 10 x 1.02 / 8
        let bytes = ExportPreset.avcIntra1080p25.estimatedBytes(duration: 10, layout: .two)
        XCTAssertEqual(bytes, 149_562_600)
        XCTAssertGreaterThan(ExportPreset.avcIntra1080p50.estimatedBytes(duration: 10, layout: .two), bytes)
        XCTAssertEqual(ExportPreset.mpeg2_1080p25.estimatedBytes(duration: -5, layout: .two), 0)
    }

    // MARK: Arguments

    func testAVCIntra1080i50ExactArgumentsForEachLayout() {
        for layout in AudioLayout.allCases {
            let args = ExportPreset.avcIntra1080i50.ffmpegArguments(
                audioPath: "/tmp/a.caf", outputFrames: 100, layout: layout,
                timecode: Timecode("10:00:00:00")!, output: "/tmp/out.mxf")
            let video = ["-vf", "\(colour),format=yuv422p10le,tinterlace=interleave_top,setfield=tff",
                         "-c:v", "libx264", "-avcintra-class", "100", "-pix_fmt", "yuv422p10le",
                         "-flags", "+ildct+ilme"]
            XCTAssertEqual(args, head(rate: 50, trackMaps: layout.trackCount) + video
                           + tail(graph: graph(samples: 192_000, tracks: layout.trackCount), tc: "10:00:00:00"),
                           "layout \(layout)")
        }
    }

    func testAVCIntra1080p25ExactArgumentsForEachLayout() {
        for layout in AudioLayout.allCases {
            let args = ExportPreset.avcIntra1080p25.ffmpegArguments(
                audioPath: "/tmp/a.caf", outputFrames: 10, layout: layout, output: "/tmp/out.mxf")
            let video = ["-vf", "\(colour),format=yuv422p10le",
                         "-c:v", "libx264", "-avcintra-class", "100", "-pix_fmt", "yuv422p10le"]
            XCTAssertEqual(args, head(rate: 25, trackMaps: layout.trackCount) + video
                           + tail(graph: graph(samples: 19_200, tracks: layout.trackCount), tc: "00:00:00:00"),
                           "layout \(layout)")
        }
    }

    func testAVCIntra1080p50ExactArgumentsForEachLayout() {
        for layout in AudioLayout.allCases {
            let args = ExportPreset.avcIntra1080p50.ffmpegArguments(
                audioPath: "/tmp/a.caf", outputFrames: 10, layout: layout,
                timecode: Timecode("00:00:01:12")!, output: "/tmp/out.mxf")
            let video = ["-vf", "\(colour),format=yuv422p10le",
                         "-c:v", "libx264", "-avcintra-class", "100", "-pix_fmt", "yuv422p10le"]
            // 25-based 12 frames becomes 24 on the 50-based timecode.
            XCTAssertEqual(args, head(rate: 50, trackMaps: layout.trackCount) + video
                           + tail(graph: graph(samples: 9_600, tracks: layout.trackCount), tc: "00:00:01:24"),
                           "layout \(layout)")
        }
    }

    func testMPEG2ExactArgumentsForEachLayout() {
        for layout in AudioLayout.allCases {
            let args = ExportPreset.mpeg2_1080p25.ffmpegArguments(
                audioPath: "/tmp/a.caf", outputFrames: 10, layout: layout, output: "/tmp/out.mxf")
            let video = ["-vf", "\(colour),setsar=1",
                         "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "50M",
                         "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792",
                         "-g", "12", "-bf", "2"]
            XCTAssertEqual(args, head(rate: 25, trackMaps: layout.trackCount) + video
                           + tail(graph: graph(samples: 19_200, tracks: layout.trackCount), tc: "00:00:00:00"),
                           "layout \(layout)")
        }
    }

    /// Build 10's MXFExport arguments, copied from MXFExport.swift. The MPEG-2 preset must equal
    /// them except for the audio graph.
    func testMPEG2MatchesBuild10ExceptAudioGraph() {
        let build10 = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                       "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "1920x1080",
                       "-framerate", "25", "-i", "pipe:0", "-i", "/tmp/a.caf",
                       "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "-1",
                       "-vf", "scale=out_color_matrix=bt709:out_range=tv,setsar=1",
                       "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "50M",
                       "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792",
                       "-g", "12", "-bf", "2", "-colorspace", "bt709", "-color_primaries", "bt709",
                       "-color_trc", "bt709", "-c:a", "pcm_s24le", "-ar", "48000", "-ac", "2",
                       "-af", "aresample=48000,apad=whole_len=\(10 * 1920),atrim=end_sample=\(10 * 1920)",
                       "-timecode", "00:00:00:00", "-f", "mxf", "/tmp/out.mxf"]
        let new = ExportPreset.mpeg2_1080p25.ffmpegArguments(
            audioPath: "/tmp/a.caf", outputFrames: 10, layout: .two, output: "/tmp/out.mxf")
        func stripAudio(_ a: [String], oldStyle: Bool) -> [String] {
            var out: [String] = []
            var i = 0
            while i < a.count {
                switch a[i] {
                case "-map" where a[i + 1] != "0:v:0": i += 2
                case "-ac", "-af", "-filter_complex": i += 2
                default: out.append(a[i]); i += 1
                }
            }
            return out
        }
        XCTAssertEqual(stripAudio(new, oldStyle: false), stripAudio(build10, oldStyle: true))
        XCTAssertFalse(new.contains("-ac"))
    }

    // MARK: Audio graph details

    func testNoDeprecatedOrForbiddenOptions() {
        for preset in ExportPreset.builtIn {
            let args = preset.ffmpegArguments(audioPath: "/a", outputFrames: 1, layout: .two, output: "/o")
            XCTAssertFalse(args.contains("-top"), preset.name)
            if preset.codec == .avcIntra100 {
                for forbidden in ["-b:v", "-g", "-preset", "-x264opts", "-r"] {
                    XCTAssertFalse(args.contains(forbidden), "\(preset.name) \(forbidden)")
                }
                XCTAssertEqual(args[args.firstIndex(of: "-avcintra-class")! + 1], "100")
            }
            XCTAssertEqual(args.last, "/o")
            XCTAssertEqual(args[args.firstIndex(of: "-f", after: 10)! + 1], "mxf")
        }
        let p25 = ExportPreset.avcIntra1080p25.ffmpegArguments(audioPath: "/a", outputFrames: 1, layout: .two, output: "/o")
        XCTAssertFalse(p25.contains("-flags"))
    }

    func testGainAndExtraFiltersGoBeforePadding() {
        let args = ExportPreset.avcIntra1080i50.ffmpegArguments(
            audioPath: "/a", outputFrames: 5, layout: .two, gainDB: -4.5,
            audioFilters: ["atrim=start=1:end=3", "afade=t=in:d=0.5"], output: "/o")
        let g = args[args.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(g.hasPrefix("[1:a]aresample=48000,atrim=start=1:end=3,afade=t=in:d=0.5,volume=-4.5dB,apad,atrim=end_sample=9600,asplit=2[s0][s1];"), g)
        let zero = ExportPreset.avcIntra1080i50.ffmpegArguments(
            audioPath: "/a", outputFrames: 5, layout: .two, gainDB: 0, output: "/o")
        XCTAssertFalse(zero.joined(separator: " ").contains("volume="))
    }

    func testEveryTrackIsMonoAndSilentTracksAreZeroed() {
        let args = ExportPreset.avcIntra1080i50.ffmpegArguments(
            audioPath: "/a", outputFrames: 1, layout: .eight, output: "/o")
        let g = args[args.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertEqual(g.components(separatedBy: "pan=mono|").count - 1, 8)
        XCTAssertTrue(g.contains("[s0]pan=mono|c0=c0[t0]"))
        XCTAssertTrue(g.contains("[s1]pan=mono|c0=c1[t1]"))
        for t in 2..<8 { XCTAssertTrue(g.contains("[s\(t)]pan=mono|c0=0*c0[t\(t)]")) }
        XCTAssertEqual(args.filter { $0 == "-map" }.count, 9)
        XCTAssertFalse(args.contains("-ac"))
    }

    func testNegativeFrameCountClampsToZeroSamples() {
        let args = ExportPreset.avcIntra1080p25.ffmpegArguments(
            audioPath: "/a", outputFrames: -3, layout: .two, output: "/o")
        XCTAssertTrue(args.contains { $0.contains("atrim=end_sample=0,") })
    }
}

private extension Array where Element == String {
    func firstIndex(of element: String, after start: Int) -> Int? {
        indices.dropFirst(start).first { self[$0] == element }
    }
}

import Foundation

/// A built-in export format: codec, picture standard and the FFmpeg arguments that encode it.
/// User-editable presets are out of scope, so every preset is a fixed value with a stable ID.
public struct ExportPreset: Sendable, Equatable, Hashable, Identifiable {
    public enum Codec: String, Sendable, Equatable, Hashable {
        case avcIntra100
        case mpeg2_50
    }

    public let id: PresetID
    /// Picker title, for example "AVC-Intra 100 · 1080i50".
    public let name: String
    public let codec: Codec
    public let video: VideoStandard
    /// Not yet proven on the operator's EVS.
    public let isExperimental: Bool
    /// Older format kept for compatibility.
    public let isLegacy: Bool
    /// Video bitrate used for the disk-space preflight, in bits per second.
    public let estimatedVideoBitsPerSecond: Double
    /// One-line note shown under the picker, or nil.
    public let note: String?

    public static let avcIntra1080i50 = ExportPreset(
        id: "avci100-1080i50", name: "AVC-Intra 100 · 1080i50", codec: .avcIntra100, video: .hd1080i50,
        isExperimental: false, isLegacy: false, estimatedVideoBitsPerSecond: 115_000_000, note: nil)
    public static let avcIntra1080p25 = ExportPreset(
        id: "avci100-1080p25", name: "AVC-Intra 100 · 1080p25", codec: .avcIntra100, video: .hd1080p25,
        isExperimental: false, isLegacy: false, estimatedVideoBitsPerSecond: 115_000_000, note: nil)
    public static let avcIntra1080p50 = ExportPreset(
        id: "avci100-1080p50", name: "AVC-Intra 100 · 1080p50 (Experimental)", codec: .avcIntra100,
        video: .hd1080p50, isExperimental: true, isLegacy: false, estimatedVideoBitsPerSecond: 230_000_000,
        note: "Experimental: FFmpeg labels this file as 25p. Test-ingest it on the EVS before relying on it.")
    public static let mpeg2_1080p25 = ExportPreset(
        id: "mpeg2-50-1080p25", name: "MPEG-2 50 Mb/s · 1080p25 (legacy)", codec: .mpeg2_50, video: .hd1080p25,
        isExperimental: false, isLegacy: true, estimatedVideoBitsPerSecond: 50_000_000, note: nil)

    /// All presets in picker order.
    public static let builtIn: [ExportPreset] = [avcIntra1080i50, avcIntra1080p25, avcIntra1080p50, mpeg2_1080p25]
    /// Selected when a job has no (or an unknown) preset.
    public static let `default` = avcIntra1080i50

    /// The preset with this ID, or nil when the ID is unknown.
    public static func preset(for id: PresetID) -> ExportPreset? { builtIn.first { $0.id == id } }

    // MARK: Readout and estimates

    public var codecName: String { codec == .avcIntra100 ? "AVC-Intra 100" : "MPEG-2 50 Mb/s" }

    /// Short toolbar text such as "1080i50 · MXF".
    public var formatReadout: String { "\(video.shortName) · MXF" }

    /// Longer readout for the inspector: codec, picture, bitrate class and audio layout.
    public func detailedReadout(layout: AudioLayout) -> String {
        "\(codecName) · \(video.shortName) · \(Int(estimatedVideoBitsPerSecond / 1_000_000)) Mb/s · \(layout.title)"
    }

    /// Frame rate of the embedded timecode: 25-based except for 1080p50 (0–49).
    public var timecodeRate: Int { video.encodeRate }

    /// Estimated output size for the disk preflight: video plus 24-bit 48 kHz mono tracks,
    /// with 2 % container overhead.
    public func estimatedBytes(duration seconds: Double, layout: AudioLayout) -> Int64 {
        let audioBits = Double(layout.trackCount) * 48_000 * 24
        return Int64((estimatedVideoBitsPerSecond + audioBits) * max(0, seconds) * 1.02 / 8)
    }

    // MARK: FFmpeg

    /// Video filter chain between the raw BGRA input and the encoder.
    var videoFilter: String {
        let colour = "scale=out_color_matrix=bt709:out_range=tv"
        switch codec {
        case .mpeg2_50: return colour + ",setsar=1"
        case .avcIntra100:
            // FFmpeg 8.1 takes the colour description from the frames, not from `-color_primaries`
            // and `-color_trc`, so without `setparams` the H.264 VUI says "unknown" for both.
            let tagged = colour + ",setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            if video.interlaced { return tagged + ",format=yuv422p10le,tinterlace=interleave_top,setfield=tff" }
            return tagged + ",format=yuv422p10le"
        }
    }

    /// The audio filter graph: pad or trim to a whole number of frames, split, and pick a mono
    /// channel for each track (left, right, then digital silence). Output labels are `t0…`.
    func audioGraph(outputFrames: Int, layout: AudioLayout, gainDB: Double, audioFilters: [String]) -> String {
        let samples = max(0, outputFrames) * video.samplesPerFrame
        var chain = ["aresample=48000"]
        chain += audioFilters
        if gainDB != 0 { chain.append("volume=\(Self.number(gainDB))dB") }
        chain += ["apad", "atrim=end_sample=\(samples)"]
        let count = layout.trackCount
        let split = (0..<count).map { "[s\($0)]" }.joined()
        var parts = ["[1:a]" + chain.joined(separator: ",") + ",asplit=\(count)" + split]
        for track in 0..<count {
            let source: String
            switch track {
            case 0: source = "c0=c0"
            case 1: source = "c0=c1"
            default: source = "c0=0*c0"
            }
            parts.append("[s\(track)]pan=mono|\(source)[t\(track)]")
        }
        return parts.joined(separator: ";")
    }

    /// Arguments for the FFmpeg process (without the executable). Video arrives as raw BGRA on
    /// `pipe:0` at the render rate; audio is read from `audioPath`.
    ///
    /// - Parameters:
    ///   - outputFrames: encoded frames in the clip (25 or 50 per second, per the preset).
    ///   - timecode: start timecode; converted to the preset's timecode rate when it differs.
    ///   - gainDB: loudness gain; a `volume=` step is added when non-zero.
    ///   - audioFilters: extra audio filters (trim, fades, pre-roll) inserted before padding.
    public func ffmpegArguments(audioPath: String, outputFrames: Int, layout: AudioLayout,
                                timecode: Timecode = .start, gainDB: Double = 0,
                                audioFilters: [String] = [], output: String) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                    "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", video.sizeString,
                    "-framerate", "\(video.renderRate)", "-i", "pipe:0", "-i", audioPath,
                    "-map", "0:v:0"]
        for track in 0..<layout.trackCount { args += ["-map", "[t\(track)]"] }
        args += ["-map_metadata", "-1", "-vf", videoFilter]
        switch codec {
        case .mpeg2_50:
            args += ["-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "50M",
                     "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792",
                     "-g", "12", "-bf", "2"]
        case .avcIntra100:
            args += ["-c:v", "libx264", "-avcintra-class", "100", "-pix_fmt", "yuv422p10le"]
            if video.interlaced { args += ["-flags", "+ildct+ilme"] }
        }
        args += ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                 "-c:a", "pcm_s24le", "-ar", "48000",
                 "-filter_complex", audioGraph(outputFrames: outputFrames, layout: layout,
                                               gainDB: gainDB, audioFilters: audioFilters),
                 "-timecode", timecode.converted(toFPS: timecodeRate).formatted,
                 "-f", "mxf", output]
        return args
    }

    static func number(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}

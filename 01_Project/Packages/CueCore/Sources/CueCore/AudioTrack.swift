import AVFoundation
import Accelerate

public struct CueError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What one analysis pass learns about a track, in a form a queue job can store and restore
/// without decoding again. `detailPeaks` are the normalised ~5 ms peaks (`AudioTrack.detailPeaks`);
/// they are coded as little-endian Float32 bytes, so a restored track renders bit-identically.
public struct TrackAnalysis: Codable, Sendable, Equatable, Hashable {
    public var seconds: Double
    public var detailPeaks: [Float]
    public var markers: MusicMarkers
    /// Loudest sample before normalisation, linear full scale; 0 when unknown.
    public var absolutePeak: Float

    public init(seconds: Double, detailPeaks: [Float], markers: MusicMarkers, absolutePeak: Float) {
        self.seconds = seconds
        self.detailPeaks = detailPeaks
        self.markers = markers
        self.absolutePeak = absolutePeak
    }

    private enum CodingKeys: String, CodingKey { case seconds, detailPeaks, markers, absolutePeak }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decode(Double.self, forKey: .seconds)
        let bytes = [UInt8](try c.decode(Data.self, forKey: .detailPeaks))
        guard seconds.isFinite, seconds > 0, !bytes.isEmpty, bytes.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .detailPeaks, in: c,
                                                   debugDescription: "Stored waveform peaks are unusable.")
        }
        detailPeaks = stride(from: 0, to: bytes.count, by: 4).map { i in
            Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
        }
        markers = (try? c.decodeIfPresent(MusicMarkers.self, forKey: .markers)) ?? .none
        absolutePeak = (try? c.decodeIfPresent(Float.self, forKey: .absolutePeak)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seconds, forKey: .seconds)
        var bytes = Data(capacity: detailPeaks.count * 4)
        for peak in detailPeaks {
            let bits = peak.bitPattern
            bytes.append(contentsOf: [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF),
                                      UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)])
        }
        try c.encode(bytes, forKey: .detailPeaks)
        try c.encode(markers, forKey: .markers)
        try c.encode(absolutePeak, forKey: .absolutePeak)
    }
}

/// A track's waveform and analysis, plus (once decoded) the 48 kHz PCM that playback and export read.
///
/// A track restored from a stored `TrackAnalysis` has no PCM (`audio == nil`) but draws exactly
/// like the analysed one, so a restored queue job can show its waveform before any decode.
/// When a `JobWorkspace` acquires the job's CAF, `attaching(_:)` gives the playable track.
public struct AudioTrack: Sendable {
    public let url: URL
    /// The decoded PCM, or `nil` for a track restored from stored analysis and not yet decoded.
    public let audio: PreparedAudio?
    public let seconds: Double
    public let detailPeaks: [Float]
    public let peaks: [Float]
    /// Detected music end and fade start (and any operator edits carried along).
    public var markers: MusicMarkers
    /// Loudest sample before normalisation, linear full scale; 0 when unknown.
    public let absolutePeak: Float
    public static let fps = 25
    public var frames: Int { max(1, Int(ceil(seconds * Double(Self.fps) - 1e-8))) }

    /// The decoded PCM. Traps on a restored track that has not been given its audio yet;
    /// check `isDecoded` or use `audio` where that can happen.
    public var pcm: PreparedAudio {
        guard let audio else { preconditionFailure("AudioTrack \(url.lastPathComponent) has no decoded audio yet.") }
        return audio
    }

    public var isDecoded: Bool { audio != nil }

    /// The storable part of this track.
    public var analysis: TrackAnalysis {
        TrackAnalysis(seconds: seconds, detailPeaks: detailPeaks, markers: markers, absolutePeak: absolutePeak)
    }

    public init(url: URL, pcm: PreparedAudio?, seconds: Double, detailPeaks: [Float], peaks: [Float],
                markers: MusicMarkers = .none, absolutePeak: Float = 0) {
        self.url = url
        self.audio = pcm
        self.seconds = seconds
        self.detailPeaks = detailPeaks
        self.peaks = peaks
        self.markers = markers
        self.absolutePeak = absolutePeak
    }

    /// Rebuilds a track from stored analysis without decoding or re-analysing. The overview
    /// peaks are derived exactly as `read` derives them.
    public init(url: URL, analysis: TrackAnalysis, audio: PreparedAudio? = nil) {
        self.init(url: url, pcm: audio, seconds: analysis.seconds, detailPeaks: analysis.detailPeaks,
                  peaks: Self.reducePeaks(analysis.detailPeaks[...], columns: 1600),
                  markers: analysis.markers, absolutePeak: analysis.absolutePeak)
    }

    /// The same track with its decoded PCM (for example from `JobWorkspace.acquire`).
    public func attaching(_ audio: PreparedAudio) -> AudioTrack {
        AudioTrack(url: url, pcm: audio, seconds: seconds, detailPeaks: detailPeaks, peaks: peaks,
                   markers: markers, absolutePeak: absolutePeak)
    }

    /// Decodes `url` to a temporary CAF and analyses it.
    public static func read(_ url: URL, encoder: URL = PreparedAudio.encoder) throws -> AudioTrack {
        try analyse(url, audio: PreparedAudio.decode(url, encoder: encoder))
    }

    /// Analyses already-decoded PCM in one sample pass: waveform peaks, absolute peak and markers.
    /// Each bucket covers its exact fraction of the track. Keep the loudest
    /// channel so out-of-phase stereo still gives the operator a visible cue.
    public static func analyse(_ url: URL, audio pcm: PreparedAudio) throws -> AudioTrack {
        let file = try AVAudioFile(forReading: pcm.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = file.length
        let format = file.processingFormat
        guard length > 0, format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw CueError("This file contains no readable audio.")
        }
        // Retain a peak about every 5 ms so a close-up can resolve quiet
        // transients even when the source runs for hours.
        // Match the export's final edit unit, including its fraction of a frame of silence.
        let samplesPerFrame = Int64(format.sampleRate) / Int64(fps)
        let paddedLength = ((length + samplesPerFrame - 1) / samplesPerFrame) * samplesPerFrame
        let count = min(Int(paddedLength), max(1600, Int(ceil(Double(paddedLength) / format.sampleRate * 200))))
        var peaks = [Float](repeating: 0, count: count)
        var start: Int64 = 0
        while start < length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), length - start)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var offset = 0
            while offset < Int(buffer.frameLength) {
                let at = start + Int64(offset)
                let bucket = min(count - 1, Int(at * Int64(count) / paddedLength))
                let end = (Int64(bucket + 1) * paddedLength + Int64(count - 1)) / Int64(count)
                let n = min(Int(end - at), Int(buffer.frameLength) - offset)
                for channel in 0..<Int(format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel] + offset, 1, &peak, vDSP_Length(n))
                    peaks[bucket] = max(peak, peaks[bucket])
                }
                offset += n
            }
            start += Int64(buffer.frameLength)
        }
        guard start > 0 else { throw CueError("The audio decoder returned no samples.") }
        let seconds = Double(start) / format.sampleRate
        // Music end reads the absolute (dBFS) peaks, before normalisation. Only buckets that begin
        // inside the real samples count; the rest cover the whole-frame padding, which would
        // otherwise read as a short silent tail on a track that plays to its end.
        let bucketSamples = Double(paddedLength) / Double(count)
        let audible = max(1, min(count, Int((Double(start) / bucketSamples - 1e-9).rounded(.up))))
        let markers = MusicEndDetector.detect(peaks: Array(peaks[..<audible]),
                                              bucketSeconds: bucketSamples / format.sampleRate,
                                              duration: seconds)
        let maximum = peaks.max() ?? 0
        if maximum > 0 { peaks = peaks.map { $0 / maximum } }
        let overview = reducePeaks(peaks[...], columns: 1600)
        return AudioTrack(url: url, pcm: pcm, seconds: seconds, detailPeaks: peaks, peaks: overview,
                          markers: markers, absolutePeak: maximum)
    }

    public static func reducePeaks(_ slice: ArraySlice<Float>, columns: Int) -> [Float] {
        guard slice.count > columns else { return Array(slice) }
        return (0..<columns).map { column in
            let first = slice.startIndex + column * slice.count / columns
            let end = slice.startIndex + (column + 1) * slice.count / columns
            return slice[first..<end].max() ?? 0
        }
    }

    public func peaks(in range: Range<Double>, columns: Int) -> [Float] {
        let rate = Double(detailPeaks.count) * Double(Self.fps) / Double(frames)
        let first = min(detailPeaks.count - 1, max(0, Int(floor(range.lowerBound * rate))))
        let end = min(detailPeaks.count, max(first + 1, Int(ceil(range.upperBound * rate))))
        return Self.reducePeaks(detailPeaks[first..<end], columns: columns)
    }

    public static func clock(_ frame: Int) -> String {
        let s = max(0, frame) / fps
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, max(0, frame) % fps)
    }
}

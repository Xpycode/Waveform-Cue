import AVFoundation
import Accelerate

struct CueError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AudioTrack {
    let url: URL
    let pcm: PreparedAudio
    let seconds: Double
    let detailPeaks: [Float]
    let peaks: [Float]
    static let fps = 25
    var frames: Int { max(1, Int(ceil(seconds * Double(Self.fps) - 1e-8))) }

    // Each bucket covers its exact fraction of the track. Keep the loudest
    // channel so out-of-phase stereo still gives the operator a visible cue.
    static func read(_ url: URL, encoder: URL = PreparedAudio.encoder) throws -> AudioTrack {
        let pcm = try PreparedAudio.decode(url, encoder: encoder)
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
        let maximum = peaks.max() ?? 0
        if maximum > 0 { peaks = peaks.map { $0 / maximum } }
        let overview = reducePeaks(peaks[...], columns: 1600)
        return AudioTrack(url: url, pcm: pcm, seconds: Double(start) / format.sampleRate,
                          detailPeaks: peaks, peaks: overview)
    }

    static func reducePeaks(_ slice: ArraySlice<Float>, columns: Int) -> [Float] {
        guard slice.count > columns else { return Array(slice) }
        return (0..<columns).map { column in
            let first = slice.startIndex + column * slice.count / columns
            let end = slice.startIndex + (column + 1) * slice.count / columns
            return slice[first..<end].max() ?? 0
        }
    }

    func peaks(in range: Range<Double>, columns: Int) -> [Float] {
        let rate = Double(detailPeaks.count) * Double(Self.fps) / Double(frames)
        let first = min(detailPeaks.count - 1, max(0, Int(floor(range.lowerBound * rate))))
        let end = min(detailPeaks.count, max(first + 1, Int(ceil(range.upperBound * rate))))
        return Self.reducePeaks(detailPeaks[first..<end], columns: columns)
    }

    static func clock(_ frame: Int) -> String {
        let s = max(0, frame) / fps
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, max(0, frame) % fps)
    }
}

import Foundation

/// Finds where the music stops before a silent tail, from absolute bucket peaks.
/// Pure function; the caller supplies the ~5 ms peaks `AudioTrack` produces before normalisation.
public enum MusicEndDetector {
    /// Absolute level (dBFS) a bucket must exceed to count as music.
    public static let musicThresholdDB: Double = -60
    /// The fade start uses this many dB below the track's peak.
    public static let fadeBelowPeakDB: Double = 40
    /// A run must stay above the threshold at least this long; shorter blips (clicks) are ignored.
    public static let minRunSeconds: Double = 0.050

    /// - Parameters:
    ///   - peaks: linear absolute peaks (0...1 full scale), one per bucket.
    ///   - bucketSeconds: bucket length in seconds.
    ///   - duration: track length in seconds; results are clamped to `0...duration`.
    public static func detect(peaks: [Float], bucketSeconds: Double, duration: Double) -> MusicMarkers {
        guard !peaks.isEmpty, bucketSeconds > 0, duration > 0 else { return .silent }
        let peak = peaks.max() ?? 0
        let musicLevel = Float(pow(10, musicThresholdDB / 20))
        guard peak > musicLevel else { return .silent }
        let fadeLevel = Float(pow(10, (20 * log10(Double(peak)) - fadeBelowPeakDB) / 20))

        // Round up to whole buckets; a track shorter than one run qualifies using all it has.
        let wanted = max(1, Int((minRunSeconds / bucketSeconds - 1e-9).rounded(.up)))
        let minRun = min(wanted, peaks.count)

        guard let musicEnd = endOfLastRun(peaks, above: musicLevel, minRun: minRun,
                                          bucketSeconds: bucketSeconds, duration: duration)
        else { return .silent }
        let fade = endOfLastRun(peaks, above: fadeLevel, minRun: minRun,
                                bucketSeconds: bucketSeconds, duration: duration) ?? musicEnd
        return MusicMarkers(detectedMusicEnd: musicEnd, detectedFadeStart: min(fade, musicEnd))
    }

    private static func endOfLastRun(_ peaks: [Float], above level: Float, minRun: Int,
                                     bucketSeconds: Double, duration: Double) -> Double? {
        var i = peaks.count - 1
        while i >= 0 {
            if peaks[i] > level {
                var j = i
                while j >= 0, peaks[j] > level { j -= 1 }
                if i - j >= minRun {
                    // A run touching the final bucket means no silent tail: music lasts to the file end.
                    if i == peaks.count - 1 { return duration }
                    return min(max(Double(i + 1) * bucketSeconds, 0), duration)
                }
                i = j
            } else {
                i -= 1
            }
        }
        return nil
    }
}

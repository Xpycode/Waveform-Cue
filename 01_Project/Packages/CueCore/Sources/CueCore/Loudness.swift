import Foundation

/// EBU R 128 measurement through FFmpeg's `ebur128` filter: command line, summary parsing,
/// the compliance badge rule and the normalisation gain rule. Pure logic; no process is run here.
public enum Loudness: Sendable {
    /// Broadcast target for integrated loudness, in LUFS.
    public static let targetLUFS = -23.0
    /// Allowed deviation from the target, in LU (inclusive).
    public static let toleranceLU = 1.0
    /// Maximum permitted true peak, in dBTP (inclusive).
    public static let maxTruePeakDBTP = -1.0
    /// `ebur128` prints this for digital silence (nothing passes its absolute gate).
    static let silenceFloorLUFS = -70.0

    /// FFmpeg arguments that print the loudness summary on stderr and discard the audio.
    public static func arguments(input: String) -> [String] {
        ["-hide_banner", "-nostdin", "-nostats", "-i", input,
         "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"]
    }

    /// Parses the text after the last `Summary:` line. Returns `nil` when no usable summary is
    /// found. Silence becomes `nil` in the matching field: a `-inf` value, or integrated
    /// loudness at the -70 LUFS floor (real FFmpeg 8.1 prints `I: -70.0` with `Peak: -inf`).
    public static func parse(stderr: String) -> LoudnessMeasurement? {
        guard let marker = stderr.range(of: "Summary:", options: .backwards) else { return nil }
        var integrated: Value?
        var lra: Value?
        var peak: Value?
        var inTruePeak = false
        for rawLine in stderr[marker.upperBound...].split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("True peak:") { inTruePeak = true; continue }
            if line.hasPrefix("Sample peak:") { inTruePeak = false; continue }
            if integrated == nil, line.hasPrefix("I:") { integrated = value(line, "I:") }
            else if lra == nil, line.hasPrefix("LRA:") { lra = value(line, "LRA:") }
            else if inTruePeak, peak == nil, line.hasPrefix("Peak:") { peak = value(line, "Peak:") }
        }
        guard let integrated, let peak, case .number(let range)? = lra else { return nil }
        var lufs: Double?
        if case .number(let v) = integrated, v > silenceFloorLUFS { lufs = v }
        var dbtp: Double?
        if case .number(let v) = peak { dbtp = v }
        return LoudnessMeasurement(integratedLUFS: lufs, truePeakDBTP: dbtp, rangeLU: range)
    }

    /// Badge rule: flagged when integrated loudness is outside -23 +/- 1 LUFS (bounds
    /// inclusive) or the true peak is above -1 dBTP. A silent clip is flagged (not at target).
    public static func isFlagged(_ m: LoudnessMeasurement) -> Bool {
        guard let lufs = m.integratedLUFS else { return true }
        if abs(lufs - targetLUFS) > toleranceLU { return true }
        if let tp = m.truePeakDBTP, tp > maxTruePeakDBTP { return true }
        return false
    }

    /// Gain to reach -23 LUFS without the true peak exceeding -1 dBTP:
    /// `gain = min(-23 - I, -1 - TP)`, `achieved = I + gain`. `limitedByPeak` is true when the
    /// peak limit, not the loudness target, set the gain. Silence has nothing to normalise:
    /// zero gain, `achievedLUFS == -.infinity`, `limitedByPeak == false`.
    public static func normalisation(for m: LoudnessMeasurement)
        -> (gainDB: Double, achievedLUFS: Double, limitedByPeak: Bool) {
        guard let lufs = m.integratedLUFS else { return (0, -.infinity, false) }
        let loudnessGain = targetLUFS - lufs
        guard let tp = m.truePeakDBTP else { return (loudnessGain, targetLUFS, false) }
        let peakGain = maxTruePeakDBTP - tp
        let limited = peakGain < loudnessGain
        let gain = limited ? peakGain : loudnessGain
        return (gain, lufs + gain, limited)
    }

    private enum Value { case number(Double), negativeInfinity }

    private static func value(_ line: String, _ label: String) -> Value? {
        let rest = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        guard let token = rest.split(separator: " ").first else { return nil }
        if token == "-inf" { return .negativeInfinity }
        guard let v = Double(token), v.isFinite else { return nil }
        return .number(v)
    }
}

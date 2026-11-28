import Foundation

// Editing rules for the Job tab's Trim section and the I and O keys (task 5.1), and the
// mapping between preview positions and source time the app's playback uses. Kept here so the
// rules test headlessly; `ClipTimeline` stays the single source of the position mapping.

extension TrimSettings {
    /// The in point set to `seconds` (I key, or the In field). Clamped inside the source; the
    /// source start clears it. An in point at or after the out point clears the out point, as
    /// in an NLE.
    public func settingIn(_ seconds: Double?, duration: Double) -> TrimSettings {
        var trim = self
        guard let value = Self.clamped(seconds, duration: duration), value > Self.tolerance else {
            trim.inPoint = nil
            return trim
        }
        trim.inPoint = value
        if let out = trim.outPoint, out <= value + Self.tolerance { trim.outPoint = nil }
        return trim
    }

    /// The out point set to `seconds` (O key, or the Out field). Clamped inside the source; the
    /// source end clears it. An out point at or before the in point clears the in point.
    public func settingOut(_ seconds: Double?, duration: Double) -> TrimSettings {
        var trim = self
        guard let value = Self.clamped(seconds, duration: duration),
              value < duration - Self.tolerance else {
            trim.outPoint = nil
            return trim
        }
        trim.outPoint = value
        if let start = trim.inPoint, start >= value - Self.tolerance { trim.inPoint = nil }
        return trim
    }

    static let tolerance = 1e-6

    private static func clamped(_ seconds: Double?, duration: Double) -> Double? {
        guard let seconds, seconds.isFinite else { return nil }
        let duration = duration.isFinite ? max(0, duration) : 0
        return min(duration, max(0, seconds))
    }
}

extension ClipTimeline {
    /// Source time shown at a preview position: the in point during the slate.
    public func sourceSeconds(at position: Int) -> Double {
        switch self.position(at: position) {
        case .slate: return sourceRange.lowerBound
        case .music(let seconds, _): return seconds
        }
    }

    /// The first position showing source time `seconds`, clamped into the trimmed range: the
    /// first music position at or before the in point, `positionCount` at or after the out point.
    public func position(ofSourceSeconds seconds: Double) -> Int {
        guard seconds.isFinite else { return preRollPositions }
        let offset = min(sourceRange.upperBound, max(sourceRange.lowerBound, seconds)) - sourceRange.lowerBound
        if offset >= musicDuration - TrimSettings.tolerance, musicDuration > 0 { return positionCount }
        let frame = Int((offset * Double(Self.clockRate) + TrimSettings.tolerance).rounded(.down))
        return position(ofClockFrame: frame)
    }

    /// The position is on the pre-roll slate.
    public func isSlate(_ position: Int) -> Bool {
        if case .slate = self.position(at: position) { return true }
        return false
    }
}

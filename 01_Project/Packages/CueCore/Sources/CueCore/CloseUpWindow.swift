public enum PlayheadMode: String, Codable, CaseIterable, Sendable {
    case edgeHeld, centered
}

public enum EndZoom: Int, Codable, CaseIterable, Sendable {
    case off = 0, two = 2, three = 3, five = 5
}

public struct CloseUpWindow: Equatable, Sendable {
    /// Window in source seconds, including any blank space beyond the trimmed clip.
    public let visible: ClosedRange<Double>
    /// Portion of the visible window containing the clip, for the overview highlight.
    public let intersection: ClosedRange<Double>

    /// All values use source seconds. A field playhead may extend into the padded final clock
    /// frame. Supply the actual trimmed clip bounds and the selected fixed width even for a shorter clip.
    /// For Auto, supply the resolved width on the timeline's 25-frame clock base.
    public static func interval(playhead: Double, clip: ClosedRange<Double>, target: Double,
                                startingWidth: Double, mode: PlayheadMode, endZoom: EndZoom) -> CloseUpWindow {
        interval(playhead: playhead, clip: clip, target: target, startingWidth: startingWidth,
                 centerAtStart: mode == .centered, centerAtEnd: mode == .centered, endZoom: endZoom)
    }

    public static func interval(playhead: Double, clip: ClosedRange<Double>, target: Double,
                                startingWidth: Double, centerAtStart: Bool, centerAtEnd: Bool,
                                endZoom: EndZoom) -> CloseUpWindow {
        // The picture timeline rounds partial last frames up. Only the highlight and source
        // sampling stop at the exact trim boundary.
        let rate = Double(ClipTimeline.clockRate)
        let frames = ClipTimeline.wholeFrames(clip.upperBound - clip.lowerBound, rate: ClipTimeline.clockRate)
        let clockDuration = Double(frames) / rate
        let clockEnd = clip.lowerBound + clockDuration
        let time = min(max(playhead, clip.lowerBound), clockEnd)
        let targetTime = min(max(target, clip.lowerBound), clockEnd)
        let requested = max(0, startingWidth)
        let initial = centerAtStart && centerAtEnd ? requested : min(requested, clockDuration)
        let final = endZoom == .off ? initial : min(initial, Double(endZoom.rawValue))
        let progress = min(1, max(0, 1 + 0.75 * final - (targetTime - time)))
        let ease = final < initial ? progress * progress * (3 - 2 * progress) : 0
        let width = initial + (final - initial) * ease

        let visible: ClosedRange<Double>
        if centerAtEnd {
            let left = centerAtStart ? time - width / 2 : max(clip.lowerBound, time - width / 2)
            visible = left...(left + width)
        } else {
            // Build 11 puts the odd frame on the right (e.g. 62 left, 63 right for 5 s).
            let halfFrames = ((initial * rate).rounded() / 2).rounded(.down)
            let centered = time - halfFrames / rate
            let original = min(centerAtStart ? centered : max(clip.lowerBound, centered), clockEnd - initial)

            // The final window ends on the target, then travels with the playhead through a tail.
            let anchor = max(targetTime, time)
            let destination = min(max(clip.lowerBound, anchor - final), clockEnd - final)
            let lower = original + (destination - original) * ease
            // A target close to trim-in can already be easing at the first frame. Keep the
            // cursor inside as the two edges interpolate, preserving the interpolated width.
            let left = centerAtStart ? min(time, lower) : max(clip.lowerBound, min(time, lower))
            visible = left...min(clockEnd, max(time, left + width))
        }
        return CloseUpWindow(visible: visible, intersection: visible.clamped(to: clip))
    }
}

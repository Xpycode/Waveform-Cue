import CoreGraphics

/// Whole-pixel offsets for the visible extents of a fitting automatic layout.
/// Supply spans in picture order (top first) in Core Graphics coordinates (positive Y is up).
/// Automatic spans must already have the minimum gap. Pixel rounding during automatic placement
/// may leave an extent half a pixel past a frame edge. That pane can stay there or move inward.
public enum OffsetResolver {
    /// A downward request from the upper pane has first use of a shared gap when neighbours
    /// move toward each other. Panes moving in the same direction can use space their neighbour
    /// vacates, so a set of requests that already fits survives both passes unchanged.
    public static func resolve(stored: [Int], spans: [ClosedRange<CGFloat>],
                               frame: ClosedRange<CGFloat>, gap: CGFloat) -> [Int] {
        precondition(stored.count == spans.count)
        var inUse = Array(repeating: 0, count: spans.count)
        for index in spans.indices.reversed() where stored[index] < 0 {
            let range = limits(index: index, inUse: inUse, spans: spans, frame: frame, gap: gap)
            inUse[index] = max(stored[index], range.lowerBound)
        }
        for index in spans.indices where stored[index] > 0 {
            let range = limits(index: index, inUse: inUse, spans: spans, frame: frame, gap: gap)
            inUse[index] = min(stored[index], range.upperBound)
        }
        return inUse
    }

    /// Inclusive offsets for this pane while every other pane stays at its current, feasible
    /// offset. A fraction of a free pixel cannot accommodate a whole-pixel step.
    public static func limits(index: Int, inUse: [Int], spans: [ClosedRange<CGFloat>],
                              frame: ClosedRange<CGFloat>, gap: CGFloat) -> ClosedRange<Int> {
        precondition(spans.count == inUse.count && spans.indices.contains(index))
        let span = spans[index]
        var low = min(0, Int((frame.lowerBound - span.lowerBound).rounded(.up)))
        var high = max(0, Int((frame.upperBound - span.upperBound).rounded(.down)))
        if index > 0 {
            let slack = spans[index - 1].lowerBound - span.upperBound - gap
            high = min(high, inUse[index - 1] + Int(slack.rounded(.down)))
        }
        if index + 1 < spans.count {
            let slack = span.lowerBound - spans[index + 1].upperBound - gap
            low = max(low, inUse[index + 1] - Int(slack.rounded(.down)))
        }
        return low...high
    }
}

import Foundation

// `VideoStandard` cannot conform to `TimelineRateProviding` directly: both declare `encodeRate`,
// but with different meanings. The standard's `encodeRate` is MXF frames per second (25 for
// 1080i50), while the timeline's is rendered images per second (50 for 1080i50 fields). A
// conformance would silently pick the standard's 25 and render 1080i50 at 25 images per second.
// This bridge maps the standard's render rate onto the timeline's `encodeRate` instead.

extension VideoStandard {
    /// The timeline rate for this standard: images rendered per second and 48 kHz samples per
    /// MXF frame. 1080i50 gives `.fields50` (50, 1920), 1080p25 `.fps25`, 1080p50 `.fps50`.
    public var timelineRate: TimelineRate {
        TimelineRate(encodeRate: renderRate, samplesPerFrame: samplesPerFrame)
    }
}

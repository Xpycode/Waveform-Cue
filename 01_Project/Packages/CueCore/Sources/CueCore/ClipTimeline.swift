import Foundation

// One mapping from output position to slate or source time (spec E, "Trim and pre-roll in the
// timeline"). The renderer, the clocks, the markers and the audio filter chain all read it, so
// preview and export cannot drift.
//
// Three time bases meet here:
// - output frames: MXF edit units (25 for 1080i50 and 1080p25, 50 for 1080p50);
// - output positions: rendered images (50 per second for 1080i50 fields and 1080p50 frames);
// - the clock base: always 25 (decision 2), the unit of `AudioTrack.clock` and the appearance
//   thresholds.

// MARK: - Rate

/// What the timeline needs from a video standard. `VideoStandard` (task 1.1) can conform by
/// supplying these two values.
public protocol TimelineRateProviding {
    /// Images rendered per second: 25 for 1080p25, 50 for 1080i50 (fields) and 1080p50.
    var encodeRate: Int { get }
    /// 48 kHz samples per output frame (MXF edit unit): 1920 at 25 fps, 960 at 50 fps.
    var samplesPerFrame: Int { get }
}

/// A plain rate value, for tests and for callers that do not hold a `VideoStandard`.
public struct TimelineRate: TimelineRateProviding, Sendable, Equatable, Hashable {
    public var encodeRate: Int
    public var samplesPerFrame: Int

    public init(encodeRate: Int, samplesPerFrame: Int) {
        self.encodeRate = encodeRate
        self.samplesPerFrame = samplesPerFrame
    }

    public init(_ standard: some TimelineRateProviding) {
        self.init(encodeRate: standard.encodeRate, samplesPerFrame: standard.samplesPerFrame)
    }

    /// 1080p25 and build 10's MPEG-2: 25 images and 25 frames per second.
    public static let fps25 = TimelineRate(encodeRate: 25, samplesPerFrame: 1920)
    /// 1080i50: 50 field images per second, woven into 25 frames per second.
    public static let fields50 = TimelineRate(encodeRate: 50, samplesPerFrame: 1920)
    /// 1080p50: 50 images and 50 frames per second.
    public static let fps50 = TimelineRate(encodeRate: 50, samplesPerFrame: 960)
}

// MARK: - Timeline

public struct ClipTimeline: Sendable, Equatable, Hashable {
    public static let sampleRate = 48_000
    /// Display clock base (decision 2): `AudioTrack.fps`.
    public static let clockRate = AudioTrack.fps
    /// Shortest trimmed range the queue will start.
    public static let minimumTrimSeconds = 1.0
    public static let trimTooShortMessage = "Trim range too short"

    /// Tolerance used by build 10's `AudioTrack.frames` so an exact whole frame is not
    /// rounded up by floating-point noise.
    static let epsilon = 1e-8

    // Inputs
    public let duration: Double
    public let trim: TrimSettings
    public let markers: MusicMarkers
    public let target: CountdownTarget
    public let rate: TimelineRate

    // Derived
    /// The trimmed range in source seconds, clamped inside the source.
    public let sourceRange: ClosedRange<Double>
    /// Images per second rendered (25 or 50).
    public let positionRate: Int
    /// Output frames per second (48000 / samplesPerFrame).
    public let frameRate: Int
    /// Rendered images per output frame (1, or 2 for 1080i50 fields).
    public let positionsPerFrame: Int
    /// Pre-roll in whole output frames. Music starts exactly on this frame, so its timecode can
    /// be the job's start timecode.
    public let preRollFrames: Int
    /// The trimmed music in output frames, rounded up to a whole frame (at least one).
    public let musicFrames: Int
    /// The trimmed music on the 25 clock base; equals build 10's `AudioTrack.frames` when
    /// there is no trim.
    public let clockFrames: Int
    /// The countdown target on the 25 clock base, measured from the first music frame.
    public let targetClockFrames: Int

    public init(duration: Double, trim: TrimSettings = .none, markers: MusicMarkers = .none,
                target: CountdownTarget = .fileEnd, standard: some TimelineRateProviding = TimelineRate.fps25) {
        let duration = duration.isFinite ? max(0, duration) : 0
        self.duration = duration
        self.trim = trim
        self.markers = markers
        self.target = target
        let rate = TimelineRate(standard)
        self.rate = rate

        let samplesPerFrame = max(1, rate.samplesPerFrame)
        let frameRate = max(1, Self.sampleRate / samplesPerFrame)
        let positionRate = max(1, rate.encodeRate)
        self.frameRate = frameRate
        self.positionRate = positionRate
        self.positionsPerFrame = max(1, positionRate / frameRate)

        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let lower = min(duration, max(0, finite(trim.inPoint) ?? 0))
        let upper = min(duration, max(lower, finite(trim.outPoint) ?? duration))
        sourceRange = lower...upper
        let length = upper - lower

        let preRoll = trim.preRoll.isFinite ? max(0, trim.preRoll) : 0
        preRollFrames = Int((preRoll * Double(frameRate)).rounded())
        musicFrames = Self.wholeFrames(length, rate: frameRate)
        clockFrames = Self.wholeFrames(length, rate: Self.clockRate)

        if target == .musicEnd, let end = finite(markers.musicEnd) {
            let inRange = min(length, max(0, end - lower))
            targetClockFrames = min(clockFrames, max(0, Int(ceil(inRange * Double(Self.clockRate) - Self.epsilon))))
        } else {
            targetClockFrames = clockFrames
        }
    }

    /// Build 10's rounding: at least one frame, a fraction of a frame rounds up.
    static func wholeFrames(_ seconds: Double, rate: Int) -> Int {
        max(1, Int(ceil(seconds * Double(rate) - epsilon)))
    }

    // MARK: Lengths

    /// Length of the trimmed range in seconds.
    public var musicDuration: Double { sourceRange.upperBound - sourceRange.lowerBound }
    /// Output frames in the file: pre-roll first, then the trimmed range.
    public var outputFrames: Int { preRollFrames + musicFrames }
    /// Images to render: `outputFrames × positionsPerFrame`.
    public var positionCount: Int { outputFrames * positionsPerFrame }
    /// Rendered images that belong to the slate.
    public var preRollPositions: Int { preRollFrames * positionsPerFrame }
    public var samplesPerFrame: Int { max(1, rate.samplesPerFrame) }
    /// Total samples per audio track, a whole number of output frames.
    public var totalSamples: Int { outputFrames * samplesPerFrame }
    /// Silence in front of the music, in samples.
    public var preRollSamples: Int { preRollFrames * samplesPerFrame }
    /// Clip length in seconds, including the whole-frame padding.
    public var outputSeconds: Double { Double(totalSamples) / Double(Self.sampleRate) }
    /// No trim and no pre-roll: the clip is the whole source, as in build 10.
    public var isIdentity: Bool { !isTrimmed && preRollFrames == 0 && trim.fadeIn == 0 && trim.fadeOut == 0 }
    /// True when the in or out point actually cuts the source.
    public var isTrimmed: Bool {
        sourceRange.lowerBound > Self.epsilon || sourceRange.upperBound < duration - Self.epsilon
    }

    // MARK: Position

    public enum Position: Sendable, Equatable, Hashable {
        /// Pre-roll slate. `startsIn` counts 25-base frames to the first music frame (rounded
        /// up, so it never reads zero while the slate is up).
        case slate(startsIn: Int)
        /// Music. `sourceSeconds` is source time; `clockFrame` is elapsed on the 25 base,
        /// clamped to `0...clockFrames`.
        case music(sourceSeconds: Double, clockFrame: Int)
    }

    /// Clamps a rendered position the way `CuePicture.draw` clamps a frame today: below zero is
    /// zero, and the end position (`positionCount`) is allowed for a preview playhead at the end.
    func clamp(_ position: Int) -> Int { min(positionCount, max(0, position)) }

    /// Music positions from the first music image; negative during the slate.
    func musicOffset(_ position: Int) -> Int { clamp(position) - preRollPositions }

    public func position(at position: Int) -> Position {
        let offset = musicOffset(position)
        if offset < 0 {
            let startsIn = (-offset * Self.clockRate + positionRate - 1) / positionRate
            return .slate(startsIn: startsIn)
        }
        let seconds = min(sourceRange.upperBound, sourceRange.lowerBound + Double(offset) / Double(positionRate))
        return .music(sourceSeconds: seconds, clockFrame: clockFrame(offset: offset))
    }

    func clockFrame(offset: Int) -> Int {
        min(clockFrames, max(0, offset * Self.clockRate / positionRate))
    }

    /// The rendered position of a 25-base clock frame within the music (inverse of
    /// `clocks(at:).elapsed`, the first image showing that frame).
    public func position(ofClockFrame frame: Int) -> Int {
        let frame = min(clockFrames, max(0, frame))
        return preRollPositions + (frame * positionRate + Self.clockRate - 1) / Self.clockRate
    }

    // MARK: Clocks

    public struct Clocks: Sendable, Equatable, Hashable {
        /// Elapsed on the 25 base; 0 during the slate and on the first music frame.
        public var elapsed: Int
        /// Remaining to the countdown target on the 25 base; holds at 0 after the target.
        public var remaining: Int
        /// Remaining to the end of the trimmed music, whatever the target.
        public var toFileEnd: Int
        /// The slate is showing; the "Starts in" value is `startsIn`.
        public var isSlate: Bool
        /// 25-base frames until the first music frame; 0 once music plays.
        public var startsIn: Int
        /// The playhead is at or past a music-end target before the file end (Remaining shows
        /// 00:00:00 in red).
        public var isPastTarget: Bool

        public var elapsedText: String { AudioTrack.clock(elapsed) }
        public var remainingText: String { AudioTrack.clock(remaining) }
    }

    public func clocks(at position: Int) -> Clocks {
        let offset = musicOffset(position)
        if offset < 0 {
            let startsIn = (-offset * Self.clockRate + positionRate - 1) / positionRate
            return Clocks(elapsed: 0, remaining: targetClockFrames, toFileEnd: clockFrames,
                          isSlate: true, startsIn: startsIn, isPastTarget: false)
        }
        let elapsed = clockFrame(offset: offset)
        let remaining = max(0, targetClockFrames - elapsed)
        return Clocks(elapsed: elapsed, remaining: remaining, toFileEnd: clockFrames - elapsed,
                      isSlate: false, startsIn: 0,
                      isPastTarget: targetClockFrames < clockFrames && remaining == 0)
    }

    // MARK: Markers

    /// A marker inside the trimmed range: seconds from the in point and its 25-base frame.
    public struct Marker: Sendable, Equatable, Hashable {
        public var seconds: Double
        public var clockFrame: Int
    }

    func marker(_ source: Double?) -> Marker? {
        guard let source, source.isFinite, sourceRange.contains(source) else { return nil }
        let seconds = source - sourceRange.lowerBound
        let frame = min(clockFrames, max(0, Int((seconds * Double(Self.clockRate)).rounded())))
        return Marker(seconds: seconds, clockFrame: frame)
    }

    /// The music-end marker relative to the trimmed range, or nil when unset or cut away.
    public var musicEndMarker: Marker? { marker(markers.musicEnd) }
    /// The fade-start marker relative to the trimmed range, or nil when unset or cut away.
    public var fadeStartMarker: Marker? { marker(markers.fadeStart) }

    // MARK: Audio

    /// FFmpeg filters for the 48 kHz source audio, in order, to join with commas. The chain
    /// starts with `aresample=48000` and ends on a whole output frame, so the caller adds
    /// only the track split. With no trim, fades or pre-roll it equals build 10's `-af`.
    public func audioFilters() -> [String] {
        let rate = Self.sampleRate
        var filters = ["aresample=\(rate)"]
        let first = Int((sourceRange.lowerBound * Double(rate)).rounded())
        let last = Int((sourceRange.upperBound * Double(rate)).rounded())
        let length = max(0, last - first)
        if isTrimmed {
            var cut = "atrim=start_sample=\(first)"
            if sourceRange.upperBound < duration - Self.epsilon { cut += ":end_sample=\(last)" }
            filters += [cut, "asetpts=PTS-STARTPTS"]
        }
        let fadeIn = min(length, Self.samples(trim.fadeIn))
        if fadeIn > 0 { filters.append("afade=t=in:start_sample=0:nb_samples=\(fadeIn)") }
        let fadeOut = min(length, Self.samples(trim.fadeOut))
        if fadeOut > 0 { filters.append("afade=t=out:start_sample=\(length - fadeOut):nb_samples=\(fadeOut)") }
        if preRollSamples > 0 { filters.append("adelay=delays=\(preRollSamples)S:all=1") }
        filters += ["apad=whole_len=\(totalSamples)", "atrim=end_sample=\(totalSamples)"]
        return filters
    }

    /// `audioFilters()` joined for `-af` or a filter graph.
    public var audioFilterChain: String { audioFilters().joined(separator: ",") }

    static func samples(_ seconds: Double) -> Int {
        seconds.isFinite ? max(0, Int((seconds * Double(sampleRate)).rounded())) : 0
    }

    // MARK: Validation

    /// Fails with "Trim range too short" when the in and out points leave under one second.
    /// An untrimmed source of any length passes, as in build 10.
    public func validate() throws {
        if isTrimmed && musicDuration < Self.minimumTrimSeconds - Self.epsilon {
            throw CueError(Self.trimTooShortMessage)
        }
    }
}

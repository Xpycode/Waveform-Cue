import CoreGraphics

/// Geometry of one 1920 × 1080 cue picture, computed from the zoom window, the clock sizes, the
/// clock position and the safe zones (spec F). Pure arithmetic: no fonts are loaded and nothing is
/// drawn, so the preview, the export, hit-testing and the guides can share one value.
///
/// Coordinates are Core Graphics picture points with a bottom-left origin, like `CuePicture`.
///
/// With safe zones None and clocks below, every value equals the constants `CuePicture` used in
/// build 10. Otherwise the elements form one vertical stack (title band, full track, close-up and
/// clocks, in picture order) that first moves within the free margins and, when it cannot fit
/// between the reserved bands, gives way in this order:
///   1. with clocks below, the gap above the clocks shrinks to its minimum,
///   2. the close-up and full-track waveform heights shrink,
///   3. the remaining gaps between groups shrink,
///   4. the clocks step down a size (never below Small),
///   5. the title shrinks (never below 34 pt),
/// after which `fits` is false. Clocks also step down when the pair is wider than the content
/// column (wide left and right reserves); waveforms and gaps cannot help there.
///
/// Every element's extent includes its text above and below (labels, tick labels, clock labels),
/// its cursor overhang and its title shadow, so no drawn pixel falls inside a reserved band.
public struct CueLayout: Sendable, Equatable {

    // MARK: Constants (build 10 geometry and text extents)

    public enum Metrics {
        public static let picture = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Build 10 rectangles and positions.
        public static let naturalOverview = CGRect(x: 96, y: 742, width: 1728, height: 100)
        public static let naturalDetail = CGRect(x: 96, y: 361, width: 1728, height: 265)
        public static let naturalClockBaseline: CGFloat = 100
        /// Left and right content margin: waveforms, clocks and title travel start here.
        public static let sideMargin: CGFloat = 96
        /// Title travel inset from the top and bottom picture edges.
        public static let titleInset: CGFloat = 55

        // Offsets the renderer draws relative to the rectangles.
        public static let overviewLabelOffset: CGFloat = 18   // "Full track" and duration, above overview
        public static let overviewLabelSize: CGFloat = 26
        public static let overviewDurationSize: CGFloat = 25  // Menlo
        public static let detailLabelOffset: CGFloat = 20     // "Close-up", above detail
        public static let detailLabelSize: CGFloat = 26
        public static let tickLabelOffset: CGFloat = 37       // tick labels, below detail
        public static let tickLabelSize: CGFloat = 26          // Menlo
        public static let cursorTriangleRise: CGFloat = 14    // close-up cursor triangle, above detail
        public static let cursorOverhang: CGFloat = 3         // cursor bar, beyond both waveforms
        public static let cursorTriangleHalfWidth: CGFloat = 11
        public static let clockLabelSize: CGFloat = 28
        public static let clockLabelRise: CGFloat = 0.77      // × clock points
        public static let clockLabelGap: CGFloat = 26
        public static let titleNaturalSize: CGFloat = 48
        public static let titleMinimumSize: CGFloat = 34
        public static let titleBoxPadding: CGFloat = 22       // box height = size + 22
        public static let titleBaselineInset: CGFloat = 17    // baseline = box.minY + 17
        public static let titleShadowSpread: CGFloat = 3
        public static let clockCharacters = 8                 // "MM:SS:FF"

        // Glyph extents as fractions of the point size, measured with CoreText (glyph path
        // bounds) and rounded up. `CueLayoutTests` re-measures them so font drift is caught.
        /// Helvetica Neue Medium labels: highest glyph top 0.731 ("Close-up").
        public static let labelAscent: CGFloat = 0.75
        /// Helvetica Neue Medium labels: lowest descender −0.205 ("Remaining").
        public static let labelDescent: CGFloat = 0.22
        /// Menlo digits and colons: top 0.742, bottom −0.014.
        public static let digitAscent: CGFloat = 0.75
        public static let digitDescent: CGFloat = 0.02
        /// Menlo advance per character (0.602).
        public static let monoAdvance: CGFloat = 0.6025
        /// Anti-aliasing allowance added to every text extent.
        public static let antialias: CGFloat = 1

        // Give-way limits.
        public static let minimumDetailHeight: CGFloat = 150
        public static let minimumOverviewHeight: CGFloat = 60
        /// Full-track height floor with zoom Off, where it also takes the close-up's place.
        public static let minimumOverviewOffHeight: CGFloat = 210
        public static let minimumGap: CGFloat = 12
        /// Clear space kept between any element and a reserved band.
        public static let bandPadding: CGFloat = 12
        /// Minimum space between the Elapsed and Remaining clocks.
        public static let clockPairGap: CGFloat = 24

        /// Extent below the detail rectangle (tick labels, cursor bar).
        static let detailBelow = max(cursorOverhang, tickLabelOffset + tickLabelSize * digitDescent + antialias)
        /// Extent above the detail rectangle ("Close-up" label, cursor triangle).
        static let detailAbove = max(cursorTriangleRise, detailLabelOffset + detailLabelSize * labelAscent + antialias)
        /// Extent below the overview rectangle (cursor bar).
        static let overviewBelow = cursorOverhang
        /// Extent above the overview rectangle ("Full track" label and duration).
        static let overviewAbove = max(cursorOverhang, overviewLabelOffset
            + max(overviewLabelSize * labelAscent, overviewDurationSize * digitAscent) + antialias)
    }

    // MARK: Inputs

    // `ZoomWindow` and `ClockSize` are not declared Sendable yet, so their raw values are stored.
    private let zoomRaw: Int
    private let requestedRaw: [String]
    private let sizeRaw: [String]

    public var zoom: ZoomWindow { ZoomWindow(rawValue: zoomRaw)! }
    public let clockPosition: ClockPosition
    public let insets: SafeZones.Insets
    /// The clock sizes the appearance asked for, before any give-way.
    public var requestedElapsedSize: ClockSize { ClockSize(rawValue: requestedRaw[0])! }
    public var requestedRemainingSize: ClockSize { ClockSize(rawValue: requestedRaw[1])! }

    // MARK: Results

    /// Reserved bands in picture points, rounded outward to whole pixels; empty bands are left out.
    public let reserved: [CGRect]
    /// The picture minus the reserved bands.
    public let usable: CGRect
    /// The frame every element stays inside: `usable` less the band padding, never closer to the
    /// picture edges than the build 10 margins (96 px sides, 55 px top and bottom).
    public let safeFrame: CGRect
    /// Full-track waveform rectangle (zoom Off: the combined full-track area).
    public let overview: CGRect
    /// Close-up waveform rectangle; `nil` with zoom Off.
    public let detail: CGRect?
    /// Baseline shared by the Elapsed and Remaining digits.
    public let clockBaseline: CGFloat
    /// Clock sizes after give-way.
    public var elapsedSize: ClockSize { ClockSize(rawValue: sizeRaw[0])! }
    public var remainingSize: ClockSize { ClockSize(rawValue: sizeRaw[1])! }
    /// Title point size before width fitting (48 unless the title gave way, never below 34).
    public let titleSize: CGFloat
    /// The area the title box travels in. Position (0, 0) puts the box at its bottom-left corner,
    /// (1, 1) at its top-right corner.
    public let titleArea: CGRect
    /// False when even the smallest give-way leaves an element inside a reserved band
    /// ("Safe zones leave too little room").
    public private(set) var fits = false

    // MARK: Derived positions

    public var contentMinX: CGFloat { safeFrame.minX }
    public var contentMaxX: CGFloat { safeFrame.maxX }
    public var contentWidth: CGFloat { safeFrame.width }
    /// Baseline of "Full track" and the duration above the full-track waveform.
    public var overviewLabelBaseline: CGFloat { overview.maxY + Metrics.overviewLabelOffset }
    /// Baseline of "Close-up" above the close-up waveform.
    public var detailLabelBaseline: CGFloat? { detail.map { $0.maxY + Metrics.detailLabelOffset } }
    /// Baseline of the time labels under the close-up ticks.
    public var tickLabelBaseline: CGFloat? { detail.map { $0.minY - Metrics.tickLabelOffset } }
    /// Top of the close-up cursor triangle.
    public var cursorTriangleTop: CGFloat? { detail.map { $0.maxY + Metrics.cursorTriangleRise } }
    public var elapsedLabelBaseline: CGFloat { Self.labelBaseline(clockBaseline, elapsedSize) }
    public var remainingLabelBaseline: CGFloat { Self.labelBaseline(clockBaseline, remainingSize) }
    /// Height of the title box for a given point size (build 10: size + 22).
    public static func titleBoxHeight(_ size: CGFloat) -> CGFloat { size + Metrics.titleBoxPadding }

    public static func labelBaseline(_ clockBaseline: CGFloat, _ size: ClockSize) -> CGFloat {
        clockBaseline + size.points * Metrics.clockLabelRise + Metrics.clockLabelGap
    }

    /// Typographic width of a clock reading at a size.
    public static func clockWidth(_ size: ClockSize) -> CGFloat {
        CGFloat(Metrics.clockCharacters) * Metrics.monoAdvance * size.points + Metrics.antialias
    }

    // MARK: Element extents

    public enum Element: String, CaseIterable, Sendable {
        case title, overview, detail, elapsedClock, remainingClock
    }

    /// The rectangle an element's drawn pixels can cover, text and overhangs included.
    public func extent(of element: Element) -> CGRect? {
        let m = Metrics.self
        switch element {
        case .title:
            return titleArea.insetBy(dx: -m.titleShadowSpread, dy: 0)
        case .overview:
            return CGRect(x: overview.minX - m.cursorOverhang, y: overview.minY - m.overviewBelow,
                          width: overview.width + 2 * m.cursorOverhang,
                          height: overview.height + m.overviewBelow + m.overviewAbove)
        case .detail:
            return detail.map {
                CGRect(x: $0.minX - m.cursorTriangleHalfWidth, y: $0.minY - m.detailBelow,
                       width: $0.width + 2 * m.cursorTriangleHalfWidth,
                       height: $0.height + m.detailBelow + m.detailAbove)
            }
        case .elapsedClock, .remainingClock:
            let size = element == .elapsedClock ? elapsedSize : remainingSize
            let width = max(Self.clockWidth(size), m.clockLabelSize * 5)
            let bottom = clockBaseline - size.points * m.digitDescent - m.antialias
            let top = Self.labelBaseline(clockBaseline, size) + m.clockLabelSize * m.labelAscent + m.antialias
            let x = element == .elapsedClock ? contentMinX : contentMaxX - width
            return CGRect(x: x, y: bottom, width: width, height: top - bottom)
        }
    }

    /// Extents of every element present in this layout.
    public var extents: [Element: CGRect] {
        var result: [Element: CGRect] = [:]
        for element in Element.allCases { result[element] = extent(of: element) }
        return result
    }

    // MARK: Init

    public init(appearance: CueAppearance, clockPosition: ClockPosition = .below, safeZones: SafeZones = .none) {
        self.init(zoom: appearance.zoom, elapsed: appearance.elapsed.size, remaining: appearance.remaining.size,
                  clockPosition: clockPosition, safeZones: safeZones)
    }

    public init(zoom: ZoomWindow = .auto, elapsed: ClockSize = .medium, remaining: ClockSize = .medium,
                clockPosition: ClockPosition = .below, safeZones: SafeZones = .none) {
        typealias M = Metrics
        zoomRaw = zoom.rawValue
        self.clockPosition = clockPosition
        insets = safeZones.insets
        requestedRaw = [elapsed.rawValue, remaining.rawValue]

        // Bands, rounded outward to whole pixels.
        let picture = M.picture
        func px(_ percent: Int, of length: CGFloat) -> CGFloat { (length * CGFloat(percent) / 100).rounded(.up) }
        let top = px(insets.top, of: picture.height), bottom = px(insets.bottom, of: picture.height)
        let left = px(insets.left, of: picture.width), right = px(insets.right, of: picture.width)
        reserved = [
            CGRect(x: 0, y: picture.maxY - top, width: picture.width, height: top),
            CGRect(x: 0, y: 0, width: picture.width, height: bottom),
            CGRect(x: 0, y: 0, width: left, height: picture.height),
            CGRect(x: picture.maxX - right, y: 0, width: right, height: picture.height)
        ].filter { $0.width > 0 && $0.height > 0 }
        usable = CGRect(x: left, y: bottom, width: picture.width - left - right, height: picture.height - top - bottom)

        let sidePad = M.cursorTriangleHalfWidth + M.bandPadding
        let minX = max(M.sideMargin, left + sidePad)
        let maxX = min(picture.maxX - M.sideMargin, picture.maxX - right - sidePad)
        let lowY = max(M.titleInset, bottom + M.bandPadding)
        let highY = min(picture.maxY - M.titleInset, picture.maxY - top - M.bandPadding)
        safeFrame = CGRect(x: minX, y: lowY, width: maxX - minX, height: highY - lowY)
        titleArea = safeFrame

        // Horizontal: the clock pair must fit side by side; only smaller clocks help.
        var eSize = elapsed, rSize = remaining
        var horizontalFit = true
        while Self.clockWidth(eSize) + Self.clockWidth(rSize) + M.clockPairGap > safeFrame.width {
            guard Self.stepLarger(&eSize, &rSize) else { horizontalFit = false; break }
        }

        // Vertical: find the first give-way stage that fits.
        var titleSize = M.titleNaturalSize
        var plan: Stack
        var verticalFit = true
        let available = highY - lowY
        while true {
            plan = Stack(zoom: zoom, position: clockPosition, elapsed: eSize, remaining: rSize, title: titleSize)
            let needed = plan.span - available
            if needed <= 0 {
                plan.top = Self.offsetTop(span: plan.span, low: lowY, high: highY)
                break
            }
            plan.top = highY
            var shrink = needed + 1  // whole-pixel rounding allowance
            if clockPosition == .below {
                shrink -= plan.reclaimGapAboveClocks(upTo: shrink)
            }
            if shrink <= plan.waveformCapacity {
                plan.shrinkWaveforms(by: shrink)
                break
            }
            if shrink <= plan.waveformCapacity + plan.gapCapacity {
                // Above keeps build 11's gap compression. Below, spend only the deficit
                // left after the waveforms reach their floors.
                let gapShrink = clockPosition == .below ? shrink - plan.waveformCapacity : shrink
                plan.shrinkWaveforms(by: plan.waveformCapacity)
                plan.shrinkGaps(by: gapShrink)
                break
            }
            if Self.stepLarger(&eSize, &rSize) { continue }
            let rest = shrink - plan.waveformCapacity - plan.gapCapacity
            let reduced = M.titleNaturalSize - rest.rounded(.up)
            if titleSize == M.titleNaturalSize, reduced >= M.titleMinimumSize {
                titleSize = reduced
                continue
            }
            // Nothing left to give: lay out at the minimums and report the failure.
            titleSize = M.titleMinimumSize
            plan = Stack(zoom: zoom, position: clockPosition, elapsed: eSize, remaining: rSize, title: titleSize)
            plan.top = highY
            plan.shrinkWaveforms(by: plan.waveformCapacity)
            plan.shrinkGaps(by: plan.gapCapacity)
            verticalFit = false
            break
        }

        let placed = plan.place(x: minX, width: maxX - minX)
        overview = placed.overview
        detail = placed.detail
        clockBaseline = placed.clockBaseline
        sizeRaw = [eSize.rawValue, rSize.rawValue]
        self.titleSize = titleSize

        var inside = true
        for element in Element.allCases {
            if let extent = extent(of: element), !usable.contains(extent) { inside = false }
        }
        fits = horizontalFit && verticalFit && inside
    }

    /// Steps the larger clock (both when equal) down one size. False when both are Small.
    private static func stepLarger(_ a: inout ClockSize, _ b: inout ClockSize) -> Bool {
        let all = ClockSize.allCases
        let ia = all.firstIndex(of: a)!, ib = all.firstIndex(of: b)!
        let largest = max(ia, ib)
        guard largest > 0 else { return false }
        if ia == largest { a = all[ia - 1] }
        if ib == largest { b = all[ib - 1] }
        return true
    }

    /// Top of a stack that fits: build 10's top unless a band pushes it, moved by whole pixels.
    private static func offsetTop(span: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        let naturalTop = Metrics.picture.maxY - Metrics.titleInset
        let up = (low - (naturalTop - span)).rounded(.up)   // smallest shift clearing the bottom
        let down = high - naturalTop                         // largest shift clearing the top
        return naturalTop + min(max(0, up), down)
    }
}

// MARK: - Vertical stack

/// The elements as vertical segments, top to bottom, with build 10 sizes and their floors.
private struct Stack {
    typealias M = CueLayout.Metrics
    enum Segment { case title, overview, detail, clocks, gap(Int) }

    let zoom: ZoomWindow
    let order: [Segment]
    let titleHeight: CGFloat
    let clockRise: CGFloat   // clock block top above the baseline
    let clockDrop: CGFloat   // clock block bottom below the baseline
    var overviewHeight: CGFloat
    var detailHeight: CGFloat
    var gaps: [CGFloat]
    var top: CGFloat = 0

    init(zoom: ZoomWindow, position: ClockPosition, elapsed: ClockSize, remaining: ClockSize, title: CGFloat) {
        self.zoom = zoom
        let hasDetail = zoom != .off
        titleHeight = CueLayout.titleBoxHeight(title)
        let largest = max(elapsed.points, remaining.points)
        clockRise = largest * M.clockLabelRise + M.clockLabelGap + M.clockLabelSize * M.labelAscent + M.antialias
        clockDrop = largest * M.digitDescent + M.antialias
        let natural = CueLayout.Metrics.naturalOverview
        overviewHeight = hasDetail ? natural.height : natural.maxY - M.naturalDetail.minY
        detailHeight = hasDetail ? M.naturalDetail.height : 0

        // Build 10 gaps for these clock sizes (clocks below, title box at the top of its travel).
        let titleBottom = M.picture.maxY - M.titleInset - CueLayout.titleBoxHeight(M.titleNaturalSize)
        let overviewTop = natural.maxY + M.overviewAbove
        let overviewBottom = (hasDetail ? natural.minY : M.naturalDetail.minY) - M.overviewBelow
        let detailTop = M.naturalDetail.maxY + M.detailAbove
        let detailBottom = M.naturalDetail.minY - M.detailBelow
        let clockTop = M.naturalClockBaseline + clockRise
        let waveBottom = hasDetail ? detailBottom : overviewBottom
        // gap 0: title ↔ upper group, 1: waveform group ↔ clocks, 2: full track ↔ close-up.
        gaps = [titleBottom - overviewTop,
                waveBottom - clockTop,
                hasDetail ? overviewBottom - detailTop : 0]
        let waves: [Segment] = hasDetail ? [.overview, .gap(2), .detail] : [.overview]
        order = position == .below
            ? [.title, .gap(0)] + waves + [.gap(1), .clocks]
            : [.title, .gap(0), .clocks, .gap(1)] + waves
    }

    private var minimumOverview: CGFloat { zoom == .off ? M.minimumOverviewOffHeight : M.minimumOverviewHeight }
    private var detailCapacity: CGFloat { zoom == .off ? 0 : max(0, detailHeight - M.minimumDetailHeight) }
    private var overviewCapacity: CGFloat { max(0, overviewHeight - minimumOverview) }
    var waveformCapacity: CGFloat { detailCapacity + overviewCapacity }
    var gapCapacity: CGFloat { usedGaps.reduce(0) { $0 + max(0, gaps[$1] - M.minimumGap) } }
    private var usedGaps: [Int] { zoom == .off ? [0, 1] : [0, 1, 2] }

    var span: CGFloat {
        order.reduce(0) { total, segment in
            switch segment {
            case .title: return total + titleHeight
            case .overview: return total + M.overviewBelow + overviewHeight + M.overviewAbove
            case .detail: return total + M.detailBelow + detailHeight + M.detailAbove
            case .clocks: return total + clockRise + clockDrop
            case .gap(let i): return total + gaps[i]
            }
        }
    }

    /// Gap 1 separates the bottom waveform's full extent (including ticks) from the clock labels.
    mutating func reclaimGapAboveClocks(upTo amount: CGFloat) -> CGFloat {
        let reclaimed = min(amount, max(0, gaps[1] - M.minimumGap))
        gaps[1] -= reclaimed
        return reclaimed
    }

    /// Whole-pixel reductions shared in proportion to what each waveform can give.
    mutating func shrinkWaveforms(by amount: CGFloat) {
        let total = waveformCapacity
        guard total > 0, amount > 0 else { return }
        let fromDetail = min(detailCapacity, (amount * detailCapacity / total).rounded(.up))
        let fromOverview = min(overviewCapacity, max(0, amount - fromDetail).rounded(.up))
        detailHeight -= fromDetail
        overviewHeight -= fromOverview
    }

    mutating func shrinkGaps(by amount: CGFloat) {
        let total = gapCapacity
        guard total > 0, amount > 0 else { return }
        let fraction = min(1, amount / total)
        for i in usedGaps { gaps[i] -= max(0, gaps[i] - M.minimumGap) * fraction }
    }

    /// Lays the segments out downward from `top`; rectangle edges land on whole pixels.
    func place(x: CGFloat, width: CGFloat) -> (overview: CGRect, detail: CGRect?, clockBaseline: CGFloat) {
        var y = top
        var overview = CGRect.zero, detail: CGRect?, baseline: CGFloat = 0
        for segment in order {
            switch segment {
            case .title:
                y -= titleHeight
            case .gap(let i):
                y -= gaps[i]
            case .overview:
                let maxY = (y - M.overviewAbove).rounded()
                overview = CGRect(x: x, y: maxY - overviewHeight, width: width, height: overviewHeight)
                y = overview.minY - M.overviewBelow
            case .detail:
                let maxY = (y - M.detailAbove).rounded()
                detail = CGRect(x: x, y: maxY - detailHeight, width: width, height: detailHeight)
                y = maxY - detailHeight - M.detailBelow
            case .clocks:
                baseline = (y - clockRise).rounded()
                y = baseline - clockDrop
            }
        }
        return (overview, detail, baseline)
    }
}

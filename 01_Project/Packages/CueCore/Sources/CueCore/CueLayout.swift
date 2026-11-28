import CoreGraphics

/// Geometry of one 1920 × 1080 cue picture, computed from the zoom window, the clock sizes, the
/// pane order and the safe zones. Measured text and visible groups determine the spacing, so the preview, the export, hit-testing and the guides can share one value.
///
/// Coordinates are Core Graphics picture points with a bottom-left origin, like `CuePicture`.
///
/// With safe zones None and the default pane order, every value equals the constants `CuePicture` used in
/// build 10. Otherwise the elements form one vertical stack (title band, full track, close-up and
/// clocks, in picture order) that first moves within the free margins and, when it cannot fit
/// between the reserved bands, gives way in this order:
///   1. the close-up and full-track waveform heights shrink,
///   2. the gaps between groups shrink,
///   3. the clocks step down a size (never below Small),
///   4. the title shrinks (never below 34 pt),
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

    let typography: PictureTypography
    public let zoom: ZoomWindow
    public let showTitle: Bool
    public let showFullTrack: Bool
    public let showElapsed: Bool
    public let showRemaining: Bool
    private let requestedRaw: [String]
    private let sizeRaw: [String]
    public let paneOrder: [PicturePane]
    public let titleAlignment: TitleAlignment
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
    /// Space reserved for the title, including its vertical shadow allowance.
    public let titleBand: CGRect
    public var titleArea: CGRect { titleBand }
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
    public var elapsedLabelBaseline: CGFloat { clockBaseline + typography.clockLabelRise(elapsedSize.points) }
    public var remainingLabelBaseline: CGFloat { clockBaseline + typography.clockLabelRise(remainingSize.points) }
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
            guard showTitle else { return nil }
            return titleBand
        case .overview:
            guard showFullTrack else { return nil }
            return CGRect(x: overview.minX - m.cursorOverhang, y: overview.minY - m.overviewBelow,
                          width: overview.width + 2 * m.cursorOverhang,
                          height: overview.height + m.overviewBelow + typography.overviewAbove)
        case .detail:
            return detail.map {
                CGRect(x: $0.minX - m.cursorTriangleHalfWidth, y: $0.minY - typography.detailBelow,
                       width: $0.width + 2 * m.cursorTriangleHalfWidth,
                       height: $0.height + typography.detailBelow + typography.detailAbove)
            }
        case .elapsedClock, .remainingClock:
            let right = element == .remainingClock
            guard right ? showRemaining : showElapsed else { return nil }
            let size = right ? remainingSize : elapsedSize
            let width = typography.clockWidth(size, right: right)
            let bottom = clockBaseline - size.points * typography.clockUnit.descent - m.antialias
            let top = clockBaseline + typography.clockLabelRise(size.points) + m.clockLabelSize * typography.titleUnit.ascent + m.antialias
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

    public init(zoom: ZoomWindow = .auto, elapsed: ClockSize = .medium, remaining: ClockSize = .medium,
                paneOrder: [PicturePane] = PicturePane.defaultOrder, safeZones: SafeZones = .none) {
        var appearance = CueAppearance()
        appearance.zoom = zoom
        appearance.elapsed.size = elapsed
        appearance.remaining.size = remaining
        appearance.paneOrder = paneOrder
        appearance.safeZones = safeZones
        self.init(appearance: appearance)
    }

    public init(appearance: CueAppearance) {
        typealias M = Metrics
        zoom = appearance.zoom
        paneOrder = appearance.paneOrder
        titleAlignment = appearance.titleAlignment
        insets = (appearance.safeZonesEnabled ? appearance.safeZones : .none).insets
        showTitle = appearance.showTitle
        showFullTrack = appearance.showFullTrack
        showElapsed = appearance.showElapsed
        showRemaining = appearance.showRemaining
        let fonts: PictureTypography = appearance.titleFontName == nil && appearance.clockFontName == nil
            ? .standard : PictureTypography(titleName: appearance.titleFontName, clockName: appearance.clockFontName)
        typography = fonts
        let elapsed = appearance.elapsed.size, remaining = appearance.remaining.size
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

        // Horizontal: the clock pair must fit side by side; only smaller clocks help.
        var eSize = elapsed, rSize = remaining
        var horizontalFit = true
        func clocksWidth(_ elapsed: ClockSize, _ remaining: ClockSize) -> CGFloat {
            (appearance.showElapsed ? fonts.clockWidth(elapsed, right: false) : 0)
                + (appearance.showRemaining ? fonts.clockWidth(remaining, right: true) : 0)
                + (appearance.showElapsed && appearance.showRemaining ? M.clockPairGap : 0)
        }
        while clocksWidth(eSize, rSize) > safeFrame.width {
            guard Self.stepLarger(&eSize, &rSize, appearance: appearance) else { horizontalFit = false; break }
        }

        // Vertical: find the first give-way stage that fits.
        var titleSize = M.titleNaturalSize
        var placed: Stack.Placement
        var verticalFit = true
        var available = highY - lowY
        while true {
            var plan = Stack(appearance: appearance, fonts: fonts, elapsed: eSize, remaining: rSize, title: titleSize)
            let needed = plan.span - available
            let shrink = needed + 1  // build 17's whole-pixel allowance
            plan.top = highY
            if needed <= 0 {
                if !showTitle || !showFullTrack || (!showElapsed && !showRemaining) {
                    plan.expandWaveform(by: (-needed).rounded(.down))
                }
                plan.top = Self.offsetTop(span: plan.span, low: lowY, high: highY)
            } else if shrink <= plan.waveformCapacity {
                plan.shrinkWaveforms(by: shrink)
            } else if shrink <= plan.waveformCapacity + plan.gapCapacity {
                plan.shrinkWaveforms(by: plan.waveformCapacity)
                // Build 17 applies the full shortage to the gaps once waveforms reach their floors.
                plan.shrinkGaps(by: shrink)
            } else {
                // A different clock or title size needs a fresh measurement of rounding.
                available = highY - lowY
                if Self.stepLarger(&eSize, &rSize, appearance: appearance) { continue }
                if titleSize > M.titleMinimumSize {
                    titleSize = showTitle ? titleSize - 1 : M.titleMinimumSize
                    continue
                }
                plan.shrinkWaveforms(by: plan.waveformCapacity)
                plan.shrinkGaps(by: plan.gapCapacity)
                verticalFit = false
            }
            placed = plan.place(x: minX, width: maxX - minX)
            let deficit = lowY - placed.bottom
            if !verticalFit || deficit <= 0 { break }
            // Rounding each pane downward to preserve a tight gap may use another pixel.
            // Charge only the measured overrun so already-fitting legacy layouts stay exact.
            available -= deficit.rounded(.up)
        }

        titleBand = placed.titleBand
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
    private static func stepLarger(_ a: inout ClockSize, _ b: inout ClockSize, appearance: CueAppearance) -> Bool {
        let all = ClockSize.allCases
        let ia = appearance.showElapsed ? all.firstIndex(of: a)! : -1
        let ib = appearance.showRemaining ? all.firstIndex(of: b)! : -1
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

    let zoom: ZoomWindow
    let fonts: PictureTypography
    let order: [PicturePane]
    let titleHeight: CGFloat
    let clockRise: CGFloat   // clock block top above the baseline
    let clockDrop: CGFloat   // clock block bottom below the baseline
    var overviewHeight: CGFloat
    var detailHeight: CGFloat
    var gaps: [CGFloat]
    var top: CGFloat = 0

    init(appearance: CueAppearance, fonts: PictureTypography, elapsed: ClockSize,
         remaining: ClockSize, title: CGFloat) {
        zoom = appearance.zoom
        self.fonts = fonts
        let hasDetail = zoom != .off
        titleHeight = fonts.titleBoxHeight(title)
        let largest = max(appearance.showElapsed ? elapsed.points : 0, appearance.showRemaining ? remaining.points : 0)
        clockRise = fonts.clockLabelRise(largest) + M.clockLabelSize * fonts.titleUnit.ascent + M.antialias
        clockDrop = largest * fonts.clockUnit.descent + M.antialias
        let natural = CueLayout.Metrics.naturalOverview
        overviewHeight = hasDetail ? natural.height : natural.maxY - M.naturalDetail.minY
        detailHeight = hasDetail ? M.naturalDetail.height : 0

        // Build 10 gaps for these clock sizes (clocks below, title box at the top of its travel).
        let titleBottom = M.picture.maxY - M.titleInset - CueLayout.titleBoxHeight(M.titleNaturalSize)
        let overviewTop = natural.maxY + M.overviewAbove
        let overviewBottom = (hasDetail ? natural.minY : M.naturalDetail.minY) - M.overviewBelow
        let detailTop = M.naturalDetail.maxY + M.detailAbove
        let detailBottom = M.naturalDetail.minY - M.detailBelow
        let clockTop = M.naturalClockBaseline + largest * M.clockLabelRise + M.clockLabelGap
            + M.clockLabelSize * M.labelAscent + M.antialias
        let waveBottom = hasDetail ? detailBottom : overviewBottom
        order = appearance.paneOrder.filter { pane in
            switch pane {
            case .title: return appearance.showTitle
            case .fullTrack: return appearance.showFullTrack
            case .closeUp: return hasDetail
            case .clocks: return appearance.showElapsed || appearance.showRemaining
            }
        }
        gaps = zip(order, order.dropFirst()).map { upper, lower in
            if upper == .title || lower == .title { return titleBottom - overviewTop }
            if upper == .clocks || lower == .clocks { return waveBottom - clockTop }
            return overviewBottom - detailTop
        }
        if !appearance.showFullTrack { overviewHeight = 0 }
    }

    mutating func expandWaveform(by amount: CGFloat) {
        if detailHeight > 0 { detailHeight += amount }
        else if overviewHeight > 0 { overviewHeight += amount }
    }

    private var minimumOverview: CGFloat { zoom == .off ? M.minimumOverviewOffHeight : M.minimumOverviewHeight }
    private var detailCapacity: CGFloat { zoom == .off ? 0 : max(0, detailHeight - M.minimumDetailHeight) }
    private var overviewCapacity: CGFloat { max(0, overviewHeight - minimumOverview) }
    var waveformCapacity: CGFloat { detailCapacity + overviewCapacity }
    var gapCapacity: CGFloat { gaps.reduce(0) { $0 + max(0, $1 - M.minimumGap) } }

    var span: CGFloat {
        var height: CGFloat = 0
        for (index, pane) in order.enumerated() {
            if index > 0 { height += gaps[index - 1] }
            switch pane {
            case .title: height += titleHeight
            case .fullTrack: height += M.overviewBelow + overviewHeight + fonts.overviewAbove
            case .closeUp: height += fonts.detailBelow + detailHeight + fonts.detailAbove
            case .clocks: height += clockRise + clockDrop
            }
        }
        return height
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
        for i in gaps.indices { gaps[i] -= max(0, gaps[i] - M.minimumGap) * fraction }
    }

    struct Placement {
        var titleBand = CGRect.zero
        var overview = CGRect.zero
        var detail: CGRect?
        var clockBaseline: CGFloat = 0
        var bottom: CGFloat
    }

    /// Keep the legacy nearest-pixel placement unless rounding up would cross the frame
    /// edge or consume part of the mandatory gap to the preceding pane.
    func place(x: CGFloat, width: CGFloat) -> Placement {
        var y = top
        var placed = Placement(bottom: top)
        // With the title hidden, preserve build 17's nearest-pixel placement of the
        // top group. Its conservative glyph extent can use half a pixel of the padding.
        let firstCeiling: CGFloat = order.contains(.title) ? top : .infinity
        for (index, pane) in order.enumerated() {
            let ceiling = index == 0 ? firstCeiling : y - M.minimumGap
            if index > 0 { y -= gaps[index - 1] }
            func anchor(below rise: CGFloat) -> CGFloat {
                min((y - rise).rounded(), (ceiling - rise).rounded(.down))
            }
            switch pane {
            case .title:
                placed.titleBand = CGRect(x: x, y: y - titleHeight, width: width, height: titleHeight)
                y = placed.titleBand.minY
            case .fullTrack:
                let maxY = anchor(below: fonts.overviewAbove)
                placed.overview = CGRect(x: x, y: maxY - overviewHeight, width: width, height: overviewHeight)
                y = placed.overview.minY - M.overviewBelow
            case .closeUp:
                let maxY = anchor(below: fonts.detailAbove)
                placed.detail = CGRect(x: x, y: maxY - detailHeight, width: width, height: detailHeight)
                y = maxY - detailHeight - fonts.detailBelow
            case .clocks:
                placed.clockBaseline = anchor(below: clockRise)
                y = placed.clockBaseline - clockDrop
            }
        }
        placed.bottom = y
        return placed
    }
}

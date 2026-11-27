import CoreText
import XCTest
@testable import CueCore

final class CueLayoutTests: XCTestCase {
    typealias M = CueLayout.Metrics

    private func zones(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) -> SafeZones {
        SafeZones(preset: .custom, custom: .init(top: top, bottom: bottom, left: left, right: right))
    }

    private func index(_ size: ClockSize) -> Int { ClockSize.allCases.firstIndex(of: size)! }

    /// The title box at its default position (top of its travel, natural or given-way size).
    private func titleBand(_ layout: CueLayout) -> CGRect {
        let height = CueLayout.titleBoxHeight(layout.titleSize)
        return CGRect(x: layout.titleArea.minX, y: layout.titleArea.maxY - height,
                      width: layout.titleArea.width, height: height)
    }

    /// Vertical extents of the stacked groups, top to bottom in picture order.
    private func stack(_ layout: CueLayout) -> [CGRect] {
        let clocks = layout.extent(of: .elapsedClock)!.union(layout.extent(of: .remainingClock)!)
        var waves = [layout.extent(of: .overview)!]
        if let detail = layout.extent(of: .detail) { waves.append(detail) }
        return layout.clockPosition == .below ? [titleBand(layout)] + waves + [clocks]
                                              : [titleBand(layout), clocks] + waves
    }

    private func gaps(_ layout: CueLayout) -> [CGFloat] {
        let groups = stack(layout)
        return zip(groups, groups.dropFirst()).map { $0.minY - $1.maxY }
    }

    private func minimumOverview(_ layout: CueLayout) -> CGFloat {
        layout.zoom == .off ? M.minimumOverviewOffHeight : M.minimumOverviewHeight
    }

    private func waveformsAtMinimum(_ layout: CueLayout) -> Bool {
        layout.overview.height <= minimumOverview(layout) && (layout.detail?.height ?? 0) <= M.minimumDetailHeight
    }

    // MARK: Build 10 equivalence

    func testNoSafeZonesClocksBelowEqualsBuild10Constants() {
        let noneVariants = [SafeZones.none, zones(), SafeZones(preset: .none, custom: .init(top: 20, bottom: 20))]
        for zoom in ZoomWindow.allCases {
            for elapsed in ClockSize.allCases {
                for remaining in ClockSize.allCases {
                    for safe in noneVariants {
                        let layout = CueLayout(zoom: zoom, elapsed: elapsed, remaining: remaining, safeZones: safe)
                        let label = "\(zoom) \(elapsed) \(remaining)"
                        XCTAssertTrue(layout.fits, label)
                        XCTAssertEqual(layout.overview, CuePicture.overviewRect(for: zoom), label)
                        XCTAssertEqual(layout.detail, zoom == .off ? nil : CuePicture.detail, label)
                        XCTAssertEqual(layout.clockBaseline, 100, label)
                        XCTAssertEqual(layout.elapsedSize, elapsed, label)
                        XCTAssertEqual(layout.remainingSize, remaining, label)
                        XCTAssertEqual(layout.titleSize, 48, label)
                        XCTAssertEqual(layout.titleArea, CGRect(x: 96, y: 55, width: 1728, height: 970), label)
                        XCTAssertEqual(layout.contentMinX, CuePicture.wave.minX, label)
                        XCTAssertEqual(layout.contentMaxX, CuePicture.wave.maxX, label)
                        XCTAssertEqual(layout.contentWidth, CuePicture.wave.width, label)
                        XCTAssertEqual(layout.reserved, [], label)
                        XCTAssertEqual(layout.usable, CGRect(origin: .zero, size: CuePicture.size), label)
                        XCTAssertEqual(layout.overviewLabelBaseline, layout.overview.maxY + 18, label)
                        XCTAssertEqual(layout.elapsedLabelBaseline, 100 + elapsed.points * 0.77 + 26, label)
                        XCTAssertEqual(layout.remainingLabelBaseline, 100 + remaining.points * 0.77 + 26, label)
                        if zoom != .off {
                            XCTAssertEqual(layout.overviewLabelBaseline, 860, label)
                            XCTAssertEqual(layout.detailLabelBaseline, 646, label)
                            XCTAssertEqual(layout.tickLabelBaseline, 324, label)
                            XCTAssertEqual(layout.cursorTriangleTop, 640, label)
                        } else {
                            XCTAssertNil(layout.detailLabelBaseline)
                            XCTAssertNil(layout.tickLabelBaseline)
                        }
                    }
                }
            }
        }
    }

    func testTitleTravelMatchesCaptionFormula() {
        let layout = CueLayout()
        for size: CGFloat in [34, 40, 48] {
            let height = CueLayout.titleBoxHeight(size)
            XCTAssertEqual(height, size + 22)
            for y: CGFloat in [0, 0.25, 1] {
                XCTAssertEqual(layout.titleArea.minY + (layout.titleArea.height - height) * y,
                               55 + (CuePicture.size.height - 110 - height) * y)
            }
        }
    }

    func testAppearanceInitReadsZoomAndClockSizes() {
        var appearance = CueAppearance()
        XCTAssertEqual(CueLayout(appearance: appearance), CueLayout(zoom: .auto, elapsed: .medium, remaining: .medium))
        appearance.zoom = .off
        appearance.elapsed.size = .extraLarge
        appearance.remaining.size = .small
        let layout = CueLayout(appearance: appearance, clockPosition: .above, safeZones: .init(preset: .evsOSD))
        XCTAssertEqual(layout, CueLayout(zoom: .off, elapsed: .extraLarge, remaining: .small,
                                         clockPosition: .above, safeZones: .init(preset: .evsOSD)))
        XCTAssertEqual(layout.requestedElapsedSize, .extraLarge)
        XCTAssertEqual(layout.insets, SafeZones.evsOSDInsets)
    }

    // MARK: Bands

    func testReservedBandsInPixels() {
        let evs = CueLayout(safeZones: SafeZones(preset: .evsOSD))
        XCTAssertEqual(evs.reserved, [CGRect(x: 0, y: 993, width: 1920, height: 87),
                                      CGRect(x: 0, y: 0, width: 1920, height: 184)])
        XCTAssertEqual(evs.usable, CGRect(x: 0, y: 184, width: 1920, height: 809))
        // 1 % of 1080 is 10.8 px: rounded outward so a partly covered row stays reserved.
        let odd = CueLayout(safeZones: zones(top: 1, left: 3))
        XCTAssertEqual(odd.reserved, [CGRect(x: 0, y: 1069, width: 1920, height: 11),
                                      CGRect(x: 0, y: 0, width: 58, height: 1080)])
    }

    // MARK: Positioning before give-way

    func testSmallReservesMoveNothingOrShiftOnly() {
        // Bottom 5 %: the clocks already clear the band; build 10 stays.
        let bottom = CueLayout(safeZones: zones(bottom: 5))
        XCTAssertEqual(bottom.overview, CuePicture.wave)
        XCTAssertEqual(bottom.detail, CuePicture.detail)
        XCTAssertEqual(bottom.clockBaseline, 100)
        XCTAssertEqual(bottom.titleArea.minY, 66)

        // Top 5 %: the stack moves down into the bottom slack without shrinking.
        let top = CueLayout(safeZones: zones(top: 5))
        XCTAssertEqual(top.titleArea.maxY, 1080 - 54 - 12)
        XCTAssertEqual(top.overview, CuePicture.wave.offsetBy(dx: 0, dy: -11))
        XCTAssertEqual(top.detail, CuePicture.detail.offsetBy(dx: 0, dy: -11))
        XCTAssertEqual(top.clockBaseline, 89)
        XCTAssertTrue(top.fits)
    }

    func testClocksAboveMovePairAboveWaveforms() {
        for zoom in [ZoomWindow.off, .auto] {
            for safe in [SafeZones.none, SafeZones(preset: .evsOSD)] {
                let layout = CueLayout(zoom: zoom, elapsed: .large, remaining: .medium, clockPosition: .above, safeZones: safe)
                XCTAssertTrue(layout.fits)
                let elapsed = layout.extent(of: .elapsedClock)!, remaining = layout.extent(of: .remainingClock)!
                let overview = layout.extent(of: .overview)!
                XCTAssertGreaterThan(elapsed.minY, overview.maxY)
                XCTAssertGreaterThan(remaining.minY, overview.maxY)
                XCTAssertLessThan(elapsed.maxY, titleBand(layout).minY)
                if let detail = layout.extent(of: .detail) { XCTAssertLessThan(detail.maxY, overview.minY) }
                // Both clocks share one baseline: they move as a pair.
                XCTAssertEqual(layout.elapsedLabelBaseline, CueLayout.labelBaseline(layout.clockBaseline, .large))
            }
        }
        // Without reserves, the above layout keeps build 10's sizes.
        let above = CueLayout(clockPosition: .above)
        XCTAssertEqual(above.overview.height, 100)
        XCTAssertEqual(above.detail?.height, 265)
        XCTAssertEqual(above.titleSize, 48)
    }

    // MARK: No element inside a reserved band

    func testNoElementIntersectsReservedBands() {
        let percents = [0, 5, 10, 15, 20, 25, 30]
        let sides = [0, 5, 15, 30]
        let sizes: [(ClockSize, ClockSize)] = [(.small, .small), (.medium, .medium), (.extraLarge, .large), (.extraLarge, .extraLarge)]
        var fitting = 0, failing = 0
        for zoom in [ZoomWindow.off, .auto] {
            for position in ClockPosition.allCases {
                for (elapsed, remaining) in sizes {
                    for top in percents {
                        for bottom in percents {
                            for side in sides {
                                let safe = zones(top: top, bottom: bottom, left: side, right: side / 3)
                                let layout = CueLayout(zoom: zoom, elapsed: elapsed, remaining: remaining,
                                                       clockPosition: position, safeZones: safe)
                                let label = "\(zoom) \(position) \(elapsed)/\(remaining) t\(top) b\(bottom) s\(side)"
                                XCTAssertLessThanOrEqual(index(layout.elapsedSize), index(elapsed), label)
                                XCTAssertLessThanOrEqual(index(layout.remainingSize), index(remaining), label)
                                XCTAssertGreaterThanOrEqual(layout.titleSize, 34, label)
                                XCTAssertLessThanOrEqual(layout.titleSize, 48, label)
                                guard layout.fits else { failing += 1; continue }
                                fitting += 1
                                XCTAssertGreaterThanOrEqual(layout.overview.height, minimumOverview(layout), label)
                                XCTAssertGreaterThanOrEqual(layout.detail?.height ?? 150, 150, label)
                                for (element, extent) in layout.extents {
                                    XCTAssertTrue(layout.usable.contains(extent), "\(label) \(element)")
                                    for band in layout.reserved {
                                        let overlap = band.intersection(extent)
                                        XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0,
                                                      "\(label) \(element) in \(band)")
                                    }
                                }
                                // Groups stay in order without overlapping.
                                for gap in gaps(layout) { XCTAssertGreaterThanOrEqual(gap, M.minimumGap - 1, label) }
                                // Clocks side by side without touching.
                                let e = layout.extent(of: .elapsedClock)!, r = layout.extent(of: .remainingClock)!
                                XCTAssertGreaterThanOrEqual(r.minX - e.maxX, M.clockPairGap - 1, label)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(fitting, 0)
        XCTAssertGreaterThan(failing, 0)
    }

    // MARK: Give-way order

    func testGiveWayOrderAcrossShrinkingArea() {
        var seen = Set<String>()
        for zoom in [ZoomWindow.off, .auto] {
            for position in ClockPosition.allCases {
                let reference = CueLayout(zoom: zoom, elapsed: .extraLarge, remaining: .extraLarge, clockPosition: position)
                let naturalGaps = gaps(reference)
                var previous: CueLayout?
                // Grow the reserves step by step: bottom first, then top on top of a full bottom.
                let steps = (0...30).map { (0, $0) } + (1...30).map { ($0, 30) }
                for (top, bottom) in steps {
                    let layout = CueLayout(zoom: zoom, elapsed: .extraLarge, remaining: .extraLarge,
                                           clockPosition: position, safeZones: zones(top: top, bottom: bottom))
                    let label = "\(zoom) \(position) t\(top) b\(bottom)"
                    let shrunkWaves = layout.overview.height < reference.overview.height
                        || (layout.detail?.height ?? 0) < (reference.detail?.height ?? 0)
                    let shrunkGaps = zip(gaps(layout), naturalGaps).contains { $0 < $1 - 1.5 }
                    let steppedClocks = layout.elapsedSize != .extraLarge || layout.remainingSize != .extraLarge
                    let shrunkTitle = layout.titleSize < 48

                    // 1 before 2: gaps only shrink once the waveforms are at their floors.
                    if shrunkGaps { XCTAssertTrue(waveformsAtMinimum(layout), label) }
                    // 2 before 3: clocks only step down once waveforms and gaps are at their floors.
                    if steppedClocks {
                        XCTAssertTrue(waveformsAtMinimum(layout), label)
                        if layout.elapsedSize == .small {
                            for gap in gaps(layout) { XCTAssertLessThanOrEqual(gap, M.minimumGap + 1.5, label) }
                        }
                    }
                    // 3 before 4: the title only shrinks once both clocks are Small.
                    if shrunkTitle {
                        XCTAssertEqual(layout.elapsedSize, .small, label)
                        XCTAssertEqual(layout.remainingSize, .small, label)
                        XCTAssertTrue(waveformsAtMinimum(layout), label)
                    }
                    // Then it no longer fits, with everything at its floor.
                    if !layout.fits {
                        XCTAssertEqual(layout.titleSize, 34, label)
                        XCTAssertEqual(layout.elapsedSize, .small, label)
                        XCTAssertTrue(waveformsAtMinimum(layout), label)
                    }
                    // Monotonic: a larger reserve never grows anything back.
                    if let previous {
                        XCTAssertLessThanOrEqual(layout.overview.height, previous.overview.height, label)
                        XCTAssertLessThanOrEqual(layout.detail?.height ?? 0, previous.detail?.height ?? 0, label)
                        XCTAssertLessThanOrEqual(index(layout.elapsedSize), index(previous.elapsedSize), label)
                        XCTAssertLessThanOrEqual(layout.titleSize, previous.titleSize, label)
                        if !previous.fits { XCTAssertFalse(layout.fits, label) }
                    }
                    previous = layout

                    if !layout.fits { seen.insert("none") }
                    else if shrunkTitle { seen.insert("title") }
                    else if steppedClocks { seen.insert("clocks") }
                    else if shrunkGaps { seen.insert("gaps") }
                    else if shrunkWaves { seen.insert("waves") }
                    else { seen.insert("natural") }
                }
            }
        }
        XCTAssertEqual(seen, ["natural", "waves", "gaps", "clocks", "title", "none"])
    }

    func testWaveformsGiveWayFirst() {
        // EVS OSD with medium clocks: only the waveforms (and possibly a sliver of gap) give way.
        let layout = CueLayout(zoom: .auto, elapsed: .medium, remaining: .medium, safeZones: .init(preset: .evsOSD))
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.elapsedSize, .medium)
        XCTAssertEqual(layout.titleSize, 48)
        XCTAssertLessThan(layout.detail!.height, 265)
        XCTAssertLessThan(layout.overview.height, 100)
        XCTAssertGreaterThanOrEqual(layout.extent(of: .elapsedClock)!.minY, 184)
        XCTAssertLessThanOrEqual(titleBand(layout).maxY, 993)
    }

    func testDoesNotFit() {
        let layout = CueLayout(zoom: .auto, elapsed: .large, remaining: .large, safeZones: zones(top: 30, bottom: 30))
        XCTAssertFalse(layout.fits)
        XCTAssertEqual(layout.elapsedSize, .small)
        XCTAssertEqual(layout.remainingSize, .small)
        XCTAssertEqual(layout.titleSize, 34)
        XCTAssertEqual(layout.detail?.height, M.minimumDetailHeight)
        XCTAssertEqual(layout.overview.height, M.minimumOverviewHeight)
    }

    func testWideSideReservesStepClocksDown() {
        let layout = CueLayout(zoom: .auto, elapsed: .extraLarge, remaining: .extraLarge,
                               safeZones: zones(left: 30, right: 30))
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.contentMinX, 576 + 23)
        XCTAssertEqual(layout.contentMaxX, 1920 - 576 - 23)
        XCTAssertEqual(layout.overview.minX, layout.contentMinX)
        XCTAssertEqual(layout.titleArea.width, layout.contentWidth)
        XCTAssertLessThan(index(layout.elapsedSize), index(.extraLarge))
        let e = layout.extent(of: .elapsedClock)!, r = layout.extent(of: .remainingClock)!
        XCTAssertGreaterThanOrEqual(r.minX - e.maxX, M.clockPairGap)
        // Vertical geometry is untouched by side reserves.
        XCTAssertEqual(layout.overview.minY, 742)
        XCTAssertEqual(layout.detail?.minY, 361)
    }

    // MARK: Text metrics guard

    func testMetricsCoverMeasuredGlyphs() {
        func bounds(_ text: String, font: String) -> (CGRect, CGFloat) {
            let run = CuePicture.line(text, font: font, size: 100, color: CuePicture.dim)
            return (CTLineGetBoundsWithOptions(run, .useGlyphPathBounds),
                    CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil)))
        }
        for text in ["Full track", "Close-up", "Elapsed", "Remaining"] {
            let (box, _) = bounds(text, font: "HelveticaNeue-Medium")
            XCTAssertLessThanOrEqual(box.maxY / 100, M.labelAscent, text)
            XCTAssertLessThanOrEqual(-box.minY / 100, M.labelDescent, text)
            XCTAssertGreaterThanOrEqual(box.minX, 0, text)
        }
        XCTAssertLessThanOrEqual(bounds("Remaining", font: "HelveticaNeue-Medium").1 * M.clockLabelSize / 100,
                                 M.clockLabelSize * 5)
        let (digits, _) = bounds("0123456789:", font: "Menlo")
        XCTAssertLessThanOrEqual(digits.maxY / 100, M.digitAscent)
        XCTAssertLessThanOrEqual(-digits.minY / 100, M.digitDescent)
        let (clock, width) = bounds("88:88:88", font: "Menlo")
        XCTAssertGreaterThanOrEqual(clock.minX, 0)
        XCTAssertLessThanOrEqual(width, CGFloat(M.clockCharacters) * M.monoAdvance * 100)
        XCTAssertLessThanOrEqual(clock.maxX, width)
        // Title box holds accented capitals and descenders at both title sizes.
        for size in [M.titleMinimumSize, M.titleNaturalSize] {
            let run = CuePicture.line("ÅÉÁ gjpqy|", font: "HelveticaNeue-Medium", size: size, color: CuePicture.dim)
            let glyphs = CTLineGetBoundsWithOptions(run, .useGlyphPathBounds)
            XCTAssertLessThanOrEqual(glyphs.maxY + M.titleShadowSpread,
                                     CueLayout.titleBoxHeight(size) - M.titleBaselineInset)
            XCTAssertLessThanOrEqual(-glyphs.minY + M.titleShadowSpread, M.titleBaselineInset)
        }
    }
}

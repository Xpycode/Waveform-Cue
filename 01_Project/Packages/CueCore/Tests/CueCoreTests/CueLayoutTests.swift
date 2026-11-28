import CoreText
import XCTest
@testable import CueCore

final class CueLayoutTests: XCTestCase {
    typealias M = CueLayout.Metrics

    private func zones(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) -> SafeZones {
        SafeZones(preset: .custom, custom: .init(top: top, bottom: bottom, left: left, right: right))
    }

    private func index(_ size: ClockSize) -> Int { ClockSize.allCases.firstIndex(of: size)! }

    static let orders: [[PicturePane]] = {
        func permutations(_ panes: [PicturePane]) -> [[PicturePane]] {
            if panes.isEmpty { return [[]] }
            return panes.flatMap { first in
                permutations(panes.filter { $0 != first }).map { [first] + $0 }
            }
        }
        return permutations(PicturePane.defaultOrder)
    }()

    /// Ordered extents, with hidden panes omitted and the two clocks measured together.
    private func stack(_ layout: CueLayout) -> [CGRect] {
        layout.paneOrder.compactMap { pane in
            switch pane {
            case .title: return layout.extent(of: .title)
            case .fullTrack: return layout.extent(of: .overview)
            case .closeUp: return layout.extent(of: .detail)
            case .clocks:
                let clocks = [layout.extent(of: .elapsedClock), layout.extent(of: .remainingClock)].compactMap { $0 }
                return clocks.isEmpty ? nil : clocks.reduce(CGRect.null) { $0.union($1) }
            }
        }
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
                        XCTAssertEqual(layout.safeFrame, CGRect(x: 96, y: 55, width: 1728, height: 970), label)
                        XCTAssertEqual(layout.titleBand, CGRect(x: 96, y: 955, width: 1728, height: 70), label)
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

    func testAllOrdersFitEveryZoomAndClockPairWithoutReserves() {
        XCTAssertEqual(Set(Self.orders).count, 24)
        for order in Self.orders {
            for zoom in ZoomWindow.allCases {
                for elapsed in ClockSize.allCases {
                    for remaining in ClockSize.allCases {
                        let layout = CueLayout(zoom: zoom, elapsed: elapsed, remaining: remaining, paneOrder: order)
                        let label = "\(order) \(zoom) \(elapsed)/\(remaining)"
                        XCTAssertTrue(layout.fits, label)
                        XCTAssertEqual(layout.paneOrder, order, label)
                        XCTAssertEqual(layout.detail == nil, zoom == .off, label)
                        XCTAssertEqual(layout.titleArea, layout.titleBand, label)
                        XCTAssertEqual(layout.extent(of: .title), layout.titleBand, label)
                        for gap in gaps(layout) { XCTAssertGreaterThanOrEqual(gap, M.minimumGap, label) }
                    }
                }
            }
        }
    }

    func testAppearanceInitReadsZoomAndClockSizes() {
        var appearance = CueAppearance()
        XCTAssertEqual(CueLayout(appearance: appearance), CueLayout(zoom: .auto, elapsed: .medium, remaining: .medium))
        appearance.zoom = .off
        appearance.elapsed.size = .extraLarge
        appearance.remaining.size = .small
        appearance.paneOrder = [.closeUp, .clocks, .fullTrack, .title]
        appearance.safeZones = .init(preset: .evsOSD)
        let layout = appearance.layout
        XCTAssertEqual(layout, CueLayout(zoom: .off, elapsed: .extraLarge, remaining: .small,
                                         paneOrder: appearance.paneOrder, safeZones: .init(preset: .evsOSD)))
        XCTAssertEqual(layout.requestedElapsedSize, .extraLarge)
        XCTAssertEqual(layout.insets, SafeZones.evsOSDInsets)
    }

    func testHiddenGroupsReturnSpaceToTheWaveform() throws {
        var look = CueAppearance()
        look.safeZones = zones(top: 11, bottom: 11)
        look.elapsed.size = .extraLarge
        look.remaining.size = .extraLarge
        let visible = look.layout
        for setting in [\CueAppearance.showTitle, \.showFullTrack] {
            var hidden = look
            hidden[keyPath: setting] = false
            XCTAssertGreaterThan(try XCTUnwrap(hidden.layout.detail).height, try XCTUnwrap(visible.detail).height)
        }
        look.safeZones = zones(left: 30, right: 30)
        let pair = look.layout
        look.showElapsed = false
        let single = look.layout
        XCTAssertNil(single.extent(of: .elapsedClock))
        XCTAssertEqual(single.remainingSize, .extraLarge)
        XCTAssertNotEqual(pair.remainingSize, single.remainingSize)
        look.showRemaining = false
        XCTAssertGreaterThan(try XCTUnwrap(look.layout.detail).height, try XCTUnwrap(single.detail).height)
    }

    func testRoundedPanesStayAboveTheLowerFrameEdge() throws {
        var look = CueAppearance()
        look.paneOrder = [.title, .closeUp, .fullTrack, .clocks]
        look.elapsed.size = .small
        look.remaining.size = .small
        look.safeZones = zones(top: 19, bottom: 30)
        let stacked = look.layout
        XCTAssertTrue(stacked.fits)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(stacked.extent(of: .elapsedClock)).minY, stacked.safeFrame.minY)

        look.paneOrder = [.fullTrack, .clocks, .title, .closeUp]
        look.showFullTrack = false
        look.safeZones = zones(bottom: 5)
        let expanded = look.layout
        XCTAssertTrue(expanded.fits)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(expanded.extent(of: .detail)).minY, expanded.safeFrame.minY)
    }

    func testHiddenTitleRetainsBuild17TopWaveformRounding() throws {
        var look = CueAppearance()
        look.showTitle = false
        look.zoom = .five
        let layout = look.layout
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.overview, CGRect(x: 96, y: 887, width: 1728, height: 100))
        XCTAssertEqual(layout.safeFrame.maxY, 1025)
        let extent = try XCTUnwrap(layout.extent(of: .overview))
        XCTAssertEqual(extent.maxY, 1025.5)
        XCTAssertTrue(layout.usable.contains(extent))
    }

    func testTallTitleFindsAFittingPointSizeBetweenItsLimits() {
        var look = CueAppearance()
        look.titleFontName = "Zapfino"
        look.zoom = .five
        look.elapsed.size = .small
        look.remaining.size = .small
        look.safeZones = zones(top: 16, bottom: 16)
        let layout = look.layout
        XCTAssertTrue(layout.fits)
        XCTAssertGreaterThanOrEqual(layout.titleSize, M.titleMinimumSize)
        XCTAssertLessThan(layout.titleSize, M.titleNaturalSize)
        let track = BaselineTests.syntheticTrack()
        let pixels = RenderTests.render(track, timeline: ClipTimeline(duration: track.seconds), position: 0,
                                        label: CueLabel(text: "Swash"), appearance: look)
        for band in layout.reserved { XCTAssertEqual(RenderTests.foreignPixels(pixels, in: band), 0) }
    }

    func testDisabledSafeZonesRestoreRoomWithoutLosingTheReserves() {
        var look = CueAppearance()
        look.safeZones = zones(top: 30, bottom: 30, left: 30, right: 30)
        XCTAssertFalse(look.layout.fits)
        look.safeZonesEnabled = false
        XCTAssertTrue(look.layout.fits)
        XCTAssertTrue(look.layout.reserved.isEmpty)
        XCTAssertEqual(look.safeZones.insets.top, 30)
    }

    func testSteppingEachPaneMovesOnlyItsDrawnExtent() throws {
        let elements: [PicturePane: [CueLayout.Element]] = [
            .title: [.title], .fullTrack: [.overview], .closeUp: [.detail], .clocks: [.elapsedClock, .remainingClock]
        ]
        for pane in PicturePane.allCases {
            var look = CueAppearance()
            if pane == .title { look.paneOrder = [.fullTrack, .title, .closeUp, .clocks] }
            let automatic = look.layout
            XCTAssertTrue(automatic.offsetLimits(for: pane).contains(1))
            look.offsets[pane] = 1
            let stepped = look.layout
            XCTAssertEqual(stepped.offsetsInUse, look.offsets)
            XCTAssertEqual(stepped, CueLayout(appearance: look))
            for element in CueLayout.Element.allCases {
                let initial = try XCTUnwrap(automatic.extent(of: element))
                let shift: CGFloat = elements[pane]!.contains(element) ? 1 : 0
                XCTAssertEqual(stepped.extent(of: element), initial.offsetBy(dx: 0, dy: shift))
            }
        }
    }

    func testTemporaryConstraintsKeepStoredOffsetsAndHiddenPanesHaveNoTravel() {
        var look = CueAppearance()
        look.offsets = PaneOffsets(title: -40, fullTrack: 35, closeUp: 40, clocks: -25)
        let open = look.layout
        look.safeZones = .init(preset: .evsOSD)
        XCTAssertTrue(look.layout.fits)
        XCTAssertNotEqual(look.layout.offsetsInUse, open.offsetsInUse)
        look.safeZones = .none
        XCTAssertEqual(look.layout, open)

        look.paneOrder = [.closeUp, .title, .clocks, .fullTrack]
        XCTAssertEqual(look.layout.offsetsInUse.closeUp, 0) // The close-up now touches the top margin.
        look.paneOrder = PicturePane.defaultOrder
        XCTAssertEqual(look.layout, open)

        look.zoom = .off
        XCTAssertEqual(look.layout.offsetsInUse.closeUp, 0)
        XCTAssertEqual(look.layout.offsetLimits(for: .closeUp), 0...0)
        look.showTitle = false
        look.showFullTrack = false
        look.showElapsed = false
        look.showRemaining = false
        let hidden = look.layout
        XCTAssertEqual(hidden.offsetsInUse, PaneOffsets())
        for pane in PicturePane.allCases { XCTAssertEqual(hidden.offsetLimits(for: pane), 0...0) }
    }

    func testOffsetLimitsHoldNeighboursFixedAfterAStoredOffsetWasClamped() {
        var look = CueAppearance()
        look.offsets = PaneOffsets(title: -120, fullTrack: 130, closeUp: 20, clocks: -5)
        let layout = look.layout
        XCTAssertNotEqual(layout.offsetsInUse, look.offsets)
        for pane in PicturePane.allCases {
            let limits = layout.offsetLimits(for: pane)
            for limit in [limits.lowerBound, limits.upperBound] {
                var edit = layout.offsetsInUse
                edit[pane] = limit
                look.offsets = edit
                XCTAssertEqual(look.layout.offsetsInUse, edit)
            }
        }
    }

    func testOffsetLimitsWithMeasuredFontsAndHiddenPanes() {
        var look = CueAppearance()
        look.titleFontName = "Zapfino"
        look.clockFontName = "Courier"
        look.offsets = PaneOffsets(title: -31, fullTrack: 19, closeUp: -55, clocks: 36)
        for order in Self.orders {
            look.paneOrder = order
            for top in [4, 16, 25] {
                look.safeZones = zones(top: top, bottom: 17)
                for showTitle in [false, true] {
                    look.showTitle = showTitle
                    let layout = look.layout
                    guard layout.fits else { continue }
                    for gap in gaps(layout) {
                        XCTAssertGreaterThanOrEqual(gap, M.minimumGap - M.picture.height.ulp)
                    }
                    for pane in order {
                        XCTAssertTrue(layout.offsetLimits(for: pane).contains(layout.offsetsInUse[pane]))
                    }
                }
            }
        }
    }

    func testStoredOffsetsAcrossAllOrdersAndSafeZones() {
        // A fixed seed gives each layout different, reproducible requests in both directions.
        var seed: UInt64 = 0xC0FFEE
        func nextOffset() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % 401) - 200
        }
        for order in Self.orders {
            var look = CueAppearance()
            look.paneOrder = order
            for zoom in [ZoomWindow.off, .auto] {
                look.zoom = zoom
                for size in ClockSize.allCases {
                    look.elapsed.size = size
                    look.remaining.size = .large
                    for top in stride(from: 0, through: 30, by: 5) {
                        for bottom in stride(from: 0, through: 30, by: 5) {
                            look.safeZones = zones(top: top, bottom: bottom, left: top, right: bottom)
                            look.offsets = PaneOffsets()
                            let automatic = look.layout
                            look.offsets = PaneOffsets(title: nextOffset(), fullTrack: nextOffset(),
                                                       closeUp: nextOffset(), clocks: nextOffset())
                            let shifted = look.layout
                            let context = "\(order) \(zoom) \(size) reserves \(top),\(bottom) offsets \(look.offsets)"
                            XCTAssertEqual(shifted.fits, automatic.fits, context)
                            guard shifted.fits else {
                                XCTAssertEqual(shifted, automatic, context)
                                for pane in order { XCTAssertEqual(shifted.offsetLimits(for: pane), 0...0, context) }
                                continue
                            }
                            // Font metrics have fractional edges. Reconstructing a translated CGRect
                            // can round a 12 px difference down by one ULP of the picture coordinates.
                            for gap in gaps(shifted) {
                                XCTAssertGreaterThanOrEqual(gap, M.minimumGap - M.picture.height.ulp, context)
                            }
                            for extent in shifted.extents.values {
                                XCTAssertGreaterThanOrEqual(extent.minY, shifted.safeFrame.minY, context)
                                XCTAssertLessThanOrEqual(extent.maxY, shifted.safeFrame.maxY, context)
                                XCTAssertTrue(shifted.usable.contains(extent), context)
                            }
                            for pane in order {
                                XCTAssertTrue(shifted.offsetLimits(for: pane).contains(shifted.offsetsInUse[pane]), context)
                            }
                        }
                    }
                }
            }
        }
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
        XCTAssertEqual(bottom.safeFrame.minY, 66)

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
                let layout = CueLayout(zoom: zoom, elapsed: .large, remaining: .medium, paneOrder: [.title, .clocks, .fullTrack, .closeUp], safeZones: safe)
                XCTAssertTrue(layout.fits)
                let elapsed = layout.extent(of: .elapsedClock)!, remaining = layout.extent(of: .remainingClock)!
                let overview = layout.extent(of: .overview)!
                XCTAssertGreaterThan(elapsed.minY, overview.maxY)
                XCTAssertGreaterThan(remaining.minY, overview.maxY)
                XCTAssertLessThan(elapsed.maxY, layout.titleBand.minY)
                if let detail = layout.extent(of: .detail) { XCTAssertLessThan(detail.maxY, overview.minY) }
                // Both clocks share one baseline: they move as a pair.
                XCTAssertEqual(layout.elapsedLabelBaseline, CueLayout.labelBaseline(layout.clockBaseline, .large))
            }
        }
        // Without reserves, the above layout keeps build 10's sizes.
        let above = CueLayout(paneOrder: [.title, .clocks, .fullTrack, .closeUp])
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
            for order in Self.orders {
                for (elapsed, remaining) in sizes {
                    for top in percents {
                        for bottom in percents {
                            for side in sides {
                                let safe = zones(top: top, bottom: bottom, left: side, right: side / 3)
                                let layout = CueLayout(zoom: zoom, elapsed: elapsed, remaining: remaining,
                                                       paneOrder: order, safeZones: safe)
                                let label = "\(zoom) \(order) \(elapsed)/\(remaining) t\(top) b\(bottom) s\(side)"
                                XCTAssertLessThanOrEqual(index(layout.elapsedSize), index(elapsed), label)
                                XCTAssertLessThanOrEqual(index(layout.remainingSize), index(remaining), label)
                                XCTAssertGreaterThanOrEqual(layout.titleSize, 34, label)
                                XCTAssertLessThanOrEqual(layout.titleSize, 48, label)
                                for gap in gaps(layout) { XCTAssertGreaterThanOrEqual(gap, M.minimumGap, label) }
                                guard layout.fits else { failing += 1; continue }
                                for extent in stack(layout) {
                                    XCTAssertGreaterThanOrEqual(extent.minY, layout.safeFrame.minY, label)
                                    XCTAssertLessThanOrEqual(extent.maxY, layout.safeFrame.maxY, label)
                                }
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

    func testBottomReserveMovesPanesContinuouslyAsWaveformsReachTheirFloors() throws {
        var look = CueAppearance()
        look.zoom = .five
        look.elapsed.size = .small
        look.remaining.size = .large
        look.paneOrder = [.title, .clocks, .fullTrack, .closeUp]
        let layouts = (0...30).map { bottom in
            look.safeZones = zones(top: 5, bottom: bottom)
            return look.layout
        }
        let initialGaps = gaps(layouts[0]).reduce(0, +)
        let transition = try XCTUnwrap(layouts.indices.first {
            waveformsAtMinimum(layouts[$0]) && gaps(layouts[$0]).reduce(0, +) < initialGaps - 1
        })

        for bottom in 1...30 {
            let previous = layouts[bottom - 1], current = layouts[bottom]
            let label = "Bottom \(bottom - 1)% to \(bottom)% (gap compression starts at \(transition)%)"
            let sameSizes = previous.elapsedSize == current.elapsedSize && previous.remainingSize == current.remainingSize
                && previous.titleSize == current.titleSize
            if bottom == transition { XCTAssertTrue(previous.fits && current.fits && sameSizes, label) }
            guard previous.fits, current.fits, sameSizes else { continue }
            // Each of the three inter-pane placements can round to a whole pixel.
            let limit = current.usable.minY - previous.usable.minY + 3
            for (before, after) in zip(stack(previous), stack(current)) {
                XCTAssertLessThanOrEqual(abs(after.maxY - before.maxY), limit, label)
                XCTAssertLessThanOrEqual(abs(after.minY - before.minY), limit, label)
            }
            XCTAssertLessThanOrEqual(abs(gaps(current).reduce(0, +) - gaps(previous).reduce(0, +)), limit, label)
        }
        for bottom in layouts.indices.reversed() {
            look.safeZones = zones(top: 5, bottom: bottom)
            XCTAssertEqual(look.layout, layouts[bottom], "Restoring Bottom \(bottom)%")
        }
    }

    func testGiveWayOrderAcrossShrinkingArea() {
        var seen = Set<String>()
        for zoom in [ZoomWindow.off, .auto] {
            for order in Self.orders {
                let reference = CueLayout(zoom: zoom, elapsed: .extraLarge, remaining: .extraLarge, paneOrder: order)
                let naturalGaps = gaps(reference)
                var previous: CueLayout?
                // Grow the reserves step by step: bottom first, then top on top of a full bottom.
                let steps = (0...30).map { (0, $0) } + (1...30).map { ($0, 30) }
                for (top, bottom) in steps {
                    let layout = CueLayout(zoom: zoom, elapsed: .extraLarge, remaining: .extraLarge,
                                           paneOrder: order, safeZones: zones(top: top, bottom: bottom))
                    let label = "\(zoom) \(order) t\(top) b\(bottom)"
                    let shrunkWaves = layout.overview.height < reference.overview.height
                        || (layout.detail?.height ?? 0) < (reference.detail?.height ?? 0)
                    let shrunkGaps = zip(gaps(layout), naturalGaps).contains { $0 < $1 - 1.5 }
                    let steppedClocks = layout.elapsedSize != .extraLarge || layout.remainingSize != .extraLarge
                    let shrunkTitle = layout.titleSize < 48

                    // 1 before 2: gaps only shrink once the waveforms are at their floors.
                    if shrunkGaps { XCTAssertTrue(waveformsAtMinimum(layout), label) }
                    // 2 before 3: the larger clocks must have run out of space even at minimum gaps.
                    // The smaller clocks can then give some of that space back to the gaps.
                    if steppedClocks {
                        XCTAssertTrue(waveformsAtMinimum(layout), label)
                        if let previous, previous.elapsedSize != layout.elapsedSize {
                            XCTAssertTrue(waveformsAtMinimum(previous), label)
                            let panes = stack(previous)
                            let tightSpan = panes.reduce(0) { $0 + $1.height } + CGFloat(panes.count - 1) * M.minimumGap
                            // Allow a pixel per pane for the fit allowance and anchor rounding.
                            XCTAssertGreaterThan(tightSpan + CGFloat(panes.count), layout.safeFrame.height, label)
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
                        for gap in gaps(layout) { XCTAssertLessThanOrEqual(gap, M.minimumGap + 1.5, label) }
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
        XCTAssertLessThanOrEqual(layout.titleBand.maxY, 993)
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

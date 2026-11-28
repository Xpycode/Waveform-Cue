import XCTest
@testable import CueCore

final class ClockSideTests: XCTestCase {
    func testClockEdgesAndPairGapFollowTheSelectedSide() throws {
        for side in LeftClock.allCases {
            for elapsed in ClockSize.allCases {
                for remaining in ClockSize.allCases {
                    var look = CueAppearance()
                    look.leftClock = side
                    look.elapsed.size = elapsed
                    look.remaining.size = remaining
                    look.safeZones = RenderTests.zones(left: 30, right: 30)
                    let layout = look.layout
                    XCTAssertTrue(layout.fits)
                    let e = try XCTUnwrap(layout.extent(of: .elapsedClock))
                    let r = try XCTUnwrap(layout.extent(of: .remainingClock))
                    let (left, right) = side == .elapsed ? (e, r) : (r, e)
                    XCTAssertEqual(left.minX, layout.contentMinX)
                    XCTAssertEqual(right.maxX, layout.contentMaxX, accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(right.minX - left.maxX, CueLayout.Metrics.clockPairGap)
                    XCTAssertEqual(layout.elapsedLabelBaseline, CueLayout.labelBaseline(layout.clockBaseline, layout.elapsedSize))
                    XCTAssertEqual(layout.remainingLabelBaseline, CueLayout.labelBaseline(layout.clockBaseline, layout.remainingSize))
                    look.showRemaining = false
                    XCTAssertNil(look.layout.extent(of: .remainingClock))
                    let single = try XCTUnwrap(look.layout.extent(of: .elapsedClock))
                    if side == .elapsed { XCTAssertEqual(single.minX, layout.contentMinX) }
                    else { XCTAssertEqual(single.maxX, layout.contentMaxX, accuracy: 0.001) }
                }
            }
        }
    }

    func testThreeDigitMinutesKeepBothReadingsInsideTheirColumns() throws {
        let sample = BaselineTests.syntheticTrack()
        let track = AudioTrack(url: sample.url, pcm: sample.pcm, seconds: 202 * 60,
                               detailPeaks: sample.detailPeaks, peaks: sample.peaks)
        let timeline = ClipTimeline(duration: track.seconds)
        for side in LeftClock.allCases {
            var look = CueAppearance()
            look.leftClock = side
            look.elapsed.size = .extraLarge
            look.remaining.size = .extraLarge
            look.safeZones = RenderTests.zones(left: 15, right: 15)
            let layout = look.layout
            let left = try XCTUnwrap(layout.extent(of: side == .elapsed ? .elapsedClock : .remainingClock))
            let right = try XCTUnwrap(layout.extent(of: side == .elapsed ? .remainingClock : .elapsedClock))
            let gap = CGRect(x: ceil(left.maxX), y: left.minY,
                             width: floor(right.minX) - ceil(left.maxX), height: left.height)
            let pixels = RenderTests.render(track, timeline: timeline, position: timeline.clockFrames / 2,
                                           label: CueLabel(), appearance: look)
            XCTAssertGreaterThanOrEqual(gap.width, CueLayout.Metrics.clockPairGap)
            XCTAssertEqual(RenderTests.foreignPixels(pixels, in: gap), 0)
            XCTAssertGreaterThan(RenderTests.foreignPixels(pixels, in: left), 1000)
            XCTAssertGreaterThan(RenderTests.foreignPixels(pixels, in: right), 1000)
        }
    }

    func testRenderedLabelsAndWarningFollowTheirClock() throws {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds)
        for side in LeftClock.allCases {
            var look = CueAppearance()
            look.leftClock = side
            look.offsets.clocks = 11
            look.elapsed.color = CueColor(0, 0, 1)
            look.remaining.color = CueColor(0, 0, 1)
            look.warning = .ten
            look.solidRedAt = .oneSecond
            let layout = look.layout
            let leftColumns = Int(layout.contentMinX)..<960
            let rightColumns = 960..<Int(layout.contentMaxX)
            let remainingColumns = side == .remaining ? leftColumns : rightColumns
            let elapsedColumns = side == .elapsed ? leftColumns : rightColumns

            // Both digits start blue. Only Remaining acquires red, first partway, then fully.
            for (secondsLeft, expectedRed) in [(15, 0...20), (5, 120...165), (1, 250...255)] {
                let pixels = RenderTests.render(track, timeline: timeline,
                                               position: timeline.clockFrames - secondsLeft * AudioTrack.fps,
                                               label: CueLabel(), appearance: look)
                let baseline = Int(layout.clockBaseline)
                func peakRed(in columns: Range<Int>) -> Int {
                    var peak: UInt8 = 0
                    for y in baseline..<(baseline + 45) {
                        for x in columns { peak = max(peak, pixels[((1079 - y) * 1920 + x) * 4 + 2]) }
                    }
                    return Int(peak)
                }
                XCTAssertTrue(expectedRed.contains(peakRed(in: remainingColumns)), "\(side), \(secondsLeft) seconds")
                XCTAssertLessThan(peakRed(in: elapsedColumns), 20)

                if secondsLeft == 15 {
                    let labelBaseline = Int(layout.elapsedLabelBaseline)
                    let rows = (labelBaseline - 8)..<(labelBaseline + 26)
                    let left = try XCTUnwrap(labelInk(pixels, columns: leftColumns, rows: rows))
                    let right = try XCTUnwrap(labelInk(pixels, columns: rightColumns, rows: rows))
                    XCTAssertLessThan(left.lowerBound - leftColumns.lowerBound, 5)
                    XCTAssertLessThan(rightColumns.upperBound - right.upperBound, 5)
                    // "Remaining" has more ink width than "Elapsed" in the default label font.
                    let (remaining, elapsed) = side == .remaining ? (left, right) : (right, left)
                    XCTAssertGreaterThan(remaining.count, elapsed.count + 15)
                }
            }
        }
    }

    private func labelInk(_ pixels: [UInt8], columns: Range<Int>, rows: Range<Int>) -> ClosedRange<Int>? {
        var first = columns.upperBound, last = columns.lowerBound - 1
        for y in rows {
            for x in columns {
                let pixel = ((1079 - y) * 1920 + x) * 4
                if pixels[pixel + 1] > 50 { // Dim label against dark background.
                    first = min(first, x)
                    last = max(last, x)
                }
            }
        }
        return first <= last ? first...last : nil
    }
}

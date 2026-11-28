import CoreGraphics
import XCTest
@testable import CueCore

/// Fade and End tags never cover each other (build 15 showed "F End" at the track's end).
final class MarkerTagTests: XCTestCase {
    private let minX: CGFloat = 100, maxX: CGFloat = 1000
    private let endWidth: CGFloat = 30, fadeWidth: CGFloat = 36

    private func boxes(endX: CGFloat, fadeX: CGFloat) -> (end: ClosedRange<CGFloat>, fade: ClosedRange<CGFloat>) {
        let lefts = CuePicture.markerTagLefts([(.fadeStart, fadeX, fadeWidth), (.musicEnd, endX, endWidth)],
                                              minX: minX, maxX: maxX)
        let pad = CuePicture.markerTagPadding
        let end = lefts[.musicEnd]!, fade = lefts[.fadeStart]!
        return ((end - pad)...(end + endWidth + pad), (fade - pad)...(fade + fadeWidth + pad))
    }

    func testFadeClearsEndFlippedAtThePanelEdge() {
        let (end, fade) = boxes(endX: maxX - 1.5, fadeX: maxX - 12)
        XCTAssertFalse(fade.overlaps(end), "Fade \(fade) covers End \(end)")
        XCTAssertLessThan(fade.upperBound, end.lowerBound, "Fade moves to the left of End")
        XCTAssertGreaterThanOrEqual(fade.lowerBound, minX)
        XCTAssertLessThanOrEqual(end.upperBound, maxX)
    }

    func testTagsFarApartKeepTheirSides() {
        let lefts = CuePicture.markerTagLefts([(.fadeStart, 500, fadeWidth), (.musicEnd, 700, endWidth)],
                                              minX: minX, maxX: maxX)
        XCTAssertEqual(lefts[.fadeStart], 500 - 6 - fadeWidth, "Fade left of its line")
        XCTAssertEqual(lefts[.musicEnd], 706, "End right of its line")
    }

    func testFadeClearsEndAtThePanelStart() {
        let (end, fade) = boxes(endX: minX + 10, fadeX: minX + 4)
        XCTAssertFalse(fade.overlaps(end), "Fade \(fade) covers End \(end)")
        XCTAssertGreaterThanOrEqual(fade.lowerBound, minX)
    }

    func testSingleMarkerIsPlacedAlone() {
        let lefts = CuePicture.markerTagLefts([(.musicEnd, maxX - 1.5, endWidth)], minX: minX, maxX: maxX)
        XCTAssertEqual(lefts.count, 1)
        XCTAssertEqual(lefts[.musicEnd], maxX - 1.5 - 6 - endWidth, "End flips left at the edge")
    }
}

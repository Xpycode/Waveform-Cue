import CoreGraphics
import XCTest
@testable import CueCore

final class OffsetResolverTests: XCTestCase {
    private let gap: CGFloat = 12

    func testOpposingRequestsGiveTheUpperPaneFirstUseOfTheGap() {
        let spans: [ClosedRange<CGFloat>] = [60...80, 20...40]
        let result = OffsetResolver.resolve(stored: [-6, 7], spans: spans, frame: 0...100, gap: gap)
        XCTAssertEqual(result, [-6, 2])
    }

    func testFractionalEdgesRoundTowardTheAvailableWholePixel() {
        let spans: [ClosedRange<CGFloat>] = [60.5...80.5, 20.5...40]
        let frame: ClosedRange<CGFloat> = 10...91
        XCTAssertEqual(OffsetResolver.resolve(stored: [.max, .min], spans: spans, frame: frame, gap: gap),
                       [10, -10])
        XCTAssertEqual(OffsetResolver.limits(index: 1, inUse: [-6, 0], spans: spans, frame: frame, gap: gap),
                       -10...2)
    }

    func testRoundedAutomaticEdgesAllowZeroAndInwardMovementOnly() {
        // With the title hidden, build 17's full track can reach 1025.5 at a 1025 frame edge.
        // Give the bottom pane the symmetric half-pixel protrusion.
        let frame: ClosedRange<CGFloat> = 55...1025
        let spans: [ClosedRange<CGFloat>] = [950...1025.5, 54.5...920]
        let automatic = [0, 0]
        XCTAssertEqual(OffsetResolver.resolve(stored: [1, -1], spans: spans, frame: frame, gap: gap),
                       automatic)
        XCTAssertEqual(OffsetResolver.limits(index: 0, inUse: automatic, spans: spans, frame: frame, gap: gap),
                       -18...0)
        XCTAssertEqual(OffsetResolver.limits(index: 1, inUse: automatic, spans: spans, frame: frame, gap: gap),
                       0...18)
        for requested in [automatic, [-18, 0], [0, 18], [-9, 9]] {
            XCTAssertEqual(OffsetResolver.resolve(stored: requested, spans: spans, frame: frame, gap: gap),
                           requested)
        }
    }

    func testTouchingFrameAndMinimumGapsLeaveNoRoom() {
        let spans: [ClosedRange<CGFloat>] = [65...85, 33...53, 1...21]
        let frame: ClosedRange<CGFloat> = 1...85
        XCTAssertEqual(OffsetResolver.resolve(stored: [-100, 100, -100], spans: spans, frame: frame, gap: gap),
                       [0, 0, 0])
        for i in spans.indices {
            XCTAssertEqual(OffsetResolver.limits(index: i, inUse: [0, 0, 0], spans: spans, frame: frame, gap: gap),
                           0...0)
        }
        XCTAssertEqual(OffsetResolver.resolve(stored: [], spans: [], frame: frame, gap: gap), [])
    }

    func testRelaxingFrameRestoresStoredRequests() {
        let spans: [ClosedRange<CGFloat>] = [70...80, 50...58]
        let stored = [17, -12]
        let open = OffsetResolver.resolve(stored: stored, spans: spans, frame: 10...100, gap: gap)
        XCTAssertEqual(open, stored)
        XCTAssertEqual(OffsetResolver.resolve(stored: stored, spans: spans, frame: 45...83, gap: gap), [3, -5])
        XCTAssertEqual(OffsetResolver.resolve(stored: stored, spans: spans, frame: 10...100, gap: gap), open)
    }

    func testMovingAWholeStackUsesRoomFreedByItsNeighbours() {
        let spans: [ClosedRange<CGFloat>] = [65...85, 33...53, 1...21]
        for step in [-20, 20] {
            let stored = Array(repeating: step, count: spans.count)
            XCTAssertEqual(OffsetResolver.resolve(stored: stored, spans: spans, frame: -19...105, gap: gap), stored)
        }
    }

    func testGeneratedStacksAndSinglePaneEdits() {
        // Pure resolver input stands in for the already placed layout. Viewer/export integration is P2.1.
        var seed: UInt64 = 0xBAD5EED
        func next(_ maximum: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(maximum + 1))
        }
        func pixels(_ maximum: Int) -> CGFloat { CGFloat(next(maximum * 2)) / 2 }

        for example in 0..<400 {
            let frameBottom = pixels(35) - 20
            var bottom = frameBottom + pixels(20)
            var spans: [ClosedRange<CGFloat>] = []
            for _ in 0...next(3) {
                let top = bottom + 1 + pixels(60)
                spans.insert(bottom...top, at: 0)
                bottom = top + gap + pixels(20)
            }
            let frame = frameBottom...(spans[0].upperBound + pixels(20))
            let stored = spans.map { _ in next(100) - 50 }

            func fits(_ offsets: [Int]) -> Bool {
                var ceiling = frame.upperBound
                for (span, offset) in zip(spans, offsets) {
                    let low = span.lowerBound + CGFloat(offset)
                    let high = span.upperBound + CGFloat(offset)
                    guard low >= frame.lowerBound, high <= ceiling else { return false }
                    ceiling = low - gap
                }
                return true
            }

            let actual = OffsetResolver.resolve(stored: stored, spans: spans, frame: frame, gap: gap)
            XCTAssertEqual(actual.count, spans.count)
            XCTAssertTrue(fits(actual), "Example \(example)")
            if fits(stored) { XCTAssertEqual(actual, stored) }
            XCTAssertEqual(OffsetResolver.resolve(stored: stored, spans: spans, frame: frame, gap: gap), actual)
            for i in actual.indices {
                XCTAssertTrue((min(0, stored[i])...max(0, stored[i])).contains(actual[i]))
                let limits = OffsetResolver.limits(index: i, inUse: actual, spans: spans, frame: frame, gap: gap)
                var edited = actual
                for value in limits {
                    edited[i] = value
                    XCTAssertTrue(fits(edited))
                    XCTAssertEqual(OffsetResolver.resolve(stored: edited, spans: spans, frame: frame, gap: gap),
                                   edited, "Example \(example), pane \(i) at \(value)")
                }
                for value in [limits.lowerBound - 1, limits.upperBound + 1] {
                    edited[i] = value
                    XCTAssertFalse(fits(edited))
                }
            }
        }
    }
}

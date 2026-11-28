import CoreGraphics
import XCTest
@testable import CueCore

/// "Dim played audio in close-up" (after build 13): upcoming close-up audio in full colour,
/// played audio dimmed. The full track keeps build 10's look either way.
final class DimPlayedCloseUpTests: XCTestCase {
    static let bright = CueAppearance.defaultDetail.cgColor
    static let dimmed = CueColor(0.32, 0.48, 0.47).cgColor

    func testDefaultsAndDecoding() throws {
        XCTAssertTrue(CueAppearance().dimPlayedCloseUp)
        // Saved appearances from build 13 and earlier have no key and take the new default.
        let old = try JSONDecoder().decode(CueAppearance.self, from: Data(RenderTests.build10JSON.utf8))
        XCTAssertTrue(old.dimPlayedCloseUp)
        var off = CueAppearance()
        off.dimPlayedCloseUp = false
        let data = try JSONEncoder().encode(off)
        XCTAssertFalse(try JSONDecoder().decode(CueAppearance.self, from: data).dimPlayedCloseUp)
    }

    /// Mid-track, the bright side of the close-up follows the toggle and the full track does not.
    func testBrightSideFollowsTheToggle() throws {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds)
        let frame = track.frames / 2
        var dim = CueAppearance()
        dim.warning = .off
        var build10 = dim
        build10.dimPlayedCloseUp = false
        let detail = try XCTUnwrap(dim.layout.detail)
        let overview = dim.layout.overview
        let played = CGRect(x: detail.minX + 4, y: detail.minY + 4, width: detail.width / 2 - 12, height: detail.height - 8)
        let upcoming = CGRect(x: detail.midX + 8, y: detail.minY + 4, width: detail.width / 2 - 12, height: detail.height - 8)

        let a = CountdownTests.render(track, timeline: timeline, position: frame, appearance: dim)
        XCTAssertEqual(CountdownTests.count(Self.bright, in: a, played), 0, "played is not bright")
        XCTAssertGreaterThan(CountdownTests.count(Self.dimmed, in: a, played), 2_000, "played is dimmed")
        XCTAssertGreaterThan(CountdownTests.count(Self.bright, in: a, upcoming), 2_000, "upcoming is bright")
        XCTAssertEqual(CountdownTests.count(Self.dimmed, in: a, upcoming), 0, "upcoming is not dimmed")

        let b = CountdownTests.render(track, timeline: timeline, position: frame, appearance: build10)
        XCTAssertGreaterThan(CountdownTests.count(Self.bright, in: b, played), 2_000)
        XCTAssertEqual(CountdownTests.count(Self.bright, in: b, upcoming), 0)
        XCTAssertGreaterThan(CountdownTests.count(Self.dimmed, in: b, upcoming), 2_000)

        XCTAssertTrue(CountdownTests.region(a, overview) == CountdownTests.region(b, overview), "full track unchanged")
    }

    /// At solid red the warning swaps sides with the colours: full red ahead, dim red behind.
    func testWarningRedSwapsSides() throws {
        let track = CountdownTests.track()
        var appearance = CountdownTests.appearance(target: .musicEnd, warning: .ten)
        appearance.dimPlayedCloseUp = true
        let timeline = CountdownTests.timeline(track, appearance)
        let detail = try XCTUnwrap(appearance.layout.detail)
        let image = CountdownTests.render(track, timeline: timeline, position: 625, appearance: appearance)
        let cursor = CuePicture.closeUp(frame: 625, total: track.frames, zoom: appearance.zoom,
                                         centerAtStart: appearance.centerAtStart, centerAtEnd: appearance.centerAtEnd)
        let x = detail.minX + detail.width * CGFloat(625 - cursor.lowerBound) / CGFloat(cursor.count)
        let behind = CGRect(x: detail.minX + 4, y: detail.minY + 4, width: x - detail.minX - 12, height: detail.height - 8)
        let ahead = CGRect(x: x + 8, y: detail.minY + 4, width: detail.maxX - x - 12, height: detail.height - 8)
        XCTAssertEqual(CountdownTests.count(CountdownTests.red, in: image, behind), 0)
        XCTAssertGreaterThan(CountdownTests.count(CountdownTests.red, in: image, ahead), 1_000)
        XCTAssertGreaterThan(CountdownTests.count(CueColor.warningRed.dimmed.cgColor, in: image, behind), 1_000)
    }
}

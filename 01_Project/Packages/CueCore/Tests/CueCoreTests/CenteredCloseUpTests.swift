import CoreGraphics
import XCTest
@testable import CueCore

extension CueAppearance {
    /// Build 10's close-up: the window holds still against both ends of the track, and played
    /// audio is full colour. The render baselines pin this look; the centred default is covered by `CenteredCloseUpTests`.
    static var build10: CueAppearance {
        var appearance = CueAppearance()
        appearance.centerAtStart = false
        appearance.centerAtEnd = false
        appearance.dimPlayedCloseUp = false
        return appearance
    }
}

final class CenteredCloseUpTests: XCTestCase {
    // 750 frames, Auto zoom: a 250-frame window, half-window 125.

    func testWindowHoldsAtEndsWhenCenteringIsOff() {
        XCTAssertEqual(CuePicture.closeUp(frame: 0, total: 750, zoom: .auto), 0..<250)
        XCTAssertEqual(CuePicture.closeUp(frame: 400, total: 750, zoom: .auto), 275..<525)
        XCTAssertEqual(CuePicture.closeUp(frame: 750, total: 750, zoom: .auto), 500..<750)
    }

    func testWindowStaysCenteredToBothEnds() {
        func window(_ frame: Int, start: Bool, end: Bool) -> Range<Int> {
            CuePicture.closeUp(frame: frame, total: 750, zoom: .auto, centerAtStart: start, centerAtEnd: end)
        }
        XCTAssertEqual(window(0, start: true, end: true), -125..<125)
        XCTAssertEqual(window(750, start: true, end: true), 625..<875)
        XCTAssertEqual(window(400, start: true, end: true), 275..<525)
        // Each end is independent.
        XCTAssertEqual(window(0, start: false, end: true), 0..<250)
        XCTAssertEqual(window(750, start: false, end: true), 625..<875)
        XCTAssertEqual(window(0, start: true, end: false), -125..<125)
        XCTAssertEqual(window(750, start: true, end: false), 500..<750)
        // Zoom Off shows the whole track whatever the toggles say.
        XCTAssertEqual(CuePicture.closeUp(frame: 0, total: 750, zoom: .off, centerAtStart: true, centerAtEnd: true),
                       -375..<375)
    }

    func testEndZoomRespectsEachEdgeAndSkipsAnUnavailableZoom() {
        let timeline = ClipTimeline(duration: 20)
        var appearance = CueAppearance()
        appearance.zoom = .five
        appearance.endZoom = .two
        for start in [false, true] {
            for end in [false, true] {
                appearance.centerAtStart = start
                appearance.centerAtEnd = end
                let first = CuePicture.closeUp(timeline: timeline, position: 0, appearance: appearance).visible
                let last = CuePicture.closeUp(timeline: timeline, position: 500, appearance: appearance).visible
                XCTAssertEqual(first.lowerBound < 0, start)
                XCTAssertEqual(last.upperBound, end ? 21 : 20, accuracy: 1e-9)
                XCTAssertEqual(last.upperBound - last.lowerBound, 2, accuracy: 1e-9)
                let short = ClipTimeline(duration: 1)
                var off = appearance
                off.endZoom = .off
                XCTAssertEqual(CuePicture.closeUp(timeline: short, position: 0, appearance: appearance),
                               CuePicture.closeUp(timeline: short, position: 0, appearance: off))
            }
        }
    }

    func testDefaultsAndDecoding() throws {
        let fresh = CueAppearance()
        XCTAssertTrue(fresh.centerAtStart)
        XCTAssertTrue(fresh.centerAtEnd)
        // Saved appearances from build 12 and earlier have no keys and take the centred default.
        let old = try JSONDecoder().decode(CueAppearance.self, from: Data(RenderTests.build10JSON.utf8))
        XCTAssertTrue(old.centerAtStart)
        XCTAssertTrue(old.centerAtEnd)
        let data = try JSONEncoder().encode(CueAppearance.build10)
        XCTAssertEqual(try JSONDecoder().decode(CueAppearance.self, from: data), .build10)
    }

    func testWave4AndBuild17SettingsSurviveMigration() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RenderTests.build10JSON.utf8)) as? [String: Any])
        for oldMode in [nil, "centered"] {
            var fields = original
            fields["closeUpShading"] = "playedBrighter"
            fields["playheadMode"] = oldMode
            fields["endZoom"] = 2
            func decode() throws -> CueAppearance {
                try JSONDecoder().decode(CueAppearance.self, from: JSONSerialization.data(withJSONObject: fields))
            }
            let old = try decode()
            XCTAssertEqual(old.centerAtStart, oldMode != nil)
            XCTAssertEqual(old.centerAtEnd, oldMode != nil)
            XCTAssertFalse(old.dimPlayedCloseUp)
            XCTAssertEqual(old.endZoom, .two)
            fields["centerAtStart"] = true
            fields["centerAtEnd"] = false
            fields["dimPlayedCloseUp"] = true
            let mixed = try decode()
            XCTAssertTrue(mixed.centerAtStart)
            XCTAssertFalse(mixed.centerAtEnd)
            XCTAssertTrue(mixed.dimPlayedCloseUp)
            XCTAssertEqual(try JSONDecoder().decode(CueAppearance.self, from: JSONEncoder().encode(mixed)), mixed)
        }
    }

    /// Playhead in the middle of the close-up at the first and last frame, empty panel beyond
    /// the track, and the full-track box kept inside the track.
    func testCenteredPictureAtBothEnds() throws {
        let track = BaselineTests.syntheticTrack()
        let appearance = CueAppearance()
        let layout = appearance.layout
        let detail = try XCTUnwrap(layout.detail)
        let timeline = ClipTimeline(duration: track.seconds)
        let paper = CuePicture.paper
        for frame in [0, track.frames] {
            let image = CountdownTests.render(track, timeline: timeline, position: frame, appearance: appearance)
            let cursor = CGRect(x: detail.midX - 3, y: detail.minY + 10, width: 6, height: detail.height - 20)
            XCTAssertGreaterThan(CountdownTests.count(paper, in: image, cursor), 200, "cursor centred @\(frame)")
            // The half beyond the track holds no waveform colour.
            let empty = frame == 0
                ? CGRect(x: detail.minX + 4, y: detail.minY + 4, width: detail.width / 2 - 12, height: detail.height - 8)
                : CGRect(x: detail.midX + 8, y: detail.minY + 4, width: detail.width / 2 - 12, height: detail.height - 8)
            let colors = [CueAppearance.defaultDetail.cgColor, CueColor(0.32, 0.48, 0.47).cgColor]
            for color in colors {
                XCTAssertEqual(CountdownTests.count(color, in: image, empty), 0, "empty half @\(frame)")
            }
        }
        // The build 10 look still matches its baseline at both ends.
        for frame in [0, track.frames] {
            let image = BaselineTests.render(track, frame: frame, label: CueLabel(text: "Baseline Track"),
                                             appearance: .build10)
            XCTAssertEqual(BaselineTests.hash(Data(image)), BaselineTests.expected["default@\(frame)"])
        }
    }
}

import CueCore
import XCTest

final class PictureArrangementTests: XCTestCase {
    func testNormalisationKeepsKnownOrderAndAppendsMissingPanes() {
        let standard: [PicturePane] = [.title, .fullTrack, .closeUp, .clocks]
        XCTAssertEqual(PicturePane.defaultOrder, standard)
        XCTAssertEqual(PicturePane.normalised([]), standard)
        XCTAssertEqual(PicturePane.normalised(["futurePane"]), standard)
        XCTAssertEqual(PicturePane.normalised(["clocks", "futurePane", "clocks", "closeUp"]),
                       [.clocks, .closeUp, .title, .fullTrack])
        var appearance = CueAppearance()
        appearance.paneOrder = [.fullTrack, .fullTrack]
        XCTAssertEqual(appearance.paneOrder, [.fullTrack, .title, .closeUp, .clocks])
    }

    func testArrangementRoundTripsAndEachFieldAffectsSharedSettings() throws {
        let original = CueJob(source: URL(fileURLWithPath: "/tmp/music.wav"))
        var edits: [CueAppearance] = []
        var look = original.appearance
        look.paneOrder = [.fullTrack, .title, .closeUp, .clocks]
        edits.append(look)
        look = original.appearance
        look.offsets = PaneOffsets(title: -9, fullTrack: 11, closeUp: 2, clocks: -1)
        edits.append(look)
        look = original.appearance
        look.titleAlignment = .center
        edits.append(look)
        look = original.appearance
        look.leftClock = .remaining
        edits.append(look)

        for change in edits {
            var source = original
            source.appearance = change
            XCTAssertNotEqual(source.appearanceSnapshot, original.appearanceSnapshot)
            XCTAssertFalse(source.sharesSettings(with: original))
            var target = original
            target.adoptSharedSettings(from: source)
            XCTAssertEqual(target.appearance, change)
            XCTAssertTrue(target.sharesSettings(with: source))
            let data = try JSONEncoder().encode(target)
            XCTAssertEqual(try JSONDecoder().decode(CueJob.self, from: data), target)
        }
    }
}

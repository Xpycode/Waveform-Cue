import XCTest
@testable import CueCore

final class FilenameTemplateTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var date: Date { Date(timeIntervalSince1970: 1_795_000_000) } // 2026-11-18 UTC

    func testDefaultTemplate() {
        XCTAssertEqual(FilenameTemplate.defaultTemplate, "{name} - Cue")
        XCTAssertEqual(FilenameTemplate.expand("{name} - Cue", name: "Intro", preset: "P", timeZone: utc), "Intro - Cue")
    }

    func testTokens() {
        let stamp = FilenameTemplate.expand("{date}", name: "x", preset: "p", date: date, timeZone: utc)
        XCTAssertEqual(stamp.count, 10)
        XCTAssertTrue(stamp.hasPrefix("2026-11-"), stamp)
        XCTAssertEqual(FilenameTemplate.expand("{name}_{preset}", name: "Show", preset: "AVC-Intra 100 · 1080i50", timeZone: utc),
                       "Show_AVC-Intra 100 · 1080i50")
        XCTAssertEqual(FilenameTemplate.expand("{date}", name: "x", preset: "p",
                                               date: Date(timeIntervalSince1970: 0), timeZone: utc), "1970-01-01")
    }

    func testStripsSeparatorsAndColons() {
        XCTAssertEqual(FilenameTemplate.expand("{name}", name: "a/b\\c:d", preset: "p", timeZone: utc), "abcd")
        XCTAssertEqual(FilenameTemplate.expand("../{name}", name: "x", preset: "p", timeZone: utc), "x")
        XCTAssertEqual(FilenameTemplate.expand("Take: 1/2", name: "x", preset: "p", timeZone: utc), "Take 12")
        XCTAssertEqual(FilenameTemplate.expand("a\nb", name: "x", preset: "p", timeZone: utc), "ab")
    }

    func testEmptyResultsFallBack() {
        XCTAssertEqual(FilenameTemplate.expand("", name: "Intro", preset: "p", timeZone: utc), "Intro - Cue")
        XCTAssertEqual(FilenameTemplate.expand("   ", name: "Intro", preset: "p", timeZone: utc), "Intro - Cue")
        XCTAssertEqual(FilenameTemplate.expand("{name}", name: "///", preset: "p", timeZone: utc), "Cue")
        XCTAssertEqual(FilenameTemplate.expand(".{name}", name: "hidden", preset: "p", timeZone: utc), "hidden")
    }

    func testResolveFreeName() {
        let name = FilenameTemplate.resolve("{name} - Cue", name: "Intro", preset: "p", timeZone: utc, exists: { _ in false })
        XCTAssertEqual(name, "Intro - Cue.mxf")
    }

    func testResolveCollisionsAddSuffixes() {
        var taken: Set<String> = ["Intro - Cue.mxf"]
        XCTAssertEqual(FilenameTemplate.resolve("{name} - Cue", name: "Intro", preset: "p", timeZone: utc,
                                                exists: { taken.contains($0) }), "Intro - Cue 2.mxf")
        taken.insert("Intro - Cue 2.mxf")
        XCTAssertEqual(FilenameTemplate.resolve("{name} - Cue", name: "Intro", preset: "p", timeZone: utc,
                                                exists: { taken.contains($0) }), "Intro - Cue 3.mxf")
        taken.insert("Intro - Cue 3.mxf")
        XCTAssertEqual(FilenameTemplate.resolve("{name} - Cue", name: "Intro", preset: "p", timeZone: utc,
                                                exists: { taken.contains($0) }), "Intro - Cue 4.mxf")
    }

    func testResolveCustomExtensionAndCheckedNames() {
        var asked: [String] = []
        let name = FilenameTemplate.resolve("{name}", name: "A", preset: "p", timeZone: utc, fileExtension: "mov",
                                            exists: { asked.append($0); return asked.count < 2 })
        XCTAssertEqual(asked, ["A.mov", "A 2.mov"])
        XCTAssertEqual(name, "A 2.mov")
    }
}

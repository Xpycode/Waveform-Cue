import XCTest
@testable import CueCore

final class Build17LayoutTests: XCTestCase {
    /// Measured with the original build 17 renderer. Exclude glyph widths, which can vary by OS.
    private struct Geometry: Codable, Equatable {
        var fullTrack: CGRect
        var closeUp: CGRect?
        var clockBaseline: CGFloat
        let elapsedPoints, remainingPoints: CGFloat
        let titlePoints: CGFloat
        let titleOrigin: CGPoint
        let titleHeight: CGFloat
        let fits: Bool

        init(_ layout: CueLayout) {
            let (_, box) = CuePicture.caption(CueLabel(text: "Cue", position: CGPoint(x: 0, y: 1)), layout: layout)
            fullTrack = layout.overview
            closeUp = layout.detail
            clockBaseline = layout.clockBaseline
            elapsedPoints = layout.elapsedSize.points
            remainingPoints = layout.remainingSize.points
            titlePoints = layout.titleSize
            titleOrigin = box.origin
            titleHeight = box.height
            fits = layout.fits
        }
    }

    private func measurements() throws -> [String: Geometry] {
        let zones: [(String, SafeZones)] = [
            ("none", .none),
            ("evs", .init(preset: .evsOSD)),
            ("asymmetric", .init(preset: .custom, custom: .init(top: 5, bottom: 12, left: 3, right: 8))),
            ("narrow", .init(preset: .custom, custom: .init(left: 30, right: 30))),
            ("compressed", .init(preset: .custom, custom: .init(top: 30, bottom: 30, left: 30, right: 30)))
        ]
        let url = try XCTUnwrap(Bundle.module.url(forResource: "build17-job", withExtension: "json"))
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var saved = try XCTUnwrap(job["appearance"] as? [String: Any])
        var rows: [String: Geometry] = [:]
        for position in ["above", "below"] {
            saved["clockPosition"] = position
            let migrated = try JSONDecoder().decode(CueAppearance.self, from: JSONSerialization.data(withJSONObject: saved))
            for zoom in [ZoomWindow.off, .auto] {
                for elapsed in ClockSize.allCases {
                    for remaining in ClockSize.allCases {
                        for (zone, safe) in zones {
                            var appearance = migrated
                            appearance.zoom = zoom
                            appearance.elapsed.size = elapsed
                            appearance.remaining.size = remaining
                            appearance.safeZones = safe
                            let key = "\(position)/\(zoom)/\(elapsed.rawValue)/\(remaining.rawValue)/\(zone)"
                            rows[key] = Geometry(appearance.layout)
                        }
                    }
                }
            }
        }
        return rows
    }

    func testGeometryMatchesBuild17() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "build17-layouts", withExtension: "json"))
        let expected = try JSONDecoder().decode([String: Geometry].self, from: Data(contentsOf: url))
        let actual = try measurements()
        XCTAssertEqual(expected.count, 320)
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        var spacingCorrections = 0
        for (key, measured) in expected {
            var row = measured
            // At 30% on every edge build 17 could not export. Its pixel rounding left
            // gaps as small as 11.5. Only these Y coordinates change to keep 12 pixels.
            if key.hasSuffix("/compressed") {
                XCTAssertFalse(row.fits, key)
                row.fullTrack.origin.y -= 1
                row.closeUp = row.closeUp?.offsetBy(dx: 0, dy: -2)
                row.clockBaseline -= key.hasPrefix("above/") ? 1 : 2
                spacingCorrections += 1
            }
            XCTAssertEqual(actual[key], row, key)
        }
        XCTAssertEqual(spacingCorrections, 64)
    }
}

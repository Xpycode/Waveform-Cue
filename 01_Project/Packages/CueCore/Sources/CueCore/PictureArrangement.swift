public enum PicturePane: String, Codable, CaseIterable, Sendable {
    case title, fullTrack, closeUp, clocks

    public static let defaultOrder: [Self] = [.title, .fullTrack, .closeUp, .clocks]

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .fullTrack: return "Full track"
        case .closeUp: return "Close-up"
        case .clocks: return "Clocks"
        }
    }

    public static func normalised(_ saved: [String]) -> [Self] {
        var result: [Self] = []
        for name in saved {
            if let pane = Self(rawValue: name), !result.contains(pane) {
                result.append(pane)
            }
        }
        return result + defaultOrder.filter { !result.contains($0) }
    }
}

public enum TitleAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right

    init(legacyX: Double) {
        if legacyX < 1.0 / 3.0 { self = .left }
        else if legacyX < 2.0 / 3.0 { self = .center }
        else { self = .right }
    }
}

public enum LeftClock: String, Codable, CaseIterable, Sendable {
    case elapsed, remaining
}

/// Signed vertical displacement in whole picture pixels. Positive values move a pane up.
public struct PaneOffsets: Codable, Equatable, Sendable {
    public var title, fullTrack, closeUp, clocks: Int

    public init(title: Int = 0, fullTrack: Int = 0, closeUp: Int = 0, clocks: Int = 0) {
        self.title = title
        self.fullTrack = fullTrack
        self.closeUp = closeUp
        self.clocks = clocks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? values.decode(Int.self, forKey: .title)) ?? 0
        fullTrack = (try? values.decode(Int.self, forKey: .fullTrack)) ?? 0
        closeUp = (try? values.decode(Int.self, forKey: .closeUp)) ?? 0
        clocks = (try? values.decode(Int.self, forKey: .clocks)) ?? 0
    }
}

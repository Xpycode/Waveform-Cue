import Foundation

/// A non-drop-frame timecode (HH:MM:SS:FF) at 25 or 50 frames per second.
public struct Timecode: Sendable, Equatable, Hashable, CustomStringConvertible {
    public static let supportedRates = [25, 50]
    public static let start = Timecode(uncheckedHours: 0, minutes: 0, seconds: 0, frames: 0, fps: 25)

    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let fps: Int

    private init(uncheckedHours h: Int, minutes m: Int, seconds s: Int, frames f: Int, fps: Int) {
        hours = h; minutes = m; seconds = s; frames = f; self.fps = fps
    }

    /// Fails when a field is out of range (hours 0–23, minutes and seconds 0–59, frames below `fps`).
    public init?(hours: Int, minutes: Int, seconds: Int, frames: Int, fps: Int = 25) {
        guard Self.supportedRates.contains(fps), (0..<24).contains(hours), (0..<60).contains(minutes),
              (0..<60).contains(seconds), (0..<fps).contains(frames) else { return nil }
        self.init(uncheckedHours: hours, minutes: minutes, seconds: seconds, frames: frames, fps: fps)
    }

    /// Parses `HH:MM:SS:FF` (`;` or `.` before the frames is accepted too). Each field is one
    /// or two digits. Returns nil for anything else.
    public init?(_ text: String, fps: Int = 25) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { ":;.".contains($0) })
        guard parts.count == 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard (1...2).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        self.init(hours: values[0], minutes: values[1], seconds: values[2], frames: values[3], fps: fps)
    }

    /// The timecode of a frame count, wrapped into 24 hours (negative counts wrap backwards).
    public init(totalFrames: Int, fps: Int = 25) {
        precondition(Self.supportedRates.contains(fps), "Unsupported timecode rate")
        let day = 24 * 3600 * fps
        let n = ((totalFrames % day) + day) % day
        self.init(uncheckedHours: n / (3600 * fps), minutes: n / (60 * fps) % 60,
                  seconds: n / fps % 60, frames: n % fps, fps: fps)
    }

    public var totalFrames: Int { ((hours * 60 + minutes) * 60 + seconds) * fps + frames }

    public var description: String { formatted }

    public var formatted: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    /// This timecode moved earlier by `seconds` (a pre-roll), wrapping past midnight.
    /// 00:00:00:00 minus 5 s is 23:59:55:00.
    public func subtracting(seconds delta: Double) -> Timecode {
        Timecode(totalFrames: totalFrames - Int((delta * Double(fps)).rounded()), fps: fps)
    }

    public func adding(seconds delta: Double) -> Timecode { subtracting(seconds: -delta) }

    /// The same time of day at another frame rate (frames scale 25 <-> 50).
    public func converted(toFPS rate: Int) -> Timecode {
        guard rate != fps, Self.supportedRates.contains(rate) else { return self }
        let f = rate > fps ? frames * (rate / fps) : frames / (fps / rate)
        return Timecode(uncheckedHours: hours, minutes: minutes, seconds: seconds, frames: f, fps: rate)
    }
}

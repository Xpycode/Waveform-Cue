import Foundation

/// Output file names from a template such as `{name} - Cue`. Tokens: `{name}` (source name),
/// `{preset}` (preset name) and `{date}` (yyyy-MM-dd).
public enum FilenameTemplate {
    public static let defaultTemplate = "{name} - Cue"
    static let fallbackStem = "Cue"

    /// Expands the tokens and strips path separators, colons and control characters.
    /// Never returns an empty stem or one that starts with a dot.
    public static func expand(_ template: String, name: String, preset: String, date: Date = Date(),
                              timeZone: TimeZone = .current) -> String {
        let source = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTemplate : template
        let expanded = source
            .replacingOccurrences(of: "{name}", with: sanitize(name))
            .replacingOccurrences(of: "{preset}", with: sanitize(preset))
            .replacingOccurrences(of: "{date}", with: dateString(date, timeZone: timeZone))
        var stem = sanitize(expanded)
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? fallbackStem : stem
    }

    /// Like `expand`, then adds " 2", " 3", … until `exists` reports the file name is free.
    /// `exists` receives the full file name including the extension. Returns the file name.
    public static func resolve(_ template: String, name: String, preset: String, date: Date = Date(),
                               timeZone: TimeZone = .current, fileExtension: String = "mxf",
                               exists: (String) -> Bool) -> String {
        let stem = expand(template, name: name, preset: preset, date: date, timeZone: timeZone)
        let ext = fileExtension.isEmpty ? "" : "." + fileExtension
        var candidate = stem + ext
        var n = 2
        while exists(candidate) {
            candidate = "\(stem) \(n)\(ext)"
            n += 1
        }
        return candidate
    }

    static func sanitize(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !banned.contains($0) }))
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

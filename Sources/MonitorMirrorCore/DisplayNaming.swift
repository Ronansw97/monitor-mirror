import Foundation

/// Pure formatting rules that turn raw display metadata into the short, wide-tracked
/// labels the design calls for ("STUDIO", "5K · 60HZ").
public enum DisplayNaming {

    /// Longest label that still fits an 84pt cell at 9pt monospace with .08em tracking.
    static let maxNameLength = 10

    /// Words that carry no identifying information once uppercased and truncated.
    private static let genericTokens: Set<String> = [
        "COLOR", "DISPLAY", "MONITOR", "LCD", "LED", "SCREEN", "GENERIC", "UNKNOWN",
    ]

    /// Derives the short cell label from `NSScreen.localizedName`.
    ///
    /// macOS already disambiguates identical panels as "H27T27 (2)"; that suffix is
    /// preserved as a compact "·2" so two of the same monitor stay tellable apart.
    public static func shortName(from rawName: String?, isBuiltIn: Bool) -> String {
        guard let rawName, !rawName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return isBuiltIn ? "BUILT-IN" : "DISPLAY"
        }

        let (base, ordinal) = splitTrailingOrdinal(rawName.trimmingCharacters(in: .whitespaces))

        let tokens = base
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Prefer the first token that actually identifies the panel; fall back to the
        // first token so a name made entirely of generic words still yields something.
        let chosen = tokens.first(where: { !genericTokens.contains($0) }) ?? tokens.first

        guard var name = chosen, !name.isEmpty else {
            return isBuiltIn ? "BUILT-IN" : "DISPLAY"
        }

        if isBuiltIn && genericTokens.contains(name) { name = "BUILT-IN" }

        let suffix = ordinal.map { "·\($0)" } ?? ""
        let budget = maxNameLength - suffix.count
        if name.count > budget { name = String(name.prefix(max(1, budget))) }
        return name + suffix
    }

    /// Splits "H27T27 (2)" into ("H27T27", 2). Returns a nil ordinal when there is no suffix.
    private static func splitTrailingOrdinal(_ name: String) -> (String, Int?) {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return (name, nil) }
        let inside = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard let value = Int(inside), value > 0 else { return (name, nil) }
        let base = String(name[name.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? name : base, value)
    }

    /// Ensures every label in a set is unique, appending ·2, ·3 … to later duplicates.
    ///
    /// macOS usually does this for us, but it does not when a remembered display is
    /// offline and its cached name collides with a newly attached twin.
    public static func disambiguate(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            guard count > 1 else { return name }
            let suffix = "·\(count)"
            let budget = maxNameLength - suffix.count
            let trimmed = name.count > budget ? String(name.prefix(max(1, budget))) : name
            return trimmed + suffix
        }
    }

    /// "5K", "QHD", "1200P" … derived from the panel's native pixel dimensions.
    public static func resolutionClass(pixelWidth: Int, pixelHeight: Int) -> String {
        switch pixelWidth {
        case 7680...: return "8K"
        case 5120...: return "5K"
        case 3840...: return "4K"
        case 3440...: return "UWQHD"
        case 2560...: return "QHD"
        case 1920...: return "FHD"
        case 1280...: return "HD"
        default: return pixelHeight > 0 ? "\(pixelHeight)P" : "—"
        }
    }

    /// The full spec line, e.g. "5K · 60HZ". The refresh half is dropped when the
    /// window server reports 0 Hz, which it does for some built-in and virtual panels.
    public static func spec(pixelWidth: Int, pixelHeight: Int, refreshHz: Double) -> String {
        let resolution = resolutionClass(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard refreshHz >= 1 else { return resolution }
        return "\(resolution) · \(Int(refreshHz.rounded()))HZ"
    }
}

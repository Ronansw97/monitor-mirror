import XCTest
@testable import MonitorMirrorCore

final class DisplayNamingTests: XCTestCase {

    // MARK: - Short names

    func testTakesTheFirstIdentifyingWord() {
        XCTAssertEqual(DisplayNaming.shortName(from: "Studio Display", isBuiltIn: false), "STUDIO")
        XCTAssertEqual(DisplayNaming.shortName(from: "DELL U2720Q", isBuiltIn: false), "DELL")
        XCTAssertEqual(DisplayNaming.shortName(from: "LG UltraFine", isBuiltIn: false), "LG")
        XCTAssertEqual(DisplayNaming.shortName(from: "M32UC", isBuiltIn: false), "M32UC")
    }

    func testSkipsGenericWords() {
        // "Color LCD" is what macOS calls a built-in panel; neither word identifies it.
        XCTAssertEqual(DisplayNaming.shortName(from: "Color LCD", isBuiltIn: true), "BUILT-IN")
        XCTAssertEqual(DisplayNaming.shortName(from: "Display P3", isBuiltIn: false), "P3")
    }

    func testKeepsMacOSDisambiguationSuffix() {
        XCTAssertEqual(DisplayNaming.shortName(from: "H27T27 (1)", isBuiltIn: false), "H27T27·1")
        XCTAssertEqual(DisplayNaming.shortName(from: "H27T27 (2)", isBuiltIn: false), "H27T27·2")
    }

    func testIgnoresNonNumericParentheses() {
        XCTAssertEqual(DisplayNaming.shortName(from: "Acme (Pro)", isBuiltIn: false), "ACME")
    }

    func testTruncatesLongNamesWithoutLosingTheSuffix() {
        let name = DisplayNaming.shortName(from: "SUPERCALIFRAGILISTIC (2)", isBuiltIn: false)
        XCTAssertEqual(name.count, DisplayNaming.maxNameLength)
        XCTAssertTrue(name.hasSuffix("·2"), name)
    }

    func testFallsBackWhenTheNameIsMissingOrEmpty() {
        XCTAssertEqual(DisplayNaming.shortName(from: nil, isBuiltIn: false), "DISPLAY")
        XCTAssertEqual(DisplayNaming.shortName(from: "   ", isBuiltIn: true), "BUILT-IN")
        // A name with no alphanumerics at all must still produce something.
        XCTAssertEqual(DisplayNaming.shortName(from: "---", isBuiltIn: false), "DISPLAY")
    }

    // MARK: - Disambiguation

    func testDisambiguateOnlySuffixesRepeats() {
        XCTAssertEqual(
            DisplayNaming.disambiguate(["DELL", "LG", "DELL", "DELL"]),
            ["DELL", "LG", "DELL·2", "DELL·3"]
        )
    }

    func testDisambiguateKeepsLabelsWithinTheWidthBudget() {
        let names = DisplayNaming.disambiguate(Array(repeating: "ABCDEFGHIJ", count: 3))
        XCTAssertTrue(names.allSatisfy { $0.count <= DisplayNaming.maxNameLength }, "\(names)")
        XCTAssertEqual(Set(names).count, 3, "labels must stay distinct after truncation")
    }

    // MARK: - Specs

    func testResolutionClasses() {
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 7680, pixelHeight: 4320), "8K")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 5120, pixelHeight: 2880), "5K")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 3840, pixelHeight: 2160), "4K")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 3440, pixelHeight: 1440), "UWQHD")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 2560, pixelHeight: 1440), "QHD")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 1920, pixelHeight: 1080), "FHD")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 1440, pixelHeight: 900), "HD")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 1024, pixelHeight: 768), "768P")
        XCTAssertEqual(DisplayNaming.resolutionClass(pixelWidth: 0, pixelHeight: 0), "—")
    }

    func testSpecMatchesTheDesign() {
        XCTAssertEqual(DisplayNaming.spec(pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60), "5K · 60HZ")
        XCTAssertEqual(DisplayNaming.spec(pixelWidth: 2560, pixelHeight: 1440, refreshHz: 144), "QHD · 144HZ")
    }

    func testSpecRoundsAwkwardRefreshRates() {
        // Panels commonly report 59.94 or 119.88.
        XCTAssertEqual(DisplayNaming.spec(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 59.94), "4K · 60HZ")
        XCTAssertEqual(DisplayNaming.spec(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 119.88), "4K · 120HZ")
    }

    func testSpecDropsRefreshWhenTheSystemReportsNone() {
        // Built-in and virtual displays often report 0 Hz.
        XCTAssertEqual(DisplayNaming.spec(pixelWidth: 3024, pixelHeight: 1964, refreshHz: 0), "QHD")
    }
}

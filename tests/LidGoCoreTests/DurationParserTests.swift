import LidGoCore

@MainActor
final class DurationParserTests {
    func testParsesSupportedDurationForms() {
        XCTAssertEqual(DurationParser.parse("90m"), 5_400)
        XCTAssertEqual(DurationParser.parse("2h"), 7_200)
        XCTAssertEqual(DurationParser.parse("1h30m"), 5_400)
        XCTAssertEqual(DurationParser.parse("1m"), 60)
    }

    func testRejectsMalformedOrNonPositiveDurations() {
        for value in ["", "0m", "0h", "1h0m", "1h-5m", "1.5h", "90", "m", "1m2h"] {
            XCTAssertNil(DurationParser.parse(value), "应拒绝 \(value)")
        }
    }

    func testConfigValidationAcceptsDefaultsAndRejectsUnsafeValues() throws {
        let validatedDefault = try LidGoConfig.default.validated()
        XCTAssertEqual(validatedDefault, .default)
        XCTAssertThrowsError(
            try LidGoConfig(defaultDurationSeconds: 0, batteryCutoffPercent: 15).validated()
        )
        XCTAssertThrowsError(
            try LidGoConfig(defaultDurationSeconds: 3_600, batteryCutoffPercent: 0).validated()
        )
        XCTAssertThrowsError(
            try LidGoConfig(defaultDurationSeconds: 3_600, batteryCutoffPercent: 100).validated()
        )
    }
}

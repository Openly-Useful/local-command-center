import XCTest
@testable import CommandCenterCore

final class TerminalTextSanitizerTests: XCTestCase {
    func testStripsCSIColorsAndCursorControls() {
        let input = "plain \u{1B}[31mred\u{1B}[0m\u{1B}[2J done"
        let result = TerminalTextSanitizer.sanitize(input)

        XCTAssertEqual(result.text, "plain red done")
        XCTAssertTrue(result.removedControlSequences)
        XCTAssertFalse(result.messageWasTruncated)
    }

    func testStripsOSCHyperlinksAndStringControls() {
        let input = "\u{1B}]8;;https://example.invalid\u{7}label\u{1B}]8;;\u{1B}\\" +
            "\u{1B}Pprivate payload\u{1B}\\safe"
        let result = TerminalTextSanitizer.sanitize(input)

        XCTAssertEqual(result.text, "labelsafe")
        XCTAssertTrue(result.removedControlSequences)
    }

    func testStripsC0AndC1ControlsButPreservesTabAndNewline() {
        let input = "a\u{0}b\t c\r\nd\u{85}e"
        let result = TerminalTextSanitizer.sanitize(input)

        XCTAssertEqual(result.text, "ab\t c\nde")
        XCTAssertTrue(result.removedControlSequences)
    }

    func testBoundsEveryLineAndContinuesAtNextLine() {
        let result = TerminalTextSanitizer.sanitize(
            "abcdef\nxy\n12345",
            limits: TextSanitizationLimits(maximumLineBytes: 4, maximumMessageBytes: 100)
        )

        XCTAssertEqual(result.text, "abcd\nxy\n1234")
        XCTAssertEqual(result.truncatedLineCount, 2)
        XCTAssertFalse(result.messageWasTruncated)
    }

    func testByteBoundsDoNotSplitExtendedGraphemeClusters() {
        let result = TerminalTextSanitizer.sanitize(
            "éé\n👍🏽z",
            limits: TextSanitizationLimits(maximumLineBytes: 5, maximumMessageBytes: 100)
        )

        XCTAssertEqual(result.text, "éé\nz")
        XCTAssertEqual(result.truncatedLineCount, 1)
        XCTAssertTrue(result.text.canBeConverted(to: .utf8))
        XCTAssertFalse(result.text.contains("👍"), "A modifier-bearing emoji must be retained or dropped whole")
    }

    func testMessageBoundIsStrict() {
        let result = TerminalTextSanitizer.sanitize(
            "1234\n5678",
            limits: TextSanitizationLimits(maximumLineBytes: 10, maximumMessageBytes: 6)
        )

        XCTAssertEqual(result.text, "1234\n5")
        XCTAssertEqual(result.text.utf8.count, 6)
        XCTAssertTrue(result.messageWasTruncated)
    }

    func testZeroBoundsProduceEmptyTruncatedOutput() {
        let result = TerminalTextSanitizer.sanitize(
            "visible",
            limits: TextSanitizationLimits(maximumLineBytes: 0, maximumMessageBytes: 0)
        )

        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.messageWasTruncated)
    }
}

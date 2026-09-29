import XCTest
@testable import KnifeKit

final class StyledScreenAnsiTests: XCTestCase {
    func testRunsBecomeSGR() {
        let screen = StyledScreen(lines: [
            [TermRun(t: "ab", f: 1, s: StyledScreen.styleBold), TermRun(t: "c")],
            [],
            [TermRun(t: "x", g: StyledScreen.trueColorFlag | 0x10_20_30)],
        ])
        let out = screen.ansi()
        XCTAssertTrue(out.hasPrefix("\u{1b}[?7l\u{1b}[H\u{1b}[2K\u{1b}[0;1;38;5;1mab\u{1b}[0mc\u{1b}[0m\r\n"))
        XCTAssertTrue(out.contains("\r\n\u{1b}[2K\u{1b}[0m\r\n"))          // the empty line is still cleared
        XCTAssertTrue(out.contains("\u{1b}[0;48;2;16;32;48mx"))
        XCTAssertTrue(out.hasSuffix("\u{1b}[0m\u{1b}[J"))
    }
}

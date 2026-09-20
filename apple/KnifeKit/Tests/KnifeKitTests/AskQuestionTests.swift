import XCTest
@testable import KnifeKit

final class AskQuestionTests: XCTestCase {
    // two real transcript lines (Claude Code 2.1.278): an AskUserQuestion call and its answered result
    func testQuestionCardAndAnswers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AskFixture.txt")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let asked = ChatTranscript.parse(jsonlLines: Array(lines.prefix(1)))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].kind, .assistant)
        XCTAssertEqual(asked[0].ask?.map(\.question), ["Pick a color", "Pick a size"])
        XCTAssertEqual(asked[0].ask?[0].options.map(\.label), ["Red", "Green", "Blue"])
        XCTAssertNil(asked[0].answers)
        let answered = ChatTranscript.parse(jsonlLines: lines)
        XCTAssertEqual(answered.count, 1)
        XCTAssertEqual(answered[0].answers, ["Pick a color": "Green", "Pick a size": "Small"])
        XCTAssertTrue(answered[0].text.contains("→ Green"))
    }
}

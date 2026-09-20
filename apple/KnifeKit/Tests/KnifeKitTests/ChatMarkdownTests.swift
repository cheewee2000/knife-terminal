import XCTest
@testable import KnifeKit

final class ChatMarkdownTests: XCTestCase {
    func testBlocks() {
        let md = "## Plan\nFirst **do** this\nand that.\n\n- one\n  - nested\n1. step\n\n```swift\nlet x = 1\n```\n| a | b |\n|---|:-:|\n| 1 | 2 |\n> note\n---\ntail"
        XCTAssertEqual(ChatMarkdown.blocks(md), [
            .heading(level: 2, text: "Plan"),
            .text("First **do** this\nand that."),
            .item(depth: 0, marker: "•", text: "one"),
            .item(depth: 1, marker: "•", text: "nested"),
            .item(depth: 0, marker: "1.", text: "step"),
            .code(["let x = 1"]),
            .table([["a", "b"], ["1", "2"]]),
            .quote("note"),
            .rule,
            .text("tail"),
        ])
    }
}

import XCTest
@testable import KnifeKit

/// Inputs the chat parsers used to get wrong.
final class ParserEdgeTests: XCTestCase {
    private func user(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "u", "message": ["role": "user", "content": text]])
        return String(data: data, encoding: .utf8)!
    }

    // only wrapper tags are plumbing; a prompt that merely starts with "<" is the user's
    func testPromptStartingWithAngleBracketIsKept() {
        for prompt in ["<div> will not center, why?", "<3 thanks", "<T> where T: Sendable — explain"] {
            XCTAssertEqual(ChatTranscript.parse(jsonlLines: [user(prompt)]).map(\.text), [prompt])
        }
    }

    func testWrapperTagsStayHidden() {
        for wrapper in ["<task-notification>\n<task-id>a</task-id>", "<local-command-stdout>ok</local-command-stdout>",
                        "<local-command-caveat>Caveat: …</local-command-caveat>", "<bash-input>ls</bash-input>",
                        "<bash-stdout>x</bash-stdout>", "<system-reminder>…</system-reminder>",
                        "<command-message>loop</command-message>", "<environment_context>\n<cwd>/</cwd>",
                        "<pasted_content id=\"1\">x</pasted_content>"] {
            XCTAssertEqual(ChatTranscript.parse(jsonlLines: [user(wrapper)]).count, 0, wrapper)
        }
    }

    // a fence closes only on a bare fence at least as long as the one that opened it
    func testLongerFenceHoldsAShorterOne() {
        XCTAssertEqual(ChatMarkdown.blocks("````md\n```\ninner\n```\n````\nafter"), [.code(["```", "inner", "```"]), .text("after")])
        XCTAssertEqual(ChatMarkdown.blocks("```markdown\n```bash\nls\n```"), [.code(["```bash", "ls"])])
    }

    // Codex: only the assistant's messages are assistant bubbles
    func testCodexDeveloperMessagesAreNotAssistantBubbles() {
        let line = ##"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>sandbox"}]}}"##
        XCTAssertEqual(ChatTranscript.parseCodex(jsonlLines: [line]).count, 0)
    }

    // an all-digit owner is not an ssh port
    func testWebURLKeepsNumericOwner() {
        XCTAssertEqual(ProjectRef.webURL(forRemote: "git@github.com:123/repo.git")?.absoluteString, "https://github.com/123/repo")
        XCTAssertEqual(ProjectRef.webURL(forRemote: "ssh://git@github.com:22/o/r.git")?.absoluteString, "https://github.com/o/r")
        XCTAssertEqual(ProjectRef.webURL(forRemote: "ssh://git@github.com/o/r")?.absoluteString, "https://github.com/o/r")
    }
}

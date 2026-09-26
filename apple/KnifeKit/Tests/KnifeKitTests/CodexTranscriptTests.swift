import XCTest
@testable import KnifeKit

final class CodexTranscriptTests: XCTestCase {
    func testParsesCodexRollout() {
        let lines = [
            ##"{"timestamp":"t0","type":"session_meta","payload":{"id":"s","cwd":"/p"}}"##,
            ##"{"timestamp":"t1","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/</cwd>"}]}}"##,
            ##"{"timestamp":"t1","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Context from my IDE setup:\n..."}]}}"##,
            ##"{"timestamp":"t2","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}"##,
            ##"{"timestamp":"t2","type":"event_msg","payload":{"type":"user_message","message":"fix the bug"}}"##,
            ##"{"timestamp":"t3","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"cat app.js\"],\"workdir\":\"/p\"}","call_id":"call_1"}}"##,
            ##"{"timestamp":"t4","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"##,
            ##"{"timestamp":"t4","type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"##,
        ]
        let msgs = ChatTranscript.parseCodex(jsonlLines: lines)
        XCTAssertEqual(msgs.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(msgs[0].text, "fix the bug")
        XCTAssertEqual(msgs[1].text, "shell · cat app.js")
        XCTAssertEqual(msgs[1].id, "call_1")
        XCTAssertEqual(msgs[2].text, "Done.")
    }
}

extension CodexTranscriptTests {
    // request_user_input_async as Codex 0.154 writes it, answered as a quoted user message
    func testQuestionCard() {
        let lines = [
            ##"{"timestamp":"t1","type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"Pick a color\",\"options\":[\"Red\",\"Green\"]}]}","call_id":"call_q"}}"##,
            ##"{"timestamp":"t2","type":"response_item","payload":{"type":"function_call_output","call_id":"call_q","output":"{\"accepted\":true}"}}"##,
            ##"{"timestamp":"t3","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"> Pick a color\n\nGreen"}]}}"##,
        ]
        let asked = ChatTranscript.parseCodex(jsonlLines: Array(lines.prefix(2)))
        XCTAssertEqual(asked.map(\.kind), [.assistant])
        XCTAssertEqual(asked[0].ask?[0].options.map(\.label), ["Red", "Green"])
        XCTAssertNil(asked[0].answers)
        let answered = ChatTranscript.parseCodex(jsonlLines: lines)
        XCTAssertEqual(answered.count, 1)
        XCTAssertEqual(answered[0].answers, ["Pick a color": "Green"])
        XCTAssertTrue(answered[0].text.hasSuffix("→ Green"))
    }
}

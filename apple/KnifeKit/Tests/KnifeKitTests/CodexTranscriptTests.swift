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

import XCTest
@testable import KnifeKit

final class QueuedPromptTests: XCTestCase {
    func testQueuedPrompts() {
        let lines = [
            ##"{"type":"user","uuid":"u1","message":{"role":"user","content":"start"}}"##,
            ##"{"type":"queue-operation","operation":"enqueue","timestamp":"t1","content":"absorbed one"}"##,
            ##"{"type":"queue-operation","operation":"enqueue","timestamp":"t2","content":"<task-notification>x</task-notification>"}"##,
            ##"{"type":"queue-operation","operation":"remove","timestamp":"t3","content":"absorbed one","reason":"absorbed_mid_turn"}"##,
            ##"{"type":"attachment","uuid":"a1","attachment":{"type":"queued_command","prompt":"absorbed one","origin":{"kind":"human"}}}"##,
            ##"{"type":"queue-operation","operation":"dequeue","timestamp":"t4"}"##,
            ##"{"type":"queue-operation","operation":"enqueue","timestamp":"t5","content":"still waiting"}"##,
            ##"{"type":"user","uuid":"u2","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"}}"##,
        ]
        let m = ChatTranscript.parse(jsonlLines: lines)
        XCTAssertEqual(m.map(\.text), ["start", "absorbed one", "/model opus", "still waiting"])
        XCTAssertEqual(m.last?.detail, "queued")
        XCTAssertNil(m[1].detail)
    }
}

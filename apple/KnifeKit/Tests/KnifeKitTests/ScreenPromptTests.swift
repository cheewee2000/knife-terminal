import XCTest
@testable import KnifeKit

final class ScreenPromptTests: XCTestCase {
    let rule = String(repeating: "─", count: 60)

    // as Claude Code 2.1.278 draws a permission prompt
    func testPermissionPrompt() {
        let screen = """
        ❯ Test only: run the bash command: touch probe2.txt — nothing else.
          ⎿  $ touch probe2.txt
        \(rule)
         Bash command
         Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
           touch probe2.txt
           Create empty probe2 file
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don’t ask again for: touch *
           3. Yes, and switch to auto mode · auto mode handles these prompts for you
           4. No
         Esc to cancel · Tab to amend


        """
        let p = ScreenPrompt.parse(screen)
        XCTAssertEqual(p?.title, "Bash command")
        XCTAssertEqual(p?.body.last, "Do you want to proceed?")
        XCTAssertEqual(p?.body.contains("touch probe2.txt"), true)
        XCTAssertEqual(p?.options, ["Yes", "Yes, and don’t ask again for: touch *",
                                    "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"])
    }

    func testIdleScreenHasNoPrompt() {
        let screen = """
        ⏺ Done. 1. first thing  2. second thing
        \(rule)
        ❯ 
        \(rule)
          claude │ proj ░░░░░░░░░░ 6% │ 5h ░░░░░░░░░░ 4% (3h28m)
          ⏸ manual mode on · esc to interrupt
        """
        XCTAssertNil(ScreenPrompt.parse(screen))
    }
}

import AppSupport
import Testing

/// The one line the app's scripted commands leave in their `--result` file, read back by the mount check (roadmap 0039).
@Suite struct AutomationResultTests {
    @Test(
        arguments: [
            (AutomationResult.mounted(id: "R1", mountPoint: "/a b/Mounts/x"), "ok\tR1\t/a b/Mounts/x"),
            (.done, "ok"),
            (.failed("the agent did not answer"), "error\tthe agent did not answer")
        ] as [(AutomationResult, String)]
    )
    func aResultIsOneLineAndReadsBack(_ result: AutomationResult, _ line: String) {
        #expect(result.line == line)
        #expect(AutomationResult(line: line) == result)
        #expect(AutomationResult(line: line + "\n") == result, "a trailing newline is not part of it")
    }

    /// A tab or a newline in the text cannot split the line: they become spaces.
    @Test func anErrorKeepsToOneLine() {
        let result = AutomationResult.failed("a\tb\nc")
        #expect(result.line == "error\ta b c")
        #expect(AutomationResult(line: result.line) == .failed("a b c"))
    }

    @Test(arguments: ["", "ok\tonly-two", "ok\ta\tb\tc", "fine", "error"])
    func anythingElseIsNoResult(_ line: String) {
        #expect(AutomationResult(line: line) == nil)
    }
}

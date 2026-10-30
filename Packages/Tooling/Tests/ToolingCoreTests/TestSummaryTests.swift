import Testing
import ToolingCore

@Suite struct TestSummaryTests {
    @Test func keepsFailuresAndTotalsAndDropsPassingCases() {
        let output = """
            \u{1B}[1;32m✔\u{1B}[0m Test crcKnownVector() passed after 0.001 seconds.
            ✘ Test lookup() recorded an issue at A.swift:3:1: Expectation failed: x == y
            ✘ Test lookup() failed after 0.002 seconds with 1 issue.
            /src/A.swift:9:2: error: cannot find 'q' in scope
            ✔ Test run with 5 tests in 1 suite passed after 0.2 seconds.
            Compiling A.swift
            """
        let summary = TestSummary.reduce(output)
        #expect(
            summary == [
                "✘ Test lookup() recorded an issue at A.swift:3:1: Expectation failed: x == y",
                "✘ Test lookup() failed after 0.002 seconds with 1 issue.",
                "/src/A.swift:9:2: error: cannot find 'q' in scope",
                "✔ Test run with 5 tests in 1 suite passed after 0.2 seconds."
            ])
    }
}

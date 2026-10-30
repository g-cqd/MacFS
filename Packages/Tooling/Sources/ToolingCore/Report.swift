/// What a plan did: the commands it ran (or would run), and the ones that failed.
public struct Report: Sendable {
    public var lines: [String] = []
    public var failed: [Command] = []

    public var succeeded: Bool { failed.isEmpty }
}

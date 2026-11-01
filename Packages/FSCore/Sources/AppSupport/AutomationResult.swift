/// What one of the app's scripted commands came to, as the single line it writes to its `--result` file: the sandboxed app's
/// standard output is lost when `open` launches it, and the mount check (roadmap 0039) reads this line back.
///
///     ok<TAB>ID<TAB>MOUNT POINT    a mount
///     ok                           an unmount, or another command that succeeded
///     error<TAB>TEXT               a failure
public enum AutomationResult: Equatable, Sendable {
    case mounted(id: String, mountPoint: String)
    case done
    case failed(String)

    public var line: String {
        switch self {
            case .mounted(let id, let mountPoint): "ok\t\(Self.flat(id))\t\(Self.flat(mountPoint))"
            case .done: "ok"
            case .failed(let text): "error\t\(Self.flat(text))"
        }
    }

    /// The result a line says, or nil when it says none.
    public init?(line: String) {
        let text = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch (fields.first, fields.count) {
            case ("ok", 1): self = .done
            case ("ok", 3): self = .mounted(id: fields[1], mountPoint: fields[2])
            case ("error", 2): self = .failed(fields[1])
            default: return nil
        }
    }

    /// Tabs and newlines become spaces, so a field never splits the line.
    private static func flat(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }
}

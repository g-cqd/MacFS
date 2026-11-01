import Foundation

/// What both mount checks verify on a mounted image: its tree against its manifest, and that a write is refused. The real one
/// reads the mount (`manifest`); tests pass their own.
public struct MountVerification: Sendable {
    let compare: @Sendable (String, String, Set<String>) throws -> [String]
    let writeRefused: @Sendable (String) -> Bool

    public init(
        compare: @escaping @Sendable (String, String, Set<String>) throws -> [String],
        writeRefused: @escaping @Sendable (String) -> Bool
    ) {
        self.compare = compare
        self.writeRefused = writeRefused
    }

    /// The mount at a point compared with the manifest file, then a write tried at its root.
    public static let manifest = MountVerification(
        compare: { point, manifest, extra in
            try TreeComparison.problems(
                root: point,
                manifest: try String(contentsOfFile: manifest, encoding: .utf8),
                extra: extra
            )
        },
        writeRefused: MountCheck.refusesWrites(at:)
    )

    /// The problems found on the mount at `point` of the image whose manifest is `manifest`.
    func problems(at point: String, manifest: String, extra: Set<String>) -> [String] {
        var problems: [String] = []
        do { problems += try compare(point, manifest, extra) } catch { problems.append("compare: \(error)") }
        if !writeRefused(point) { problems.append("a write was accepted on a read-only mount") }
        return problems
    }
}

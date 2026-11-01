/// Every static gate the white paper names, in one plan. Each fails on a warning.
public enum Gates {
    /// What the gates read: the shipped code and its tests, never build output.
    public static let corpus = [
        "Packages/FSCore/Sources", "Packages/FSCore/Tests", "Packages/Tooling/Sources", "Packages/Tooling/Tests",
        "Extensions", "App"
    ]
    /// Formatting also covers what the analyzers skip: manifests, benchmarks and plugins.
    public static let formatted =
        corpus + [
            "Packages/FSCore/Package.swift", "Packages/Tooling/Package.swift", "Packages/FSCore/Benchmarks",
            "Packages/Tooling/Plugins"
        ]
    public static let shipped = ["Packages/FSCore/Sources", "Packages/Tooling/Sources", "Extensions", "App"]
    /// Types whose state is touched from more than one place; their TLA+ models are checked by TLC.
    public static let modelledTypes = ["ReadOnlyModule", "Browser", "ExtensionStatus"]

    public static func plan(root: String, tools: ToolPaths) -> Plan {
        let corpus = Self.corpus.map { "\(root)/\($0)" }
        let shipped = Self.shipped.map { "\(root)/\($0)" }
        var steps = [
            Command(
                tools.swift,
                ["format", "lint", "--strict", "--recursive", "--configuration", "\(root)/.swift-format"]
                    + formatted.map { "\(root)/\($0)" }
            ),
            Command(tools.swiftlint, ["lint", "--strict", "--quiet", "--config", "\(root)/.swiftlint.yml"] + shipped)
        ]
        for analyzer in [tools.deadwood, tools.dolly, tools.arcleak] {
            steps.append(Command(analyzer, ["analyze", "--strict", "--no-cache", "--relative-to", root] + corpus))
        }
        steps.append(Command(tools.fcheck, ["analyze", "--strict", "--no-cache", "--relative-to", root] + shipped))
        steps.append(Command(tools.modeler, ["check", "--strict"] + shipped))
        let models = "\(root)/docs/models"
        for type in modelledTypes {
            steps.append(Command(tools.modeler, ["tla", "--type", type, "--output", models] + shipped))
            steps.append(
                Command(
                    tools.java,
                    [
                        "-cp", tools.tla2tools, "tlc2.TLC", "-workers", "auto", "-cleanup", "-config",
                        "\(models)/\(type)Model.cfg",
                        "\(models)/\(type)Model.tla"
                    ]
                )
            )
        }
        // Lean: the arithmetic of AlignedReader and MountedTree, proved (Proofs/).
        steps.append(Command(tools.lake, ["-d", "\(root)/Proofs", "build"]))
        return Plan(steps: steps)
    }
}

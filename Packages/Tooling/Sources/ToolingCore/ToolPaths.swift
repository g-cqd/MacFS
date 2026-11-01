/// Where each gate's tool lives. Resolved by the caller (the plugin, from the toolchain and pinned caches).
public struct ToolPaths: Sendable {
    public let swift: String
    public let swiftlint: String
    public let deadwood: String
    public let dolly: String
    public let arcleak: String
    public let fcheck: String
    public let modeler: String
    public let java: String
    public let tla2tools: String
    public let lake: String

    public init(
        swift: String,
        swiftlint: String,
        deadwood: String,
        dolly: String,
        arcleak: String,
        fcheck: String,
        modeler: String,
        java: String,
        tla2tools: String,
        lake: String
    ) {
        self.swift = swift
        self.swiftlint = swiftlint
        self.deadwood = deadwood
        self.dolly = dolly
        self.arcleak = arcleak
        self.fcheck = fcheck
        self.modeler = modeler
        self.java = java
        self.tla2tools = tla2tools
        self.lake = lake
    }
}

// swift-tools-version: 6.4
import PackageDescription

// Development tooling for MacFS: what used to be shell scripts, as tested Swift behind command plugins.
//   swift package --package-path Packages/Tooling --disable-sandbox images [--dry-run]
//   swift package --package-path Packages/Tooling --disable-sandbox gates [--dry-run]
//   swift package --package-path Packages/Tooling --allow-writing-to-package-directory plists [--check]
// Separate from FSCore so no consumer of the readers resolves any of it.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "Tooling",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "macfs-tool", targets: ["macfs-tool"]),
        .plugin(name: "Images", targets: ["Images"]),
        .plugin(name: "Gates", targets: ["Gates"]),
        .plugin(name: "Plists", targets: ["Plists"]),
        .plugin(name: "Mounts", targets: ["Mounts"]),
        .plugin(name: "Install", targets: ["Install"])
    ],
    dependencies: [
        .package(path: "../FSCore"),
        // Pattern matching for the repository rules: the family's own engine, pinned like Aemi is pinned.
        .package(url: "https://github.com/g-cqd/AemiRegex.git", revision: "15003076346975031fe2974fb4c3c496265c80a4")
    ],
    targets: [
        .target(
            name: "ToolingCore",
            dependencies: [
                .product(name: "Formats", package: "FSCore"), .product(name: "AppSupport", package: "FSCore"),
                .product(name: "AemiRegex", package: "AemiRegex")
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "macfs-tool", dependencies: ["ToolingCore"], swiftSettings: strictSettings),
        .testTarget(name: "ToolingCoreTests", dependencies: ["ToolingCore"], swiftSettings: strictSettings),
        .plugin(
            name: "Images",
            capability: .command(
                intent: .custom(
                    verb: "images",
                    description: "Build the test images and their manifests in a Linux container"
                )
            ),
            dependencies: ["macfs-tool"]
        ),
        .plugin(
            name: "Gates",
            capability: .command(
                intent: .custom(verb: "gates", description: "Run every static gate: format, lint, analyzers, models")
            ),
            dependencies: ["macfs-tool"]
        ),
        .plugin(
            name: "Plists",
            capability: .command(
                intent: .custom(verb: "plists", description: "Write or check the FSKit modules' Info.plists"),
                permissions: [.writeToPackageDirectory(reason: "Write Extensions/*/Info.plist from DiskFormat")]
            ),
            dependencies: ["macfs-tool"]
        ),
        .plugin(
            name: "Mounts",
            capability: .command(
                intent: .custom(
                    verb: "mounts",
                    description: "Mount every test image through its FSKit module and compare it with its manifest"
                )
            ),
            dependencies: ["macfs-tool"]
        ),
        .plugin(
            name: "Install",
            capability: .command(
                intent: .custom(
                    verb: "install",
                    description:
                        "Build the Release app, verify it, install it in /Applications and register its modules"
                )
            ),
            dependencies: ["macfs-tool"]
        )
    ]
)

// swift-tools-version: 6.4
import PackageDescription

// Same strictness as the Aemi family: Swift 6 mode, warnings as errors, the upcoming features that
// tighten existentials and imports. No unsafe flags, so the package can be consumed by version.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

// The readers parse bytes from disks nobody vouches for, so every unsafe construct in them is marked
// `unsafe` and confined (ADR-0003).
let readerSettings: [SwiftSetting] = strictSettings + [.strictMemorySafety()]

let aemiKernel: Target.Dependency = .product(name: "AemiKernel", package: "aemi")
let aemiIO: Target.Dependency = .product(name: "AemiIO", package: "aemi")
let aemiKernels: Target.Dependency = .product(name: "AemiKernels", package: "aemi")
let aemiTestKit: Target.Dependency = .product(name: "AemiTestKit", package: "aemi")

let package = Package(
    name: "FSCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FSCore", targets: ["FSCore"]),
        .library(name: "Btrfs", targets: ["Btrfs"]),
        .library(name: "NTFS", targets: ["NTFS"]),
        .library(name: "ExtFS", targets: ["ExtFS"]),
        .library(name: "Formats", targets: ["Formats"]),
        .library(name: "MountKit", targets: ["MountKit"]),
        .library(name: "AppSupport", targets: ["AppSupport"]),
        .library(name: "NFSProxy", targets: ["NFSProxy"]),
        .executable(name: "macfs-nfsd", targets: ["macfs-nfsd"]),
        .executable(name: "fsprobe", targets: ["fsprobe"])
    ],
    dependencies: [
        // Pinned to one revision, the one AemiRegex pins (ADR-0004).
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "8475434abab0493d9bda746f78e33087899391c3"),
        // The mount registry's and the agent's encoding (ADR-0015); it pins the same aemi.
        .package(url: "https://github.com/g-cqd/AemiProtobuf.git", revision: "7b7dbc551b4d8289640fb8b4d6870c698232cbba")
    ],
    targets: [
        // The format-specific kernels (NTFS fixups, LZNT1) in arm64 assembly, with portable C versions that double as the
        // test references, and the device ioctls. CRC-32C, bit counts and UTF-16 narrowing come from aemi's kernels (ADR-0012).
        // Release C is -Os by default; the C kernels (zstd above all) are 8 to 11% faster at -O3 (docs/research/
        // 2026-10-30-compression-kernels.md). Allowed here: FSCore is only ever a root or a local package.
        .target(
            name: "CFSKernels",
            cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))]
        ),
        .target(
            name: "FSCore",
            dependencies: ["CFSKernels", aemiKernel, aemiKernels, aemiIO],
            swiftSettings: readerSettings
        ),
        .target(name: "Btrfs", dependencies: ["FSCore", "CFSKernels", aemiKernel], swiftSettings: readerSettings),
        .target(name: "NTFS", dependencies: ["FSCore", "CFSKernels", aemiKernel], swiftSettings: readerSettings),
        .target(name: "ExtFS", dependencies: ["FSCore", aemiKernel], swiftSettings: readerSettings),
        .target(name: "XFS", dependencies: ["FSCore", aemiKernel], swiftSettings: readerSettings),
        // The one list of formats every mount technology, the app and fsprobe share.
        .target(
            name: "Formats",
            dependencies: ["FSCore", "Btrfs", "NTFS", "ExtFS", "XFS"],
            swiftSettings: readerSettings
        ),
        // What every mount technology needs on top of a reader: identifiers, listings with "." and "..".
        .target(name: "MountKit", dependencies: ["FSCore"], swiftSettings: readerSettings),
        // The mount registry on disk: protobuf in a checked envelope (ADR-0015). Apart from MountKit, which the FSKit
        // extensions link: only the app and the agent carry protobuf.
        .target(
            name: "MountRegistry",
            dependencies: ["MountKit", "FSCore", .product(name: "AemiProtobuf", package: "AemiProtobuf")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MountRegistryTests",
            dependencies: [
                "MountRegistry", "MountKit", "FSCore", .product(name: "AemiProtobuf", package: "AemiProtobuf")
            ],
            swiftSettings: strictSettings
        ),
        // The app's logic, apart from its views so it is tested: the status checks (roadmap 0021).
        .target(name: "AppSupport", dependencies: ["Formats"], swiftSettings: strictSettings),
        .testTarget(name: "AppSupportTests", dependencies: ["AppSupport", "Formats"], swiftSettings: strictSettings),
        // A read-only NFSv3 server over MountKit, mounted by macOS's own client (ADR-0005, roadmap 0007).
        .target(name: "NFSProxy", dependencies: ["MountKit", "FSCore"], swiftSettings: readerSettings),
        .executableTarget(
            name: "macfs-nfsd",
            dependencies: ["NFSProxy", "Formats", "FSCore", "MountKit", "MountRegistry"],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "fsprobe", dependencies: ["Formats", "FSCore"], swiftSettings: strictSettings),
        // A call that checks the assembly kernels keep the callee-saved registers (KernelABITests). Tests only.
        .target(name: "KernelABI", dependencies: ["CFSKernels"], path: "Tests/KernelABI"),
        // The system libz, the reference the codec tests make their streams with and hold `fsk_inflate` to. Tests only.
        .target(name: "CodecOracle", path: "Tests/CodecOracle", linkerSettings: [.linkedLibrary("z")]),
        .testTarget(
            name: "FSCoreTests",
            dependencies: ["FSCore", "CFSKernels", "KernelABI", aemiTestKit],
            swiftSettings: strictSettings
        ),
        // The images are built by Scripts/make-test-images.sh in a Linux container from the reference tools
        // (mkfs.btrfs, mkntfs, ntfscp) and found by path, not bundled: they are hundreds of megabytes.
        .testTarget(
            name: "BtrfsTests",
            dependencies: ["Btrfs", "FSCore", "CFSKernels", "CodecOracle", aemiTestKit],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "NTFSTests", dependencies: ["NTFS", "FSCore", "CFSKernels"], swiftSettings: strictSettings),
        .testTarget(name: "ExtFSTests", dependencies: ["ExtFS", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "XFSTests", dependencies: ["XFS", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "FormatsTests", dependencies: ["Formats", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "MountKitTests", dependencies: ["MountKit", "FSCore"], swiftSettings: strictSettings),
        .testTarget(
            name: "NFSProxyTests",
            dependencies: ["NFSProxy", "MountKit", "FSCore"],
            swiftSettings: strictSettings
        )
    ]
)

// aemi's kernels against C baselines and MacFS's former assembly (docs/research/2026-10-30-neon-kernels.md), dev-only:
//   MACFS_DEV=1 swift run -c release fskbench
if Context.environment["MACFS_DEV"] != nil {
    package.targets += [
        .target(
            name: "CFSKernelsBaseline",
            path: "Benchmarks/CFSKernelsBaseline",
            cSettings: [.unsafeFlags(["-O3", "-march=armv8.2-a+crc+crypto"])]
        ),
        .executableTarget(
            name: "fskbench",
            dependencies: ["CFSKernelsBaseline", aemiKernels],
            path: "Benchmarks/fskbench"
        )
    ]
}

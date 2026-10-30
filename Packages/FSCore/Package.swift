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
        .library(name: "NFSProxy", targets: ["NFSProxy"]),
        .executable(name: "macfs-nfsd", targets: ["macfs-nfsd"]),
        .executable(name: "fsprobe", targets: ["fsprobe"])
    ],
    dependencies: [
        // Pinned to one revision, as AemiRegex and AemiJSON pin it (ADR-0004).
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "04e49d108e43a94fac449f344bfca9eabc5be0e9")
    ],
    targets: [
        // arm64 assembly (CRC, PMULL, NEON) with a portable C fallback that doubles as the test reference.
        .target(name: "CFSKernels"),
        .target(name: "FSCore", dependencies: ["CFSKernels", aemiKernel, aemiIO], swiftSettings: readerSettings),
        .target(name: "Btrfs", dependencies: ["FSCore", aemiKernel], swiftSettings: readerSettings),
        .target(name: "NTFS", dependencies: ["FSCore", aemiKernel], swiftSettings: readerSettings),
        .target(name: "ExtFS", dependencies: ["FSCore", aemiKernel], swiftSettings: readerSettings),
        // The one list of formats every mount technology, the app and fsprobe share.
        .target(name: "Formats", dependencies: ["FSCore", "Btrfs", "NTFS", "ExtFS"], swiftSettings: readerSettings),
        // What every mount technology needs on top of a reader: identifiers, listings with "." and "..".
        .target(name: "MountKit", dependencies: ["FSCore"], swiftSettings: readerSettings),
        // A read-only NFSv3 server over MountKit, mounted by macOS's own client (ADR-0005, roadmap 0007).
        .target(name: "NFSProxy", dependencies: ["MountKit", "FSCore"], swiftSettings: readerSettings),
        .executableTarget(
            name: "macfs-nfsd", dependencies: ["NFSProxy", "Formats", "FSCore"], swiftSettings: strictSettings),
        .executableTarget(name: "fsprobe", dependencies: ["Formats", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "FSCoreTests", dependencies: ["FSCore", "CFSKernels"], swiftSettings: strictSettings),
        // The images are built by Scripts/make-test-images.sh in a Linux container from the reference tools
        // (mkfs.btrfs, mkntfs, ntfscp) and found by path, not bundled: they are hundreds of megabytes.
        .testTarget(name: "BtrfsTests", dependencies: ["Btrfs", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "NTFSTests", dependencies: ["NTFS", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "ExtFSTests", dependencies: ["ExtFS", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "FormatsTests", dependencies: ["Formats", "FSCore"], swiftSettings: strictSettings),
        .testTarget(name: "MountKitTests", dependencies: ["MountKit", "FSCore"], swiftSettings: strictSettings),
        .testTarget(
            name: "NFSProxyTests", dependencies: ["NFSProxy", "MountKit", "FSCore"], swiftSettings: strictSettings)
    ]
)

// Kernel benchmarks against the best C baseline (docs/research/2026-10-30-neon-kernels.md), dev-only:
//   MACFS_DEV=1 swift run -c release fskbench
if Context.environment["MACFS_DEV"] != nil {
    package.targets += [
        .target(
            name: "CFSKernelsBaseline", path: "Benchmarks/CFSKernelsBaseline",
            cSettings: [.unsafeFlags(["-O3", "-march=armv8.2-a+crc+crypto"])]),
        .executableTarget(
            name: "fskbench", dependencies: ["CFSKernels", "CFSKernelsBaseline"], path: "Benchmarks/fskbench")
    ]
}

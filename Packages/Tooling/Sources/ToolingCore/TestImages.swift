/// The test images: built in a Linux container by the reference tools (`Scripts/make-test-images.inner.sh`).
public enum TestImages {
    /// Pinned so the tools that write the oracle do not move under the tests (TestImages/versions.txt records them).
    public static let image = "alpine:3.22"

    /// What a run produces, each in its own gitignored directory.
    public enum Kind: String, Sendable, CaseIterable {
        /// The test images, their manifests and reference manifests.
        case test
        /// The profiling corpus (`BenchImages/`, about 4 GiB, roadmap 0012).
        case bench
        /// The reference test suites' images (e2fsprogs, btrfs-progs), a hostile corpus (docs/conformance).
        case corpus

        public var directory: String {
            switch self {
                case .test: "TestImages"
                case .bench: "BenchImages"
                case .corpus: "TestCorpus"
            }
        }

        var payload: String {
            switch self {
                case .test: "make-test-images.inner.sh"
                case .bench: "make-bench-images.inner.sh"
                case .corpus: "fetch-reference-suites.inner.sh"
            }
        }
    }

    public static func plan(root: String, container: String, kind: Kind = .test) -> Plan {
        Plan(steps: [
            Command(
                container,
                [
                    // Mounting (the kernel's ext driver, ntfs-3g through FUSE) needs the capabilities a container drops.
                    "run", "--rm", "--cap-add", "ALL", "-v", "\(root)/\(kind.directory):/work", "-v",
                    "\(root)/Scripts:/scripts", image, "sh", "/scripts/\(kind.payload)"
                ])
        ])
    }
}

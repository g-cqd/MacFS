/// The test images: built in a Linux container by the reference tools (`Scripts/make-test-images.inner.sh`).
public enum TestImages {
    /// Pinned so the tools that write the oracle do not move under the tests (TestImages/versions.txt records them).
    public static let image = "alpine:3.22"

    /// `bench` builds the profiling corpus instead (`BenchImages/`, about 4 GiB, roadmap 0012).
    public static func plan(root: String, container: String, bench: Bool = false) -> Plan {
        let directory = bench ? "BenchImages" : "TestImages"
        let payload = bench ? "make-bench-images.inner.sh" : "make-test-images.inner.sh"
        return Plan(steps: [
            Command(
                container,
                [
                    "run", "--rm", "-v", "\(root)/\(directory):/work", "-v", "\(root)/Scripts:/scripts", image, "sh",
                    "/scripts/\(payload)"
                ])
        ])
    }
}

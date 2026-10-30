/// The test images: built in a Linux container by the reference tools (`Scripts/make-test-images.inner.sh`).
public enum TestImages {
    /// Pinned so the tools that write the oracle do not move under the tests (TestImages/versions.txt records them).
    public static let image = "alpine:3.22"

    public static func plan(root: String, container: String) -> Plan {
        Plan(steps: [
            Command(
                container,
                [
                    "run", "--rm", "-v", "\(root)/TestImages:/work", "-v", "\(root)/Scripts:/scripts", image, "sh",
                    "/scripts/make-test-images.inner.sh"
                ])
        ])
    }
}

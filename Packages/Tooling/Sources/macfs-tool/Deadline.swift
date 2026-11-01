/// How long one command may take before it is stopped (roadmap 0048): each long past what it takes when it works.
enum Deadline {
    /// A step of the gates or the images: a whole test suite, an image built in a container.
    static let planStep: Duration = .seconds(2 * 3600)
    /// A Release build of the app, or one of the installer's other steps.
    static let build: Duration = .seconds(30 * 60)
    /// An analyzer's release archive.
    static let download: Duration = .seconds(10 * 60)
    /// One step of the mount check: attach, mount, compare, unmount, the app's automation; a wedged module stops here.
    static let mountStep: Duration = .seconds(120)
}

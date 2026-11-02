/// What both FSKit checks do around their work: an image attached without mounting, mounted through its module, the work run
/// on the mount, unmounted, and detached whatever failed before.
struct MountSession: Sendable {
    let runner: any ProcessRunning
    /// Waits before the retry; the tests' does not.
    let pause: @Sendable (Duration) -> Void

    /// `work`'s problems with the mount's (or the attach's); `mounted` tells whether the work ran.
    func run(
        image: String,
        attach options: [String],
        type: String,
        mount mountOptions: [String],
        at point: String,
        _ work: () -> [String]
    ) -> (problems: [String], mounted: Bool) {
        guard
            let attach = try? runner.run(Command("/usr/bin/hdiutil", ["attach", "-nomount"] + options + [image])),
            attach.status == 0, let device = MountCheck.device(attach.output)
        else { return (["attach: no device for \(image)"], false) }
        let command = Command("/sbin/mount", ["-F", "-t", type] + mountOptions + [device, point])
        var mount = try? runner.run(command)
        // FSKit stops a module's process after its volume unmounts; a mount arriving while it lingers finds no helper (diary
        // 2026-11-01-11). Retried once, for that answer only.
        if let failed = mount, failed.status != 0,
            failed.output.contains("Couldn’t communicate with a helper application")
        {
            pause(.seconds(5))
            mount = try? runner.run(command)
        }
        var problems: [String] = []
        let mounted = mount?.status == 0
        if mounted {
            problems = work()
            if (try? runner.run(Command("/sbin/umount", [point])))?.status != 0 {
                problems.append("umount \(point) failed")
            }
        } else {
            problems.append("mount -t \(type): \(mount?.output ?? "did not run")")
        }
        _ = try? runner.run(Command("/usr/bin/hdiutil", ["detach", device]))
        return (problems, mounted)
    }
}

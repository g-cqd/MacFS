import Foundation
import ToolingCore

/// Every test image through its FSKit module (roadmap 0025). Needs the app in /Applications with its modules enabled.
func mounts(_ options: Options) -> Int32 {
    if options.dryRun {
        for target in MountCheck.targets {
            print(
                "TestImages/\(target.image).img: attach, mount -F -t \(target.type), compare, refuse a write, release"
            )
            print(
                "TestImages/\(target.image).img: clone, mount through MacFS's agent, compare, refuse a write, unmount"
            )
        }
        for target in WriteCheck.targets {
            print(
                "TestImages/\(target.image).img: copy, attach it the ordinary way, its automount refuses a write, detach"
            )
            print(
                "TestImages/\(target.image).img: copy, mount -F -t \(target.type) -o rw, change, release, check on Linux"
            )
        }
        return 0
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("macfs-mounts-\(getpid())").path
    let check = MountCheck(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.mountStep),
        root: options.root,
        mountPoint: { target in
            let point = base + "/" + target.image
            try? FileManager.default.createDirectory(atPath: point, withIntermediateDirectories: true)
            return point
        },
        verification: .manifest,
        pause: { Thread.sleep(forTimeInterval: Double($0.components.seconds)) }
    )
    // The agent path (roadmap 0039): the installed app mounts a clone in its container through its agent.
    let container = NSHomeDirectory() + "/Library/Containers/dev.gcqd.MacFS/Data/tmp"
    let app = AppLaunch(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.mountStep),
        app: "/Applications/MacFS.app",
        resultFile: container + "/agentcheck-result.txt"
    )
    let agent = AgentMountCheck(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.mountStep),
        root: options.root,
        container: container,
        launch: app.run,
        verification: .manifest
    )
    var failed = false
    func report(_ outcome: MountCheck.Outcome, _ path: String) {
        let target = outcome.target
        if outcome.problems.isEmpty {
            print("[OK]   \(target.image) (\(target.type), \(path))")
        } else {
            failed = true
            print("[FAIL] \(target.image) (\(target.type), \(path))")
            outcome.problems.prefix(10).forEach { print("       \($0)") }
        }
    }
    for target in MountCheck.targets { report(check.run(target), "FSKit") }
    try? FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
    for target in MountCheck.targets { report(agent.run(target), "agent") }
    writeChecks(options, in: base, report: report)
    try? FileManager.default.removeItem(atPath: base)
    return failed ? 1 : 0
}

/// The writable formats' sessions (roadmap 0046), each on a fresh copy: its automount refuses a write, then a writable FSKit
/// mount is changed and judged on Linux.
func writeChecks(_ options: Options, in base: String, report: (MountCheck.Outcome, String) -> Void) {
    // Writes (roadmap 0046): a copy changed through its writable FSKit mount, then judged on Linux.
    let writes = WriteCheck(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.mountStep),
        pause: { Thread.sleep(forTimeInterval: Double($0.components.seconds)) },
        checker: LinuxVerdict.problems
    )
    let automounts = AutomountCheck(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.mountStep),
        writeRefused: MountCheck.refusesWrites(at:)
    )
    for target in WriteCheck.targets {
        do {
            let workspace = try WriteCheck.prepare(target, root: options.root, in: base + "/write-" + target.image)
            let automount = automounts.run(image: workspace.image)
            report(
                MountCheck.Outcome(
                    target: .init(image: target.image, type: target.type, extra: []),
                    problems: automount
                ),
                "automount, read-only"
            )
            report(writes.run(target, in: workspace), "FSKit, writable")
        } catch {
            report(
                MountCheck.Outcome(
                    target: .init(image: target.image, type: target.type, extra: []),
                    problems: ["copy: \(error)"]
                ),
                "FSKit, writable"
            )
        }
    }
}

import MountKit
import Testing

/// The system's mount table as `getmntinfo` gives it, and paths spelled as it spells them.
@Suite struct SystemMountTableTests {
    @Test func theRootVolumeIsInTheTable() {
        let root = SystemMountTable().entries().first { $0.mountPoint == "/" }
        #expect(root?.type == "apfs")
        #expect(root?.mountedFrom.hasPrefix("/dev/disk") == true)
    }

    /// `/tmp` is a link to `/private/tmp`, and the table names mounts by their real path.
    @Test func pathsAreCanonicalAsTheTableSpellsThem() {
        let table = SystemMountTable()
        #expect(table.canonical("/tmp/macfs-not-there/x") == "/private/tmp/macfs-not-there/x")
        #expect(table.canonical("/Users") == "/Users")
    }
}

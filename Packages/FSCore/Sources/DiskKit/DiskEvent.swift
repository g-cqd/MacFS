/// What the watcher saw happen to a disk.
public enum DiskEvent: Sendable, Hashable {
    case appeared(DiskDescription)
    case changed(DiskDescription)
    case disappeared(String)
}

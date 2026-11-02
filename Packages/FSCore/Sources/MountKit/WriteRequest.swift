/// Whether a mount's options ask to write (ADR-0018, roadmap 0046). Only by name: Disk Arbitration's automount passes no
/// `rdonly` once a module has a check (`-o nodev,noowners,nosuid,nofollow`, measured), so writes are asked for with `rw` (a
/// mount by hand) or `writable` (kept in Disk Arbitration's arguments, which drop a bare `rw`). `rdonly` or `ro` wins.
public enum WriteRequest {
    public static func asksToWrite(_ options: [String]) -> Bool {
        let words = zip(options, options.dropFirst())
            .filter { flag, _ in flag == "-o" }
            .flatMap { _, list in list.split(separator: ",") }
        guard !words.contains(where: { $0 == "rdonly" || $0 == "ro" }) else { return false }
        return words.contains { $0 == "rw" || $0 == "writable" }
    }
}

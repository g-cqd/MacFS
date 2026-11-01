/// Whether a backend can mount a source here, and if not, why: shown to the user, never answered by another backend instead.
public enum MountAvailability: Hashable, Sendable {
    case available
    case unavailable(String)
}

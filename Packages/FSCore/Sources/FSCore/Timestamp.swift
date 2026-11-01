import Darwin

/// Seconds and nanoseconds since 1970, UTC.
public struct Timestamp: Sendable, Equatable {
    public var seconds: Int64
    public var nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public static let epoch = Timestamp(seconds: 0, nanoseconds: 0)

    /// The system's time now (CLOCK_REALTIME).
    public static var now: Timestamp {
        var time = timespec()
        unsafe clock_gettime(CLOCK_REALTIME, &time)
        return Timestamp(seconds: Int64(time.tv_sec), nanoseconds: Int32(time.tv_nsec))
    }
}

/// Seconds and nanoseconds since 1970, UTC.
public struct Timestamp: Sendable, Equatable {
    public var seconds: Int64
    public var nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public static let epoch = Timestamp(seconds: 0, nanoseconds: 0)
}

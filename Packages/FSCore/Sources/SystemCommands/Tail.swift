/// The last `limit` bytes of what was appended, holding at most twice that: a build's minutes of output cost no more.
struct Tail {
    let limit: Int
    private(set) var held: [UInt8] = []

    init(limit: Int) { self.limit = limit }

    mutating func append(_ bytes: some Collection<UInt8>) {
        held += bytes
        if held.count > 2 * limit { held.removeFirst(held.count - limit) }
    }

    var bytes: [UInt8] { Array(held.suffix(limit)) }
}

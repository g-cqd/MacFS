public import FSCore
import Synchronization

/// Records every write and flush made through it to `device`, and gives the crash states of that sequence (ADR-0018 decision 6):
/// the image before any write, as of every flush, and at the end; and inside each epoch (the writes between two flushes, which
/// may land in any subset), its proper subsets in write order. Past `exhaustive` writes, an epoch is sampled: each write alone,
/// each but one, and each prefix.
public final class CrashRecorder: WritableBlockSource {
    enum Event: Sendable {
        case write(UInt64, [UInt8])
        case flush
    }

    private let device: any WritableBlockSource
    private let original: [UInt8]
    private let exhaustive: Int
    private let events = Mutex<[Event]>([])

    /// `device`'s bytes now are the image every crash state starts from.
    public init(_ device: MemoryBlockSource, exhaustive: Int = 8) {
        self.device = device
        original = device.bytes
        self.exhaustive = exhaustive
    }

    public var byteCount: UInt64 { device.byteCount }

    public func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        try device.read(at: offset, count: count)
    }

    public func write(at offset: UInt64, _ bytes: [UInt8]) throws(DiskError) {
        try device.write(at: offset, bytes)
        events.withLock { $0.append(.write(offset, bytes)) }
    }

    public func flush() throws(DiskError) {
        try device.flush()
        events.withLock { $0.append(.flush) }
    }

    public func crashStates() -> [CrashState] {
        var epochs: [[Write]] = [[]]
        var number = 0
        for event in events.withLock({ $0 }) {
            switch event {
                case .write(let offset, let bytes):
                    number += 1
                    epochs[epochs.count - 1].append(Write(number: number, offset: offset, bytes: bytes))
                case .flush:
                    epochs.append([])
            }
        }
        var states = [CrashState(name: "before any write", original: original, writes: [])]
        var durable: [Write] = []
        for (index, epoch) in epochs.enumerated() {
            let before = index == 0 ? "before any write" : "after flush \(index)"
            for subset in subsets(of: epoch.count) {
                let chosen = subset.map { epoch[$0] }
                let numbers = chosen.map { String($0.number) }.joined(separator: ", ")
                states.append(
                    CrashState(
                        name: "\(before), then writes \(numbers) of epoch \(index + 1)",
                        original: original,
                        writes: durable + chosen
                    )
                )
            }
            durable += epoch
            let isLast = index == epochs.count - 1
            // A flush with no write after it leaves the end equal to its own state.
            if isLast {
                if !epoch.isEmpty || index == 0 {
                    states.append(CrashState(name: "the end", original: original, writes: durable))
                }
            } else if !(epoch.isEmpty && index > 0) {
                states.append(CrashState(name: "after flush \(index + 1)", original: original, writes: durable))
            }
        }
        return states
    }

    /// The proper, non-empty subsets of `count` writes, as indices in write order.
    private func subsets(of count: Int) -> [[Int]] {
        guard count > 1 else { return [] }
        // Sampling needs three writes or more: with two, the singles are every proper subset.
        if count <= max(2, exhaustive) {
            return (1 ..< (1 << count) - 1).map { mask in (0 ..< count).filter { mask & (1 << $0) != 0 } }
        }
        let alone = (0 ..< count).map { [$0] }
        let allButOne = (0 ..< count).map { skipped in (0 ..< count).filter { $0 != skipped } }
        let prefixes = (2 ..< count - 1).map { Array(0 ..< $0) }
        return alone + allButOne + prefixes
    }
}

import CrashTesting
import FSCore
import Testing

/// Crash states of a recorded write sequence (ADR-0018 decision 6): the image as of every flush, and, inside each epoch between
/// flushes, the subsets of its writes that may have landed.
struct CrashRecorderTests {
    static let base = [UInt8](repeating: 0, count: 8)

    /// Writes A, flush, B, C, flush, D: the durable states are none, A, A+B+C and all four (the end, as if flushed); inside the
    /// second epoch, B alone and C alone over A. A one-write epoch has no proper subset.
    @Test func theStatesAreEachFlushAndTheSubsetsOfEachEpoch() throws {
        let recorder = CrashRecorder(MemoryBlockSource(Self.base))
        try recorder.write(at: 0, [1])  // A
        try recorder.flush()
        try recorder.write(at: 1, [2])  // B
        try recorder.write(at: 2, [3])  // C
        try recorder.flush()
        try recorder.write(at: 3, [4])  // D
        let states = try recorder.crashStates().map { try $0.read(at: 0, count: 4) }
        #expect(
            Set(states) == [[0, 0, 0, 0], [1, 0, 0, 0], [1, 2, 3, 0], [1, 2, 3, 4], [1, 2, 0, 0], [1, 0, 3, 0]]
        )
        #expect(states.count == 6)
    }

    /// Writes that overlap keep their order in every state that has both: the later one's bytes win.
    @Test func overlappingWritesKeepTheirOrder() throws {
        let recorder = CrashRecorder(MemoryBlockSource(Self.base))
        try recorder.write(at: 0, [1, 1])
        try recorder.write(at: 1, [2, 2])
        let states = try recorder.crashStates().map { try $0.read(at: 0, count: 3) }
        #expect(Set(states) == [[0, 0, 0], [1, 1, 0], [0, 2, 2], [1, 2, 2]])
    }

    /// Each state says what it is, for the failure that names it.
    @Test func eachStateIsNamed() throws {
        let recorder = CrashRecorder(MemoryBlockSource(Self.base))
        try recorder.write(at: 0, [1])
        try recorder.flush()
        try recorder.write(at: 1, [2])
        try recorder.write(at: 2, [3])
        let names = recorder.crashStates().map(\.name)
        #expect(names.contains("after flush 1"))
        #expect(names.contains("after flush 1, then writes 2 of epoch 2"))
        #expect(names.contains("the end"))
    }

    /// Past `exhaustive` writes, an epoch is sampled: each write alone, each but one, and each prefix, rather than 2^n states.
    @Test func aLargeEpochIsSampledNotEnumerated() throws {
        let recorder = CrashRecorder(MemoryBlockSource([UInt8](repeating: 0, count: 64)), exhaustive: 4)
        for index in 0 ..< 10 { try recorder.write(at: UInt64(index), [1]) }
        let states = recorder.crashStates()
        // none, the end, 10 alone, 10 all but one, and the prefixes of lengths 2 to 8 (1 is a single, 9 is all but one): 29
        #expect(Set(try states.map { try $0.read(at: 0, count: 10) }).count == states.count)
        #expect(states.count == 1 + 1 + 10 + 10 + 7)
    }

    /// At `exhaustive` writes an epoch is still enumerated (2^3 - 2 subsets); one more, and it is sampled (4 + 4 + 1).
    @Test func theExhaustiveBoundIsInclusive() throws {
        for (count, subsets) in [(3, 6), (4, 9)] {
            let recorder = CrashRecorder(MemoryBlockSource([UInt8](repeating: 0, count: 8)), exhaustive: 3)
            for index in 0 ..< count { try recorder.write(at: UInt64(index), [1]) }
            #expect(recorder.crashStates().count == 2 + subsets, "\(count) writes")
        }
    }

    /// Two writes cannot be sampled (no inner prefix): even with a smaller bound, they are enumerated.
    @Test func twoWritesAreAlwaysEnumerated() throws {
        let recorder = CrashRecorder(MemoryBlockSource([UInt8](repeating: 0, count: 8)), exhaustive: 1)
        try recorder.write(at: 0, [1])
        try recorder.write(at: 1, [1])
        #expect(recorder.crashStates().count == 4)
    }

    /// A state read away from a write sees the original bytes there, and only the part of a write inside the range.
    @Test func aStateReadsOnlyTheBytesAsked() throws {
        let recorder = CrashRecorder(MemoryBlockSource(Self.base))
        try recorder.write(at: 0, [1, 1])
        try recorder.write(at: 6, [2, 2])
        let end = try #require(recorder.crashStates().first { $0.name == "the end" })
        #expect(try end.read(at: 3, count: 2) == [0, 0])
        #expect(try end.read(at: 1, count: 6) == [1, 0, 0, 0, 0, 2])
    }

    /// The recorder passes reads and writes through to the device it records.
    @Test func theRecordedDeviceSeesEveryWrite() throws {
        let device = MemoryBlockSource(Self.base)
        let recorder = CrashRecorder(device)
        try recorder.write(at: 5, [9])
        #expect(device.bytes[5] == 9)
        #expect(try recorder.read(at: 5, count: 1) == [9])
    }
}

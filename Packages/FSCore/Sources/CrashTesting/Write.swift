/// One write the recorder saw; `number` counts from 1 across the whole sequence.
struct Write: Sendable {
    let number: Int
    let offset: UInt64
    let bytes: [UInt8]
}

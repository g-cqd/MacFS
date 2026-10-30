import FSCore

/// Attribute type codes (`$AttrDef`).
// @dl:accept -- a table of on-disk constants; its shape is shared with every other format's table
enum NTFSAttributeType {
    static let standardInformation: UInt32 = 0x10
    static let attributeList: UInt32 = 0x20
    static let fileName: UInt32 = 0x30
    static let volumeName: UInt32 = 0x60
    static let data: UInt32 = 0x80
    static let indexRoot: UInt32 = 0x90
    static let indexAllocation: UInt32 = 0xA0
    static let reparsePoint: UInt32 = 0xC0
    static let end: UInt32 = 0xFFFF_FFFF
}

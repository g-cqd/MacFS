import FSCore
import FSKit

/// Kernel-offloaded I/O (roadmap 0018): the kernel reads a mappable file's blocks from the device itself, as Apple's own
/// modules do; the module only says where they are. Files flagged `inhibitKernelOffloadedIO` (not stored as their bytes) keep
/// going through `read`. A reader with data checksums verifies a range before the kernel reads it (`prepareMappedRead`).
extension ReadOnlyVolume: FSVolume.KernelOffloadedIOHandler {
    /// The longest extent FSKit takes is `UINT32_MAX` bytes; ranges are cut at a power of two below it, so pieces stay
    /// block-aligned.
    private static let longestExtent: UInt64 = 1 << 30

    // FSKit fixes this signature; the count is the protocol's.
    // swiftlint:disable:next function_parameter_count
    func blockmapFile(
        _ file: FSItem, offset: off_t, length: Int, flags: FSBlockmapFlags, operationID: FSOperationID,
        packer: FSExtentPacker, replyHandler reply: @escaping @Sendable (FSBlockmapResult?, (any Error)?) -> Void
    ) {
        guard offset >= 0, length >= 0 else { return reply(nil, ModuleError.invalid) }
        answer(file, reply, "blockmap") { (file) throws(DiskError) -> FSBlockmapResult? in
            guard let mapping = tree.fileSystem as? any BlockMapping else { throw .unsupported("no block maps") }
            let id = tree.readerID(for: file.mountID)
            log.debug("blockmap \(id) at \(offset) for \(length), operation \(operationID.rawValue)")
            if operationID != .unspecified {
                try mapping.prepareMappedRead(id, offset: UInt64(offset), length: UInt64(length))
            }
            pack: for range in try mapping.blockMap(id, offset: UInt64(offset), length: UInt64(length)) {
                var done: UInt64 = 0
                while done < range.length {
                    let piece = min(range.length - done, Self.longestExtent)
                    let more = packer.packExtent(
                        resource: device, type: range.physical == nil ? .zeroFill : .data,
                        logicalOffset: off_t(range.logical + done), physicalOffset: off_t((range.physical ?? 0) + done),
                        length: Int(piece))
                    done += piece
                    // A full packer: FSKit asks again, with the same operation, for what is left.
                    if !more { break pack }
                }
            }
            // A read-only volume's free space never changes.
            return FSBlockmapResult(freeSpace: .noUpdate)
        }
    }

    // FSKit fixes this signature; the count is the protocol's.
    // swiftlint:disable:next function_parameter_count
    func completeIO(
        for file: FSItem, offset: off_t, length: Int, status: any Error, flags: FSCompleteIOFlags,
        operationID: FSOperationID, replyHandler reply: @escaping @Sendable (FSCompleteIOResult?, (any Error)?) -> Void
    ) {
        answerAttributes(file, reply, "completeIO", FSCompleteIOResult.init(itemAttributes:))
    }

    func lookupItem(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName, in directory: FSItem, packer: FSExtentPacker, context: FSContext,
        replyHandler reply: @escaping @Sendable (FSLookupItemKOIOResult?, (any Error)?) -> Void
    ) {
        // Extents are supplied only on demand (blockmapFile): the documentation asks for no extra I/O here.
        answerLookup(name, in: directory, reply, FSLookupItemKOIOResult.init(foundItem:itemName:itemAttributes:))
    }

    func createFile(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName, in directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest,
        packer: FSExtentPacker, context: FSContext,
        replyHandler reply: @escaping @Sendable (FSCreateFileKOIOResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }
}

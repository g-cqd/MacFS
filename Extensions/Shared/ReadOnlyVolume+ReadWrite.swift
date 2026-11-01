import FSCore
import FSKit

extension ReadOnlyVolume: FSVolume.ReadWriteHandler {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (FSReadFileResult?, (any Error)?) -> Void
    ) {
        guard offset >= 0 else { return reply(nil, ModuleError.invalid) }
        answer(item, reply, "read") { (item) throws(DiskError) -> FSReadFileResult? in
            let bytes = try tree.fileSystem.read(
                tree.readerID(for: item.mountID),
                at: UInt64(offset),
                count: min(length, buffer.length)
            )
            buffer.withUnsafeMutableBytes { target in
                bytes.withUnsafeBytes { source in
                    target.copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: source[0 ..< min(source.count, target.count)])
                    )
                }
            }
            return FSReadFileResult(bytesRead: bytes.count, itemAttributes: try attributes(item.mountID))
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping (FSWriteFileResult?, (any Error)?) -> Void
    ) {
        guard offset >= 0 else { return reply(nil, ModuleError.invalid) }
        log.info("write \(contents.count) at \(offset)")
        change(item, reply, "write") { (writer, item) throws(DiskError) -> FSWriteFileResult? in
            try writer.write(tree.readerID(for: item.mountID), at: UInt64(offset), [UInt8](contents))
            return FSWriteFileResult(
                bytesWritten: contents.count,
                itemAttributes: try attributes(item.mountID),
                freeSpace: nil
            )
        }
    }
}

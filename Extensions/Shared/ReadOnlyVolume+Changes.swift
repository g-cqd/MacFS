import FSCore
import FSKit
import MountKit

// Every operation that changes the volume (ADR-0018, roadmap 0046). They go to the volume's writer, which exists only when
// the mount was asked for writable and the format's writer accepted the volume (`activateVolume`); otherwise the answer is
// EROFS. Each signature is an FSKit protocol requirement.
// @dl:accept -- FSKit requirements that all go to the writer; the shared part is their signatures
extension ReadOnlyVolume {
    func setAttributes(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void
    ) {
        change(item, reply, "setattr") { (writer, item) throws(DiskError) -> FSSetAttributesResult? in
            let id = id(of: item)
            if newAttributes.isValid(.size) {
                try writer.setSize(id, to: newAttributes.size)
                newAttributes.consumedAttributes.insert(.size)
            }
            var changes = AttributeChanges()
            if newAttributes.isValid(.mode) { changes.mode = UInt16(truncatingIfNeeded: newAttributes.mode) }
            if newAttributes.isValid(.uid) { changes.uid = newAttributes.uid }
            if newAttributes.isValid(.gid) { changes.gid = newAttributes.gid }
            if newAttributes.isValid(.accessTime) { changes.accessed = Self.timestamp(newAttributes.accessTime) }
            if newAttributes.isValid(.modifyTime) { changes.modified = Self.timestamp(newAttributes.modifyTime) }
            if changes != AttributeChanges() {
                try writer.setAttributes(id, changes)
                newAttributes.consumedAttributes.formUnion([.mode, .uid, .gid, .accessTime, .modifyTime])
            }
            return FSSetAttributesResult(attributes: try attributes(item.mountID), freeSpace: nil)
        }
    }

    func createItem(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        attributes newAttributes: FSItem.SetAttributesRequest,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void
    ) {
        answerCreate(name, type, in: directory, newAttributes, reply, FSCreateItemResult.init)
    }

    /// A file or directory made, answered as `T`: both creates (plain and kernel-offloaded) answer through here.
    func answerCreate<T>(
        _ name: FSFileName,
        _ type: FSItem.ItemType,
        in directory: FSItem,
        _ newAttributes: FSItem.SetAttributesRequest,
        _ reply: (T?, (any Error)?) -> Void,
        _ make: (FSItem, FSFileName, FSItem.Attributes, FSItem.Attributes, FSFreeSpace?) -> T?
    ) {
        change(directory, reply, "create") { (writer, directory) throws(DiskError) -> T? in
            let kind: NodeKind
            switch type {
                case .file: kind = .regular
                case .directory: kind = .directory
                default: throw .unsupported("creating a \(type)")
            }
            let fallback: UInt16 = kind == .directory ? 0o755 : 0o644
            let mode = newAttributes.isValid(.mode) ? UInt16(truncatingIfNeeded: newAttributes.mode) & 0o7777 : fallback
            let id = try writer.create(
                bytes(name),
                kind: kind,
                in: id(of: directory),
                mode: mode,
                owner: Self.owner(newAttributes)
            )
            let mountID = try tree.checkedMountID(for: id)
            return make(item(mountID), name, try attributes(mountID), try attributes(directory.mountID), nil)
        }
    }

    func createSymbolicLink(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName,
        in directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void
    ) {
        change(directory, reply, "symlink") { (writer, directory) throws(DiskError) -> FSCreateSymlinkResult? in
            let id = try writer.createSymlink(
                bytes(name),
                target: bytes(contents),
                in: id(of: directory),
                owner: Self.owner(newAttributes)
            )
            let mountID = try tree.checkedMountID(for: id)
            return FSCreateSymlinkResult(
                newItem: item(mountID),
                newItemName: name,
                newItemAttributes: try attributes(mountID),
                directoryAttributes: try attributes(directory.mountID),
                freeSpace: nil
            )
        }
    }

    func createLink(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        to item: FSItem,
        named name: FSFileName,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        in directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void
    ) {
        change(directory, reply, "link") { (writer, directory) throws(DiskError) -> FSCreateLinkResult? in
            let linked = try cast(item)
            try writer.link(
                // @dl:accept -- each FSKit change hands the writer identifiers and names, then answers attributes
                id(of: linked),
                as: bytes(name),
                in: id(of: directory)
            )
            return FSCreateLinkResult(
                linkName: name,
                linkAttributes: try attributes(linked.mountID),
                directoryAttributes: try attributes(directory.mountID),
                freeSpace: nil
            )
        }
    }

    // FSKit fixes this signature; the count is the protocol's.
    // swiftlint:disable:next function_parameter_count
    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        context: FSContext,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void
    ) {
        change(sourceDirectory, reply, "rename") { (writer, source) throws(DiskError) -> FSRenameItemResult? in
            let moved = try cast(item)
            let destination = try cast(destinationDirectory)
            try writer.rename(
                // @dl:accept -- each FSKit change hands the writer identifiers and names, then answers attributes
                bytes(sourceName),
                in: id(of: source),
                to: bytes(destinationName),
                in: id(of: destination)
            )
            return FSRenameItemResult(
                newName: destinationName,
                renamedItemAttributes: try attributes(moved.mountID),
                sourceDirectoryAttributes: try attributes(source.mountID),
                destinationDirectoryAttributes: try attributes(destination.mountID),
                overItemAttributes: nil,
                freeSpace: nil
            )
        }
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        from directory: FSItem,
        context: FSContext,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void
    ) {
        change(directory, reply, "remove") { (writer, directory) throws(DiskError) -> FSRemoveItemResult? in
            let removed = try cast(item)
            // Its attributes as they were: once it has no name left, the node is gone.
            let before = try attributes(removed.mountID)
            try writer.remove(bytes(name), from: id(of: directory))
            let after = (try? attributes(removed.mountID)) ?? before
            return FSRemoveItemResult(
                itemAttributes: after,
                directoryAttributes: try attributes(directory.mountID),
                freeSpace: nil
            )
        }
    }

    // MARK: Pieces

    /// Answers `reply` for a change on `item` through the writer, or EROFS when the volume does not write.
    func change<T>(
        _ item: FSItem,
        _ reply: (T?, (any Error)?) -> Void,
        _ what: String,
        _ body: (any WritableFileSystem, ReadOnlyItem) throws(DiskError) -> T?
    ) {
        guard let writer = writer.withLock({ $0 }) else { return reply(nil, ModuleError.readOnly) }
        answer(item, reply, what) { (item) throws(DiskError) -> T? in try body(writer, item) }
    }

    /// One of this volume's items; FSKit hands no other.
    func cast(_ item: FSItem) throws(DiskError) -> ReadOnlyItem {
        guard let item = item as? ReadOnlyItem else { throw .corrupt("an item that is not this volume's") }
        return item
    }

    /// The reader's identifier for an item.
    func id(of item: ReadOnlyItem) -> UInt64 { tree.readerID(for: item.mountID) }

    /// A name's bytes, as the writer takes them.
    func bytes(_ name: FSFileName) -> [UInt8] { Array(name.data) }

    static func owner(_ attributes: FSItem.SetAttributesRequest) -> (uid: UInt32, gid: UInt32) {
        (attributes.isValid(.uid) ? attributes.uid : 0, attributes.isValid(.gid) ? attributes.gid : 0)
    }

    static func timestamp(_ time: timespec) -> Timestamp {
        Timestamp(seconds: Int64(time.tv_sec), nanoseconds: Int32(time.tv_nsec))
    }
}

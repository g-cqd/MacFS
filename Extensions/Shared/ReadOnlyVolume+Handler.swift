import FSCore
import FSKit
import MountKit

extension ReadOnlyVolume: FSVolume.Handler {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = true
        capabilities.supportsSparseFiles = true
        capabilities.supports2TBFiles = true
        capabilities.supportsHiddenFiles = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.caseFormat =
            tree.fileSystem.volume.caseRule == .sensitive ? .sensitive : .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: shortName)
        guard let statistics = try? tree.fileSystem.statistics() else { return result }
        let block = UInt64(statistics.blockSize)
        result.blockSize = statistics.blockSize
        result.ioSize = max(statistics.blockSize, 1 << 20)
        result.totalBlocks = statistics.totalBlocks
        result.freeBlocks = statistics.freeBlocks
        result.availableBlocks = statistics.freeBlocks
        result.usedBlocks = statistics.totalBlocks - min(statistics.totalBlocks, statistics.freeBlocks)
        result.totalBytes = statistics.totalBlocks * block
        result.freeBytes = statistics.freeBlocks * block
        result.availableBytes = statistics.freeBlocks * block
        result.usedBytes = result.usedBlocks * block
        result.totalFiles = statistics.files
        return result
    }

    var requestedMountOptions: FSVolume.MountOptions { .readOnly }

    // MARK: PathConf

    var maximumLinkCount: Int { 65_000 }
    var maximumNameLength: Int { tree.fileSystem.volume.maximumNameLength }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: Life cycle

    func activateVolume(options: FSTaskOptions, replyHandler reply: @escaping (FSActivateResult?, (any Error)?) -> Void)
    {
        reply(FSActivateResult(rootItem: item(MountedTree.root)), nil)
    }

    func deactivateVolume(options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func unmount(replyHandler reply: @escaping () -> Void) { reply() }
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) { reply(nil) }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        forget(item)
        reply(nil)
    }

    // MARK: Reading

    func lookupItem(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName, in directory: FSItem, context: FSContext,
        replyHandler reply: @escaping (FSLookupItemResult?, (any Error)?) -> Void
    ) {
        answer(directory, reply, "lookup") { (directory) throws(DiskError) -> FSLookupItemResult? in
            let entry = try tree.fileSystem.lookup(Array(name.data), in: tree.readerID(for: directory.mountID))
            let mountID = try tree.checkedMountID(for: entry.id)
            return FSLookupItemResult(
                foundItem: item(mountID), itemName: FSFileName(data: Data(entry.name)),
                itemAttributes: try attributes(mountID))
        }
    }

    func getAttributes(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        _ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, context: FSContext,
        replyHandler reply: @escaping (FSGetAttributesResult?, (any Error)?) -> Void
    ) {
        answer(item, reply, "getattr") { (item) throws(DiskError) -> FSGetAttributesResult? in
            FSGetAttributesResult(attributes: try attributes(item.mountID))
        }
    }

    // FSKit fixes this signature; the count is the protocol's.
    // swiftlint:disable:next function_parameter_count
    func enumerateDirectory(
        _ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
        attributes wanted: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, context: FSContext,
        replyHandler reply: @escaping (FSEnumerateDirectoryResult?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? ReadOnlyItem else { return reply(nil, ModuleError.invalid) }
        // The volume never changes, so one nonzero verifier holds for its whole life.
        let current: UInt64 = 1
        var position = cookie.rawValue
        do throws(DiskError) {
            pages: while true {
                let page = try tree.page(of: directory.mountID, from: position, includeDots: wanted == nil, limit: 128)
                if page.isEmpty { break }
                for entry in page {
                    let attributes = wanted == nil ? nil : try attributes(entry.mountID)
                    let packed = packer.packEntry(
                        name: FSFileName(data: Data(entry.name)), itemType: Self.type(entry.kind),
                        itemID: FSItem.Identifier(rawValue: entry.mountID) ?? .invalid,
                        nextCookie: FSDirectoryCookie(rawValue: entry.nextCookie), attributes: attributes)
                    if !packed { break pages }
                    position = entry.nextCookie
                }
            }
            reply(FSEnumerateDirectoryResult(verifier: current), nil)
        } catch {
            reply(nil, cookie.rawValue == 1 ? ModuleError.invalidCookie : error.fskit)
        }
    }

    // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
    func readSymbolicLink(
        _ item: FSItem, context: FSContext, replyHandler reply: @escaping (FSReadSymlinkResult?, (any Error)?) -> Void
    ) {
        answer(item, reply, "readlink") { (item) throws(DiskError) -> FSReadSymlinkResult? in
            let target = try tree.fileSystem.readLink(tree.readerID(for: item.mountID))
            return FSReadSymlinkResult(
                contents: FSFileName(data: Data(target)), symlinkAttributes: try attributes(item.mountID))
        }
    }
}

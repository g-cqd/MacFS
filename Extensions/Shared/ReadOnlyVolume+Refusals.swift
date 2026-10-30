import FSKit

// Every operation that would change the volume. The volume is mounted read-only, so the kernel should
// not send these; if it does, the answer is EROFS. Each signature is an FSKit protocol requirement, so
// their likeness is the API's, not a copy to factor out.
// @dl:accept -- six FSKit requirements that all answer EROFS; the shared part is their signatures
extension ReadOnlyVolume {
    func setAttributes(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        _ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, context: FSContext,
        replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }

    func createItem(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName, type: FSItem.ItemType, in directory: FSItem,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        attributes newAttributes: FSItem.SetAttributesRequest,
        context: FSContext, replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }

    func createSymbolicLink(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        named name: FSFileName, in directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        context: FSContext, replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }

    func createLink(
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext,
        replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }

    // FSKit fixes this signature; the count is the protocol's.
    // swiftlint:disable:next function_parameter_count
    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName,
        // @dl:accept -- an FSKit requirement; the parameter list is the protocol's
        inDirectory destinationDirectory: FSItem, overItem: FSItem?, context: FSContext,
        replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }

    func removeItem(
        _ item: FSItem, named name: FSFileName, from directory: FSItem, context: FSContext,
        replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void
    ) { reply(nil, ModuleError.readOnly) }
}

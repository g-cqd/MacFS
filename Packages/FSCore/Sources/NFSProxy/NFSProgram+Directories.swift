import FSCore
import MountKit

extension NFSProgram {
    /// The one cookie verifier: the volume never changes, so every cookie handed out stays valid.
    static let verifier: UInt64 = 1

    /// READDIR and READDIRPLUS. Entries are added until the next one would pass `limit` bytes; `.` and `..`
    /// come from `MountedTree`, so their cookies are the same as FSKit's.
    func list(_ id: UInt64, cookie: UInt64, verifier: UInt64, limit: Int, plus: Bool, _ results: inout XDRWriter) {
        guard cookie == 0 || verifier == Self.verifier else {
            results.u32(NFSStatus.badCookie)
            dispatcher.attributes.postOp(id, into: &results)
            return
        }
        answer(&results, failureAttributes: id) { (writer) throws(DiskError) in
            dispatcher.attributes.postOp(id, into: &writer)
            writer.u64(Self.verifier)
            // The fixed part of the reply (status, attributes, verifier, list end, eof) is under 120 bytes.
            var used = writer.bytes.count + 16
            var position = cookie
            var finished = false
            var added = 0
            pages: while true {
                let page = try tree.page(of: id, from: position, includeDots: true, limit: 64)
                if page.isEmpty {
                    finished = true
                    break
                }
                for entry in page {
                    var item = XDRWriter()
                    item.bool(true)
                    item.u64(entry.mountID)
                    item.opaque(entry.name)
                    item.u64(entry.nextCookie)
                    if plus {
                        dispatcher.attributes.postOp(entry.mountID, into: &item)
                        item.bool(true)
                        item.opaque(dispatcher.handles.handle(entry.mountID))
                    }
                    if used + item.bytes.count > limit, added > 0 { break pages }
                    writer.append(item)
                    used += item.bytes.count
                    added += 1
                    position = entry.nextCookie
                }
            }
            writer.bool(false)
            writer.bool(finished)
        }
    }
}

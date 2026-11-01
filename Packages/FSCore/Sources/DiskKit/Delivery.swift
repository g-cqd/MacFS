/// The handler behind the callbacks' context pointer.
final class Delivery: Sendable {
    let handler: @Sendable (DiskEvent) -> Void

    init(_ handler: @escaping @Sendable (DiskEvent) -> Void) { self.handler = handler }

    static func of(_ context: UnsafeMutableRawPointer?) -> Delivery? {
        context.map { Unmanaged<Delivery>.fromOpaque($0).takeUnretainedValue() }
    }

    func deliver(_ event: DiskEvent?) { if let event { handler(event) } }
}

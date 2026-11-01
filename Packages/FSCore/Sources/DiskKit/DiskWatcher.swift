import DiskArbitration
public import Dispatch
import Foundation
import Synchronization

/// Disk Arbitration's appeared, changed and disappeared callbacks, as `DiskEvent`s on `queue` (roadmap 0021). On start, every
/// disk already attached is reported as appeared. Works in the App Sandbox (research 2026-11-01-disks-from-the-app).
///
/// `queue` must be serial: `stop` keeps the callbacks' context alive on it until the callbacks already queued have run.
public final class DiskWatcher: Sendable {
    private let session: Mutex<DASession?>
    private let queue: DispatchQueue
    /// The callbacks' context; kept alive past `stop` until the callbacks already queued have run.
    private let delivery: Delivery

    public init(queue: DispatchQueue, handler: @escaping @Sendable (DiskEvent) -> Void) {
        self.queue = queue
        let created = DASessionCreate(kCFAllocatorDefault)
        delivery = Delivery(handler)
        let pointer = Unmanaged.passUnretained(delivery).toOpaque()
        if let created {
            DARegisterDiskAppearedCallback(
                created,
                nil,
                { disk, context in
                    Delivery.of(context)?.deliver(DiskDescription(disk).map(DiskEvent.appeared))
                },
                pointer
            )
            DARegisterDiskDescriptionChangedCallback(
                created,
                nil,
                nil,
                { disk, _, context in
                    Delivery.of(context)?.deliver(DiskDescription(disk).map(DiskEvent.changed))
                },
                pointer
            )
            DARegisterDiskDisappearedCallback(
                created,
                nil,
                { disk, context in
                    Delivery.of(context)?
                        .deliver(DADiskGetBSDName(disk).map { DiskEvent.disappeared(String(cString: $0)) })
                },
                pointer
            )
            DASessionSetDispatchQueue(created, queue)
        }
        session = Mutex(created)
    }

    deinit { stop() }

    /// Stops the callbacks; no event follows the ones already queued. Idempotent.
    public func stop() {
        guard let stopped = session.withLock({ $0.take() }) else { return }
        DASessionSetDispatchQueue(stopped, nil)
        // The callbacks already queued still read the context: it lives until they have run.
        queue.async { [delivery] in withExtendedLifetime(delivery) {} }
    }
}

/// The handler behind the callbacks' context pointer.
private final class Delivery: Sendable {
    let handler: @Sendable (DiskEvent) -> Void

    init(_ handler: @escaping @Sendable (DiskEvent) -> Void) { self.handler = handler }

    static func of(_ context: UnsafeMutableRawPointer?) -> Delivery? {
        context.map { Unmanaged<Delivery>.fromOpaque($0).takeUnretainedValue() }
    }

    func deliver(_ event: DiskEvent?) { if let event { handler(event) } }
}

extension DiskDescription {
    /// The disk's description as Disk Arbitration has it now; nil without one or without a BSD name.
    init?(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as NSDictionary? as? [String: Any] else { return nil }
        self.init(description.compactMapValues { DiskValue($0 as CFTypeRef) })
    }
}

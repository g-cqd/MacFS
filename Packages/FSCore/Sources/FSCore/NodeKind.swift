/// What a node is, in the terms every mount technology shares.
public enum NodeKind: Sendable, Equatable {
    case regular
    case directory
    case symlink
    case fifo
    case characterDevice
    case blockDevice
    case socket
}

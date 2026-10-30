/// One line of the app's status pane.
public struct StatusCheck: Identifiable, Sendable, Equatable {
    public enum State: Int, Sendable, Comparable {
        case ok, information, unknown, attention, failed
        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What the user can do about it, as a button.
    public enum Remedy: Sendable, Equatable {
        case openExtensionSettings
        case moveToApplications
        case reinstall
    }

    public let id: String
    public let title: String
    public let state: State
    public let detail: String
    public let remedy: Remedy?

    public init(id: String, title: String, state: State, detail: String, remedy: Remedy? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.remedy = remedy
    }
}

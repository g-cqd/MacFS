import AppSupport
import SwiftUI

/// How each state and remedy looks: one place, so the sidebar and the pane agree.
enum StatusStyle {
    /// Symbol, color and spoken label of a state, in one table.
    private static func look(_ state: StatusCheck.State) -> (symbol: String, color: Color, label: String) {
        switch state {
            case .ok: ("checkmark.circle.fill", .green, "OK")
            case .information: ("info.circle.fill", .blue, "Note")
            case .unknown: ("questionmark.circle", .secondary, "Unknown")
            case .attention: ("exclamationmark.triangle.fill", .orange, "Needs attention")
            case .failed: ("xmark.octagon.fill", .red, "Failed")
        }
    }

    static func symbol(_ state: StatusCheck.State) -> String { look(state).symbol }
    static func color(_ state: StatusCheck.State) -> Color { look(state).color }
    static func label(_ state: StatusCheck.State) -> String { look(state).label }

    static func title(_ remedy: StatusCheck.Remedy) -> String {
        switch remedy {
            case .openExtensionSettings: "Open Extension Settings…"
            case .moveToApplications, .reinstall: "Show in Finder"
        }
    }
}

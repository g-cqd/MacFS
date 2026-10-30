import AppSupport
import SwiftUI

/// One check: a symbol for its state, its title and detail, and the button that fixes it.
struct StatusRow: View {
    let check: StatusCheck
    let perform: (StatusCheck.Remedy) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: StatusStyle.symbol(check.state))
                .foregroundStyle(StatusStyle.color(check.state))
                .font(.title3)
                .frame(width: 22)
                .accessibilityLabel(StatusStyle.label(check.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.headline)
                Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let remedy = check.remedy {
                Button(StatusStyle.title(remedy)) { perform(remedy) }
            }
        }
        .padding(.vertical, 4)
    }
}

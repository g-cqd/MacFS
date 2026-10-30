import AppKit
import AppSupport
import SwiftUI

/// Settings → Status: the summary, every check with its remedy, and a live refresh while the pane is open, so enabling a
/// module in System Settings shows here without a click.
struct StatusPane: View {
    let status: ExtensionStatus
    @AppStorage("liveStatus") private var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: StatusStyle.symbol(status.summary.state))
                    .font(.system(size: 34))
                    .foregroundStyle(StatusStyle.color(status.summary.state))
                VStack(alignment: .leading) {
                    Text(status.summary.headline).font(.title3.weight(.semibold))
                    if let checked = status.checkedAt {
                        Text("Checked \(checked.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Now") { Task { await status.refresh() } }
            }
            Divider()
            List(status.checks) { check in StatusRow(check: check) { status.perform($0) } }
                .listStyle(.inset)
            HStack {
                Toggle("Refresh while this pane is open", isOn: $live)
                Spacer()
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(status.report, forType: .string)
                }
            }
        }
        .padding()
        .task(id: live) {
            await status.refresh()
            while live, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await status.refresh()
            }
        }
    }
}

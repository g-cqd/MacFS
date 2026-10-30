import SwiftUI

/// Settings → General: what MacFS does on its own.
struct GeneralPane: View {
    @AppStorage("checkStatusAtLaunch") private var checkAtLaunch = true
    @AppStorage("liveStatus") private var live = true

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Check the file system modules when MacFS opens", isOn: $checkAtLaunch)
                Toggle("Refresh the Status pane while it is open", isOn: $live)
            }
            Section("Volumes") {
                LabeledContent("Access", value: "Read-only")
                Text("Writing is designed per format and gated on the Linux tools' own checkers (roadmap 0017).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

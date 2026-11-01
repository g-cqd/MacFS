import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let status: ExtensionStatus
    @State private var browser = Browser()
    @State private var mounts = Mounts()
    @State private var selection: Browser.Row.ID?
    @AppStorage("checkStatusAtLaunch") private var checkAtLaunch = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List {
                Section("Status") {
                    Button {
                        openSettings()
                    } label: {
                        Label {
                            Text(status.summary.headline)
                        } icon: {
                            Image(systemName: StatusStyle.symbol(status.summary.state))
                                .foregroundStyle(StatusStyle.color(status.summary.state))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open the Status pane")
                    ForEach(status.checks.filter { $0.id.hasPrefix("module.") }) { check in
                        Label {
                            Text(check.title)
                        } icon: {
                            Image(systemName: StatusStyle.symbol(check.state))
                                .foregroundStyle(StatusStyle.color(check.state))
                        }
                    }
                }
                Section("Mounts") {
                    ForEach(mounts.records, id: \.id) { record in
                        HStack {
                            Label(
                                record.mountPoint.split(separator: "/").last.map(String.init) ?? record.mountPoint,
                                systemImage: "externaldrive.connected.to.line.below"
                            )
                            .help("\(record.source) at \(record.mountPoint)")
                            Spacer()
                            Button {
                                Task { await mounts.unmount(record) }
                            } label: {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.borderless)
                            .help("Unmount")
                        }
                    }
                    if let problem = mounts.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                if checkAtLaunch { await status.refresh() }
                if status.facts.agent == .enabled { await mounts.refresh() }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(Array(browser.path.enumerated()), id: \.offset) { index, part in
                        Button(part.1) { browser.up(to: index) }.buttonStyle(.link)
                        if index < browser.path.count - 1 {
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Mount") {
                        if let image = browser.image { Task { await mounts.mount(image) } }
                    }
                    .disabled(browser.image == nil || mounts.busy || status.facts.agent != .enabled)
                    .help("Mount it in Finder through the NFS proxy; it stays mounted after MacFS quits")
                    Button("Open Image…", action: chooseImage)
                }
                Table(browser.rows, selection: $selection) {
                    TableColumn("Name") { row in Label(row.name, systemImage: icon(row)) }
                    TableColumn("Size") { row in
                        Text(
                            row.kind == .directory
                                ? "—" : ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file)
                        )
                    }
                }
                .contextMenu(forSelectionType: Browser.Row.ID.self) { ids in
                    if let row = browser.rows.first(where: { ids.contains($0.id) }), row.kind == .regular {
                        Button("Export…") { export(row) }
                    }
                } primaryAction: { ids in
                    if let row = browser.rows.first(where: { ids.contains($0.id) }) { browser.enter(row) }
                }
                if let problem = browser.problem { Text(problem).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(browser.title)
        }
    }

    private func icon(_ row: Browser.Row) -> String {
        switch row.kind {
            case .directory: "folder"
            case .symlink: "arrow.turn.up.right"
            default: "doc"
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage, .data]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { browser.open(url) }
    }

    private func export(_ row: Browser.Row) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = row.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? browser.export(row, to: url)
    }
}

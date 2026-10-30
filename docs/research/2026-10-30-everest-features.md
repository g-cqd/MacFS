# Everest: what MacFS takes, and what it leaves (2026-10-30)

Everest (`~/Developer/ongoing/swift/Everest`) mounts UPnP media servers. ADR-0001 takes its findings, not its code. Read: its
README (the findings table), `EverestCore` (MountBackend, MountService, MountRemovalPolicy, FileLogger, the WebDAV and File Provider
backends), `WebDAVKit`, and the app (MountController, settings panes).

| Everest | What it is | For MacFS | Status |
|---|---|---|---|
| Host app must live in /Applications | FSKit and File Provider register extensions of an installed app only | The status pane checks it and offers "Show in Finder" | **Taken** (AppSupport) |
| Reveal out of process (`/usr/bin/open -R`) | `activateFileViewerSelecting` stats on the main thread; a wedged volume pins the UI | Every reveal in the app | **Taken** (ExtensionStatus) |
| Settings window with panes | Backends and media players configured in Settings | Status, General, Formats, About | **Taken**, with a tested status model |
| `MountBackend` + `MountService` | One protocol per mount technology; unmount routed to the backend that mounted | FSKit, NFS proxy, WebDAV (0008) and File Provider share it once the app mounts (0021) | Roadmap 0035 |
| WebDAVKit findings | Finder probes `._*`, `.DS_Store`, `.metadata_*` (answer 404); Quick Look issues no-range GETs (refuse large ones); bounded channels (backpressure); `mount_webdav -S` | The WebDAV option (0008) takes the findings; the code only after its own tests pass here | Roadmap 0008, amended |
| File Provider backend | A Finder sidebar domain that survives quit; whole-file `fetchContents` only (ranged reads measured ignored) | Images browsable without enabling an FSKit module; acceptable for small files only | Roadmap 0036 |
| Teardown in `NSApplicationDelegate`, stale mounts cleared at launch | SwiftUI `.task` cancellation fires on view churn, not only on quit | Required before the app hosts the NFS proxy itself | Roadmap 0035 |
| `FileLogger` (`~/Library/Logs/<app>/`) | Request-level logs tie a Finder stall to the request | The modules log through `Logger`; the app's "Copy Diagnostics" covers status. A file log only with the in-app proxy | Left |
| Media player Services ("Stream with IINA") | Hands a loopback URL to a player | Local volumes stream natively | Not applicable |
| UPnPKit, SSDP per interface | Discovery of media servers | No network sources in MacFS | Not applicable |
| Swift 6.4 typed-throws crash | `catch E.case` crashes SIL | Seen here too, in another form (a typed-throws closure into a `rethrows` API) | Recorded in AGENTS.md |

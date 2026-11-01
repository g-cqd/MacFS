# Disks from the app: what macOS already does, and what a sandboxed app can do (2026-11-01)

**Question.** Roadmap 0021 says "Disk Arbitration discovery, raw device access through `authopen`, mounting through
`FSClient.mountSingleVolume`". Which of these does a sandboxed MacFS need, and which does macOS do already?

**Method.** The installed Release app's four FSKit modules (macOS 27, M2 Pro); test images attached with `hdiutil` (with and
without `-nomount`); `diskutil`; Finder by AppleScript; and a probe calling Disk Arbitration directly
(`probes/disk-arbitration.swift.txt`: `DADiskCopyDescription`, `DADiskUnmount`, `DADiskMount`), run plain and sandboxed (the App
Sandbox entitlement, an Info.plist in the binary; the sandbox confirmed by a file outside the container being unreadable).
Apple's exFAT FSKit module, on a 20 MB exFAT image, as the reference.

## Results

| Check | ext4 | btrfs | NTFS | XFS | exFAT (Apple) |
|---|---|---|---|---|---|
| Automounted on attach (`fskit`, `/Volumes/<name>`) | ours | ours | **Apple's** (`UVFSService`) | ours | Apple's |
| Disk Arbitration's description: `DAVolumeKind`, name, UUID, path | yes | yes | yes | yes | yes |
| `DADiskUnmount`, then `DADiskMount` | both work | both | both | both | — |
| The same calls from a sandboxed process | work (ext4 tried) | | | | |
| `DADiskMount` of a disk attached `-nomount` | mounts (ext4 tried) | | | | |
| `diskutil unmount` / `diskutil mount` | **fail** (StorageKit error 119) | **fail** | mount works after `-nomount` | **fail** | both work |
| `diskutil info`: personality, bundle | **none** ("no file system") | **none** | Apple's `ntfs` bundle | **none** | `ExFAT`, `exfat` |
| Finder's Eject | unmounts and ejects (ext4 tried) | | | | |

Also measured:
- **Signing:** the development profile grants `com.apple.developer.fskit.mount`, the entitlement `FSClient.mountSingleVolume`
  requires. The app was signed with it and its embedded profile lists it. A mount through it was not tried.
- **Resources:** `FSBlockDeviceResource` has no public initializer, so the app cannot name a disk to `mountSingleVolume`.
  `FSPathURLResource(url:writable:)` can be made for a file, but only for a module that sets `FSSupportsPathURLs`, and ours set it
  false. It could mount an image as a local FSKit volume, with no `hdiutil` and no NFS proxy (not tried).
- **Stale registrations:** pluginkit had the modules registered from the build folder (`/tmp/macfs-release/...`), not
  `/Applications`, and the modules ran from there; a scratch build in another folder took them over in turn. Unregistering with
  `pluginkit -r` and adding with `-a` moved them, but cost XFS its enablement, which only System Settings could restore. The
  installer (roadmap 0041) unregisters the build's copy with `lsregister -u` and deletes it instead; after two installs all four
  modules were still enabled.
- **NTFS:** the NTFS image was automounted by Apple's own reader (`UVFSService`, through `ntfs.fs`), not by our module, whose
  process was not running; ours mounts only when named (`mount -F -t ntfsro`).

## Conclusions

1. **Real disks need no raw access.** macOS mounts our formats on attach through our modules. The app's part is to show them and
   to unmount, mount again and eject through Disk Arbitration, which works sandboxed. `authopen` drops out of 0021.
2. **Disk Arbitration is the registry for disks.** Their lifecycle belongs to macOS (attach, automount, eject). The mount
   registry (ADR-0016) keeps the mounts MacFS makes itself, of image files, which macOS does not track.
3. **`diskutil` and StorageKit do not know our volumes.** Disk Utility probably has the same problem (not tried). Apple's FSKit
   modules ship a `/System/Library/Filesystems/<name>.fs` bundle beside them; whether a third-party `.fs` bundle in an app can
   supply one is an open question for a later item.
4. **A third image backend is in reach:** FSKit with path URL resources, through `FSClient.mountSingleVolume`. Images would mount
   as local volumes in `/Volumes`, with the kernel's buffer cache and none of NFS's limits. It needs the modules to accept
   `FSPathURLResource`, and a probe.

Not verified: Finder's Eject for btrfs, NTFS and XFS; `DADiskMount` of a partition (ext4-gpt); a physical USB disk; Disk Utility.

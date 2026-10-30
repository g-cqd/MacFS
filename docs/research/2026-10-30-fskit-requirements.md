# What macOS requires of a file-system extension (2026-10-30)

**Sources.** apple-docs MCP (FSKit, `building-a-passthrough-file-system`, the entitlement page), the macOS 27.2 SDK headers
(`FSKit.framework/Headers`, swiftinterface), Xcode 27.1's "File System Extension" template, and the shipped
`/System/Library/ExtensionKit/Extensions/com.apple.fskit.msdos.appex` (Info.plist and entitlements read with `plutil` and `codesign -d`).

## Mandatory

| Requirement | Evidence |
|---|---|
| An ExtensionKit app extension embedded in an app (`Contents/Extensions`) | Template ancestor `com.apple.dt.unit.extensionkit-extension.macOS`; msdos is an `.appex` under ExtensionKit |
| Entitlement `com.apple.developer.fskit.fsmodule` = true | Template entitlements; msdos entitlements; docs list it under FSKit → Entitlements |
| App Sandbox on the extension | Template `ENABLE_APP_SANDBOX = YES`; msdos `com.apple.security.app-sandbox` |
| `EXAppExtensionAttributes` with `EXExtensionPointIdentifier = com.apple.fskit.fsmodule` and `FSShortName` | Template and msdos Info.plist; `FSStatFSResult.fileSystemTypeName` "must match FSShortName" (docs) |
| Resource keys: `FSSupportsBlockResources` (block devices), or path/generic/server URL keys | Template, msdos |
| `FSPersonalities` (name, case sensitivity), optional `FSMediaTypes` (partition types, probe order) | Template, msdos |
| An `@main` type conforming to `UnaryFileSystemExtension` returning an `FSUnaryFileSystem & FSUnaryFileSystemOperations` | Template; docs: "The current version of FSKit supports only FSUnaryFileSystem" |
| `probeResource`, `loadResource` (returns the `FSVolume`), `unloadResource` | `FSUnaryFileSystem.h` |
| The volume implements `FSVolume.Handler` (macOS 27) or the deprecated `FSVolume.Operations` (15.4 to 26) | `FSVolume.h`: `FSKIT_API_INTRODUCED_V1_DEPRECATED_V3_WITH_REPLACEMENT("FSVolumeHandler")` |
| The user enables the module: System Settings → General → Login Items & Extensions → File System Extensions | Passthrough sample; `FSClient.openFileSystemExtensionsSettings()` (macOS 27) opens it |
| Mount with `mount -F -t <FSShortName> <resource> <dir>` or `FSClient.mountSingleVolume` (macOS 27) | Passthrough sample (`mount -t passthrough`); `FSClient.h` |

## Directory enumeration rules (docs)

Pack `.` and `..` only when no attributes are requested; for the root they are identical. Reply with a nonzero verifier. An unknown
cookie answers `FSError.Code.invalidDirectoryCookie`. Implemented in `MountedTree` and proved in `Proofs/MountedTree.lean`.

## What macOS 27 adds (headers)

The `*Handler` protocols take an `FSContext` (caller's ids) and return result objects that carry attributes (`FSLookupItemResult`,
`FSReadFileResult`, ...); `FSClient.mountSingleVolume`; `FSVolume.KernelOffloadedIOHandler`; `requestedMountOptions` (`.readOnly`).

## Not verified here

Whether the account can be granted the capability: it can (roadmap 0006; Everest's failure was not reproduced here). Whether automount
follows `FSMediaTypes` without `FSProbeExecutable` (msdos uses `msdos.util`; the template omits it). No module was loaded.

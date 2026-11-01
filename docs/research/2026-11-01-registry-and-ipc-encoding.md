# The mount registry's and the agent's encoding: protobuf, plist or JSON (2026-11-01)

**Question.** The mount registry (roadmap 0035) is a small file that must survive crashes, and app upgrades and downgrades. The
agent's messages (0039) cross a process boundary between an app and an agent that can run different versions for a while after an
update. Is AemiProtobuf better for MacFS than a Foundation property list or AemiJSON, or only faster?

**Method.** A scratch package (`/tmp/xh/regproto`, release, Swift 6.4, M2 Pro) at MacFS's pins: aemi `8475434`, AemiJSON `1a79d01`,
AemiProtobuf `7b7dbc5` (bumped to those pins for this; its `quality.sh fast` and `test` green). One registry of mount records
(id, kind, source, mount point, mounted-from) in two versions: v2 adds `owner` and renames `mountPoint` to `target`. Each encoding
through the same checks: version skew both ways, every truncation and every one-bit change of an eight-record file, size, and the
cost of a minimal executable.

## Results

| Check | protobuf (`@ProtoMessage`) | binary plist (`Codable`) | AemiJSON (`Codable`) |
|---|---|---|---|
| New reads old, v2 only adds a defaulted field | reads, default 0 | **`keyNotFound`** | **`keyNotFound`** |
| New reads old, a property renamed | reads (field number kept) | **`keyNotFound`** | **`keyNotFound`** |
| Old reads new | reads | reads (added key ignored) | reads |
| Old rewrites new: is the new field kept? | **kept** (unknown fields, its ADR 0012) | **lost** | **lost** |
| An enum value the old reader does not know | default value, raw kept and restored on rewrite | — | — |
| Truncations of the 8-record file | 1,392 of 1,400 refused; **8 accepted**: each cut at a record boundary decodes as fewer records | all 1,678 refused | all 1,821 refused |
| One-bit changes | 96 refused, **1,304 accepted with other values** | 276 refused, **1,395 accepted different** | 517 refused, **1,304 accepted different** |
| Size, 8 records | 1,400 B | 1,678 B | 1,821 B |
| Minimal executable, stripped | 597 KB | 56 KB | 2,359 KB |
| Clean release build | 201 s (swift-syntax, for the macro) | 8 s | 212 s |

Synthesized `Codable` cannot read a file written before a field was added, even a defaulted one, and loses fields it does not
know on rewrite: every change would need a hand-written `init(from:)`, and a downgrade followed by an upgrade loses data. Protobuf
does both by construction. No encoding detects corruption: most single-bit changes decode to other values. Protobuf alone accepts
some truncations. A closed enum maps an unknown value to its default, so an older agent would read a WebDAV mount as FSKit and
route its unmount to the wrong backend.

XPC carries `Codable` values itself (`XPCSession.send`, macOS 14), so the IPC does not need protobuf to work. It needs protobuf
for the same skew an app update creates: the app, updated, talks to an agent of the previous version until launchd restarts it.

AemiJSON's size comes mostly from its engine; 17% of its code (225 KB) is AemiRegex, linked through `Schema/` beside the coders
(reported: g-cqd/AemiJSON#5).

## Verdict

Protobuf is better for MacFS, not only faster, on three conditions, which ADR-0015 records:

1. **An envelope**: magic, format version, length, CRC-32C (aemi's kernel, already in MacFS) over the message, written to a
   temporary file, `fsync`ed and renamed. It refuses the truncations protobuf accepts and the bit changes no format catches.
2. **Open enums** for every kind a newer version may add; an unrecognized value is refused, never acted on.
3. **Outside `MountKit`**: the FSKit extensions link MountKit, and the 0.6 MB and swift-syntax build belong only to the app and the
   agent. The seam keeps its store behind a protocol; the protobuf store is its own target.

Not measured: the agent's message rate (small; speed is not the reason), and a downgrade through a real app update.

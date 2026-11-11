# Locus

Locus is an iOS/iPadOS MobileGestalt management tool with device diagnostics,
independent region and capability changes, and backed-up transactions. Hardware
identity is never rewritten. It uses private APIs and requires a device you own
or are authorized to manage. It is not affiliated with Apple.

## Features and availability

| Feature | Behavior and requirements |
| --- | --- |
| Diagnostics | Model, iOS/build, cache access, CacheUUID, CacheVersion, CacheData length, runtime answers and DeviceTree values |
| RegionCode | Changes an existing string to J; exact-value restore |
| RegionInfo | Changes exactly one existing region-info key to J/A; ambiguous dual keys are rejected |
| RegulatoryModelNumber | Uses the existing real-ProductType whitelist for the Japan model |
| Apple Intelligence capability | Changes a missing or canonical Boolean/integer flag to true/1; restores its original type or absence |
| green-tea / not-green-tea / wapi | Requires an independently reviewed binary/cache mapping, valid values and file access |
| MobileActivation | Requires verified container identity, schema and reviewed storage/consumer semantics; separate refresh in Region |
| Full Japan Region | Requires every identity, cache-behavior and activation prerequisite; AI is independent |
| CoreText GB18030 | Separate process-local experiment, requiring a reviewed loaded binary and writable target memory |

The MobileGestalt mapping, MobileActivation and CoreText review registries are
empty. Their gated actions remain unavailable. Identity and AI actions still
require valid inputs, backups and actual on-device access. A capability flag does
not establish service availability or successful activation.

## Reading and diagnostics

Diagnostics and Region share `MobileGestaltAccess`. A read acquires a worse_query
lease for the existing MobileGestalt cache directory, opens the fixed absolute
`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`
path, checks that the opened object is a nonempty regular file of at most 16 MiB,
and reads it once. Plist display additionally requires a dictionary. The file
opens with `O_RDONLY | O_NOFOLLOW`; descriptors and leases are released on exit.
Permission and parsing failures appear in Diagnostics and can be retried with
Refresh. Raw-byte reads remain available to the backup/transaction code.

The fixed system ancestors are trusted and may resolve through symlinks. Final
component `O_NOFOLLOW` is **not** equivalent to opening every ancestor without
following links. Ordinary reads neither open `/private` separately nor require
runtime descriptor mapping, hashes, repeated reads or an audit export. A single
read does not promise a coherent snapshot during a concurrent system update.

Loaded-image inspection remains part of the separate mutation checks; it is not
a prerequisite for Diagnostics. Diagnostics does not request write access or
scan MobileActivation containers. Its runtime answers and DeviceTree values are
independent observations of current process APIs and IORegistry.

## Backups and recovery

Persistent actions use the serialized Region coordinator. It saves original and
intended bytes, SHA-256 checksums, device/build identity, a fixed write scope and
a durable journal before writing. Exact current bytes must match before each
write. Readback verifies results; failures attempt reverse-order rollback and
report verified recovery or recovery required.

`Documents/Region Module Backups` holds first-module originals and operation
journals. Legacy backups are retained. "Original" means before Locus's first
edit, not factory provenance. Restore preserves unrelated fields and rejects
incompatible updates or external target-field changes. An unfinished journal
blocks writes to its affected source until recovered. Keep the app container and
backups while recovery is pending; export the container through Xcode before
reinstalling.

The inode-preserving writer uses truncation and in-place writes. Partial content
can be visible to other readers; neither power-loss atomicity nor cross-file
atomicity is guaranteed. This read simplification does not relax those write
gates or remove backups, compare-and-replace, readback or recovery.

CoreText changes no system file or page protection and restores its temporary
cached byte. Glyph-cache reuse can still make its rendering result inconclusive.

## Build and sign

Use Xcode with the project's iOS SDK, Developer Mode, and your own signing team.
The project/scheme is `Locus`, with default bundle identifier
`io.github.tenkyuchimata.locus`. No team is hardcoded. Register a dedicated App
Group `group.<your Bundle Identifier>` and authorize it in the provisioning
profile. Debug and Release both use `Locus/Locus.entitlements`.

The bridge checks signed entitlements and group-container access. A single
signer-remapped group is accepted; ambiguous multiple groups require the
bundle-derived group. Re-signing an unsigned IPA must provide usable App Group
entitlements. Compilation alone does not establish device access.

worse_query temporarily replaces the dedicated group's `Library/Caches` path.
Locus preserves existing data by rename and restores the original directory,
with process serialization and a cross-process lock. Residual links or
`.locus-worse-query-caches` backups are refused rather than deleted. Inspect and
preserve them after interruption. Other apps should not share this workspace.

```sh
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/LocusDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Validation

```sh
sh Scripts/test-portable.sh    # C sanitizers, Python/project checks; Swift if available
sh Scripts/test-swift.sh       # planners, mapping write gates, journals, recovery
sh Scripts/test-macos.sh       # native access/write/image tests and Swift; Apple SDKs
sh Scripts/check-ios-native.sh # iPhoneOS arm64 source checks; Xcode required
```

Tests use synthetic data, temporary files and simulated private authorization
APIs. Optional local device snapshots remain read-only and are never bundled.
CI runs portable checks, native host/Swift and iPhoneOS source checks, independent
unsigned Debug/Release builds, then a gated Release rebuild and IPA packaging.
A failed required check prevents IPA upload.

Linux checks cannot validate Objective-C/Swift against Apple SDKs, device sandbox
access or the actual UI. macOS tests, iPhoneOS Debug/Release builds, packaging and
real-device read/refresh checks must be verified in their respective environments.

## License

Locus is **GPL-3.0-only**; see [LICENSE](LICENSE). The inherited MIT notice is
preserved in [LICENSES/Locus-original-MIT.txt](LICENSES/Locus-original-MIT.txt).
worse_query retains its original GPL-3.0-or-later notice. These notices and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) are bundled with the app.

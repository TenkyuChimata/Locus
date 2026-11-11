# Locus

Locus is an iOS/iPadOS MobileGestalt region tool. Its writable settings are
limited to the following six fields. **Full Japan Region applies all six in one
MobileGestalt plist transaction.** Hardware identity is never rewritten.

| Setting | Target |
| --- | --- |
| RegionCode | `J` |
| RegionInfo | `J/A`, using exactly one existing supported key |
| RegulatoryModelNumber | Japanese model from the existing verified ProductType map |
| green-tea | `false` |
| not-green-tea | `true` |
| wapi | `false` |

Each setting supports Review Changes, Apply and Restore. Full Japan offers the
same workflow for the combined six-field configuration. It does not change or
verify every system region behavior. Restart the device, observe runtime answers
and test affected features separately after applying.

## Supported layouts

CacheData writes and Full Japan currently support only **iPhone18,3 / iOS 27.2 /
24B119**, CacheUUID `48CB1FAC-755B-435F-9A01-A20E5D810EA9`, CacheVersion `24B119`,
6480 bytes (720 slots). The verified Japan model for this ProductType is `A3519`.
The existing ProductType/model map is unchanged; it does not authorize CacheData
writes on other models.

The Boolean slots are green-tea 383, not-green-tea 506 and wapi 694. Each must
contain a canonical 8-byte Boolean with validity exactly 1. Hashed or plain
CacheExtra overrides block the corresponding slot. Only the low value byte may
change; validity is never enabled or repaired. Unknown devices, builds, UUIDs,
lengths, field types, invalid slots and ambiguous RegionInfo keys are refused.
The three independent CacheExtra settings retain their existing checks without
requiring the unrelated CacheData options to be supported.

Full Japan validates all six before preparing a single plan, using
`JapanRegionMutation.applying()`. The coordinator independently checks the exact
three CacheExtra keys, three Boolean offsets and complete six-field target.
Other plist values, CacheData bytes, CacheUUID and CacheVersion must remain
semantically unchanged. Plist serialization can change container encoding; raw
original bytes are retained for exact restoration where possible.

## Review, Apply and Restore

The Region page contains Device, Individual Region Settings, Full Japan Region
and Recovery. Legacy backup details appear when relevant. Current file values,
targets, runtime observations, access and original-backup availability are shown
separately. Full Japan reports Ready, Applied, Not Applied, Unsupported or
Recovery Required. Applied means the six persistent values match; it makes no
claim about post-restart runtime or all system behavior.

Review Changes rereads and validates the source, saves complete original and
intended bytes with SHA-256 checksums, and durably prepares a journal. No system
write happens until the confirmation sheet's Apply or Restore button is pressed.
Confirmation uses the saved preview; any source-byte change rejects the write.
Already matching values report **Already Applied / No Changes Needed**, without
writing or creating an invented original baseline. An existing compatible
original remains available for Restore.

Every write uses `RegionTransactionCoordinator`, `MobileGestaltAccess` and the
inode-preserving `InPlaceFileTransaction` writer. Full byte readback follows
replacement; failures attempt a verified rollback. Original module pointers are
immutable. Restore uses the saved original target values, preserves unrelated
later changes and refuses externally changed target fields or incompatible
cache identities. New iOS journals bind the app vendor identifier as well as
ProductType/build; cached device identifiers, when present, must also match.

Backups are in `Documents/Region Module Backups`, inside the app container.
"Original" means the values before this module's first edit in its backup
format, not factory provenance. Preserve the app container while recovery is
pending; export it through Xcode before reinstalling.

## Legacy backups and recovery

New journals carry `schemaVersion = 2`. Full Japan uses
`originals/fullJapan-v2.plist`; the old `originals/fullJapan.plist` is never
reused, overwritten or migrated automatically. Existing compatible single-field
v1 MobileGestalt originals retain their names and can still restore within the
six-setting whitelist. Their checksums, context, layout and scope are rechecked.

The small legacy compatibility layer reads obsolete module/file names as
metadata only. Old dual-file Full Japan, standalone MobileActivation and Apple
Intelligence transactions are excluded from current Apply/Restore authorization.
Completed legacy journals and original pointers remain intact and are shown as
legacy records. Missing or corrupt legacy backups are reported explicitly.
The older `Japan Region Transaction Backups` directory is also retained, with
no automatic import of its unjournaled files.

Any unfinished unsupported legacy transaction blocks new writes and automatic
recovery. Locus retains every journal and backup for manual recovery review;
it never restores MobileActivation or an obsolete capability. A malformed
journal also blocks writes. Recovery of supported six-setting transactions
retains the existing context, checksums, compare-and-replace, rollback and
readback checks. No backup or journal is automatically deleted.

The in-place writer truncates and rewrites the existing inode. Partial content
can be visible to other readers; writes are not crash or power-loss atomic.
`flock` coordinates Locus writers but cannot exclude system daemons. If bytes
match neither original nor intended content, recovery refuses forced overwrite.

## Diagnostics and access

Diagnostics shows device/build, cache access, CacheUUID, CacheVersion, CacheData
length, CacheExtra and ordinary MobileGestalt runtime answers. Runtime answers
are current-process observations and may initialize process caches.

Reads acquire a worse_query lease for the fixed MobileGestalt cache directory
and open the fixed system plist with `O_RDONLY | O_NOFOLLOW`. The opened file must
be a nonempty regular file no larger than 16 MiB. Descriptors and leases are
released on exit. Ancestor symlinks are resolved by the OS; final-component
`O_NOFOLLOW` does not imply every ancestor was opened without following links.
A single read does not promise a coherent snapshot during a concurrent update.

MobileActivation access/discovery, RegionalBehavior reference research, CoreText
memory experiments and Apple Intelligence writes have been removed. There are
no DeviceTree, NVRAM, SysCfg or firmware write paths. The independent firmware
research directory outside this repository is untouched.

## Build and sign

Use Xcode, Developer Mode and your own signing team. The project/scheme is
`Locus`, default bundle identifier `io.github.tenkyuchimata.locus`. No team is
hardcoded. Register a dedicated App Group `group.<your Bundle Identifier>` and
authorize it in the provisioning profile. Debug and Release both use
`Locus/Locus.entitlements`.

The bridge retains signed-entitlement and group-container checks. A single
signer-remapped group is accepted; ambiguous groups require the bundle-derived
group. Re-signing an IPA must provide usable App Group entitlements. Compilation
does not establish device access.

worse_query temporarily replaces the dedicated group's `Library/Caches` path,
preserving existing data by rename and restoring the original directory. It
retains process serialization and a cross-process lock. Residual links and
`.locus-worse-query-caches` backups are refused rather than deleted. Other apps
should not share this workspace. Its lease allowlist is limited to the existing
MobileGestalt cache directory; container scanning and inode discovery are gone.

```sh
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/LocusDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Validation

```sh
sh Scripts/test-portable.sh    # C ASan/UBSan, Python/project checks; Swift if available
sh Scripts/test-swift.sh       # six-field planners, journals, legacy compatibility, disk writes
sh Scripts/test-macos.sh       # native access/CAS/lease regressions and Swift; Apple SDKs
sh Scripts/check-ios-native.sh # iPhoneOS arm64 source checks; Xcode required
```

Tests use synthetic data, temporary files and simulated native authorization
APIs. Optional local device snapshots remain read-only and are never bundled.
CI retains portable/native checks and unsigned Debug/Release builds; every
required check must pass before IPA packaging/upload. Linux checks cannot
validate Apple SDK compilation, SwiftUI, device sandbox access or real-device
behavior. Those require macOS/Xcode and a separately authorized device run.

## License

Locus is **GPL-3.0-only**; see [LICENSE](LICENSE). The inherited MIT notice is
preserved in [LICENSES/Locus-original-MIT.txt](LICENSES/Locus-original-MIT.txt).
worse_query retains its original GPL-3.0-or-later notice. These notices and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) are bundled with the app.

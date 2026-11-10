# Locus

Locus is a focused iOS/iPadOS region and runtime research utility. Japan Region
contains independent modules for MobileGestalt region identity, regional cache
behaviors, Apple Intelligence capability, MobileActivation, and a strict full
Japan transaction. Diagnostics and the process-local CoreText experiment remain
separate. Hardware identity is never rewritten.

Locus uses private APIs and is intended for devices you own or are authorized to
research. It is not affiliated with Apple.

## Current feature status

| Module | Implemented behavior | Write gate |
| --- | --- | --- |
| RegionCode | Existing string to J; independent exact-value restore | Typed existing key and file access |
| RegionInfo | Existing old **or** current key to J/A; no alias synthesis | Exactly one existing string alias; dual aliases remain unsupported |
| RegulatoryModelNumber | Japan model from the existing ProductType whitelist | Real device profile and typed existing key |
| Apple Intelligence capability | A62OafQ85EJAiiqKn4agtg to Boolean true/integer 1; restore original type or absence | Missing or canonical Boolean/integer 0 or 1 and file access |
| green-tea / not-green-tea / wapi | Independent descriptor diagnostics, bounded patches and restore | Exact binary review, cache identity/version/length, canonical values/validity and file access |
| MobileActivation | Independent diagnostics, schema planning and transactional restore path | Verified container identity, existing file, schema and reviewed storage/consumer binary semantics |
| CoreText GB18030 | Loaded UUID probe and temporary process-local rendering experiment | Reviewed predicate/data references and existing writable memory |
| Full Japan Region | All identity, three cache behaviors and activation sources in one transaction | Every prerequisite must pass; AI and CoreText are independent |

**No current MobileGestalt semantic review, MobileActivation storage/consumer
fingerprint or CoreText fingerprint is registered. Those writes remain disabled.**
Independent identity and AI actions do not depend on those reviews. They still
require authorized on-device file access; host tests do not prove that access.

The dynamic scanner snapshots the process's loaded MobileGestalt image using
checked Mach VM reads. It examines __TEXT.__cstring and relevant __const sections
in __AUTH_CONST, __DATA_CONST and __DATA, with segment/section/ASLR bounds checks.
The 64-byte descriptor, +0x3A index and +0x3C type-11 Boolean are hypotheses.
Its five levels are Unavailable, Candidate, Structurally Valid, Binary Verified
and Writable. A masked PAC pointer match, a unique cstring UUID, matching answers,
or 8N+N bytes alone never grants write permission. wapi is scanned independently;
there is no historical-offset fallback.

Identity changes touch only their allowed CacheExtra key. RegionCode and sales
region are independent. RegionInfo never adds a second alias; when both aliases
exist, diagnostics show both and writes require further semantic review. The AI
capability flag does not establish Settings visibility, model-download access
or working Apple Intelligence services.

## Backups, transactions and recovery

All persistent actions use one serialized coordinator and an inode-preserving
compare-and-replace writer. Before writing it saves complete original and intended
file bytes, SHA-256 checksums, a fixed key/byte whitelist, device model/build and
a durable transaction phase. Exact current bytes must still match before each
write. Complete readback verifies the result; failures roll back in reverse order
and report verified rollback or recovery required.

The new Documents/Region Module Backups directory contains immutable first-module
baseline references and per-operation journals. Legacy Japan Region Transaction
Backups and user-saved originals are retained. Original means the state before
Locus's first edit, **not factory provenance**. An already-J/A no-op creates no
invented original. Restore changes only the selected module's exact saved values
(including AI key absence and validity bytes), preserving other modules. A system
update or external target-field change requires review instead of forced restore.

After interruption, writes to the affected source are blocked until its journal is recovered; a standalone activation failure does not block unrelated MobileGestalt modules.
Preparing/prepared phases cannot have written system files and are closed without
overwriting external changes. A full transaction requires both source plans inside the coordinator itself.
Writing/rollback phases accept only exact original
or intended file contents. Unrecognized torn/corrupt contents retain the original
backups and require manual investigation; in-place truncation cannot promise
power-loss atomicity or a cross-inode atomic commit. Do not delete the app or its container while recovery is
outstanding. Export the app container through Xcode before reinstalling.

CoreText never changes system files, memory page protection or the once token.
Its reviewed-path experiment restores its one cached byte in cleanup and uses
identical rendering inputs for baseline/override/restored controls. Glyph-cache
reuse can still make rendering comparisons inconclusive. It is independent of
the system RegionalBehaviorGB18030 answer.

See [the review and device acceptance procedure](docs/region-modules-review.md)
for evidence gaps, risks, changed files and iPhone18,3 / 24B119 checks.

## Building and signing

Requirements:

- Xcode with the iOS SDK required by the project
- an authorized iPhone or iPad whose individual capability checks pass
- Developer Mode and your own signing configuration for device installation

The product and scheme are `Locus`; the default bundle identifier is
`io.github.tenkyuchimata.locus`. No development team is hardcoded. Open
`Locus.xcodeproj`, select your own team (and change the bundle identifier if
your signing account requires it). Register a dedicated App Group named
`group.<your Bundle Identifier>` and authorize it in your provisioning profile.
Both Debug and Release use `Locus/Locus.entitlements`, with
`group.$(PRODUCT_BUNDLE_IDENTIFIER)`; no Team ID is embedded.

The bridge reads the actual process signature via Security task APIs and checks
that FileManager can open the group container. When Security introspection is
unavailable, only the bundle-derived group is probed through the container API.
A signer-remapped single App
Group is accepted; ambiguous multiple groups require the bundle-derived group.
Unsigned builds can be packaged without provisioning, but installation/re-signing
must supply authorized App Group entitlements. Missing or mismatched signing
produces an explicit error; unsigned compilation does not validate access.

worse_query temporarily uses the group's `Library/Caches` path. Existing data
is moved aside and restored without recursive removal. Cross-process locking
and process-wide serialization protect query setup. If execution is interrupted,
Locus refuses any residual symlink or `.locus-worse-query-caches` backup instead
of deleting it. Preserve that backup and inspect the group before recovery.
Use a dedicated group; unrelated apps should not access its Caches during a query.

Unsigned validation/build:

```sh
xcodebuild \
  -project Locus.xcodeproj \
  -scheme Locus \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/LocusDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

The GitHub Actions workflow runs portable regressions, macOS native regressions,
and generic unsigned Debug/Release device builds in independent jobs. A failed
test does not prevent either build from reporting its result and keeps CI red.
Only after all jobs succeed does the packaging job rebuild unsigned Release,
place `Locus.app` under `Payload`, and upload `Locus-unsigned.ipa`.

Do not treat a simulator or host build as validation of private device behavior.
Persistent mutation and CoreText address validation require on-device testing.

## Architecture

- `Region/` — independent planners, descriptor assessments, ProductType profiles,
  fixed write scopes, immutable originals, SHA-256 journals and transaction UI
- `Diagnostics/` — the compact read-only diagnostics model and UI
- `CoreText/` — loaded-binary CoreText validation/experiment and rendering UI
- `LowLevel/` — focused Objective-C bridges for MobileGestalt,
  MobileActivation, DeviceTree/IOKit, and worse_query
- `Support/` — the retained optional SpringBoard refresh implementation

## Licensing and attribution

Locus as a combined distribution is licensed **GPL-3.0-only**; the complete GNU
GPL version 3 text is in [LICENSE](LICENSE). The previous MIT copyright and
permission notice, including GestaltEdit and Locus contributors, is preserved in
[LICENSES/Locus-original-MIT.txt](LICENSES/Locus-original-MIT.txt). The adapted
worse_query source retains Taj C (forcequit)'s GPL-3.0-or-later notice. All three
license/notice files are included in the app resources.

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records code origins and scope.
Locus retains its own Region/Diagnostics/CoreText architecture and UI. GestaltEdit
was consulted only for its local worse_query integration; no editor, presets,
automation or backup UI was imported.

## Regression checks

```sh
sh Scripts/test-portable.sh  # C sanitizer/Python checks; also Swift when available
sh Scripts/test-swift.sh     # actual pure Swift planner/scanner/coordinator/service
sh Scripts/test-macos.sh     # macOS Objective-C/Mach-O bridge and Swift regressions
```

The Swift suite runs the actual planners, scanner and journal engine with synthetic
fixtures and simulated I/O. If the two local device snapshots exist, an optional
read-only test also checks in-memory edits and exact restore against them; they
are not bundled or published. Native tests exercise checked loaded-image reads
with synthetic Mach-O headers and the actual writer on temporary files.
The macOS suite also checks signing/query/handle behavior with simulated private
APIs. None is an on-device compatibility or functional test.

The Linux review environment ran the portable and Swift suites. macOS native
regressions and unsigned iOS Debug/Release builds require Apple SDKs and are
pending for this revision; no IPA or real-device validation is claimed. The CI
failure analysis and validation limits are recorded in
[the CI regression notes](docs/ci-native-regressions.md).

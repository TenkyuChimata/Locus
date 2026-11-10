# Locus

Locus is a focused iOS/iPadOS region and runtime research utility. It has three
areas:

- **Japan Region** applies one verified, per-device Japan software-region
  profile without changing hardware identity.
- **Diagnostics** compares relevant MobileGestalt runtime/cache answers,
  DeviceTree `/chosen`, iBoot `syscfg-*`, and MobileActivation region sources.
- **CoreText GB18030** provides a binary-validated, process-local rendering experiment
  and restores its temporary cached-byte override before returning.

Locus uses private APIs and is intended only for devices you own or are
authorized to research. It is not affiliated with Apple.

## Compatibility and safety

Capability checks are per feature:

- Read-only Runtime Diagnostics has no global OS-build gate. Individual private
  APIs and backing files may still be unavailable on untested systems.
- Japan Region requires a reviewed question-to-slot mapping identified by
  `CacheUUID`, typed CacheExtra fields, a current cache version, canonical
  boolean/valid bytes, bounded offsets and a verified device profile. The
  inherited `0x1947` layout (`0x0BF0/0x17F6`, `0x0FC8/0x1871`,
  `0x15A8/0x192D`) is retained independently of OS build.
- **No reviewed CacheUUID/descriptor evidence was supplied with the original
  offsets. The schema registry is intentionally empty: Japan Region mutation
  currently refuses all layouts, including on `24A5390f`.** Equal blob length
  or matching boolean answers cannot prove the meaning of an offset. Existing
  Japan-like settings remain visible as unverified. Read-only diagnostics work
  independently. A reviewed schema can be reused across builds without a
  version allowlist; this migration does not claim on-device compatibility.
- CoreText checks the loaded Mach-O UUID before considering any recovered
  address, then requires section, complete memory-range and protection checks.
  **The original source also had no reviewed CoreText binary fingerprint, so
  the experimental override is currently disabled on all binaries.** Its
  read-only probe remains available, and it does not gate other features.
- MobileActivation accepts only the existing unambiguous string-field schema
  with valid country/region codes and UInt32 SoftwareBehaviors semantics. It
  retains inode-preserving writes, read-back verification and exact rollback.

Japan Region mutation is inherently risky. Locus refuses unknown ProductTypes
instead of guessing, uses the real `hw.machine` ProductType to select a verified
Japanese regulatory model, and never writes ProductType, HWModelStr,
HardwarePlatform, CPU identity, or WSKU.

Before either persistent source is changed, Locus stores byte-exact backups of
both MobileGestalt and MobileActivation `region_info.plist`. It preserves the
backing inodes, reads both sources back, verifies every expected value, and
rolls back in reverse order if any stage fails. Backups are internal transaction
artifacts in the app's Documents container; there is intentionally no general
plist editor or arbitrary restore UI.

The CoreText experiment is not a persistent system patch. It initializes the
predicate through normal UIKit/CoreText rendering, temporarily changes only an
already-writable process-local cached byte, saves and restores the original byte
in cleanup, and verifies restoration. It never changes page protection or the
CoreText once token.

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

The GitHub Actions workflow runs host regressions and generic unsigned Debug
and Release device builds,
places `Locus.app` under `Payload`, creates `Locus-unsigned.ipa`, and uploads it
as an artifact.

Do not treat a simulator or host build as validation of private device behavior.
Persistent mutation and CoreText address validation require on-device testing.

## Architecture

- `Region/` — verified ProductType profiles, exact CacheData mutation, Swift
  transaction orchestration, backups, verification, rollback, and UI
- `Diagnostics/` — the compact read-only diagnostics model and UI
- `CoreText/` — loaded-binary CoreText validation/experiment and rendering UI
- `LowLevel/` — focused Objective-C bridges for MobileGestalt,
  MobileActivation, DeviceTree/IOKit, and worse_query
- `Support/` — the retained post-write SpringBoard refresh implementation

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
sh Scripts/test-portable.sh  # actual temporary-directory C tests and static checks
sh Scripts/test-macos.sh    # macOS Foundation/Swift host regressions
```

The macOS suite tests signing/query/handle behavior using simulated private APIs,
the actual plist schema parser and in-place writers using temporary files,
CacheData rejection/bounds, exact backup bytes, and the actual Swift transaction
orchestrator with simulated I/O failures. None is a real-device test. See
[the migration and validation report](docs/worse-query-migration.md) for commits,
file changes, executed checks, outstanding native builds and device limitations.

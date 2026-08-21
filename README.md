# Locus

Locus is a focused iOS/iPadOS region and runtime research utility. It has three
areas:

- **Japan Region** applies one verified, per-device Japan software-region
  profile without changing hardware identity.
- **Diagnostics** compares relevant MobileGestalt runtime/cache answers,
  DeviceTree `/chosen`, iBoot `syscfg-*`, and MobileActivation region sources.
- **CoreText GB18030** runs an exact-build, process-local rendering experiment
  and restores its temporary cached-byte override before returning.

Locus uses private APIs and is intended only for devices you own or are
authorized to research. It is not affiliated with Apple.

## Compatibility and safety

Capability checks are per feature:

- Read-only Runtime Diagnostics has no global OS-build gate. Individual private
  APIs and backing files may still be unavailable on untested systems.
- Japan Region persistent mutation is hard-gated to Darwin build `24A5390f`.
  The `green-tea`, `not-green-tea`, and `wapi` CacheData offsets are used only
  on that exact build and only with the verified `0x1947`-byte layout.
- CoreText GB18030 is hard-gated to `24A5390f`; its recovered CoreText image,
  section, runtime addresses, and current VM protections must all validate.

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
- an iPhone or iPad running the build needed by the feature under test
- Developer Mode and your own signing configuration for device installation

The product and scheme are `Locus`; the default bundle identifier is
`io.github.tenkyuchimata.locus`. No development team is hardcoded. Open
`Locus.xcodeproj`, select your own team (and change the bundle identifier if
your signing account requires it), then build for a physical device.

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

The GitHub Actions workflow performs the same generic unsigned device build,
places `Locus.app` under `Payload`, creates `Locus-unsigned.ipa`, and uploads it
as an artifact.

Do not treat a simulator or host build as validation of private device behavior.
Persistent mutation and CoreText address validation require on-device testing.

## Architecture

- `Region/` — verified ProductType profiles, exact CacheData mutation, Swift
  transaction orchestration, backups, verification, rollback, and UI
- `Diagnostics/` — the compact read-only diagnostics model and UI
- `CoreText/` — exact-build CoreText validation/experiment and rendering UI
- `LowLevel/` — focused Objective-C bridges for MobileGestalt,
  MobileActivation, DeviceTree/IOKit, and bad_query
- `Support/` — the retained post-write SpringBoard refresh implementation

## Licensing and attribution

Locus is distributed under the [MIT License](LICENSE). The prior GestaltEdit
contributor copyright notice is retained because substantial low-level behavior
was refactored rather than clean-room rewritten. Relevant dependency and
research attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
including bad_query and neospring.

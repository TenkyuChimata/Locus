# Third-party notices

Locus is an independent project distributed as a combined work under
**GPL-3.0-only**. [LICENSE](LICENSE) contains the complete GNU GPL v3 text.
The following original grants and attributions remain applicable to their
respective contributions; this does not relicense an upstream project.

## worse_query — Taj C (forcequit)

- Source: [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)
- Reviewed/adapted revision:
  [`d1540e20cd82b974d891e0551ced6d6aeb570ac2`](https://github.com/forcequitOS/worse_query/tree/d1540e20cd82b974d891e0551ced6d6aeb570ac2)
- Copyright (C) 2026 Taj C (forcequit)
- Original source license: **GPL-3.0-or-later** (version 3 or any later version).
  Locus distributes the combined work using version 3. The original copyright,
  license election and warranty disclaimer remain in `WorseQueryBridge.m`.
- `Locus/LowLevel/WorseQueryBridge.m` adapts the upstream class 7 / part 3
  App Group query, both flag variants, symlink-based access and sandbox-token
  consumption/release. It is modified source, not a byte-identical vendor copy.
  Locus adds runtime signing checks, reference-counted leases, serialized
  access, tracked release failures, bounded retry, fixed business-path scope,
  existing-target validation and non-destructive workspace handling.
- `WorseQueryWorkspace.*` is Locus's own implementation. It preserves an
  existing Caches directory by rename, restores its original inode, and
  refuses unowned links or interrupted work. It does not use upstream's
  recursive deletion. Locus's existing bounded fsgetpath/inode discovery helper
  remains independent of the access query; no upstream pathleak source was copied.

## Prior MIT-licensed Locus / GestaltEdit-derived code

The full original repository MIT notice is preserved verbatim in
[LICENSES/Locus-original-MIT.txt](LICENSES/Locus-original-MIT.txt), including:

    Copyright (c) 2026 GestaltEdit contributors
    Copyright (c) 2026 Locus contributors

The original permission and warranty clauses continue to accompany the retained
code. In particular, in-place MobileGestalt writes and the MobileActivation
SystemGroup/inode fallback were already present in Locus before this migration.
The MIT permission permits inclusion in this GPL v3 distribution; it is not
replaced by an assertion of exclusive ownership of those earlier contributions.

## GestaltEdit — limited technical reference

[frs0n/GestaltEdit](https://github.com/frs0n/GestaltEdit) revision
[`d860e9f11541d7aea528ad486af7201901fe7251`](https://github.com/frs0n/GestaltEdit/tree/d860e9f11541d7aea528ad486af7201901fe7251)
was consulted for its worse_query changes: preservation of nonempty Caches,
cleanup limited to an owned symlink, runtime entitlement-based App Group
selection, and directory-scoped MobileGestalt access. No new GestaltEdit GPL
source was copied in this migration. Locus independently implements those
requirements in its existing bridge architecture. In particular, it does not
copy GestaltEdit's Mach-O entitlement parser, generic editor, presets, automation,
models or backup UI. The MIT-era inherited attribution above remains intact.

## GestaltX — scoped descriptor and field reference

- Source: [midori01/GestaltX](https://github.com/midori01/GestaltX), reviewed
  revision [`2ec7e15a9ccf1bcdb1da652561eb9eca476b550d`](https://github.com/midori01/GestaltX/tree/2ec7e15a9ccf1bcdb1da652561eb9eca476b550d)
- Copyright (C) 2026 huamidev
- License: **GPL-3.0-only**; the complete license accompanies Locus in `LICENSE`.
- `MobileGestaltCacheLayout.swift` and `GXMobileGestaltImage.m` informed the
  loaded-image section selection, 64-byte descriptor hypothesis, key-pointer
  comparison and index/type offsets in Locus's `RegionCacheMapping.swift` and
  `MobileGestaltImage.m`. These are modified, scoped implementations, with the
  upstream attribution retained. Locus adds checked Mach VM reads, segment and
  section bounds, separate evidence levels, per-question conflicts and an empty
  independent binary-review registry. It imports no upstream historical profile.
- `DeviceCacheOptions.swift`, `GestaltDocument.swift`, `GestaltManager.swift`,
  `Capabilities.swift` and `tests/DocumentTests.swift` were reviewed for field
  separation, capability-key handling, precise restore and regression cases.
  Locus retains its own region UI, file coordinator, journals and backup format;
  no general editor, preset catalog, model spoofing or application shell is copied.

## SpringBoard refresh research

`Locus/Support/RespringOverlay.swift` is unchanged by this migration. It retains
the existing WebKit refresh technique attributed to
[rooootdev/neospring](https://github.com/rooootdev/neospring), developed by
neonmodder123 and ported to Swift by skadz108. The original Locus MIT notice is
preserved for this pre-existing repository code. The referenced upstream tree
(`3ce9c3e6c580d5ca75d985d58457688e2d14b1ac`) had no separate license file at
review; this notice does not claim a license to copy additional upstream code.
No additional neospring source is imported here.

No new package or runtime-library dependency is added. Apple SDK/system APIs
remain platform dependencies; this repository does not redistribute Apple's
framework binaries. These acknowledgements imply no endorsement or affiliation.

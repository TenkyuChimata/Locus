#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
temporary=$(mktemp -d /tmp/LocusSwiftTests.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
compiler=${SWIFTC:-swiftc}
# These sources contain the actual app planner, layout checks and transaction engine.
# Match the Xcode target's default MainActor isolation as well as Swift 5 mode.
set -- Locus/Region/JapanRegionProfile.swift Locus/Region/JapanRegionCacheLayout.swift \
  Locus/Region/JapanRegionMutation.swift Locus/Region/RegionCacheMapping.swift \
  Locus/Region/RegionModuleMutation.swift Locus/Region/RegionBackupDigest.swift \
  Locus/Region/RegionTransactionCoordinator.swift
"$compiler" -swift-version 5 -default-isolation MainActor -warnings-as-errors -module-cache-path "$temporary/cache" \
  "$@" Tests/Modules/main.swift -o "$temporary/module-tests"
"$temporary/module-tests"
"$compiler" -swift-version 5 -default-isolation MainActor -warnings-as-errors -module-cache-path "$temporary/cache" \
  "$@" Locus/Region/TransactionBackupStore.swift Tests/Layout/main.swift -o "$temporary/layout-tests"
"$temporary/layout-tests"
"$compiler" -swift-version 5 -default-isolation MainActor -warnings-as-errors -module-cache-path "$temporary/cache" \
  "$@" Locus/Region/RegionIdentityService.swift Tests/Transaction/Stubs.swift \
  Tests/Transaction/main.swift -o "$temporary/service-tests"
"$temporary/service-tests"
"$compiler" -swift-version 5 -default-isolation MainActor -warnings-as-errors -module-cache-path "$temporary/cache" \
  "$@" Tests/DeviceSnapshots/main.swift -o "$temporary/snapshot-tests"
if [ -f iPhone17_CHA.plist ] && [ -f iPhoneSE3_JA.plist ]; then
  "$temporary/snapshot-tests" iPhone17_CHA.plist iPhoneSE3_JA.plist
else
  echo 'SKIP: real device snapshot checks; both local plist files are required (snapshot test compilation passed).'
fi

# Exercise actual cache plist writes with the existing production C engine.
clang -std=c17 -D_GNU_SOURCE -Wall -Wextra -Werror -c Locus/LowLevel/InPlaceFileTransaction.c -o "$temporary/in-place.o"
"$compiler" -swift-version 5 -default-isolation MainActor -warnings-as-errors -module-cache-path "$temporary/cache" \
  -import-objc-header Locus/LowLevel/InPlaceFileTransaction.h \
  "$@" Tests/CacheWrites/main.swift "$temporary/in-place.o" -o "$temporary/cache-write-tests"
"$temporary/cache-write-tests"

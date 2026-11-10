#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
temporary=$(mktemp -d /tmp/LocusNativeTests.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
clang -std=c17 -Wall -Wextra -Werror -c Locus/LowLevel/WorseQueryWorkspace.c \
  -o "$temporary/workspace.o"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/NativeAccessTests.m Locus/LowLevel/MobileActivationRegionAccess.m \
  "$temporary/workspace.o" -o "$temporary/access-tests"
"$temporary/access-tests"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/ActivationDiagnosticsTests.m -o "$temporary/activation-diagnostics-tests"
"$temporary/activation-diagnostics-tests"
for activation in 0 1; do
  clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
    -DLOCUS_TEST_ACTIVATION="$activation" -I Locus/LowLevel -framework Foundation \
    Tests/NativeWriteTests.m Locus/LowLevel/WorseQueryBridge.m \
    "$temporary/workspace.o" -o "$temporary/write-tests-$activation"
  "$temporary/write-tests-$activation"
done
swiftc Locus/Region/JapanRegionProfile.swift Locus/Region/JapanRegionCacheLayout.swift \
  Locus/Region/JapanRegionMutation.swift Locus/Region/TransactionBackupStore.swift Tests/Layout/main.swift \
  -o "$temporary/layout-tests"
"$temporary/layout-tests"
swiftc -swift-version 5 Locus/Region/RegionIdentityService.swift \
  Tests/Transaction/Stubs.swift Tests/Transaction/main.swift \
  -o "$temporary/transaction-tests"
"$temporary/transaction-tests"

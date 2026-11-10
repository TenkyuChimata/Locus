#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS Foundation and Apple SDKs are required for native regressions.' >&2; exit 1; }
cd "$(dirname "$0")/.."
temporary=$(mktemp -d /tmp/LocusNativeTests.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
clang -std=c17 -Wall -Wextra -Werror -I Locus/LowLevel \
  -c Locus/LowLevel/ReadOnlyEvidenceFile.c -o "$temporary/evidence-file.o"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation Tests/MobileGestaltEvidenceTests.m \
  "$temporary/evidence-file.o" -o "$temporary/evidence-native-tests"
"$temporary/evidence-native-tests"
clang -std=c17 -Wall -Wextra -Werror -c Locus/LowLevel/WorseQueryWorkspace.c \
  -o "$temporary/workspace.o"
clang -std=c17 -Wall -Wextra -Werror -c Locus/LowLevel/InPlaceFileTransaction.c \
  -o "$temporary/in-place.o"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -c Locus/LowLevel/MobileGestaltImage.m \
  -o "$temporary/image.o"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/NativeAccessTests.m Locus/LowLevel/MobileActivationRegionAccess.m \
  "$temporary/workspace.o" "$temporary/in-place.o" "$temporary/image.o" -o "$temporary/access-tests"
"$temporary/access-tests"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/ActivationDiagnosticsTests.m "$temporary/in-place.o" "$temporary/image.o" \
  -o "$temporary/activation-diagnostics-tests"
"$temporary/activation-diagnostics-tests"
swiftc Locus/Diagnostics/MobileActivationDiagnosticSummary.swift Tests/Diagnostics/main.swift \
  -o "$temporary/diagnostics-summary-tests"
"$temporary/diagnostics-summary-tests"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/NativeWriteTests.m Locus/LowLevel/WorseQueryBridge.m \
  "$temporary/workspace.o" "$temporary/in-place.o" -o "$temporary/write-tests"
"$temporary/write-tests"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation Tests/MobileGestaltImageTests.m \
  -o "$temporary/image-tests"
"$temporary/image-tests"
sh Scripts/test-swift.sh

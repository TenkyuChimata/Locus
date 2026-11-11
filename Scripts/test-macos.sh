#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS Foundation and Apple SDKs are required for native regressions.' >&2; exit 1; }
cd "$(dirname "$0")/.."
temporary=$(mktemp -d /tmp/LocusNativeTests.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
clang -std=c17 -Wall -Wextra -Werror -c Locus/LowLevel/WorseQueryWorkspace.c \
  -o "$temporary/workspace.o"
clang -std=c17 -Wall -Wextra -Werror -c Locus/LowLevel/InPlaceFileTransaction.c \
  -o "$temporary/in-place.o"
clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
  -I Locus/LowLevel -framework Foundation \
  Tests/NativeAccessTests.m "$temporary/workspace.o" "$temporary/in-place.o" -o "$temporary/access-tests"
"$temporary/access-tests"
sh Scripts/test-swift.sh

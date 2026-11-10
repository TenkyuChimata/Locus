#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
temporary=$(mktemp -d /tmp/LocusTests.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
clang -std=c17 -D_GNU_SOURCE -Wall -Wextra -Werror \
  -fsanitize=address,undefined -g -I Locus/LowLevel \
  Locus/LowLevel/WorseQueryWorkspace.c Tests/QueryWorkspaceTests.c \
  -o "$temporary/workspace-tests"
"$temporary/workspace-tests"
clang -std=c17 -D_GNU_SOURCE -Wall -Wextra -Werror \
  -fsanitize=address,undefined -g -I Locus/LowLevel \
  Tests/InPlaceFileTransactionTests.c -o "$temporary/in-place-tests"
"$temporary/in-place-tests"
python3 Tests/check_project.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py'
if command -v "${SWIFTC:-swiftc}" >/dev/null 2>&1; then
  sh Scripts/test-swift.sh
else
  echo 'SKIP: Swift regressions require swiftc; run Scripts/test-swift.sh on a Swift host.'
fi

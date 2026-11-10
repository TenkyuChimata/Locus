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
python3 Tests/check_project.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py'

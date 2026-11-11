#!/bin/sh
# Syntax only: actual iPhoneOS headers, never host headers or a simulated SDK.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'Xcode and the iPhoneOS SDK are required for iOS native syntax checks.' >&2; exit 1; }
cd "$(dirname "$0")/.."
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
test -d "$sdk"
temporary=$(mktemp -d /tmp/LocusIOSNative.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
# Match the app's minimum iOS version and device architecture. No linking or
# -framework arguments belong in this check; xcodebuild still validates links.
set -- -target arm64-apple-ios26.0 -isysroot "$sdk" -fsyntax-only \
    -Wall -Wextra -Werror -I Locus/LowLevel
for source in Locus/LowLevel/*.c; do
    printf 'iPhoneOS arm64 syntax: %s\n' "$source"
    xcrun --sdk iphoneos clang "$@" -std=c17 "$source"
done
for source in Locus/LowLevel/*.m Locus/Locus-Bridging-Header.h; do
    printf 'iPhoneOS arm64 syntax: %s\n' "$source"
    xcrun --sdk iphoneos clang "$@" -x objective-c -fobjc-arc -fblocks -fmodules \
        -fmodules-cache-path="$temporary/modules" -Wno-nullability-completeness "$source"
done

#!/bin/bash
# Shared settings for every build script. Sourced, never run.
#
# Brim builds with plain `swiftc` rather than SwiftPM. On the Mac it was written
# on, the Command Line Tools shipped a `swift-package` that crashes at launch
# (dyld symbol mismatch) and a default SDK built by a newer Swift than the
# installed compiler, so neither `swift build` nor `xcodebuild` could be used.
# Driving `swiftc` directly needs nothing beyond the Command Line Tools.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Brim"
BUNDLE_ID="local.brim.Brim"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="15.0"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${MIN_MACOS}"
BUILD_DIR="${ROOT}/build"
JOBS="$(sysctl -n hw.ncpu)"

# Picks an SDK the installed compiler can actually read. The default one is
# tried first; if it was built by a different Swift (a mixed CLT install), each
# macOS SDK is tried newest-first until a trivial file compiles against it.
# The answer is cached per compiler version.
pick_sdk() {
    if [[ -n "${BRIM_SDK:-}" ]]; then
        echo "$BRIM_SDK"
        return
    fi
    mkdir -p "$BUILD_DIR"
    local compiler cache probe candidate
    compiler="$(swiftc --version 2>&1 | head -1)"
    cache="${BUILD_DIR}/.sdk-cache"
    if [[ -f "$cache" ]] && [[ "$(head -1 "$cache")" == "$compiler" ]]; then
        tail -1 "$cache"
        return
    fi
    probe="$(mktemp -d)"
    printf 'import Foundation\nprint(Date())\n' > "${probe}/probe.swift"
    local candidates=()
    candidates+=("$(xcrun --show-sdk-path 2>/dev/null || true)")
    local dev
    dev="$(xcode-select -p 2>/dev/null || true)"
    for dir in "${dev}/SDKs" "${dev}/Platforms/MacOSX.platform/Developer/SDKs"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r sdk; do candidates+=("$sdk"); done < <(ls -d "$dir"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV)
        fi
    done
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" || ! -d "$candidate" ]] && continue
        if swiftc -sdk "$candidate" -target "$TARGET" -typecheck "${probe}/probe.swift" >/dev/null 2>&1; then
            printf '%s\n%s\n' "$compiler" "$candidate" > "$cache"
            rm -rf "$probe"
            echo "$candidate"
            return
        fi
    done
    rm -rf "$probe"
    echo "error: no macOS SDK compatible with: ${compiler}" >&2
    exit 1
}

# Every .swift file under a directory, in a stable order.
sources_in() {
    find "$1" -name '*.swift' -type f | LC_ALL=C sort
}

#!/bin/bash
# Compiles BrimCore and BrimUI for testing, links the test suites against them
# and runs the result. Arguments are passed to the runner as name filters, e.g.
#   scripts/test.sh ResetCopy Threshold
#
# Tests use the small harness in Tests/TestKit instead of XCTest or Swift
# Testing: the Command Line Tools on the development Mac ship neither in a
# working state (see scripts/common.sh), and the harness needs nothing but the
# compiler.
source "$(dirname "$0")/common.sh"

SDK="$(pick_sdk)"
OUT="${BUILD_DIR}/test"
MODULES="${OUT}/modules"
mkdir -p "$MODULES"
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -Onone -g -j "$JOBS")

build_module() {
    local name="$1"; shift
    echo "==> ${name} (testable)"
    swiftc "${COMMON[@]}" -parse-as-library -enable-testing \
        -module-name "$name" -I "$MODULES" \
        -emit-module -emit-module-path "${MODULES}/${name}.swiftmodule" \
        -emit-library -static -o "${OUT}/lib${name}.a" "$@"
}

# shellcheck disable=SC2046
build_module BrimCore $(sources_in "${ROOT}/Sources/BrimCore")
LIBS=(-lBrimCore)
if [[ -n "$(sources_in "${ROOT}/Sources/BrimUI")" ]]; then
    # shellcheck disable=SC2046
    build_module BrimUI $(sources_in "${ROOT}/Sources/BrimUI")
    LIBS=(-lBrimUI -lBrimCore)
fi

echo "==> test runner"
# shellcheck disable=SC2046
swiftc "${COMMON[@]}" -module-name BrimTests -I "$MODULES" -L "$OUT" "${LIBS[@]}" \
    $(sources_in "${ROOT}/Tests/TestKit") \
    $(sources_in "${ROOT}/Tests/BrimCoreTests") \
    $(sources_in "${ROOT}/Tests/BrimUITests") \
    "${ROOT}/Tests/main.swift" \
    -o "${OUT}/brim-tests"

echo "==> running"
BRIM_FIXTURES="${ROOT}/Tests/Fixtures" "${OUT}/brim-tests" "$@"

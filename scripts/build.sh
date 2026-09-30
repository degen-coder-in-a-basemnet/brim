#!/bin/bash
# Builds build/Brim.app. CONFIG=debug for an unoptimised build.
source "$(dirname "$0")/common.sh"

CONFIG="${CONFIG:-release}"
SDK="$(pick_sdk)"
OUT="${BUILD_DIR}/${CONFIG}"
MODULES="${OUT}/modules"
mkdir -p "$MODULES"

if [[ "$CONFIG" == "release" ]]; then
    OPT=(-O -wmo -num-threads "$JOBS")
else
    OPT=(-Onone -g -enable-testing -j "$JOBS")
fi

COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -parse-as-library)

compile_module() {
    local name="$1"; shift
    echo "==> ${name} (${CONFIG})"
    # shellcheck disable=SC2046
    swiftc "${COMMON[@]}" "${OPT[@]}" \
        -module-name "$name" \
        -I "$MODULES" \
        -emit-module -emit-module-path "${MODULES}/${name}.swiftmodule" \
        -emit-library -static -o "${OUT}/lib${name}.a" \
        "$@"
}

# shellcheck disable=SC2046
compile_module BrimCore $(sources_in "${ROOT}/Sources/BrimCore")
# shellcheck disable=SC2046
compile_module BrimUI $(sources_in "${ROOT}/Sources/BrimUI")

echo "==> ${APP_NAME} executable"
swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 "${OPT[@]}" \
    -I "$MODULES" -L "$OUT" -lBrimUI -lBrimCore \
    "${ROOT}/Sources/Brim/main.swift" -o "${OUT}/${APP_NAME}"

APP="${BUILD_DIR}/${APP_NAME}.app"
echo "==> bundling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${OUT}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
sed -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    -e "s/__MIN_MACOS__/${MIN_MACOS}/g" \
    -e "s/__NAME__/${APP_NAME}/g" \
    "${ROOT}/Resources/Info.plist" > "${APP}/Contents/Info.plist"
if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi
cp "${ROOT}/THIRD_PARTY_NOTICES.md" "${APP}/Contents/Resources/" 2>/dev/null || true

# Ad-hoc signature: local only, no developer identity, no entitlements, no
# sandbox exceptions requested. Enough for macOS to run it and to grant it
# notification permission.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" >/dev/null
echo "==> built $(du -sh "$APP" | cut -f1) ${APP}"

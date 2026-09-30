#!/bin/bash
# Watches the running Brim's sockets and fails on any that is not loopback.
# With the default settings there should be none at all.
# Usage: scripts/netcheck.sh [seconds]   (launches the build if Brim isn't running)
source "$(dirname "$0")/common.sh"

WATCH="${1:-20}"
pid="$(pgrep -x "$APP_NAME" | head -1 || true)"
if [[ -z "$pid" ]]; then
    open "${BUILD_DIR}/${APP_NAME}.app"
    for _ in $(seq 1 20); do
        pid="$(pgrep -x "$APP_NAME" | head -1 || true)"
        [[ -n "$pid" ]] && break
        sleep 0.5
    done
fi
if [[ -z "$pid" ]]; then
    echo "Brim is not running."
    exit 1
fi

echo "==> Watching ${APP_NAME} (pid ${pid}) for ${WATCH}s"
sockets=0
remote=0
for _ in $(seq 1 "$WATCH"); do
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        sockets=$((sockets + 1))
        echo "  $line"
        if ! grep -qE '127\.0\.0\.1|\[::1\]' <<< "$line"; then remote=$((remote + 1)); fi
    done < <(lsof -nP -a -p "$pid" -i 2>/dev/null | tail -n +2)
    sleep 1
done

if (( remote )); then
    echo "FAIL: ${remote} socket sample(s) reached beyond this Mac."
    exit 1
elif (( sockets )); then
    echo "ok: ${sockets} socket sample(s), all loopback (Ollama or LM Studio switched on)."
else
    echo "ok: no sockets opened."
fi

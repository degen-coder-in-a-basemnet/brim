#!/bin/bash
# Removes Brim and everything it wrote. Nothing of Claude Code's, Codex's,
# Ollama's or LM Studio's is touched: Brim only ever read those.
set -euo pipefail

BUNDLE_ID="local.brim.Brim"
pkill -x Brim 2>/dev/null || true

remove() {
    if [[ -e "$1" ]]; then
        rm -rf "$1"
        echo "removed $1"
    fi
}

remove "$HOME/Applications/Brim.app"
remove "/Applications/Brim.app"
remove "$HOME/Library/Application Support/Brim"                     # settings, cached readings
remove "$HOME/Library/Preferences/${BUNDLE_ID}.plist"               # Settings window position
remove "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
remove "$HOME/Library/Caches/${BUNDLE_ID}"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Brim is gone. A source checkout and its build folder are left where they are."
echo "If you allowed notifications, macOS drops that entry by itself once the app is gone."

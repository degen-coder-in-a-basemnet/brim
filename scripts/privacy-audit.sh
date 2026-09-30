#!/bin/bash
# Checks the promises in docs/PRIVACY.md against the source and the built app.
# Prints locations only, never file contents. Exits non-zero on any breach.
source "$(dirname "$0")/common.sh"
cd "$ROOT"

APP="${BUILD_DIR}/${APP_NAME}.app"
BINARY="${APP}/Contents/MacOS/${APP_NAME}"
failures=0

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# Every file under Sources matching `pattern` must be one of the allowed files.
confined() {
    local what="$1" pattern="$2"; shift 2
    local found stray=()
    found="$(grep -rlE "$pattern" Sources || true)"
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local allowed=false
        for keep in "$@"; do [[ "$file" == "$keep" ]] && allowed=true; done
        $allowed || stray+=("$file")
    done <<< "$found"
    if (( ${#stray[@]} )); then
        fail "$what outside ${*:-nowhere}: ${stray[*]}"
    else
        ok "$what: ${*:-none anywhere}"
    fi
}

echo "==> Source"
confined "Network APIs" \
    'URLSession|URLRequest|NSURLConnection|NWConnection|NWPathMonitor|import Network|CFSocket|CFStream|WKWebView|SCNetworkReachability' \
    Sources/BrimCore/Networking/LoopbackHTTPClient.swift Sources/BrimCore/Networking/AnthropicUsageClient.swift
confined "Subprocesses" \
    'Process\(|NSTask|posix_spawn|popen\(|(^|[^A-Za-z.])system\(|execv' \
    Sources/BrimCore/Security/ProcessRunner.swift
confined "Keychain and credential APIs" \
    'SecItem|SecKeychain|kSecClass|SecAccessControl|import Security|LocalAuthentication|ASWebAuthentication' \
    Sources/BrimCore/Security/ClaudeKeychain.swift
if grep -rqE 'SecItemAdd|SecItemUpdate|SecItemDelete|SecKeychainAdd|SecKeychainItemModify|SecKeychainItemDelete|SecAccessCreate|SecKeychainSetUserInteractionAllowed|usr/bin/security|(let|var) refreshToken|grant_type|/oauth/token' Sources; then
    fail "the keychain is written, renewed or read around macOS's prompt somewhere"
else
    ok "Keychain use is read-only, never renews a sign-in, never goes around macOS's prompt"
fi
confined "Logging" \
    '\b(print|NSLog|os_log|debugPrint|dump)\(|Logger\(' \
    Sources/BrimCore/Security/SafeLog.swift Sources/BrimUI/App/SnapshotRenderer.swift
confined "Opening URLs or apps" \
    'NSWorkspace\.shared\.open' \
    Sources/BrimUI/App/AppController.swift Sources/BrimUI/Settings/ProvidersPane.swift Sources/BrimUI/App/SessionFocus.swift
confined "Apple Events (selecting a clicked session's terminal tab)" \
    'NSAppleScript|NSAppleEventDescriptor|AEDeterminePermissionToAutomateTarget|AESendMessage|osascript|SBApplication' \
    Sources/BrimUI/App/SessionFocus.swift
confined "Other processes' open files (Codex session process ids)" \
    'proc_pidfdinfo|PROC_PIDLISTFDS|proc_listallpids' \
    Sources/BrimCore/Providers/Codex/CodexProcessFinder.swift
if grep -qE 'contents of|history of|text of' Sources/BrimUI/App/SessionFocus.swift; then
    fail "a terminal script reads a tab's contents"
else
    ok "Terminal scripts read each tab's device name only"
fi
confined "Analytics, crash reporting or update frameworks" \
    'Sparkle|Firebase|Sentry|Crashlytics|Mixpanel|Amplitude|Segment|TelemetryDeck|PostHog|AppCenter'

# Every URL literal in the source must be one of these.
allowed_urls=(
    "http://127.0.0.1"                        # Ollama and LM Studio, loopback only
    "https://claude.ai/settings/usage"        # opened in the browser on request
    "https://chatgpt.com/codex/settings/usage"
    "https://github.com/vinzdg/codenotch"     # attribution comments
    "https://api.anthropic.com/api/oauth/usage"  # opt-in keychain fallback only
)
url_ok() {
    local url="$1"
    for allowed in "${allowed_urls[@]}"; do [[ "$url" == "$allowed"* ]] && return 0; done
    return 1
}
unknown=()
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    url_ok "$url" || unknown+=("$url")
done < <(grep -rhoE 'https?://[A-Za-z0-9._~:/?#@!$&+,;=%-]+' Sources | sort -u)
if (( ${#unknown[@]} )); then
    fail "URL literals not on the allowlist: ${unknown[*]}"
else
    ok "URL literals: only the allowlisted ones"
fi

remote=Sources/BrimCore/Networking/AnthropicUsageClient.swift
if [[ "$(grep -oE 'https://[^"]+' "$remote" | sort -u)" == "https://api.anthropic.com/api/oauth/usage" ]] \
   && grep -q 'completionHandler(nil)' "$remote"; then
    ok "The one remote client is pinned to Anthropic's usage endpoint and follows no redirects"
else
    fail "The remote client is not pinned to https://api.anthropic.com/api/oauth/usage"
fi

client=Sources/BrimCore/Networking/LoopbackHTTPClient.swift
if grep -qE 'static let host = "127\.0\.0\.1"' "$client" && grep -q 'components.host = host' "$client" \
   && [[ "$(grep -c 'components.host' "$client")" == 1 ]]; then
    ok "The HTTP client is pinned to 127.0.0.1"
else
    fail "The HTTP client is not pinned to 127.0.0.1"
fi

echo "==> Built app"
if [[ ! -x "$BINARY" ]]; then
    fail "no build at ${APP} (run scripts/build.sh first)"
else
    binary_unknown=()
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        url_ok "$url" || binary_unknown+=("$url")
    done < <(strings -a "$BINARY" | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&+,;=%-]+' | sort -u)
    if (( ${#binary_unknown[@]} )); then
        fail "URLs in the binary not on the allowlist: ${binary_unknown[*]}"
    else
        ok "URLs in the binary: only the allowlisted ones"
    fi

    if otool -L "$BINARY" | grep -qE 'Sparkle|WebKit'; then
        fail "links a framework it should not: $(otool -L "$BINARY" | grep -oE '(Sparkle|WebKit)\.framework' | sort -u | tr '\n' ' ')"
    else
        ok "Linked frameworks: no WebKit or update framework"
    fi

    security_calls="$(nm -u "$BINARY" 2>/dev/null | grep -oE '_Sec[A-Z][A-Za-z]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [[ -z "$security_calls" || "$security_calls" == "_SecItemCopyMatching" ]]; then
        ok "Keychain functions the binary can call: ${security_calls:-none} (read only)"
    else
        fail "the binary can call keychain functions beyond reading: ${security_calls}"
    fi

    entitlements="$(codesign -d --entitlements - "$APP" 2>/dev/null | grep -oE '<key>[^<]+</key>' || true)"
    if [[ -z "$entitlements" ]]; then
        ok "Entitlements: none"
    else
        fail "unexpected entitlements: ${entitlements}"
    fi
fi

echo
if (( failures )); then
    echo "Privacy audit: ${failures} problem(s)."
    exit 1
fi
echo "Privacy audit passed."

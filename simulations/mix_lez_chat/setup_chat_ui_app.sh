#!/usr/bin/env bash
# Stage a writable copy of logos-chat-ui-app with all the modules needed for
# mix+RLN+gifter operation: wallet (logos_execution_zone), RLN module, and
# the standard chat_module + capability_module. Launch path printed at end.
#
# Pair this with `SIM_INFRA_ONLY=1 bash simulations/mix_lez_chat/run_simulation_lgx.sh`
# in another terminal: the sim brings up sequencer + 4 mix nodes + receiver,
# prints the env vars + intro bundle this GUI needs, then polls until it
# sees the message you send from the GUI arrive at the receiver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEZ_RLN_DIR="$SCRIPT_DIR/../../vendor/logos-lez-rln"

# Auto-resolve the chat-ui-app's nix-store path if no override is supplied.
if [ -z "${APP_NIX:-}" ]; then
    APP_NIX=$(nix build github:logos-co/logos-chat-ui-app --no-link --print-out-paths 2>/dev/null) \
        || { echo "FATAL: failed to nix build logos-chat-ui-app; set APP_NIX manually" >&2; exit 1; }
fi

# Build wallet/RLN .lgx with the same override chain the sim uses (see
# run_simulation_lgx.sh `lgx_from`). The wallet override pulls in lssa's
# `SequencerClientBuilder::request_timeout(...)`; without it, a slow
# sequencer hangs the wallet's Qt thread and libp2p stops accepting dials.
#
# Trailing args flow through to `nix bundle` (e.g. --override-input).
resolve_lgx() {
    local attr="$1"; shift
    local out_link lgx
    out_link=$(mktemp -d)/result
    (cd "$LEZ_RLN_DIR" && nix bundle --bundler github:logos-co/nix-bundle-lgx \
        "$@" --out-link "$out_link" ".#$attr" >/dev/null) \
        || { echo "FATAL: failed to nix bundle $attr" >&2; exit 1; }
    lgx=$(find "$(readlink "$out_link")" -maxdepth 1 -name "*.lgx" | head -1)
    rm -f "$out_link"; rmdir "$(dirname "$out_link")" 2>/dev/null || true
    [ -f "$lgx" ] || { echo "FATAL: no .lgx in $attr bundle output" >&2; exit 1; }
    printf '%s' "$lgx"
}

if [ -z "${WALLET_LGX:-}" ]; then
    WALLET_LGX=$(resolve_lgx "wallet-module" \
        --override-input logos-wallet-module "path:$LEZ_RLN_DIR/logos-execution-zone-module" \
        --override-input logos-wallet-module/logos-execution-zone "path:$LEZ_RLN_DIR/lssa")
fi

if [ -z "${RLN_LGX:-}" ]; then
    RLN_LGX=$(resolve_lgx "logos-rln-module")
fi

echo "Using:"
echo "  APP_NIX     = $APP_NIX"
echo "  WALLET_LGX  = $WALLET_LGX"
echo "  RLN_LGX     = $RLN_LGX"

APP_ROOT=${APP_ROOT:-/tmp/chat_ui_app_staged}
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/bin" "$APP_ROOT/modules" "$APP_ROOT/lib"

# Copy (not symlink): applicationDirPath() resolves through realpath, so a
# symlinked bin would point back into /nix/store and miss the extra modules
# staged under $APP_ROOT/modules.
# `cp -a "$APP_NIX"/bin/.` (note the trailing dot) is required to grab the
# `.logos-chat-ui-app-wrapped` dotfile — the actual Mach-O the launcher
# execs into. Plain `cp $APP_NIX/bin/*` silently skips it.
cp -a "$APP_NIX"/bin/. "$APP_ROOT/bin/"
[ -d "$APP_NIX"/lib ] && cp -R "$APP_NIX"/lib/* "$APP_ROOT/lib/" 2>/dev/null || true
chmod -R +w "$APP_ROOT/bin/" 2>/dev/null || true
# The launcher hardcodes an absolute /nix/store path to its wrapped Mach-O.
# Rewrite it in-place to point at $APP_ROOT so applicationDirPath() resolves
# under the staging dir. Pad with trailing NULs to preserve the cstring's
# section size — avoids rewriting load commands.
OLD_PATH="$APP_NIX/bin/.logos-chat-ui-app-wrapped"
NEW_PATH="$APP_ROOT/bin/.logos-chat-ui-app-wrapped"
python3 - <<PYEOF
import sys, re
old=$(printf '%s' "$OLD_PATH" | python3 -c 'import sys; print(repr(sys.stdin.read()))')
new=$(printf '%s' "$NEW_PATH" | python3 -c 'import sys; print(repr(sys.stdin.read()))')
old_b = old.encode()
new_b = new.encode()
if len(new_b) > len(old_b):
    print(f"FATAL: new path ({len(new_b)}) longer than old ({len(old_b)})", file=sys.stderr)
    sys.exit(1)
new_b_padded = new_b + b'\x00' * (len(old_b) - len(new_b))
with open("$APP_ROOT/bin/logos-chat-ui-app", "rb") as f:
    data = f.read()
if old_b not in data:
    print(f"WARN: old path {old_b!r} not found in wrapper binary", file=sys.stderr)
    sys.exit(0)
data = data.replace(old_b, new_b_padded)
with open("$APP_ROOT/bin/logos-chat-ui-app", "wb") as f:
    f.write(data)
print(f"Patched wrapper: $OLD_PATH -> $NEW_PATH (padded {len(old_b) - len(new_b)} bytes)")
PYEOF
codesign --force --sign - "$APP_ROOT/bin/logos-chat-ui-app" 2>/dev/null || true

# Copy chat-related modules from the nix output (writable so we can co-locate libs)
cp "$APP_NIX"/modules/*.dylib "$APP_ROOT/modules/"
# Also copy chat_ui.dylib (lives at app root, not in modules/)
cp "$APP_NIX"/chat_ui.dylib "$APP_ROOT/" 2>/dev/null || true

# Extract wallet (logos_execution_zone) module + its libwallet_ffi sidecar
WTMP=$(mktemp -d)
tar -xzf "$WALLET_LGX" -C "$WTMP"
cp "$WTMP"/variants/darwin-arm64-dev/*.dylib "$APP_ROOT/modules/"

# Extract RLN module + its liblez_rln_ffi sidecar
RTMP=$(mktemp -d)
tar -xzf "$RLN_LGX" -C "$RTMP"
cp "$RTMP"/variants/darwin-arm64-dev/*.dylib "$APP_ROOT/modules/"

echo "Staged at: $APP_ROOT"
echo "Modules:"
ls -la "$APP_ROOT/modules/"
echo
echo "Launch with the mix+gifter env vars (printed by start_mix_infra.sh):"
echo "  $APP_ROOT/bin/logos-chat-ui-app"

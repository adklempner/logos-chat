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

# Build the wallet (logos-execution-zone) .lgx the SAME WAY the sim does so
# the GUI shares the sim's exact behaviour — most importantly, the
# `.request_timeout(120s)` patch in lssa/wallet/src/lib.rs (without it,
# send_public_transaction on testnet hangs the wallet's Qt thread forever
# the first time the sequencer is slow → libp2p stops accepting dials →
# every chat client gets "gifter dial failed"). See memory note
# project_testnet_http_timeout_root_cause.md for context.
if [ -z "${WALLET_LGX:-}" ]; then
    out_link=$(mktemp -d)/result
    (cd "$LEZ_RLN_DIR" && nix bundle --bundler github:logos-co/nix-bundle-lgx \
        --override-input logos-wallet-module "path:$LEZ_RLN_DIR/logos-execution-zone-module" \
        --override-input logos-wallet-module/logos-execution-zone "path:$LEZ_RLN_DIR/lssa" \
        --out-link "$out_link" ".#wallet-module" >/dev/null) \
        || { echo "FATAL: failed to nix bundle wallet-module" >&2; exit 1; }
    WALLET_LGX=$(find "$(readlink "$out_link")" -maxdepth 1 -name "*.lgx" | head -1)
    rm -f "$out_link"; rmdir "$(dirname "$out_link")" 2>/dev/null || true
    [ -f "$WALLET_LGX" ] || { echo "FATAL: no .lgx in wallet-module bundle output" >&2; exit 1; }
fi

if [ -z "${RLN_LGX:-}" ]; then
    out_link=$(mktemp -d)/result
    (cd "$LEZ_RLN_DIR" && nix bundle --bundler github:logos-co/nix-bundle-lgx \
        --out-link "$out_link" ".#logos-rln-module" >/dev/null) \
        || { echo "FATAL: failed to nix bundle logos-rln-module" >&2; exit 1; }
    RLN_LGX=$(find "$(readlink "$out_link")" -maxdepth 1 -name "*.lgx" | head -1)
    rm -f "$out_link"; rmdir "$(dirname "$out_link")" 2>/dev/null || true
    [ -f "$RLN_LGX" ] || { echo "FATAL: no .lgx in logos-rln-module bundle output" >&2; exit 1; }
fi

echo "Using:"
echo "  APP_NIX     = $APP_NIX"
echo "  WALLET_LGX  = $WALLET_LGX"
echo "  RLN_LGX     = $RLN_LGX"

APP_ROOT=${APP_ROOT:-/tmp/chat_ui_app_staged}
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/bin" "$APP_ROOT/modules" "$APP_ROOT/lib"

# COPY (not symlink) the bin AND the nix-wrapper dotfile binaries so
# applicationDirPath() resolves to APP_ROOT/bin instead of the nix store
# path. With symlinks the realpath() resolves into /nix/store/... and our
# extra wallet+RLN modules (staged in APP_ROOT/modules) are invisible.
# IMPORTANT: cp $APP_NIX/bin/* misses dotfiles (.logos-chat-ui-app-wrapped
# is the actual Mach-O the launcher execs into); use `cp -a` with explicit
# dotfile glob to grab them too.
cp -a "$APP_NIX"/bin/. "$APP_ROOT/bin/"
[ -d "$APP_NIX"/lib ] && cp -R "$APP_NIX"/lib/* "$APP_ROOT/lib/" 2>/dev/null || true
chmod -R +w "$APP_ROOT/bin/" 2>/dev/null || true
# The launcher (bin/logos-chat-ui-app, a small Mach-O env-setter wrapper)
# hardcodes an absolute /nix/store path to its wrapped binary. Patch it
# in-place so it execs OUR copy under APP_ROOT/bin instead — that way
# applicationDirPath() resolves to APP_ROOT and our wallet+RLN modules in
# APP_ROOT/modules are discoverable.
OLD_PATH="$APP_NIX/bin/.logos-chat-ui-app-wrapped"
NEW_PATH="$APP_ROOT/bin/.logos-chat-ui-app-wrapped"
# Pad NEW_PATH to OLD_PATH length with trailing NULs so the Mach-O cstring
# section keeps its size (simple in-place patch — no need to rebuild
# load commands).
python3 - <<PYEOF
import sys, re
old=$(printf '%s' "$OLD_PATH" | python3 -c 'import sys; print(repr(sys.stdin.read()))')
new=$(printf '%s' "$NEW_PATH" | python3 -c 'import sys; print(repr(sys.stdin.read()))')
old_b = old.encode()
new_b = new.encode()
if len(new_b) > len(old_b):
    print(f"FATAL: new path ({len(new_b)}) longer than old ({len(old_b)})", file=sys.stderr)
    sys.exit(1)
# Pad with NULs
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

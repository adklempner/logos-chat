#!/usr/bin/env bash
# One-shot: fresh logos-chat clone -> running the testnet acceptance sim.
# Run from the root of a logos-chat clone (branch port/sim-config-v3):
#   bash simulations/mix_lez_chat/bootstrap.sh
# Idempotent — re-run to skip finished steps. Codifies README.md §2-6 (the
# testnet path; no local sequencer / lssa / spel / guest ELFs needed).
set -euo pipefail

CHAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$CHAT_DIR"
LEZ="$CHAT_DIR/vendor/logos-lez-rln"
say() { printf '\n=== %s ===\n' "$*"; }

# 1. git wrapper for nimble (git >= 2.51 rejects `git -C <missing-dir> init`)
if [ ! -x "$HOME/.local/bin/git-wrapper/git" ]; then
    say "installing nimble git wrapper"
    mkdir -p "$HOME/.local/bin/git-wrapper"
    _realgit="$(command -v git)"
    cat > "$HOME/.local/bin/git-wrapper/git" <<EOF
#!/bin/bash
args=("\$@")
for i in "\${!args[@]}"; do
    if [ "\${args[\$i]}" = "-C" ] && [ -n "\${args[\$i+1]:-}" ]; then
        [ ! -d "\${args[\$i+1]}" ] && mkdir -p "\${args[\$i+1]}" 2>/dev/null || true
        break
    fi
done
exec "$_realgit" "\$@"
EOF
    chmod +x "$HOME/.local/bin/git-wrapper/git"
fi
export PATH="$HOME/.local/bin/git-wrapper:$PATH"
export TMPDIR=/tmp

# 2. sibling + nested clones (correct branches — see README §2)
clone() { [ -d "$2/.git" ] || git clone -b "$3" "$1" "$2"; }
say "cloning repos"
clone git@github.com:adklempner/logos-chat-module.git "$CHAT_DIR/../logos-chat-module" rebase/on-upstream-2026-07-08
[ -f logos_chat.nims ] || make update
clone git@github.com:adklempner/logos-delivery-module.git "$LEZ/logos-delivery-module" handoff/on-delivery-config-v3
for d in "$LEZ/logos-delivery-module/vendor/logos-delivery" "$LEZ/logos-delivery"; do
    [ -d "$d/.git" ] || git clone -b port/lez-mix-on-config-v3 --recurse-submodules \
        git@github.com:adklempner/logos-delivery.git "$d"
done

# 3. delivery library (the nested clone is the one the sim loads)
say "building liblogosdelivery (~7 min cold)"
DELIVERY_SRC="$LEZ/logos-delivery-module/vendor/logos-delivery"
[ -f "$DELIVERY_SRC/build/liblogosdelivery.dylib" ] || \
    ( cd "$DELIVERY_SRC" && make -j4 liblogosdelivery )

# 4. module plugins (nix)
say "building module plugins (nix)"
CHAT_PLUGIN=$(cd "$CHAT_DIR/../logos-chat-module" && \
    nix build .#default --print-out-paths --no-link)/lib/chat_module_plugin.dylib
DELIVERY_PLUGIN=$(cd "$LEZ/logos-delivery-module" && \
    nix build .#lib --print-out-paths --no-link)/lib/delivery_module_plugin.dylib

# 5. run the testnet acceptance gate
say "running the testnet sim (faucet-funded; ~20-25 min)"
CHAT_PLUGIN_OVERRIDE="$CHAT_PLUGIN" \
DELIVERY_PLUGIN_OVERRIDE="$DELIVERY_PLUGIN" \
DELIVERY_DYLIB_OVERRIDE="$DELIVERY_SRC/build/liblogosdelivery.dylib" \
SIM_NETWORK=testnet SIM_NODE_STARTUP_SLEEP=45 SIM_NPC_RETRIES=2 \
    exec bash "$CHAT_DIR/simulations/mix_lez_chat/run_simulation_lgx.sh" --fresh

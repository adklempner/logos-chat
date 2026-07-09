# mix_lez_chat sim — quickstart from fresh clone

End-to-end mix + LEZ RLN spam-protected chat simulation. `SIM_NETWORK=local` runs against a locally-built sequencer; `SIM_NETWORK=testnet` runs against a shared LEZ RLN deployment on the testnet.

Verified 15/15 PASS on both `SIM_NETWORK=local` and `SIM_NETWORK=testnet` (`TESTNET_RPC_URL=http://lez-node.local:3040/`) on 2026-07-08.

## Prerequisites

- macOS (Darwin/arm64 tested) or Linux
- `nix` (flake commands used)
- `git` (2.51+; nimble tmp-dir wrapper needed — see below)
- `cargo` (nightly OK; for sequencer + lez-rln binaries)
- `cmake` (for `logos-delivery-module` plugin — nix path handles it)

## 1. Clone the repos

Three sibling directories, all on `adklempner/*` forks:

```bash
mkdir -p ~/Waku/Logos && cd ~/Waku/Logos
git clone -b rebase/sim-rln-gifter-on-new-stack \
    git@github.com:adklempner/logos-chat.git
git clone -b rebase/on-upstream-2026-07-08 \
    git@github.com:adklempner/logos-chat-module.git
```

Then hydrate `logos-chat`'s submodules:

```bash
cd logos-chat
make update  # inits vendor/logos-lez-rln, vendor/nwaku
```

`logos-lez-rln` doesn't track its inner `logos-delivery-module` or `logos-delivery` dirs. Add them manually:

```bash
LEZ_DIR=vendor/logos-lez-rln
git clone -b rebase/on-upstream-2026-07-08 \
    git@github.com:adklempner/logos-delivery-module.git \
    $LEZ_DIR/logos-delivery-module

git clone -b rebase/add-mix-rln-spam-plugin-submodule --recurse-submodules \
    git@github.com:adklempner/logos-delivery.git \
    $LEZ_DIR/logos-delivery-module/vendor/logos-delivery
# also: same-repo second checkout for the nix flake path
git clone -b rebase/add-mix-rln-spam-plugin-submodule --recurse-submodules \
    git@github.com:adklempner/logos-delivery.git \
    $LEZ_DIR/logos-delivery
```

## 2. Git wrapper for nimble (macOS/git 2.51+)

Nimble runs `git -C <path-with-#> init` where the dir doesn't exist yet; on git ≥2.51 this fails. Install a wrapper that mkdir's the `-C` arg before invoking real git:

```bash
mkdir -p ~/.local/bin/git-wrapper
cat > ~/.local/bin/git-wrapper/git <<'EOF'
#!/bin/bash
args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "-C" ] && [ -n "${args[$i+1]:-}" ]; then
        [ ! -d "${args[$i+1]}" ] && mkdir -p "${args[$i+1]}" 2>/dev/null || true
        break
    fi
done
exec /opt/homebrew/bin/git "$@"   # or /usr/bin/git on Linux
EOF
chmod +x ~/.local/bin/git-wrapper/git
```

Prepend to PATH when running the sim (see step 5).

## 3. Build the delivery library (~7 min cold, ~1 min incremental)

```bash
cd ~/Waku/Logos/logos-chat/vendor/logos-lez-rln/logos-delivery
PATH="$HOME/.local/bin/git-wrapper:$PATH" TMPDIR=/tmp make -j4 liblogosdelivery
```

If nimble complains about missing `sds/types`, sed the `nimble.paths`:

```bash
sed -i.bak 's|/sds-0.3.0-[a-f0-9]*/sds"|/sds-0.3.0-XXX"|' nimble.paths
# replace XXX with the actual sha1 from the same line
```

(Root cause: nimble regenerates this path with a `/sds` suffix pointing at a non-existent subdir. Filed as a workaround; delivery's Makefile could sed it post-setup.)

Result: `build/liblogosdelivery.dylib` (43 MB), statically-linked librln.

## 4. Build the plugin bundles via nix

Chat module + delivery module — both as `.dylib` plugins:

```bash
# chat_module (2-3 min cold)
cd ~/Waku/Logos/logos-chat-module
nix build .#default --print-out-paths
# → /nix/store/<hash>-logos-chat_module-module/lib/chat_module_plugin.dylib

# delivery_module (5-10 min cold if zerokit + nim deps not cached)
cd ~/Waku/Logos/logos-chat/vendor/logos-lez-rln/logos-delivery-module
nix build .#lib --print-out-paths
# → /nix/store/<hash>-logos-delivery_module-module-lib-0.1.2/lib/delivery_module_plugin.dylib
```

## 5. Run the sim

```bash
cd ~/Waku/Logos/logos-chat

# Override plugin paths (use nix output paths from step 4)
export CHAT_PLUGIN_OVERRIDE=$(nix eval --raw \
    ~/Waku/Logos/logos-chat-module#default.outPath)/lib/chat_module_plugin.dylib
export DELIVERY_PLUGIN_OVERRIDE=$(nix eval --raw \
    ./vendor/logos-lez-rln/logos-delivery-module#lib.outPath)/lib/delivery_module_plugin.dylib
export DELIVERY_DYLIB_OVERRIDE=$(pwd)/vendor/logos-lez-rln/logos-delivery/build/liblogosdelivery.dylib

# Local (default)
SIM_NETWORK=local SIM_NODE_STARTUP_SLEEP=45 SIM_NPC_RETRIES=1 \
    PATH="$HOME/.local/bin/git-wrapper:$PATH" TMPDIR=/tmp \
    bash simulations/mix_lez_chat/run_simulation_lgx.sh --fresh

# Testnet (uses shared LEZ deployment; ~7 min E2E vs ~5 min local)
SIM_NETWORK=testnet \
TESTNET_RPC_URL=http://lez-node.local:3040/ \
SIM_NODE_STARTUP_SLEEP=45 SIM_NPC_RETRIES=1 \
    PATH="$HOME/.local/bin/git-wrapper:$PATH" TMPDIR=/tmp \
    bash simulations/mix_lez_chat/run_simulation_lgx.sh --fresh
```

Expected output tail:
```
ALL 15 CHECKS PASSED
```

Per-run logs land in `simulations/mix_lez_chat/.sim_state/`.

## 6. Iteration workflow

- Edit any Nim source → rebuild step 3.
- Edit chat_module Rust or delivery_module C++ → rebuild step 4.
- Edit `simulations/mix_lez_chat/run_simulation_lgx.sh` → re-run step 5 directly.

## Common failure modes

| Symptom | Fix |
|---|---|
| `git init` fails on `/tmp/nimble_.../githubcom_*#*_*` dir | Use the git wrapper (step 2). |
| `Downloaded package checksum does not correspond to that in the lock file` | `rm -rf nimbledeps/pkgs2/<pkg>*` and retry — nimble will refetch and update checksum inline; if still failing, patch `nimble.lock`'s sha1 with the printed "Checksum:" value. |
| `sds.nim(3, 11) Error: cannot open file: sds/types` | Sed nimble.paths (see step 3). |
| `verifyProof must be implemented by concrete spam protection types` | `libp2p_mix` pin is wrong. `nimble.lock` should have url=`adklempner/nim-libp2p-mix`, vcsRevision=`a93112306d...`, sha1=`32f433a3c7ed...`. |
| Receiver's `lp_subscribe returned null` | pollLoop wedge — should be fixed by plugin `24c90f4` (60s init delay). Verify plugin submodule is on `phase4/pollloop-sleep-first`. |
| `Waiting for sender on-chain membership confirmation` → sim exits early | `set -e` trap on grep — the sim's guards at `GIFTER_INFO` / `CONVO_ID` need `|| true`. Should be fixed in the current sim commit. |
| Sim exits without markers | Check for lingering daemons from previous runs: `pkill -f 'logoscore \-m /var/folders'`. |

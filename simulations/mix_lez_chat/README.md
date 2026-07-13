# Mix + LEZ RLN Chat Simulation

End-to-end private chat between two logos-chat clients over a 4-node mix
network with on-chain (LEZ) RLN spam protection. Two `logoscore` instances
(sender + receiver) do an X3DH key agreement via an out-of-band intro
bundle, then exchange double-ratchet-encrypted messages routed through 3-hop
Sphinx onion routes with per-hop RLN proof generation and verification. Node
0 runs the LIP-158 gifter service; nodes 1–3 and both chat clients get their
RLN memberships gifted on-chain (no per-user wallet or funding).

**Acceptance criterion:** a run ends with `ALL 15 CHECKS PASSED`.

## Quick start

Fresh clone → running the testnet acceptance sim, in two lines (needs the §1
tools + GitHub SSH access; ~30 min incl. builds):

```bash
git clone -b port/sim-config-v3 git@github.com:adklempner/logos-chat.git
cd logos-chat && bash simulations/mix_lez_chat/bootstrap.sh
```

`bootstrap.sh` installs the nimble git-wrapper, clones the sibling repos at
the right branches, builds the delivery library + module plugins, and runs
the sim. It's idempotent — re-run to resume. The rest of this document is the
manual/reference version and covers the local path, funding, and internals.

---

This is the single source of truth for the sim. It covers: running it from a
fresh clone (§1–§7), what the checks mean (§8), troubleshooting (§9), the
reference branches and requirements for the delivery/chat maintainers
(§10–§12), funding and deployments (§13), overrides and the Rust RLN overlay
(§14), and the companion docker sim (§15).

---

## 0. Two paths — pick before you start

| | **Testnet** (the acceptance path) | **Local** |
|---|---|---|
| Sequencer | remote (`https://testnet.lez.logos.co/`) | built + run locally |
| On-chain funding | claim-based faucet (automatic) | `run_setup` deploys a local tree |
| Extra host toolchain | none beyond §2 | lssa + spel checkouts, RISC0 guest ELFs, `run_setup` binary |
| Time (warm caches) | ~20–25 min | ~5 min/run + ~30 min one-time bootstrap |
| Use it for | **acceptance / reviewing a change** | fast inner-loop iteration |

**To accept a change, use testnet** — it needs nothing beyond the clone +
build below. The local path's extra bootstrap is in §7.

---

## 1. Requirements

- **nix** with flakes (`experimental-features = nix-command flakes`).
- **git ≥ 2.51** + the nimble wrapper in §3.
- **rust** via rustup (a `1.94.0` toolchain is pinned in a few crates;
  rustup fetches it on demand).
- **cmake**, **python3**, **curl**, **jq**, **rsync**, **openssl**.
- **docker** — ONLY to provision your own testnet deployment with
  reproducible guest ELFs (§13). Not needed to run the sim.

**Path-length caveat (important):** clone under a **short** parent such as
`~/Waku/Logos/`. The Nim compiler cache encodes the absolute source path into
cache *filenames*; a deep clone path overflows the 255-byte filename limit
and the delivery build dies with `Error: cannot open '~/.cache/nim/...@m..@s...'`.

---

## 2. Clone

```bash
mkdir -p ~/Waku/Logos && cd ~/Waku/Logos

git clone -b port/sim-config-v3        git@github.com:adklempner/logos-chat.git
git clone -b rebase/on-upstream-2026-07-08 git@github.com:adklempner/logos-chat-module.git

cd logos-chat
make update            # hydrates vendor/logos-lez-rln (@ 8ef7650) + vendor/nwaku

LEZ=vendor/logos-lez-rln
git clone -b handoff/on-delivery-config-v3 \
    git@github.com:adklempner/logos-delivery-module.git $LEZ/logos-delivery-module
# logos-delivery is cloned TWICE: nested (the sim's runtime dylib source) and
# at the lez-rln root (nix flake input for the delivery-module plugin).
git clone -b port/lez-mix-on-config-v3 --recurse-submodules \
    git@github.com:adklempner/logos-delivery.git \
    $LEZ/logos-delivery-module/vendor/logos-delivery
git clone -b port/lez-mix-on-config-v3 --recurse-submodules \
    git@github.com:adklempner/logos-delivery.git $LEZ/logos-delivery
```

**Expected heads** (a fresh clone should land exactly here):

| Repo | Path | Branch | Head |
|---|---|---|---|
| logos-chat | `.` | `port/sim-config-v3` | tip |
| logos-chat-module | `../logos-chat-module` | `rebase/on-upstream-2026-07-08` | `82546d0` |
| logos-lez-rln (submodule) | `vendor/logos-lez-rln` | `feat/rln-module-rs` | `8ef7650` |
| logos-delivery-module | `…/logos-delivery-module` | `handoff/on-delivery-config-v3` | `c8a5a18` |
| logos-delivery (both) | `…/logos-delivery` | `port/lez-mix-on-config-v3` | `0b819ef` |
| mix-rln-spam-protection-plugin | `…/logos-delivery/vendor/mix-rln-spam-protection-plugin` | `phase4/pollloop-sleep-first` | `df2051e` |

---

## 3. Git wrapper for nimble (macOS / git ≥ 2.51)

Nimble runs `git -C <path-that-doesn't-exist-yet> init`; git ≥ 2.51 refuses.
Install a wrapper that `mkdir`s the `-C` target first:

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
exec /opt/homebrew/bin/git "$@"   # /usr/bin/git on Linux
EOF
chmod +x ~/.local/bin/git-wrapper/git
```

---

## 4. Build the delivery library

Build in the **nested** clone — the path the sim reads at runtime. The outer
`vendor/logos-lez-rln/logos-delivery` clone is only the nix flake input.

```bash
cd ~/Waku/Logos/logos-chat/vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery
PATH="$HOME/.local/bin/git-wrapper:$PATH" TMPDIR=/tmp make -j4 liblogosdelivery
# → build/liblogosdelivery.dylib (~43 MB)
```

If nimble complains `cannot open file: sds/types`, sed the stale path:
`sed -i.bak 's|/sds-0.3.0-[a-f0-9]*/sds"|/sds-0.3.0-XXX"|' nimble.paths` (XXX
= the sha1 on the same line), then re-run.

---

## 5. Build the module plugins (nix)

```bash
cd ~/Waku/Logos/logos-chat-module        && nix build .#default --print-out-paths
cd ~/Waku/Logos/logos-chat/vendor/logos-lez-rln/logos-delivery-module \
                                          && nix build .#lib     --print-out-paths
```

The wallet + RLN `.lgx` bundles are built by the sim on first run; pin them
via the override matrix (§14) if needed.

---

## 6. Run against testnet (the acceptance gate)

```bash
cd ~/Waku/Logos/logos-chat

export CHAT_PLUGIN_OVERRIDE=$(cd ~/Waku/Logos/logos-chat-module && \
    nix build .#default --print-out-paths --no-link)/lib/chat_module_plugin.dylib
export DELIVERY_PLUGIN_OVERRIDE=$(cd ./vendor/logos-lez-rln/logos-delivery-module && \
    nix build .#lib --print-out-paths --no-link)/lib/delivery_module_plugin.dylib
export DELIVERY_DYLIB_OVERRIDE=$(pwd)/vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery/build/liblogosdelivery.dylib

SIM_NETWORK=testnet SIM_NODE_STARTUP_SLEEP=45 SIM_NPC_RETRIES=2 \
    PATH="$HOME/.local/bin/git-wrapper:$PATH" TMPDIR=/tmp \
    bash simulations/mix_lez_chat/run_simulation_lgx.sh --fresh
```

Funding is automatic (faucet — see §13). Watch for `Faucet funding done:
GIFTER_ACCOUNT=…`. First run after a fresh staging may show `self=0` /
`0/3 client regs` on a cold wallet — state persists, just re-run. Expected
tail: `ALL 15 CHECKS PASSED`. Logs land in `.sim_state/`.

---

## 7. Run locally (fast iteration)

Local builds and runs its own sequencer, so it needs the execution-zone host
toolchain (lssa + spel checkouts, RISC0 guest ELFs, `run_setup` binary).
`setup_from_scratch.sh` does all of it plus the §4–§5 builds:

```bash
cd ~/Waku/Logos/logos-chat
bash simulations/mix_lez_chat/setup_from_scratch.sh
# then, same overrides as §6 with SIM_NETWORK=local SIM_NPC_RETRIES=1
```

<details><summary>By hand instead of the script</summary>

```bash
LEZ=vendor/logos-lez-rln
git clone --branch v0.2.0-rc6 https://github.com/logos-blockchain/logos-execution-zone.git $LEZ/lssa
git clone --branch feat/v0.5.0-rc6-port https://github.com/adklempner/spel.git $LEZ/spel
# guest ELFs (host risc0 toolchain, NOT docker — docker's context excludes the
# lssa/spel path deps) + run_setup:
(cd $LEZ/lez-rln/methods && PYO3_PYTHON=$(command -v python3) cargo build --release)
(cd $LEZ/lez-rln && PYO3_PYTHON=$(command -v python3) \
    cargo build --bin run_setup --bin register_member --bin derive_accounts)
```
</details>

---

## 8. What the 15 checks prove

| # | Check | Proves |
|---|---|---|
| 1–4 | Node 0–3 mounted mix | Sphinx mix mounts on every relay |
| 5 | Node 0 gifter service mounted | LIP-158 gifter LPProtocol up (and self-registration succeeded) |
| 6 | LEZ RLN active | on-chain root polling live on the relays |
| 7 / 9 | Receiver / Sender initialized | chat `init_after_delivery` completed |
| 8 / 10 | Receiver / Sender started | waku node started inside the chat instance |
| 11 / 12 | Receiver / Sender mounted mix+LEZ | joined the mix network, LEZ callbacks wired |
| 13 | Receiver ready for messages | messageReceived subscription registered |
| 14 | Sender sent message | RLN proof generated + mix route accepted the send |
| 15 | Receiver received message | full E2E: payload crossed the 3-hop mix with valid RLN proofs |

Local runs are deterministic (typically 16/16 messages); testnet runs are
non-deterministic (slot allocation, confirmation, circuit timing). A 14/15
with only marker 15 failing is usually a stale `liblogosdelivery` (no gifter
mount) or the mix-publish race — re-run on a quiet machine.

Running with `SIM_DEMO_MODE=1` replaces the 15 checks with 4 gifter-protocol
markers: (1) gifter request received, (2) sender membership granted, (3a) mix
nodes generated RLN proofs, (3b) a proof verified.

---

## 9. Troubleshooting

Grouped by the stage that owns the failure.

**Clone / nimble (setup):**

| Symptom | Fix |
|---|---|
| `git init` fails on `/tmp/nimble_.../githubcom_*#*` | git wrapper (§3). |
| `Build failed for the package: testutils` + `cannot open '~/.cache/nim/...@m..@s...'` | Clone path too deep — re-clone under a shorter parent (§1). |
| `sds.nim ... cannot open file: sds/types` | Sed `nimble.paths` (§4). |
| `verifyProof must be implemented …` | Wrong `libp2p_mix` pin (`nimble.lock` → `adklempner/nim-libp2p-mix` rev `a93112306d…`). |
| `duplicate symbol _rust_eh_personality` at link | librln_mix + rust-bundle each embed Rust std — `scripts/fix_mix_librln_dupes.sh` localizes them. |
| `nix bundle` 403 | crates.io rate limit → use the `.lgx` env pins (§14). |
| `symbol not found: _logosdelivery_*` | stale 8-symbol Nim dylib — rebuild (§4), or ensure `DELIVERY_EXTRA_LIB`/`DELIVERY_DYLIB_OVERRIDE` point at your build. |

**Setup / on-chain (testnet):**

| Symptom | Fix |
|---|---|
| `Testnet unreachable` | RPC down / network. |
| Run 1: `self=0` / `0/3 client regs`, `RLN config not set on gifter node` | Cold-wallet first-contact sync starves the gifter — re-run (run 2 warm). |
| `run_setup` panics `Timeout waiting for account … to be initialized` | Only on legacy `wallet-key` deployments with a drained supply — the faucet default (§13) avoids this; else mint a private tree (`SIM_FRESH_TREE=1`). |
| `DeserializeUnexpectedEnd` | lssa rev mismatch vs the lez-rln pin (local path). |

**Runtime (nodes / mix / delivery):**

| Symptom | Fix |
|---|---|
| `call failed: delivery_module.start()` | **Expected** — Qt loop blocked; success is `Node started successfully`, not this RPC. |
| `RLN fetcher not registered` / `Plugin not ready` | trampoline not installed pre-start. |
| Chat daemon `Segmentation fault: 11` right after `Delivery start completed with success` | Post-start QtRO call burst race — handled by the sim's call sequencing; if it recurs, capture per §11. |
| `Self-verify … Expected one of the provided roots` | RLN proof/window staleness (get_merkle_proofs non-atomicity / stalled pollLoop). |
| `Mix lightpush timed out` | SURB reply missed the 60s deadline; the forward path may still have delivered. |
| Node daemon dies silently after `Node started successfully` | Memory pressure — re-run on a quiet machine. |
| `Receiver received message (0/≥1)` with `failed to initiate send` | Load-induced mix-send flake — re-run on a quiet machine. |
| Local: `run_setup failed … registration program binary … No such file` / `lssa checkout … failed` | Guest ELFs / siblings missing — run `setup_from_scratch.sh` (§7). |

---

## 10. What's applied on top of upstream (reference branches)

The stack adds **mix routing + LEZ RLN spam protection** to the stock
delivery/chat pipeline. Per repo, newest upstream base first; each commit is
*(feature)* or *(workaround — reason)*.

### logos-delivery — `port/lez-mix-on-config-v3` on upstream `90fa5fa9`
- `55648cfb` **port(deps)** — pins `libp2p_mix` to the adklempner fork
  *(workaround — upstream's `verifyProof` is sync; LEZ verify needs async)*;
  adds the spam-protection plugin as a submodule; build glue.
- `a4f4af37` **port(feat)** — the LEZ mix+RLN modules: `lez_mix_setup.nim`
  (mix/RLN wiring, gifter service + worker, self/client registration), the
  2-phase gifter protocol, the RLN FFI surface.
- `8d771c82` **port(integration)** — node_factory LEZ hooks + config-v3
  (`mode`/`kernelOverrides`) surface.
- `e871ed1b` gifter-client dial budget 5×5s → 30×15s *(workaround — §11)*.
- `0b819ef` **fix** — run the gifter's RLN registration off the chronos
  loop (the self-registration freeze — §11).

### logos-delivery-module — `handoff/on-delivery-config-v3` on `2577383` (2 commits)
- `69d1c21` **port(feat)** — typed RLN client, the `rln_fetcher` trampoline
  (Nim worker blocks on a promise; Qt loop stays free), selfRegisterRln /
  setRlnConfig, v3-aware port defaults, `CALLBACK_TIMEOUT` 30s→180s
  *(workaround — §11)*.
- `c8a5a18` flake pin. (Iterative history survives on
  `port/on-delivery-config-v3` @ `a13b718`, tree-identical.)

### logos-chat-module — `rebase/on-upstream-2026-07-08` on `5c79789`
- `107f138` **feat** — `set_rln_config` ported to the Rust LIDL module.
- `82546d0` `init_after_delivery` *(workaround — logos-core has no module
  dependency-ordering/ready signal; homework: upstream lifecycle hook)*.

### logos-lez-rln — submodule at `8ef7650` (`feat/rln-module-rs`, 2 commits on upstream `4b403c1`)
- `644b772` **deploy** *(feature — review first)* — deployment-configurable
  funding (faucet claim model + legacy wallet-key), membership policy fields,
  `mint_tokens`/`claim_tokens`/tri-state `get_token_balance` on the C++ RLN
  module + ffi, and the `tools/deployments/` provisioning surface. This is the
  same tree as the shared **`feat/deploy-policies` @ `ae3b066`** branch (which
  the docker sim pins and is left intact); it's presented here as one commit.
- `8ef7650` **feat** — the rust-sdk work: lez-rln-ffi Rust-native API
  extraction (`native.rs`; C header byte-identical) + the Rust port of
  logos-rln-module (`lez-rln-module-rs/`, drop-in, wire-parity; funding
  methods deferred → **legacy profiles only**, §12) + the committed
  `deployments/mlc-faucet-260712/` descriptor.

### logos-chat — `port/sim-config-v3` (fork-only, one consolidated commit on upstream `15f68f2`)
The sim harness plus its supporting logos-chat changes: post-#32 chat
adaptation, config.nims excluding vendor/nwaku from the vendor scan,
config-v3 delivery configs, post-start call sequencing *(workaround — §11)*,
testnet supply preflight + `SIM_FRESH_TREE`, faucet claim-funding, the
deploy-policies lez-rln submodule pin, and src/chat delivery-client
adaptations for the mix + RLN path.

### mix-rln-spam-protection-plugin — submodule at `df2051e`
- `edb6afe` **feat** — stateless LEZ RLN, on-demand valid-roots refresh.
- `ba32e9f` **feat** — defensive witness-implied root add (atomic
  root+proof refresh).
- `df2051e` pollLoop first-tick delay 60s *(workaround — early tick starves
  QtRO subscribers; homework: async fetcher)*.

---

## 11. Standing workarounds (each hides a real bug)

"Regresses" = which of the 15 checks fail without it.

| Workaround (where) | Underlying bug | Suggested real fix | Regresses |
|---|---|---|---|
| Post-start call sequencing (sim) | QtRO calls queued behind the blocking `start()` burst-dispatch at start-completion and SIGSEGV the chat daemon ~50%/instance on testnet | Non-blocking `start()` or re-entrancy-safe FFI dispatch | 7/9 → 14/15 |
| `CALLBACK_TIMEOUT` 30s→180s (delivery-module) | Sync QtRO→RLN→wallet chain blocks worker threads for the full confirmation window | Async registration end-to-end | 9/14/15 |
| Gifter dial budget 30×15s (`e871ed1b`) | Clients dial while the gifter serializes registrations | Serve the gifter protocol independent of registration progress | 6, 14/15 |
| pollLoop first-tick delay 60s (plugin) | Cover traffic asks for proofs before the plugin's root window is warm | Gate cover traffic on a readiness signal | 5/6, flaky 15 |
| `SIM_NODE_STARTUP_SLEEP=45` (sim) | Same readiness race, node-startup flavor | Same readiness signal | flaky 1–6 |
| SURB timeout 15s→60s + error→warn (waku_client) | SURB replies outlive 15s over 3-hop testnet routes; the error-level teardown killed healthy sends | Measured timeout; drop the teardown | 15 (bidirectional) |

**Fixed in this branch — gifter self-registration freeze.** `gifterWorker`
called `gifterSubmitOnce` synchronously, and its `callRlnFetcher(
"register_member")` ran the 60–90s QtRO→wallet→chain round-trip **on the
chronos event-loop thread** — node 0 stopped serving libp2p / the gift
protocol for the whole submit (last gifter log line was the tx submit, then
silence), so later chat-client gifts were starved and marker 15 never landed.
Fix: repair the shelved `callRlnFetcherAsync` (its worker-thread callback
allocated Nim GC strings → cross-heap SIGSEGV under `--mm:refc --threads:on`;
now the result crosses the thread boundary in shared, non-GC memory) and
route `register_member` + the confirmation poll off-thread. The gifter's loop
now stays live through its own registration.
(`logos-delivery/.../logos_core_client.nim` + `lez_mix_setup.nim`.)

---

## 12. Open bugs (requirements to implement)

1. **Double `register_member` fire (delivery-module):** sync `selfRegisterRln`
   and the async Nim fetcher both register ~2s apart, reusing the payer nonce
   (testnet confirmation is 60–90s), so the second tx is silently dropped;
   on a virgin tree this poisoned the gifter. Reference mitigation:
   `REG_IN_FLIGHT` dedup in the Rust RLN module
   (`lez-rln-module-rs/rust-lib/src/lib.rs`). Real fix: a single registration
   owner in the delivery module.
2. **Per-signer nonce collision (LEZ wallet, `lssa/wallet/`):** when the
   gifter fires several `register_member`s within one sequencer block window,
   all fetch the same chain nonce N, sign with N, and submit; the first
   commits and the rest fail `validate_on_state` with `Nonce mismatch`, are
   dropped at the sequencer, and `get_transaction` can't tell "rejected" from
   "pending". Root cause is a wallet-level gap: no per-signer nonce
   serialization, no mempool dedup. (Reproduced locally 2026-05-27; this is
   the deeper cause the §12.1 dedup works around at the RLN layer.)
3. **Deferred-result sentinel (delivery-module):** the pinned logos-cpp-sdk
   predates `resolveDeferred`/`__logos_call_complete__`, so multi-concurrency
   provider replies read as instant failures — forcing the Rust RLN module to
   `concurrency: single`. Requirement: bump the pin; acceptance: flip the
   module's metadata to `"concurrency": "multi"`, rebuild, sim stays 15/15.
4. **Rust RLN module funding-method lag (logos-lez-rln):** the C++ module on
   `feat/deploy-policies` gained `mint_tokens`/`claim_tokens`/
   `get_token_balance`; the Rust port defers them, so the overlay (§14) only
   works on legacy-funding profiles. The rebased lez-rln-ffi already exposes
   the natives; porting is lidl entries + 3 handlers + wire-parity probes.

---

## 13. Testnet funding & deployments

**Faucet (default).** Testnet runs default to `mlc-faucet-260712` (tree
`01aa0cac…`, funding `faucet`): each run claims its own budget
(`CLAIM_BUDGET`, default 10M ≈ 6M run cost + slack) from a program-owned PDA
via the RLN module's `claim_tokens` — no drainable supply, no mint key, no
tree management. Knobs: `DEPLOYMENT`, `CLAIM_BUDGET`, `CLAIM_CHUNK` (default
10M, must be ≤ the deployment's on-chain `faucet_claim_cap`).

**Private trees (legacy wallet-key).** For an isolated tree: `SIM_FRESH_TREE=1`
mints a new tree (~10 min block-seal waits, persisted in `.tree_id_hex`) with
100B RLNTOK; each `--fresh` run draws 10B (≈9 runs). A drained supply fails
*silently* on-chain and `run_setup` panics ~3 min later — the sim preflights
the supply balance on legacy profiles and dies with the real story. Tree-id
precedence: `SIM_FRESH_TREE` > `LEZ_RLN_TREE_ID_HEX` > `.tree_id_hex`
(ignored when a faucet deployment is staged) > descriptor > default.

**Roll your own deployment:** `tools/deployments/provision.sh --name <n>
--funding faucet [--claim-cap N]` then `verify.sh`; commit
`deployments/<n>/{deployment,storage}.json` and run with `DEPLOYMENT=<n>`.
Build the guest ELFs reproducibly first: `cargo risczero build
--manifest-path methods/guest/Cargo.toml` **from `lez-rln/`** (docker context
must include the path deps), then `cd methods && cargo build` to strip under
the 511,800-byte tx cap.

---

## 14. Overrides & the Rust RLN overlay

Every module can be pinned via env (needed when nix bundling can't run, or to
swap an implementation):

| Env var | Overrides |
|---|---|
| `CHAT_LGX` / `CHAT_PLUGIN_OVERRIDE` | chat_module bundle / plugin |
| `DELIVERY_LGX` / `DELIVERY_PLUGIN_OVERRIDE` | delivery_module bundle / plugin |
| `DELIVERY_DYLIB_OVERRIDE` / `DELIVERY_EXTRA_LIB` | liblogosdelivery staged / DYLD-preloaded |
| `WALLET_LGX` / `WALLET_PLUGIN_OVERRIDE` | logos_execution_zone bundle / plugin |
| `RLN_LGX` / `RLN_PLUGIN_OVERRIDE` | liblogos_rln_module bundle / plugin |

**Rust RLN module overlay.** A wire-parity Rust port of logos-rln-module
lives at `logos-lez-rln` `feat/rln-module-rs` (`lez-rln-module-rs/`, see its
README). Build (`nix build 'path:.#default'` + `'.#lgx'`), then run with
`RLN_PLUGIN_OVERRIDE` + `RLN_LGX` pointed at it. Local 15/15 verified;
**legacy-funding profiles only** on testnet until the funding methods are
ported (§12.4) — pair with `SIM_FRESH_TREE=1` or a wallet-key deployment, not
the faucet default. A faucet-run bundle built from a pre-deploy-policies tree
lacks `claim_tokens` and breaks the funding bootstrap; use a bundle from the
current vendor tree.

---

## 15. Companion: the docker sim (logos-rln-mix-sim)

`logos-co/logos-rln-mix-sim` is the parallel docker-compose harness for the
same protocol on an independent stack — and the origin of the faucet funding
model this sim adopted. Useful as a second wire-compatibility surface. Notes
for its maintainers: its `Dockerfile.testnet-e2e` pins lez-rln
`feat/deploy-policies` at `7e6e9ab` (branch moved to `ae3b066`), and its
README still claims lez-rln `main @ 4b403c1` — both stale.

---

## Layout

- `bootstrap.sh` — fresh clone → running the testnet sim in one command
  (git-wrapper + sibling clones + builds + run). See "Quick start".
- `run_simulation_lgx.sh` — the acceptance harness (`.lgx`/daemon mode).
- `setup_from_scratch.sh` — one-shot local bootstrap (siblings, guest ELFs,
  binaries, module builds); also sourced by the harness for its prep helpers.
- `fixtures/gifter_auth/` — committed EIP-191 test keys + allowlist.
- `.sim_state/` — per-run logs/keystores/configs (git-ignored).

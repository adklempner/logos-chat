# Mix + LEZ RLN Chat Simulation

End-to-end private chat between two logos-chat clients over a 4-node mix
network with LEZ-backed (on-chain) RLN spam protection.

Two logoscore instances (sender + receiver) establish an X3DH key agreement
via an out-of-band intro bundle, then exchange double-ratchet-encrypted
messages routed through 3-hop Sphinx onion routes with per-hop RLN proof
generation and verification. Node 0 mounts the rln_gifter service on two
codecs (`/logos/rln/membership/1.0.0` for registration +
`/logos/rln/membership/status/1.0.0` for status polling); nodes 1-3 and
both chat clients register RLN memberships on-chain via the gifter, with
a background watcher that polls the status codec until the on-chain
membership PDA materialises and corrects the leaf index if a concurrent
registration won the optimistic slot. The sender publishes via
`lightpushPublish(mixify=true)`, every mix hop verifies the inbound spam
proof and generates a fresh proof for the next hop, the exit node fans out
via lightpush, and the receiver consumes via a Waku filter subscription.

This README covers setup, day-to-day operation, configuration, and
common-failure triage. For an in-depth walkthrough of what each stage of
the sim does and how it can fail at the protocol layer, see
[SIMULATION_STAGES.md](SIMULATION_STAGES.md).

---

## Quick start (macOS / Linux native)

**Prereqs:** nix (with flakes), Docker, cargo + cargo-risczero, SSH access
to GitHub, cmake + ninja + pkg-config.

```bash
git clone -b rebase/sim-rln-gifter-on-new-stack \
  git@github.com:adklempner/logos-chat.git
cd logos-chat
git submodule update --init --recursive

bash simulations/mix_lez_chat/setup_from_scratch.sh   # ~30 min on first run
bash simulations/mix_lez_chat/demo_step.sh            # 4/4 PASS
```

`setup_from_scratch.sh` is **idempotent** — every step skips itself when
its output is already on disk, so re-running it after edits is a few-second
no-op. It handles:
- the nix builds for `logos-rln-module` and `wallet-module`,
- the Rust setup binaries (`run_setup`, `register_member`, etc.),
- the chat-side and delivery-side Nim builds (`liblogosdelivery.dylib` and
  `liblogoschat.dylib`) with all the PR #3807-transitional prep that the
  current nimble pin set needs (nimble.lock URL-bug workarounds, stale
  libp2p-carcass rename, nimbledeps mirroring, librln_mix dedup against
  rust-bundle).

`demo_step.sh` is just `SIM_DEMO_MODE=1 bash run_simulation_lgx.sh` — it
runs the full sim and reports the 4-marker gifter-protocol pass criteria.
For the deeper 15-check verification block, use
`bash simulations/mix_lez_chat/run_simulation_lgx.sh` directly.

`run_simulation_lgx.sh` also sources `setup_from_scratch.sh` and calls the
prep helpers from its auto-build paths, so calling `demo_step.sh` directly
on a fresh-but-not-bootstrapped clone also works — the explicit bootstrap
step is just a separate gate so you can spot setup failures without them
hiding inside sim-stage failures.

First-run timing: roughly **~30-45 min** on macOS arm64 (most of it is the
RISC0 zkVM guest build, followed by 4 `.lgx` bundles, the two Nim dylibs,
and the C++ delivery plugin). Re-runs against the same checkout reuse the
nix store and finish in **~10-15 min** for local, **~20-30 min** for
testnet.

On x86_64 Linux this should work out of the box. On aarch64 Linux, guest
zkVM binaries must be pre-built on another platform (rzup doesn't support
aarch64-linux) and the wallet module nix build needs
`RISC0_SKIP_BUILD_KERNELS=1`.

Override the auto-clone source for `vendor/logos-delivery` with
`DELIVERY_REPO` / `DELIVERY_BRANCH`, or skip auto-build entirely with
`DELIVERY_EXTRA_LIB` / `CHAT_EXTRA_LIB` pointed at pre-built dylibs.

### Linux (via Docker)

**Prereqs:** Docker with 24 GB RAM allocated.

```bash
git clone -b rebase/sim-rln-gifter-on-new-stack \
  git@github.com:adklempner/logos-chat.git
cd logos-chat && bash scripts/run_in_docker.sh
```

The pre-built image (`ghcr.io/adklempner/logos-chat-sim`) is pulled
automatically (~8.5 GB download). Guest zkVM binaries must exist on the
host from a previous macOS/x86_64 build, or set `GUEST_BINARIES_DIR`.

Each sim run: ~10 min (clone + sequencer build + sim). To force a local
image rebuild: `REBUILD_IMAGE=1 bash scripts/run_in_docker.sh`.

### If `nix bundle` returns 403 (crates.io rate limit)

The wallet and chat `.lgx` builds vendor Rust deps through
`static.crates.io`; that endpoint occasionally 403s on fresh clones. The
fix is to point the sim at an already-cached `.lgx` in the nix store:

```bash
find /nix/store -maxdepth 3 -name "logos-chat_module-module-lib.lgx" | head -1
find /nix/store -maxdepth 3 -name "logos-execution-zone-module*.lgx" | head -1
CHAT_LGX=<path-from-above> WALLET_LGX=<path-from-above> \
    bash simulations/mix_lez_chat/demo_step.sh
```

If neither cache hit, run `nix-collect-garbage --delete-older-than 7d` to
free disk + retry, or vendor the crate tarballs manually from
`~/.cargo/registry/cache/`.

---

## Branch refs (the rebased stack)

| Repo | Branch | Tip |
|---|---|---|
| `adklempner/logos-chat` | `rebase/sim-rln-gifter-on-new-stack` | top |
| `adklempner/logos-delivery` | `rebase/lez-rln-gifter-on-3807` | nwaku LEZ-RLN gifter on PR #3807 |
| `logos-co/logos-lez-rln` | `feat/rln-stateless-v2.0.2` | rln 2.0.2 + stateless |
| `adklempner/mix-rln-spam-protection-plugin` | `feat/lez-rln-stateless` | PR #9 stateless + 4 LEZ commits |

Submodule pointers in this repo already track these tips. The forks are
not under CI; **local builds are the only verification path**.

---

## Pass criteria

**`demo_step.sh` (default fresh-clone entry):**
`DEMO PASS: all 4 markers fired` printed in the `[6/6]` block:

1. Gifter service received the membership request (logged on node 0 — the gifter)
2. Sender received a valid RLN membership (logged on the sender's chat module)
3. Mix nodes generated RLN proofs (≥1 across nodes 1-3)
4. A mix node verified another node's proof (≥1 across nodes 1-3)

A passing local sim deterministically generates ~6000 proofs and verifies
~5000 of them across the 4 mix nodes within a single demo run.

A passing run also reports `Delivery check after Ns (messages: N/expected ≥1)`
if mix forward delivery completed end-to-end. Local sims are deterministic
and typically deliver 16 messages; testnet sims currently hit a self-verify
race ("Expected one of the provided roots") on the sender's first publish
— markers 1+2 fire but 3a/3b stay at 0 and delivery times out. The race
is in the mix spam-protection plugin's `cachedProof` ↔ `validRoots` window
divergence, addressed partially in `mix-rln-spam-protection-plugin`
`d06aad7` (atomic root+proof refresh in `pollLoop`) but not yet fully
closed.

**`run_simulation_lgx.sh` (no SIM_DEMO_MODE):** the deeper 15-check
verification block — 4 mix nodes mounted, gifter service mounted, LEZ
RLN active, both chat clients initialised/started/mix-mounted, intro
bundle created, sender publishes, receiver delivers ≥1 chat event. Use
this when debugging the lower layers; see SIMULATION_STAGES.md for the
per-check breakdown.

---

## Architecture

```
logoscore (per mix node)                    logoscore (per chat client)
├── wallet_module (LEZ wallet)              ├── wallet_module (LEZ wallet)
├── liblogos_rln_module (RLN proofs)        ├── liblogos_rln_module (RLN proofs)
└── delivery_module (Waku mix relay)        └── chat_module (logos-chat-module)
    ├── liblogosdelivery.so                     ├── chat_module_plugin.so
    └── mix + relay + filter + gifter           └── liblogoschat.so
                                                    └── mix client + filter + gifter client
```

Node 0 runs the RLN gifter service. Nodes 1-3 register via gifter on
startup. Chat clients also register via gifter when `startChat()` runs.

For what happens at each protocol stage (RLN program deploy, gifter
codec, mix sphinx hops, RLN proof generation/verification per hop, SURB
reply, etc.), see [SIMULATION_STAGES.md](SIMULATION_STAGES.md).

---

## LEZ backend

The simulation runs against the SPEL framework (logos-lez-rln
`feat/rln-stateless-v2.0.2` branch). On-chain RLN programs use SPEL's
`#[lez_program]` macro with 32-byte tree IDs, Borsh-encoded state, and
PDA-based account derivation via `combine_seeds`. The RLN module's
`get_merkle_proofs` RPC returns the merkle proof and validRoots window
atomically from the same on-chain main-account read, eliminating the
cross-RPC race that previously left proof roots absent from polled
validRoots.

The mix-rln-spam-protection plugin uses PR #9's stateless backend
(zerokit 2.0.2 + Nim-IMT) — the Merkle tree lives Nim-side rather than
pmtree, which removes pmtree-only FFI exports and lets the single
`librln_v2.0.2.a` archive serve both the C++ RLN module and the Nim mix
plugin without duplicate-symbol link errors.

---

## Networks: local sequencer vs testnet

`SIM_NETWORK=local` (default) runs against an in-process LSSA sequencer
with ~15 s blocks. `SIM_NETWORK=testnet` targets
`https://testnet.lez.logos.co/` (~60 s blocks + variable finality lag).
On testnet the run uses persistent wallet state under
`vendor/logos-lez-rln/testnet/`, seeded on first use from the committed
`storage.json.seed` + supply sidecar so fresh clones don't need to
redeploy programs.

`SIM_SLIM=1` (testnet only) skips `run_setup` when the shipped
`config_account.txt` + a cached `payment_account_<tree>.txt` exist, so
fresh clones can run without building `lez-rln`'s `run_setup` binary.
Typical slim testnet run:

```bash
SIM_NETWORK=testnet SIM_SLIM=1 SIM_DELIVERY_TIMEOUT=1800 \
    bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

`SIM_DELIVERY_TIMEOUT=1800` (30 min) is required: the gifter serializes
registrations through a single-writer worker that awaits chain
confirmation between submissions to avoid per-signer nonce collisions
(see `../../MODE_A_GIFTER_SLOT_BUG.md`). With testnet's ~60-90 s block
cadence and up to ~6 jobs ahead in the queue, the chat sender (last in
line) needs the longer window — the default 300 s would expire before
its registration confirms.

Testnet runs are non-deterministic — gifter slot allocation, block
confirmation, and mix circuit timing all vary per run. The defensive
layers (self-verify on bad proofs, libp2p-status-codec watcher correcting
optimistic leaf indices) catch most failure modes; a silent-drop gap is
still open.

### Reproducibility on a fresh clone (testnet)

The canonical testnet deployment (RLN tree + minted supply) is shared
across developers. On first run, the script seeds two artifacts from the
submodule so `run_setup` can short-circuit to `create_funded_user`:

- `vendor/logos-lez-rln/testnet/storage.json.seed` →
  `vendor/logos-lez-rln/testnet/storage.json` if absent. Contains only
  the supply holding account + its signing key.
- `vendor/logos-lez-rln/testnet/supply_holding.txt` →
  `~/.logos-lez-rln/supply_holding_<tree_id>.txt` if absent. Contains
  the supply `AccountId`.

What stays shared vs. fresh:

| Artifact | Shared | Per-dev fresh |
|---|---|---|
| `TREE_ID`, sequencer URL, deployed program IDs (on-chain), gifter EIP-191 auth keys, mix node identity keys | ✓ | |
| Supply holding account + signing key (seeded from submodule) | ✓ | |
| Per-run payment account (`~/.logos-lez-rln/payment_account_<tree>.txt`) | | ✓ |
| Working-copy `testnet/storage.json` (gitignored; accumulates payment accounts) | | ✓ |
| Mix + chat RLN credentials (in `.sim_state/rln_keystore_*.json`) | | ✓ |

**Security:** the supply signing key being in the repo is acceptable
only because testnet does not charge gas and the tokens are test tokens
with no real value.

### Minimum submodule set for slim mode

```bash
git clone --branch rebase/sim-rln-gifter-on-new-stack <repo> logos-chat
cd logos-chat
git submodule update --init vendor/logos-lez-rln vendor/nwaku \
    vendor/nimbus-build-system vendor/nim-protobuf-serialization \
    vendor/npeg vendor/blake2 vendor/libchat vendor/nim-ffi
(cd vendor/logos-lez-rln && git submodule update --init logos-delivery-module)
(cd vendor/logos-lez-rln/logos-delivery-module && \
    git submodule update --init --recursive vendor/logos-delivery)
```

The `lssa` (~11 GB) and `logos-execution-zone-module` clones are
unnecessary for slim mode — both are fetched via nix flake from GitHub
when building the wallet/RLN modules. For the local-sequencer flow
(`SIM_NETWORK=local`) or to hack on the wallet/sequencer source, init the
extras: `(cd vendor/logos-lez-rln && git submodule update --init lssa logos-execution-zone-module)`.
The Docker bootstrap (`setup_and_run.sh`) gates these on
`SIM_NETWORK=local` automatically; pass `SIM_FULL_SUBMODS=1` to force
the wide init.

All slim-mode runs share one on-chain payment account — concurrent runs
across devs will race on its nonce. Use serially.

---

## Running the GUI chat client (logos-chat-ui-app) against the sim

The headless sim normally drives both sender and receiver. For demos /
interactive testing you can keep the sim infra (sequencer + 4 mix nodes
+ gifter + receiver) running headless and have the GUI act as the sender.

### One-shot setup (per shell)

```bash
# Terminal 1 — sim infra (stays in foreground; Ctrl-C cleans up)
SIM_INFRA_ONLY=1 bash simulations/mix_lez_chat/run_simulation_lgx.sh
# … or for testnet:
SIM_NETWORK=testnet SIM_INFRA_ONLY=1 \
    bash simulations/mix_lez_chat/run_simulation_lgx.sh
```

Wait for the green banner. It prints:
- the `export CHAT_*` env vars the GUI needs (cluster id, port, gifter
  peer, auth key, mix nodes, static peers),
- the receiver's intro bundle (`logos_chatintro_1_…`) to paste into the GUI.

The sim then polls the receiver log for inbound `chatNewMessage` events
and prints one line per delivered message, so you have live feedback
while you drive the GUI.

### Staging the GUI

```bash
# Terminal 2 — stage a writable copy of logos-chat-ui-app with the right modules
bash simulations/mix_lez_chat/setup_chat_ui_app.sh
```

`setup_chat_ui_app.sh` auto-resolves the chat-ui-app, wallet, and RLN
`.lgx` paths and builds the wallet `.lgx` with the same
`--override-input` chain as the sim. That chain carries the
`request_timeout(...)` patch in the wallet's Rust HTTP client; without
it, `send_public_transaction` against a slow testnet hangs the wallet's
Qt thread on the first call and the GUI silently stops responding. Set
`APP_NIX`, `WALLET_LGX`, or `RLN_LGX` to skip the auto-resolve.

### Launching the GUI

Paste the `export CHAT_*` block printed by the sim into terminal 2, then:

```bash
/tmp/chat_ui_app_staged/bin/logos-chat-ui-app
```

In the GUI: Ctrl+I (Initialize Chat) → Ctrl+S (Start Chat) → File →
New Private Conversation → paste the intro bundle the sim printed →
type a message → send. Terminal 1 will print `RECEIVED MESSAGE #1` when
the receiver picks it up.

For testnet on a fresh wallet: see "If it fails → Testnet wallet drift"
below.

---

## Configuration

Override defaults via environment:

| Variable | Default (local / testnet) | Purpose |
|---|---|---|
| `SIM_NETWORK` | `local` | `local` runs against a sequencer on `127.0.0.1:3040`; `testnet` runs against `https://testnet.lez.logos.co/` |
| `SIM_DEMO_MODE` | `0` | Swap the `[6/6]` block for the 4-marker gifter-protocol check (set automatically by `demo_step.sh`) |
| `SIM_SETUP_ONLY` | `0` | Bring sim infra + receiver up, write `demo_state.env`, then block — used by `demo_setup.sh` and the GUI flow |
| `SIM_INFRA_ONLY` | `0` | Like `SIM_SETUP_ONLY` but interactive: prints env vars + intro bundle for a human GUI driver |
| `SIM_SLIM` | `0` | Testnet only: skip `run_setup` when a cached funded payment account is present. Saves the lez-rln Rust build on fresh clones; stale sidecars from a prior LOCAL run will fail (wipe per "If it fails" below) |
| `SIM_NUM_NODES` | `4` | Number of mix relay nodes |
| `SIM_BASE_TCP_PORT` | `60001` | First node's TCP port (increments per node) |
| `SIM_BASE_DISC_PORT` | `9001` | First node's discv5 UDP port (increments per node) |
| `SIM_CLUSTER_ID` | `99` | Waku cluster ID |
| `SIM_LOG_LEVEL` | `INFO` | Chronicles log level (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`) |
| `SIM_CHAT_RECV_PORT` | `60010` | Chat receiver TCP port |
| `SIM_CHAT_SEND_PORT` | `60011` | Chat sender TCP port |
| `SIM_KADEMLIA_MIN_WAIT` | `30 / 120` | Minimum seconds before kademlia/RLN readiness gate can pass |
| `SIM_KADEMLIA_HARD_CAP` | `180 / 1800` | Hard ceiling (s) on the readiness wait |
| `SIM_RECEIVER_MIN_WAIT` | `15 / 60` | Minimum seconds to wait for receiver to join mix |
| `SIM_DELIVERY_TIMEOUT` | `120 / 300` | Max seconds to wait for receiver to see a chat event |
| `SIM_NODE_STARTUP_SLEEP` | `10 / 30` | Spacing between mix node startups |
| `WALLET_LGX` / `RLN_LGX` / `DELIVERY_LGX` / `CHAT_LGX` | unset | Skip the corresponding `nix bundle` and use a pre-built `.lgx` from `/nix/store`. Useful when crates.io 403s on a fresh build (see "If `nix bundle` returns 403" above) |
| `DELIVERY_EXTRA_LIB` / `CHAT_EXTRA_LIB` | unset | Skip the `make liblogosdelivery` / `make liblogoschat` auto-build and use the supplied dylib path directly. Useful when iterating on the C++ plugin layer without touching Nim sources |
| `DELIVERY_REPO` | `git@github.com:adklempner/logos-delivery.git` | Where to clone `vendor/logos-delivery` from when missing (it's `.gitignored` inside `logos-delivery-module`, so `git submodule update --init --recursive` doesn't populate it) |
| `DELIVERY_BRANCH` | `rebase/lez-rln-gifter-on-3807` | Branch checked out from `DELIVERY_REPO` |
| `LGX_CACHE_DIR` | `~/.cache/sim-lgx` | Where the sim parks indirect GC roots for each module's bundle output. First run builds + pins; subsequent runs resolve the symlink and skip `nix bundle` entirely (~10 min → ~5 s for the bundling phase). Pins survive `nix-collect-garbage`. |
| `SIM_REBUILD_LGX` | unset | Set to `1` to invalidate the `LGX_CACHE_DIR` pins and force a fresh `nix bundle` per module. Use after editing module sources. |

Example — fast iteration with verbose logging:

```bash
SIM_LOG_LEVEL=TRACE SIM_KADEMLIA_MIN_WAIT=10 SIM_RECEIVER_MIN_WAIT=5 \
  bash simulations/mix_lez_chat/run_simulation_lgx.sh
```

---

## `--fresh` behavior

When `--fresh` is passed:
- Kills all existing `logos_host` processes
- Cleans `/tmp/logos_*` Qt RemoteObjects sockets
- Removes `.sim_state/` directory
- On `SIM_NETWORK=local` (default): removes sequencer state (`rocksdb/`,
  `bedrock_signing_key`), rebuilds and restarts the sequencer, redeploys
  RLN programs via `run_setup`
- On `SIM_NETWORK=testnet`: leaves on-chain state and the persistent
  wallet under `vendor/logos-lez-rln/testnet/` intact; `run_setup`
  short-circuits to `create_funded_user`

Without `--fresh`, on `SIM_NETWORK=local` it reuses an existing sequencer
if port 3040 is already bound.

---

## If it fails

The triage table in
[SIMULATION_STAGES.md → Quick failure-triage index](SIMULATION_STAGES.md#quick-failure-triage-index)
maps specific log/error lines to the stage that owns them. Common
top-level reset moves:

### Re-run with fresh state
```bash
pkill -f 'lssa|sequencer|logoscore' ; sleep 2
rm -rf vendor/logos-lez-rln/lssa/rocksdb \
       vendor/logos-lez-rln/dev/storage.json \
       simulations/mix_lez_chat/.sim_state
bash simulations/mix_lez_chat/demo_step.sh
```

### Wallet/sequencer errors (local)
```bash
kill $(lsof -ti tcp:3040) 2>/dev/null   # stop any stale sequencer
rm -rf ~/.nssa/wallet
rm -f vendor/logos-lez-rln/dev/wallet_config.json \
      vendor/logos-lez-rln/dev/storage.json
rm -f ~/.logos-lez-rln/payment_account_*.txt \
      ~/.logos-lez-rln/supply_holding_*.txt
rm -rf vendor/logos-lez-rln/lssa/rocksdb
```

### Testnet wallet drift
Symptoms: `KeyNotFoundError`, account-init timeout, `register_member
failed`, "gifter dial failed after 5 attempts".

```bash
# Drop the cached sidecars + wallet entirely and let run_setup re-fund.
# SIM_SLIM=1 would skip run_setup and reuse the cached payment account —
# do NOT use it for a clean reset, because the cached account is what's
# probably stale (a payment account from a previous LOCAL run, or the
# seeded testnet one that's at 0 RLNTOK balance).
rm -f ~/.logos-lez-rln/payment_account_*.txt \
      ~/.logos-lez-rln/supply_holding_*.txt
rm -rf ~/.nssa/wallet
SIM_NETWORK=testnet bash simulations/mix_lez_chat/run_simulation_lgx.sh
```

The sim's `[2/6] Deploying programs` will then call `run_setup` against
testnet, transfer ~1B RLNTOK from supply_holding into a freshly-derived
payment account, and write the new sidecar. The fix is durable across
reruns.

If node 0 stops logging shortly after startup and chat clients hit
`gifter dial failed`, the `WALLET_LGX` in use is missing the sequencer
HTTP request-timeout patch (see
`vendor/logos-lez-rln/lssa/wallet/src/lib.rs` for the
`SequencerClientBuilder::request_timeout(...)` call). Unset `WALLET_LGX`
to force a rebuild from the current sources.

### Stale guest binaries (after updating submodules)
```bash
rm -rf vendor/logos-lez-rln/lez-rln/methods/guest/target
bash simulations/mix_lez_chat/demo_step.sh
```

### Stale Qt RemoteObjects sockets ("Sender started FAIL")
```bash
rm -f /tmp/logos_*
bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

### Build-stage issues unique to the PR #3807 transition

These usually surface during a fresh-clone bootstrap; the per-build prep
helpers in `setup_from_scratch.sh` handle them automatically, but if you
hit them manually the fix is:

| Symptom | Cause | Fix |
|---|---|---|
| `make liblogosdelivery`: `nimble setup` fails on `bearssl_pkey_decoder` with `git -C ... init failed` | nimble 0.22.3 URL-mangling bug on `#`-prefix version pins | Re-run `bash simulations/mix_lez_chat/setup_from_scratch.sh` — `patch_delivery_nimble_lock` handles it. Manual fallback: clone the failing dep into `nimbledeps/pkgs2/<name>-#<rev>-<sha>/` (sha fields are in `nimble.lock`) |
| `make liblogoschat`: `Error: cannot open file: brokers/broker_context` | chat's nim path doesn't see nwaku's nimble deps | `mirror_chat_nimbledeps` handles it |
| `make liblogoschat`: `EVP_PKEY undeclared` in libp2p's `certificate_ffi.nim` | OLD libp2p carcass picked up before the nimble-resolved v2.0.0 | `rename_libp2p_carcass` handles it |
| `make liblogoschat`: `duplicate symbol _rust_eh_personality` at link | `librln_mix_v2.0.2.a` and the rust-bundle each embed their own Rust std | `scripts/fix_mix_librln_dupes.sh` should handle this; if it doesn't, verify `xcrun nm` is the macOS one (not a Homebrew GNU `nm` that can't parse rcgu objects) |

### Docker
Docker logs are rescued to `./docker-sim-logs/` on failure.

---

## Adapting for other LEZ programs

This simulation provides a complete mix network infrastructure that other
logos modules can reuse for testing. To test your own module:

### What the sim provides
- 4 logoscore mix nodes with `delivery_module` (Waku relay + mix + RLN)
- LEZ sequencer with deployed RLN programs
- RLN gifter service on node 0
- Wallet modules for on-chain transactions

### What you replace
The chat_module sender/receiver instances (phase 5 of
`run_simulation.sh`). Your module needs:

1. **A C++ Qt plugin** implementing `PluginInterface` (see
   `chat_module_plugin.cpp`)
   - `initLogos(LogosAPI*)` — receive the LogosAPI instance
   - `eventResponse(QString, QVariantList)` signal — mandatory per
     logos-liblogos contract
   - Methods exposed via `LOGOS_METHOD` for logoscore `-c` invocation
2. **A shared library** with your program logic (like `liblogoschat.so`)
3. **RLN integration** — wire `setRlnConfig` to pass RLN credentials
   from the C++ plugin to your library
4. **EVENT: stderr fallback** — on Linux, Qt signal forwarding from
   plugin to logoscore doesn't work across the FFI thread boundary.
   Write event data to stderr in `EVENT:name:data` format (gated by
   `LOGOS_EVENT_STDERR` env var) for cross-platform reliability.

### How to stage your module

```bash
MDIR=$(mktemp -d)
mkdir -p "$MDIR/your_module"
cp your_module_plugin.so "$MDIR/your_module/"
cp libyour_library.so "$MDIR/your_module/"
echo '{"name":"your_module","version":"1.0.0","type":"core",...}' \
    > "$MDIR/your_module/manifest.json"

logoscore -m "$MDIR" \
  -l "liblogos_execution_zone_wallet_module,liblogos_rln_module,your_module" \
  -c "liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)" \
  -c "your_module.init(@config.json)" \
  -c "your_module.start()"
```

### Reference
- `chat_module_plugin.cpp` — complete working example with RLN, gifter,
  mix, and event emission
- `delivery_module_plugin.cpp` — more complex example with full RLN
  fetcher integration
- `run_simulation.sh` — orchestration, module staging, and verification
  patterns

---

## Logs

All logs in `simulations/mix_lez_chat/.sim_state/`:
- `node0.log` – `node3.log` — mix relay nodes
- `chat_receiver.log` — receiver chat module
- `chat_sender.log` — sender chat module
- `sequencer.log` — LEZ sequencer

For the per-stage interpretation of these logs see
[SIMULATION_STAGES.md](SIMULATION_STAGES.md).

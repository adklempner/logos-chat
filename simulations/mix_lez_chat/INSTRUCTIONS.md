# Running the Mix + LEZ RLN Chat Simulation

End-to-end private chat between two logos-chat-module clients over a 4-node mix network with LEZ-backed RLN spam protection.

Two logoscore instances (sender + receiver) establish an X3DH key agreement via an out-of-band intro bundle, then exchange double-ratchet-encrypted messages routed through 3-hop Sphinx onion routes with per-hop RLN proof generation and verification. Node 0 mounts the rln_gifter service on two codecs (`/logos/rln/membership/1.0.0` for registration + `/logos/rln/membership/status/1.0.0` for status polling); nodes 1-3 and both chat clients register RLN memberships on-chain via the gifter, with a background watcher that polls the status codec until the on-chain membership PDA materialises and corrects the leaf index if a concurrent registration won the optimistic slot. The sender publishes via `lightpushPublish(mixify=true)`, every mix hop verifies the inbound spam proof and generates a fresh proof for the next hop, the exit node fans out via lightpush, and the receiver consumes via a Waku filter subscription.

## macOS

**Prereqs:** nix (with flakes), Docker, cargo-risczero, SSH access to GitHub.

```bash
git clone -b feat/sim-rln-gifter-auth-v2 git@github.com:logos-messaging/logos-chat.git
cd logos-chat
git submodule update --init --recursive
bash simulations/mix_lez_chat/setup_and_run.sh
```

First run: ~15-25 min. Re-runs: `bash simulations/mix_lez_chat/run_simulation.sh --fresh` (~5 min).

## Linux (native)

**Prereqs:** nix (with flakes), Docker, cargo-risczero, SSH access to GitHub.

```bash
git clone -b feat/sim-rln-gifter-auth-v2 git@github.com:logos-messaging/logos-chat.git
cd logos-chat
git submodule update --init --recursive
bash simulations/mix_lez_chat/setup_and_run.sh
```

Same as macOS. On x86_64 Linux this should work out of the box. On aarch64 Linux, guest zkVM binaries must be pre-built on another platform (rzup doesn't support aarch64-linux) and the wallet module nix build needs `RISC0_SKIP_BUILD_KERNELS=1`.

## Linux (via Docker)

**Prereqs:** Docker.

```bash
git clone -b feat/sim-rln-gifter-auth-v2 git@github.com:logos-messaging/logos-chat.git
cd logos-chat && bash scripts/run_in_docker.sh
```

The pre-built image (`ghcr.io/adklempner/logos-chat-sim`) is pulled automatically (~8.5GB download). Guest zkVM binaries must exist on the host from a previous macOS/x86_64 build, or set `GUEST_BINARIES_DIR`.

Each sim run: ~10 min (clone + sequencer build + sim). To force a local image rebuild: `REBUILD_IMAGE=1 bash scripts/run_in_docker.sh`.

## Networks: local sequencer vs testnet

`SIM_NETWORK=local` (default) runs against an in-process LSSA sequencer with ~15 s blocks. `SIM_NETWORK=testnet` targets `https://testnet.lez.logos.co/` (~60 s blocks + variable finality lag). On testnet the run uses persistent wallet state under `vendor/logos-lez-rln/testnet/`, seeded on first use from the committed `storage.json.seed` + supply sidecar so fresh clones don't need to redeploy programs.

`SIM_SLIM=1` (testnet only) skips `run_setup` when the shipped `config_account.txt` + a cached `payment_account_<tree>.txt` exist, so fresh clones can run without building `lez-rln`'s `run_setup` binary.

```bash
SIM_NETWORK=testnet SIM_SLIM=1 bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

Testnet runs are non-deterministic — gifter slot allocation, block confirmation, and mix circuit timing all vary per run. See `cleanup/FRESH_CLONE_RESULTS.md` for the failure modes the defensive layers catch (self-verify on bad proofs, libp2p-status-codec watcher correcting optimistic leaf indices) and the silent-drop gap that's still open.

## Pass criteria

**ALL 15 CHECKS PASSED** — 4 mix nodes mounted, node 0 gifter service mounted, LEZ RLN active, sender+receiver initialized/started/mix-mounted, intro bundle created, sender publishes, receiver delivers ≥1 chat event. Local runs are deterministic; testnet runs may report 14/15 with the receiver-delivery check as the failing one (failure modes documented in `cleanup/FRESH_CLONE_RESULTS.md`).

## LEZ backend

The simulation runs against the SPEL framework (logos-lez-rln `feat/eip191-gifter-auth` branch). On-chain RLN programs use SPEL's `#[lez_program]` macro with 32-byte tree IDs, Borsh-encoded state, and PDA-based account derivation via `combine_seeds`. The RLN module's `get_merkle_proofs` RPC returns the merkle proof and validRoots window atomically from the same on-chain main-account read, eliminating the cross-RPC race that previously left proof roots absent from polled validRoots.

## Configuration

```bash
SIM_LOG_LEVEL=TRACE SIM_KADEMLIA_MIN_WAIT=10 bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

Key `SIM_*` variables (full list in `simulations/mix_lez_chat/README.md`):

| Variable | Default (local / testnet) | Purpose |
|---|---|---|
| `SIM_NETWORK` | `local` | `local` or `testnet` |
| `SIM_SLIM` | `0` | Testnet only: skip `run_setup` when shipped config + payment account exist |
| `SIM_LOG_LEVEL` | `INFO` | Chronicles log level (`TRACE` for verbose) |
| `SIM_KADEMLIA_MIN_WAIT` | `30 / 120` | Minimum wait (s) before kademlia/RLN readiness gate can pass |
| `SIM_KADEMLIA_HARD_CAP` | `180 / 1800` | Hard ceiling (s) on the readiness wait |
| `SIM_DELIVERY_TIMEOUT` | `120 / 300` | Seconds to wait for receiver to see a chat event |
| `SIM_NODE_STARTUP_SLEEP` | `10 / 30` | Spacing between mix node startups |

## Restore point

Tag `restore/sim-15-15-pass-2026-05-21` marks a verified-working state at each submodule level. To restore the whole chain:

```bash
TAG=restore/sim-15-15-pass-2026-05-21
git checkout "$TAG"
git -C vendor/nwaku checkout "$TAG"
git -C vendor/nwaku/vendor/mix-rln-spam-protection-plugin checkout "$TAG"
git -C vendor/logos-lez-rln checkout "$TAG"
git -C vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery checkout "$TAG"
```

See `RESTORE_POINT.md` at the repo root for SHA + dylib hash details.

## If it fails

Re-run with fresh state:
```bash
bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

Wallet/sequencer errors (local):
```bash
rm -f vendor/logos-lez-rln/dev/wallet_config.json vendor/logos-lez-rln/dev/storage.json
rm -f ~/.logos-lez-rln/payment_account_*.txt
```

Testnet wallet drift (`KeyNotFoundError`, account-init timeout):
```bash
TREE=000102030405060708090a0b0c0d0e0f10111213141516171a05100200000000
rm -f ~/.logos-lez-rln/{supply_holding,payment_account}_${TREE}.txt
rm -f vendor/logos-lez-rln/testnet/storage.json
cp vendor/logos-lez-rln/testnet/storage.json.seed vendor/logos-lez-rln/testnet/storage.json
cp vendor/logos-lez-rln/testnet/supply_holding.txt ~/.logos-lez-rln/supply_holding_${TREE}.txt
cp vendor/logos-lez-rln/testnet/payment_account.txt ~/.logos-lez-rln/payment_account_${TREE}.txt
```

Guest binary errors after updating submodules:
```bash
rm -rf vendor/logos-lez-rln/lez-rln/methods/guest/target
bash simulations/mix_lez_chat/setup_and_run.sh
```

Docker logs are rescued to `./docker-sim-logs/` on failure.

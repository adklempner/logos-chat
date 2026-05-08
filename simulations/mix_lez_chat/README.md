# Mix + LEZ RLN Chat Simulation

End-to-end private chat between two logos-chat-module clients over a 4-node mix network with LEZ-backed RLN spam protection.

Two logoscore instances (sender + receiver) establish an X3DH key agreement via an out-of-band intro bundle, then exchange double-ratchet-encrypted messages routed through 3-hop Sphinx onion routes with per-hop RLN proof generation and verification. Node 0 mounts the rln_gifter service; nodes 1-3 and both chat clients register RLN memberships on-chain via the gifter protocol. The sender publishes via `lightpushPublish(mixify=true)`, the mix exit node verifies the RLN proof before fanning out via gossipsub relay, and the receiver consumes the message via a Waku filter subscription.

## macOS

**Prereqs:** nix (with flakes), Docker, cargo-risczero, SSH access to GitHub.

```bash
git clone -b feat/logos-delivery git@github.com:adklempner/logos-chat.git
cd logos-chat && bash simulations/mix_lez_chat/setup_and_run.sh
```

First run: ~15-25 min. Re-runs: `bash simulations/mix_lez_chat/run_simulation.sh --fresh` (~5 min).

## Linux (native)

**Prereqs:** nix (with flakes), Docker, cargo-risczero, SSH access to GitHub.

```bash
git clone -b feat/logos-delivery git@github.com:adklempner/logos-chat.git
cd logos-chat && bash simulations/mix_lez_chat/setup_and_run.sh
```

Same as macOS. On x86_64 Linux this should work out of the box. On aarch64 Linux, guest zkVM binaries must be pre-built on another platform (rzup doesn't support aarch64-linux) and the wallet module nix build needs `RISC0_SKIP_BUILD_KERNELS=1`.

## Linux (via Docker)

**Prereqs:** Docker with 24GB RAM allocated.

```bash
git clone -b feat/logos-delivery git@github.com:adklempner/logos-chat.git
cd logos-chat && bash scripts/run_in_docker.sh
```

The pre-built image (`ghcr.io/adklempner/logos-chat-sim`) is pulled automatically (~8.5GB download). Guest zkVM binaries must exist on the host from a previous macOS/x86_64 build, or set `GUEST_BINARIES_DIR`.

Each sim run: ~10 min (clone + sequencer build + sim). To force a local image rebuild: `REBUILD_IMAGE=1 bash scripts/run_in_docker.sh`.

## Pass criteria

**ALL 15 CHECKS PASSED** — 4 mix nodes mounted, gifter service, LEZ RLN active, sender+receiver initialized/started/mix-mounted, intro bundle created, messages sent and received.

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

Node 0 runs the RLN gifter service. Nodes 1-3 register via gifter on startup. Chat clients also register via gifter when `startChat()` runs.

## Configuration

Override defaults via environment:

| Variable | Default | Description |
|---|---|---|
| `SIM_NUM_NODES` | `4` | Number of mix relay nodes |
| `SIM_BASE_TCP_PORT` | `60001` | First node's TCP port (increments per node) |
| `SIM_BASE_DISC_PORT` | `9001` | First node's discv5 UDP port (increments per node) |
| `SIM_CLUSTER_ID` | `99` | Waku cluster ID |
| `SIM_LOG_LEVEL` | `INFO` | Node log level (TRACE, DEBUG, INFO, WARN, ERROR) |
| `SIM_CHAT_RECV_PORT` | `60010` | Chat receiver TCP port |
| `SIM_CHAT_SEND_PORT` | `60011` | Chat sender TCP port |
| `SIM_KADEMLIA_MIN_WAIT` | `30` | Minimum seconds to wait for kademlia propagation |
| `SIM_RECEIVER_MIN_WAIT` | `15` | Minimum seconds to wait for receiver to join mix |
| `SIM_DELIVERY_TIMEOUT` | `120` | Max seconds to wait for message delivery |

Example — fast iteration with verbose logging:

```bash
SIM_LOG_LEVEL=TRACE SIM_KADEMLIA_MIN_WAIT=10 SIM_RECEIVER_MIN_WAIT=5 \
  bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

## `--fresh` behavior

When `--fresh` is passed:
- Kills all existing `logos_host` processes
- Cleans `/tmp/logos_*` Qt RemoteObjects sockets
- Removes `.sim_state/` directory
- Removes sequencer state (`rocksdb/`, `bedrock_signing_key`)
- Rebuilds and restarts the sequencer
- Redeploys RLN programs via `run_setup`

Without `--fresh`, reuses existing sequencer if port 3040 is already bound.

## Troubleshooting

**Re-run with fresh state:**
```bash
bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

**"Sequencer failed to start"** — port 3040 already in use:
```bash
kill $(lsof -ti tcp:3040) && bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

**"run_setup failed" / "Timeout waiting for account"** — stale guest binaries or wallet state:
```bash
rm -rf vendor/logos-lez-rln/lez-rln/methods/guest/target
rm -f vendor/logos-lez-rln/dev/wallet_config.json vendor/logos-lez-rln/dev/storage.json
bash simulations/mix_lez_chat/setup_and_run.sh
```

**"Sender started FAIL"** — stale Qt RemoteObjects sockets:
```bash
rm -f /tmp/logos_*
bash simulations/mix_lez_chat/run_simulation.sh --fresh
```

Docker logs are rescued to `./docker-sim-logs/` on failure.

## Adapting for other LEZ programs

This simulation provides a complete mix network infrastructure that other logos modules can reuse for testing. To test your own module:

### What the sim provides
- 4 logoscore mix nodes with `delivery_module` (Waku relay + mix + RLN)
- LEZ sequencer with deployed RLN programs
- RLN gifter service on node 0
- Wallet modules for on-chain transactions

### What you replace
The chat_module sender/receiver instances (phase 5 of run_simulation.sh). Your module needs:

1. **A C++ Qt plugin** implementing `PluginInterface` (see `chat_module_plugin.cpp`)
   - `initLogos(LogosAPI*)` — receive the LogosAPI instance
   - `eventResponse(QString, QVariantList)` signal — mandatory per logos-liblogos contract
   - Methods exposed via `LOGOS_METHOD` for logoscore `-c` invocation
2. **A shared library** with your program logic (like `liblogoschat.so`)
3. **RLN integration** — wire `setRlnConfig` to pass RLN credentials from the C++ plugin to your library
4. **EVENT: stderr fallback** — on Linux, Qt signal forwarding from plugin to logoscore doesn't work across the FFI thread boundary. Write event data to stderr in `EVENT:name:data` format (gated by `LOGOS_EVENT_STDERR` env var) for cross-platform reliability.

### How to stage your module

```bash
MDIR=$(mktemp -d)
mkdir -p "$MDIR/your_module"
cp your_module_plugin.so "$MDIR/your_module/"
cp libyour_library.so "$MDIR/your_module/"
echo '{"name":"your_module","version":"1.0.0","type":"core",...}' > "$MDIR/your_module/manifest.json"

logoscore -m "$MDIR" \
  -l "liblogos_execution_zone_wallet_module,liblogos_rln_module,your_module" \
  -c "liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)" \
  -c "your_module.init(@config.json)" \
  -c "your_module.start()"
```

### Reference
- `chat_module_plugin.cpp` — complete working example with RLN, gifter, mix, and event emission
- `delivery_module_plugin.cpp` — more complex example with full RLN fetcher integration
- `run_simulation.sh` — orchestration, module staging, and verification patterns

## Logs

All logs in `simulations/mix_lez_chat/.sim_state/`:
- `node0.log` – `node3.log` — mix relay nodes
- `chat_receiver.log` — receiver chat module
- `chat_sender.log` — sender chat module
- `sequencer.log` — LEZ sequencer

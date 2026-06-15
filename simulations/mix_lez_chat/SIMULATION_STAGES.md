# Mix + LEZ RLN Chat Simulation — Stage-by-Stage Notes

Working notes for the full simulation pipeline (`run_simulation_lgx.sh` and the
`demo_step.sh` wrapper). Each stage lists the components involved, the processes
that occur, and how success/failure is determined. Line references point at
`run_simulation_lgx.sh` unless otherwise noted.

This file is the deep-dive reference. Setup and operating instructions live in
`README.md`. Read this when something's broken and you need to know which stage
owns the failure.

---

## Stage 0 — Workspace & prerequisites

**Components**
- `logos-chat` (this repo) — chat library (`liblogoschat`), sim scripts.
- `vendor/logos-lez-rln` — umbrella submodule: `lez-rln` (Rust RLN programs +
  `run_setup`), `lssa` (sequencer + wallet), `logos-execution-zone-module`
  (wallet C++ module), `logos-rln-module` (RLN C++ module),
  `logos-delivery-module` (delivery C++ module).
- `logos-delivery-module/vendor/logos-delivery` — Nim Waku/mix stack
  (`liblogosdelivery`). NOT a real submodule (`vendor/*` is gitignored there);
  auto-cloned from `DELIVERY_REPO`/`DELIVERY_BRANCH` on first run (~line 562).
- Toolchains: nix (flakes), cargo + risc0 (`RISC0_DEV_MODE=1` is exported),
  Nim (via nimbus-build-system), Qt (logoscore), Docker (Linux path).

**Processes**
- `--fresh` removes `.sim_state/`; always: `pkill logos_host`, remove stale
  `/tmp/logos_*` QtRO sockets (~line 320) — stale LocalServer sockets
  confuse capability_module lookups.
- Repo discovery: `LEZ_RLN_DIR`, `CHAT_MODULE_DIR`, `DELIVERY_MODULE_DIR`
  resolved from vendored paths or siblings (~lines 16-30).
- `setup_from_scratch.sh` is sourced at the top of the script (~line 43)
  so the per-build prep helpers (`patch_delivery_nimble_lock`,
  `rename_libp2p_carcass`, `mirror_chat_nimbledeps`) are available to
  the auto-build blocks in Stage 3. Each helper is idempotent — sourcing
  defines them; calling them is a no-op once the per-step gate is satisfied.

**Success / failure**
- Hard `die` if `logos-lez-rln` can't be found.
- Failure symptom of skipping the socket cleanup: "Sender started FAIL" /
  client hangs at connect.

---

## Stage 1 — Sequencer (local) or reachability probe (testnet)

**Components**: LSSA `sequencer_service` (Rust, port 3040) — local only;
`https://testnet.lez.logos.co/` for testnet.

**Processes** (lines 324-369)
- **Testnet**: single `getLastBlockId` JSON-RPC probe with 10s timeout. No
  local sequencer at all.
- **Local**: reuse a sequencer already bound to 3040 (unless `--fresh`);
  otherwise wipe `lssa/rocksdb` + `bedrock_signing_key`, then run a pre-built
  `target/debug/sequencer_service` or build it (`cargo build --features
  standalone -p sequencer_service`). Before building, the script pins `lssa`
  to the rev in `lez-rln/Cargo.toml` — wire-format divergence between the
  host client and sequencer otherwise yields `DeserializeUnexpectedEnd`.
- Local blocks ~15s; testnet ~60-90s + finality lag. All later timing floors
  branch on this (lines 257-273).

**Success / failure**
- Testnet: `"result"` in the probe response, else fail-fast `die` (avoids
  10+ min of setup against a dead RPC).
- Local: port 3040 answers within 60s, else `die "Sequencer failed to start"`.
- Log: `.sim_state/sequencer.log`.

---

## Stage 2 — Building & deploying the LEZ RLN programs

**Components**: `lez-rln/run_setup` (Rust binary), registration + merkle SPEL
programs (`#[lez_program]`, Borsh state, PDA derivation via `combine_seeds`),
wallet storage under `dev/` (local) or `testnet/` (persistent).

**Processes** (lines 371-441; `run_setup.rs`)
- Wallet home selection: `NSSA_WALLET_HOME_DIR=vendor/logos-lez-rln/{dev|testnet}`.
  Local wipes `wallet_config.json`/`storage.json` each run (unless
  `SIM_PERSIST_LOCAL=1`); testnet persists.
- Testnet first-run seeding: `storage.json.seed` → `storage.json`,
  `supply_holding.txt` → `~/.logos-lez-rln/supply_holding_<tree>.txt`,
  optional `payment_account.txt` sidecar (lines 392-410). This shares the
  canonical deployment (TREE_ID `...e26e`, program IDs, minted supply) so
  fresh clones never redeploy.
- `run_setup` branches on `is_initialized()`:
  - **First run (local fresh)**: deploy both programs, create RLNTOK token,
    initialize the tree, fund a payment account (10B RLNTOK ≈ 10K
    registrations at rateLimit=100).
  - **Already initialized (testnet, or local re-run)**: short-circuit to
    `create_funded_user` — derive a fresh payment account, transfer funding
    from supply_holding.
- Outputs parsed from stdout: `Config account:` → `CONFIG_ACCOUNT`; the
  payment account sidecar → `GIFTER_ACCOUNT`.
- **Slim mode** (`SIM_SLIM=1`, testnet only): skip `run_setup` entirely when
  the shipped `config_account.txt` + cached `payment_account_<tree>.txt`
  exist — avoids building lez-rln Rust at all (lines 417-426).
- EIP-191 gifter auth fixtures sourced from `fixtures/gifter_auth/`
  (secp256k1 keys + allowlist of mix1-3, sender, receiver, receiver2 addresses).

**Caveats: local vs testnet**
- Fresh-tree deployment **against testnet with a new wallet silently fails**
  (txs hash but never apply) — fresh-tree needs admin bootstrap; always use
  the shipped tree pins.
- `run_setup` **binary drift**: if `target/debug/run_setup` is older than
  source, local `--fresh` fails at register_member with wallet
  `KeyNotFoundError`. Rebuild the binary; don't chase root-propagation timing.
- All slim-mode runs share one payment account → concurrent runs race on its
  nonce. Serial use only.

**Success / failure**
- `run_setup` non-zero exit or unparsable `Config account:` → `die`.
- Missing `GIFTER_ACCOUNT` sidecar → `die`.
- Testnet drift symptoms (`KeyNotFoundError`, account-init timeout,
  `register_member failed`, "gifter dial failed after 5 attempts") → wipe
  `~/.logos-lez-rln/payment_account_*` + `~/.nssa/wallet` and let run_setup
  re-fund (see README "If it fails").

---

## Stage 3 — Building the logos-core modules & .lgx packages

**Components**
- `logoscore` CLI — `nix build github:logos-co/logos-logoscore-cli` (~line 470).
- Four `.lgx` bundles via `nix bundle --bundler nix-bundle-lgx`:
  - **wallet** (`logos_execution_zone`) — built with `--override-input` chain:
    local `logos-execution-zone-module` (carries the `send_public_transaction`
    Q_INVOKABLE that register_member needs) + local `lssa` (carries
    `SequencerClientBuilder::request_timeout(...)` — without it a stuck
    sequencer response `block_on()`s forever inside FFI, freezing the wallet
    Qt thread and cascading into delivery_module's chronos loop).
  - **rln** (`liblogos_rln_module`) — the C++ bridge whose `get_merkle_proofs`
    / `get_valid_roots` RPCs the spam-protection plugin polls.
  - **delivery** (`delivery_module`) — C++ plugin over Nim `liblogosdelivery`.
  - **chat** (`chat_module`) — C++ plugin over Nim `liblogoschat`.
- Nim shared libs built outside nix: `make liblogosdelivery` (in
  vendor/logos-delivery; auto-clone first if missing) and `make liblogoschat`
  (this repo). They're injected post-install because nix-bundle-lgx drops
  `metadata.json:include[]` libs (~lines 530-600).

**Processes**
- `.lgx` outputs are pinned under `LGX_CACHE_DIR` (`~/.cache/sim-lgx`) as
  indirect nix GC roots; cache hit skips `nix bundle` (~10 min → ~5 s).
  `SIM_REBUILD_LGX=1` invalidates after source edits (~lines 480-510).
- Per-module env overrides `WALLET_LGX`/`RLN_LGX`/`DELIVERY_LGX`/`CHAT_LGX`
  short-circuit to a known-good store path — the crates.io 403 workaround.
- `pick_lib_with_min_symbols` guards against stale 8-symbol
  `liblogosdelivery` builds in /nix/store (would load but fail at first FFI
  call); the local vendor build is preferred because nix-store builds lack
  the gifter mount code (→ 14/15 PASS ceiling).

**Auto-build prep helpers (PR #3807 transition)**
Before invoking `make liblogosdelivery` and `make liblogoschat`, the script
calls helpers defined in `setup_from_scratch.sh`:
- `patch_delivery_nimble_lock` — patches `vendor/logos-delivery/nimble.lock`
  in place to work around a nimble 0.22.3 URL-mangling bug on two `#`-prefix
  package versions PR #3807's lockfile ships with. Idempotent; greps for the
  original sha1s before patching. Local-only edit; never committed upstream.
- `rename_libp2p_carcass` — moves the stale
  `vendor/nwaku/vendor/nim-libp2p` checkout aside. PR #3807 dropped the
  submodule but the directory lingers in pre-PR-3807 working clones; the
  chat's `config.nims` walker would otherwise pick it up before the
  nimble-resolved v2.0.0 libp2p and compile would fail with
  `EVP_PKEY undeclared`.
- `mirror_chat_nimbledeps` — mirrors `nimbledeps/pkgs2/` from the
  delivery-side build (where `make liblogosdelivery` populated it) into
  `vendor/nwaku/` and strips the obsolete-pin libp2p/websock variants.
  Required so the chat's nim build can resolve nwaku's nimble deps via
  the search path.

**`librln_mix` (PR #9 stateless rebuild)**
- The chat Makefile no longer builds its own `librln_mix_v2.0.0.a` via
  `vendor/nwaku/scripts/build_rln_mix.sh`. It instead copies the prebuilt
  `vendor/logos-lez-rln/logos-delivery/librln_v2.0.2.a` (a side product of
  step 2's `nix build .#logos-rln-module`) into
  `build/librln_mix_v2.0.2.a`, then runs
  `scripts/fix_mix_librln_dupes.sh` to localize cross-archive symbols
  shared with `rust-bundle` (Rust std `_rust_eh_personality`,
  `_ffi_c_string_free` from libchat's double-ratchets — also the reason
  rust-bundle no longer imports `rln`).

**Success / failure**
- Each `nix bundle` failure → `die`. Missing dylib (17-symbol delivery lib,
  chat lib) → `die`. All four `.lgx` must exist (~line 605).
- Known failure: crates.io 403 on `librln-mix-2.0.0-vendor-staging` → use the
  `.lgx` env pins or populate the vendor-staging path manually.

---

## Stage 4 — Starting logoscore instances & sending them commands

**Components**: `logoscore` daemon (`-D`) per instance, `logos_host_qt`
subprocesses per loaded module, QtRO local sockets, the `call` subcommand.

**Process model** (`start_logoscore_instance`, lines 94-212) — every instance
(mix node or chat client) follows the same lifecycle:
1. **Stage modules**: `install_lgx` extracts each bundle's `manifest.json` +
   the current platform variant into a temp modules dir; `install_extra_lib`
   drops the Nim dylib next to the plugin (resolved via `@loader_path`).
2. **Launch daemon** under an isolated `LOGOSCORE_CONFIG_DIR`, via `env -i`
   with a minimal env. `DYLD_INSERT_LIBRARIES` preloads the Nim dylib —
   plugins are built `-undefined dynamic_lookup` so dyld can't resolve their
   flat-namespace symbols at dlopen otherwise; `env -i` is required or Qt's
   QProcess sanitization strips `DYLD_*`.
3. **Two-phase readiness**: wait for `client/config.json` to exist AND
   `list-modules` to report `capability_module` loaded, then a fixed 5s
   settle (RPCs in the first ~3s after capability-loaded hang past 30s).
4. **Load modules in order** (`load-module`, 30s timeout each): wallet →
   rln → delivery|chat. Order satisfies inter-module deps.
5. **Dispatch calls** via `logoscore call <module> <method> <args>` (NOT the
   top-level `-c`, which spawns a separate daemon). 180s timeout per call
   (`CALL_TIMEOUT`). Failures log-and-continue — see expected-failure note.

**Gotchas encoded in the harness**
- TMPDIR must match between daemon and client (Qt LocalSocket path) — both
  sides unset it (lines 99-106).
- Log files use `:>` + append-only `>>` on both daemon and client fds —
  a plain `>` daemon fd would overwrite the client's interleaved JSON.
- logoscore-cli auto-coerces digit-leading args to int/qulonglong; any
  digit-leading non-numeric arg is wrapped as `@tmpfile` (lines 188-198), and
  JSON-blob variants (`selfRegisterRlnJson`, `sendMessageJson`) exist
  specifically to dodge this.

**Success / failure**
- Per-call success marker: a JSON line `{"status":"ok", ...}` in the
  instance log; `wait_method_calls` greps a count threshold.
- **Expected failure**: `call failed: delivery_module.start()` is by design —
  start()'s async backend (gifter registration + on-chain watcher) keeps the
  Qt thread busy past the ~20s QtRO reply ceiling even though the node
  started fine. Diagnose via `"Node started successfully"` in the log +
  subsequent call counts, never via this RPC error.

---

## Stage 5 — Mix node bring-up (Phase 4, lines 593-788)

**Components**: 4 logoscore instances, each loading
`logos_execution_zone → liblogos_rln_module → delivery_module`. Fixed
identities: per-node `NODEKEYS`/`PEER_IDS` (libp2p) and
`MIXKEYS`/`MIX_PUBKEYS` (sphinx). Node 0 = gifter + bootstrap peer.

**Per-node config** (`node<i>_config.json`): cluster 99, 1 shard, ports
60001+/9001+, relay+lightpush+filter+mix all on, `mixOnchainLEZ: true`,
static peers = all other nodes, kademlia bootstrap = node 0.
- Node 0 gets `mixGifterService: true` + wallet account + allowlist.
- Nodes 1-3 get `mixGifterNode` (node 0's multiaddr) + per-node EIP-191
  auth key (`KEY_MIX1..3`).

**Call sequences**
- **Node 0 (gifter)**: `open(wallet)` → `createNode(@config)` → `start()` →
  `sync_to_block(<chain head>)` → `selfRegisterRlnJson(@{config,wallet,rate:100})`
  → `subscribe(topic)`. Six expected ok-calls. The explicit sync is needed
  because `open()` leaves `last_synced_block=0`; register_member can't build
  a valid tx otherwise. Self-registration pays from the gifter account and
  is what lets the gifter service mount.
- **Nodes 1-3**: `open(wallet)` → `createNode(@config)` →
  `setRlnConfig(CONFIG_ACCOUNT, 0)` (placeholder leaf — pre-start!) →
  `start()` → `subscribe(topic)`. Five expected ok-calls. Registration itself
  happens **automatically inside Nim startNode()** via the gifter protocol;
  the sim must NOT call setRlnConfig with a real leaf for them.

**Why the placeholder setRlnConfig before start()** (lines 724-764): it
installs the C++→Nim rln_fetcher trampoline while the Qt loop is still
responsive. After start(), chronos saturates Qt and delivery_module RPCs hang
forever. Without the trampoline, the spam-protection pollLoop gets "RLN
fetcher not registered", `cachedProof` never lands, `isReady()` stays false,
and every sphinx hop fails "Plugin not ready".
**Node 0 is excluded**: a pre-start leaf=0 flips `membershipIndex` to Some(0)
(the `>= 0` check in `setRlnIdentity`), which suppresses the gifter
self-register asyncSpawn — gifter would mount but own no on-chain credentials
("RLN config not set on gifter node" for every client dial).

**Success / failure**
- Per node: `wait_method_calls` reaches 6 (node 0) / 5 (nodes 1-3) within 90s,
  else a WARNING (not fatal — verification catches real breakage).
- `NODE_STARTUP_SLEEP` (10s local / 30s testnet) staggers startups; the
  gifter serializes registrations through a single-writer worker, so
  simultaneous arrivals just queue.

---

## Stage 6 — Readiness gate: gifter registrations + RLN convergence

**Components**: node logs as ground truth; gifter status codec
(`/logos/rln/membership/status/1.0.0`); LEZ pollLoops on every node.

**Processes** (lines 793-823)
- Loop until ALL of:
  - elapsed ≥ `KADEMLIA_MIN_WAIT` (30s local / 120s testnet),
  - node 0 logged ≥3 `RLN gifter registration succeeded` (nodes 1-3),
  - node 0 logged ≥1 `Gifter self-registered as mix relay`,
  - ≥40 LEZ root events across nodes (`Polled valid roots` etc.).
- Hard cap `KADEMLIA_HARD_CAP` (180s local / 1800s testnet) breaks the loop
  regardless — testnet RLN confirmations can take minutes per node.
- Mix routing does NOT depend on kademlia (pool is seeded from `mixNodes`
  config); the kad-peer count is diagnostic only.

**What "registration" entails per node** (the gifter protocol):
1. Client dials node 0 on `/logos/rln/membership/1.0.0` with an EIP-191
   signature over its identity commitment (key must be in the allowlist).
2. Gifter's single-writer worker submits `register_member` on-chain from the
   gifter wallet, **awaiting chain confirmation between jobs** (avoids
   per-signer nonce collisions; see `MODE_A_GIFTER_SLOT_BUG.md`).
3. Gifter replies with (configAccount, leafIndex, idCommitment...).
4. A background watcher on the client polls the status codec until the
   membership PDA materialises on-chain, and **corrects the leaf index** if a
   concurrent registration won the optimistic slot.

**Success / failure**
- Gate pass logged as `Kademlia ready after Ns (3/3 client regs, self=1, ...)`.
- Timing out at the hard cap is non-fatal but almost always means downstream
  delivery failure (unregistered hops drop sphinx packets).

---

## Stage 7 — Chat clients (Phase 5)

**Components**: receiver + sender (optionally receiver2) logoscore instances,
loading `logos_execution_zone → liblogos_rln_module → chat_module`. The chat
stack: X3DH key agreement, double-ratchet encryption, mix client, Waku filter.

**Receiver** (lines 859-941)
- Calls: `open(wallet)` → `initChat(@config)` → `setEventCallback()` →
  `startChat()` → `createIntroBundle()` (5 expected ok-calls).
- `startChat()` internally: starts the Waku client, registers via gifter
  (using `gifterNodeAddr` + `gifterAuthKey` from config), mounts mix, sets up
  the filter subscription.
- The **intro bundle** (X3DH prekey bundle, `logos_chatintro_1_…`) is
  scraped from the log: the module logs it as a decimal byte array which the
  sim decodes (lines 916-923).
- Join gate: `Waku client started` in log + `RECEIVER_MIN_WAIT` floor
  (15s/60s) so the filter subscription propagates through the relay mesh.

**Sender** (lines 1108-1226)
- First batch: `open` → `initChat` → `setEventCallback` → `startChat` ONLY.
  `newPrivateConversation` is deliberately deferred.
- **Membership confirmation wait**: poll the sender log for `membership
  confirmed on-chain` (up to 600s local / 3600s testnet). Reason: the
  mix-side spam-protection plugin is only `isReady()` once confirmation lands
  AND the next pollLoop tick caches the merkle proof; publishing earlier hits
  "Failed to generate spam protection proof" with the message silently
  dropped.
- **+60s cushion** after confirmation so all mix nodes' pollLoops converge
  their valid_roots windows on the post-registration tree state (the
  self-verify "Expected one of the provided roots" race lives here).
- **Explicit RLN fetcher wiring**: extract (configAccount, leafIndex) from the
  `Registered via RLN gifter` log line and call
  `chat_module.setRlnConfig(@acct, leaf)` — the gifter-only flow doesn't
  install the C++ rln_fetcher trampoline by itself. Then +25s for the
  deferred valid_roots subscription + one poll cycle.

**Message exchange**
- `newPrivateConversation(@bundle, @msgHex)` — test payload is prefixed with
  byte `0xff` so the hex string starts with 'f' (dodges arg auto-coercion).
  Retried up to `SIM_NPC_RETRIES` (default 2) on
  `Mix lightpush timed out` / `no SURB reply`; each retry creates a fresh
  convoId and the receiver accepts whichever handshake lands. Success marker:
  `Message sent via mix successfully` within ~100s of dispatch.
- **Extras**: `SIM_EXTRA_MESSAGES=N` sends N more via
  `sendMessageJson(@{convoId, contentHex})` (JSON variant required —
  digit-leading convoIds get qulonglong-coerced otherwise), spaced
  `SIM_EXTRA_MESSAGE_GAP` (5s) apart to respect RLN rate-limit windows.
- **Replies**: `SIM_REPLY_MESSAGES=N` has the receiver send N messages back
  on the same convoId (receiver→sender direction), then waits for the sender
  to log the corresponding chat events.
- **Receiver2** (`SIM_RECEIVER2=1`): a second NPC from the sender to
  receiver2's bundle — demonstrates RLN membership reuse across conversations.

**The mix publish path (what one message entails)**
1. Sender's chat module encrypts (double-ratchet), publishes via
   `lightpushPublish(mixify=true)`.
2. Entry: a 3-hop sphinx route is selected from the mix pool; SURBs are
   created for the reply path; the sender's spam-protection plugin generates
   an RLN proof bound to the outgoing packet and **self-verifies** it before
   forwarding (`spam_protection.nim:404`) — fail here means local drop.
3. Each intermediate hop: verifies the inbound proof (epoch gap, merkle root
   in its own valid_roots window, zkSNARK, nullifier log for double-signal),
   peels its sphinx layer, holds the packet for the sampled delay while
   generating a **fresh proof for the next hop** (proof gen runs sync inside
   `allFutures(proofGenFut, delayFut)`, `mix_protocol.nim:418`), forwards.
4. Exit node fans out via lightpush into the relay mesh.
5. Receiver's filter subscription delivers; chat module decrypts and emits
   `chatNewMessage` (mirrored to stderr as `EVENT:` lines via
   `LOGOS_EVENT_STDERR=1` — Qt signal forwarding doesn't cross the FFI thread
   boundary on Linux).
6. SURB reply confirms round-trip to the sender (60s deadline, widened from
   15s). **Forward delivery is independent of the SURB reply** — a SURB
   timeout does not imply the receiver missed the message.

**RLN data flow underneath (per node, continuous)**
- `OnchainLEZGroupManager.pollLoop` (10s interval): fetch valid roots; for
  membership holders, fetch `(pathElements, root, validRoots)` from the RLN
  module's `get_merkle_proofs` in one RPC and atomically reset cachedProof +
  rootTracker together (`onchain_group_manager.nim:204-217`).
- The C++ side (`logos_rln_module.cpp:571-724`) assembles that response from
  4 separate `get_account_public` reads (config, main, subtrees, main-refetch)
  — **non-atomic**; a registration landing mid-fetch (or a poll iteration
  stalled by slow RPCs serving a mid-churn snapshot) can yield a proof whose
  path-implied root is in no validRoots window → self-verify failure →
  packet drop. Known open issue; fixes under discussion: stable-snapshot
  loop + path-implied-root self-check server-side, cachedProof age stamp
  client-side.

**Success / failure**
- Sender: ok-calls ≥4, `Registered via RLN gifter` + `Waku client started`,
  membership confirmed, NPC success marker.
- Receiver: delivery loop counts `chatNewMessage|chatNewConversation` events
  until ≥ `1 + SIM_EXTRA_MESSAGES` or `SIM_DELIVERY_TIMEOUT` (240s local /
  300s testnet; use 1800 for testnet runs — the gifter queue puts the sender
  last, see README).

---

## Stage 8 — Verification (Phase 6, lines 1415-1520)

All checks are **log greps** against `.sim_state/*.log` (ANSI-stripped).

**Demo mode** (`SIM_DEMO_MODE=1`, set by `demo_step.sh`) — 4 markers:
| # | Marker | Grep | Log | Meaning |
|---|---|---|---|---|
| 1 | Gifter received request | `handling RLN gifter request` | node0 | gifter codec dial + auth passed |
| 2 | Sender got membership | `RLN membership granted\|Registered via RLN gifter` | sender | full gifter round-trip incl. on-chain tx |
| 3a | Proofs generated | `Generated RLN proof successfully` ≥1 | nodes 0-3 | at least one hop wrapped a packet (implies sender publish reached mix) |
| 3b | Proof verified | `Proof verified successfully` ≥1 | nodes 0-3 | a hop accepted another node's proof (epoch+root+zkSNARK+nullifier all passed) |

PR #9 (mix-rln plugin stateless backend) renamed the verification log line —
the old `Spam protection proof verified successfully` is now just
`Proof verified successfully`. The sim's grep accepts the new form.

`DEMO PASS: all 4 markers fired` → exit 0. Markers 3a/3b at 0 with 1+2
passing = the self-verify / proof-staleness class of failure (sender's first
publish died locally).

**Full mode** — the 15-check block:
- 4× `Node i mounted mix` (`mounting mix protocol`) — delivery_module came up
  with mix enabled.
- `Node 0 gifter service mounted` — self-registration succeeded (this is the
  check that fails if the placeholder-leaf bug suppresses self-register).
- `LEZ RLN active` — ≥1 root event across nodes (pollLoops running).
- Receiver/sender `initialized` (`Chat context created`), `started`
  (`Waku client started`), `mounted mix+LEZ` (`Wired LEZ callbacks`).
- `Receiver created intro bundle` (`IntroBundleCreated`).
- `Sender sent message` (`Message sent via mix`).
- `Receiver received message` — count ≥ `DELIVERY_EXPECTED`; the only check
  that proves full E2E forward delivery.
- (+3 receiver2 checks when enabled.)

Exit 0 iff zero FAILs. A 14/15 with only receiver-delivery failing typically
means a stale `liblogosdelivery` (no gifter mount) or the mix-publish race;
local runs are deterministic (typically 16/16 messages), testnet runs are
non-deterministic (slot allocation, confirmation, circuit timing).

---

## Quick failure-triage index

| Symptom | Stage | Likely cause |
|---|---|---|
| `Testnet unreachable` | 1 | RPC down / network |
| `DeserializeUnexpectedEnd` | 1 | lssa rev mismatch vs lez-rln pin |
| `KeyNotFoundError` at register_member | 2 | stale run_setup binary or stale payment-account sidecar |
| `supply holding may be out of funds` | 2 | stale sequencer process / state from prior run — kill `lssa`/`sequencer` + wipe `lssa/rocksdb` + `dev/storage.json` |
| txs hash but state never changes | 2 | fresh-tree-on-testnet bootstrap gap — use shipped tree |
| `nimble setup` fails on `bearssl_pkey_decoder` with `git -C ... init failed` | 3 | nimble 0.22.3 URL-mangling bug — `patch_delivery_nimble_lock` handles this; if reached manually, see `setup_from_scratch.sh` |
| `Error: cannot open file: brokers/broker_context` | 3 | chat's nim path doesn't see nwaku's nimble deps — `mirror_chat_nimbledeps` handles this |
| `EVP_PKEY undeclared` in libp2p `certificate_ffi.nim` | 3 | OLD libp2p carcass shadowing the nimble-resolved v2.0.0 — `rename_libp2p_carcass` handles this |
| `duplicate symbol _rust_eh_personality` at link | 3 | librln_mix + rust-bundle each embed their own Rust std — `scripts/fix_mix_librln_dupes.sh` localizes runtime symbols including the rcgu objects system nm can't parse |
| `nix bundle` 403 | 3 | crates.io rate limit → `.lgx` env pins |
| `symbol not found: _logosdelivery_*` | 3/4 | Nim dylib missing/stale (8-symbol build) |
| client hangs at connect, no diagnostic | 4 | TMPDIR mismatch or stale `/tmp/logos_*` |
| `call failed: delivery_module.start()` | 5 | **expected** — Qt loop blocked; check `Node started successfully` |
| `RLN fetcher not registered` / `Plugin not ready` | 5 | trampoline not installed pre-start |
| `RLN config not set on gifter node` | 5 | gifter self-register suppressed (placeholder-leaf ordering bug) |
| gifter dial failed after 5 attempts | 5/6 | WALLET_LGX missing request_timeout patch, or node 0 frozen |
| `Self-verify ... Expected one of the provided roots` | 7 | RLN proof/window staleness (get_merkle_proofs non-atomicity / stalled pollLoop) |
| `Mix lightpush timed out` | 7 | SURB reply missed 60s deadline; forward path may still have delivered |
| markers 1+2 pass, 3a/3b zero | 8 | sender's first publish dropped locally (proof gen/self-verify) |
| marker 3b shows 0 despite plenty of generations | 8 | if grepping logs manually with the legacy `Spam protection proof verified successfully`, switch to `Proof verified successfully` — PR #9 renamed it |

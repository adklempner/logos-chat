# Mix LEZ-RLN sim — setup from a fresh clone

End-to-end reproduction of the `demo_step.sh` 4/4 PASS on the rebased
chat-over-mix stack (nim-libp2p v2.0.0 + zerokit 2.0.2 stateless +
PR #3807 DoS + cover traffic + LEZ-RLN gifter).

Tested on macOS 15 (arm64).

## TL;DR

After cloning + initializing submodules, the entire bootstrap is
automated by `setup_from_scratch.sh` (each step is idempotent —
re-running is a no-op):

```bash
git clone -b rebase/sim-rln-gifter-on-new-stack \
  git@github.com:adklempner/logos-chat.git
cd logos-chat
git submodule update --init --recursive

bash simulations/mix_lez_chat/setup_from_scratch.sh
bash simulations/mix_lez_chat/demo_step.sh
```

The bootstrap takes ~30 min on a fresh clone (most of it is the RISC0
guest build the first time around) and seconds on subsequent invocations.

`run_simulation_lgx.sh` also sources `setup_from_scratch.sh` and calls
the per-build helpers from its auto-build paths, so `demo_step.sh` alone
will also do the right thing if you skip the explicit bootstrap step.

The rest of this doc is a manual-step reference for debugging when the
automated path falls over.

## Prerequisites

| Tool | Notes |
|---|---|
| `git` | with SSH access to github.com |
| `nix` | with flakes enabled |
| Docker | for RISC0 zkVM guest build (one-time) |
| Rust toolchain | stable + nightly via rustup; `cargo-risczero` installed |
| `nim` 2.2.4 + `nimble` 0.22.3 | the chat/delivery Makefiles will install these locally if missing |
| `cmake` + `ninja` + `pkg-config` | for the C++ delivery_module plugin build |
| Qt 6.9.2 (qtbase + qtremoteobjects + qttools) | comes via the `logoscore` nix build |

## Branch refs

| Repo | Branch | Tip |
|---|---|---|
| `adklempner/logos-chat` | `rebase/sim-rln-gifter-on-new-stack` | `1adde6c` |
| `adklempner/logos-delivery` | `rebase/lez-rln-gifter-on-3807` | `81dd0b3` |
| `logos-co/logos-lez-rln` | `feat/rln-stateless-v2.0.2` | `cbac992` |
| `adklempner/mix-rln-spam-protection-plugin` | `feat/lez-rln-stateless` | `ba32e9f` |

## 1 — Clone + initialize submodules

```bash
git clone -b rebase/sim-rln-gifter-on-new-stack \
  git@github.com:adklempner/logos-chat.git
cd logos-chat
git submodule update --init --recursive
```

Submodule pointers already track the right branches via `.gitmodules`;
recursive init brings down `vendor/nwaku`, `vendor/logos-lez-rln`,
`vendor/libchat`, and the nested `vendor/nwaku/vendor/zerokit` +
`vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery`
working clones.

## 2 — Build the lez-rln side modules (nix)

These produce the wallet, RLN, and execution-zone modules consumed by
the sim's logoscore process.

```bash
cd vendor/logos-lez-rln
nix build .#logos-rln-module -o logos-rln-module/result-rln
(cd logos-execution-zone-module && \
  RISC0_SKIP_BUILD_KERNELS=1 nix build --impure \
    --override-input logos-execution-zone "git+file://$(pwd)/../lssa" \
    -o ../logos-rln-module/result-wallet)
```

The RISC0 guest binaries needed by the wallet build are produced
automatically — first invocation takes ~10 min while it pulls the
Docker-based RISC0 toolchain.

## 3 — Build the Rust setup binaries

```bash
# still inside vendor/logos-lez-rln
(cd lez-rln && cargo build --bin run_setup --bin register_member \
                           --bin register_commitments --bin get_roots)
```

These are debug binaries the sim's `run_setup` step invokes via the
shell.

## 4 — Build liblogosdelivery (the delivery .dylib)

```bash
cd vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery
```

### 4a — One-time nimble workarounds

PR #3807's `nimble.lock` ships with two entries that nimble 0.22.3's
URL-handling layer fails to resolve on macOS. They have to be patched
in the local checkout (and **not** committed back):

```bash
# Patch the nim package sha1 to what nimble actually computes
sed -i.bak \
  's/68bb85cbfb1832ce4db43943911b046c3af3caab/a092a045d3a427d127a5334a6e59c76faff54686/' \
  nimble.lock

# Revert bearssl_pkey_decoder one commit (clang-15 fix only — semantically equivalent;
# the newer SHA triggers a nimble bug where the URL fragment with `#` mangles the temp
# dir nimble tries to clone into)
sed -i.bak \
  -e 's/d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368/21dd3710df9345ed2ad8bf8f882761e07863b8e0/g' \
  -e 's/8666edbcb77cb9f97c659114d57c4ba0e7ab74c3/bcfd6fc9c5e10a52b87117219b7ab5c98136bc8e/g' \
  nimble.lock

rm nimble.lock.bak
```

### 4b — Build

```bash
make liblogosdelivery
```

If nimble still chokes on a `#`-prefix package, the affected URL is
printed in the error. Manually clone that repo into
`nimbledeps/pkgs2/<name>-#<rev>-<sha>/` (the SHA fields come from
`nimble.lock`) and re-run `make liblogosdelivery` — nimble will skip
the failed download and pick up the pre-staged copy.

### 4c — Verify

```bash
nm -gU build/liblogosdelivery.dylib | grep -c "_logosdelivery_"
# expected: 17
```

The 5 LEZ-RLN-specific exports must be present:
`_logosdelivery_set_rln_fetcher`, `_set_rln_config`, `_set_rln_identity`,
`_push_roots`, `_push_proof`.

## 5 — Build liblogoschat (the chat .dylib)

```bash
cd $LOGOS_CHAT_DIR   # i.e. the top-level logos-chat working dir
```

### 5a — One-time vendor cleanup in `vendor/nwaku/`

PR #3807 dropped a swath of `vendor/nwaku/vendor/*` submodules in favor
of nimble deps, but the OLD libp2p carcass at
`vendor/nwaku/vendor/nim-libp2p/` lingers and gets picked up by the
chat's generic `config.nims` vendor walker, shadowing the nimble-resolved
v2.0.0 libp2p:

```bash
mv vendor/nwaku/vendor/nim-libp2p vendor/nwaku/vendor/nim-libp2p.STALE-PR3807
```

(Renaming rather than deleting keeps the carcass available for spelunking
if a build error mentions it; rename breaks the directory match nim does.)

### 5b — Stage nwaku's nimbledeps

The chat's nim build expects all nwaku deps reachable on the import path.
The simplest path: mirror the working `nimbledeps/pkgs2/` from the
delivery clone (which `make liblogosdelivery` populated in step 4):

```bash
cp -R vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery/nimbledeps \
      vendor/nwaku/

# The mirrored set still contains the previous-pin libp2p — remove it
# so the chat compile picks the v2.0.0 one from PR #3807.
rm -rf 'vendor/nwaku/nimbledeps/pkgs2/libp2p-#ff8d51857b4b79a68468e7bcc27b2026cca02996-fa2a7552c6ec860717b77ce34cf0b7afe4570234'

# Same for the previous websock pin.
rm -rf 'vendor/nwaku/nimbledeps/pkgs2/websock-0.3.0-1294a66520fa4541e261dec8a6a84f774fb8c0ac'
```

### 5c — Build

```bash
make liblogoschat
```

This pulls the prebuilt `librln_v2.0.2.a` from
`vendor/logos-lez-rln/logos-delivery/` (built as a side product of step 2),
copies it into `build/librln_mix_v2.0.2.a`, runs the
`scripts/fix_mix_librln_dupes.sh` dedup pass against
`rust-bundle/target/release/liblogoschat_rust_bundle.a`, then compiles
the chat library against the deduped archive.

### 5d — Verify

```bash
ls -la build/liblogoschat.dylib
# expected: ~39 MB arm64 dylib
```

## 6 — Build the C++ delivery_module plugin

The C++ plugin wraps `liblogosdelivery.dylib` and ships as the
`delivery_module_plugin.dylib` that logoscore dlopens.

```bash
cd vendor/logos-lez-rln
bash build_all.sh
```

`build_all.sh` finishes by running cmake against the delivery-module
checkout, picking up the dylib from step 4, and producing
`vendor/logos-lez-rln/logos-delivery-module/build_plugin/modules/delivery_module_plugin.dylib`.

## 7 — Run the sim

```bash
cd $LOGOS_CHAT_DIR
bash simulations/mix_lez_chat/demo_step.sh
```

### 7a — PASS condition

```
PASS: (1) Gifter service received request (5)
PASS: (2) Sender received valid RLN membership (2)
PASS: (3a) Mix nodes generated RLN proofs (≥1 total)
PASS: (3b) Proof verified by another mix node (≥1 total)

DEMO PASS: all 4 markers fired
```

A successful run produces ~6000 proof generations and ~5000 verifications
across the 4 mix nodes.

### 7b — Re-running

The sim's first step is "Sequencer" — if a prior sequencer process is
still alive, the new run reuses it (and inherits whatever supply-holding
state it has). For a fully fresh run:

```bash
pkill -f 'lssa|sequencer|logoscore' ; sleep 2
rm -rf vendor/logos-lez-rln/lssa/rocksdb \
       vendor/logos-lez-rln/dev/storage.json \
       simulations/mix_lez_chat/.sim_state
bash simulations/mix_lez_chat/demo_step.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make liblogosdelivery`: `nimble setup` fails on `bearssl_pkey_decoder` with `git -C ... init failed` | nimble 0.22.3 URL-mangling bug on `#`-prefix version pins | Apply step 4a workarounds; if needed, manually clone the failing dep into `nimbledeps/pkgs2/<name>-#<rev>-<sha>/` |
| `make liblogoschat`: `Error: cannot open file: brokers/broker_context` | chat's nim path doesn't see nwaku's nimble deps | Step 5b — mirror nimbledeps from delivery clone |
| `make liblogoschat`: `EVP_PKEY undeclared` in libp2p's `certificate_ffi.nim` | OLD libp2p carcass picked up before the nimble-resolved v2.0.0 | Step 5a — rename `vendor/nwaku/vendor/nim-libp2p` |
| `make liblogoschat`: `duplicate symbol _rust_eh_personality` | `librln_mix_v2.0.2.a` and the rust-bundle each embed their own Rust std | `scripts/fix_mix_librln_dupes.sh` should handle this; if it doesn't, verify `xcrun nm` is the macOS one (not a Homebrew GNU `nm` that can't parse rcgu objects) |
| sim: `FATAL: run_setup failed — supply holding may be out of funds` | stale sequencer from a previous run still alive | Step 7b — kill processes + wipe `lssa/rocksdb` + `dev/storage.json` |
| sim: `(3b) Proof verified by another mix node (0 total)` even though mix nodes are generating proofs | sim was grepping the legacy `Spam protection proof verified successfully` log line, replaced in PR #9 plugin with `Proof verified successfully` | Already fixed on the current `rebase/sim-rln-gifter-on-new-stack` tip; verify your checkout includes commit `707673f` or newer |

## Notes

- All four branches are forks; **no CI runs these** — local builds are
  the only verification path.
- The `nimble.lock` patches in step 4a are local-build-only and must
  not be committed (they exist solely as a workaround for nimble
  0.22.3's URL handling against PR #3807's lockfile).
- The dirty/untracked content under `vendor/logos-lez-rln/dev/`,
  `vendor/logos-lez-rln/vendor/`, etc. is sim-run debris from `run_setup`
  and the nix builds — safe to leave alone between runs.
- For the chat-side dylib swap to actually take effect, the sim script
  picks `DELIVERY_EXTRA_LIB` from
  `vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery/build/liblogosdelivery.dylib`
  whenever that path exists. If you rebuild the dylib in step 4, just
  re-run the sim — no further wiring needed.

#!/usr/bin/env bash
#
# Bootstrap a fresh logos-chat clone to the point where demo_step.sh can run.
# Idempotent — each step skips itself if already done. Safe to re-run.
#
# Source-able as well: if BASH_SOURCE != $0, the script defines the bootstrap
# functions without running them. run_simulation_lgx.sh calls these to keep
# its auto-build paths in sync with this canonical setup.
#
# Mirrors the manual sequence in SETUP_FROM_SCRATCH.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGOS_CHAT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEZ_RLN_DIR="$LOGOS_CHAT_DIR/vendor/logos-lez-rln"
DELIVERY_DIR="$LEZ_RLN_DIR/logos-delivery-module/vendor/logos-delivery"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
skip() { echo "[$(date '+%H:%M:%S')]   skipping — $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ---------- Step 4a — nimble.lock workarounds ----------
#
# PR #3807 ships a nimble.lock that hits a nimble 0.22.3 URL-mangling bug on
# `#`-prefix package versions. Two specific entries fail until patched. Both
# changes are semantically inert (nim package sha1 = recompute; bearssl_pkey
# revert = clang-15 compile-only delta). Apply locally; do NOT commit upstream.
patch_delivery_nimble_lock() {
    local lock="$DELIVERY_DIR/nimble.lock"
    [ -f "$lock" ] || die "$lock not found — submodules initialized?"

    local need_patch=0
    grep -q '"sha1": "68bb85cbfb1832ce4db43943911b046c3af3caab"' "$lock" && need_patch=1
    grep -q 'd34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368' "$lock" && need_patch=1

    if [ "$need_patch" -eq 0 ]; then
        skip "nimble.lock workarounds already applied"
        return 0
    fi

    log "Applying nimble.lock workarounds in $DELIVERY_DIR..."
    # nim package: replace upstream-claimed sha1 with what nimble actually
    # computes from the fetched tree.
    sed -i.bak \
        's/68bb85cbfb1832ce4db43943911b046c3af3caab/a092a045d3a427d127a5334a6e59c76faff54686/' \
        "$lock"
    # bearssl_pkey_decoder: revert from d34aa46 (clang-15 fix) to 21dd3710.
    # The newer SHA triggers the nimble 0.22.3 URL bug; semantics unchanged.
    sed -i.bak \
        -e 's/d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368/21dd3710df9345ed2ad8bf8f882761e07863b8e0/g' \
        -e 's/8666edbcb77cb9f97c659114d57c4ba0e7ab74c3/bcfd6fc9c5e10a52b87117219b7ab5c98136bc8e/g' \
        "$lock"
    rm -f "$lock.bak"
}

# ---------- Step 5a — rename stale libp2p carcass ----------
#
# PR #3807 dropped vendor/nwaku/vendor/nim-libp2p in favor of a nimble dep.
# The OLD checkout lingers as untracked. logos-chat's config.nims walks
# vendor/ recursively and would pick this old libp2p before the new one,
# breaking compile with `EVP_PKEY undeclared`. Rename rather than delete so
# the dir is preserved for spelunking.
rename_libp2p_carcass() {
    local stale="$LOGOS_CHAT_DIR/vendor/nwaku/vendor/nim-libp2p"
    if [ -d "$stale/.git" ] || [ -d "$stale/libp2p" ]; then
        log "Renaming stale vendor/nwaku/vendor/nim-libp2p carcass..."
        mv "$stale" "$stale.STALE-PR3807"
    elif [ -d "$stale.STALE-PR3807" ]; then
        skip "stale libp2p already renamed"
    else
        skip "no stale libp2p carcass to rename"
    fi
}

# ---------- Step 5b — mirror nimbledeps for chat-side nwaku ----------
#
# chat's nim build needs nwaku's nimble deps reachable on the import path.
# Mirror the working pkgs2/ that `make liblogosdelivery` populated in the
# delivery clone, then strip any pkg dirs whose pin doesn't appear in
# nwaku's nimble.lock — those would shadow the correct version on the
# search path and break compile.
mirror_chat_nimbledeps() {
    local src="$DELIVERY_DIR/nimbledeps"
    local dst="$LOGOS_CHAT_DIR/vendor/nwaku/nimbledeps"

    [ -d "$src/pkgs2" ] || die "delivery-side nimbledeps not built yet — run \`make liblogosdelivery\` first"

    if [ ! -d "$dst/pkgs2" ]; then
        log "Mirroring nimbledeps from delivery clone -> vendor/nwaku..."
        cp -R "$src" "$LOGOS_CHAT_DIR/vendor/nwaku/"
    else
        log "Syncing nimbledeps from delivery clone -> vendor/nwaku..."
        # Sync new pkgs from delivery side; the strip pass below removes
        # any stale variants the chat side accumulated.
        rsync -a --delete --no-times "$src/pkgs2/" "$dst/pkgs2/"
    fi

    # Strip pkg dirs whose pin doesn't match nwaku's lockfile — these
    # would shadow the correct version on nim's search path. Idempotent
    # against re-runs and PR-3807-transitional pin set changes.
    log "Stripping pin-mismatched nimbledeps variants from chat-side..."
    python3 - "$LOGOS_CHAT_DIR/vendor/nwaku/nimble.lock" "$dst/pkgs2" <<'PYEND'
import json, os, sys, shutil
lock_path, pkgs2 = sys.argv[1], sys.argv[2]
with open(lock_path) as f:
    lock = json.load(f)
# Build the set of accepted (name, version) tuples from nimble.lock.
accepted = {}
for name, entry in lock["packages"].items():
    accepted[name] = entry["version"]
removed = 0
for dirname in os.listdir(pkgs2):
    path = os.path.join(pkgs2, dirname)
    if not os.path.isdir(path):
        continue
    # pkgs2 dirnames are <name>-<version>-<sha1>
    parts = dirname.rsplit("-", 2)
    if len(parts) < 3:
        continue
    pkg_name, pkg_ver, _ = parts
    if pkg_name in accepted and accepted[pkg_name] != pkg_ver:
        shutil.rmtree(path)
        removed += 1
        print(f"  stripped {dirname}", flush=True)
if removed:
    print(f"  removed {removed} stale pkg dir(s)", flush=True)
PYEND
}

# ---------- Pre-stage every nimble.lock entry ----------
#
# Two problems this works around in one helper:
# 1. nimble 0.22.3 URL-handling bug — mangles `#`-prefix package versions
#    into a tempdir path that's never created, so `nimble setup` fails on
#    any git-pinned entry.
# 2. macOS filename-length limit (255 bytes) on nim's nimcache. When nim
#    compiles a package from the deep tempdir nimble downloads to, its
#    mangled nimcache filenames embed the full source path and silently
#    exceed 255 bytes (rooted at the long DELIVERY_DIR path), and the .c
#    file open() fails. Pre-staging every package into pkgs2/ shortens
#    those paths enough to stay under the limit.
#
# Pre-cloning each entry into pkgs2/<name>-<version>-<sha1>/ with a
# hand-written nimblemeta.json lets nimble find them by directory match
# and skip both the broken URL fetch and the tempdir build entirely.
#
# Idempotent: per-package check before clone.
prestage_all_nimble_deps() {
    local lock="$1"
    local nimbledeps="$2"
    local pkgs2="$nimbledeps/pkgs2"
    mkdir -p "$pkgs2"

    python3 - "$lock" "$pkgs2" <<'PYEND'
import json, os, subprocess, sys
lock_path, pkgs2 = sys.argv[1], sys.argv[2]
with open(lock_path) as f:
    lock = json.load(f)
for name, entry in lock["packages"].items():
    if name == "nim":
        # nim itself is provisioned by install_nim.sh; skip.
        continue
    ver = entry.get("version", "")
    rev = entry.get("vcsRevision", "")
    if not rev:
        # No git revision recorded — nothing to clone.
        continue
    url = entry["url"]
    sha1 = entry["checksums"]["sha1"]
    dest = os.path.join(pkgs2, f"{name}-{ver}-{sha1}")
    if os.path.isdir(dest) and os.path.isfile(os.path.join(dest, "nimblemeta.json")):
        continue
    if os.path.isdir(dest):
        # incomplete from a prior aborted run — start over
        subprocess.check_call(["rm", "-rf", dest])
    print(f"  cloning {name}@{rev[:8]}...", flush=True)
    subprocess.check_call(["git", "clone", "--quiet", url, dest])
    subprocess.check_call(["git", "-C", dest, "checkout", "--quiet", rev])
    # Some packages (secp256k1, miniupnpc-via-nat_traversal, bearssl)
    # vendor their C sources as submodules. Init recursively so build
    # can find them at compile time.
    subprocess.check_call(["git", "-C", dest, "submodule", "update",
                           "--init", "--recursive", "--quiet"])
    # srcDir flatten — packages declare srcDir = "<sub>" in their .nimble
    # (e.g. "src", "sds"), and consumers import as if those files were at
    # the package root. Read the declared value and flatten accordingly.
    # Match permissively: both srcDir="X" and srcDir = "X" appear in the
    # wild, sometimes with multiple spaces around the =.
    import re
    nimble_files = [f for f in os.listdir(dest) if f.endswith(".nimble")]
    if nimble_files:
        with open(os.path.join(dest, nimble_files[0])) as f:
            # Only match srcDir at start of a line — avoid matching
            # `srcDir = "./"` inside proc parameter defaults (e.g. dnsdisc).
            m = re.search(r'^\s*srcDir\s*=\s*"([^"]+)"', f.read(), re.MULTILINE)
        if m and m.group(1) not in (".", ""):
            src_dir = os.path.join(dest, m.group(1))
            if os.path.isdir(src_dir):
                subprocess.check_call(["bash", "-c",
                    f'cp -R "{src_dir}/." "{dest}/" && rm -rf "{src_dir}"'])
    # nimblemeta.json
    files = []
    for root, dirs, fns in os.walk(dest):
        if ".git" in root.split(os.sep):
            continue
        for fn in fns:
            rel = os.path.relpath(os.path.join(root, fn), dest)
            files.append("/" + rel)
    files.sort()
    meta = {
        "version": 1,
        "metaData": {
            "url": url, "downloadMethod": "git", "vcsRevision": rev,
            "files": files, "binaries": [], "specialVersions": [ver],
        }
    }
    with open(os.path.join(dest, "nimblemeta.json"), "w") as f:
        json.dump(meta, f, indent=2)
PYEND
}

# ---------- Step 4 — build delivery dylib (with patches applied first) ----------
ensure_liblogosdelivery() {
    local out="$DELIVERY_DIR/build/liblogosdelivery"
    local ext; ext="$(uname -s | grep -qi darwin && echo dylib || echo so)"

    if [ -f "$out.$ext" ]; then
        skip "liblogosdelivery.$ext already built"
        return 0
    fi

    # vendor/logos-delivery has three possible states on a fresh clone:
    #   1. Absent — logos-delivery-module has it .gitignored on some branches
    #   2. Populated by `--recurse-submodules` at the upstream master pin —
    #      the pin predates nimble.lock (needed for our build), so we treat
    #      this the same as absent and reclone into it
    #   3. Populated at our fork's rebase branch — do nothing
    # Marker for state 3: nimble.lock exists at the top. If it doesn't,
    # deinit the submodule (if any), remove the working tree, and clone
    # the fork branch fresh.
    if [ ! -f "$DELIVERY_DIR/nimble.lock" ]; then
        local repo="${DELIVERY_REPO:-git@github.com:adklempner/logos-delivery.git}"
        local branch="${DELIVERY_BRANCH:-rebase/lez-rln-gifter-on-3807}"
        if [ -e "$DELIVERY_DIR/.git" ]; then
            log "vendor/logos-delivery at upstream pin (no nimble.lock) — deinit + reclone"
            (cd "$LEZ_RLN_DIR/logos-delivery-module" && \
                git submodule deinit -f vendor/logos-delivery 2>&1 | tail -1) || true
            rm -rf "$DELIVERY_DIR"
        fi
        log "Auto-cloning vendor/logos-delivery ($repo @ $branch)..."
        git clone -b "$branch" "$repo" "$DELIVERY_DIR" 2>&1 | tail -3 \
            || die "git clone $repo failed"
        (cd "$DELIVERY_DIR" && git submodule update --init --recursive 2>&1 | tail -3) \
            || die "delivery submodule init failed"
    fi

    patch_delivery_nimble_lock
    log "Pre-staging nimble deps from lockfile..."
    prestage_all_nimble_deps "$DELIVERY_DIR/nimble.lock" "$DELIVERY_DIR/nimbledeps"
    log "Building liblogosdelivery.$ext (this takes ~10 min on first build)..."
    (cd "$DELIVERY_DIR" && make -j4 liblogosdelivery 2>&1 | tail -3) \
        || die "make liblogosdelivery failed"
}

# ---------- Step 5 — build chat dylib (with prep applied first) ----------
ensure_liblogoschat() {
    local out="$LOGOS_CHAT_DIR/build/liblogoschat"
    local ext; ext="$(uname -s | grep -qi darwin && echo dylib || echo so)"

    if [ -f "$out.$ext" ]; then
        skip "liblogoschat.$ext already built"
        return 0
    fi

    rename_libp2p_carcass
    mirror_chat_nimbledeps
    log "Building liblogoschat.$ext (this takes ~5 min on first build)..."
    (cd "$LOGOS_CHAT_DIR" && make update && make liblogoschat 2>&1 | tail -3) \
        || die "make liblogoschat failed"
}

# ---------- Step 1b — lssa sibling clone ----------
#
# The flake fetches lssa via fetchFromGitHub (portable, no submodule), but
# host-side cargo (RISC0 guest, run_setup, derive_accounts, wallet-module's
# --override-input for nix) still needs a plain sibling working directory at
# vendor/logos-lez-rln/lssa. Clone at exactly the flake's pinned rev
# (v0.2.0-rc6) if missing; skip otherwise.
ensure_lssa_sibling() {
    local dst="$LEZ_RLN_DIR/lssa"
    if [ -d "$dst/.git" ]; then
        skip "lssa sibling already cloned"
        return 0
    fi
    log "Cloning lssa sibling at v0.2.0-rc6..."
    git clone --branch v0.2.0-rc6 \
        https://github.com/logos-blockchain/logos-execution-zone.git "$dst" 2>&1 | tail -3 \
        || die "git clone lssa failed"
}

# ---------- Step 1c — spel-framework sibling clone ----------
#
# The RISC0 guest (lez-rln/methods/guest/Cargo.toml) has a path dep on
# `../../../spel/spel-framework`, expecting a `spel/` sibling of `lez-rln/`.
# spel isn't tracked in the logos-lez-rln repo; clone it on the rc6 port
# branch if missing. Same pattern as ensure_lssa_sibling.
ensure_spel_sibling() {
    local dst="$LEZ_RLN_DIR/spel"
    if [ -d "$dst/.git" ]; then
        skip "spel sibling already cloned"
        return 0
    fi
    log "Cloning spel sibling at feat/v0.5.0-rc6-port..."
    git clone --branch feat/v0.5.0-rc6-port \
        https://github.com/adklempner/spel.git "$dst" 2>&1 | tail -3 \
        || die "git clone spel failed"
}

# ---------- Step 2 — nix builds (logos-rln-module + wallet-module) ----------
ensure_lez_rln_nix_builds() {
    if [ -e "$LEZ_RLN_DIR/logos-rln-module/result-rln" ] \
       && [ -e "$LEZ_RLN_DIR/logos-rln-module/result-wallet" ]; then
        skip "logos-rln-module + wallet-module nix builds already present"
        return 0
    fi
    command -v nix >/dev/null || die "nix not on PATH — install it first"

    log "Building logos-rln-module via nix..."
    (cd "$LEZ_RLN_DIR" && nix build .#logos-rln-module -o logos-rln-module/result-rln) \
        || die "nix build .#logos-rln-module failed"

    log "Building wallet-module via nix..."
    (cd "$LEZ_RLN_DIR/logos-execution-zone-module" && \
        RISC0_SKIP_BUILD_KERNELS=1 nix build --impure \
            --override-input logos-execution-zone "git+file://$(pwd)/../lssa" \
            -o ../logos-rln-module/result-wallet) \
        || die "wallet-module nix build failed"
}

# ---------- Step 3 — Rust setup binaries (debug) ----------
ensure_lez_rln_rust_binaries() {
    local target="$LEZ_RLN_DIR/lez-rln/target/debug"
    if [ -x "$target/run_setup" ] && [ -x "$target/register_member" ] \
       && [ -x "$target/derive_accounts" ]; then
        skip "lez-rln debug binaries already built"
        return 0
    fi
    command -v cargo >/dev/null || die "cargo not on PATH — install Rust first"

    log "Building lez-rln debug binaries (run_setup, register_*, get_roots)..."
    # rc6 lssa pulls in keycard_wallet -> pyo3, which links Python3 framework
    # at build time. Default `python3` on macOS is Xcode's bundled Python at a
    # non-rpath location; baked path then fails dyld lookup at runtime. Pin to
    # Homebrew python3 when present so the linker bakes an absolute path that
    # actually resolves.
    PY_FOR_PYO3="${PYO3_PYTHON:-}"
    if [ -z "$PY_FOR_PYO3" ]; then
        for cand in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11; do
            [ -x "$cand" ] && PY_FOR_PYO3="$cand" && break
        done
    fi
    (cd "$LEZ_RLN_DIR/lez-rln" && \
        env ${PY_FOR_PYO3:+PYO3_PYTHON="$PY_FOR_PYO3"} cargo build --bin run_setup --bin register_member \
                    --bin register_commitments --bin get_roots --bin derive_accounts 2>&1 | tail -3) \
        || die "cargo build (lez-rln debug binaries) failed"
}

# ---------- Step 3b — RISC0 zkVM guest binaries ----------
#
# run_setup loads two zkVM ELF binaries at startup:
#   methods/guest/target/riscv32im-risc0-zkvm-elf/docker/rln_registration.bin
#   methods/guest/target/.../incremental_merkle_tree.bin
# These come from `cargo risczero build` (Docker-backed) and aren't
# produced by the regular cargo build above.
ensure_risc0_guest_binaries() {
    local guest_dir="$LEZ_RLN_DIR/lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker"
    if [ -f "$guest_dir/rln_registration.bin" ] && \
       [ -f "$guest_dir/incremental_merkle_tree.bin" ]; then
        skip "RISC0 guest binaries already built"
        return 0
    fi
    command -v cargo-risczero >/dev/null || \
        die "cargo-risczero not on PATH — install via rzup (https://dev.risczero.com/api/zkvm/install)"
    command -v docker >/dev/null || die "docker not on PATH — required by cargo risczero build"

    log "Building RISC0 guest binaries via 'cargo risczero build' (Docker, ~10 min)..."
    (cd "$LEZ_RLN_DIR/lez-rln" && \
        cargo risczero build --manifest-path methods/guest/Cargo.toml 2>&1 | tail -3) \
        || die "cargo risczero build failed"
}

# ---------- Step 3c — stage testnet fixtures from the shared deployment ----------
#
# The lez-rln tree ships a canonical shared testnet deployment as a descriptor
# under deployments/shared-5ade/. Stage it into vendor/logos-lez-rln/testnet/
# (flat fixture layout the sim consumes) so a fresh clone can run SIM_NETWORK=testnet
# without hand-maintained fixture files. Idempotent — stage.sh no-ops nothing
# but overwriting is safe: it re-derives from the descriptor deterministically.
ensure_testnet_fixtures_staged() {
    local desc="$LEZ_RLN_DIR/deployments/${DEPLOYMENT:-shared-5ade}"
    local out="$LEZ_RLN_DIR/testnet"
    local stage="$LEZ_RLN_DIR/tools/deployments/stage.sh"
    if [ ! -x "$stage" ]; then
        skip "tools/deployments/stage.sh not present — old lez-rln pin?"
        return 0
    fi
    if [ ! -d "$desc" ]; then
        skip "deployment descriptor $desc not present"
        return 0
    fi
    if [ -f "$out/storage.json.seed" ] && [ -f "$out/wallet_config.json" ] \
       && [ -f "$out/payment_account.txt" ] && [ -f "$out/supply_holding.txt" ]; then
        skip "testnet fixtures already staged"
        return 0
    fi
    command -v jq >/dev/null || die "jq not on PATH — required by stage.sh"
    log "Staging testnet fixtures from $desc..."
    bash "$stage" "$desc" "$out" || die "stage.sh failed"
}

# ---------- logos-chat-module sibling clone ----------
#
# The sim script defaults CHAT_MODULE_DIR to $LOGOS_CHAT_DIR/../logos-chat-module.
# That repo isn't part of logos-chat's submodules — it lives as a SIBLING
# checkout. Auto-clone it on first use; the sim picks it up via the default.
ensure_chat_module_sibling() {
    local dst="$LOGOS_CHAT_DIR/../logos-chat-module"
    if [ -d "$dst/.git" ]; then
        skip "logos-chat-module sibling already cloned"
        return 0
    fi
    # feat/logos-delivery-v2 lives on adklempner's fork (matches the
    # current rebased delivery + chat stack); logos-co master predates
    # PR #3807's logos_delivery/* layout and won't compile against our
    # delivery dylib.
    local repo="${CHAT_MODULE_REPO:-git@github.com:adklempner/logos-chat-module.git}"
    local branch="${CHAT_MODULE_BRANCH:-feat/logos-delivery-v2}"
    log "Auto-cloning logos-chat-module sibling ($repo @ $branch)..."
    git clone -b "$branch" "$repo" "$dst" 2>&1 | tail -3 \
        || die "git clone $repo failed"
}

# ---------- Step 6 — delivery_module C++ plugin (OPTIONAL) ----------
#
# The default sim picks delivery_module_plugin.dylib from the DELIVERY_LGX
# bundle, so a fresh local plugin build is only needed if you want to test
# a code change in logos-delivery-module/src/*.cpp. Invoked manually:
#   bash vendor/logos-lez-rln/build_all.sh
# (build_all.sh's chat2mix step currently fails on PR #3807 — unrelated to
# the sim path, but it short-circuits the plugin step. Patch around it or
# run cmake directly if you need a fresh plugin.)
ensure_delivery_module_plugin_optional() {
    local plug="$LEZ_RLN_DIR/logos-delivery-module/build_plugin/modules/delivery_module_plugin.dylib"
    if [ -f "$plug" ]; then
        skip "delivery_module_plugin.dylib already built (override available)"
    else
        skip "delivery_module_plugin.dylib not pre-built — sim will use the .lgx-bundled copy"
    fi
}

# ---------- Orchestrator ----------
bootstrap_all() {
    log "=== Bootstrapping mix LEZ-RLN sim from fresh clone ==="
    log "  LOGOS_CHAT_DIR=$LOGOS_CHAT_DIR"
    log "  LEZ_RLN_DIR=$LEZ_RLN_DIR"
    log "  DELIVERY_DIR=$DELIVERY_DIR"

    ensure_chat_module_sibling
    ensure_lssa_sibling
    ensure_spel_sibling
    ensure_lez_rln_nix_builds
    ensure_lez_rln_rust_binaries
    ensure_risc0_guest_binaries
    ensure_liblogosdelivery
    ensure_liblogoschat
    ensure_delivery_module_plugin_optional
    ensure_testnet_fixtures_staged

    log "=== Bootstrap complete — run 'bash $SCRIPT_DIR/demo_step.sh' ==="
}

# Run when invoked directly; do nothing when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    bootstrap_all
fi

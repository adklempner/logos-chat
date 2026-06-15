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
# delivery clone, then strip the obsolete-pin variants of libp2p / websock
# so chat compile picks the new ones.
mirror_chat_nimbledeps() {
    local src="$DELIVERY_DIR/nimbledeps"
    local dst="$LOGOS_CHAT_DIR/vendor/nwaku/nimbledeps"

    if [ -d "$dst/pkgs2" ] && [ "$(ls "$dst/pkgs2" 2>/dev/null | wc -l)" -gt 30 ]; then
        skip "chat-side vendor/nwaku/nimbledeps already populated"
        return 0
    fi

    [ -d "$src/pkgs2" ] || die "delivery-side nimbledeps not built yet — run \`make liblogosdelivery\` first"

    log "Mirroring nimbledeps from delivery clone -> vendor/nwaku..."
    cp -R "$src" "$LOGOS_CHAT_DIR/vendor/nwaku/"

    # Strip the obsolete libp2p (pre-v2.0.0) — chat compile must pick the new one.
    rm -rf "$dst/pkgs2/libp2p-#ff8d51857b4b79a68468e7bcc27b2026cca02996-fa2a7552c6ec860717b77ce34cf0b7afe4570234"

    # Strip the obsolete websock (chat compile fails with readHttpRequest undeclared
    # if the new libp2p resolves against websock 0.3.0).
    rm -rf "$dst/pkgs2/websock-0.3.0-1294a66520fa4541e261dec8a6a84f774fb8c0ac"
}

# ---------- Step 4 — build delivery dylib (with patches applied first) ----------
ensure_liblogosdelivery() {
    local out="$DELIVERY_DIR/build/liblogosdelivery"
    local ext; ext="$(uname -s | grep -qi darwin && echo dylib || echo so)"

    if [ -f "$out.$ext" ]; then
        skip "liblogosdelivery.$ext already built"
        return 0
    fi

    [ -d "$DELIVERY_DIR/.git" ] || die "$DELIVERY_DIR not a git repo — submodules initialized?"

    patch_delivery_nimble_lock
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
    if [ -x "$target/run_setup" ] && [ -x "$target/register_member" ]; then
        skip "lez-rln debug binaries already built"
        return 0
    fi
    command -v cargo >/dev/null || die "cargo not on PATH — install Rust first"

    log "Building lez-rln debug binaries (run_setup, register_*, get_roots)..."
    (cd "$LEZ_RLN_DIR/lez-rln" && \
        cargo build --bin run_setup --bin register_member \
                    --bin register_commitments --bin get_roots 2>&1 | tail -3) \
        || die "cargo build (lez-rln debug binaries) failed"
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

    ensure_lez_rln_nix_builds
    ensure_lez_rln_rust_binaries
    ensure_liblogosdelivery
    ensure_liblogoschat
    ensure_delivery_module_plugin_optional

    log "=== Bootstrap complete — run 'bash $SCRIPT_DIR/demo_step.sh' ==="
}

# Run when invoked directly; do nothing when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    bootstrap_all
fi

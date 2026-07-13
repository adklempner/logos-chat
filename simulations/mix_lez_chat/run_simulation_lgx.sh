#!/usr/bin/env bash
# Mix + LEZ RLN chat simulation — the acceptance harness (.lgx / daemon-mode
# logoscore). Each instance starts a daemon (logoscore -m MDIR -D) under an
# isolated LOGOSCORE_CONFIG_DIR, loads modules via `load-module <name>`, and
# issues `X.method(args)` calls against the running daemon. Modules ship as
# .lgx bundles produced by nix-bundle-lgx and installed via install_lgx.
#
# Requirements + usage: see README.md.
# Usage: ./run_simulation_lgx.sh [--fresh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGOS_CHAT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHAT_MODULE_DIR="${CHAT_MODULE_DIR:-$(cd "$LOGOS_CHAT_DIR/../logos-chat-module" && pwd)}"

# Use vendored logos-lez-rln submodule, or auto-detect as sibling
LEZ_RLN_DIR="${LEZ_RLN_DIR:-}"
if [ -z "$LEZ_RLN_DIR" ] && [ -d "$LOGOS_CHAT_DIR/vendor/logos-lez-rln/lez-rln" ]; then
    LEZ_RLN_DIR="$LOGOS_CHAT_DIR/vendor/logos-lez-rln"
fi
for candidate in "$LOGOS_CHAT_DIR/.." "$LOGOS_CHAT_DIR/../logos-lez-rln"; do
    [ -n "$LEZ_RLN_DIR" ] && break
    [ -d "$candidate/lez-rln" ] && LEZ_RLN_DIR="$(cd "$candidate" && pwd)" && break
done
[ -z "$LEZ_RLN_DIR" ] && { echo "FATAL: Cannot find logos-lez-rln repo. Set LEZ_RLN_DIR or run: git submodule update --init --recursive"; exit 1; }

DELIVERY_MODULE_DIR="${DELIVERY_MODULE_DIR:-$LEZ_RLN_DIR/logos-delivery-module}"
DELIVERY_DIR="$DELIVERY_MODULE_DIR/vendor/logos-delivery"

export RISC0_DEV_MODE=1
export TMPDIR=/tmp
export LOGOS_EVENT_STDERR=1  # Mirror EVENT: lines to stderr so the sim can grep them.

die() { echo "  FATAL: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Source setup_from_scratch.sh for the prep helpers (patch_delivery_nimble_lock,
# rename_libp2p_carcass, mirror_chat_nimbledeps). Each is idempotent so calling
# them from the auto-build paths below is safe on already-set-up clones.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup_from_scratch.sh"

# Poll a logoscore log until it shows >= $expected "Method call successful"
# lines, or until $timeout iterations (sleeping $sleep_sec each) have elapsed.
# Sets global $N to the last observed count so callers can branch on it.
wait_method_calls() {
    local logfile="$1" expected="$2" timeout="$3" sleep_sec="${4:-1}"
    local t
    for t in $(seq 1 "$timeout"); do
        # New logoscore `call` subcommand emits one JSON line per successful
        # invocation: `{"method":"...","module":"...","result":N,"status":"ok"}`.
        N=$(grep -c '"status":"ok"' "$logfile" 2>/dev/null || true); N=${N:-0}
        [ "$N" -ge "$expected" ] && return 0
        sleep "$sleep_sec"
    done
    return 1
}

# Install a .lgx bundle into a logoscore modules dir. Extracts the manifest +
# the current $PLATFORM variant into <mdir>/<manifest.name>/, flattens dylibs
# to the top, and writes a `variant` marker file with the platform key.
install_lgx() {
    local mdir="$1" lgx="$2"
    local name tmp
    name=$(tar xzOf "$lgx" manifest.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    [ -z "$name" ] && die "install_lgx: cannot read name from $lgx"
    tmp=$(mktemp -d)
    tar xzf "$lgx" -C "$tmp"
    rm -rf "$mdir/$name"
    mkdir -p "$mdir/$name"
    cp "$tmp/manifest.json" "$mdir/$name/manifest.json"
    if [ -d "$tmp/variants/$PLATFORM" ]; then
        cp -L "$tmp"/variants/"$PLATFORM"/* "$mdir/$name/"
    else
        die "install_lgx: $lgx has no variants/$PLATFORM"
    fi
    printf '%s' "$PLATFORM" > "$mdir/$name/variant"
    rm -rf "$tmp"
}

# Copy a runtime-shared dylib into an already-installed module dir. nix-bundle-lgx
# currently drops `metadata.json:include[]` libs from the .lgx (tracked upstream),
# so we patch them in post-install. The dylib is looked up via @loader_path from
# the plugin, so dropping it next to the plugin is the correct fix.
install_extra_lib() {
    local mdir="$1" module="$2" lib="$3"
    [ -f "$lib" ] || die "install_extra_lib: missing $lib for $module"
    cp -L "$lib" "$mdir/$module/"
}

# Start a logoscore daemon under an isolated config dir, then load the
# comma-separated $LOAD list (in order, satisfies inter-module dependencies),
# then issue each subsequent argument as a `-c` call. Daemon PID is appended
# to INSTANCE_PIDS; config dirs accumulate in INSTANCE_CFG_DIRS so cleanup can
# tear everything down. Sets $LAST_DAEMON_PID for callers that need to wait.
#
# Usage: start_logoscore_instance <log_file> <modules_dir> <load_csv> <call1> [<call2> ...]
start_logoscore_instance() {
    local log_file="$1" mdir="$2" load_csv="$3"; shift 3
    local cfg_dir
    cfg_dir=$(mktemp -d); INSTANCE_CFG_DIRS+=("$cfg_dir")
    LAST_DAEMON_CFG="$cfg_dir"
    # CRITICAL: daemon and client MUST share the same effective TMPDIR — Qt
    # LocalSocket sockets are created under $TMPDIR (resolved via
    # QStandardPaths::TempLocation) and the client looks them up there. The sim's
    # top-level `export TMPDIR=/tmp` (legacy, for old logoscore path-length
    # workaround) would otherwise leave daemon at the macOS default
    # (/var/folders/.../T/, via env -i) and client at /tmp/ — mismatch → client
    # hangs at connect with no diagnostic. We unset TMPDIR on BOTH sides so they
    # converge on the macOS default.
    #
    # DYLD_INSERT_LIBRARIES is the fix for modules whose plugin was built with
    # `-undefined dynamic_lookup` (logos-module-builder default) — those plugins
    # have NO LC_LOAD_DYLIB entry for their `EXTERNAL_LIBS` dylib (e.g.
    # liblogosdelivery, liblogoschat), so dyld can't resolve their flat-namespace
    # symbols at dlopen time. Pre-loading the lib via DYLD_INSERT_LIBRARIES into
    # the daemon makes the subprocess (logos_host_qt) inherit it — but only when
    # the daemon is launched via `env -i` with a clean env (otherwise Qt's
    # QProcess sanitization strips DYLD_*). Per-module pairing happens in the
    # caller via the DYLD_PRELOAD_LIBS env. When unset, no injection happens and
    # modules without flat-namespace deps work fine.
    local -a daemon_env=(HOME="$HOME" PATH="$PATH" LOGOSCORE_CONFIG_DIR="$cfg_dir" RUST_BACKTRACE=full)
    [ -n "${DYLD_PRELOAD_LIBS:-}" ] && daemon_env+=(DYLD_INSERT_LIBRARIES="$DYLD_PRELOAD_LIBS")
    # lez-rln-ffi (inside the rln-module plugin) reads LEZ_RLN_TREE_ID_HEX
    # to derive program PDAs. Without it, merkle_proofs_plan derives a
    # tree_main that doesn't match what run_setup created on-chain →
    # register_member fails. env -i clears it; re-export explicitly.
    [ -n "${LEZ_RLN_TREE_ID_HEX:-}" ] && daemon_env+=(LEZ_RLN_TREE_ID_HEX="$LEZ_RLN_TREE_ID_HEX")
    # Truncate first via `:>`, then daemon AND client both append via `>>`.
    # Critical: using bash `>` for the daemon leaves its fd in O_WRONLY (no
    # O_APPEND), so when the client interleaves appends via `>>` and then the
    # daemon writes again, the daemon's fd at its prior offset overwrites the
    # client's JSON response. O_APPEND on both sides keeps the file coherent.
    : > "$log_file"
    (cd "$STATE_DIR" && env -i "${daemon_env[@]}" \
        "$LOGOSCORE" -m "$mdir" -D </dev/null >>"$log_file" 2>&1) &
    LAST_DAEMON_PID=$!; INSTANCE_PIDS+=("$LAST_DAEMON_PID")
    # Two-phase readiness: client config file (daemon emitted) AND list-modules
    # responding with capability_module loaded. The config file alone is too
    # eager — the daemon's QtRO local server isn't always ready to accept
    # subprocess load requests yet, which made load-module return RPC failures.
    local t
    for t in $(seq 1 60); do
        [ -f "$cfg_dir/client/config.json" ] && break
        sleep 1
    done
    [ -f "$cfg_dir/client/config.json" ] || { echo "    daemon $LAST_DAEMON_PID failed to start (no client config)"; return 1; }
    for t in $(seq 1 60); do
        # 5s timeout per probe call: a daemon mid-subprocess-load can be momentarily
        # unresponsive over QtRO; without the timeout one stuck probe wedges the
        # whole sim.
        timeout 5 env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg_dir" "$LOGOSCORE" --quiet --json list-modules 2>/dev/null \
            | grep -q '"capability_module".*"loaded"' && break
        sleep 1
    done
    # Even after list-modules shows capability_module "loaded", the daemon's
    # QtRO registry may not be fully ready to broker load-module RPCs (which
    # spawn new logos_host_qt subprocesses that handshake with capability_module
    # for tokens). Empirically, RPCs fired within the first ~3s of capability
    # loaded hang past a 30s timeout. Settle for a fixed window.
    sleep 5
    # Load modules in declared order; logoscore resolves their deps internally.
    # Each subprocess load takes ~1-5s; 30s/module is generous.
    local mod rc
    for mod in ${load_csv//,/ }; do
        echo "  [debug] cfg=$cfg_dir loading $mod..." >&2
        echo "=== CLIENT LOAD $mod ===" >> "$log_file"
        timeout 30 env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg_dir" "$LOGOSCORE" --json load-module "$mod" \
            >>"$log_file" 2>&1
        rc=$?
        echo "=== rc=$rc ===" >> "$log_file"
        echo "  [debug] load $mod rc=$rc" >&2
        [ "$rc" -ne 0 ] && { echo "    load-module $mod failed (pid $LAST_DAEMON_PID, rc=$rc)"; return 1; }
    done
    # Issue per-call invocations against the running daemon. The top-level
    # `-c "X.method(args)"` flag is NOT a client — it spawns a SEPARATE daemon,
    # so it can never reach the modules we just loaded. The correct surface is
    # the `call` subcommand: `logoscore call <module> <method> <arg>...`.
    # `parse_call` splits our legacy "X.method(a,b,c)" string into the discrete
    # args the subcommand wants. Each successful call logs a JSON line
    # `{"method":"...","result":N,"status":"ok"}` — replaces the old "Method
    # call successful" marker that wait_method_calls used to grep for.
    local call mod meth args_str arg_tmp_dir
    arg_tmp_dir=$(mktemp -d); INSTANCE_CFG_DIRS+=("$arg_tmp_dir")
    for call in "$@"; do
        mod=${call%%.*}
        meth=${call#*.}; meth=${meth%%(*}
        args_str=${call#*\(}; args_str=${args_str%\)}
        # IFS split on comma; if args_str is empty, pass no args.
        local -a raw_args=() final_args=()
        [ -n "$args_str" ] && IFS=',' read -ra raw_args <<< "$args_str"
        # Wrap any digit-leading non-purely-numeric arg as @tmpfile to force
        # string typing — logoscore-cli's `call` parser auto-coerces numeric-
        # looking tokens to int/double, which mangles digit-prefixed identifiers
        # like wallet account IDs (e.g. "3SdWB8iLJ8Ct..." → int 3 → server-side
        # "failed to resolve account IDs"). The @file form bypasses coercion.
        local i=0 a
        for a in "${raw_args[@]+"${raw_args[@]}"}"; do
            if [[ "$a" =~ ^[0-9] ]] && [[ "$a" =~ [^0-9] ]]; then
                local f="$arg_tmp_dir/${RANDOM}_${i}.arg"
                printf '%s' "$a" > "$f"
                final_args+=("@$f")
            else
                final_args+=("$a")
            fi
            i=$((i+1))
        done
        # Default 180s timeout per call. Wallet open/startChat can take ~30s on
        # cold sequencer; mix peer joins ~5s. Bump via CALL_TIMEOUT env if needed.
        # Don't return on failure — keep dispatching remaining calls. Non-gifter
        # delivery_module.start()'s RPC reply times out (~20s QtRO ceiling) because
        # its async backend (gifter client registration + on-chain watcher) keeps
        # the Qt thread busy past the deadline, even though the underlying node
        # actually started fine. Subsequent calls (setRlnConfig, subscribe) MUST
        # still dispatch — they're independent of start()'s reply.
        timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg_dir" "$LOGOSCORE" --json call "$mod" "$meth" "${final_args[@]+"${final_args[@]}"}" \
            >>"$log_file" 2>&1 \
            || echo "    call failed: $call (pid $LAST_DAEMON_PID) — continuing"
    done
    return 0
}

# Post-start call sequencing (2026-07-11): issuing subscribe/init_after_delivery
# while delivery_module.start() still blocks the Qt loop leaves their QtRO
# dispatch queued; they all fire in a burst the instant start completes,
# racing the FFI/chronos start-completion transition. On testnet (40-60s
# start vs ~2s local) this SIGSEGVs the chat daemons ~50% of the time,
# always right after "Delivery start completed with success". Hold the
# post-start calls until that marker, then issue them spaced.
wait_start_completed() {
    local log_file="$1" max="${2:-150}" t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$max" ]; do
        grep -q "Delivery start completed with success" "$log_file" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
issue_call_now() {
    local cfg_dir="$1" log_file="$2" mod="$3" meth="$4"; shift 4
    timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg_dir" "$LOGOSCORE" --json call "$mod" "$meth" "$@" \
        >>"$log_file" 2>&1 \
        || echo "    deferred call failed: $mod.$meth — continuing"
}
# Like issue_call_now but prints the CLI's JSON output for result capture.
call_json() {
    local cfg_dir="$1" mod="$2" meth="$3"; shift 3
    timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$cfg_dir" "$LOGOSCORE" --json call "$mod" "$meth" "$@" 2>/dev/null
}
# Extract the first ok-status result from call_json output (raw string for
# string results; compact JSON otherwise). Empty output = call failed.
jres() {
    python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("status") == "ok" and "result" in d:
        r = d["result"]
        print(r if isinstance(r, str) else json.dumps(r))
        break
'
}

# --- Node identity constants (4 mix nodes) ---
NODEKEYS=(
    "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
    "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
    "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
    "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
    "1d3a29b6cfeb7f88ea1e0e6c5aad9d8267d59c39a5b41a9e847ffd4c3e0b62f7"
    "5c94a1f0d68d4b3ea18b7b46f6e2eeb92d9d0be8e4b6721f9d3a03f2e88a51c8"
)
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"
    "16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f"
    ""
    ""
)
MIXKEYS=(
    "c86029e02c05a7e25182974b519d0d52fcbafeca6fe191fbb64857fb05be1a53"
    "b858ac16bbb551c4b2973313b1c8c8f7ea469fca03f1608d200bbf58d388ec7f"
    "d8bd379bb394b0f22dd236d63af9f1a9bc45266beffc3fbbe19e8b6575f2535b"
    "780fff09e51e98df574e266bf3266ec6a3a1ddfcf7da826a349a29c137009d49"
    "af28661d6fed30ca979ee460d4527446574d922532cf32b99e63ea92edac3e7d"
    "c7e905d2f2a7d4db754403bd5e9fe07ef6180a6d557dc8213fac50eb68cc1e3b"
)
MIX_PUBKEYS=(
    "9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a"
    "275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c"
    "e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18"
    "8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f"
)
# --- Configurable parameters (override via environment) ---
NUM_NODES=${SIM_NUM_NODES:-4}
BASE_TCP_PORT=${SIM_BASE_TCP_PORT:-60001}
BASE_DISC_PORT=${SIM_BASE_DISC_PORT:-9001}
CLUSTER_ID=${SIM_CLUSTER_ID:-99}
NUM_SHARDS=1
CONTENT_TOPIC="/logos-chat/1/mix-test/proto"
TEST_MESSAGE_PREFIX="chatmixtest"
LOG_LEVEL=${SIM_LOG_LEVEL:-DEBUG}
CHAT_RECV_PORT=${SIM_CHAT_RECV_PORT:-60010}
CHAT_RECV2_PORT=${SIM_CHAT_RECV2_PORT:-60012}
CHAT_SEND_PORT=${SIM_CHAT_SEND_PORT:-60011}
SIM_NETWORK=${SIM_NETWORK:-local}
case "$SIM_NETWORK" in
  local|testnet) ;;
  *) die "SIM_NETWORK must be 'local' or 'testnet', got: $SIM_NETWORK";;
esac

# Timing floors: local sequencer ~15s blocks vs testnet ~60s + more variance.
if [ "$SIM_NETWORK" = testnet ]; then
    KADEMLIA_MIN_WAIT=${SIM_KADEMLIA_MIN_WAIT:-120}
    # Testnet block times + finality lag can stretch RLN tx confirmations to
    # multiple minutes per mix node. 4 nodes × ~5 min each + slack ≈ 30 min.
    KADEMLIA_HARD_CAP=${SIM_KADEMLIA_HARD_CAP:-1800}
    RECEIVER_MIN_WAIT=${SIM_RECEIVER_MIN_WAIT:-60}
    DELIVERY_TIMEOUT=${SIM_DELIVERY_TIMEOUT:-300}
    NODE_STARTUP_SLEEP=${SIM_NODE_STARTUP_SLEEP:-30}
    export LEZ_RLN_BLOCK_SEAL_SECS="${LEZ_RLN_BLOCK_SEAL_SECS:-90}"
else
    KADEMLIA_MIN_WAIT=${SIM_KADEMLIA_MIN_WAIT:-30}
    KADEMLIA_HARD_CAP=${SIM_KADEMLIA_HARD_CAP:-180}
    RECEIVER_MIN_WAIT=${SIM_RECEIVER_MIN_WAIT:-15}
    DELIVERY_TIMEOUT=${SIM_DELIVERY_TIMEOUT:-240}
    NODE_STARTUP_SLEEP=${SIM_NODE_STARTUP_SLEEP:-10}
fi
TESTNET_RPC_URL="${TESTNET_RPC_URL:-https://testnet.lez.logos.co/}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="darwin-arm64-dev"; EXT="dylib";;
  Linux-x86_64) PLATFORM="linux-x86_64-dev"; EXT="so";;
  Linux-aarch64) PLATFORM="linux-aarch64-dev"; EXT="so";;
  *) die "Unsupported platform";;
esac

STATE_DIR="$SCRIPT_DIR/.sim_state"
FRESH=0
for arg in "$@"; do [ "$arg" = "--fresh" ] && FRESH=1; done
[ "$FRESH" -eq 1 ] && rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

SEQUENCER_PID=""
OWN_SEQUENCER=0
INSTANCE_PIDS=()
INSTANCE_CFG_DIRS=()
MODULES_DIRS=()
SENDER_PID=""
RECEIVER_PID=""
EXIT_CODE=1

cleanup() {
    set +u
    echo ""; echo "=== Shutting down ==="
    [ -n "$SENDER_PID" ] && kill "$SENDER_PID" 2>/dev/null || true
    [ -n "$RECEIVER_PID" ] && kill "$RECEIVER_PID" 2>/dev/null || true
    for pid in "${INSTANCE_PIDS[@]+"${INSTANCE_PIDS[@]}"}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    pkill -f 'logos_host' 2>/dev/null || true
    [ "$OWN_SEQUENCER" -eq 1 ] && [ -n "$SEQUENCER_PID" ] && kill "$SEQUENCER_PID" 2>/dev/null || true
    for mdir in "${MODULES_DIRS[@]+"${MODULES_DIRS[@]}"}"; do [ -n "$mdir" ] && rm -rf "$mdir"; done
    for cdir in "${INSTANCE_CFG_DIRS[@]+"${INSTANCE_CFG_DIRS[@]}"}"; do [ -n "$cdir" ] && rm -rf "$cdir"; done
    echo "  Logs: $STATE_DIR"; echo "Done."; exit "$EXIT_CODE"
}
trap cleanup EXIT

echo "=== Mix + LEZ RLN Chat Simulation ($NUM_NODES nodes) ==="
echo "  Network:          $SIM_NETWORK"
[ "$SIM_NETWORK" = testnet ] && echo "  Testnet RPC:      $TESTNET_RPC_URL"
echo "  LEZ repo:         $LEZ_RLN_DIR"
echo "  Chat module:      $CHAT_MODULE_DIR"
echo "  Logos-chat:        $LOGOS_CHAT_DIR"
echo ""

pkill -f 'logos_host' 2>/dev/null || true; sleep 1
# Stale QtRO LocalServer sockets confuse capability_module lookups.
rm -f /tmp/logos_* 2>/dev/null || true

# ---------- Phase 1: Sequencer ----------
echo "[1/6] Sequencer..."
if [ "$SIM_NETWORK" = testnet ]; then
    # Fail fast if testnet RPC is unreachable before 10+ min of setup work.
    BLOCK_RESP=$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
        "$TESTNET_RPC_URL" 2>&1)
    case "$BLOCK_RESP" in
      *'"result"'*) log "  Testnet reachable: $(echo "$BLOCK_RESP" | grep -oE '"result":[0-9]+' | head -1)";;
      *) die "Testnet unreachable at $TESTNET_RPC_URL: $BLOCK_RESP";;
    esac
elif nc -z 127.0.0.1 3040 2>/dev/null && [ "$FRESH" -eq 0 ]; then
    SEQUENCER_PID=$(lsof -ti tcp:3040 2>/dev/null || true)
    echo "  Already running (PID $SEQUENCER_PID)"
else
    [ "$(nc -z 127.0.0.1 3040 2>/dev/null; echo $?)" = "0" ] && kill "$(lsof -ti tcp:3040 2>/dev/null)" 2>/dev/null || true; sleep 1
    rm -rf "$LEZ_RLN_DIR/lssa/rocksdb" "$LEZ_RLN_DIR/lssa/sequencer/service/bedrock_signing_key"

    # Pre-built binary path skips both the cargo build and the lssa auto-sync
    # (auto-sync needs full git history; shallow Docker clones break it).
    if [ -x "$LEZ_RLN_DIR/lssa/target/debug/sequencer_service" ]; then
        log "  Using pre-built sequencer"
        SEQ_BIN="./target/debug/sequencer_service"
        for cfg in lez/sequencer/service/configs/debug/sequencer_config.json sequencer/service/configs/debug/sequencer_config.json; do
            [ -f "$LEZ_RLN_DIR/lssa/$cfg" ] && SEQ_CFG="$cfg" && break
        done
    else
        # lssa rev must match what lez-rln's host-side client pins, else
        # DeserializeUnexpectedEnd from wire-format divergence. When lez-rln
        # uses path = "../lssa/..." deps the submodule IS the source of truth,
        # so there's no separate rev to align against — skip the auto-pin.
        #
        # Post-deploy-policies, lez-rln pins its execution-zone deps by
        # `git tag = "vX"` against the logos-execution-zone REPO (self-
        # contained cargo fetch), NOT against this lssa checkout. So a bare
        # rev/tag grep here false-positives: it would try to `git checkout`
        # an execution-zone tag inside lssa. Only honor a pin the lssa
        # checkout can actually resolve; otherwise trust its HEAD (which
        # setup_from_scratch.sh's ensure_lssa_sibling already pins).
        LSSA_REV=$( (grep -oE '(rev|tag)\s*=\s*"[^"]+"' "$LEZ_RLN_DIR/lez-rln/Cargo.toml" || true) | head -1 | sed 's/.*"\([^"]*\)"/\1/')
        _lssa_has_rev() {
            git -C "$LEZ_RLN_DIR/lssa" rev-parse --git-dir >/dev/null 2>&1 || return 1
            git -C "$LEZ_RLN_DIR/lssa" cat-file -e "$1^{commit}" 2>/dev/null && return 0
            git -C "$LEZ_RLN_DIR/lssa" fetch --quiet --tags origin 2>/dev/null || true
            git -C "$LEZ_RLN_DIR/lssa" cat-file -e "$1^{commit}" 2>/dev/null
        }
        if [ -n "$LSSA_REV" ] && _lssa_has_rev "$LSSA_REV"; then
            if ! git -C "$LEZ_RLN_DIR/lssa" merge-base --is-ancestor "$LSSA_REV" HEAD 2>/dev/null; then
                log "  Pinning lssa to $LSSA_REV..."
                (cd "$LEZ_RLN_DIR/lssa" && git checkout --quiet "$LSSA_REV") \
                    || die "lssa checkout $LSSA_REV failed"
            fi
        else
            log "  lssa: no matching pin in checkout; trusting HEAD ($(git -C "$LEZ_RLN_DIR/lssa" rev-parse --short HEAD 2>/dev/null || echo '?'))"
        fi
        log "  Building sequencer..."
        if (cd "$LEZ_RLN_DIR/lssa" && cargo build --features standalone -p sequencer_service 2>&1 | tail -3); then
            SEQ_BIN="./target/debug/sequencer_service"
            # rc6 moved the sequencer tree from sequencer/... to lez/sequencer/...
            for cfg in lez/sequencer/service/configs/debug/sequencer_config.json sequencer/service/configs/debug/sequencer_config.json; do
                [ -f "$LEZ_RLN_DIR/lssa/$cfg" ] && SEQ_CFG="$cfg" && break
            done
        elif (cd "$LEZ_RLN_DIR/lssa" && cargo build --features standalone -p sequencer_runner 2>&1 | tail -3); then
            SEQ_BIN="./target/debug/sequencer_runner"; SEQ_CFG="sequencer_runner/configs/debug"
        else die "sequencer build failed"; fi
    fi
    (cd "$LEZ_RLN_DIR/lssa" && env RUST_LOG=info "$SEQ_BIN" "$SEQ_CFG") >"$STATE_DIR/sequencer.log" 2>&1 &
    SEQUENCER_PID=$!; OWN_SEQUENCER=1; echo "  PID: $SEQUENCER_PID"
    for _ in $(seq 1 60); do nc -z 127.0.0.1 3040 2>/dev/null && break; sleep 1; done
    nc -z 127.0.0.1 3040 2>/dev/null || die "Sequencer failed to start"
    log "  Ready."
fi

# ---------- Phase 2: Deploy programs ----------
echo "[2/6] Deploying programs..."
# `local` -> dev/ (re-init each run); `testnet` -> testnet/ (persistent
# wallet + on-chain state). wallet_config.json under each picks the sequencer.
WALLET_HOME_SUBDIR=$([ "$SIM_NETWORK" = testnet ] && echo testnet || echo dev)
export NSSA_WALLET_HOME_DIR="$LEZ_RLN_DIR/$WALLET_HOME_SUBDIR"
# rc6 renamed nssa->lee, including the wallet-home env var. Set both so the
# script works against both rc5- and rc6-era wallet builds.
export LEE_WALLET_HOME_DIR="$NSSA_WALLET_HOME_DIR"
export WALLET_CONFIG="$NSSA_WALLET_HOME_DIR/wallet_config.json"
export WALLET_STORAGE="$NSSA_WALLET_HOME_DIR/storage.json"

# Testnet: auto-stage flat fixtures from the shared deployment descriptor if
# missing, then source the staged env.sh so the descriptor's LEZ_RLN_TREE_ID_HEX
# becomes the tree_id source of truth for this run. Descriptor is authoritative:
# wallet in storage.json.seed is bound to that tree_id; using any other value
# makes run_setup redeploy and desync the sim from shared on-chain state.
if [ "$SIM_NETWORK" = testnet ]; then
    # Default deployment: the mix_lez_chat faucet profile (funding=faucet —
    # per-run budget claimed from a program-owned PDA, no drainable supply).
    # Override with DEPLOYMENT=<name> (e.g. a wallet-key legacy profile).
    DEPLOYMENT="${DEPLOYMENT:-mlc-faucet-260712}"
    # Restage when the staged fixtures belong to a different deployment than
    # the one requested (tree drift): park the old testnet/ dir aside.
    _desc_json="$LEZ_RLN_DIR/deployments/$DEPLOYMENT/deployment.json"
    if [ -f "$LEZ_RLN_DIR/testnet/env.sh" ] && [ -f "$_desc_json" ] && command -v jq >/dev/null; then
        _want_tree=$(jq -r .tree_id "$_desc_json" 2>/dev/null || true)
        _have_tree=$(grep -oE 'LEZ_RLN_TREE_ID_HEX=[0-9a-f]{64}' "$LEZ_RLN_DIR/testnet/env.sh" | head -1 | cut -d= -f2 || true)
        if [ -n "$_want_tree" ] && [ -n "$_have_tree" ] && [ "$_want_tree" != "$_have_tree" ]; then
            log "  Staged fixtures are for tree ${_have_tree:0:8}…; deployment '$DEPLOYMENT' wants ${_want_tree:0:8}… — restaging"
            mv "$LEZ_RLN_DIR/testnet" "$LEZ_RLN_DIR/testnet.stale-$(date +%s)"
        fi
    fi
    if [ ! -f "$LEZ_RLN_DIR/testnet/storage.json.seed" ] \
       && [ -x "$LEZ_RLN_DIR/tools/deployments/stage.sh" ] \
       && [ -d "$LEZ_RLN_DIR/deployments/$DEPLOYMENT" ]; then
        log "  Auto-staging testnet fixtures from deployments/$DEPLOYMENT"
        bash "$LEZ_RLN_DIR/tools/deployments/stage.sh" \
            "$LEZ_RLN_DIR/deployments/$DEPLOYMENT" \
            "$LEZ_RLN_DIR/testnet" || die "stage.sh failed"
    fi
    # Funding mode, staged by stage.sh (deploy-policies): "faucet" claims a
    # per-run budget at run start; absent/other => legacy run_setup funding.
    FUNDING_MODE=$(tr -d '\n\r' < "$LEZ_RLN_DIR/testnet/funding.txt" 2>/dev/null || true)
    # Tree lifecycle (see QUICKSTART "Testnet tree lifecycle"): SIM_FRESH_TREE=1
    # mints a new random tree id — run_setup takes the first-run path (programs
    # already deployed are skipped; a fresh 100B RLNTOK supply is created;
    # ~10 min of block-seal waits). The id persists in .tree_id_hex next to
    # this script and later runs reuse it. Resolution precedence:
    # SIM_FRESH_TREE > explicit env > .tree_id_hex > descriptor > default.
    TREE_ID_FILE="$SCRIPT_DIR/.tree_id_hex"
    if [ "${SIM_FRESH_TREE:-0}" = "1" ]; then
        LEZ_RLN_TREE_ID_HEX="$(openssl rand -hex 32)"
        printf '%s\n' "$LEZ_RLN_TREE_ID_HEX" > "$TREE_ID_FILE"
        log "  SIM_FRESH_TREE=1: minted tree id $LEZ_RLN_TREE_ID_HEX (persisted to .tree_id_hex)"
    elif [ -z "${LEZ_RLN_TREE_ID_HEX:-}" ] && [ -f "$TREE_ID_FILE" ]; then
        if [ "${FUNDING_MODE:-}" = "faucet" ]; then
            # A faucet deployment is staged: its descriptor tree wins over a
            # leftover private tree. Use SIM_FRESH_TREE=1 or an explicit
            # LEZ_RLN_TREE_ID_HEX to opt back into the private-tree flow.
            log "  Ignoring stale .tree_id_hex (faucet deployment '$DEPLOYMENT' staged)"
        else
            LEZ_RLN_TREE_ID_HEX="$(tr -d '\n\r' < "$TREE_ID_FILE")"
            log "  Tree id from .tree_id_hex: $LEZ_RLN_TREE_ID_HEX"
        fi
    fi
    # Read tree_id from the descriptor directly — do NOT source testnet/env.sh
    # here (it reassigns SCRIPT_DIR when sourced, clobbering the sim's own).
    if [ -z "${LEZ_RLN_TREE_ID_HEX:-}" ]; then
        _desc_json="$LEZ_RLN_DIR/deployments/${DEPLOYMENT:-shared-5ade-v2}/deployment.json"
        if [ -f "$_desc_json" ] && command -v jq >/dev/null; then
            LEZ_RLN_TREE_ID_HEX="$(jq -r .tree_id "$_desc_json")"
        fi
    fi
fi

# Deployment-specific tree id. Sourced from the on-chain registrar this sim
# targets; bump together with the registrar's deploy. NOT hardcoded in Rust
# source — lez-rln binaries read LEZ_RLN_TREE_ID_HEX from the env, so we
# export it for run_setup. Override at invocation by setting the env var.
TREE_ID_HEX="${LEZ_RLN_TREE_ID_HEX:-000102030405060708090a0b0c0d0e0f1011121314151617a0cba6e85ca1e26e}"
export LEZ_RLN_TREE_ID_HEX="$TREE_ID_HEX"
GIFTER_ACCOUNT_FILE="$HOME/.logos-lez-rln/payment_account_${TREE_ID_HEX}.txt"

# Local: clean wallet each run so run_setup re-deploys.
# Testnet: persist wallet + on-chain state; run_setup short-circuits via
# is_initialized() into create_funded_user.
if [ "$SIM_NETWORK" = local ] && [ "${SIM_PERSIST_LOCAL:-0}" != "1" ]; then
    rm -f "$WALLET_CONFIG" "$WALLET_STORAGE"
fi

# Testnet bootstrap: seed wallet + supply-holding sidecar from the
# submodule-shipped artifacts on first run. After that, create_funded_user
# draws fresh per-dev payment accounts from the shared supply.
if [ "$SIM_NETWORK" = testnet ]; then
    # Copy shipped seed -> runtime location iff runtime is missing.
    seed_copy() {
        local label="$1" src="$2" dst="$3"
        [ -f "$dst" ] && return 0
        [ -f "$src" ] || return 0
        log "  Seeding $label -> $dst"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    }
    seed_copy "testnet wallet" \
        "$LEZ_RLN_DIR/testnet/storage.json.seed" "$WALLET_STORAGE"
    seed_copy "supply holding sidecar" \
        "$LEZ_RLN_DIR/testnet/supply_holding.txt" \
        "$HOME/.logos-lez-rln/supply_holding_${TREE_ID_HEX}.txt"
    seed_copy "payment account sidecar" \
        "$LEZ_RLN_DIR/testnet/payment_account.txt" \
        "$HOME/.logos-lez-rln/payment_account_${TREE_ID_HEX}.txt"
fi

# Supply preflight (testnet): run_setup's funding transfer fails SILENTLY
# on-chain when the tree's supply holding runs dry — the sequencer confirms
# submission only — and surfaces ~180s later as the misleading "Timeout
# waiting for account ... to be initialized" panic. Each --fresh run draws
# USER_FUNDING (10B RLNTOK) from the per-tree supply (100B minted at tree
# creation => ~9 runs per tree). Check the balance up front and fail with
# the real story. Skips quietly when the sidecar is absent (fresh tree) or
# the RPC/python probe fails (never blocks the run on tooling). Skipped on
# SIM_FRESH_TREE runs: the sidecar (if seeded) predates the just-minted tree
# and run_setup's first-run path creates a fresh supply anyway. Also skipped
# for faucet-funded deployments — there is no drainable supply to check.
if [ "$SIM_NETWORK" = testnet ] && [ "${SIM_SLIM:-0}" != "1" ] && [ "${SIM_FRESH_TREE:-0}" != "1" ] \
        && [ "${FUNDING_MODE:-}" != "faucet" ]; then
    _supply_file="$HOME/.logos-lez-rln/supply_holding_${TREE_ID_HEX}.txt"
    if [ -f "$_supply_file" ]; then
        _supply_acct=$(tr -d '\n\r' < "$_supply_file")
        _supply_balance=$(curl -s -m 15 -X POST -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccount\",\"params\":[\"$_supply_acct\"]}" \
            "$TESTNET_RPC_URL" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)["result"]["data"]
    print(int.from_bytes(bytes(d[33:49]),"little") if len(d)==49 else "")
except Exception:
    print("")' 2>/dev/null)
        if [ -n "$_supply_balance" ] && [ "$_supply_balance" -lt 10000000000 ] 2>/dev/null; then
            die "supply drained: tree ${TREE_ID_HEX:0:8}… holding $_supply_acct has $_supply_balance RLNTOK, below the 10B a --fresh run draws. run_setup would fail ~3 min in with 'Timeout waiting for account ... to be initialized'. Mint a fresh tree with SIM_FRESH_TREE=1 (or export a new LEZ_RLN_TREE_ID_HEX)."
        elif [ -n "$_supply_balance" ]; then
            log "  Supply preflight: $_supply_balance RLNTOK on tree ${TREE_ID_HEX:0:8}… ($((_supply_balance / 10000000000)) fresh runs left)"
        fi
    fi
fi

# Slim mode (SIM_SLIM=1, testnet only): skip run_setup when the shipped
# config_account + cached payment_account are both present — lets fresh
# clones avoid building lez-rln/run_setup. The shared payment_account is
# signed in storage.json.seed and has enough RLNTOK for ~1M Register txs.
# Experimental; the default run_setup path is better-tested.
CONFIG_ACCOUNT_SEED="$LEZ_RLN_DIR/testnet/config_account.txt"
SLIM=0
if [ "$SIM_NETWORK" = testnet ] && [ "${SIM_SLIM:-0}" = "1" ] \
        && [ -f "$CONFIG_ACCOUNT_SEED" ] && [ -f "$GIFTER_ACCOUNT_FILE" ]; then
    SLIM=1
fi
if [ "$SIM_NETWORK" = testnet ] && [ "${FUNDING_MODE:-}" = "faucet" ] && [ "${SIM_FRESH_TREE:-0}" != "1" ]; then
    # Faucet-funded deployment: no run_setup, no pre-funded payment account.
    # The per-run gifter budget is claimed from the program-owned faucet PDA
    # by a short funding-bootstrap daemon after module bundling (below) —
    # GIFTER_ACCOUNT is resolved there.
    log "  Faucet deployment '$DEPLOYMENT': skipping run_setup (budget claimed after bundling)"
    [ -f "$CONFIG_ACCOUNT_SEED" ] || die "faucet deployment staged without config_account.txt"
    CONFIG_ACCOUNT=$(tr -d '\n\r' < "$CONFIG_ACCOUNT_SEED")
    GIFTER_ACCOUNT=""
elif [ "$SLIM" = "1" ]; then
    log "  Slim mode: skipping run_setup (using shipped config_account + cached payment_account)"
    CONFIG_ACCOUNT=$(tr -d '\n\r' < "$CONFIG_ACCOUNT_SEED")
    GIFTER_ACCOUNT=$(cat "$GIFTER_ACCOUNT_FILE")
else
    # pyo3 (via the wallet dep chain) may link the CLT Python framework,
    # which resolves only with an explicit framework path (same export as
    # tools/deployments/provision.sh).
    _dyfw="${DYLD_FRAMEWORK_PATH:-/Library/Developer/CommandLineTools/Library/Frameworks}"
    if [ -x "$LEZ_RLN_DIR/lez-rln/target/debug/run_setup" ]; then
        SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR/lez-rln" && DYLD_FRAMEWORK_PATH="$_dyfw" ./target/debug/run_setup 2>&1) || { echo "$SETUP_OUTPUT" | tail -30; die "run_setup failed"; }
    else
        SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR/lez-rln" && DYLD_FRAMEWORK_PATH="$_dyfw" cargo run --bin run_setup 2>&1) || { echo "$SETUP_OUTPUT" | tail -30; die "run_setup failed"; }
    fi
    echo "$SETUP_OUTPUT" | tail -4
    # Both deploy + already-initialized branches print "Config account:".
    CONFIG_ACCOUNT=$(echo "$SETUP_OUTPUT" | grep -oE 'Config account:\s+\S+' | awk '{print $NF}' || true)
    [ -z "$CONFIG_ACCOUNT" ] && die "Failed to parse config account"
    GIFTER_ACCOUNT=$(cat "$GIFTER_ACCOUNT_FILE" 2>/dev/null || true)
    [ -z "$GIFTER_ACCOUNT" ] && die "Gifter account not found at $GIFTER_ACCOUNT_FILE"
fi
echo "  CONFIG_ACCOUNT=$CONFIG_ACCOUNT"
echo "  GIFTER_ACCOUNT=${GIFTER_ACCOUNT:-(faucet: claimed after bundling)}"

# EIP-191 auth fixtures: secp256k1 keys + gifter (mix node 0) allowlist.
# Committed test fixtures only — do NOT reuse in prod.
GIFTER_AUTH_DIR="$SCRIPT_DIR/fixtures/gifter_auth"
# shellcheck disable=SC1091
source "$GIFTER_AUTH_DIR/keys.env"
# shellcheck disable=SC1091
source "$GIFTER_AUTH_DIR/addresses.env"
GIFTER_ALLOWLIST="$ADDR_MIX1,$ADDR_MIX2,$ADDR_MIX3,$ADDR_SENDER,$ADDR_RECEIVER,$ADDR_RECEIVER2"
echo "  Gifter allowlist: $GIFTER_ALLOWLIST"

# ---------- Phase 3: Prerequisites ----------
echo "[3/6] Verifying prerequisites..."
# Use liblogos's native SDK pin — overriding to 1468180b breaks liblogos
# 7df6195's source (uses old requestObject/onEvent shapes). Plugins built
# via logos-module-builder use SDK 8bdbd13 transitively; smoke load shows
# they're ABI-compatible with the native build.
LOGOSCORE="${LOGOSCORE:-$(nix build github:logos-co/logos-logoscore-cli --no-link --print-out-paths)/bin/logoscore}"

# Build .lgx bundles for all four plugins. nix bundle is cached so this is fast
# after the first run. The new logoscore-cli discovers modules by reading
# manifest.json from each module subdir, not raw .dylib filenames.
log "  Bundling .lgx packages..."
# Optional `extra_args...` flow through to nix bundle (e.g. --override-input).
#
# Bundles are pinned under $LGX_CACHE_DIR (default ~/.cache/sim-lgx) as
# indirect GC roots so nix-collect-garbage can't blow them away between
# runs. On re-entry we resolve the symlink and reuse the cached .lgx
# directly, skipping nix bundle entirely. Set SIM_REBUILD_LGX=1 to force
# a fresh bundle (e.g. after editing module sources).
LGX_CACHE_DIR="${LGX_CACHE_DIR:-$HOME/.cache/sim-lgx}"
mkdir -p "$LGX_CACHE_DIR"
lgx_from() {
    local dir="$1" attr="$2"; shift 2
    local cache_key="${dir//\//_}__${attr}"
    local gc_link="$LGX_CACHE_DIR/$cache_key"

    # Tier 0: authoritative — flake exposes a content-addressed .lgx output
    # (either `.#<attr>` already .lgx-shaped, or `.#<attr>-lgx` bundled).
    # Whichever resolves is deterministic w.r.t. source, so we never risk a
    # /nix/store lottery. Skip when SIM_REBUILD_LGX is set only if the caller
    # also wants to bypass this — the flake output IS the fresh build.
    local flake_attr=""
    if (cd "$dir" && nix eval --raw ".#${attr}-lgx" >/dev/null 2>&1); then
        flake_attr="${attr}-lgx"
    elif (cd "$dir" && nix eval --raw ".#${attr}" 2>/dev/null | grep -q '\-lgx-'); then
        flake_attr="${attr}"
    fi
    if [ -n "$flake_attr" ]; then
        local store_path store_lgx
        store_path=$(cd "$dir" && nix build --no-link --print-out-paths ".#$flake_attr" 2>/dev/null) \
            || die "nix build .#$flake_attr failed in $dir"
        store_lgx=$(find "$store_path" -maxdepth 1 -name '*.lgx' 2>/dev/null | head -1)
        if [ -f "$store_lgx" ]; then
            log "  lgx_from $attr: using flake output .#$flake_attr ($(basename "$store_lgx"))" >&2
            nix-store --add-root "$gc_link" --indirect -r "$store_path" >/dev/null 2>&1 || true
            printf '%s' "$store_lgx"
            return 0
        fi
    fi

    # Tier 1: per-sim GC-link cache from a previous run (fastest).
    if [ -z "${SIM_REBUILD_LGX:-}" ] && [ -L "$gc_link" ]; then
        local cached_path cached_lgx
        cached_path=$(readlink "$gc_link")
        cached_lgx=$(find "$cached_path" -maxdepth 1 -name "*.lgx" 2>/dev/null | head -1)
        if [ -f "$cached_lgx" ]; then
            printf '%s' "$cached_lgx"
            return 0
        fi
        rm -f "$gc_link"
    fi

    # Tier 2: any pre-built .lgx already in /nix/store. Prefers cached output
    # over rebuilding because `nix bundle` for these modules transitively
    # fetches Rust crates from crates.io's static.crates.io endpoint, which
    # 403s often enough that "rebuild on every fresh clone" is unreliable.
    # SIM_REBUILD_LGX=1 forces a fresh bundle when source changes need to
    # take effect.
    if [ -z "${SIM_REBUILD_LGX:-}" ]; then
        local pattern=""
        case "$attr" in
            wallet-module)    pattern="logos*execution*zone*-module*.lgx" ;;
            logos-rln-module) pattern="logos-rln-module*.lgx" ;;
            lib)
                # disambiguate by the source dir
                if [[ "$dir" == *chat-module* ]]; then
                    pattern="logos-chat_module-module-lib*.lgx"
                else
                    pattern="logos-delivery_module-module-lib*.lgx"
                fi
                ;;
        esac
        if [ -n "$pattern" ]; then
            local store_lgx
            store_lgx=$(find /nix/store -maxdepth 3 -name "$pattern" 2>/dev/null | head -1)
            if [ -f "$store_lgx" ]; then
                # stderr — stdout is the function's return channel for the path.
                log "  lgx_from $attr: using prebuilt $(basename "$store_lgx") from /nix/store" >&2
                # Pin a GC root so the chosen .lgx survives nix-collect-garbage.
                local store_dir; store_dir=$(dirname "$store_lgx")
                nix-store --add-root "$gc_link" --indirect -r "$store_dir" >/dev/null 2>&1 || true
                printf '%s' "$store_lgx"
                return 0
            fi
        fi
    fi

    # Tier 3: no cache hit, build fresh via nix bundle.
    local out_link store_path lgx
    out_link=$(mktemp -d)/result
    (cd "$dir" && nix bundle --bundler github:logos-co/nix-bundle-lgx "$@" --out-link "$out_link" ".#$attr" >/dev/null 2>&1) \
        || die "nix bundle failed in $dir for $attr"
    store_path=$(readlink "$out_link")
    lgx=$(find "$store_path" -maxdepth 1 -name "*.lgx" | head -1)
    rm -f "$out_link"; rmdir "$(dirname "$out_link")" 2>/dev/null || true
    [ -f "$lgx" ] || die "no .lgx in bundle output for $attr (looked at $store_path)"
    nix-store --add-root "$gc_link" --indirect -r "$store_path" >/dev/null 2>&1 || true
    printf '%s' "$lgx"
}
# .lgx precedence:
#   1. explicit env vars (WALLET_LGX / RLN_LGX / DELIVERY_LGX / CHAT_LGX) win
#   2. LGX_CACHE_DIR GC link from a previous run of this sim
#   3. lgx_from auto-discovers a matching .lgx already in /nix/store
#   4. nix bundle rebuilds from source
# SIM_REBUILD_LGX=1 forces tier 4 (use after editing module sources).
#
# wallet-module override chain:
# - logos-execution-zone-module: upstream pin lacks the `send_public_transaction`
#   Q_INVOKABLE that register_member's tx-submit path requires; without it
#   selfRegisterRln fails with "register_member failed" → "RLN config not set
#   on gifter node".
# - lssa: carries `SequencerClientBuilder::request_timeout(...)` on the wallet's
#   Rust HTTP client. A stuck sequencer response would otherwise block_on()
#   forever inside the FFI, freezing the wallet plugin's Qt thread and
#   cascading through the rln_fetcher trampoline into delivery_module's
#   chronos loop (libp2p stops accepting gifter codec dials).
WALLET_LGX=${WALLET_LGX:-$(lgx_from "$LEZ_RLN_DIR" "wallet-module" \
    --override-input logos-wallet-module "path:$LEZ_RLN_DIR/logos-execution-zone-module" \
    --override-input logos-wallet-module/logos-execution-zone "path:$LEZ_RLN_DIR/lssa")}
RLN_LGX=${RLN_LGX:-$(lgx_from "$LEZ_RLN_DIR" "logos-rln-module")}
DELIVERY_LGX=${DELIVERY_LGX:-$(lgx_from "$DELIVERY_MODULE_DIR" "lib")}
CHAT_LGX=${CHAT_LGX:-$(lgx_from "$CHAT_MODULE_DIR" "lib")}

# liblogosdelivery.dylib is stripped by nix-bundle-lgx, so we patch it into the
# delivery_module's runtime dir post-install. The dylib is the Nim-built backend
# behind the C++ delivery_module_plugin.dylib; without it the plugin's dlopen
# fails with `symbol not found: _logosdelivery_get_available_configs`. Pick the
# 17-symbol version — older 8-symbol builds linger in /nix/store and would
# silently load but fail at first call (missing FFI entrypoints).
pick_lib_with_min_symbols() {
    local pattern="$1" symbol_prefix="$2" min_count="$3"
    local cand
    for cand in $(find /nix/store -maxdepth 5 -path "$pattern" 2>/dev/null); do
        local n; n=$(nm -gU "$cand" 2>/dev/null | grep -c "$symbol_prefix") || true
        [ "${n:-0}" -ge "$min_count" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}
if [ -z "${DELIVERY_EXTRA_LIB:-}" ]; then
    # Prefer the vendor working-copy build over /nix/store hits — the
    # local build has the gifter mount code ("RLN gifter service mounted for
    # mix"). The nix-store builds of logos-delivery-module-lib (e.g.
    # ng60yfx... 48MB) lack gifter mount and produce 14/15 PASS at best with
    # receiver-message-delivery the only fail. The local build is 53MB+.
    if [ ! -f "$DELIVERY_DIR/build/liblogosdelivery.$EXT" ]; then
        # Fresh clone — no local build yet. Auto-clone + `make liblogosdelivery`
        # in vendor/logos-delivery rather than falling through to a stale
        # /nix/store hit that lacks gifter mount and would silently produce a
        # 14/15-PASS run. The repo is NOT a git submodule of logos-delivery-
        # module (vendor/* is .gitignored there); the canonical setup clones
        # adklempner/logos-delivery into this path on first use. Takes ~5-10
        # min on first call; subsequent runs reuse the local build.
        if [ ! -d "$DELIVERY_DIR/.git" ]; then
            log "  Cloning vendor/logos-delivery..."
            DELIVERY_REPO="${DELIVERY_REPO:-git@github.com:adklempner/logos-delivery.git}"
            DELIVERY_BRANCH="${DELIVERY_BRANCH:-rebase/add-mix-rln-spam-plugin-submodule}"
            git clone -b "$DELIVERY_BRANCH" "$DELIVERY_REPO" "$DELIVERY_DIR" 2>&1 | tail -3 \
                || die "git clone $DELIVERY_REPO failed"
            (cd "$DELIVERY_DIR" && git submodule update --init --recursive 2>&1 | tail -3) \
                || die "delivery submodule init failed"
        fi
        log "  Local liblogosdelivery.$EXT missing — building via make..."
        # Patch nimble.lock for the nimble 0.22.3 URL bug before invoking nimble.
        # Idempotent: skips if patches are already applied.
        patch_delivery_nimble_lock
        (cd "$DELIVERY_DIR" && make -j4 liblogosdelivery 2>&1 | tail -3) \
            || die "make liblogosdelivery failed in $DELIVERY_DIR"
    fi
    if [ -f "$DELIVERY_DIR/build/liblogosdelivery.$EXT" ]; then
        DELIVERY_EXTRA_LIB="$DELIVERY_DIR/build/liblogosdelivery.$EXT"
    else
        DELIVERY_EXTRA_LIB=$(pick_lib_with_min_symbols "*logos-delivery-module-lib*/lib/liblogosdelivery.$EXT" "_logosdelivery_" 15)
    fi
fi
[ -f "$DELIVERY_EXTRA_LIB" ] || die "liblogosdelivery.$EXT (17-symbol) not found; build delivery-module first or set DELIVERY_EXTRA_LIB"

# chat_module has the same flat-namespace gap on liblogoschat.dylib.
if [ -z "${CHAT_EXTRA_LIB:-}" ]; then
    if [ ! -f "$LOGOS_CHAT_DIR/build/liblogoschat.$EXT" ]; then
        # Same auto-build pattern as liblogosdelivery — the Nim chat lib
        # is produced by `make liblogoschat` from $LOGOS_CHAT_DIR. Skipping
        # this on a fresh clone falls through to a stale /nix/store hit.
        log "  Local liblogoschat.$EXT missing — building via make..."
        # PR #3807 carcass + nimbledeps prep. Both idempotent.
        rename_libp2p_carcass
        mirror_chat_nimbledeps
        (cd "$LOGOS_CHAT_DIR" && make update && make liblogoschat 2>&1 | tail -3) \
            || die "make liblogoschat failed in $LOGOS_CHAT_DIR"
    fi
    if [ -f "$LOGOS_CHAT_DIR/build/liblogoschat.$EXT" ]; then
        CHAT_EXTRA_LIB="$LOGOS_CHAT_DIR/build/liblogoschat.$EXT"
    else
        CHAT_EXTRA_LIB=$(find /nix/store -maxdepth 5 -path "*logos-chat-module*/lib/liblogoschat.$EXT" 2>/dev/null | head -1)
    fi
fi
[ -f "$CHAT_EXTRA_LIB" ] || die "liblogoschat.$EXT not found; build chat lib first or set CHAT_EXTRA_LIB"
for lgx in "$WALLET_LGX" "$RLN_LGX" "$DELIVERY_LGX" "$CHAT_LGX"; do
    [ -f "$lgx" ] || die "Missing .lgx: $lgx"
done
log "  All .lgx bundles present."

# ---------- Phase 4: Start mix nodes ----------
echo "[4/6] Starting $NUM_NODES mix+LEZ nodes..."
LOAD_ORDER="logos_execution_zone,liblogos_rln_module,delivery_module"
WALLET_CALL="logos_execution_zone.open($WALLET_CONFIG,$WALLET_STORAGE)"
BOOTSTRAP_PEER="/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}"

# All RLN memberships are issued at runtime by the gifter on node 0 — no
# off-chain setup_credentials / pre-registration step.

# Faucet funding bootstrap (deploy-policies deployments, funding=faucet):
# claim the run's gifter budget from the program-owned faucet PDA before any
# node config is written (GIFTER_ACCOUNT feeds node 0's delivery config).
# Mirrors the docker sim's orchestrate.sh gifter block: derive the first
# key-chain account with no on-chain holding, claim CLAIM_BUDGET in
# CLAIM_CHUNK slices (each capped on-chain by the deployment's
# faucet_claim_cap), and poll get_token_balance until the credit lands.
# A full 15-check run burns ~6M RLNTOK (6 registrations at rate_limit=100 ×
# price_per_unit=10000); the 10M default leaves slack for retries.
if [ "$SIM_NETWORK" = testnet ] && [ "${FUNDING_MODE:-}" = "faucet" ] && [ -z "$GIFTER_ACCOUNT" ]; then
    CLAIM_BUDGET="${CLAIM_BUDGET:-10000000}"
    CLAIM_CHUNK="${CLAIM_CHUNK:-10000000}"
    log "  Faucet funding: claiming $CLAIM_BUDGET RLNTOK for this run..."
    BOOT_LOG="$STATE_DIR/funding_bootstrap.log"
    BOOT_MDIR=$(mktemp -d); MODULES_DIRS+=("$BOOT_MDIR")
    install_lgx "$BOOT_MDIR" "$WALLET_LGX"
    install_lgx "$BOOT_MDIR" "$RLN_LGX"
    if [ -n "${WALLET_PLUGIN_OVERRIDE:-}" ] && [ -f "$WALLET_PLUGIN_OVERRIDE" ]; then
        cp "$WALLET_PLUGIN_OVERRIDE" "$BOOT_MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib"
        codesign --force --sign - "$BOOT_MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib" 2>/dev/null || true
    fi
    if [ -n "${RLN_PLUGIN_OVERRIDE:-}" ] && [ -f "$RLN_PLUGIN_OVERRIDE" ]; then
        cp "$RLN_PLUGIN_OVERRIDE" "$BOOT_MDIR/liblogos_rln_module/liblogos_rln_module.dylib"
        codesign --force --sign - "$BOOT_MDIR/liblogos_rln_module/liblogos_rln_module.dylib" 2>/dev/null || true
    fi
    start_logoscore_instance "$BOOT_LOG" "$BOOT_MDIR" "logos_execution_zone,liblogos_rln_module" \
        "$WALLET_CALL" || true
    BOOT_CFG="$LAST_DAEMON_CFG"; BOOT_PID="$LAST_DAEMON_PID"
    _fb_args=$(mktemp -d); INSTANCE_CFG_DIRS+=("$_fb_args")
    printf '%s' "$CONFIG_ACCOUNT" > "$_fb_args/config.arg"

    # Derive the first key-chain account with no on-chain holding (previous
    # runs consumed earlier derivations; the walk lands one past them).
    HOLDING=""
    for _t in $(seq 1 30); do
        ACC=$(call_json "$BOOT_CFG" logos_execution_zone create_account_public | jres) || ACC=""
        [ -n "$ACC" ] || { sleep 2; continue; }
        printf '%s' "$ACC" > "$_fb_args/acc.arg"
        BAL_JSON=""
        for _r in 1 2 3; do
            BAL_JSON=$(call_json "$BOOT_CFG" liblogos_rln_module get_token_balance "@$_fb_args/acc.arg" | jres) || BAL_JSON=""
            [ -n "$BAL_JSON" ] && break
            sleep 2
        done
        case "$BAL_JSON" in
            *'"exists":false'*|*'"exists": false'*) HOLDING="$ACC"; break ;;
        esac
    done
    [ -n "$HOLDING" ] || die "faucet bootstrap: no unused holding after 30 derivations (see $BOOT_LOG)"
    log "    Fresh holding account: $HOLDING"
    printf '%s' "$HOLDING" > "$_fb_args/holding.arg"

    _claimed=0
    while [ "$_claimed" -lt "$CLAIM_BUDGET" ]; do
        _step=$(( CLAIM_BUDGET - _claimed ))
        [ "$_step" -gt "$CLAIM_CHUNK" ] && _step="$CLAIM_CHUNK"
        printf '%s' "$_step" > "$_fb_args/amount.arg"
        CLAIM_RES=$(call_json "$BOOT_CFG" liblogos_rln_module claim_tokens \
            "@$_fb_args/config.arg" "@$_fb_args/holding.arg" "@$_fb_args/amount.arg" | jres) || CLAIM_RES=""
        [ -n "$CLAIM_RES" ] || die "faucet bootstrap: claim_tokens failed (see $BOOT_LOG)"
        _claimed=$(( _claimed + _step ))
    done
    log "    Claimed $_claimed (chunks of ≤$CLAIM_CHUNK); waiting for on-chain credit..."

    _bal=0
    for _t in $(seq 1 36); do
        BAL_JSON=$(call_json "$BOOT_CFG" liblogos_rln_module get_token_balance "@$_fb_args/holding.arg" | jres) || BAL_JSON=""
        _bal=$(printf '%s' "$BAL_JSON" | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin).get("balance", "0")))
except Exception:
    print(0)') || _bal=0
        [ -n "$_bal" ] || _bal=0
        log "    credit poll $_t: balance=$_bal (raw: ${BAL_JSON:-<empty>})"
        [ "$_bal" -ge "$CLAIM_BUDGET" ] && break
        sleep 5
    done
    [ "$_bal" -ge "$CLAIM_BUDGET" ] || die "faucet bootstrap: budget not credited (balance=$_bal, want $CLAIM_BUDGET) — see $BOOT_LOG"
    kill "$BOOT_PID" 2>/dev/null || true
    pkill -f "logoscore -m $BOOT_MDIR" 2>/dev/null || true
    GIFTER_ACCOUNT="$HOLDING"
    log "  Faucet funding done: GIFTER_ACCOUNT=$GIFTER_ACCOUNT (balance $_bal)"
fi

for i in $(seq 0 $((NUM_NODES - 1))); do
    TCP_PORT=$((BASE_TCP_PORT + i)); DISC_PORT=$((BASE_DISC_PORT + i))
    NODE_CONFIG="$STATE_DIR/node${i}_config.json"
    LOG_FILE="$STATE_DIR/node${i}.log"
    KAD_BOOTSTRAP="[]"; [ "$i" -gt 0 ] && KAD_BOOTSTRAP="[\"$BOOTSTRAP_PEER\"]"
    PEER_LIST=""
    for j in $(seq 0 $((NUM_NODES - 1))); do
        [ "$j" -eq "$i" ] && continue
        [ -n "$PEER_LIST" ] && PEER_LIST="$PEER_LIST,"
        PEER_LIST="$PEER_LIST\"/ip4/127.0.0.1/tcp/$((BASE_TCP_PORT + j))/p2p/${PEER_IDS[$j]}\""
    done
    STATIC_PEERS="[$PEER_LIST]"

    GIFTER_FIELDS=""
    if [ "$i" -eq 0 ]; then
        GIFTER_FIELDS="\"mixGifterService\": true, \"mixGifterWalletAccount\": \"$GIFTER_ACCOUNT\", \"mixGifterAllowlist\": \"$GIFTER_ALLOWLIST\","
    else
        # KEY_MIX{1..3} align with non-gifter nodes 1..3.
        AUTH_KEY_VAR="KEY_MIX$i"
        GIFTER_FIELDS="\"mixGifterNode\": \"$BOOTSTRAP_PEER\", \"mixGifterWalletAccount\": \"$GIFTER_ACCOUNT\", \"mixGifterAuthKey\": \"${!AUTH_KEY_VAR}\","
    fi

    # Config-v3 shape: mode replaces the old flat protocol flags; kernel-only
    # options (mix, discovery, static peers) ride in kernelOverrides.
    # discv5Discovery=false preserves the pre-v3 default (Core turns it on).
    cat > "$NODE_CONFIG" <<EOF
{
  "mode": "Core",
  "kernelOverrides": {
    "clusterId": $CLUSTER_ID,
    "numShardsInNetwork": $NUM_SHARDS,
    "listenAddress": "127.0.0.1",
    "tcpPort": $TCP_PORT,
    "websocketPort": $((TCP_PORT + 1000)),
    "discv5UdpPort": $DISC_PORT,
    "discv5Discovery": false,
    "nat": "extip:127.0.0.1",
    "extMultiAddrs": ["/ip4/127.0.0.1/tcp/$TCP_PORT"],
    "extMultiAddrsOnly": true,
    "nodekey": "${NODEKEYS[$i]}",
    "staticnodes": $STATIC_PEERS,
    "relay": true,
    "lightpush": true,
    "filter": true,
    "mix": true,
    "mixkey": "${MIXKEYS[$i]}",
    "mixOnchainLEZ": true,
    $GIFTER_FIELDS
    "enableKadDiscovery": true,
    "kadBootstrapNodes": $KAD_BOOTSTRAP,
    "peerExchange": false,
    "rendezvous": false,
    "colocationLimit": 0,
    "logLevel": "$LOG_LEVEL"
  }
}
EOF

    MDIR=$(mktemp -d); MODULES_DIRS+=("$MDIR")
    install_lgx "$MDIR" "$WALLET_LGX"
    install_lgx "$MDIR" "$RLN_LGX"
    install_lgx "$MDIR" "$DELIVERY_LGX"
    install_extra_lib "$MDIR" delivery_module "$DELIVERY_EXTRA_LIB"
    # Optional delivery_module_plugin.dylib override (same rationale as
    # CHAT_PLUGIN_OVERRIDE): drop-in replacement carrying the createNode
    # patch that installs logosdelivery_set_rln_fetcher unconditionally, so
    # non-gifter mix nodes — which never call setRlnConfig from outside —
    # still get the C++→Nim rln_fetcher trampoline wired. Otherwise their
    # spam-protection groupManager's poll loop hits "RLN fetcher not
    # registered", cachedProof never lands, isReady stays false, and every
    # sphinx hop fails "Failed to generate spam protection proof for next
    # hop: Plugin not ready" → SURB timeout on sender.
    if [ -n "${DELIVERY_PLUGIN_OVERRIDE:-}" ] && [ -f "$DELIVERY_PLUGIN_OVERRIDE" ]; then
        cp "$DELIVERY_PLUGIN_OVERRIDE" "$MDIR/delivery_module/delivery_module_plugin.dylib"
        codesign --force --sign - "$MDIR/delivery_module/delivery_module_plugin.dylib" 2>/dev/null || true
    fi
    if [ -n "${RLN_PLUGIN_OVERRIDE:-}" ] && [ -f "$RLN_PLUGIN_OVERRIDE" ]; then
        cp "$RLN_PLUGIN_OVERRIDE" "$MDIR/liblogos_rln_module/liblogos_rln_module.dylib"
        codesign --force --sign - "$MDIR/liblogos_rln_module/liblogos_rln_module.dylib" 2>/dev/null || true
    fi
    # Optional logos_execution_zone_plugin.dylib override (same mechanism as
    # RLN_PLUGIN_OVERRIDE): drop-in replacement for the wallet plugin, e.g.
    # the Rust port (lez-wallet-module-rs), which links wallet-ffi in-process
    # and ignores the staged libwallet_ffi.dylib.
    if [ -n "${WALLET_PLUGIN_OVERRIDE:-}" ] && [ -f "$WALLET_PLUGIN_OVERRIDE" ]; then
        cp "$WALLET_PLUGIN_OVERRIDE" "$MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib"
        codesign --force --sign - "$MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib" 2>/dev/null || true
    fi
    # Note: mix nodes do NOT get DELIVERY_DYLIB_OVERRIDE / librln.dylib swaps.
    # The .lgx-shipped liblogosdelivery+librln pair works for the mix-node code
    # path (verified when self-registration succeeds and `LEZ root events` land).
    # Swapping to a nix-built liblogosdelivery+librln pair crashes in
    # createRLNInstance (SIGSEGV in newRLNInstance) — the plugin's C++ code
    # against the newer liblogosdelivery.dylib does hit that override, but its
    # `selfRegisterRln` codepath is different from the mix-mount RLN codepath.
    # See stage_chat_module for the receiver/sender flavor where the swap IS
    # needed (they hit createNode which pulls in _ffi_bytes_le_to_cfr).

    log "  Starting node $i (port $TCP_PORT)..."
    # Node 0 is the gifter — it must self-register on-chain (paying its own
    # RLNTOK from $GIFTER_ACCOUNT) so its mix init can complete and the gifter
    # service can mount. Nodes 1-3 register via the gifter protocol AUTOMATICALLY
    # during Nim startNode() (triggered by mixGifterNode config), so the sim
    # must NOT call setRlnConfig for them — that's the gifter's job and a
    # manual call would overwrite the gifter-assigned leaf. The new
    # OnchainLEZGroupManager.register() explicitly bans Self-registration to
    # force everything through selfRegisterRln (for the gifter) or the gifter
    # protocol (for everyone else).
    if [ "$i" -eq 0 ]; then
        # Wallet needs an explicit sync to bring its account state up to current
        # chain height before register_member can construct a valid tx — open()
        # alone leaves last_synced_block=0 even though storage.json knows about
        # accounts at higher chain_index values. Query sequencer for current
        # head and pass as the sync target.
        # Probe sequencer for current head. On testnet there's no local
        # server on 3040; use the testnet RPC URL instead. Wrap in || true
        # to defuse set -e under pipefail when curl returns connection-refused.
        if [ "$SIM_NETWORK" = "local" ]; then
            CHAIN_HEAD=$(curl -sS -m 5 -X POST -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
                http://127.0.0.1:3040/ 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' 2>/dev/null || true)
        else
            CHAIN_HEAD=$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
                "$TESTNET_RPC_URL" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' 2>/dev/null || true)
        fi
        : "${CHAIN_HEAD:=10000}"
        log "    chain head=$CHAIN_HEAD (for wallet sync)"
        # selfRegisterRln args go via @file JSON object — logoscore-cli's `call`
        # subcommand auto-coerces digit-leading positional args (e.g. base58
        # accounts like "38nxK...") to int. Wrapping all three args inside a
        # single JSON blob whose first char is `{` dodges that coercion (same
        # trick createNode already uses for its config blob).
        # Direct 3-arg selfRegisterRln — the parse_call helper at ~line 194
        # already wraps digit-leading base58 args as @tmpfile to dodge
        # logoscore-cli's numeric coercion, so the JSON wrapper variant
        # (which older plugins expose but newer ones from our local rebuild
        # don't, due to logos-cpp-generator version drift) isn't required.
        EXTRA_CALLS=(
            "logos_execution_zone.sync_to_block($CHAIN_HEAD)"
            "delivery_module.selfRegisterRln($CONFIG_ACCOUNT,$GIFTER_ACCOUNT,100)"
        )
        EXPECTED_CALLS=6
    else
        EXTRA_CALLS=()
        EXPECTED_CALLS=5
    fi
    # For non-gifter mix nodes: install C++ rln_fetcher trampoline with
    # placeholder config IMMEDIATELY AFTER createNode, BEFORE start. The
    # trampoline only needs deliveryCtx (createNode provides it); placing it
    # before start ensures it's dispatched while the daemon's Qt event loop
    # is still responsive. Nim's internal gifter registration during start()
    # later calls mix_lez_client.setRlnConfig to overwrite the placeholder
    # config with real account/leaf — the C++ fetcher install persists.
    # Without this, the spam-protection poll loop's callRlnFetcher returns
    # "RLN fetcher not registered", cachedProof never lands, every sphinx
    # hop fails "Plugin not ready". setRlnConfig also can't be issued after
    # start() because start()'s async backend saturates Qt indefinitely,
    # blocking all subsequent RPCs to delivery_module.
    # Non-gifter mix nodes get pre-start setRlnConfig (placeholder leaf=0)
    # so the C++ rln_fetcher trampoline is installed before start (Nim's
    # internal gifter-client registration during startNode() later
    # overwrites the placeholder leaf with the real on-chain leaf).
    #
    # NODE 0 (gifter) is EXCLUDED again. Setting setRlnConfig with leaf=0
    # before start triggers an ordering bug: somewhere in mix.start()'s
    # spam-protection init path, setRlnIdentity gets called and reads the
    # placeholder leaf=0; setRlnIdentity at logos_core_client.nim:137-138
    # does `if leafIdx >= 0: gmRef.membershipIndex = some(MembershipIndex(leafIdx))`
    # — the `>= 0` (vs `> 0`) check means leaf=0 looks like a valid leaf
    # and the gifter's lezGm.membershipIndex flips to Some(0). The gifter
    # self-register block at node_factory.nim:738 then SKIPS the asyncSpawn
    # (gated on `if lezGm.membershipIndex.isNone`), so the gifter never
    # self-registers on-chain. Symptom: gifter mounted, "RLN config set
    # (leaf=0)" log appears, but no "Self-registering gifter as mix relay".
    # All inbound chat-client gifter dials get "RLN config not set on
    # gifter node" because gifter has no real on-chain credentials.
    #
    # Local path: selfRegisterRlnJson succeeds within the 180s sync RPC
    # window (timeout bumped from 20s in delivery_module_plugin.cpp:702 so
    # this also works on testnet). selfRegisterRln sequences setRlnConfig
    # → setRlnIdentity with the REAL leaf, so the asyncSpawn block is
    # skipped intentionally (gifter is already registered).
    if [ "$i" -ne 0 ]; then
        PRE_START_CALLS=("delivery_module.setRlnConfig($CONFIG_ACCOUNT,0)")
    else
        PRE_START_CALLS=()
    fi
    DYLD_PRELOAD_LIBS="$DELIVERY_EXTRA_LIB" \
    start_logoscore_instance "$LOG_FILE" "$MDIR" "$LOAD_ORDER" \
        "$WALLET_CALL" \
        "delivery_module.createNode(@$NODE_CONFIG)" \
        "${PRE_START_CALLS[@]+"${PRE_START_CALLS[@]}"}" \
        "delivery_module.start()" \
        "${EXTRA_CALLS[@]+"${EXTRA_CALLS[@]}"}" \
        "delivery_module.subscribe($CONTENT_TOPIC)" || true
    wait_method_calls "$LOG_FILE" "$EXPECTED_CALLS" 90 1 || true
    if [ "${N:-0}" -ge "$EXPECTED_CALLS" ]; then
        log "    Node $i ready ($N/$EXPECTED_CALLS calls) PID: $LAST_DAEMON_PID"
    else
        echo "  WARNING: Node $i: $N/$EXPECTED_CALLS calls"
    fi
    NODE_CFG_DIRS[$i]="$LAST_DAEMON_CFG"
    sleep "$NODE_STARTUP_SLEEP"
done

# (Post-loop fetcher wiring removed — moved into the per-node EXTRA_CALLS in
#  Phase 4 above. Doing it externally after daemon stabilization doesn't work
#  because delivery_module's Qt event loop is saturated by chronos poll loops
#  within seconds of start(), making subsequent RPCs to delivery_module hang
#  indefinitely. The early-batch placeholder install runs before Qt blocks.)
echo ""

# ---------- Phase 5: Chat module sender/receiver ----------
echo "[5/6] Starting chat module instances..."

# Wait for all nodes ready (gifter registrations finalize during startup).
for i in $(seq 0 $((NUM_NODES - 1))); do
    wait_method_calls "$STATE_DIR/node${i}.log" 5 120 2 || true
done

# Wait for RLN root convergence. Mix pool is seeded from each node's
# mixNodes config (processBootNodes), so kademlia isn't required for routing —
# the kad-peer count is logged only for diagnostics.
echo "  Waiting for kademlia propagation + RLN convergence..."
KADEMLIA_T0=$SECONDS
# Block chat startup until every mix hop has RLN credentials confirmed
# on-chain — unregistered hops drop sphinx packets (Plugin not ready).
REQUIRED_CLIENT_REGS=$((NUM_NODES - 1))
while true; do
    ELAPSED=$((SECONDS - KADEMLIA_T0))
    GR=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node0.log" 2>/dev/null | grep -c "RLN gifter registration succeeded" || true); GR=${GR:-0}
    SELF=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node0.log" 2>/dev/null | grep -c "Gifter self-registered as mix relay" || true); SELF=${SELF:-0}
    LR=0
    MIX_PEERS_PER_NODE=""
    for i in $(seq 0 $((NUM_NODES - 1))); do
        LOG="$STATE_DIR/node${i}.log"
        L=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -c "Polled valid roots\|Fetched roots from\|valid_roots\|OnchainLEZGroupManager initialized\|Wired LEZ callbacks" || true)
        LR=$((LR + L))
        MP=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -c "mix peer added via kademlia lookup" || true); MP=${MP:-0}
        MIX_PEERS_PER_NODE="${MIX_PEERS_PER_NODE}n${i}=${MP} "
    done
    if [ "$ELAPSED" -ge "$KADEMLIA_MIN_WAIT" ] && [ "$GR" -ge "$REQUIRED_CLIENT_REGS" ] && [ "$SELF" -ge 1 ] && [ "$LR" -ge 40 ]; then break; fi
    [ "$ELAPSED" -ge "$KADEMLIA_HARD_CAP" ] && break
    sleep 1
done
log "  Kademlia ready after $((SECONDS - KADEMLIA_T0))s ($GR/$REQUIRED_CLIENT_REGS client regs, self=$SELF, $LR LEZ root events, kad mix peers: $MIX_PEERS_PER_NODE)"

RECEIVER_LOG="$STATE_DIR/chat_receiver.log"
SENDER_LOG="$STATE_DIR/chat_sender.log"

# Build mix node list (multiaddr:mixPubKey) for chat config.
MIXNODE_LIST=""
for j in $(seq 0 $((NUM_NODES - 1))); do
    [ -n "$MIXNODE_LIST" ] && MIXNODE_LIST="$MIXNODE_LIST,"
    MIXNODE_LIST="$MIXNODE_LIST\"/ip4/127.0.0.1/tcp/$((BASE_TCP_PORT + j))/p2p/${PEER_IDS[$j]}:${MIX_PUBKEYS[$j]}\""
done

# Stage wallet + RLN + chat modules for a logoscore instance.
stage_chat_module() {
    local MDIR=$1
    install_lgx "$MDIR" "$WALLET_LGX"
    install_lgx "$MDIR" "$RLN_LGX"
    install_lgx "$MDIR" "$DELIVERY_LGX"
    install_lgx "$MDIR" "$CHAT_LGX"
    install_extra_lib "$MDIR" chat_module "$CHAT_EXTRA_LIB"
    if [ -n "${RLN_PLUGIN_OVERRIDE:-}" ] && [ -f "$RLN_PLUGIN_OVERRIDE" ]; then
        cp "$RLN_PLUGIN_OVERRIDE" "$MDIR/liblogos_rln_module/liblogos_rln_module.dylib"
        codesign --force --sign - "$MDIR/liblogos_rln_module/liblogos_rln_module.dylib" 2>/dev/null || true
    fi
    if [ -n "${WALLET_PLUGIN_OVERRIDE:-}" ] && [ -f "$WALLET_PLUGIN_OVERRIDE" ]; then
        cp "$WALLET_PLUGIN_OVERRIDE" "$MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib"
        codesign --force --sign - "$MDIR/logos_execution_zone/logos_execution_zone_plugin.dylib" 2>/dev/null || true
    fi
    if [ -n "${DELIVERY_PLUGIN_OVERRIDE:-}" ] && [ -f "$DELIVERY_PLUGIN_OVERRIDE" ]; then
        cp "$DELIVERY_PLUGIN_OVERRIDE" "$MDIR/delivery_module/delivery_module_plugin.dylib"
        codesign --force --sign - "$MDIR/delivery_module/delivery_module_plugin.dylib" 2>/dev/null || true
    fi
    if [ -n "${DELIVERY_DYLIB_OVERRIDE:-}" ] && [ -f "$DELIVERY_DYLIB_OVERRIDE" ]; then
        cp "$DELIVERY_DYLIB_OVERRIDE" "$MDIR/delivery_module/liblogosdelivery.dylib"
        codesign --force --sign - "$MDIR/delivery_module/liblogosdelivery.dylib" 2>/dev/null || true
        # liblogosdelivery.dylib links against librln.dylib for zerokit's Rust
        # FFI; the override liblogosdelivery may reference newer zerokit symbols
        # (e.g. _ffi_bytes_le_to_cfr) not present in the .lgx-shipped librln.
        # Co-install the matching librln from the same source dir if we can find
        # one there, else honor DELIVERY_LIBRLN_OVERRIDE.
        _sib_rln=$(dirname "$DELIVERY_DYLIB_OVERRIDE")/librln.dylib
        if [ -n "${DELIVERY_LIBRLN_OVERRIDE:-}" ] && [ -f "$DELIVERY_LIBRLN_OVERRIDE" ]; then
            cp "$DELIVERY_LIBRLN_OVERRIDE" "$MDIR/delivery_module/librln.dylib"
            codesign --force --sign - "$MDIR/delivery_module/librln.dylib" 2>/dev/null || true
        elif [ -f "$_sib_rln" ]; then
            cp "$_sib_rln" "$MDIR/delivery_module/librln.dylib"
            codesign --force --sign - "$MDIR/delivery_module/librln.dylib" 2>/dev/null || true
        fi
    fi
    # Post-#32 chat plugin override — Rust-based, self-contained. Prefer the
    # locally-built dylib since the pinned CHAT_LGX predates the Rust migration.
    if [ -n "${CHAT_PLUGIN_OVERRIDE:-}" ] && [ -f "$CHAT_PLUGIN_OVERRIDE" ]; then
        cp "$CHAT_PLUGIN_OVERRIDE" "$MDIR/chat_module/chat_module_plugin.dylib"
        codesign --force --sign - "$MDIR/chat_module/chat_module_plugin.dylib" 2>/dev/null || true
    fi
}

# Delivery-shaped JSON for a chat instance (sender/receiver). Mirrors the mix-
# node NODE_CONFIG template but with sender/receiver-specific keys. Called
# after the mix nodes are up so BOOTSTRAP_PEER and MIXNODE_LIST are populated.
write_chat_delivery_config() {
    local OUT="$1" IDX="$2" TCP_PORT="$3" AUTH_KEY="$4"
    local KADBS="[\"$BOOTSTRAP_PEER\"]"
    local PEER_LIST=""
    for j in $(seq 0 $((NUM_NODES - 1))); do
        [ -n "$PEER_LIST" ] && PEER_LIST="$PEER_LIST,"
        PEER_LIST="$PEER_LIST\"/ip4/127.0.0.1/tcp/$((BASE_TCP_PORT + j))/p2p/${PEER_IDS[$j]}\""
    done
    local DISC_PORT=$((BASE_DISC_PORT + IDX))
    cat > "$OUT" <<CFG
{
  "mode": "Core",
  "kernelOverrides": {
    "clusterId": $CLUSTER_ID,
    "numShardsInNetwork": $NUM_SHARDS,
    "listenAddress": "127.0.0.1",
    "tcpPort": $TCP_PORT,
    "discv5UdpPort": $DISC_PORT,
    "discv5Discovery": false,
    "nat": "extip:127.0.0.1",
    "extMultiAddrs": ["/ip4/127.0.0.1/tcp/$TCP_PORT"],
    "extMultiAddrsOnly": true,
    "nodekey": "${NODEKEYS[$IDX]}",
    "staticnodes": [$PEER_LIST],
    "relay": true,
    "lightpush": true,
    "filter": true,
    "mix": true,
    "mixkey": "${MIXKEYS[$IDX]}",
    "mixnodes": [$MIXNODE_LIST],
    "mixOnchainLEZ": true,
    "mixGifterNode": "$BOOTSTRAP_PEER",
    "mixGifterWalletAccount": "$GIFTER_ACCOUNT",
    "mixGifterAuthKey": "$AUTH_KEY",
    "enableKadDiscovery": true,
    "kadBootstrapNodes": $KADBS,
    "peerExchange": false,
    "rendezvous": false,
    "colocationLimit": 0,
    "logLevel": "$LOG_LEVEL"
  }
}
CFG
}

CHAT_LOAD_ORDER="logos_execution_zone,liblogos_rln_module,delivery_module,chat_module"

# --- Receiver ---
RECV_MDIR=$(mktemp -d); MODULES_DIRS+=("$RECV_MDIR")
stage_chat_module "$RECV_MDIR"

RECV_CONFIG="$STATE_DIR/chat_receiver_delivery.json"
write_chat_delivery_config "$RECV_CONFIG" 4 "$CHAT_RECV_PORT" "$KEY_RECEIVER"

RECV_INSTANCE_DIR="$STATE_DIR/chat_receiver_instance"
mkdir -p "$RECV_INSTANCE_DIR"

log "  Starting receiver..."
# Post-#32: delivery bring-up explicit, then chat init_after_delivery
# (escape-hatch skipping chat's built-in preset-based delivery bootstrap).
# RLN leaf layout: 0-3 mix nodes, 4 gifter-reserved, 5 receiver, 6 sender.
DYLD_PRELOAD_LIBS="$CHAT_EXTRA_LIB" \
start_logoscore_instance "$RECEIVER_LOG" "$RECV_MDIR" "$CHAT_LOAD_ORDER" \
    "$WALLET_CALL" \
    "delivery_module.createNode(@$RECV_CONFIG)" \
    "delivery_module.setRlnConfig($CONFIG_ACCOUNT,5)" \
    "delivery_module.start()" || true
RECEIVER_PID="$LAST_DAEMON_PID"
RECEIVER_CFG_DIR="$LAST_DAEMON_CFG"
log "  Receiver PID: $RECEIVER_PID"
wait_start_completed "$RECEIVER_LOG" || log "  WARNING: receiver start-completed marker not seen"
sleep 2
issue_call_now "$RECEIVER_CFG_DIR" "$RECEIVER_LOG" delivery_module subscribe "$CONTENT_TOPIC"
sleep 2
issue_call_now "$RECEIVER_CFG_DIR" "$RECEIVER_LOG" chat_module init_after_delivery "$RECV_INSTANCE_DIR"
sleep 2
issue_call_now "$RECEIVER_CFG_DIR" "$RECEIVER_LOG" chat_module get_address

RECV_EXPECTED=7
wait_method_calls "$RECEIVER_LOG" "$RECV_EXPECTED" 180 2 || true
log "  Receiver method calls: $N/$RECV_EXPECTED"

# Extract DirectV1 account address emitted by chat_module.get_address().
# logoscore-cli --json call prints the return under "result" as a JSON string.
PEER_ADDRESS=""
for t in $(seq 1 30); do
    PEER_ADDRESS=$(sed 's/\x1b\[[0-9;]*m//g' "$RECEIVER_LOG" 2>/dev/null \
        | grep -oE '"method":"get_address"[^}]*"result":"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"result":"([^"]+)".*/\1/')
    [ -n "$PEER_ADDRESS" ] && break; sleep 2
done
if [ -n "$PEER_ADDRESS" ]; then
    log "  Receiver DirectV1 address: ${PEER_ADDRESS:0:40}..."
else
    log "  WARNING: Could not extract receiver address from log"
fi

# Wait for delivery_module.start to complete ("Node started successfully") +
# a floor for the filter subscription to propagate through the relay mesh.
echo "  Waiting for receiver to join mix network..."
JOIN_T0=$SECONDS
while true; do
    ELAPSED=$((SECONDS - JOIN_T0))
    RS=$(grep -c "Node started successfully\|Waku client started" "$RECEIVER_LOG" 2>/dev/null || true); RS=${RS:-0}
    [ "$ELAPSED" -ge "$RECEIVER_MIN_WAIT" ] && [ "$RS" -ge 1 ] && break
    [ "$ELAPSED" -ge 60 ] && break
    sleep 1
done
log "  Receiver joined after $((SECONDS - JOIN_T0))s"

# --- Receiver 2 (optional, demonstrates sender reusing membership for multiple convos) ---
RECEIVER2_LOG="$STATE_DIR/chat_receiver2.log"
RECEIVER2_PID=""
RECEIVER2_CFG_DIR=""
INTRO_BUNDLE2=""
if [ "${SIM_RECEIVER2:-0}" = "1" ]; then
    RECV2_MDIR=$(mktemp -d); MODULES_DIRS+=("$RECV2_MDIR")
    stage_chat_module "$RECV2_MDIR"

    RECV2_CONFIG="$STATE_DIR/chat_receiver2_config.json"
    cat > "$RECV2_CONFIG" <<EOF
{
  "name": "receiver2",
  "clusterId": $CLUSTER_ID,
  "shardId": 0,
  "port": $CHAT_RECV2_PORT,
  "mixEnabled": true,
  "mixNodes": [$MIXNODE_LIST],
  "destPeerAddr": "$BOOTSTRAP_PEER",
  "minMixPoolSize": 4,
  "gifterNodeAddr": "$BOOTSTRAP_PEER",
  "gifterAuthKey": "$KEY_RECEIVER2",
  "staticPeers": [$CHAT_STATIC_PEERS]
}
EOF

    log "  Starting receiver2..."
    DYLD_PRELOAD_LIBS="$CHAT_EXTRA_LIB" \
    start_logoscore_instance "$RECEIVER2_LOG" "$RECV2_MDIR" "$CHAT_LOAD_ORDER" \
        "$WALLET_CALL" \
        "chat_module.initChat(@$RECV2_CONFIG)" \
        "chat_module.setEventCallback()" \
        "chat_module.startChat()" \
        "chat_module.createIntroBundle()" || true
    RECEIVER2_PID="$LAST_DAEMON_PID"
    RECEIVER2_CFG_DIR="$LAST_DAEMON_CFG"
    log "  Receiver2 PID: $RECEIVER2_PID"

    wait_method_calls "$RECEIVER2_LOG" 5 180 2 || true
    log "  Receiver2 method calls: $N/5"

    # Extract receiver2's intro bundle
    for t in $(seq 1 30); do
        INTRO_BUNDLE2=$(sed 's/\x1b\[[0-9;]*m//g' "$RECEIVER2_LOG" 2>/dev/null \
            | grep -oE 'bundle="\[[0-9, ]+\]"' \
            | head -1 \
            | sed -E 's/bundle="\[//;s/\]"$//' \
            | awk -F', *' '{for(i=1;i<=NF;i++) printf "%c",$i}')
        [ -n "$INTRO_BUNDLE2" ] && break; sleep 2
    done
    [ -n "$INTRO_BUNDLE2" ] && log "  Receiver2 intro bundle: ${INTRO_BUNDLE2:0:40}..." \
        || log "  WARNING: Could not extract receiver2 intro bundle"

    # Wait for receiver2 to join
    echo "  Waiting for receiver2 to join mix network..."
    R2_JOIN_T0=$SECONDS
    while true; do
        R2S=$(grep -c "Waku client started" "$RECEIVER2_LOG" 2>/dev/null || true)
        [ "$((SECONDS - R2_JOIN_T0))" -ge "$RECEIVER_MIN_WAIT" ] && [ "${R2S:-0}" -ge 1 ] && break
        [ "$((SECONDS - R2_JOIN_T0))" -ge 60 ] && break
        sleep 1
    done
    log "  Receiver2 joined after $((SECONDS - R2_JOIN_T0))s"
fi

# --- Sender ---
SEND_MDIR=$(mktemp -d); MODULES_DIRS+=("$SEND_MDIR")
stage_chat_module "$SEND_MDIR"

SEND_CONFIG="$STATE_DIR/chat_sender_delivery.json"
write_chat_delivery_config "$SEND_CONFIG" 5 "$CHAT_SEND_PORT" "$KEY_SENDER"

SEND_INSTANCE_DIR="$STATE_DIR/chat_sender_instance"
mkdir -p "$SEND_INSTANCE_DIR"

# Post-#32 sender bootstrap: delivery_module explicit bring-up, then chat
# init_after_delivery. Deferring create_conversation/send_message until after
# on-chain gifter membership + a mix-pool cushion, same reasoning as before —
# the chat client only publishes reliably once the spam-protection plugin is
# isReady() AND all mix nodes' valid_roots windows have converged.
SENDER_CALLS=(
    "$WALLET_CALL"
    "delivery_module.createNode(@$SEND_CONFIG)"
    "delivery_module.start()"
)

log "  Starting sender..."
DYLD_PRELOAD_LIBS="$CHAT_EXTRA_LIB" \
start_logoscore_instance "$SENDER_LOG" "$SEND_MDIR" "$CHAT_LOAD_ORDER" "${SENDER_CALLS[@]}" || true
SENDER_PID="$LAST_DAEMON_PID"
SENDER_CFG_DIR="$LAST_DAEMON_CFG"
log "  Sender PID: $SENDER_PID"
wait_start_completed "$SENDER_LOG" || log "  WARNING: sender start-completed marker not seen"
sleep 2
issue_call_now "$SENDER_CFG_DIR" "$SENDER_LOG" delivery_module subscribe "$CONTENT_TOPIC"
sleep 2
issue_call_now "$SENDER_CFG_DIR" "$SENDER_LOG" chat_module init_after_delivery "$SEND_INSTANCE_DIR"

SEND_EXPECTED=5
wait_method_calls "$SENDER_LOG" "$SEND_EXPECTED" 180 2 || true

# On slower systems the sender's async gifter registration may trail
# create_conversation. Wait for RLN readiness; delivery-side Nim async code
# retries the publish once credentials land.
echo "  Waiting for sender RLN readiness..."
SENDER_RLN_T0=$SECONDS
for t in $(seq 1 60); do
    SG=$(sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null | grep -c "Registered via RLN gifter\|Node started successfully" || true)
    [ "${SG:-0}" -ge 2 ] && break
    sleep 1
done
log "  Sender RLN ready after $((SECONDS - SENDER_RLN_T0))s"
N=$(grep -c '^Method call successful' "$SENDER_LOG" 2>/dev/null || true); N=${N:-0}
log "  Sender method calls: $N/$SEND_EXPECTED"

# Wait for the sender's gifter-granted RLN membership to be confirmed on chain
# before dispatching newPrivateConversation. The chat client's mix-side spam-
# protection plugin only becomes isReady() after this confirmation lands AND
# the next 10s poll cycle fetches our merkle proof from LEZ. Local sequencer
# typically confirms in ~3 min; testnet up to 5-30 min.
if [ -n "$PEER_ADDRESS" ]; then
    echo "  Waiting for sender on-chain membership confirmation..."
    CONFIRM_T0=$SECONDS
    # Local: ~3min typical. Testnet: chat-client senders never emit
    # "membership confirmed on-chain" — watchMembershipConfirmation is
    # only wired on the mix-node registration path (logos-delivery
    # node_factory.nim:840). The wait is a nudge, not a gate; the loop
    # falls through on timeout and setRlnConfig fires anyway. Keep it
    # short so the sim doesn't waste an hour waiting for a log line
    # that won't come. Override with SIM_SENDER_CONFIRM_TIMEOUT if a
    # future chat-module change adds a confirmation-log path.
    if [ "$SIM_NETWORK" = testnet ]; then
        CONFIRM_TIMEOUT=${SIM_SENDER_CONFIRM_TIMEOUT:-120}
    else
        CONFIRM_TIMEOUT=${SIM_SENDER_CONFIRM_TIMEOUT:-60}
    fi
    for t in $(seq 1 $CONFIRM_TIMEOUT); do
        if sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null | grep -q "membership confirmed on-chain"; then
            log "  Sender membership confirmed after $((SECONDS - CONFIRM_T0))s"
            break
        fi
        sleep 1
    done
    # Cushion: give the next poll tick (~10s) time to fetch the proof so
    # isReady() flips true before we issue the publish. Longer cushion (60s)
    # also gives all mix nodes' poll loops time to converge their valid_roots
    # window on the latest tree state — without this, mix entry node 0's
    # self-verify of generated proof fails with "Expected one of the provided
    # roots" because its valid_roots window doesn't yet contain the root its
    # generated proof references (race between fetchProof + tree changes from
    # late client registrations).
    sleep 60

    SENDER_CFG_DIR="$LAST_DAEMON_CFG"

    # Wire the delivery module's RLN with the gifter-assigned leaf. In the
    # post-#32 Rust world chat.set_rln_config is a passthrough to
    # delivery_module.setRlnConfig (see rust-lib/src/actions.rs) — either
    # works. Extract config account + leaf from the gifter-success log line.
    # `|| true` guards set -euo pipefail: when the gifter-log line hasn't
    # (yet) appeared, grep returns 1 → assignment exits nonzero → whole sim
    # aborts silently. Landing empty here is the intended path — the WARN
    # branch below reports it.
    GIFTER_INFO=$(sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null \
        | grep "Registered via RLN gifter" | tail -1 || true)
    SENDER_CONFIG_ACCT=$(printf '%s' "$GIFTER_INFO" | sed -nE 's/.*configAccount=([A-Za-z0-9]+).*/\1/p')
    SENDER_LEAF=$(printf '%s' "$GIFTER_INFO" | sed -nE 's/.*leafIndex=([0-9]+).*/\1/p')
    if [ -n "$SENDER_CONFIG_ACCT" ] && [ -n "$SENDER_LEAF" ]; then
        log "  Wiring sender RLN: account=$SENDER_CONFIG_ACCT leaf=$SENDER_LEAF"
        SETCFG_ACCT_ARG="$STATE_DIR/sender_setcfg_acct.arg"
        printf '%s' "$SENDER_CONFIG_ACCT" > "$SETCFG_ACCT_ARG"
        timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$SENDER_CFG_DIR" "$LOGOSCORE" --json call delivery_module setRlnConfig "@$SETCFG_ACCT_ARG" "$SENDER_LEAF" \
            >>"$SENDER_LOG" 2>&1 \
            || log "  setRlnConfig call failed"
        # setRlnConfig schedules the valid_roots subscription 15s later; wait
        # for that to subscribe + one poll cycle so roots+proof are cached.
        sleep 25
    else
        log "  WARN: couldn't extract sender gifter configAccount/leafIndex"
    fi

    log "  Sending create_conversation + send_message..."
    # Post-#32: DirectV1 replaces intro-bundle + newPrivateConversation with
    # a plain-string peer address + separate create_conversation/send_message.
    # PEER_ADDRESS was extracted from the receiver's chat_module.get_address()
    # return value earlier. Content passes as plain UTF-8 (LIDL tstr), not hex.
    ADDR_ARG="$STATE_DIR/sender_convo_peer.arg"
    MSG_ARG="$STATE_DIR/sender_msg_content.arg"
    printf '%s' "$PEER_ADDRESS" > "$ADDR_ARG"
    printf '%s' "$TEST_MESSAGE_PREFIX" > "$MSG_ARG"

    # Retry the NPC on mix-lightpush timeout. Each NPC creates a fresh
    # convoId on success; if the first attempt's sphinx packet doesn't
    # generate a SURB reply within 15s, the chat client logs
    # "Mix lightpush timed out" and abandons the send. Without a retry,
    # the receiver never gets the conversation handshake and any
    # subsequent sendMessage extras arrive as orphans (unknown convoId →
    # silently dropped). Re-dispatching newPrivateConversation creates a
    # new conversation; the receiver accepts whichever arrives.
    NPC_MAX_RETRIES=${SIM_NPC_RETRIES:-2}
    for attempt in $(seq 0 "$NPC_MAX_RETRIES"); do
        # Snapshot sender log line count so we only inspect entries
        # produced by THIS attempt's mix send.
        LOG_BEFORE=$(wc -l < "$SENDER_LOG" 2>/dev/null || echo 0)
        # create_conversation returns Result<Value::String(chat_id), String>;
        # send_message needs that chat_id. First-cut approach: capture the
        # returned convo_id from the create_conversation JSON output, then
        # feed it into send_message. If unavailable, fall back to peer addr
        # (libchat's DirectV1 chat_id derives deterministically from it).
        CC_OUT=$(timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$SENDER_CFG_DIR" "$LOGOSCORE" --json call chat_module create_conversation "@$ADDR_ARG" 2>&1) \
            || log "  create_conversation call failed (attempt $((attempt+1)))"
        printf '%s\n' "$CC_OUT" >>"$SENDER_LOG"
        # `|| true` guards set -euo pipefail: when the RPC output doesn't have
        # a value line (e.g. the call failed), the grep pipeline returns 1 →
        # assignment aborts the script. Empty CONVO_ID is the intended
        # fallback path (line below sets it to PEER_ADDRESS).
        #
        # The Rust chat_module's create_conversation returns
        # `{"method":"create_conversation","module":"chat_module",
        #   "result":{"error":null,"success":true,"value":"<convo_id>"},...}`
        # so we extract from the nested `"value":"..."` inside `result`.
        CONVO_ID=$(printf '%s' "$CC_OUT" | grep -oE '"value":"[a-f0-9]+"' | head -1 | sed -E 's/.*"value":"([^"]+)".*/\1/' || true)
        [ -z "$CONVO_ID" ] && CONVO_ID="$PEER_ADDRESS"
        printf '%s' "$CONVO_ID" > "$STATE_DIR/sender_convo_id.arg"
        timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$SENDER_CFG_DIR" "$LOGOSCORE" --json call chat_module send_message "@$STATE_DIR/sender_convo_id.arg" "@$MSG_ARG" \
            >>"$SENDER_LOG" 2>&1 \
            || log "  send_message call failed (attempt $((attempt+1)))"

        # Wait for either success or timeout marker in the newly-emitted
        # log range. The chat client doesn't start "Sending via mix"
        # until ~20s after the NPC call (after intro-bundle parsing +
        # mix-pool readiness gate), and the SURB deadline is now 60s
        # (widened from 15s per Phase-B+C mitigation in waku_client.nim).
        # Outcome determined within ~85s of dispatch. 100s window adds
        # slack for log flush + slow daemons.
        NPC_OUTCOME=""
        for w in $(seq 1 100); do
            LINE_RANGE=$(tail -n +"$((LOG_BEFORE + 1))" "$SENDER_LOG" 2>/dev/null \
                | sed -E 's/\x1b\[[0-9;]*m//g')
            if grep -q "Message sent via mix successfully" <<<"$LINE_RANGE"; then
                NPC_OUTCOME=ok
                break
            elif grep -qE "Mix lightpush timed out|Mix lightpush: no SURB reply" <<<"$LINE_RANGE"; then
                # SURB reply not received within deadline. Even though
                # forward delivery is independent of SURB, the receiver-
                # side conversation handshake may not have fully landed
                # (the chat module relies on the round-trip to confirm
                # delivery and update conversation state). Retry to give
                # the receiver another shot at the handshake.
                NPC_OUTCOME=timeout
                break
            fi
            sleep 1
        done

        if [ "$NPC_OUTCOME" = ok ]; then
            log "  NPC attempt $((attempt+1)) succeeded via mix"
            break
        elif [ "$NPC_OUTCOME" = timeout ]; then
            if [ "$attempt" -lt "$NPC_MAX_RETRIES" ]; then
                log "  NPC attempt $((attempt+1)) mix-lightpush timed out — retrying"
                sleep 5
            else
                log "  NPC exhausted $((NPC_MAX_RETRIES+1)) attempts; continuing"
            fi
        else
            # No clear marker yet — likely succeeded but flush lag, OR
            # the chat client is still working on something else. Don't
            # retry; downstream delivery check will catch true failure.
            log "  NPC attempt $((attempt+1)) outcome unclear after 25s; continuing"
            break
        fi
    done

    # Optional: send N additional messages after newPrivateConversation.
    # Controlled via SIM_EXTRA_MESSAGES (default 0). The convId is extracted
    # from the sender's "CREATED ... convoId=..." log line emitted by
    # newPrivateConversation. Each extra send is dispatched via the same
    # `chat_module.sendMessage(convoId, hex)` Q_INVOKABLE the chat-ui would
    # call, separated by SIM_EXTRA_MESSAGE_GAP seconds (default 5) so RLN
    # rate-limit windows don't reject closely-spaced sends.
    EXTRA_N=${SIM_EXTRA_MESSAGES:-0}
    EXTRA_GAP=${SIM_EXTRA_MESSAGE_GAP:-5}
    if [ "$EXTRA_N" -gt 0 ]; then
        # Wait briefly for the CREATED log line — the convo emit fires from
        # the chat client's async newPrivateConversation callback.
        CONVO_ID=""
        for t in $(seq 1 30); do
            CONVO_ID=$(sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null \
                | grep -oE "convoId=[0-9a-f]+" | head -1 | cut -d= -f2)
            [ -n "$CONVO_ID" ] && break
            sleep 1
        done
        if [ -z "$CONVO_ID" ]; then
            log "  WARN: couldn't extract convoId for extra messages; skipping"
        else
            log "  Sending $EXTRA_N extra messages (convoId=${CONVO_ID:0:12}…, gap=${EXTRA_GAP}s)"
            for i in $(seq 1 "$EXTRA_N"); do
                sleep "$EXTRA_GAP"
                BODY="mixmsg #$i $(date -u +%H:%M:%S)"
                BODY_HEX=$(printf '\xff%s' "$BODY" | xxd -p | tr -d '\n')
                SM_JSON_ARG="$STATE_DIR/sender_sm_json_$i.arg"
                # logoscore-cli's `call` subcommand coerces digit-leading
                # positional args (and @file content) to qulonglong even with
                # @-prefix. Wrap the args in a JSON object and dispatch via
                # the Json variant — same pattern as selfRegisterRlnJson.
                printf '{"convoId":"%s","contentHex":"%s"}' "$CONVO_ID" "$BODY_HEX" > "$SM_JSON_ARG"
                timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$SENDER_CFG_DIR" "$LOGOSCORE" --json call chat_module sendMessageJson "@$SM_JSON_ARG" \
                    >>"$SENDER_LOG" 2>&1 \
                    || log "    extra send #$i call failed"
            done
            log "  Extra messages dispatched"
        fi
    fi
fi

# Poll receiver log for delivery. Initial NPC handshake emits a few events
# (chatNewConversation + chatNewMessage); each extra sendMessage adds at
# least one more chatNewMessage. We want to see ≥ (1 + EXTRA_N) inbound
# chat events before declaring delivery successful.
echo "  Waiting for message delivery via mix..."
DELIVERY_EXPECTED=$(( 1 + ${SIM_EXTRA_MESSAGES:-0} ))
DELIVERY_T0=$SECONDS
for t in $(seq 1 $DELIVERY_TIMEOUT); do
    RM=$(grep -c "message_received" "$RECEIVER_LOG" 2>/dev/null || true); RM=${RM:-0}
    [ "$RM" -ge "$DELIVERY_EXPECTED" ] && break
    sleep 1
done
log "  Delivery check after $((SECONDS - DELIVERY_T0))s (messages: $RM/expected ≥$DELIVERY_EXPECTED)"

# ─── Receiver replies back to sender ───
# Once the receiver has received messages, have it send replies back through
# the mix network. Uses the same convoId (extracted from sender's CREATED log).
REPLY_N=${SIM_REPLY_MESSAGES:-0}
REPLY_GAP=${SIM_REPLY_MESSAGE_GAP:-5}
if [ "$REPLY_N" -gt 0 ] && [ "${RM:-0}" -ge 1 ] && [ -n "${CONVO_ID:-}" ] && [ -n "${RECEIVER_CFG_DIR:-}" ]; then
    log "  Receiver sending $REPLY_N replies (convoId=${CONVO_ID:0:12}…, gap=${REPLY_GAP}s)"
    for i in $(seq 1 "$REPLY_N"); do
        sleep "$REPLY_GAP"
        BODY="reply #$i $(date -u +%H:%M:%S)"
        BODY_HEX=$(printf '\xff%s' "$BODY" | xxd -p | tr -d '\n')
        RM_JSON_ARG="$STATE_DIR/receiver_sm_json_$i.arg"
        printf '{"convoId":"%s","contentHex":"%s"}' "$CONVO_ID" "$BODY_HEX" > "$RM_JSON_ARG"
        timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$RECEIVER_CFG_DIR" "$LOGOSCORE" --json call chat_module sendMessageJson "@$RM_JSON_ARG" \
            >>"$RECEIVER_LOG" 2>&1 \
            || log "    receiver reply #$i call failed"
    done
    log "  Receiver replies dispatched"

    # Wait for sender to receive the replies
    SENDER_REPLY_EXPECTED=$REPLY_N
    echo "  Waiting for sender to receive replies..."
    for t in $(seq 1 $DELIVERY_TIMEOUT); do
        SM=$(grep -c "message_received" "$SENDER_LOG" 2>/dev/null || true); SM=${SM:-0}
        [ "$SM" -ge "$SENDER_REPLY_EXPECTED" ] && break
        sleep 1
    done
    log "  Sender received $SM reply events (expected ≥$SENDER_REPLY_EXPECTED)"
fi

# ─── Sender → Receiver2 conversation (reuses sender's existing RLN membership) ───
if [ "${SIM_RECEIVER2:-0}" = "1" ] && [ -n "$INTRO_BUNDLE2" ] && [ -n "$SENDER_CFG_DIR" ]; then
    echo ""
    echo "  --- Sender → Receiver2 (reusing existing membership) ---"

    NPC2_BUNDLE_ARG="$STATE_DIR/npc2_bundle.arg"
    NPC2_HEX_ARG="$STATE_DIR/npc2_hex.arg"
    NPC2_MSG="hello receiver2 $(date -u +%H:%M:%S)"
    NPC2_MSG_HEX=$(printf '\xff%s' "$NPC2_MSG" | xxd -p | tr -d '\n')
    printf '%s' "$INTRO_BUNDLE2" > "$NPC2_BUNDLE_ARG"
    printf '%s' "$NPC2_MSG_HEX" > "$NPC2_HEX_ARG"

    log "  Sending newPrivateConversation to receiver2..."
    timeout "${CALL_TIMEOUT:-180}" env -u TMPDIR LOGOSCORE_CONFIG_DIR="$SENDER_CFG_DIR" \
        "$LOGOSCORE" --json call chat_module newPrivateConversation "@$NPC2_BUNDLE_ARG" "@$NPC2_HEX_ARG" \
        >>"$SENDER_LOG" 2>&1 || true

    # Wait for receiver2 to get the message
    echo "  Waiting for receiver2 delivery..."
    R2_DELIVERY_T0=$SECONDS
    for t in $(seq 1 $DELIVERY_TIMEOUT); do
        R2M=$(grep -c "message_received" "$RECEIVER2_LOG" 2>/dev/null || true); R2M=${R2M:-0}
        [ "$R2M" -ge 1 ] && break
        sleep 1
    done
    log "  Receiver2 delivery check after $((SECONDS - R2_DELIVERY_T0))s (messages: $R2M)"
fi

echo ""

# ---------- Phase 6: Verify ----------
echo "[6/6] Verification"; echo ""
PASS=0; FAIL=0
check() { local c=$1 d=$2; if eval "$c"; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d"; FAIL=$((FAIL+1)); fi; }

# Demo mode: replace the full 6/6 check with the three RLN-gifter-protocol
# markers the demo cares about (gifter request received, membership granted,
# proof verified by a mix node). Skips the receive-side delivery checks that
# depend on end-to-end mix forward delivery (orthogonal to the gifter
# protocol itself working).
if [ "${SIM_DEMO_MODE:-0}" = "1" ]; then
    echo "  --- RLN gifter protocol demo ---"
    GIFTER_REQ=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node0.log" 2>/dev/null \
        | grep -c "handling RLN gifter request" || true)
    check "[ ${GIFTER_REQ:-0} -ge 1 ]" "(1) Gifter service received request ($GIFTER_REQ)"

    SEND_MEMB=$(sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null \
        | grep -c "RLN membership granted\|Registered via RLN gifter" || true)
    check "[ ${SEND_MEMB:-0} -ge 1 ]" "(2) Sender received valid RLN membership ($SEND_MEMB)"

    # RLN proofs are generated by each mix node as it wraps/forwards the
    # sphinx packet (NOT by the chat sender). Count generations across all
    # mix nodes — each downstream verification implies a prior generation.
    count_across_nodes() {
        local pattern="$1" total=0 i n
        for i in $(seq 0 $((NUM_NODES - 1))); do
            n=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node${i}.log" 2>/dev/null \
                | grep -c "$pattern" || true)
            total=$((total + ${n:-0}))
        done
        printf '%d' "$total"
    }
    PROOF_GEN=$(count_across_nodes "Generated RLN proof successfully")
    check "[ $PROOF_GEN -ge 1 ]" "(3a) Mix nodes generated RLN proofs ($PROOF_GEN total)"

    # PR #9 (mix-rln plugin stateless) renamed the verification log line. Match
    # either the legacy "Spam protection proof verified successfully" or the new
    # "Proof verified successfully" emitted at INFO from the plugin.
    PROOF_VERIFIED=$(count_across_nodes "Proof verified successfully")
    check "[ $PROOF_VERIFIED -ge 1 ]" "(3b) Proof verified by another mix node ($PROOF_VERIFIED total)"

    echo ""; echo "  =========================================="
    if [ "$FAIL" -eq 0 ]; then echo "  DEMO PASS: all $PASS markers fired"; EXIT_CODE=0
    else echo "  DEMO FAIL: $FAIL/$((PASS+FAIL)) markers missing"; EXIT_CODE=1; fi
    echo "  =========================================="
    exit $EXIT_CODE
fi

echo "  --- logos-core mix nodes ---"
for i in $(seq 0 $((NUM_NODES - 1))); do
    M=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node${i}.log" 2>/dev/null | grep -c "mounting mix protocol" || true)
    check "[ ${M:-0} -ge 1 ]" "Node $i mounted mix ($M)"
done
echo ""

echo "  --- RLN gifter ---"
GIFTER_MOUNTED=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node0.log" 2>/dev/null | grep -c "RLN gifter service mounted" || true)
check "[ ${GIFTER_MOUNTED:-0} -ge 1 ]" "Node 0 gifter service mounted ($GIFTER_MOUNTED)"
echo ""

echo "  --- LEZ RLN ---"
LEZ_ROOTS=0
for i in $(seq 0 $((NUM_NODES - 1))); do
    R=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node${i}.log" 2>/dev/null | grep -c "Polled valid roots\|Fetched roots from\|valid_roots\|OnchainLEZGroupManager initialized\|Wired LEZ callbacks" || true)
    LEZ_ROOTS=$((LEZ_ROOTS + R))
done
check "[ $LEZ_ROOTS -ge 1 ]" "LEZ RLN active ($LEZ_ROOTS events across nodes)"
echo ""

echo "  --- chat module ---"
# Post-#32 Rust chat_module log format: init returns via the RPC status line
# `{"method":"init_after_delivery","module":"chat_module","result":{"error":null,"success":true,...},"status":"ok"}`.
# Old Nim-side chatInitResult / "Chat context created" strings no longer emit.
# The RPC line reliably appears exactly once per successful init call.
RECV_INIT=$(grep -c '"method":"init_after_delivery","module":"chat_module"' "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_INIT:-0} -ge 1 ]" "Receiver initialized ($RECV_INIT)"
RECV_START=$(grep -c "Node started successfully\|delivery_state_changed" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_START:-0} -ge 1 ]" "Receiver started ($RECV_START)"
SEND_INIT=$(grep -c '"method":"init_after_delivery","module":"chat_module"' "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_INIT:-0} -ge 1 ]" "Sender initialized ($SEND_INIT)"
SEND_START=$(grep -c "Node started successfully\|delivery_state_changed" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_START:-0} -ge 1 ]" "Sender started ($SEND_START)"

RECV_MIX=$(grep -c "mounting mix protocol\|Wired LEZ callbacks" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_MIX:-0} -ge 1 ]" "Receiver mounted mix+LEZ ($RECV_MIX)"
SEND_MIX=$(grep -c "mounting mix protocol\|Wired LEZ callbacks" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_MIX:-0} -ge 1 ]" "Sender mounted mix+LEZ ($SEND_MIX)"

# DirectV1 replaces intro-bundle publication with `chat_module.get_address()` —
# the receiver's own account address IS the "invitation payload". The chat
# plugin logs its messageReceived subscription right after get_address returns
# non-empty; that's the receive-side readiness signal.
RECV_READY=$(grep -c 'LogosAPIConsumer: event callback registered for: "messageReceived"' "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_READY:-0} -ge 1 ]" "Receiver ready for messages ($RECV_READY)"
echo ""

echo "  --- message exchange ---"
# Post-#32 send flow: `chat_module.send_message(convo_id, content)` returns via
# status line. `success:true` indicates the send was accepted by libchat (it
# then packages and dispatches via delivery_module.send).
SEND_MSG=$(grep -c '"method":"send_message","module":"chat_module","result":{"error":null,"success":true' "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_MSG:-0} -ge 1 ]" "Sender sent message ($SEND_MSG)"
# Post-#32 receive: chat_module's Rust `inbound::bridge_loop` decodes DirectV1
# frames and emits a `messageReceived` Qt event via the LogosProviderBase glue.
# The Qt IPC layer dispatches to the consumer; we count dispatched deliveries.
RECV_MSG=$(grep -c 'dispatching event "messageReceived"' "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_MSG:-0} -ge ${DELIVERY_EXPECTED:-1} ]" "Receiver received message ($RECV_MSG / ≥${DELIVERY_EXPECTED:-1})"

if [ "${SIM_RECEIVER2:-0}" = "1" ]; then
    echo ""
    echo "  --- receiver2 (membership reuse) ---"
    R2_INIT=$(grep -c "chatInitResult\|Chat context created" "$RECEIVER2_LOG" 2>/dev/null || true)
    check "[ ${R2_INIT:-0} -ge 1 ]" "Receiver2 initialized ($R2_INIT)"
    R2_START=$(grep -c "Node started successfully\|delivery_state_changed" "$RECEIVER2_LOG" 2>/dev/null || true)
    check "[ ${R2_START:-0} -ge 1 ]" "Receiver2 started ($R2_START)"
    R2_MSG=$(grep -c "message_received" "$RECEIVER2_LOG" 2>/dev/null || true)
    check "[ ${R2_MSG:-0} -ge 1 ]" "Receiver2 received message ($R2_MSG)"
fi

echo ""; echo "  =========================================="
if [ "$FAIL" -eq 0 ]; then echo "  ALL $PASS CHECKS PASSED"; EXIT_CODE=0
else echo "  $FAIL FAILED, $PASS passed"; EXIT_CODE=1; fi
echo "  =========================================="

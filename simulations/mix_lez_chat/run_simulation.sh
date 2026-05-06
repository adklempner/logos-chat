#!/usr/bin/env bash
# Mix + LEZ RLN simulation using logos-chat-module as sender/receiver.
# Reuses the logoscore mix node infrastructure from logos-lez-rln and replaces
# chat2mix with logoscore instances running the chat_module plugin.
#
# Prerequisites:
#   - logos-lez-rln repo as sibling or set LEZ_RLN_DIR
#   - logos-chat-module built (nix build in ../logos-chat-module)
#   - logos-chat built (make liblogoschat in this repo)
#
# Usage: ./run_simulation.sh [--fresh]
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
    [ -d "$candidate/lez-rln" ] && [ -d "$candidate/lssa" ] && LEZ_RLN_DIR="$(cd "$candidate" && pwd)" && break
done
[ -z "$LEZ_RLN_DIR" ] && { echo "FATAL: Cannot find logos-lez-rln repo. Set LEZ_RLN_DIR or run: git submodule update --init --recursive"; exit 1; }

DELIVERY_MODULE_DIR="${DELIVERY_MODULE_DIR:-$LEZ_RLN_DIR/logos-delivery-module}"
DELIVERY_DIR="$DELIVERY_MODULE_DIR/vendor/logos-delivery"

export RISC0_DEV_MODE=1
export TMPDIR=/tmp
export LOGOS_EVENT_STDERR=1  # Enable EVENT: stderr output for sim script event observation

die() { echo "  FATAL: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Node identity constants (4 mix nodes) ---
NODEKEYS=(
    "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
    "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
    "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
    "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
)
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"
    "16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f"
)
MIXKEYS=(
    "c86029e02c05a7e25182974b519d0d52fcbafeca6fe191fbb64857fb05be1a53"
    "b858ac16bbb551c4b2973313b1c8c8f7ea469fca03f1608d200bbf58d388ec7f"
    "d8bd379bb394b0f22dd236d63af9f1a9bc45266beffc3fbbe19e8b6575f2535b"
    "780fff09e51e98df574e266bf3266ec6a3a1ddfcf7da826a349a29c137009d49"
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
LOG_LEVEL=${SIM_LOG_LEVEL:-INFO}
CHAT_RECV_PORT=${SIM_CHAT_RECV_PORT:-60010}
CHAT_SEND_PORT=${SIM_CHAT_SEND_PORT:-60011}
KADEMLIA_MIN_WAIT=${SIM_KADEMLIA_MIN_WAIT:-30}
RECEIVER_MIN_WAIT=${SIM_RECEIVER_MIN_WAIT:-15}
DELIVERY_TIMEOUT=${SIM_DELIVERY_TIMEOUT:-120}

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
    echo "  Logs: $STATE_DIR"; echo "Done."; exit "$EXIT_CODE"
}
trap cleanup EXIT

echo "=== Mix + LEZ RLN Chat Simulation ($NUM_NODES nodes) ==="
echo "  LEZ repo:         $LEZ_RLN_DIR"
echo "  Chat module:      $CHAT_MODULE_DIR"
echo "  Logos-chat:        $LOGOS_CHAT_DIR"
echo ""

pkill -f 'logos_host' 2>/dev/null || true; sleep 1
# Clean stale QtRO LocalServer sockets from prior runs (can confuse capability_module lookups)
rm -f /tmp/logos_* 2>/dev/null || true

# ---------- Phase 1: Sequencer ----------
echo "[1/6] Sequencer..."
if nc -z 127.0.0.1 3040 2>/dev/null && [ "$FRESH" -eq 0 ]; then
    SEQUENCER_PID=$(lsof -ti tcp:3040 2>/dev/null || true)
    echo "  Already running (PID $SEQUENCER_PID)"
else
    [ "$(nc -z 127.0.0.1 3040 2>/dev/null; echo $?)" = "0" ] && kill "$(lsof -ti tcp:3040 2>/dev/null)" 2>/dev/null || true; sleep 1
    rm -rf "$LEZ_RLN_DIR/lssa/rocksdb" "$LEZ_RLN_DIR/lssa/sequencer/service/bedrock_signing_key"

    # Skip sequencer build if binary already exists (pre-built in Docker image).
    # Also skip lssa auto-sync (requires full git history, fails on shallow clones).
    if [ -x "$LEZ_RLN_DIR/lssa/target/debug/sequencer_service" ]; then
        log "  Using pre-built sequencer"
        SEQ_BIN="./target/debug/sequencer_service"; SEQ_CFG="sequencer/service/configs/debug/sequencer_config.json"
    else
        # Sequencer guest binaries must match the lssa rev that lez-rln's host-side
        # client pins. Mismatch → DeserializeUnexpectedEnd (wire format divergence).
        LSSA_REV=$(grep -oE 'rev\s*=\s*"[0-9a-f]+"' "$LEZ_RLN_DIR/lez-rln/Cargo.toml" | head -1 | sed 's/.*"\([0-9a-f]*\)"/\1/')
        [ -z "$LSSA_REV" ] && die "Could not extract lssa rev from lez-rln/Cargo.toml"
        if ! git -C "$LEZ_RLN_DIR/lssa" merge-base --is-ancestor "$LSSA_REV" HEAD 2>/dev/null; then
            log "  Pinning lssa to $LSSA_REV..."
            (cd "$LEZ_RLN_DIR/lssa" && git fetch --quiet origin && git checkout --quiet "$LSSA_REV") \
                || die "lssa checkout $LSSA_REV failed"
        fi
        log "  Building sequencer..."
        if (cd "$LEZ_RLN_DIR/lssa" && cargo build --features standalone -p sequencer_service 2>&1 | tail -3); then
            SEQ_BIN="./target/debug/sequencer_service"; SEQ_CFG="sequencer/service/configs/debug/sequencer_config.json"
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
export NSSA_WALLET_HOME_DIR="$LEZ_RLN_DIR/dev"
export WALLET_CONFIG="$NSSA_WALLET_HOME_DIR/wallet_config.json"
export WALLET_STORAGE="$NSSA_WALLET_HOME_DIR/storage.json"
TREE_ID_HEX="000102030405060708090a0b0c0d0e0f1011121314151617"
GIFTER_ACCOUNT_FILE="$HOME/.logos-lez-rln/payment_account_${TREE_ID_HEX}.txt"

rm -f "$WALLET_CONFIG" "$WALLET_STORAGE"
# Use pre-built binary if available, otherwise cargo run
if [ -x "$LEZ_RLN_DIR/lez-rln/target/debug/run_setup" ]; then
    SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR/lez-rln" && ./target/debug/run_setup 2>&1) || die "run_setup failed"
else
    SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR/lez-rln" && cargo run --bin run_setup 2>&1) || die "run_setup failed"
fi
echo "$SETUP_OUTPUT" | tail -4
CONFIG_ACCOUNT=$(echo "$SETUP_OUTPUT" | grep -oE 'Config account:\s+\S+' | awk '{print $NF}' || true)
[ -z "$CONFIG_ACCOUNT" ] && die "Failed to parse config account"
GIFTER_ACCOUNT=$(cat "$GIFTER_ACCOUNT_FILE" 2>/dev/null || true)
[ -z "$GIFTER_ACCOUNT" ] && die "Gifter account not found at $GIFTER_ACCOUNT_FILE"

# ---------- Phase 3: Prerequisites ----------
echo "[3/6] Verifying prerequisites..."
LOGOSCORE="${LOGOSCORE:-$(nix build github:logos-co/logos-liblogos/7df6195 --override-input logos-cpp-sdk github:logos-co/logos-cpp-sdk/a4bd66c --no-link --print-out-paths)/bin/logoscore}"
RLN_MODULE="$LEZ_RLN_DIR/logos-rln-module/result-rln/lib"
WALLET_MODULE="$LEZ_RLN_DIR/logos-rln-module/result-wallet/lib"

# Delivery module plugin (for mix relay nodes)
if [ -f "$DELIVERY_MODULE_DIR/build_plugin/modules/delivery_module_plugin.$EXT" ]; then
    DELIVERY_PLUGIN="$DELIVERY_MODULE_DIR/build_plugin/modules/delivery_module_plugin.$EXT"
else
    DELIVERY_PLUGIN="$DELIVERY_MODULE_DIR/result/lib/delivery_module_plugin.$EXT"
fi

# Chat module plugin (for sender/receiver)
# Prefer locally-built liblogoschat over nix result (uses vendored Nim toolchain)
CHAT_MODULE_RESULT="$CHAT_MODULE_DIR/result"
if [ -f "$LOGOS_CHAT_DIR/build/liblogoschat.$EXT" ]; then
    CHAT_LIB="$LOGOS_CHAT_DIR/build/liblogoschat.$EXT"
    log "  Using locally-built liblogoschat"
else
    CHAT_LIB="$CHAT_MODULE_RESULT/lib/liblogoschat.$EXT"
fi
CHAT_PLUGIN="$CHAT_MODULE_RESULT/lib/chat_module_plugin.$EXT"

for check in \
    "$RLN_MODULE/liblogos_rln_module.$EXT" \
    "$WALLET_MODULE/liblogos_execution_zone_wallet_module.$EXT" \
    "$DELIVERY_PLUGIN" \
    "$CHAT_PLUGIN" \
    "$CHAT_LIB"; do
    [ -f "$check" ] || die "Missing: $check"
done
log "  All modules present."

# ---------- Phase 4: Start mix nodes ----------
echo "[4/6] Starting $NUM_NODES mix+LEZ nodes..."
LOAD_ORDER="liblogos_execution_zone_wallet_module,liblogos_rln_module,delivery_module"
WALLET_CALL="liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)"
BOOTSTRAP_PEER="/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}"

# NOTE: Off-chain credential generation (setup_credentials) and pre-registration
# (register_commitments) are not used. All nodes and chat clients register their
# RLN memberships at runtime via the gifter protocol on node 0.

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
        GIFTER_FIELDS="\"mixGifterService\": true, \"mixGifterWalletAccount\": \"$GIFTER_ACCOUNT\","
    else
        GIFTER_FIELDS="\"mixGifterNode\": \"$BOOTSTRAP_PEER\", \"mixGifterWalletAccount\": \"$GIFTER_ACCOUNT\","
    fi

    cat > "$NODE_CONFIG" <<EOF
{
  "clusterId": $CLUSTER_ID,
  "numShardsInNetwork": $NUM_SHARDS,
  "listenAddress": "127.0.0.1",
  "tcpPort": $TCP_PORT,
  "discv5UdpPort": $DISC_PORT,
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
EOF

    MDIR=$(mktemp -d); MODULES_DIRS+=("$MDIR")
    # Stage wallet module
    mkdir -p "$MDIR/liblogos_execution_zone_wallet_module"
    cp -L "$WALLET_MODULE/liblogos_execution_zone_wallet_module.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    [ -f "$WALLET_MODULE/libwallet_ffi.$EXT" ] && cp -L "$WALLET_MODULE/libwallet_ffi.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    echo "{\"name\":\"liblogos_execution_zone_wallet_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_execution_zone_wallet_module.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/liblogos_execution_zone_wallet_module/manifest.json"
    # Stage RLN module
    mkdir -p "$MDIR/liblogos_rln_module"
    cp -L "$RLN_MODULE/liblogos_rln_module.$EXT" "$MDIR/liblogos_rln_module/"
    cp -L "$RLN_MODULE/liblez_rln_ffi.$EXT" "$MDIR/liblogos_rln_module/" 2>/dev/null || true
    echo "{\"name\":\"liblogos_rln_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_rln_module.$EXT\"},\"dependencies\":[\"liblogos_execution_zone_wallet_module\"],\"capabilities\":[]}" > "$MDIR/liblogos_rln_module/manifest.json"
    # Stage delivery module
    mkdir -p "$MDIR/delivery_module"
    cp -L "$DELIVERY_PLUGIN" "$MDIR/delivery_module/"
    if [ -f "$DELIVERY_DIR/build/liblogosdelivery.$EXT" ]; then
        cp -L "$DELIVERY_DIR/build/liblogosdelivery.$EXT" "$MDIR/delivery_module/"
    else
        cp -L "$DELIVERY_MODULE_DIR/result/lib/liblogosdelivery.$EXT" "$MDIR/delivery_module/" 2>/dev/null || true
    fi
    for pq in "$DELIVERY_MODULE_DIR"/result/lib/libpq*; do [ -f "$pq" ] && cp -L "$pq" "$MDIR/delivery_module/"; done
    echo "{\"name\":\"delivery_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"delivery_module_plugin.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/delivery_module/manifest.json"

    log "  Starting node $i (port $TCP_PORT)..."
    (cd "$STATE_DIR" && TMPDIR=/tmp "$LOGOSCORE" -m "$MDIR" -l "$LOAD_ORDER" \
        -c "$WALLET_CALL" \
        -c "delivery_module.createNode(@$NODE_CONFIG)" \
        -c "delivery_module.start()" \
        -c "delivery_module.setRlnConfig($CONFIG_ACCOUNT,$i)" \
        -c "delivery_module.subscribe($CONTENT_TOPIC)" \
        </dev/null >"$LOG_FILE" 2>&1) &
    EXPECTED_CALLS=5
    NODE_PID=$!; INSTANCE_PIDS+=($NODE_PID)
    WAIT_TIMEOUT=90
    for t in $(seq 1 $WAIT_TIMEOUT); do
        N=$(grep -c '^Method call successful' "$LOG_FILE" 2>/dev/null || true); N=${N:-0}
        [ "$N" -ge "$EXPECTED_CALLS" ] && break; sleep 1
    done
    if [ "${N:-0}" -ge "$EXPECTED_CALLS" ]; then
        log "    Node $i ready ($N/$EXPECTED_CALLS calls) PID: $NODE_PID"
    else
        echo "  WARNING: Node $i: $N/$EXPECTED_CALLS calls"
    fi
    sleep 10
done
echo ""

# ---------- Phase 5: Chat module sender/receiver ----------
echo "[5/6] Starting chat module instances..."

# Wait for all nodes to be fully ready (gifter registrations finalize during startup)
for i in $(seq 0 $((NUM_NODES - 1))); do
    LOG_FILE="$STATE_DIR/node${i}.log"
    EC=5
    for t in $(seq 1 120); do
        N=$(grep -c '^Method call successful' "$LOG_FILE" 2>/dev/null || true); N=${N:-0}
        [ "$N" -ge "$EC" ] && break; sleep 2
    done
done

# Wait for mix mesh + RLN root convergence. Requires: 3 gifter registrations on
# node0, LEZ root polling events across all nodes, AND min 30s floor for mix
# protocol handshakes to complete (no single log line signals this cleanly).
echo "  Waiting for kademlia propagation + RLN convergence..."
KADEMLIA_T0=$SECONDS
while true; do
    ELAPSED=$((SECONDS - KADEMLIA_T0))
    GR=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node0.log" 2>/dev/null | grep -c "RLN gifter registration succeeded" || true); GR=${GR:-0}
    LR=0
    for i in $(seq 0 $((NUM_NODES - 1))); do
        L=$(sed 's/\x1b\[[0-9;]*m//g' "$STATE_DIR/node${i}.log" 2>/dev/null | grep -c "Polled valid roots\|Fetched roots from\|valid_roots\|OnchainLEZGroupManager initialized\|Wired LEZ callbacks" || true)
        LR=$((LR + L))
    done
    if [ "$ELAPSED" -ge "$KADEMLIA_MIN_WAIT" ] && [ "$GR" -ge 3 ] && [ "$LR" -ge 40 ]; then break; fi
    [ "$ELAPSED" -ge 120 ] && break
    sleep 1
done
log "  Kademlia ready after $((SECONDS - KADEMLIA_T0))s ($GR gifter regs, $LR LEZ root events)"

RECEIVER_LOG="$STATE_DIR/chat_receiver.log"
SENDER_LOG="$STATE_DIR/chat_sender.log"

# Build mix node list for chat config (multiaddr:mixPubKey format)
MIXNODE_LIST=""
for j in $(seq 0 $((NUM_NODES - 1))); do
    [ -n "$MIXNODE_LIST" ] && MIXNODE_LIST="$MIXNODE_LIST,"
    MIXNODE_LIST="$MIXNODE_LIST\"/ip4/127.0.0.1/tcp/$((BASE_TCP_PORT + j))/p2p/${PEER_IDS[$j]}:${MIX_PUBKEYS[$j]}\""
done

# Helper: stage chat_module for a logoscore instance
stage_chat_module() {
    local MDIR=$1
    mkdir -p "$MDIR/liblogos_execution_zone_wallet_module"
    cp -L "$WALLET_MODULE/liblogos_execution_zone_wallet_module.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    [ -f "$WALLET_MODULE/libwallet_ffi.$EXT" ] && cp -L "$WALLET_MODULE/libwallet_ffi.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    echo "{\"name\":\"liblogos_execution_zone_wallet_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_execution_zone_wallet_module.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/liblogos_execution_zone_wallet_module/manifest.json"

    mkdir -p "$MDIR/liblogos_rln_module"
    cp -L "$RLN_MODULE/liblogos_rln_module.$EXT" "$MDIR/liblogos_rln_module/"
    cp -L "$RLN_MODULE/liblez_rln_ffi.$EXT" "$MDIR/liblogos_rln_module/" 2>/dev/null || true
    echo "{\"name\":\"liblogos_rln_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_rln_module.$EXT\"},\"dependencies\":[\"liblogos_execution_zone_wallet_module\"],\"capabilities\":[]}" > "$MDIR/liblogos_rln_module/manifest.json"

    mkdir -p "$MDIR/chat_module"
    cp -L "$CHAT_PLUGIN" "$MDIR/chat_module/"
    cp -L "$CHAT_LIB" "$MDIR/chat_module/"
    echo "{\"name\":\"chat_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"chat_module_plugin.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/chat_module/manifest.json"
}

CHAT_LOAD_ORDER="liblogos_execution_zone_wallet_module,liblogos_rln_module,chat_module"

# --- Receiver ---
RECV_MDIR=$(mktemp -d); MODULES_DIRS+=("$RECV_MDIR")
stage_chat_module "$RECV_MDIR"

RECV_CONFIG="$STATE_DIR/chat_receiver_config.json"
# Build static peer list (ENR or multiaddr) for chat nodes to join relay mesh
CHAT_STATIC_PEERS=""
for j in $(seq 0 $((NUM_NODES - 1))); do
    [ -n "$CHAT_STATIC_PEERS" ] && CHAT_STATIC_PEERS="$CHAT_STATIC_PEERS,"
    CHAT_STATIC_PEERS="$CHAT_STATIC_PEERS\"/ip4/127.0.0.1/tcp/$((BASE_TCP_PORT + j))/p2p/${PEER_IDS[$j]}\""
done
cat > "$RECV_CONFIG" <<EOF
{
  "name": "receiver",
  "clusterId": $CLUSTER_ID,
  "shardId": 0,
  "port": $CHAT_RECV_PORT,
  "mixEnabled": true,
  "mixNodes": [$MIXNODE_LIST],
  "destPeerAddr": "$BOOTSTRAP_PEER",
  "minMixPoolSize": 4,
  "gifterNodeAddr": "$BOOTSTRAP_PEER",
  "staticPeers": [$CHAT_STATIC_PEERS]
}
EOF

TEST_MSG_HEX=$(printf '%s' "$TEST_MESSAGE_PREFIX" | xxd -p | tr -d '\n')

log "  Starting receiver..."
(cd "$STATE_DIR" && TMPDIR=/tmp "$LOGOSCORE" -m "$RECV_MDIR" -l "$CHAT_LOAD_ORDER" \
    -c "$WALLET_CALL" \
    -c "chat_module.initChat(@$RECV_CONFIG)" \
    -c "chat_module.setEventCallback()" \
    -c "chat_module.startChat()" \
    -c "chat_module.setRlnConfig($CONFIG_ACCOUNT,5)" \
    -c "chat_module.createIntroBundle()" \
    </dev/null >"$RECEIVER_LOG" 2>&1) &
RECEIVER_PID=$!; INSTANCE_PIDS+=($RECEIVER_PID)
log "  Receiver PID: $RECEIVER_PID"

# Wait for receiver to complete all method calls (6 calls now including createIntroBundle)
RECV_EXPECTED=6
for t in $(seq 1 180); do
    N=$(grep -c '^Method call successful' "$RECEIVER_LOG" 2>/dev/null || true); N=${N:-0}
    [ "$N" -ge "$RECV_EXPECTED" ] && break; sleep 2
done
N=$(grep -c '^Method call successful' "$RECEIVER_LOG" 2>/dev/null || true); N=${N:-0}
log "  Receiver method calls: $N/$RECV_EXPECTED"

# Extract intro bundle from receiver log (event callback delivers it as chatCreateIntroBundleResult)
INTRO_BUNDLE=""
for t in $(seq 1 30); do
    INTRO_BUNDLE=$(grep -oE 'logos_chatintro_[A-Za-z0-9_-]+' "$RECEIVER_LOG" 2>/dev/null | head -1 || true)
    [ -n "$INTRO_BUNDLE" ] && break; sleep 2
done
if [ -n "$INTRO_BUNDLE" ]; then
    log "  Receiver intro bundle: ${INTRO_BUNDLE:0:40}..."
else
    log "  WARNING: Could not extract intro bundle from receiver log"
fi

# Wait for receiver's async startChat to finish (Waku client started) AND give
# filter subscription a 15s floor to propagate through the relay mesh.
echo "  Waiting for receiver to join mix network..."
JOIN_T0=$SECONDS
while true; do
    ELAPSED=$((SECONDS - JOIN_T0))
    RS=$(grep -c "Waku client started" "$RECEIVER_LOG" 2>/dev/null || true); RS=${RS:-0}
    [ "$ELAPSED" -ge "$RECEIVER_MIN_WAIT" ] && [ "$RS" -ge 1 ] && break
    [ "$ELAPSED" -ge 60 ] && break
    sleep 1
done
log "  Receiver joined after $((SECONDS - JOIN_T0))s"

# --- Sender ---
SEND_MDIR=$(mktemp -d); MODULES_DIRS+=("$SEND_MDIR")
stage_chat_module "$SEND_MDIR"

SEND_CONFIG="$STATE_DIR/chat_sender_config.json"
cat > "$SEND_CONFIG" <<EOF
{
  "name": "sender",
  "clusterId": $CLUSTER_ID,
  "shardId": 0,
  "port": $CHAT_SEND_PORT,
  "mixEnabled": true,
  "mixNodes": [$MIXNODE_LIST],
  "destPeerAddr": "$BOOTSTRAP_PEER",
  "minMixPoolSize": 4,
  "gifterNodeAddr": "$BOOTSTRAP_PEER",
  "staticPeers": [$CHAT_STATIC_PEERS]
}
EOF

# Build sender -c calls: init, start, setRlnConfig, then if we have the intro bundle,
# create a private conversation with the test message
SENDER_CALLS="-c \"$WALLET_CALL\""
SENDER_CALLS="$SENDER_CALLS -c \"chat_module.initChat(@$SEND_CONFIG)\""
SENDER_CALLS="$SENDER_CALLS -c \"chat_module.setEventCallback()\""
SENDER_CALLS="$SENDER_CALLS -c \"chat_module.startChat()\""
# RLN leaf indices: 0-3 = mix nodes, 4 = gifter-reserved, 5 = receiver, 6 = sender
SENDER_CALLS="$SENDER_CALLS -c \"chat_module.setRlnConfig($CONFIG_ACCOUNT,6)\""
if [ -n "$INTRO_BUNDLE" ]; then
    SENDER_CALLS="$SENDER_CALLS -c \"chat_module.newPrivateConversation($INTRO_BUNDLE,$TEST_MSG_HEX)\""
fi

log "  Starting sender..."
eval "(cd \"$STATE_DIR\" && TMPDIR=/tmp \"$LOGOSCORE\" -m \"$SEND_MDIR\" -l \"$CHAT_LOAD_ORDER\" \
    $SENDER_CALLS \
    </dev/null >\"$SENDER_LOG\" 2>&1) &"
SENDER_PID=$!; INSTANCE_PIDS+=($SENDER_PID)
log "  Sender PID: $SENDER_PID"

# Wait for sender to complete method calls
SEND_EXPECTED=6
[ -n "$INTRO_BUNDLE" ] && SEND_EXPECTED=7
for t in $(seq 1 180); do
    N=$(grep -c '^Method call successful' "$SENDER_LOG" 2>/dev/null || true); N=${N:-0}
    [ "$N" -ge "$SEND_EXPECTED" ] && break; sleep 2
done

# On slower systems (Docker/ARM), the sender's async gifter registration may not
# complete before newPrivateConversation runs. Wait for gifter + RLN readiness
# before checking for message delivery. If newPrivateConversation initially failed,
# the Nim async code will retry once credentials are valid.
echo "  Waiting for sender RLN readiness..."
SENDER_RLN_T0=$SECONDS
for t in $(seq 1 60); do
    SG=$(sed 's/\x1b\[[0-9;]*m//g' "$SENDER_LOG" 2>/dev/null | grep -c "Registered via RLN gifter\|Waku client started" || true)
    [ "${SG:-0}" -ge 2 ] && break
    sleep 1
done
log "  Sender RLN ready after $((SECONDS - SENDER_RLN_T0))s"
N=$(grep -c '^Method call successful' "$SENDER_LOG" 2>/dev/null || true); N=${N:-0}
log "  Sender method calls: $N/$SEND_EXPECTED"

# Poll receiver log for incoming message(s) instead of waiting a fixed 120s.
echo "  Waiting for message delivery via mix..."
DELIVERY_T0=$SECONDS
for t in $(seq 1 $DELIVERY_TIMEOUT); do
    RM=$(grep -c "chatNewMessage\|chatNewConversation\|New Message\|new_message" "$RECEIVER_LOG" 2>/dev/null || true); RM=${RM:-0}
    [ "$RM" -ge 1 ] && break
    sleep 1
done
log "  Delivery check after $((SECONDS - DELIVERY_T0))s (messages: $RM)"

echo ""

# ---------- Phase 6: Verify ----------
echo "[6/6] Verification"; echo ""
PASS=0; FAIL=0
check() { local c=$1 d=$2; if eval "$c"; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d"; FAIL=$((FAIL+1)); fi; }

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
RECV_INIT=$(grep -c "chatInitResult\|Chat context created" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_INIT:-0} -ge 1 ]" "Receiver initialized ($RECV_INIT)"
RECV_START=$(grep -c "chatStartResult\|Waku client started" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_START:-0} -ge 1 ]" "Receiver started ($RECV_START)"
SEND_INIT=$(grep -c "chatInitResult\|Chat context created" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_INIT:-0} -ge 1 ]" "Sender initialized ($SEND_INIT)"
SEND_START=$(grep -c "chatStartResult\|Waku client started" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_START:-0} -ge 1 ]" "Sender started ($SEND_START)"

RECV_MIX=$(grep -c "mounting mix protocol\|Wired LEZ callbacks" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_MIX:-0} -ge 1 ]" "Receiver mounted mix+LEZ ($RECV_MIX)"
SEND_MIX=$(grep -c "mounting mix protocol\|Wired LEZ callbacks" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_MIX:-0} -ge 1 ]" "Sender mounted mix+LEZ ($SEND_MIX)"

RECV_BUNDLE=$(grep -c "logos_chatintro_" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_BUNDLE:-0} -ge 1 ]" "Receiver created intro bundle ($RECV_BUNDLE)"
echo ""

echo "  --- message exchange ---"
SEND_MSG=$(grep -c "chatNewPrivateConversationResult\|chatSendMessageResult\|Message sent via mix" "$SENDER_LOG" 2>/dev/null || true)
check "[ ${SEND_MSG:-0} -ge 1 ]" "Sender sent message ($SEND_MSG)"
RECV_MSG=$(grep -c "chatNewMessage\|chatNewConversation\|New Message\|new_message" "$RECEIVER_LOG" 2>/dev/null || true)
check "[ ${RECV_MSG:-0} -ge 1 ]" "Receiver received message ($RECV_MSG)"

echo ""; echo "  =========================================="
if [ "$FAIL" -eq 0 ]; then echo "  ALL $PASS CHECKS PASSED"; EXIT_CODE=0
else echo "  $FAIL FAILED, $PASS passed"; EXIT_CODE=1; fi
echo "  =========================================="

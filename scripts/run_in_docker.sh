#!/usr/bin/env bash
# Run the mix+LEZ chat simulation inside a Docker container (Linux aarch64).
#
# The Docker image pre-builds EVERYTHING: LEZ modules, sequencer, logoscore,
# liblogoschat, chat_module_plugin. Each sim run only clones the repo (for
# scripts + configs), symlinks pre-built artifacts, and runs the simulation.
#
# First run: ~60 min (one-time docker build)
# Subsequent runs: ~5 min (clone + submodule init + sim)
#
# Prerequisites: Docker Desktop running.
#
# Usage:
#   bash scripts/run_in_docker.sh
#   BRANCH=my-branch bash scripts/run_in_docker.sh  # test a different branch
#
# Environment variables:
#   BRANCH              — git branch to clone (default: feat/logos-delivery)
#   REPO_URL            — git repo URL
#   GUEST_BINARIES_DIR  — path to pre-built guest .bin files (auto-detected)
#   REBUILD_IMAGE       — set to 1 to force image rebuild
#   SIM_*               — simulation parameters, passed through to run_simulation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$ROOT/.github/Dockerfile.sim"
IMAGE_NAME="logos-chat-sim"
CONTAINER_NAME="logos-chat-sim-run"
BRANCH="${BRANCH:-feat/logos-delivery}"
REPO_URL="${REPO_URL:-https://github.com/adklempner/logos-chat.git}"

# Build image if it doesn't exist or REBUILD_IMAGE=1
if [ "${REBUILD_IMAGE:-0}" = "1" ] || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "=== Building Docker image (one-time — ~60 min) ==="
    docker build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$ROOT"
else
    echo "=== Docker image cached ==="
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
trap 'echo "=== Rescuing logs ==="; docker cp "$CONTAINER_NAME:/root/logos-chat/simulations/mix_lez_chat/.sim_state" ./docker-sim-logs 2>/dev/null || true; docker rm -f "$CONTAINER_NAME" 2>/dev/null || true' EXIT

echo "=== Starting container ==="
docker run --rm -d --name "$CONTAINER_NAME" "$IMAGE_NAME" tail -f /dev/null

# Stage guest binaries
GUEST_REL="vendor/logos-lez-rln/lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker"
GUEST_SRC=""
for candidate in \
    "${GUEST_BINARIES_DIR:-}" \
    "$ROOT/$GUEST_REL" \
    "$HOME/Waku/Logos/logos-chat/$GUEST_REL" \
    "../logos-chat/$GUEST_REL"; do
    [ -f "$candidate/rln_registration.bin" ] 2>/dev/null && GUEST_SRC="$candidate" && break
done
if [ -n "$GUEST_SRC" ]; then
    echo "=== Staging guest binaries ==="
    docker exec "$CONTAINER_NAME" mkdir -p "/tmp/guest-bins"
    docker cp "$GUEST_SRC/rln_registration.bin" "$CONTAINER_NAME:/tmp/guest-bins/"
    docker cp "$GUEST_SRC/incremental_merkle_tree.bin" "$CONTAINER_NAME:/tmp/guest-bins/"
fi

# Collect SIM_* env vars
SIM_ENVS=""
for var in $(env | grep '^SIM_' | cut -d= -f1); do
    SIM_ENVS="$SIM_ENVS export $var='${!var}';"
done

echo "=== Running simulation ==="
docker exec "$CONTAINER_NAME" bash -c "
$SIM_ENVS
export RISC0_DEV_MODE=1

# Clone repo (just for scripts + configs, not for building)
cd /root
rm -rf logos-chat
git clone --depth 1 -b $BRANCH $REPO_URL
cd logos-chat
# Only init top-level submodules + logos-lez-rln selectively (for sim script paths)
git submodule update --init --depth 1
(cd vendor/logos-lez-rln && git submodule update --init --depth 1 lssa logos-delivery logos-delivery-module logos-execution-zone-module)
(cd vendor/logos-lez-rln/logos-delivery-module && git submodule update --init --depth 1 vendor/logos-delivery)

# Symlink ALL pre-built artifacts from the Docker image
LEZ_DIR=vendor/logos-lez-rln
ln -sf /root/lez-modules/result-rln \$LEZ_DIR/logos-rln-module/result-rln
ln -sf /root/lez-modules/result-wallet \$LEZ_DIR/logos-rln-module/result-wallet
mkdir -p \$LEZ_DIR/logos-delivery-module/build_plugin
cp -r /root/lez-modules/delivery-plugin \$LEZ_DIR/logos-delivery-module/build_plugin/modules
mkdir -p \$LEZ_DIR/logos-delivery-module/vendor/logos-delivery/build
cp /root/lez-modules/delivery-build/* \$LEZ_DIR/logos-delivery-module/vendor/logos-delivery/build/ 2>/dev/null || true
# Sequencer is built from source at runtime (pre-built crashes in risc0 dev prover).
# Reuse cargo target cache from image to speed up (~30s vs ~2min).
ln -sf /root/lez-modules/lssa-target-cache \$LEZ_DIR/lssa/target
mkdir -p \$LEZ_DIR/lez-rln/target/debug
cp /root/lez-modules/run_setup \$LEZ_DIR/lez-rln/target/debug/
mkdir -p build
cp /root/lez-modules/liblogoschat.so build/

# Restore guest binaries
GUEST_DIR=\"\$LEZ_DIR/lez-rln/methods/guest/target/riscv32im-risc0-zkvm-elf/docker\"
if [ -f /tmp/guest-bins/rln_registration.bin ]; then
    mkdir -p \"\$GUEST_DIR\"
    cp /tmp/guest-bins/*.bin \"\$GUEST_DIR/\"
fi

# Chat module — symlink from pre-built in image
ln -sf /root/lez-modules/chat-module-result /root/logos-chat-module/result 2>/dev/null || \
    (mkdir -p /root/logos-chat-module && ln -sf /root/lez-modules/chat-module-result /root/logos-chat-module/result)

# Set env vars for sim
export LOGOSCORE=\"/root/lez-modules/logoscore-result/bin/logoscore\"
CLANG_SO=\$(find /nix/store -maxdepth 3 -name 'libclang.so' 2>/dev/null | head -1 || true)
[ -n \"\$CLANG_SO\" ] && export LIBCLANG_PATH=\$(dirname \"\$CLANG_SO\")

bash simulations/mix_lez_chat/run_simulation.sh --fresh
"

echo "=== Done ==="
# Container cleanup handled by EXIT trap (which also rescues logs on failure)

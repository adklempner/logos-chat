#!/usr/bin/env bash
# Demo wrapper: run the full sim with SIM_DEMO_MODE=1, which replaces the
# normal 6/6 verification with the RLN gifter-protocol markers (request
# received, membership granted, proof generated, proof verified by another
# mix node). Spins up its own infra each run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SIM_DEMO_MODE=1
exec bash "$SCRIPT_DIR/run_simulation_lgx.sh" "$@"

#!/usr/bin/env bash
# Demo wrapper: run the full sim with SIM_DEMO_MODE=1, which replaces the
# normal 6/6 verification with a three-marker check of the RLN gifter
# protocol (request received, membership granted, proof verified by another
# mix node). Spins up its own infra each run — re-runnable against a
# persistent demo_setup.sh is not yet wired (would need to skip phases 1-5
# by sourcing $STATE_DIR/demo_state.env).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SIM_DEMO_MODE=1
exec bash "$SCRIPT_DIR/run_simulation_lgx.sh" "$@"

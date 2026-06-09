#!/usr/bin/env bash
# Demo wrapper: bring the mix+LEZ+chat infra up and pause with the receiver
# ready, waiting for demo_step.sh to spawn a fresh sender against it.
# Ctrl-C tears everything down via the sim's EXIT trap.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SIM_SETUP_ONLY=1
exec bash "$SCRIPT_DIR/run_simulation_lgx.sh" "$@"

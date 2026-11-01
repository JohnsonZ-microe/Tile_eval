#!/usr/bin/env bash
# Rev4 VCS wrapper (Linux, licensed VCS). Delegates to scripts/run.py.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite) SUITE="$2"; shift 2;;
        --seed) SEED="$2"; shift 2;;
        --test) TEST="$2"; shift 2;;
        *) ARGS+=("$1"); shift;;
    esac
done
export SUITE="${SUITE:-full}" SEED="${SEED:-817}" TEST="${TEST:-all}"
python3 -B scripts/run.py vcs --suite "$SUITE" --seed "$SEED" --test "$TEST" "${ARGS[@]+"${ARGS[@]}"}"

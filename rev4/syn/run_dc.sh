#!/usr/bin/env bash
set -euo pipefail
syn_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "${PYTHON:-python3}" -B "$syn_dir/../scripts/run.py" dc "$@"

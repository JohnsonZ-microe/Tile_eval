#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/run_vcs.sh --test tile --suite legacy --seed 817
bash scripts/run_vcs.sh --test all --suite full --seed 817
for seed in 818 819; do
    bash scripts/run_vcs.sh --test tile --suite full --seed "$seed"
done

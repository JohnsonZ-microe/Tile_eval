#!/usr/bin/env bash
# Run the remaining benches after tile/yacc/yacc_direct acceptance.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
command -v python3 >/dev/null || exit 127
command -v "${VCS:-vcs}" >/dev/null || { echo "VCS environment is not loaded" >&2; exit 127; }
seed="${SEED:-817}"
summary="$(mktemp "${TMPDIR:-/tmp}/tile-remaining-full-XXXXXXXX.tsv")" || exit 1
printf 'test\texit_code\n' > "$summary"
echo "Summary: $summary"
failed=0
for test in cells math modules compute protocol memory control promotion; do
    printf '\nStarting %s (full, seed %s)\n' "$test" "$seed"
    bash scripts/run_vcs.sh --test "$test" --suite full --seed "$seed"
    rc=$?
    printf '%s\t%s\n' "$test" "$rc" >> "$summary"
    if [ "$rc" -ne 0 ]; then failed=1; fi
done
cat "$summary"
echo "Each run prints its own products_dir and log_dir; inspect manifests for acceptance."
exit "$failed"

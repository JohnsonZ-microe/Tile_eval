#!/usr/bin/env bash
# SpyGlass lint check for rev4 RTL (syn/run_spyglass.sh)
# Usage:
#   source /usr/eelocal/synopsys/spyglass-vv2023.12-sp1/.cshrc
#   bash syn/run_spyglass.sh [--top tile_ffn_v4] [--goal lint_rtl]
#
# Options (env vars or flags):
#   TOP       — design top (default: tile_ffn_v4)
#   GOAL      — SpyGlass goal (default: lint_rtl; also: lint, cdc, cdc_reset)
#   OUTDIR    — output directory (default: spyglass_results/<stamp>)
#   BLACKBOX  — 1=define PE4_MEM_BLACKBOX (default: 0, lint the real code)

set -euo pipefail
cd "$(dirname "$0")/.."

TOP="${TOP:-tile_ffn_v4}"
GOAL="${GOAL:-lint_rtl}"
BLACKBOX="${BLACKBOX:-0}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="${OUTDIR:-spyglass_results/${STAMP}-$$}"
mkdir -p "${OUTDIR}"

# Parse command-line overrides
while [[ $# -gt 0 ]]; do
    case "$1" in
        --top)    TOP="$2"; shift 2;;
        --goal)   GOAL="$2"; shift 2;;
        --outdir) OUTDIR="$2"; shift 2;;
        --blackbox) BLACKBOX=1; shift;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

echo "=== SpyGlass lint ==="
echo "TOP=${TOP}  GOAL=${GOAL}  BLACKBOX=${BLACKBOX}"
echo "OUTDIR=${OUTDIR}"

# ------------------------------------------------------------------
# Build the file list: only rev4 RTL (skip frozen rev3)
# ------------------------------------------------------------------
FILELIST="${OUTDIR}/rtl_spyglass.f"
SOURCES=()
while IFS= read -r line; do
    line="$(echo "$line" | xargs)"  # trim
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == ../rev3/* ]] && continue  # skip frozen rev3
    SOURCES+=("$line")
done < scripts/rtl.f

echo "Source files (${#SOURCES[@]}):"
for f in "${SOURCES[@]}"; do echo "  $f"; done

# Verify all files exist
for f in "${SOURCES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: missing source file $f"
        exit 1
    fi
done

# ------------------------------------------------------------------
# Generate the SpyGlass project file
# ------------------------------------------------------------------
PRJ="${OUTDIR}/spyglass.prj"
{
    echo "# SpyGlass project — auto-generated $(date -u)"
    echo "# TOP=${TOP} GOAL=${GOAL}"

    # Define macro if blackbox mode
    if [[ "$BLACKBOX" == "1" ]]; then
        echo "read_file -type sv -define PE4_MEM_BLACKBOX \\"
    else
        echo "read_file -type sv \\"
    fi

    # List files
    first=1
    for f in "${SOURCES[@]}"; do
        if [[ $first -eq 1 ]]; then
            echo "    $f"
            first=0
        else
            echo "    $f"
        fi
    done

    echo ""
    echo "# Design settings"
    echo "set_option top ${TOP}"
    echo "set_option language sv"
    echo "set_option enableSV yes"
    echo "set_option svaoff yes"

} > "${PRJ}"

echo ""
echo "Project file: ${PRJ}"
echo ""

# ------------------------------------------------------------------
# Run SpyGlass
# ------------------------------------------------------------------
SG_CMD="$(command -v spyglass || command -v sg_shell || echo spyglass)"
echo "Running: ${SG_CMD} -goal ${GOAL} -project ${PRJ}"
echo ""

"${SG_CMD}" -goal "${GOAL}" -project "${PRJ}" \
    2>&1 | tee "${OUTDIR}/spyglass_console.log"

SG_EXIT=$?

echo ""
echo "=== Results ==="

# Check for summary report
SUMMARY="${OUTDIR}/spyglass_console.log"
if [[ -f "$SUMMARY" ]]; then
    # Show summary
    grep -E "(Violation|Warning|Error|Info|PASS|FAIL|Summary|Total)" "$SUMMARY" | tail -20 || true
fi

# Look for HTML reports
HTML_DIR="${OUTDIR}/spyglass_reports"
if [[ -d "$HTML_DIR" ]]; then
    echo "HTML reports: ${HTML_DIR}"
fi

# Look for generated reports
for f in "${OUTDIR}"/*report* "${OUTDIR}"/*summary*; do
    [[ -f "$f" ]] && echo "  $(basename "$f")"
done

echo ""
echo "Output directory: ${OUTDIR}"
echo "Console log: ${OUTDIR}/spyglass_console.log"
echo "Exit code: ${SG_EXIT}"

exit ${SG_EXIT}

#!/usr/bin/env bash
# SpyGlass lint check for rev4 RTL (syn/run_spyglass.sh)
# Usage:
#   source /usr/eelocal/synopsys/spyglass-vv2023.12-sp1/.cshrc
#   bash syn/run_spyglass.sh [--top tile_ffn_v4] [--goal lint_rtl]
#
# Options (env vars or flags):
#   TOP       — design top (default: tile_ffn_v4)
#   GOAL      — SpyGlass goal (default: lint_rtl). Goal availability depends
#               on the site methodology; if the goal is rejected the script
#               auto-retries GOAL_FALLBACKS (goal lookup fails fast).
#   GOAL_FALLBACKS — space-separated fallback goals (default: "lint lint_lint
#               lint_abstract"). Example: GOAL=cdc GOAL_FALLBACKS='cdc_reset cdc_verify'
#   OUTDIR    — output directory (default: spyglass_results/<stamp>)
#   BLACKBOX  — 1=define PE4_MEM_BLACKBOX (default: 0, lint the real code)
#   TYPE      — read_file file type (default: verilog). This install has NO
#               'sverilog' type — allowed values (from its own error msg):
#               verilog vhdl def hdl gateslib gateslibdb sglib lef plib
#               sgdc waiver adc awl sourcelist sourcelist_relative obw
#   EXTRA_PRJ_LINES — extra lines appended verbatim to spyglass.prj, e.g.
#               EXTRA_PRJ_LINES='set_option enableSV yes' bash syn/run_spyglass.sh
#   --dry-run — generate + self-check spyglass.prj, do NOT launch SpyGlass

set -euo pipefail
cd "$(dirname "$0")/.."

TOP="${TOP:-tile_ffn_v4}"
GOAL="${GOAL:-lint_rtl}"
BLACKBOX="${BLACKBOX:-0}"
TYPE="${TYPE:-verilog}"
EXTRA_PRJ_LINES="${EXTRA_PRJ_LINES:-}"
GOAL_FALLBACKS="${GOAL_FALLBACKS:-lint lint_lint lint_abstract}"
DRYRUN=0
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
        --type)   TYPE="$2"; shift 2;;
        --dry-run) DRYRUN=1; shift;;
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
    # trim leading/trailing whitespace (pure bash; xargs breaks on spaces)
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == ../rev3/* ]] && continue  # skip frozen rev3
    SOURCES+=("$line")
done < scripts/rtl.f

# Keep the filtered file list for reference / other tools
printf '%s\n' "${SOURCES[@]}" > "${FILELIST}"

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
#
# IMPORTANT: a .prj file is a Tcl script — SpyGlass reads it with a Tcl
# interpreter. Tcl line continuation ("\" at end of line) must appear on
# EVERY continued line, so multi-line file lists are fragile. We emit ONE
# self-contained single-line read_file command per source file: no
# continuations, no escapes — valid Tcl by construction.
# File type: verified against THIS install (spyglass vv2023.12-sp1) —
# 'sverilog' is NOT a valid read_file -type here; .sv files are read with
# -type verilog. To experiment with extra SpyGlass options without editing
# this script, use EXTRA_PRJ_LINES (see header).
# ------------------------------------------------------------------
PRJ="${OUTDIR}/spyglass.prj"
{
    echo "# SpyGlass project — auto-generated $(date -u)"
    echo "# TOP=${TOP} GOAL=${GOAL} BLACKBOX=${BLACKBOX} TYPE=${TYPE}"
    echo ""

    OPTS="-type ${TYPE}"
    if [[ "$BLACKBOX" == "1" ]]; then
        OPTS="${OPTS} -define PE4_MEM_BLACKBOX"
    fi
    for f in "${SOURCES[@]}"; do
        echo "read_file ${OPTS} $f"
    done

    echo ""
    echo "# Design settings"
    echo "set_option top ${TOP}"
    if [[ -n "${EXTRA_PRJ_LINES}" ]]; then
        echo ""
        echo "# Extra options via EXTRA_PRJ_LINES"
        while IFS= read -r l; do
            [[ -z "$l" ]] && continue
            echo "$l"
        done <<< "${EXTRA_PRJ_LINES}"
    fi
} > "${PRJ}"

echo ""
echo "Project file: ${PRJ}"
echo ""

# ------------------------------------------------------------------
# Self-check: the .prj is a Tcl script. Validate it with tclsh (SpyGlass
# commands stubbed out) so syntax errors surface HERE, not as FATAL
# errors inside SpyGlass after license checkout and a long parse.
# ------------------------------------------------------------------
if command -v tclsh >/dev/null 2>&1; then
    CHECK="${OUTDIR}/prj_syntax_check.tcl"
    cat > "${CHECK}" <<EOF
# Auto-generated: stub SpyGlass commands; Tcl syntax check only
foreach cmd {read_file set_option current_goal run_goal} {
    proc \$cmd {args} {}
}
if {[catch {source {${PRJ}}} err]} {
    puts stderr "PRJ-SYNTAX-ERROR: \$err"
    exit 1
}
puts "PRJ-SYNTAX-OK"
EOF
    echo "Syntax-checking ${PRJ} with tclsh ..."
    if ! tclsh "${CHECK}"; then
        echo ""
        echo "ERROR: generated .prj is not valid Tcl. Content:"
        echo "---- ${PRJ} ----"
        cat "${PRJ}"
        echo "----------------"
        exit 1
    fi
else
    echo "NOTE: tclsh not found - skipped .prj Tcl syntax self-check"
fi

if [[ "$DRYRUN" == "1" ]]; then
    echo ""
    echo "=== DRY RUN complete - SpyGlass NOT launched ==="
    echo "---- ${PRJ} ----"
    cat "${PRJ}"
    echo "----------------"
    echo "Output directory: ${OUTDIR}"
    exit 0
fi

# ------------------------------------------------------------------
# Run SpyGlass
#
# Goal availability depends on the site's methodology (one install reported
# `lint_rtl' not found). Goal lookup happens BEFORE any RTL compile and
# fails within seconds, so trying fallback goals is cheap.
# ------------------------------------------------------------------
SG_CMD="$(command -v spyglass || command -v sg_shell || echo spyglass)"

GOAL_CANDIDATES=("${GOAL}")
if [[ -n "${GOAL_FALLBACKS}" ]]; then
    read -r -a _FB <<< "${GOAL_FALLBACKS}"
    GOAL_CANDIDATES+=("${_FB[@]}")
fi

SG_EXIT=1
ATTEMPTED=""
for G in "${GOAL_CANDIDATES[@]}"; do
    [[ " ${ATTEMPTED} " == *" ${G} "* ]] && continue   # skip duplicates
    ATTEMPTED="${ATTEMPTED} ${G}"
    echo "Running: ${SG_CMD} -goal ${G} -project ${PRJ}"
    echo ""
    # set -e off so a failure still reaches the diagnostics below;
    # PIPESTATUS[0] is spyglass's own exit code, not tee's.
    set +e
    "${SG_CMD}" -goal "${G}" -project "${PRJ}" \
        2>&1 | tee "${OUTDIR}/spyglass_console.log"
    SG_EXIT=${PIPESTATUS[0]}
    set -e
    if grep -q "not found in current methodology" "${OUTDIR}/spyglass_console.log"; then
        echo ""
        echo "NOTE: goal '${G}' not found in this methodology - trying next candidate"
        echo "      (override the candidate list with GOAL_FALLBACKS='name1 name2 ...')"
        continue
    fi
    GOAL="${G}"
    break
done

if grep -q "not found in current methodology" "${OUTDIR}/spyglass_console.log"; then
    echo ""
    echo "ERROR: none of the candidate goals${ATTEMPTED} exist in this methodology."
    echo "       Check which goals your site provides (SpyGlass GUI goal browser or admin docs)"
    echo "       and rerun with GOAL=<name>."
fi

echo ""
echo "=== Results ==="

# Check for summary report
SUMMARY="${OUTDIR}/spyglass_console.log"
if [[ -f "$SUMMARY" ]]; then
    # Show summary
    grep -E "(FATAL|invalid|Violation|Warning|Error|Info|PASS|FAIL|Summary|Total)" "$SUMMARY" | tail -20 || true
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
echo "Goal used:    ${GOAL}"
echo "Exit code: ${SG_EXIT}"

exit ${SG_EXIT}

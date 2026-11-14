#!/usr/bin/env bash
# tile-logs-sync (VDI side)
#
# Watches ~/Desktop/Products/logs for finished VCS run directories and pushes
# each one to the local Windows machine, which unpacks it into
# D:\Documents\ChatGPT\LNS_DSE\Tile_eval\logs\<tag>\.
#
# A run is considered finished when its directory contains exit_code.txt
# (run.py writes that last) and has stopped changing for SETTLE seconds.
#
# Usage:
#   ./vdi_push_logs.sh --once            push everything finished, then exit
#   ./vdi_push_logs.sh --watch           keep watching (default)
#   ./vdi_push_logs.sh --tag vcs-...     push one specific run
#   ./vdi_push_logs.sh --force           re-push even if already sent
#   ./vdi_push_logs.sh --status          show what is pending/already sent
#
# Config (~/.tile-logs-sync.conf, auto-created on first run):
#   PUSH_URL=http://143.89.176.1:8000
#   PUSH_TOKEN=<shared secret>
#
set -u

LOGS_DIR="${LOGS_DIR:-$HOME/Desktop/Products/logs}"
CONF="${LOGS_CONF:-$HOME/.tile-logs-sync.conf}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/tile-logs-sync}"
PUSHED_DIR="$STATE_DIR/pushed"
INTERVAL="${INTERVAL:-15}"        # seconds between scans in --watch
SETTLE="${SETTLE:-8}"             # seconds a dir must be quiet to count as done
MARKER="exit_code.txt"

mkdir -p "$PUSHED_DIR" || { echo "cannot create $PUSHED_DIR" >&2; exit 1; }

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
else
  cat > "$CONF" <<EOF
# tile-logs-sync endpoint (laptop running receiver.py)
PUSH_URL=${PUSH_URL:-http://143.89.176.1:8000}
PUSH_TOKEN=${PUSH_TOKEN:-}
EOF
  chmod 600 "$CONF"
  echo "created $CONF -- edit PUSH_URL if the laptop IP changed" >&2
fi

PUSH_URL="${PUSH_URL:-http://143.89.176.1:8000}"
PUSH_TOKEN="${PUSH_TOKEN:-}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

need_url() {
  if [ -z "$PUSH_TOKEN" ]; then
    echo "PUSH_TOKEN is empty; set it in $CONF" >&2
    exit 2
  fi
}

# A directory is pushable when it holds the completion marker and its mtimes
# have settled (avoids shipping a half-written tar).
dir_ready() {
  local d="$1"
  [ -d "$d" ] || return 1
  [ -f "$d/$MARKER" ] || return 1
  local newest now
  newest=$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  [ -n "$newest" ] || return 1
  now=$(date +%s)
  # shellcheck disable=SC2004
  awk -v n="$newest" -v now="$now" -v s="$SETTLE" 'BEGIN{exit !((now - n) >= s)}'
}

push_one() {
  local tag="$1"
  local dir="$LOGS_DIR/$tag"
  local marker="$PUSHED_DIR/$tag"
  local force="${2:-0}"

  if [ -f "$marker" ] && [ "$force" != "1" ]; then
    log "skip $tag (already pushed; use --force to resend)"
    return 0
  fi
  if ! dir_ready "$dir"; then
    log "skip $tag (not finished yet: no $MARKER or still changing)"
    return 1
  fi

  local tmp resp code attempt
  tmp=$(mktemp -t "tilelogs.XXXXXX") || return 1
  resp="${tmp}.resp"
  if ! tar czf "$tmp" -C "$LOGS_DIR" "$tag" 2>"${tmp}.err"; then
    log "tar failed for $tag: $(cat "${tmp}.err")"
    rm -f "$tmp" "${tmp}.err" "$resp"
    return 1
  fi
  local size
  size=$(wc -c < "$tmp")
  log "pushing $tag (${size} bytes) -> $PUSH_URL"

  code=""
  for attempt in 1 2 3; do
    # feed the archive through stdin: never let curl interpret our temp path
    code=$(curl -sS -m 300 -o "$resp" -w '%{http_code}' \
      -H "X-Sync-Token: $PUSH_TOKEN" \
      -H "Content-Type: application/gzip" \
      --data-binary @- \
      "$PUSH_URL/push/$tag.tgz" < "$tmp" 2>"${tmp}.curlerr") || code="000"
    case "$code" in
      200|201) break ;;
      409)     log "server already has identical $tag"; break ;;
      000|5*)  log "attempt $attempt failed (http=$code): $(cat "${tmp}.curlerr")"; sleep $((attempt * 3)) ;;
      *)       log "rejected (http=$code): $(head -c 300 "$resp" 2>/dev/null)"; break ;;
    esac
  done

  if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "409" ]; then
    date '+%Y-%m-%dT%H:%M:%S%z' > "$marker"
    log "ok $tag ($code)"
    rm -f "$tmp" "$resp" "${tmp}.err" "${tmp}.curlerr"
    return 0
  fi
  log "giving up on $tag for now (http=$code); will retry on next scan"
  rm -f "$tmp" "$resp" "${tmp}.err" "${tmp}.curlerr"
  return 1
}

scan_once() {
  local tag rc=0
  [ -d "$LOGS_DIR" ] || { log "no logs dir: $LOGS_DIR"; return 1; }
  for dir in "$LOGS_DIR"/vcs-*; do
    [ -d "$dir" ] || continue
    tag=$(basename "$dir")
    if ! dir_ready "$dir"; then continue; fi
    if [ -f "$PUSHED_DIR/$tag" ] && [ "${FORCE:-0}" != "1" ]; then continue; fi
    push_one "$tag" "${FORCE:-0}" || rc=1
  done
  return $rc
}

status() {
  local tag
  echo "logs dir : $LOGS_DIR"
  echo "endpoint : $PUSH_URL"
  for dir in "$LOGS_DIR"/vcs-*; do
    [ -d "$dir" ] || continue
    tag=$(basename "$dir")
    if [ -f "$PUSHED_DIR/$tag" ]; then
      printf '  sent     %s (at %s)\n' "$tag" "$(cat "$PUSHED_DIR/$tag")"
    elif dir_ready "$dir"; then
      printf '  PENDING  %s\n' "$tag"
    else
      printf '  running  %s\n' "$tag"
    fi
  done
}

MODE="watch"
FORCE=0
ONE_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once)   MODE="once" ;;
    --watch)  MODE="watch" ;;
    --force)  FORCE=1 ;;
    --status) MODE="status" ;;
    --tag)    shift; ONE_TAG="${1:-}" ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

need_url

case "$MODE" in
  status) status ;;
  once)
    if [ -n "$ONE_TAG" ]; then push_one "$ONE_TAG" "$FORCE"; else scan_once; fi ;;
  watch)
    log "watching $LOGS_DIR -> $PUSH_URL (every ${INTERVAL}s)"
    log "already-sent state: $PUSHED_DIR"
    if [ -n "$PUSH_TOKEN" ]; then :; fi
    while :; do
      scan_once || true
      sleep "$INTERVAL"
    done ;;
esac

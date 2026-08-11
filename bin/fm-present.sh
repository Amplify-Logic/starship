#!/usr/bin/env bash
# fm-present.sh - open a captain-action artifact at most once per unchanged milestone.
#
# This policy wrapper routes reports and decisions through their existing private
# Lavish owners and uses macOS open only to reveal local artifacts.
# Call it only when the captain's next action is to read, review, or choose.
# Routine progress is not a presentation milestone, and opening never records
# approval or performs an outward action.
#
# Usage:
#   fm-present.sh report <task-id-or-markdown>
#   fm-present.sh decision <origin-id>
#   fm-present.sh reveal <path>
#
# Environment:
#   FM_HOME                   private Firstmate home; defaults to this repository root
#   FM_STATE_OVERRIDE         receipt directory override; defaults to $FM_HOME/state
#   FM_PRESENT_GUI            auto, 1, or 0; explicit values are intended for tests
#   FM_PRESENT_READ_BIN       report-owner override for tests
#   FM_PRESENT_DECISION_BIN   decision-owner override for tests
#   FM_PRESENT_OPEN_BIN       macOS open override for tests
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
READ_BIN=${FM_PRESENT_READ_BIN:-$SCRIPT_DIR/fm-read.sh}
DECISION_BIN=${FM_PRESENT_DECISION_BIN:-$SCRIPT_DIR/fm-decision-surface.sh}
OPEN_BIN=${FM_PRESENT_OPEN_BIN:-open}
GUI_MODE=${FM_PRESENT_GUI:-auto}
CLAIMED_RECEIPT=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-present: %s\n' "$*" >&2
  exit 1
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

absolute_existing_path() {
  local path=$1 dir base
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
    return
  fi
  dir=$(dirname "$path")
  base=$(basename "$path")
  [ -d "$dir" ] || return 1
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

report_source() {
  local input=$1 report
  if [ -f "$input" ]; then
    absolute_existing_path "$input"
  elif printf '%s\n' "$input" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    report=$FM_HOME/data/$input/report.md
    [ -f "$report" ] || return 1
    absolute_existing_path "$report"
  else
    return 1
  fi
}

gui_available() {
  case "$GUI_MODE" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
    auto|'') ;;
    *) return 1 ;;
  esac

  [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 1
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    command -v launchctl >/dev/null 2>&1 || return 1
    launchctl print "gui/$(id -u)" >/dev/null 2>&1
  else
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
  fi
}

reveal_gui_available() {
  gui_available || return 1
  case "$GUI_MODE" in
    1|true|yes) ;;
    *) [ "$(uname -s 2>/dev/null || true)" = Darwin ] || return 1 ;;
  esac
  command -v "$OPEN_BIN" >/dev/null 2>&1
}

print_fallback() {
  printf '%s\n' "$1"
  exit 0
}

receipt_claim() {
  local milestone=$1 artifact_digest=$2 key receipt
  key=$(printf '%s\n%s\n' "$milestone" "$artifact_digest" | sha256_stream) || return 1
  receipt=$STATE/.fm-present-$key.receipt
  [ ! -e "$receipt" ] || return 1
  mkdir -p "$STATE" 2>/dev/null || return 1
  (
    set -C
    umask 077
    printf 'fm-present-v1\nmilestone=%s\nartifact-sha256=%s\n' "$milestone" "$artifact_digest" > "$receipt"
  ) 2>/dev/null || return 1
  CLAIMED_RECEIPT=$receipt
}

receipt_cleanup() {
  [ -z "$CLAIMED_RECEIPT" ] || rm -f "$CLAIMED_RECEIPT"
}

receipt_commit() {
  CLAIMED_RECEIPT=
  trap - EXIT HUP INT TERM
}

presentation_failed() {
  print_fallback "$1"
}

decision_artifact() {
  local page=$1 origin=$2
  node - "$page" "$origin" <<'NODE'
const fs = require("node:fs");
const [page, origin] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const match = html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s);
if (!match) process.exit(1);
const manifest = JSON.parse(match[1]);
const decisions = manifest.decisions.filter((item) => item.origin === origin);
if (decisions.length === 0) process.exit(1);
process.stdout.write(JSON.stringify(decisions));
NODE
}

plain_text_file() {
  [ -f "$1" ] || return 1
  [ ! -s "$1" ] || LC_ALL=C grep -Iq . "$1"
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
KIND=$1
INPUT=$2
MILESTONE=
TARGET=
ROUTE_INPUT=$INPUT

case "$KIND" in
  report)
    TARGET=$(report_source "$INPUT") || fail "no Markdown report found for: $INPUT"
    case "${TARGET##*.}" in
      md|MD|markdown|MARKDOWN) ;;
      *) fail "report is not Markdown: $TARGET" ;;
    esac
    MILESTONE=report:$TARGET
    ;;
  decision)
    printf '%s\n' "$INPUT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
      || fail "invalid decision origin id: $INPUT"
    TARGET=$FM_HOME/.lavish/captain-decisions.html
    MILESTONE=decision:$INPUT
    ;;
  reveal)
    [ -e "$INPUT" ] || fail "artifact does not exist: $INPUT"
    TARGET=$(absolute_existing_path "$INPUT") || fail "could not resolve artifact: $INPUT"
    MILESTONE=reveal:$TARGET
    ;;
  *) usage >&2; exit 2 ;;
esac

[ ! -e "$STATE/.afk" ] || print_fallback "$TARGET"
if [ "$KIND" = reveal ]; then
  reveal_gui_available || print_fallback "$TARGET"
else
  gui_available || print_fallback "$TARGET"
fi

case "$KIND" in
  report)
    ARTIFACT_DIGEST=$(sha256_file "$TARGET") || print_fallback "$TARGET"
    ;;
  decision)
    if ! "$DECISION_BIN" generate >/dev/null 2>&1; then
      print_fallback "$TARGET"
    fi
    DECISION_ARTIFACT=$(decision_artifact "$TARGET" "$INPUT" 2>/dev/null) || print_fallback "$TARGET"
    ARTIFACT_DIGEST=$(printf '%s' "$DECISION_ARTIFACT" | sha256_stream) || print_fallback "$TARGET"
    ;;
  reveal)
    if [ -f "$TARGET" ]; then
      ARTIFACT_DIGEST=$(sha256_file "$TARGET") || print_fallback "$TARGET"
    else
      ARTIFACT_DIGEST=$(printf '%s' "$TARGET" | sha256_stream) || print_fallback "$TARGET"
    fi
    ;;
esac

receipt_claim "$MILESTONE" "$ARTIFACT_DIGEST" || print_fallback "$TARGET"
trap receipt_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "$KIND" in
  report)
    "$READ_BIN" "$ROUTE_INPUT" || presentation_failed "$TARGET"
    ;;
  decision)
    "$DECISION_BIN" open --page "$TARGET" || presentation_failed "$TARGET"
    ;;
  reveal)
    if [ -d "$TARGET" ]; then
      "$OPEN_BIN" "$TARGET" >/dev/null 2>&1 || presentation_failed "$TARGET"
    elif "$OPEN_BIN" -R "$TARGET" >/dev/null 2>&1; then
      :
    elif plain_text_file "$TARGET"; then
      "$OPEN_BIN" -t "$TARGET" >/dev/null 2>&1 || presentation_failed "$TARGET"
    else
      presentation_failed "$TARGET"
    fi
    printf '%s\n' "$TARGET"
    ;;
esac

receipt_commit

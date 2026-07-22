#!/usr/bin/env bash
# fm-adhd.sh - bounded ADHD divergent-ideation CLI wrapper for firstmate.
#
# Invokes the third-party `adhd` CLI from the npm package `adhd-agent` with small
# default --frames/--ideas bounds, passes through the decision prompt, and writes
# the distilled CLI output to a caller-named file.
#
# Never sets or requires ANTHROPIC_API_KEY; ADHD rides the Claude subscription.
# See docs/adhd.md for install, uninstall, cost policy, and usage.
#
# Usage:
#   fm-adhd.sh --out <path> [--frames N] [--ideas N] [--top N]
#              [--context PATH] [--json] [--quiet] [--] <decision>
#   fm-adhd.sh -h|--help
#
# Defaults (bounded): --frames 3 --ideas 4 --top 2
#
# Exit:
#   0 on success
#   1 on usage or run failure
#   127 when the adhd CLI is absent (prints reversible install instructions)
set -eu

# Bounded firstmate defaults; callers may raise them explicitly.
FM_ADHD_FRAMES_DEFAULT=3
FM_ADHD_IDEAS_DEFAULT=4
FM_ADHD_TOP_DEFAULT=2

usage() {
  cat <<'EOF' >&2
usage: fm-adhd.sh --out <path> [--frames N] [--ideas N] [--top N]
                  [--context PATH] [--json] [--quiet] [--] <decision>

Bounded ADHD divergent-ideation wrapper around the `adhd` CLI (npm: adhd-agent).
Writes distilled CLI output to --out. Never sets or requires ANTHROPIC_API_KEY.
See docs/adhd.md for install, uninstall, and cost policy.
EOF
}

fail() {
  printf 'fm-adhd: %s\n' "$*" >&2
  exit 1
}

refuse_missing_cli() {
  cat <<'EOF' >&2
fm-adhd: adhd CLI not found on PATH.
Install (reversible): npm install -g adhd-agent
Uninstall: npm uninstall -g adhd-agent
See docs/adhd.md for usage and the cost policy.
EOF
  exit 127
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

OUT=
FRAMES=$FM_ADHD_FRAMES_DEFAULT
IDEAS=$FM_ADHD_IDEAS_DEFAULT
TOP=$FM_ADHD_TOP_DEFAULT
CONTEXT=
JSON=false
QUIET=false
DECISION=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --out)
      [ "$#" -ge 2 ] || fail "--out requires a path"
      OUT=$2
      shift 2
      ;;
    --frames)
      [ "$#" -ge 2 ] || fail "--frames requires a positive integer"
      FRAMES=$2
      shift 2
      ;;
    --ideas)
      [ "$#" -ge 2 ] || fail "--ideas requires a positive integer"
      IDEAS=$2
      shift 2
      ;;
    --top)
      [ "$#" -ge 2 ] || fail "--top requires a positive integer"
      TOP=$2
      shift 2
      ;;
    --context)
      [ "$#" -ge 2 ] || fail "--context requires a path"
      CONTEXT=$2
      shift 2
      ;;
    --json)
      JSON=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown flag: $1"
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi
DECISION=$*

[ -n "$OUT" ] || fail "--out <path> is required"
is_positive_int "$FRAMES" || fail "--frames must be a positive integer"
is_positive_int "$IDEAS" || fail "--ideas must be a positive integer"
is_positive_int "$TOP" || fail "--top must be a positive integer"
if [ -n "$CONTEXT" ] && [ ! -f "$CONTEXT" ]; then
  fail "--context file not found: $CONTEXT"
fi
[ -n "$DECISION" ] || fail "decision prompt must not be empty"

ADHD_BIN=${FM_ADHD_BIN:-}
if [ -z "$ADHD_BIN" ]; then
  if ! ADHD_BIN=$(command -v adhd 2>/dev/null); then
    refuse_missing_cli
  fi
elif [ ! -x "$ADHD_BIN" ]; then
  refuse_missing_cli
fi

OUT_DIR=$(dirname "$OUT")
if [ ! -d "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" || fail "cannot create output directory: $OUT_DIR"
fi

ARGS=(--frames "$FRAMES" --ideas "$IDEAS" --top "$TOP")
if [ -n "$CONTEXT" ]; then
  ARGS+=(--context "$CONTEXT")
fi
if [ "$JSON" = true ]; then
  ARGS+=(--json)
fi
if [ "$QUIET" = true ]; then
  ARGS+=(--quiet)
fi

# Never introduce cash API billing: do not set or require ANTHROPIC_API_KEY.
# Unset any ambient key so this wrapper stays on the Claude subscription path.
TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-adhd.XXXXXX")
# shellcheck disable=SC2064
trap 'rm -f "$TMP_OUT"' EXIT

set +e
env -u ANTHROPIC_API_KEY "$ADHD_BIN" "$DECISION" "${ARGS[@]}" >"$TMP_OUT"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  fail "adhd CLI failed with exit $RC"
fi

# Prefer CLI stdout as the distilled artifact; if empty, keep an explicit marker.
if [ -s "$TMP_OUT" ]; then
  mv "$TMP_OUT" "$OUT"
  trap - EXIT
else
  printf 'fm-adhd: adhd CLI produced empty stdout for decision\n' >"$OUT"
fi

printf 'fm-adhd: wrote %s (frames=%s ideas=%s top=%s)\n' "$OUT" "$FRAMES" "$IDEAS" "$TOP" >&2
exit 0

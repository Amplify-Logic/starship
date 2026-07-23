#!/usr/bin/env bash
# fm-second-opinion.sh - bounded rival-model second-opinion wrapper for firstmate.
#
# Invokes a registered reviewer (default: sol via Pi) with a hostile-reviewer
# prompt scaffold, writes the verbatim review to a caller-named file, and refuses
# oversized input, unknown reviewers, and low Codex quota rather than proceeding
# silently.
#
# CRITICAL: the reviewer process MUST run from a neutral working directory
# (mktemp -d). Launching `pi --print` inside the firstmate checkout loads the
# project context and answers as a lock-refused firstmate instead of reviewing.
# See docs/second-opinion.md.
#
# Reviewer registry (data-driven; add rows without changing callers):
#   sol  -> pi --print --model openai-codex/gpt-5.6-sol --thinking xhigh
#   k3   -> kimi --model kimi-code/k3 --prompt <hostile-review-prompt>
# Only `sol` and `k3` are verified. Unknown names refuse loudly.
#
# Never sets or requires ANTHROPIC_API_KEY or OPENAI_API_KEY; strips ambient ones
# so the Pi -> Codex/OpenAI subscription path stays in force.
#
# Usage:
#   fm-second-opinion.sh --out <path> [--context <file>]... [--reviewer <name>]
#                        [--] <decision-or-design text>
#   fm-second-opinion.sh -h|--help
#
# Defaults: --reviewer sol
# Prompt size bound: FM_SECOND_OPINION_MAX_PROMPT_BYTES (default 100000)
# Quota floor: refuse when Codex general-window percentRemaining is below 10
#   unless FM_SECOND_OPINION_FORCE=1. Missing/unparseable quota tooling warns
#   and proceeds.
#
# Exit:
#   0 on success
#   1 on usage, quota floor, empty/refused reviewer output, or run failure
#   127 when the reviewer binary is absent
#   otherwise propagates the reviewer process exit code
set -eu

FM_SECOND_OPINION_MAX_PROMPT_BYTES=${FM_SECOND_OPINION_MAX_PROMPT_BYTES:-100000}
FM_SECOND_OPINION_QUOTA_FLOOR=${FM_SECOND_OPINION_QUOTA_FLOOR:-10}

usage() {
  cat <<'EOF' >&2
usage: fm-second-opinion.sh --out <path> [--context <file>]... [--reviewer <name>]
                            [--] <decision-or-design text>

Bounded rival-model second-opinion wrapper. Default reviewer is sol (Pi +
openai-codex/gpt-5.6-sol at thinking xhigh). Writes the reviewer's verbatim
output to --out with a small header. Never sets or requires API keys.
See docs/second-opinion.md for cost policy, the neutral-cwd rule, and the
reviewer registry.
EOF
}

fail() {
  printf 'fm-second-opinion: %s\n' "$*" >&2
  exit 1
}

refuse_missing_cli() {
  local name=$1
  cat <<EOF >&2
fm-second-opinion: reviewer binary not found on PATH: ${name}
Install or restore the reviewer CLI (Pi for sol, kimi for k3), then retry.
See docs/second-opinion.md.
EOF
  exit 127
}

# Resolve a registry name into REVIEWER_LABEL, REVIEWER_BIN_NAME, and
# REVIEWER_ARGS (bash array of argv after the binary). Add verified reviewers
# here only; callers stay unchanged.
resolve_reviewer() {
  case "$1" in
    sol)
      REVIEWER_LABEL='sol'
      REVIEWER_BIN_NAME=pi
      REVIEWER_ARGS=(--print --model openai-codex/gpt-5.6-sol --thinking xhigh)
      ;;
    k3)
      # Kimi Code K3 via non-interactive --prompt (PROMPT is the next argv after
      # --prompt). Must run from a neutral cwd like sol - never the proposal repo.
      REVIEWER_LABEL='k3'
      REVIEWER_BIN_NAME=kimi
      REVIEWER_ARGS=(--model kimi-code/k3 --prompt)
      ;;
    *)
      fail "unknown reviewer: $1 (verified: sol, k3)"
      ;;
  esac
}

# Print Codex general-window percentRemaining (min of five_hour/weekly), or
# "na" when tooling is absent or unparseable. Never exits non-zero itself.
codex_general_remaining() {
  local quota_cmd quota_json
  if [ -n "${FM_SECOND_OPINION_QUOTA_JSON:-}" ]; then
    if [ ! -f "$FM_SECOND_OPINION_QUOTA_JSON" ]; then
      printf 'na\n'
      return 0
    fi
    quota_json=$(cat "$FM_SECOND_OPINION_QUOTA_JSON" 2>/dev/null) || {
      printf 'na\n'
      return 0
    }
  else
    quota_cmd=${FM_SECOND_OPINION_QUOTA_AXI:-quota-axi}
    if ! command -v "$quota_cmd" >/dev/null 2>&1; then
      printf 'na\n'
      return 0
    fi
    quota_json=$("$quota_cmd" --json 2>/dev/null) || {
      printf 'na\n'
      return 0
    }
  fi
  printf '%s\n' "$quota_json" | jq -r '
    ([.providers[]? | select(.provider == "codex") | .windows[]? as $window
      | select((["five_hour","weekly"] | index($window.id)) != null
        and (($window.kind? // "") != "model")
        and (($window.percentRemaining? | type) == "number"))
      | $window.percentRemaining] | if length == 0 then "na" else min end)
  ' 2>/dev/null || printf 'na\n'
}

check_quota_floor() {
  local remaining floor
  # Codex subscription floor applies only to the sol reviewer path.
  [ "$REVIEWER_LABEL" = sol ] || return 0
  floor=$FM_SECOND_OPINION_QUOTA_FLOOR
  remaining=$(codex_general_remaining)
  case "$remaining" in
    na|'')
      printf 'fm-second-opinion: quota advisory: Codex general-window reading unavailable; proceeding\n' >&2
      return 0
      ;;
  esac
  printf 'fm-second-opinion: quota advisory: Codex general-window percentRemaining=%s (floor=%s)\n' \
    "$remaining" "$floor" >&2
  if awk -v r="$remaining" -v f="$floor" 'BEGIN { exit ((r + 0 < f + 0) ? 0 : 1) }'; then
    if [ "${FM_SECOND_OPINION_FORCE:-}" = 1 ]; then
      printf 'fm-second-opinion: quota below floor but FM_SECOND_OPINION_FORCE=1; proceeding\n' >&2
      return 0
    fi
    fail "Codex general-window percentRemaining ${remaining} is below floor ${floor}; set FM_SECOND_OPINION_FORCE=1 to override"
  fi
}

byte_count() {
  # Portable byte length without relying on GNU wc -c quirks on empty input.
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

OUT=
REVIEWER=sol
CONTEXT_FILES=()
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
    --context)
      [ "$#" -ge 2 ] || fail "--context requires a path"
      CONTEXT_FILES+=("$2")
      shift 2
      ;;
    --reviewer)
      [ "$#" -ge 2 ] || fail "--reviewer requires a name"
      REVIEWER=$2
      shift 2
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
[ -n "$DECISION" ] || fail "decision-or-design text must not be empty"
[ -n "$REVIEWER" ] || fail "--reviewer must not be empty"

resolve_reviewer "$REVIEWER"

ctx=
for f in "${CONTEXT_FILES[@]+"${CONTEXT_FILES[@]}"}"; do
  [ -f "$f" ] || fail "--context file not found: $f"
  ctx+="$(printf '\n\n## Context: %s\n\n%s' "$f" "$(cat "$f")")"
done

PROMPT=$(cat <<EOF
You are a hostile design reviewer. Try to break the proposal below.
Rank findings by severity (CRITICAL / HIGH / MEDIUM / LOW).
Be concrete: name failure modes, missing invariants, attack paths, and what must change.
Do not rubber-stamp. If something is sound, say so briefly after the findings.

## Subject

${DECISION}${ctx}
EOF
)

PROMPT_BYTES=$(byte_count "$PROMPT")
if awk -v n="$PROMPT_BYTES" -v max="$FM_SECOND_OPINION_MAX_PROMPT_BYTES" \
  'BEGIN { exit ((n + 0 > max + 0) ? 0 : 1) }'; then
  fail "prompt is ${PROMPT_BYTES} bytes; exceeds bound ${FM_SECOND_OPINION_MAX_PROMPT_BYTES} (refuse rather than truncate)"
fi

REVIEWER_BIN=${FM_SECOND_OPINION_BIN:-}
if [ -z "$REVIEWER_BIN" ]; then
  if ! REVIEWER_BIN=$(command -v "$REVIEWER_BIN_NAME" 2>/dev/null); then
    refuse_missing_cli "$REVIEWER_BIN_NAME"
  fi
elif [ ! -x "$REVIEWER_BIN" ]; then
  refuse_missing_cli "$REVIEWER_BIN_NAME"
fi

check_quota_floor

OUT_DIR=$(dirname "$OUT")
if [ ! -d "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" || fail "cannot create output directory: $OUT_DIR"
fi

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-second-opinion.XXXXXX")
NEUTRAL_CWD=$(mktemp -d "${TMPDIR:-/tmp}/fm-second-opinion-cwd.XXXXXX")
# shellcheck disable=SC2064
trap 'rm -f "$TMP_OUT"; rm -rf "$NEUTRAL_CWD"' EXIT

# Never introduce cash API billing: do not set or require API keys.
# Unset ambient keys so this wrapper stays on the Pi -> Codex/OpenAI path.
# CRITICAL: run from NEUTRAL_CWD so Pi does not load the firstmate project context.
set +e
(
  cd "$NEUTRAL_CWD" || exit 1
  # Record cwd for hermetic tests that assert neutrality.
  if [ -n "${FM_SECOND_OPINION_CWD_LOG:-}" ]; then
    pwd -P >"$FM_SECOND_OPINION_CWD_LOG"
  fi
  env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
    "$REVIEWER_BIN" "${REVIEWER_ARGS[@]}" "$PROMPT"
) >"$TMP_OUT" 2>"${TMP_OUT}.err"
RC=$?
set -e

if [ -s "${TMP_OUT}.err" ]; then
  cat "${TMP_OUT}.err" >&2
fi
rm -f "${TMP_OUT}.err"

if [ "$RC" -ne 0 ]; then
  printf 'fm-second-opinion: reviewer process failed with exit %s\n' "$RC" >&2
  exit "$RC"
fi

if [ ! -s "$TMP_OUT" ]; then
  fail "reviewer produced empty output (loud failure; --out not written)"
fi

SUBJECT_LINE=$(printf '%s\n' "$DECISION" | head -n 1 | cut -c1-120)
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
  printf '# Second-opinion review\n\n'
  printf 'Date: %s\n' "$DATE_UTC"
  printf 'Reviewer: %s\n' "$REVIEWER_LABEL"
  printf 'Subject: %s\n\n' "$SUBJECT_LINE"
  cat "$TMP_OUT"
  printf '\n'
} >"$OUT"
trap 'rm -rf "$NEUTRAL_CWD"' EXIT
rm -f "$TMP_OUT"

printf 'fm-second-opinion: wrote %s (reviewer=%s)\n' "$OUT" "$REVIEWER_LABEL" >&2
exit 0

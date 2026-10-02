#!/usr/bin/env bash
# fm-second-opinion.sh - bounded rival-model second-opinion wrapper for firstmate.
#
# Invokes a registered reviewer (default: fable via Claude Code) with a
# hostile-reviewer prompt scaffold, writes the verbatim review to a caller-named
# file, and refuses oversized input, unknown reviewers, and a reviewer pool below
# its quota floor rather than proceeding silently.
#
# CRITICAL: the reviewer process MUST run from a neutral working directory
# (mktemp -d). Launching a reviewer CLI inside the firstmate checkout loads the
# project context and answers as a lock-refused firstmate instead of reviewing.
# See docs/second-opinion.md.
#
# Reviewer registry (data-driven; add rows without changing callers):
#   fable -> claude -p --model claude-fable-5-1 --effort medium
#              --strict-mcp-config --no-session-persistence <prompt>
#   grok  -> cursor-agent -p --model grok-4.7-xhigh --mode ask --trust <prompt>
#   sol   -> pi --print --model openai-codex/gpt-5.6-sol --thinking xhigh <prompt>
#   k3    -> kimi --model kimi-code/k3 --prompt <prompt>
# Unknown names refuse loudly. `sol` stays available but is no longer the
# default; it stops working when the Codex subscription lapses.
#
# Never sets or requires ANTHROPIC_API_KEY or OPENAI_API_KEY; strips ambient ones
# so every reviewer stays on its subscription path (Claude plan, Cursor plan,
# Codex plan) rather than cash API billing.
#
# Usage:
#   fm-second-opinion.sh --out <path> [--context <file>]... [--reviewer <name>]
#                        [--] <decision-or-design text>
#   fm-second-opinion.sh -h|--help
#
# Defaults: --reviewer fable
# Prompt size bound: FM_SECOND_OPINION_MAX_PROMPT_BYTES (default 100000)
# Quota floor: refuse when the reviewer's pool percentRemaining (read from
#   quota-axi --json) is below FM_SECOND_OPINION_QUOTA_FLOOR (default 10)
#   unless FM_SECOND_OPINION_FORCE=1. Pools per reviewer (lowest window wins):
#     fable -> claude model:fable and seven_day
#     grok  -> cursor all_models effective availability (quota-axi's lowest
#              bounding window: included_usage, auto_usage, api_usage)
#     sol   -> codex five_hour and weekly
#     k3    -> none
#   A reading marked stale counts as unavailable. An unavailable reading warns
#   and proceeds, except for grok, which refuses without
#   FM_SECOND_OPINION_FORCE=1: once Cursor's included pool is empty a run draws
#   the paid API balance, so an unknown reading must not spend it.
#
# Exit:
#   0 on success
#   1 on usage, quota floor, empty/refused reviewer output, or run failure
#   127 when the reviewer binary is absent
#   otherwise propagates the reviewer process exit code
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

FM_SECOND_OPINION_MAX_PROMPT_BYTES=${FM_SECOND_OPINION_MAX_PROMPT_BYTES:-100000}
FM_SECOND_OPINION_QUOTA_FLOOR=${FM_SECOND_OPINION_QUOTA_FLOOR:-10}

usage() {
  cat <<'EOF' >&2
usage: fm-second-opinion.sh --out <path> [--context <file>]... [--reviewer <name>]
                            [--] <decision-or-design text>

Bounded rival-model second-opinion wrapper. Default reviewer is fable (Claude
Code + claude-fable-5-1 at effort medium). Use --reviewer grok (Cursor +
grok-4.7-xhigh) beside it for high-stakes calls. sol (Pi + Codex) and k3
(Kimi) remain available. Writes the reviewer's verbatim output to --out with a
small header. Never sets or requires API keys.
See docs/second-opinion.md for cost policy, quota floors, the neutral-cwd rule,
and the reviewer registry.
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
Install or restore the reviewer CLI (claude for fable, cursor-agent for grok,
pi for sol, kimi for k3), then retry.
See docs/second-opinion.md.
EOF
  exit 127
}

# Resolve a registry name into REVIEWER_LABEL, REVIEWER_BIN_NAME, REVIEWER_ARGS
# (bash array of argv after the binary; the prompt is appended as the final
# argv), and the quota pool: QUOTA_PROVIDER and either QUOTA_WINDOWS
# (space-separated quota-axi window ids, lowest percentRemaining wins) or
# QUOTA_SCOPE (a quotaSemantics.effectiveAvailability scope whose known
# effectivePercentRemaining is read), QUOTA_POOL (human label), and
# QUOTA_UNAVAILABLE (proceed|refuse). No QUOTA_PROVIDER means no floor. Add
# verified reviewers here only; callers stay unchanged.
resolve_reviewer() {
  QUOTA_PROVIDER=
  QUOTA_WINDOWS=
  QUOTA_SCOPE=
  QUOTA_POOL=
  QUOTA_UNAVAILABLE=proceed
  case "$1" in
    fable)
      # Claude Code print mode on the Claude subscription. Strict MCP config with
      # no --mcp-config loads no MCP servers, so user servers cannot leak live
      # state into the review; no session persistence keeps throwaway neutral
      # cwds out of the session history. Avoid variadic flags here: they would
      # swallow the trailing prompt argv.
      REVIEWER_LABEL='fable'
      REVIEWER_BIN_NAME=claude
      REVIEWER_ARGS=(-p --model claude-fable-5-1 --effort medium
        --strict-mcp-config --no-session-persistence)
      QUOTA_PROVIDER=claude
      QUOTA_WINDOWS='model:fable seven_day'
      QUOTA_POOL='Claude Fable week'
      ;;
    grok)
      # Cursor agent print mode, read-only ask mode, on Cursor's included pool.
      # The floor reads quota-axi's all-model effective availability, which is
      # the lowest of every window bounding a non-Auto run, so an empty sub-pool
      # refuses even while the combined included pool still reads high.
      REVIEWER_LABEL='grok'
      REVIEWER_BIN_NAME=cursor-agent
      REVIEWER_ARGS=(-p --model grok-4.7-xhigh --mode ask --trust)
      QUOTA_PROVIDER=cursor
      QUOTA_SCOPE='all_models'
      QUOTA_POOL='Cursor all-model availability (lowest of included, auto and API usage)'
      QUOTA_UNAVAILABLE=refuse
      ;;
    sol)
      REVIEWER_LABEL='sol'
      REVIEWER_BIN_NAME=pi
      REVIEWER_ARGS=(--print --model openai-codex/gpt-5.6-sol --thinking xhigh)
      QUOTA_PROVIDER=codex
      QUOTA_WINDOWS='five_hour weekly'
      QUOTA_POOL='Codex general-window'
      ;;
    k3)
      # Kimi Code K3 via non-interactive --prompt (PROMPT is the next argv after
      # --prompt). Must run from a neutral cwd like the others - never the
      # proposal repo.
      REVIEWER_LABEL='k3'
      REVIEWER_BIN_NAME=kimi
      REVIEWER_ARGS=(--model kimi-code/k3 --prompt)
      ;;
    *)
      fail "unknown reviewer: $1 (verified: fable, grok, sol, k3)"
      ;;
  esac
}

# Print the lowest percentRemaining across QUOTA_WINDOWS, or the lowest known
# effectivePercentRemaining for QUOTA_SCOPE, for QUOTA_PROVIDER; or "na" when
# tooling is absent or unparseable, any matching provider row is stale, or
# nothing listed reports a number. Model-kind windows count only under their own
# model:<name> id, so a per-model window can never stand in for a general one.
# Never exits non-zero.
pool_remaining() {
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
  printf '%s\n' "$quota_json" | jq -r --arg provider "$QUOTA_PROVIDER" \
    --arg ids "$QUOTA_WINDOWS" --arg scope "$QUOTA_SCOPE" '
    ($ids | split(" ") | map(select(length > 0))) as $wanted
    | [.providers[]? | select(.provider == $provider)] as $rows
    | if any($rows[]; .state.stale? == true) then "na"
      elif $scope != "" then
        ([$rows[] | .quotaSemantics.effectiveAvailability[]?
          | select(.scope == $scope and .status == "known"
            and ((.effectivePercentRemaining? | type) == "number"))
          | .effectivePercentRemaining] | if length == 0 then "na" else min end)
      else
        ([$rows[] | .windows[]? as $window
          | select(($wanted | index($window.id)) != null
            and ((($window.kind? // "") != "model")
              or (($window.id | tostring) | startswith("model:")))
            and (($window.percentRemaining? | type) == "number"))
          | $window.percentRemaining] | if length == 0 then "na" else min end)
      end
  ' 2>/dev/null || printf 'na\n'
}

check_quota_floor() {
  local remaining floor
  [ -n "$QUOTA_PROVIDER" ] || return 0
  floor=$FM_SECOND_OPINION_QUOTA_FLOOR
  remaining=$(pool_remaining)
  case "$remaining" in
    na|'')
      if [ "$QUOTA_UNAVAILABLE" = refuse ]; then
        if [ "${FM_SECOND_OPINION_FORCE:-}" = 1 ]; then
          printf 'fm-second-opinion: quota advisory: %s reading unavailable but FM_SECOND_OPINION_FORCE=1; proceeding\n' \
            "$QUOTA_POOL" >&2
          return 0
        fi
        fail "${QUOTA_POOL} reading unavailable; ${REVIEWER_LABEL} could draw paid usage, so refusing; set FM_SECOND_OPINION_FORCE=1 to override"
      fi
      printf 'fm-second-opinion: quota advisory: %s reading unavailable; proceeding\n' "$QUOTA_POOL" >&2
      return 0
      ;;
  esac
  printf 'fm-second-opinion: quota advisory: %s percentRemaining=%s (floor=%s)\n' \
    "$QUOTA_POOL" "$remaining" "$floor" >&2
  if awk -v r="$remaining" -v f="$floor" 'BEGIN { exit ((r + 0 < f + 0) ? 0 : 1) }'; then
    if [ "${FM_SECOND_OPINION_FORCE:-}" = 1 ]; then
      printf 'fm-second-opinion: quota below floor but FM_SECOND_OPINION_FORCE=1; proceeding\n' >&2
      return 0
    fi
    fail "${QUOTA_POOL} percentRemaining ${remaining} is below floor ${floor}; set FM_SECOND_OPINION_FORCE=1 to override"
  fi
}

byte_count() {
  # Portable byte length without relying on GNU wc -c quirks on empty input.
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

OUT=
REVIEWER=fable
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
Check threading, concurrency, timeouts, retries and idempotency explicitly: what happens if two calls overlap, a call times out but the work continues, or a step is retried.
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
  if [ "$REVIEWER_BIN_NAME" = cursor-agent ]; then
    REVIEWER_BIN=$(fm_cursor_resolve_binary) || refuse_missing_cli "$REVIEWER_BIN_NAME"
  elif ! REVIEWER_BIN=$(command -v "$REVIEWER_BIN_NAME" 2>/dev/null); then
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
# Unset ambient keys so every reviewer stays on its subscription path.
# CRITICAL: run from NEUTRAL_CWD so the reviewer does not load the firstmate
# project context.
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

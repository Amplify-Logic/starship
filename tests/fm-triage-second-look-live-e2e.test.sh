#!/usr/bin/env bash
# Live smoke for the opt-in second look, against the real TypeSafe (Jev) API.
#
# tests/fm-triage-second-look.test.sh pins the request shape, the thresholds and
# every fail-open path against a recorded response, so it catches a change on
# THIS side. It cannot catch a change on the vendor's: a pinned model that stops
# answering, an answer shape that moves, a question the model reads differently
# after an upgrade. Only a real call does, and this guard is what refreshes the
# dated evidence in docs/verification/triage-second-look.md.
#
# It spends real money. One batched request over four fixture lines is a fraction
# of a cent (~516 input tokens per line at $42/Btok), so the guard is opt-in and
# skips by default:
#   FM_TRIAGE_SECOND_LOOK_LIVE_E2E=1 bash tests/fm-triage-second-look-live-e2e.test.sh
# The key comes from TYPESAFE_API_KEY, from FM_TRIAGE_SECOND_LOOK_ENV_FILE, or
# from a .env at the repository root, and is never printed by this script or by
# anything it calls. With none of those the guard fails rather than passing
# vacuously, because a requested live guard that checked nothing is worse than no
# guard at all.
#
# The assertions are deliberately about the CONTRACT, not about exact
# probabilities: a model answers a shade differently run to run, and pinning a
# number here would make this guard flap. What must hold is that the pinned model
# answers at all, in the documented shape, and that the two ends of the
# fixture set still land on opposite sides of the rule.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_TRIAGE_SECOND_LOOK_LIVE_E2E python3

TOOL="$ROOT/bin/fm-triage-second-look.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-triage-second-look-live.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data/live"
printf 'enabled = true\n' > "$HOME_DIR/config/triage-second-look"
printf 'kind=ship\n' > "$HOME_DIR/state/live.meta"
printf "# Task\n## Captain's intent\nAdd a users.last_seen column and backfill it.\n" \
  > "$HOME_DIR/data/live/brief.md"
printf 'working: writing the backfill migration\n' > "$HOME_DIR/state/live.status"

# The key comes from the operator, not from a fixture. tests/lib.sh points
# FM_HOME at a hermetic temp home, so the tool's own "read this home's .env"
# fallback can never find a real key here; name the file explicitly instead.
if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -z "${FM_TRIAGE_SECOND_LOOK_ENV_FILE:-}" ]; then
  if [ -f "$ROOT/.env" ]; then
    export FM_TRIAGE_SECOND_LOOK_ENV_FILE="$ROOT/.env"
  else
    printf 'not ok - %s was requested but no key is available; set TYPESAFE_API_KEY or FM_TRIAGE_SECOND_LOOK_ENV_FILE\n' \
      FM_TRIAGE_SECOND_LOOK_LIVE_E2E >&2
    exit 1
  fi
fi

records="$LAB/records"
# shellcheck disable=SC2016  # the dollar amounts are fixture text, not expansions
{
  # Two that must promote, at opposite ends of the rule: destroyed data, and a
  # spend the captain owns.
  printf 'live\tworking: the backfill migration truncated public.users on staging before I caught it; 4100 rows gone\n'
  printf 'live\tworking: the only queue tier that handles our burst is the $400/month plan, signing up needs a card\n'
  # Two that must stay silent: ordinary progress, and a cost mentioned as a
  # finding rather than as a request to spend.
  printf 'live\tworking: rebased onto main and reran the suite, all green\n'
  printf 'live\tworking: the nightly job costs about $12/month on this tier, well inside the existing plan\n'
} > "$records"

out="$LAB/out"
err="$LAB/err"
status=0
FM_HOME="$HOME_DIR" "$TOOL" < "$records" > "$out" 2> "$err" || status=$?

if [ "$status" -ne 0 ]; then
  printf 'not ok - the live second look did not complete (exit %s): %s\n' \
    "$status" "$(cat "$err")" >&2
  exit 1
fi

# The key must not have leaked into either stream, whatever happened.
if [ -n "${TYPESAFE_API_KEY:-}" ] && grep -qF "$TYPESAFE_API_KEY" "$out" "$err" 2>/dev/null; then
  printf 'not ok - the API key appeared in the live output\n' >&2
  exit 1
fi

promoted=$(cut -f4 < "$out")

grep -qF 'truncated public.users' <<<"$promoted" \
  || { printf 'not ok - the live call did not promote a line reporting destroyed data: %s\n' \
        "$(cat "$out")" >&2; exit 1; }
# shellcheck disable=SC2016  # the dollar amount is fixture text, not an expansion
grep -qF '$400/month plan' <<<"$promoted" \
  || { printf 'not ok - the live call did not promote a spend the captain owns: %s\n' \
        "$(cat "$out")" >&2; exit 1; }
grep -qF 'all green' <<<"$promoted" \
  && { printf 'not ok - the live call promoted ordinary progress: %s\n' "$(cat "$out")" >&2; exit 1; }
grep -qF 'well inside the existing plan' <<<"$promoted" \
  && { printf 'not ok - the live call promoted a cost mentioned as a finding: %s\n' \
        "$(cat "$out")" >&2; exit 1; }

# Every promotion must carry a tier and a reason the caller can put in a digest.
while IFS=$(printf '\t') read -r task tier reason line; do
  [ -n "$task" ] || continue
  case "$tier" in
    alert|digest) ;;
    *) printf 'not ok - live promotion carried an unknown tier: %s\n' "$tier" >&2; exit 1 ;;
  esac
  case "$reason" in
    *needs_captain*|*adverse_event*|*understated_terminal*) ;;
    *) printf 'not ok - live promotion carried an unrecognised reason: %s\n' "$reason" >&2; exit 1 ;;
  esac
  [ -n "$line" ] || { printf 'not ok - live promotion carried no line\n' >&2; exit 1; }
done < "$out"

printf 'ok - the pinned model answers live and still separates the two ends of the fixture set\n'

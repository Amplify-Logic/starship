#!/usr/bin/env bash
# Behavior tests for the opt-in continuous channel intake gate and its schedule.
#
# Contracts under test:
#   - A home with no `enabled = true` line is completely inert, so cloning the
#     repo or seeding another home never enrolls a device.
#   - A new ask appears exactly once: the first observation opens an item and an
#     unchanged re-read produces no second item and no second notification.
#   - An edit updates the SAME item rather than creating a second one, and
#     re-notifies exactly once.
#   - A captain response clears the item, archiving it with its evidence, and a
#     later re-read of a resolved ask never reopens it.
#   - An interrupted or failed read loses no data: the checkpoint advances only
#     behind a completed read, so the next tick re-reads the same window.
#   - A gap while the laptop slept is caught up from the checkpoint rather than
#     skipped, and the interval is a target rather than an upper bound.
#   - An unavailable source reads `unknown`, never "nothing new".
#   - An optional scanning window bounds the reads themselves: outside it no
#     source is due, so nothing reads and nothing wakes, while the first tick
#     after the window opens reads at once instead of waiting for a boundary.
#   - No poll loop can run away: the interval has a hard floor, a failing source
#     backs off geometrically to a ceiling, and one armed cycle produces one wake.
#   - A cross-source duplicate keeps every source's provenance and stays ONE
#     item instead of becoming a second task.
#   - Notifications are grouped, rate-limited, capped per local day, and refused
#     outright until the recipient is verified against the known captain, and a
#     refusal or a cap reads as itself instead of looking like a quiet home.
#   - A quiet cycle succeeds: once every source has been read, the scheduled
#     tick, a claim and the watcher check all exit clean rather than failing.
#   - The live watcher check wakes once per state and re-arms when the state
#     recurs, instead of going permanently silent after its first wake.
#   - Due sources and held alerts are suppressed independently, so an alert the
#     gate refuses or holds is reported once instead of re-waking the primary
#     every time the due set empties and refills under it.
#   - The alert half is identified by which items are notifiable, so a cleared
#     ask replaced by a different one still wakes the primary.
#   - Only a captain-requested `--open` render opens the written page; a
#     background or scheduled render never takes focus, and an opener that is
#     missing or fails is reported without failing the render.
#   - A re-read never erases why an item is waiting on someone else.
#   - Quiet hours defer the notifiable classes but preserve real severity: a
#     service outage still goes out.
#   - A post-resolution edit is news exactly once: the same edited message
#     re-read on every later poll re-announces nothing and re-logs nothing,
#     while a genuinely later edit is reported once more and never reopens.
#   - Per-poll work stays bounded: the tracked thread set retires dormant
#     parents, and routine traffic past the brief horizon leaves the polled set
#     by moving aside with its record intact rather than being deleted.
#   - The gate writes nothing the Action Deck renders, so detection can never
#     manufacture an executable card.
#   - The brief and the to-do list render from one ledger, so a correction and a
#     completion reconcile across both by construction.
#   - Writes to the durable ledger are serialized, so a watcher sweep cannot
#     overwrite an orchestrator's observation.
#   - Arming the watcher check is all-or-nothing, and losing that shim is
#     reported by the read-only session-start surface.
#   - No existing fleet is overridden: no session lock is taken, no watcher is
#     started, and a foreign home's records are untouched.
#   - Local configuration stays private: unknown keys are refused rather than
#     parked, and status prints only declared knobs.
#   - Install and uninstall work against a temporary home and a fake launchd
#     transport, and refuse a home that never opted in.
#   - A team announcement is information, not an ask: only an announcement
#     source accepts it, it is never notified or put on the to-do list, it
#     shows in the brief, and it leaves the polled set only after its own
#     longer horizon.
#   - Slack DM, calendar and Asana sources each get their own read on a claim,
#     the Asana full re-list once per local day.
#   - Observe refuses a title-less new item, keeps a partner mark across
#     re-reads, and a wait needs a date unless it states a hand-over to someone
#     named other than the captain.
#   - Session-start bootstrap surfaces the intake through the built-in hook.
#   - A home whose add-on still carries the intake runs the add-on's copy: its
#     same-named bootstrap hooks replace the built-in ones and run its own
#     scripts, a live check it armed keeps naming its own script, and its
#     same-named skills are linked in place of the opt-in ones.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-channel-intake.sh"
SCHEDULE="$ROOT/bin/fm-channel-intake-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-channel-intake-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600   # 09:00 local
T_0915=1789024500   # 09:15 local - one interval later
T_2300=1789074000   # 23:00 local - inside the configured quiet hours
T_NEXT_0900=1789110000  # 2026-09-11 09:00 local
T_1015=1789028100   # 10:15 local - a laptop opened partway into a 09:00 window
T_1700=1789052400   # 17:00 local - after a 16:30 scanning window closes

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/reports" "$h/data/channel-intake"
  cat >"$h/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
stale_after_seconds = 5400
backoff_seconds = 900
backoff_max_seconds = 3600
quiet_start = 22:00
quiet_end = 07:00
notify_min_interval_seconds = 1800
notify_max_per_day = 8
notify_recipient = U_CAPTAIN
notify_recipient_verified = true
report_dir = $h/reports
EOF
  # The private inventory: the ONLY place a source identity lives, and the
  # explicit coverage statement. Two sources, deliberately not "the workspace".
  printf 'C_BRIEF\tslack-channel\tdaily brief channel, top-level messages\n' \
    >"$h/data/channel-intake/sources.tsv"
  printf 'M_ACTION\tgmail\tmail carrying the action label only\n' \
    >>"$h/data/channel-intake/sources.tsv"
}

# Every invocation pins the clock instead of sleeping or suspending anything.
at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"
}

queue_lines() {
  grep -c '[^[:space:]]' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'
}

# The item key is content-addressed, so tests read it back rather than guess it.
key_of() {
  printf '%s' "$1" | awk '{ print $2 }'
}

item_field() {
  local h=$1 key=$2 field=$3 f
  for f in "$h/data/channel-intake/items/$key" "$h/data/channel-intake/archive/$key"; do
    [ -f "$f" ] || continue
    awk -F= -v k="$field" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$f"
    return 0
  done
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

# A live process holding the gate's own state mutex, so contention is real
# rather than simulated. Nothing is slept for: the contended command is bounded
# by FM_CHANNEL_INTAKE_LOCK_WAIT and returns inside it.
HOLDER_PID=
hold_state_lock() {
  local h=$1 lock
  lock="$h/data/channel-intake/state.lock"
  mkdir -p "$lock"
  sleep 10 &
  HOLDER_PID=$!
  disown "$HOLDER_PID" 2>/dev/null || true
  printf '%s\n' "$HOLDER_PID" >"$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$HOLDER_PID" >"$lock/pid-identity" 2>/dev/null ) || true
}

release_state_lock() {
  local h=$1
  [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  rm -rf "$h/data/channel-intake/state.lock"
}

test_inert_without_opt_in() {
  local h out code
  h="$TMP_ROOT/no-optin"
  mkdir -p "$h/config" "$h/state"

  out=$(at "$h" "$T_0900" tick) && code=0 || code=$?
  expect_code 0 "$code" 'tick on a home with no config'
  [ -z "$out" ] || fail "un-enrolled home produced output: $out"
  assert_absent "$h/data/channel-intake/items" 'un-enrolled home wrote a ledger'
  assert_absent "$h/state/.wake-queue" 'un-enrolled home enqueued a wake'

  printf 'enabled = false\n' >"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" tick)
  [ -z "$out" ] || fail "disabled home produced output: $out"
  out=$(at "$h" "$T_0900" pending)
  [ -z "$out" ] || fail "disabled home surfaced a bootstrap line: $out"
  out=$(at "$h" "$T_0900" check)
  [ -z "$out" ] || fail "disabled home woke the watcher: $out"

  pass 'a home without an explicit opt-in is completely inert, so no clone or device self-enrolls'
}

test_new_ask_appears_once_and_unchanged_polls_are_silent() {
  local h out key
  h="$TMP_ROOT/appears-once"
  new_home "$h"

  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'can you approve the invoice' --class urgent \
    --title 'invoice approval asked of the captain' --source-epoch 1789023000)
  case "$out" in new\ *) ;; *) fail "first observation was not new: $out" ;; esac
  key=$(key_of "$out")

  # The same message read again by the next tick. Same content, so nothing about
  # the item's attention state may move and no second item may exist.
  out=$(at "$h" "$T_0915" observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'can you approve the invoice' --class urgent \
    --title 'invoice approval asked of the captain')
  assert_contains "$out" "unchanged $key" 'an unchanged re-read did not report unchanged'
  [ "$(at "$h" "$T_0915" items | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'an unchanged re-read created a second item'

  # One notification, then silence while nothing changes.
  out=$(at "$h" "$T_0915" notify-due)
  assert_contains "$out" 'items: 1' 'the new ask did not become one notification'
  assert_contains "$out" 'recipient: U_CAPTAIN' 'the payload did not name the verified recipient'
  at "$h" "$T_0915" notify-sent --keys "$key" >/dev/null
  out=$(at "$h" $((T_0915 + 3600)) notify-due)
  [ -z "$out" ] || fail "an unchanged item was notified a second time: $out"

  pass 'a new ask appears once and an unchanged poll produces neither a second item nor a repeat ping'
}

test_edit_updates_the_same_item() {
  local h out key second
  h="$TMP_ROOT/edit"
  new_home "$h"

  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'ship it on Thursday' --class deadline --title 'ship on Thursday')
  key=$(key_of "$out")
  at "$h" "$T_0900" notify-sent --keys "$key" >/dev/null

  # An in-place edit keeps the source id, so the gate recognises it by content.
  out=$(at "$h" "$T_0915" observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'ship it on Friday, not Thursday' --class deadline \
    --title 'ship on Friday (corrected)')
  assert_contains "$out" "updated $key" 'an edit did not update the same item'
  second=$(at "$h" "$T_0915" items | grep -c '[^[:space:]]')
  [ "$second" = 1 ] || fail "an edit created a second item ($second items)"
  [ "$(item_field "$h" "$key" revisions)" = 1 ] || fail 'the correction was not counted'
  [ "$(item_field "$h" "$key" title)" = 'ship on Friday (corrected)' ] \
    || fail 'the corrected title did not replace the original'
  [ "$(item_field "$h" "$key" created)" = "$T_0900" ] \
    || fail 'an edit reset the first-seen time'

  # Content changed since the notification that went out, so it re-notifies -
  # once.
  out=$(at "$h" $((T_0915 + 3600)) notify-due)
  assert_contains "$out" 'items: 1' 'a corrected item did not re-notify'
  assert_contains "$out" 'corrected' 'the re-notification carried the stale title'

  # The brief reports the correction rather than silently swapping the text.
  out=$(at "$h" "$T_0915" brief)
  assert_contains "$out" 'was corrected 1 time(s)' 'the brief did not report the correction'

  pass 'an edit updates the same item, re-notifies once, and is reported as a correction'
}

test_captain_response_clears_and_never_reopens() {
  local h out key log
  h="$TMP_ROOT/resolve"
  new_home "$h"

  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'approve the invoice' --class urgent --title 'invoice approval' \
    --link 'https://example.invalid/m/1')
  key=$(key_of "$out")

  out=$(at "$h" "$T_0915" resolve --item "$key" --reason 'captain approved the amount in thread')
  assert_contains "$out" "archived $key" 'the captain response did not clear the item'
  [ "$(at "$h" "$T_0915" items --state open | grep -c '[^[:space:]]')" = 0 ] \
    || fail 'a resolved ask stayed on the active list'

  # Archived, not deleted: the evidence survives.
  assert_present "$h/data/channel-intake/archive/$key" 'the archived item lost its evidence'
  [ "$(item_field "$h" "$key" link)" = 'https://example.invalid/m/1' ] \
    || fail 'the archived item lost its source link'
  [ "$(item_field "$h" "$key" provenance)" = 'C_BRIEF:1789023000.1000' ] \
    || fail 'the archived item lost its provenance'
  [ "$(item_field "$h" "$key" resolution)" = 'captain approved the amount in thread' ] \
    || fail 'the archived item lost the reason it was closed'

  # A reaction or an unchanged re-read of a resolved ask must stay silent.
  out=$(at "$h" $((T_0915 + 900)) observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'approve the invoice')
  assert_contains "$out" "archived-unchanged $key" 'an unchanged re-read reopened a resolved ask'
  # Even a genuine later edit only annotates; reopening is a captain decision.
  out=$(at "$h" $((T_0915 + 1800)) observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'approve the invoice, revised')
  assert_contains "$out" "archived-changed $key" 'a late edit was not reported against the archive'
  [ "$(at "$h" $((T_0915 + 1800)) items --state open | grep -c '[^[:space:]]')" = 0 ] \
    || fail 'a late edit reopened a resolved ask'

  # The annotation is on the archive record itself, so the brief can say the
  # source moved without the obligation coming back.
  [ "$(item_field "$h" "$key" edited_after_resolution)" = "$((T_0915 + 1800))" ] \
    || fail 'a late edit did not annotate the archived record'
  [ "$(item_field "$h" "$key" state)" = archived ] \
    || fail 'annotating a late edit changed the archived state'
  [ "$(item_field "$h" "$key" resolution)" = 'captain approved the amount in thread' ] \
    || fail 'annotating a late edit overwrote the archived evidence'
  out=$(at "$h" $((T_0915 + 1800)) brief)
  assert_contains "$out" 'was edited after it was closed; it stays closed' \
    'the brief never mentioned the post-resolution edit'

  # A post-resolution edit is news exactly ONCE. The poll that first sees it
  # reports it and logs it; every later poll of that same unchanged edited
  # message must report no change and append no second log line, or the
  # orchestrator re-reports "the source moved" on every tick forever and the
  # log grows without bound behind it.
  log="$h/data/channel-intake/log"
  [ "$(grep -c "archived item $key changed after resolution" "$log")" = 1 ] \
    || fail 'the first post-resolution edit was not reported exactly once in the log'
  out=$(at "$h" $((T_0915 + 2700)) observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'approve the invoice, revised')
  assert_contains "$out" "archived-unchanged $key" \
    're-reading the same post-resolution edit re-announced it as a change'
  assert_not_contains "$out" 'archived-changed' \
    're-reading the same post-resolution edit alerted the orchestrator again'
  [ "$(grep -c "archived item $key changed after resolution" "$log")" = 1 ] \
    || fail 'a re-read of the same post-resolution edit appended another log line'
  [ "$(item_field "$h" "$key" edited_after_resolution)" = "$((T_0915 + 1800))" ] \
    || fail 'an unchanged re-read of an edited archive re-annotated it'
  [ "$(grep -c '^edited_after_resolution=' "$h/data/channel-intake/archive/$key")" = 1 ] \
    || fail 'an unchanged re-read grew the archived record'

  # Suppressing the repeat loses none of the evidence the brief renders from.
  [ "$(item_field "$h" "$key" state)" = archived ] \
    || fail 'suppressing a repeat edit changed the archived state'
  [ "$(item_field "$h" "$key" resolution)" = 'captain approved the amount in thread' ] \
    || fail 'suppressing a repeat edit lost the reason the item was closed'
  [ "$(item_field "$h" "$key" link)" = 'https://example.invalid/m/1' ] \
    || fail 'suppressing a repeat edit lost the source link'
  [ "$(item_field "$h" "$key" provenance)" = 'C_BRIEF:1789023000.1000' ] \
    || fail 'suppressing a repeat edit lost the provenance'
  [ "$(item_field "$h" "$key" revisions)" = 0 ] \
    || fail 'suppressing a repeat edit disturbed the revision count'
  out=$(at "$h" $((T_0915 + 2700)) brief)
  assert_contains "$out" 'was edited after it was closed; it stays closed' \
    'suppressing the repeat also dropped the edit from the brief'

  # A genuinely later, DIFFERENT edit is news again - exactly once more - and
  # still never reopens the item.
  out=$(at "$h" $((T_0915 + 3600)) observe --source C_BRIEF --ref 1789023000.1000 \
    --digest 'approve the invoice, revised again')
  assert_contains "$out" "archived-changed $key" \
    'a second, different post-resolution edit was not reported'
  [ "$(grep -c "archived item $key changed after resolution" "$log")" = 2 ] \
    || fail 'a second, different post-resolution edit was not logged once more'
  [ "$(item_field "$h" "$key" edited_after_resolution)" = "$((T_0915 + 3600))" ] \
    || fail 'a second edit did not supersede the archive annotation'
  [ "$(at "$h" $((T_0915 + 3600)) items --state open | grep -c '[^[:space:]]')" = 0 ] \
    || fail 'a second late edit reopened a resolved ask'

  # The edit note is bounded like every other brief row.
  out=$(at "$h" $((T_0915 + 3600 + 86401)) brief)
  case "$out" in
    *'was edited after it was closed'*)
      fail 'a stale post-resolution edit stayed on the brief forever' ;;
  esac

  # Waiting-on-others is the honest middle state, and it is not a clearance.
  out=$(at "$h" "$T_0900" observe --source M_ACTION --ref msg-77 \
    --digest 'supplier must confirm' --class obligation --title 'supplier confirmation')
  key=$(key_of "$out")
  at "$h" "$T_0915" resolve --item "$key" --waiting --reason 'handed to Dan at the supplier' >/dev/null
  out=$(at "$h" "$T_0915" brief)
  assert_contains "$out" 'supplier confirmation' 'a handed-off obligation vanished from the brief'
  [ "$(item_field "$h" "$key" state)" = waiting ] \
    || fail 'a handed-off obligation was cleared rather than moved to waiting'
  # The source keeps being re-read every interval, so a re-observation must not
  # erase why the item is waiting: without the reason the ledger says only that
  # something is stuck, not who it is stuck on.
  at "$h" $((T_0915 + 900)) observe --source M_ACTION --ref msg-77 \
    --digest 'supplier must confirm' --class obligation --title 'supplier confirmation' >/dev/null
  [ "$(item_field "$h" "$key" resolution)" = 'handed to Dan at the supplier' ] \
    || fail 'an unchanged re-read erased the reason a handed-off item is waiting'
  at "$h" $((T_0915 + 1800)) observe --source M_ACTION --ref msg-77 \
    --digest 'supplier must confirm by friday' --class obligation \
    --title 'supplier confirmation' >/dev/null
  [ "$(item_field "$h" "$key" resolution)" = 'handed to Dan at the supplier' ] \
    || fail 'a corrected re-read erased the reason a handed-off item is waiting'
  assert_contains "$(at "$h" $((T_0915 + 1800)) brief)" 'supplier confirmation' \
    'a corrected handed-off obligation left waiting-on-others'

  pass 'a captain response clears the item with its evidence preserved, and no re-read reopens it'
}

test_interrupted_read_retries_without_data_loss() {
  local h out before
  h="$TMP_ROOT/interrupted"
  new_home "$h"

  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint 1789023000.1000 >/dev/null
  before=$(at "$h" "$T_0900" sources | awk -F'\t' '$1 == "C_BRIEF" { print $4 }')
  [ "$before" = 'checkpoint=1789023000.1000' ] || fail "checkpoint not recorded: $before"

  # The next read dies part way through and reports a failure. The checkpoint
  # must not move, so the same window is read again rather than skipped.
  at "$h" "$T_0915" claim --source C_BRIEF >/dev/null
  out=$(at "$h" "$T_0915" fail --source C_BRIEF --reason 'connection reset mid-page')
  assert_contains "$out" 'read failed (1 consecutive)' 'a failed read was not recorded as a failure'
  [ "$(at "$h" "$T_0915" sources | awk -F'\t' '$1 == "C_BRIEF" { print $4 }')" = "$before" ] \
    || fail 'a failed read advanced the checkpoint and lost its window'

  # An unavailable source reads unknown, which is not the same as nothing new.
  assert_contains "$(at "$h" "$T_0915" sources)" 'unknown' \
    'a failed source did not read unknown'
  assert_contains "$(at "$h" "$T_0915" brief)" 'unknown' \
    'the brief did not disclose the unavailable source'
  assert_contains "$(at "$h" "$T_0915" pending)" 'reading unknown' \
    'session start did not surface the unavailable source'

  # The retry, once the backoff clears, resumes from the retained checkpoint.
  out=$(at "$h" $((T_0915 + 1000)) claim --source C_BRIEF)
  assert_contains "$out" 'checkpoint: 1789023000.1000' \
    'the retry did not resume from the retained checkpoint'

  pass 'an interrupted read retries from its own checkpoint, and an unavailable source stays unknown'
}

test_sleep_gap_is_caught_up_from_the_checkpoint() {
  local h out
  h="$TMP_ROOT/sleep"
  new_home "$h"

  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint 1789023000.1000 >/dev/null
  at "$h" "$T_0900" complete --source M_ACTION --checkpoint msg-1 >/dev/null

  # The laptop slept through the rest of the day. No tick ran. The first tick
  # after it wakes must find the sources due and hand back the SAME checkpoints,
  # so the gap is walked forward rather than skipped or re-read from origin.
  out=$(at "$h" "$T_NEXT_0900" tick)
  assert_contains "$out" '2 source(s) due' 'the first tick after a long sleep found nothing due'
  out=$(at "$h" "$T_NEXT_0900" claim)
  assert_contains "$out" 'checkpoint: 1789023000.1000' 'the catch-up lost the channel checkpoint'
  assert_contains "$out" 'checkpoint: msg-1' 'the catch-up lost the mail checkpoint'

  # Freshness is exposed rather than implied: a long gap reads stale, and the
  # brief says the interval is a target and not an upper bound.
  at "$h" "$T_NEXT_0900" complete --source C_BRIEF --checkpoint 1789023000.2000 >/dev/null
  assert_contains "$(at "$h" "$T_NEXT_0900" sources)" 'fresh' 'a completed read did not read fresh'
  assert_contains "$(at "$h" "$T_NEXT_0900" brief)" 'not a guaranteed upper bound' \
    'the brief implied the poll interval bounds detection latency'

  pass 'a gap while the laptop slept is caught up from each checkpoint, and freshness is exposed'
}

test_no_poll_loop_can_run_away() {
  local h out code n backoff_first backoff_second
  h="$TMP_ROOT/bounded"
  new_home "$h"

  # A cadence below the floor is refused rather than accepted, because an awake
  # laptop multiplies it by every enrolled source.
  printf 'enabled = true\ninterval_seconds = 60\n' >"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a sub-floor interval was accepted'
  assert_contains "$out" 'at least 300s' 'the refusal did not name the interval floor'
  new_home "$h"

  # Repeat ticks inside one armed cycle enqueue exactly one wake.
  at "$h" "$T_0900" tick >/dev/null
  [ "$(queue_lines "$h")" = 1 ] || fail 'the first armed cycle did not enqueue exactly one wake'
  at "$h" $((T_0900 + 60)) tick >/dev/null
  at "$h" $((T_0900 + 120)) tick >/dev/null
  [ "$(queue_lines "$h")" = 1 ] || fail 'repeat ticks inside one armed cycle duplicated the wake'

  # A failing source backs off geometrically instead of retrying harder, and the
  # backoff stops at the configured ceiling.
  at "$h" "$T_0900" claim --source C_BRIEF >/dev/null
  out=$(at "$h" "$T_0900" fail --source C_BRIEF --reason 'connector reported retry-after')
  backoff_first=$(printf '%s' "$out" | sed -n 's/.*backing off \([0-9]*\)s.*/\1/p')
  [ "$backoff_first" = 900 ] || fail "first backoff was not the configured value: $backoff_first"
  out=$(at "$h" $((T_0900 + 1000)) fail --source C_BRIEF --reason 'still throttled')
  backoff_second=$(printf '%s' "$out" | sed -n 's/.*backing off \([0-9]*\)s.*/\1/p')
  [ "$backoff_second" = 1800 ] || fail "the backoff did not grow: $backoff_second"
  n=0
  while [ "$n" -lt 6 ]; do
    at "$h" $((T_0900 + 100000 + n * 10000)) fail --source C_BRIEF --reason 'still throttled' >/dev/null
    n=$((n + 1))
  done
  out=$(at "$h" $((T_0900 + 900000)) fail --source C_BRIEF --reason 'still throttled')
  assert_contains "$out" 'backing off 3600s' 'the backoff grew past the configured ceiling'

  # A source inside its backoff is not due, so it is not read on every tick.
  out=$(at "$h" $((T_0900 + 900060)) claim)
  assert_not_contains "$out" 'source: C_BRIEF' 'a backed-off source was still claimed'

  # The quiet cycle is the steady state, and it must succeed. A scheduled tick
  # that exits non-zero once every source has been read records a launchd
  # failure on nearly every run and leaves the armed marker behind.
  new_home "$h"
  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint c-1 >/dev/null
  at "$h" "$T_0900" complete --source M_ACTION --checkpoint m-1 >/dev/null
  out=$(at "$h" $((T_0900 + 60)) tick) && code=0 || code=$?
  expect_code 0 "$code" 'a tick with nothing due reported a failure'
  [ -z "$out" ] || fail "a tick with nothing due was not silent: $out"
  out=$(at "$h" $((T_0900 + 60)) claim) && code=0 || code=$?
  expect_code 0 "$code" 'a claim with nothing due reported a failure'
  assert_contains "$out" '<none due>' 'a claim with nothing due did not say so'
  out=$(at "$h" $((T_0900 + 60)) check) && code=0 || code=$?
  expect_code 0 "$code" 'a watcher check with nothing due reported a failure'
  assert_absent "$h/data/channel-intake/armed" 'a quiet cycle left the armed marker set'

  pass 'the interval has a floor, one armed cycle wakes once, a failing source backs off to a ceiling, and a quiet cycle succeeds'
}

test_cross_source_duplicate_stays_one_item() {
  local h out key
  h="$TMP_ROOT/dedup"
  new_home "$h"

  # The same ask arrives in the channel and again by mail. One obligation, two
  # provenances - never two tasks.
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1000 \
    --dedup-key 'invoice-4471' --digest 'approve invoice 4471' --class urgent \
    --title 'approve invoice 4471')
  key=$(key_of "$out")
  out=$(at "$h" "$T_0900" observe --source M_ACTION --ref msg-88 \
    --dedup-key 'invoice-4471' --digest 'approve invoice 4471')
  assert_contains "$out" "merged $key" 'a cross-source duplicate was not merged'
  [ "$(at "$h" "$T_0900" items | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'a cross-source duplicate created a second task'
  case "$(item_field "$h" "$key" provenance)" in
    *C_BRIEF:1789023000.1000*M_ACTION:msg-88*) ;;
    *) fail "the merged item lost a provenance: $(item_field "$h" "$key" provenance)" ;;
  esac

  pass 'a cross-source duplicate retains every provenance and stays one item'
}

test_notifications_are_private_verified_grouped_and_capped() {
  local h out code k1 k2
  h="$TMP_ROOT/notify"
  new_home "$h"

  # Refused outright until the recipient has been checked against the known
  # captain account. Standing scope covers the captain and nobody else.
  sed 's/^notify_recipient_verified = true$/notify_recipient_verified = false/' \
    "$h/config/channel-intake" >"$h/config/channel-intake.tmp"
  mv "$h/config/channel-intake.tmp" "$h/config/channel-intake"
  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1 --digest 'urgent one' \
    --class urgent --title 'urgent one' >/dev/null
  out=$(at "$h" "$T_0900" notify-due 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unverified recipient was notified'
  assert_contains "$out" 'verify the recipient against the known captain account' \
    'the refusal did not name recipient verification'
  new_home "$h"

  # Two urgent items in one window group into ONE payload, not two pings.
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1 \
    --digest 'urgent one' --class urgent --title 'urgent one')
  k1=$(key_of "$out")
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.2 \
    --digest 'urgent two' --class urgent --title 'urgent two')
  k2=$(key_of "$out")
  out=$(at "$h" "$T_0900" notify-due)
  assert_contains "$out" 'items: 2' 'two items did not group into one payload'
  assert_contains "$out" 'urgent one' 'the grouped payload dropped an item'
  assert_contains "$out" 'urgent two' 'the grouped payload dropped an item'

  # Rendering does not stamp: an interrupted send re-renders rather than
  # silently swallowing the alert.
  out=$(at "$h" "$T_0900" notify-due)
  assert_contains "$out" 'items: 2' 'an unconfirmed payload was treated as delivered'

  # The captain can resolve a rendered item before the send is confirmed. The
  # DM already went out, so the surviving item is still stamped, the resolved
  # one is skipped and named, and the payload still counts against the cap.
  at "$h" "$T_0900" resolve --item "$k2" --reason 'handled in the thread' >/dev/null
  out=$(at "$h" "$T_0900" notify-sent --keys "$k1 $k2") \
    || fail 'notify-sent failed because one rendered item had been resolved'
  assert_contains "$out" 'recorded for 1 item' 'the surviving item was not stamped'
  assert_contains "$out" "skipped (already resolved): $k2" 'the resolved key was not reported'
  [ -n "$(item_field "$h" "$k1" notified)" ] || fail 'the surviving item carries no notified stamp'
  out=$(at "$h" "$T_0900" notify-due)
  [ -z "$out" ] || fail "a delivered payload re-rendered after a partial stamp: $out"
  assert_grep 'count=1' "$h/data/channel-intake/notify-state" \
    'a partially stamped payload was not counted against the daily cap'

  # Rate limited: a third urgent item inside the minimum gap waits.
  at "$h" $((T_0900 + 60)) observe --source C_BRIEF --ref 1789023000.3 \
    --digest 'urgent three' --class urgent --title 'urgent three' >/dev/null
  out=$(at "$h" $((T_0900 + 60)) notify-due)
  [ -z "$out" ] || fail "a payload was sent inside the minimum gap: $out"
  out=$(at "$h" $((T_0900 + 1900)) notify-due)
  assert_contains "$out" 'urgent three' 'the deferred item never went out after the gap'

  # Routine work is never a ping; it accumulates into the brief instead.
  at "$h" $((T_0900 + 2000)) observe --source C_BRIEF --ref 1789023000.4 \
    --digest 'routine note' --class routine --title 'routine note' >/dev/null
  out=$(at "$h" $((T_0900 + 4000)) notify-due)
  assert_not_contains "$out" 'routine note' 'a routine change produced a private ping'
  assert_contains "$(at "$h" $((T_0900 + 4000)) brief)" 'routine note' \
    'a routine change never reached the brief'

  pass 'notifications are refused until the recipient is verified, then grouped, rate-limited and severity-scoped'
}

test_quiet_hours_defer_but_preserve_real_severity() {
  local h out
  h="$TMP_ROOT/quiet"
  new_home "$h"

  at "$h" "$T_2300" observe --source C_BRIEF --ref 1789073000.1 \
    --digest 'please review tomorrow' --class urgent --title 'review asked overnight' >/dev/null
  out=$(at "$h" "$T_2300" notify-due)
  [ -z "$out" ] || fail "an ordinary urgent item pinged inside quiet hours: $out"

  # Real severity survives quiet hours: a service outage still goes out.
  at "$h" "$T_2300" observe --source C_BRIEF --ref 1789073000.2 \
    --digest 'dispensers offline at the Rotterdam site' --class outage \
    --title 'service outage reported' >/dev/null
  out=$(at "$h" "$T_2300" notify-due)
  assert_contains "$out" 'service outage reported' 'a service outage was silenced by quiet hours'
  assert_not_contains "$out" 'review asked overnight' \
    'quiet hours leaked an ordinary urgent item alongside the outage'

  # Nothing was dropped: the deferred item goes out once quiet hours end.
  out=$(at "$h" "$T_NEXT_0900" notify-due)
  assert_contains "$out" 'review asked overnight' 'the deferred item was lost rather than deferred'

  pass 'quiet hours defer ordinary alerts without dropping them, and a service outage still gets through'
}

test_nothing_reaches_the_action_deck() {
  local h out
  h="$TMP_ROOT/deck"
  new_home "$h"

  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.9 \
    --digest 'these six units all need the same firmware push' \
    --class automation-candidate --title 'firmware push looks automatable')
  case "$out" in new\ *) ;; *) fail "the candidate was not recorded: $out" ;; esac

  # The deck renders its staged cards from the action gateway's own store,
  # which is also what the tray reads, plus the standing-order record and loose
  # ends. Detection must touch none of them: an intake can propose an
  # automation, and can never manufacture a button that fires one.
  assert_absent "$h/data/action-gateway" 'intake wrote a staged action the deck would render'
  assert_absent "$h/data/orders" 'intake wrote a standing order'
  assert_absent "$h/data/loose-ends" 'intake wrote into the loose-ends inbox'

  out=$(at "$h" "$T_0900" brief)
  assert_contains "$out" 'firmware push looks automatable' 'the candidate was not proposed in the brief'
  assert_contains "$out" 'Proposals only' 'the brief did not mark candidates as proposals'
  assert_contains "$out" 'grants no permission to act' \
    'the brief did not disclaim permission to act on a candidate'

  # A candidate is not a human obligation either, so it stays off the to-do list.
  assert_not_contains "$(at "$h" "$T_0900" todo)" 'firmware push looks automatable' \
    'an automation candidate was filed as a human to-do'

  # And it is never a private ping.
  out=$(at "$h" "$T_0900" notify-due)
  [ -z "$out" ] || fail "an automation candidate produced a private ping: $out"

  pass 'an automation candidate is a proposal only: nothing reaches the Action Deck and nothing becomes executable'
}

test_brief_and_todo_reconcile_from_one_ledger() {
  local h out key
  h="$TMP_ROOT/render"
  new_home "$h"

  out=$(at "$h" "$T_0900" observe --source M_ACTION --ref msg-1 \
    --digest 'sign the lease' --class obligation --title 'sign the lease')
  key=$(key_of "$out")
  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.5 \
    --digest 'renewal due 2026-09-20' --class deadline --title 'renewal due 2026-09-20' >/dev/null

  out=$(at "$h" "$T_0900" brief)
  assert_contains "$out" '## What changed' 'the brief lost its house-style sections'
  assert_contains "$out" '## What needs you' 'the brief lost its house-style sections'
  assert_contains "$out" '## Waiting on others' 'the brief lost its house-style sections'
  assert_contains "$out" '## Next dated actions' 'the brief lost its house-style sections'
  assert_contains "$out" 'renewal due 2026-09-20' 'a dated action missed the brief'
  assert_contains "$(at "$h" "$T_0900" todo)" 'sign the lease' 'an obligation missed the to-do list'

  # Completing the obligation reconciles across BOTH surfaces in one step,
  # because both render from the same ledger.
  at "$h" "$T_0915" resolve --item "$key" --reason 'lease signed and filed' >/dev/null
  assert_not_contains "$(at "$h" "$T_0915" todo)" 'sign the lease' \
    'a completed obligation stayed on the to-do list'
  out=$(at "$h" "$T_0915" brief)
  assert_not_contains "$out" '- [obligation] sign the lease' \
    'a completed obligation stayed under what needs you'
  assert_contains "$out" 'lease signed and filed' 'the completion left no evidence in the brief'

  # A background render updates the existing page rather than leaving a trail.
  at "$h" "$T_0915" brief --out "$h/reports/intake.md" >/dev/null
  at "$h" "$T_0915" todo --out "$h/reports/todo.md" >/dev/null
  assert_grep 'Channel intake brief' "$h/reports/intake.md" 'the brief was not written to the report'
  at "$h" "$T_NEXT_0900" brief --out "$h/reports/intake.md" >/dev/null
  [ "$(find "$h/reports" -name 'intake*.md' | wc -l | tr -d ' ')" = 1 ] \
    || fail 'a repeat render created a second page instead of updating the existing one'

  # Output outside the configured report directory is refused.
  out=$(at "$h" "$T_0915" brief --out "$TMP_ROOT/escape.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'the brief was written outside the configured report directory'
  out=$(at "$h" "$T_0915" brief --out "$h/reports/../escape.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a .. component walked --out out of the report directory'
  assert_contains "$out" '.. path component' 'the refusal did not name the .. component'
  assert_absent "$h/escape.md" 'the traversal wrote a page outside the report directory'
  out=$(at "$h" "$T_0915" todo --out "$h/reports/sub/../todo.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a .. component inside the report directory was accepted for todo'

  pass 'the brief and to-do list render from one ledger, so corrections and completions reconcile across both'
}

test_thread_replies_are_tracked_and_the_limit_is_disclosed() {
  local h out
  h="$TMP_ROOT/threads"
  new_home "$h"

  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.6 \
    --digest 'parent message' --class routine --title 'parent message' \
    --thread 1789023000.6 --reply-marker 1789023100.1 >/dev/null

  # The tracked parent comes back on claim, so only threads whose marker moved
  # need a re-read. That covers the tracked set and nothing older.
  out=$(at "$h" "$T_0915" claim --source C_BRIEF)
  assert_contains "$out" 'thread: C_BRIEF' 'the tracked thread parent was not handed back'
  assert_contains "$out" '1789023100.1' 'the reply marker was not handed back'

  # The revision window is handed over explicitly, and both detection limits are
  # stated on the captain-facing surface rather than left implicit.
  assert_contains "$out" 'revision_window_from:' 'the bounded revision window was not handed over'
  assert_contains "$out" 'thread_tracking_window_seconds:' \
    'claim did not state how far the tracked set actually reaches'
  out=$(at "$h" "$T_0915" brief)
  assert_contains "$out" 'revision window is not detected' \
    'the brief did not disclose the edit horizon'
  assert_contains "$out" 'can appear in no cursor read' \
    'the brief did not disclose the thread-reply gap'

  # The tracked set is BOUNDED, which is what makes the "tracked set" claim
  # literally true: a parent whose reply marker has not advanced within the
  # revision window leaves it, so neither the claim output nor the connector
  # work an orchestrator does per tick grows with all thread history.
  out=$(at "$h" $((T_0900 + 86401)) claim --source C_BRIEF)
  assert_not_contains "$out" 'thread: C_BRIEF' \
    'a dormant thread parent stayed in the tracked set forever'
  assert_contains "$(at "$h" $((T_0900 + 86401)) brief)" 'The tracked set is bounded' \
    'the brief claimed forever-complete thread tracking'

  # Retiring a marker retires a re-read hint and nothing else. The captured
  # item, its evidence and its key are untouched, so a later reply still lands
  # on the same item instead of becoming a second one.
  out=$(at "$h" $((T_0900 + 86401)) observe --source C_BRIEF --ref 1789023000.6 \
    --digest 'parent message')
  case "$out" in unchanged\ *) ;; *) fail "retiring a thread marker cost the captured item: $out" ;; esac

  # An advancing marker keeps its parent in the set; only dormancy retires one.
  at "$h" $((T_0900 + 86401)) observe --source C_BRIEF --ref 1789023000.7 \
    --digest 'a reply landed' --class routine --title 'a reply landed' \
    --thread 1789023000.6 --reply-marker 1789023900.2 >/dev/null
  out=$(at "$h" $((T_0900 + 87000)) claim --source C_BRIEF)
  assert_contains "$out" '1789023900.2' 'an advancing thread marker was retired anyway'

  pass 'thread parents are tracked for re-read inside a bounded set, and both detection limits are disclosed on the brief'
}

test_per_poll_work_is_bounded_without_losing_anything() {
  local h out key routine_key late
  h="$TMP_ROOT/bounded-work"
  new_home "$h"
  late=$((T_0900 + 86401 + 900))

  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.20 \
    --digest 'standup notes' --class routine --title 'standup notes')
  routine_key=$(key_of "$out")
  out=$(at "$h" "$T_0900" observe --source M_ACTION --ref msg-owed \
    --digest 'sign the lease' --class obligation --title 'sign the lease')
  key=$(key_of "$out")

  # Inside the brief horizon nothing moves: routine traffic is still exactly
  # what the "what changed" section is for.
  at "$h" $((T_0900 + 3600)) tick >/dev/null
  assert_present "$h/data/channel-intake/items/$routine_key" \
    'routine traffic left the polled set while it was still on the brief'

  # Past that same existing horizon it leaves the polled set by MOVING, record
  # intact - never by deletion, and never by being resolved on the captain's
  # behalf.
  at "$h" "$late" tick >/dev/null
  assert_absent "$h/data/channel-intake/items/$routine_key" \
    'routine traffic never left the polled set, so every later poll keeps paying for it'
  assert_present "$h/data/channel-intake/inactive/$routine_key" \
    'a retired routine record was deleted rather than moved'
  assert_contains "$(at "$h" "$late" items --state inactive)" "$routine_key" \
    'a retired routine record became invisible to items'
  assert_contains "$(at "$h" "$late" items)" "$routine_key" \
    'a bare items listing hid a retired record'
  assert_contains "$(at "$h" "$late" status)" 'items_inactive: 1' \
    'status did not report the retired record'

  # Nothing owed leaves, whatever its age.
  assert_present "$h/data/channel-intake/items/$key" 'an aged obligation was retired'
  assert_contains "$(at "$h" "$late" todo)" 'sign the lease' \
    'an aged obligation fell off the to-do list'

  # Dedup identity survives the move: re-observing the same message restores
  # the one item rather than opening a second one.
  out=$(at "$h" $((late + 900)) observe --source C_BRIEF --ref 1789023000.20 \
    --digest 'standup notes' --class routine --title 'standup notes')
  case "$out" in
    unchanged\ "$routine_key") ;;
    *) fail "re-observing a retired routine message did not restore the same item: $out" ;;
  esac
  assert_present "$h/data/channel-intake/items/$routine_key" \
    're-observing a retired routine message did not bring it back'

  pass 'the polled set stays bounded by moving aged routine traffic aside, without deleting evidence or forgetting an obligation'
}

test_ledger_writes_are_serialized() {
  local h out code
  h="$TMP_ROOT/serialized"
  new_home "$h"

  hold_state_lock "$h"
  # A watcher sweep must stay silent rather than block or clobber an
  # observation in flight, and finish well inside FM_CHECK_TIMEOUT.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_0900" \
    FM_CHANNEL_INTAKE_LOCK_WAIT=1 "$INTAKE" check) && code=0 || code=$?
  expect_code 0 "$code" 'a contended watcher sweep did not exit cleanly'
  [ -z "$out" ] || fail "a contended watcher sweep woke the primary anyway: $out"

  # A live write refuses loudly rather than racing the holder.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_0900" \
    FM_CHANNEL_INTAKE_LOCK_WAIT=1 "$INTAKE" observe --source C_BRIEF --ref 1789023000.7 \
    --digest 'contended' --title 'contended ask' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a contended observation was not refused'
  assert_contains "$out" 'still holds' 'the refusal did not name the contended record'
  release_state_lock "$h"

  # With the holder gone the same command succeeds.
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.7 --digest 'contended' --title 'contended ask')
  case "$out" in new\ *) ;; *) fail "the observation did not land once uncontended: $out" ;; esac

  pass 'ledger writes are serialized on a private mutex, so a sweep never clobbers an observation'
}

test_no_existing_fleet_is_overridden() {
  local h other out
  h="$TMP_ROOT/isolation"
  other="$TMP_ROOT/isolation-other"
  new_home "$h"
  new_home "$other"
  at "$other" "$T_0900" observe --source C_BRIEF --ref 1789023000.8 \
    --digest 'the other home' --class urgent --title 'the other home' >/dev/null

  at "$h" "$T_0900" tick >/dev/null
  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1 --digest 'this home' --title 'this home' >/dev/null

  # No session lock, no watcher lock, no watcher process.
  assert_absent "$h/state/.lock" 'the intake took the per-home session lock'
  assert_absent "$h/state/.watch.lock" 'the intake took the watcher lock'
  [ "$(at "$h" "$T_0900" items | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'this home saw the other home items'
  [ "$(at "$other" "$T_0900" items | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'the foreign home records were modified'
  out=$(at "$other" "$T_0900" items)
  assert_contains "$out" 'the other home' 'the foreign home ledger was overwritten'

  pass 'the intake never takes a fleet lock, starts a watcher, or touches another home records'
}

test_local_configuration_stays_private() {
  local h out code
  h="$TMP_ROOT/private"
  new_home "$h"

  # A source identity or token cannot be parked in the config file: unknown
  # keys are refused rather than ignored.
  printf 'enabled = true\nslack_channel_id = C0DEADBEEF\n' >"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unknown config key was accepted'
  assert_contains "$out" 'unknown config key: slack_channel_id' \
    'the refusal did not name the rejected key'

  new_home "$h"
  # Status prints declared knobs only, and never the recipient itself.
  out=$(at "$h" "$T_0900" status)
  assert_contains "$out" 'notify_recipient_set: true' 'status did not report recipient configuration'
  assert_contains "$out" 'notify_recipient_verified: true' 'status did not report recipient verification'
  assert_not_contains "$out" 'U_CAPTAIN' 'status printed the private recipient identity'

  # Message content never lands in the ledger, only its hash.
  printf 'the customer complained about the water quality at site 12\n' >"$h/body.txt"
  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.1 \
    --digest-file "$h/body.txt" --class routine --title 'a customer report' >/dev/null
  assert_no_grep 'water quality' "$(find "$h/data/channel-intake/items" -type f | head -1)" \
    'message content was copied into the ledger'

  # The tracked repository ignores both the config and the private ledger.
  assert_grep '/config/' "$ROOT/.gitignore" 'config is no longer gitignored'
  assert_grep 'data/' "$ROOT/.gitignore" 'data is no longer gitignored'

  pass 'source identities and message content stay out of the tracked repository and out of config'
}

test_arm_check_leaves_no_unregistered_shim() {
  local h out code
  h="$TMP_ROOT/armcheck"
  new_home "$h"

  at "$h" "$T_0900" arm-check
  assert_present "$h/state/channel-intake.check.sh" 'arming did not install the live check'
  [ "$(file_mode "$h/state/channel-intake.check.sh")" = 700 ] \
    || fail 'the live check is not mode 0700'
  assert_present "$h/state/channel-intake.check-trust" 'the live check was not bound'
  assert_contains "$(at "$h" "$T_0900" status)" 'check_armed: armed' \
    'the armed live check did not report as armed'

  # Re-arming converges rather than duplicating, and rebinds drifted bytes.
  at "$h" "$T_0900" arm-check
  assert_contains "$(at "$h" "$T_0900" status)" 'check_armed: armed' 'a second arm broke the binding'
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h/state/channel-intake.check.sh"
  assert_contains "$(at "$h" "$T_0900" status)" 'check_armed: unregistered' \
    'a drifted shim still reported as armed'
  at "$h" "$T_0900" arm-check
  assert_contains "$(at "$h" "$T_0900" status)" 'check_armed: armed' 'a drifted shim was not rebound'

  # A registration failure must leave nothing behind for the watcher to reject.
  # The failure is driven through the real registrar the way the morning gate's
  # is - an unwritable trust destination - because arm-check calls it by its
  # absolute path, so a shim on PATH would never be reached and the case would
  # assert nothing.
  rm -f "$h/state/channel-intake.check.sh" "$h/state/channel-intake.check-trust"
  mkdir -p "$h/state/channel-intake.check-trust"
  out=$(at "$h" "$T_0900" arm-check 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a failed registration was reported as success'
  assert_contains "$out" 'registration failed' 'a failed registration did not name itself'
  assert_absent "$h/state/channel-intake.check.sh" \
    'a failed registration left an unregistered shim for the watcher to reject'
  [ "$(at "$h" "$T_0900" status | awk '$1 == "check_armed:" { print $2 }')" = absent ] \
    || fail 'status reported a check that is not armed'
  rm -rf "$h/state/channel-intake.check-trust"

  # Losing the shim is reported where an operator already looks.
  new_home "$h"
  at "$h" "$T_0900" arm-check
  rm -f "$h/state/channel-intake.check.sh" "$h/state/channel-intake.check-trust"
  out=$(at "$h" "$T_0900" pending)
  assert_contains "$out" 'live check is absent' 'a lost live check was not reported at session start'
  assert_contains "$out" 'arm-check' 'the report did not name the repair'

  at "$h" "$T_0900" arm-check
  out=$(at "$h" "$T_0900" disarm-check)
  assert_contains "$out" 'disarmed' 'disarming did not report'
  assert_absent "$h/state/channel-intake.check.sh" 'disarming left the shim behind'
  assert_present "$h/data/channel-intake/sources.tsv" 'disarming discarded the private inventory'

  pass 'arming the live check is all-or-nothing and idempotent, and losing it is reported with its repair'
}

test_a_held_alert_with_nothing_due_wakes_once_per_state() {
  local h out offset
  h="$TMP_ROOT/check-held-idle"
  new_home "$h"
  sed -i.bak -e 's/^notify_recipient_verified = true$/notify_recipient_verified = false/' \
    -e 's/^interval_seconds = 900$/interval_seconds = 86400/' "$h/config/channel-intake"
  rm -f "$h/config/channel-intake.bak"

  at "$h" "$T_0900" observe --source C_BRIEF --ref out-1 \
    --digest 'the dispenser at site 12 is down' --class outage \
    --title 'service outage at site 12' >/dev/null
  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint c-1 >/dev/null
  at "$h" "$T_0900" complete --source M_ACTION --checkpoint m-1 >/dev/null

  out=$(at "$h" "$T_0900" check)
  assert_contains "$out" '1 item(s) blocked' 'the held alert did not wake the primary'
  assert_not_contains "$out" 'due to read' 'an idle due set was reported as due'

  # Watcher sweeps every 300s must not turn an unchanged held alert into a nag.
  for offset in 300 600 3600 21600 43199; do
    out=$(at "$h" $((T_0900 + offset)) check)
    [ -z "$out" ] || fail "an unchanged held alert woke the primary again after ${offset}s: $out"
  done

  # A wake lost before delivery is bounded by the 12-hour backstop, once.
  out=$(at "$h" $((T_0900 + 43200)) check)
  assert_contains "$out" '1 item(s) blocked' 'the backstop did not re-wake an unchanged held alert'
  out=$(at "$h" $((T_0900 + 43500)) check)
  [ -z "$out" ] || fail "the backstop became a wake loop: $out"

  # A changed signature wakes at once, inside the backstop window.
  at "$h" $((T_0900 + 43800)) observe --source M_ACTION --ref m-99 \
    --digest 'the permit expires on friday' --class deadline \
    --title 'permit renewal deadline' >/dev/null
  out=$(at "$h" $((T_0900 + 43800)) check)
  assert_contains "$out" '2 item(s) blocked' 'a changed held alert was suppressed by the backstop'
  pass 'a held alert with nothing due wakes once per state, with a 12-hour backstop'
}

test_check_signals_once_per_state() {
  local h out
  h="$TMP_ROOT/check"
  new_home "$h"

  out=$(at "$h" "$T_0900" check)
  assert_contains "$out" '2 source(s) due to read' 'the watcher check did not report due sources'
  # Suppression by signature: the same state must not wake the primary again.
  out=$(at "$h" $((T_0900 + 60)) check)
  [ -z "$out" ] || fail "an unchanged state woke the primary again: $out"

  # Suppression must not outlive the condition. Once every source is read the
  # check goes quiet, and the next interval is a genuinely new due state that
  # has to wake the primary again - otherwise the live path fires once in the
  # life of the home and every later cycle waits for a session start.
  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint 1789023000.1 >/dev/null
  at "$h" "$T_0900" complete --source M_ACTION --checkpoint m-1 >/dev/null
  out=$(at "$h" "$T_0900" check)
  [ -z "$out" ] || fail "a settled home still woke the primary: $out"
  out=$(at "$h" "$T_0915" check)
  assert_contains "$out" '2 source(s) due to read' \
    'a recurring due state was suppressed forever by the first wake'

  pass 'the watcher check wakes the primary once per state and re-arms when the state recurs'
}

# A standing alert the gate refuses or holds is reported once, not turned into
# a wake loop by the due set emptying and refilling underneath it.
test_a_held_alert_does_not_become_a_wake_loop() {
  local h out t i due_wakes=0 quiet_wakes=0
  h="$TMP_ROOT/check-nag"
  new_home "$h"
  sed -i.bak 's/^notify_recipient_verified = true$/notify_recipient_verified = false/' \
    "$h/config/channel-intake"
  rm -f "$h/config/channel-intake.bak"

  at "$h" "$T_0900" observe --source C_BRIEF --ref out-1 \
    --digest 'the dispenser at site 12 is down' --class outage \
    --title 'service outage at site 12' >/dev/null

  # The first sweep reports both conditions together, once.
  out=$(at "$h" "$T_0900" check)
  assert_contains "$out" 'source(s) due to read' 'the first sweep did not report the due sources'
  assert_contains "$out" 'blocked' 'the first sweep did not report the blocked alert'

  # Four worked poll cycles. The due set empties on every claim and refills one
  # interval later; the blocked alert never changes, so it must never be the
  # reason for another wake, and a sweep with nothing due must stay silent.
  t=$T_0900
  i=0
  while [ "$i" -lt 4 ]; do
    at "$h" "$t" claim >/dev/null
    at "$h" "$t" complete --source C_BRIEF --checkpoint "c-$i" >/dev/null
    at "$h" "$t" complete --source M_ACTION --checkpoint "m-$i" >/dev/null
    out=$(at "$h" $((t + 60)) check)
    if [ -n "$out" ]; then
      quiet_wakes=$((quiet_wakes + 1))
      assert_not_contains "$out" '0 source(s) due to read' \
        'a sweep with nothing due still claimed sources were due'
    fi
    t=$((t + 900))
    out=$(at "$h" "$t" check)
    [ -z "$out" ] || due_wakes=$((due_wakes + 1))
    i=$((i + 1))
  done
  [ "$quiet_wakes" -eq 0 ] \
    || fail "a held alert woke the primary $quiet_wakes time(s) on a settled due set"
  [ "$due_wakes" -eq 4 ] \
    || fail "a genuinely recurring due state woke the primary $due_wakes time(s) in 4 cycles"

  # The alert half re-wakes on its own terms: a second blocked item is a real
  # change and must be surfaced even though the first one already was.
  at "$h" "$t" observe --source M_ACTION --ref m-99 \
    --digest 'the permit expires on friday' --class deadline \
    --title 'permit renewal deadline' >/dev/null
  out=$(at "$h" "$t" check)
  assert_contains "$out" '2 item(s) blocked' 'a newly blocked item was suppressed by the earlier one'

  pass 'a blocked or held alert is reported once rather than re-waking the primary every poll'
}

# The alert half must be identified by WHICH items are notifiable, not by how
# many. One urgent ask cleared and replaced by a different one is the most
# ordinary sequence there is, and it collides on every count-only signature.
test_a_replaced_alert_still_wakes_the_primary() {
  local h out key
  h="$TMP_ROOT/check-identity"
  new_home "$h"
  # Settle the due half so nothing but the alert can be the reason for a wake.
  at "$h" "$T_0900" claim >/dev/null
  at "$h" "$T_0900" complete --source C_BRIEF --checkpoint c-0 >/dev/null
  at "$h" "$T_0900" complete --source M_ACTION --checkpoint m-0 >/dev/null

  out=$(at "$h" $((T_0900 + 60)) observe --source C_BRIEF --ref ask-a \
    --digest 'approve invoice A' --class urgent --title 'ask A')
  key=$(key_of "$out")
  out=$(at "$h" $((T_0900 + 60)) check)
  assert_contains "$out" '1 item(s) ready to send' 'the first alert did not wake the primary'
  out=$(at "$h" $((T_0900 + 120)) check)
  [ -z "$out" ] || fail "the same standing alert woke the primary again: $out"

  # The captain clears A, and a genuinely different urgent ask arrives. Same
  # state token, same count, different obligation.
  at "$h" $((T_0900 + 180)) resolve --item "$key" --reason 'captain approved A' >/dev/null
  at "$h" $((T_0900 + 180)) observe --source C_BRIEF --ref ask-b \
    --digest 'approve invoice B' --class urgent --title 'ask B' >/dev/null
  out=$(at "$h" $((T_0900 + 180)) check)
  assert_contains "$out" '1 item(s) ready to send' \
    'a replacement urgent ask was suppressed by the cleared one it happened to match'
  out=$(at "$h" $((T_0900 + 240)) check)
  [ -z "$out" ] || fail "the replacement alert woke the primary twice: $out"

  # A correction to an alert already reported is a change too: the content the
  # captain would be pinged about is not the content already surfaced.
  at "$h" $((T_0900 + 300)) observe --source C_BRIEF --ref ask-b \
    --digest 'approve invoice B, revised upward' --class urgent --title 'ask B' >/dev/null
  out=$(at "$h" $((T_0900 + 300)) check)
  assert_contains "$out" '1 item(s) ready to send' \
    'a corrected alert never reached the live wake path'

  pass 'a cleared alert replaced by a different one still wakes the primary, and an unchanged one still does not'
}

# A refusal and a suppression are not the same thing as nothing to send, and
# neither may reach the captain as a quiet home.
test_blocked_notifications_are_visible_rather_than_silent() {
  local h out
  h="$TMP_ROOT/notify-blocked"
  new_home "$h"
  sed -i.bak 's/^notify_recipient_verified = true$/notify_recipient_verified = false/' \
    "$h/config/channel-intake"
  rm -f "$h/config/channel-intake.bak"

  at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.9 \
    --digest 'the dispenser at site 12 is down' --class outage \
    --title 'service outage at site 12' >/dev/null

  out=$(at "$h" "$T_0900" pending)
  assert_contains "$out" 'notify_recipient_verified is not true' \
    'an unverified recipient blocked the alert without saying so at session start'
  assert_contains "$(at "$h" "$T_0900" status)" 'notifications_state: unverified' \
    'status did not report the refusal'
  assert_contains "$(at "$h" "$T_0900" check)" 'blocked' \
    'the watcher check reported a blocked alert as quiet'

  # The refusal itself still stands: nothing is rendered for an unverified
  # recipient, whatever the reporting surfaces say about it.
  out=$(at "$h" "$T_0900" notify-due 2>&1) && fail 'an unverified recipient rendered a payload'
  assert_contains "$out" 'verify the recipient' 'the refusal did not name its repair'

  # The daily cap is held rather than lost, and reads as held.
  sed -i.bak 's/^notify_recipient_verified = false$/notify_recipient_verified = true/; s/^notify_max_per_day = 8$/notify_max_per_day = 1/' \
    "$h/config/channel-intake"
  rm -f "$h/config/channel-intake.bak"
  out=$(at "$h" "$T_0900" notify-due)
  at "$h" "$T_0900" notify-sent --keys "$(printf '%s' "$out" | awk '$1 == "keys:" { $1 = ""; print }')" >/dev/null
  at "$h" "$T_0915" observe --source M_ACTION --ref m-2 \
    --digest 'the permit expires on friday' --class deadline \
    --title 'permit renewal deadline' >/dev/null
  out=$(at "$h" "$T_0915" pending)
  assert_contains "$out" 'daily notification cap is spent' \
    'a capped payload was reported as nothing to send'
  assert_contains "$(at "$h" "$T_0915" status)" 'notifications_state: capped' \
    'status did not report the cap'

  pass 'a refused or capped notification is reported as itself instead of looking like a quiet home'
}

# A report the captain asked for opens when it is ready. A scheduled or
# background render writes the same page and never takes focus.
test_only_a_requested_render_opens_the_page() {
  local h out code fake log
  h="$TMP_ROOT/open"
  new_home "$h"
  fake=$(fm_fakebin "$h")
  log="$h/opened.log"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"%s"\n' "$log" >"$fake/fm-fake-open"
  chmod +x "$fake/fm-fake-open"
  printf 'open_command = %s/fm-fake-open\n' "$fake" >>"$h/config/channel-intake"

  at "$h" "$T_0900" observe --source M_ACTION --ref msg-1 \
    --digest 'sign the lease' --class obligation --title 'sign the lease' >/dev/null

  # A captain-requested render opens exactly the page it wrote, once.
  out=$(at "$h" "$T_0900" brief --out "$h/reports/intake.md" --open)
  assert_contains "$out" 'brief written to' 'the requested render did not report the written page'
  assert_contains "$out" "opened $h/reports/intake.md" 'the requested render did not report opening the page'
  [ "$(grep -c . "$log")" = 1 ] || fail "a requested brief did not open exactly once: $(cat "$log")"
  [ "$(head -1 "$log")" = "$h/reports/intake.md" ] \
    || fail "the opener was handed something other than the written page: $(head -1 "$log")"

  out=$(at "$h" "$T_0900" todo --out "$h/reports/todo.md" --open)
  assert_contains "$out" "opened $h/reports/todo.md" 'a requested to-do render did not open its page'
  [ "$(grep -c . "$log")" = 2 ] || fail "a requested to-do list did not open exactly once: $(cat "$log")"

  # Every unflagged render - including the scheduled path - opens nothing.
  rm -f "$log"
  at "$h" "$T_0915" brief --out "$h/reports/intake.md" >/dev/null
  at "$h" "$T_0915" todo --out "$h/reports/todo.md" >/dev/null
  at "$h" "$T_0915" brief >/dev/null
  at "$h" "$T_0915" tick >/dev/null
  at "$h" "$T_0915" claim >/dev/null
  at "$h" "$T_0915" check >/dev/null || true
  at "$h" "$T_0915" pending >/dev/null
  assert_absent "$log" 'a background render or a scheduled tick stole focus by opening a page'
  assert_present "$h/reports/intake.md" 'the background render did not write the page'
  [ "$(find "$h/reports" -name 'intake*.md' | wc -l | tr -d ' ')" = 1 ] \
    || fail 'the open flag changed the same-path overwrite into a trail of pages'

  # There is no page to open without --out, and that is refused up front
  # rather than silently opening nothing.
  out=$(at "$h" "$T_0915" brief --open 2>&1) && code=0 || code=$?
  expect_code 2 "$code" '--open without --out was accepted'
  assert_contains "$out" 'requires --out' 'the refusal did not explain what is missing'

  # Fail-soft: the render is the deliverable and the open is a convenience.
  printf '#!/usr/bin/env bash\nexit 3\n' >"$fake/fm-fake-open"
  chmod +x "$fake/fm-fake-open"
  out=$(at "$h" "$T_0915" brief --out "$h/reports/intake.md" --open) && code=0 || code=$?
  expect_code 0 "$code" 'a failing opener turned a written page into a failed command'
  assert_contains "$out" 'brief written to' 'the fail-soft path lost the written page'
  assert_contains "$out" 'could not open' 'a failing opener was not reported'

  # An opener that is not installed at all is the same fail-soft path.
  printf 'enabled = true
timezone = Europe/Amsterdam
report_dir = %s/reports
open_command = fm-opener-that-does-not-exist
' "$h" >"$h/config/channel-intake"
  out=$(at "$h" "$T_0915" todo --out "$h/reports/todo.md" --open) && code=0 || code=$?
  expect_code 0 "$code" 'a missing opener turned a written page into a failed command'
  assert_contains "$out" 'to-do list written to' 'the fail-soft path lost the written page'
  assert_contains "$out" 'no opener named' 'a missing opener was not reported'

  pass 'a requested render opens its page once, a background render never does, and a bad opener never fails the render'
}

test_unresolvable_timezone_is_refused() {
  local h out code
  h="$TMP_ROOT/tz"
  new_home "$h"
  printf 'enabled = true\ntimezone = Mars/Olympus\n' >"$h/config/channel-intake"

  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unresolvable timezone was accepted'
  assert_contains "$out" 'does not resolve on this host' 'the refusal did not name the timezone'

  pass 'a timezone that does not resolve is refused instead of silently becoming UTC'
}

# The read side, not the alert side: quiet hours already have their own test.
test_scan_window_bounds_the_reads() {
  local h out code

  # With no window configured nothing changes: a source is due whenever the
  # interval says so, at any hour.
  h="$TMP_ROOT/window-unset"
  new_home "$h"
  out=$(at "$h" "$T_1700" tick)
  assert_contains "$out" 'source(s) due' 'an unconfigured window stopped an ordinary read'

  h="$TMP_ROOT/window"
  new_home "$h"
  printf 'active_start = 09:00\nactive_end = 16:30\n' >>"$h/config/channel-intake"

  # Outside the window nothing is due at all, so the scheduled tick enqueues no
  # wake, the watcher check stays silent, and a claim hands back no source.
  out=$(at "$h" "$T_1700" tick)
  [ -z "$out" ] || fail "a tick outside the scanning window reported work: $out"
  [ "$(queue_lines "$h")" = 0 ] || fail 'a tick outside the scanning window woke the primary'
  out=$(at "$h" "$T_1700" check)
  [ -z "$out" ] || fail "the watcher check fired outside the scanning window: $out"
  out=$(at "$h" "$T_1700" claim)
  assert_contains "$out" '<none due>' 'a claim outside the scanning window handed back a source'
  out=$(at "$h" "$T_1700" status)
  assert_contains "$out" 'active_window: 09:00-16:30' 'status did not report the scanning window'
  assert_contains "$out" 'in_active_window: false' 'status placed 17:00 inside a 09:00-16:30 window'
  assert_contains "$out" 'sources_due: 0' 'sources read as due outside the scanning window'

  # A laptop opened partway into the window reads on that first tick rather
  # than waiting for the next interval boundary.
  out=$(at "$h" "$T_1015" tick)
  assert_contains "$out" '2 source(s) due' 'the first tick after the window opened did not read'
  out=$(at "$h" "$T_1015" status)
  assert_contains "$out" 'in_active_window: true' 'status placed 10:15 outside a 09:00-16:30 window'

  # A window whose end is at or before its start wraps midnight, the same rule
  # quiet hours use.
  h="$TMP_ROOT/window-wrap"
  new_home "$h"
  printf 'active_start = 22:00\nactive_end = 07:00\n' >>"$h/config/channel-intake"
  out=$(at "$h" "$T_2300" status)
  assert_contains "$out" 'in_active_window: true' '23:00 fell outside a 22:00-07:00 window'
  out=$(at "$h" "$T_2300" tick)
  assert_contains "$out" 'source(s) due' 'a read inside the wrapped window was suppressed'
  out=$(at "$h" "$T_0900" status)
  assert_contains "$out" 'in_active_window: false' '09:00 fell inside a 22:00-07:00 window'

  # Half a window is a configuration error, not a silent all-day scan.
  h="$TMP_ROOT/window-half"
  new_home "$h"
  printf 'active_start = 09:00\n' >>"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a half-configured scanning window was accepted'
  assert_contains "$out" 'must be set together' 'the refusal did not name the missing bound'

  h="$TMP_ROOT/window-equal"
  new_home "$h"
  printf 'active_start = 09:00\nactive_end = 09:00\n' >>"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'equal scanning-window bounds were accepted'
  assert_contains "$out" 'must differ' 'the refusal did not explain the equal bounds'

  pass 'the scanning window bounds the reads themselves and opens with an immediate first read'
}

test_equal_quiet_bounds_are_refused() {
  local h out code
  h="$TMP_ROOT/quiet-equal"
  new_home "$h"
  sed 's/^quiet_end = 07:00$/quiet_end = 22:00/' \
    "$h/config/channel-intake" >"$h/config/channel-intake.tmp"
  mv "$h/config/channel-intake.tmp" "$h/config/channel-intake"

  out=$(at "$h" "$T_0900" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'equal quiet bounds were accepted and would silence every hour'
  assert_contains "$out" 'must differ' 'the refusal did not explain the equal bounds'

  pass 'quiet hours with equal bounds are refused instead of silencing every alert forever'
}

test_both_schedules_share_one_launchd_writer() {
  assert_grep 'fm-launchd-schedule-lib.sh' "$SCHEDULE" \
    'the channel-intake schedule no longer reuses the shared launchd writer'
  assert_grep 'FM_LAUNCHD_STEM=channel-intake' "$SCHEDULE" \
    'the channel-intake schedule does not declare its own launchd stem'
  assert_no_grep 'FM_LAUNCHD_STEM=morning-intake' "$SCHEDULE" \
    'the channel-intake schedule collides with the morning intake agent'

  pass 'the schedule reuses the one launchd writer under its own agent label'
}

test_install_and_uninstall_on_a_temp_home() {
  local h agents fake out code
  h="$TMP_ROOT/install"
  new_home "$h"
  agents="$h/LaunchAgents"
  mkdir -p "$agents"
  fake=$(fm_fakebin "$h")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/launchctl.log"\nexit 0\n' "$h" \
    >"$fake/launchctl"
  chmod +x "$fake/launchctl"

  sched() {
    FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
      FM_CHANNEL_INTAKE_LAUNCH_AGENTS_DIR="$agents" \
      FM_CHANNEL_INTAKE_LAUNCHCTL="$fake/launchctl" "$SCHEDULE" "$@"
  }

  out=$(sched render)
  assert_contains "$out" '<key>StartInterval</key>' 'the rendered agent has no interval trigger'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the rendered agent does not run at load'
  assert_contains "$out" '900' 'the rendered agent did not read the cadence from the gate'
  assert_contains "$out" 'fm-channel-intake.sh' 'the rendered agent does not run the gate'
  assert_contains "$out" 'tick' 'the rendered agent does not run the repeat-poll entry point'

  # `install` is the shared launchd writer's macOS-only path, so everywhere else
  # the inspectable definition above is the whole of this schedule's contract.
  if [ "$(uname)" != Darwin ]; then
    pass 'the schedule renders an inspectable per-home launchd definition (install skipped: not macOS)'
    return 0
  fi

  sched install >/dev/null
  [ "$(find "$agents" -name '*.plist' | wc -l | tr -d ' ')" = 1 ] \
    || fail 'install did not write exactly one agent'
  assert_present "$h/state/channel-intake.check.sh" 'install did not arm the live check'
  assert_grep 'bootstrap' "$h/launchctl.log" 'install did not load the agent into launchd'

  sched remove >/dev/null
  [ "$(find "$agents" -name '*.plist' | wc -l | tr -d ' ')" = 0 ] \
    || fail 'remove left the agent behind'
  assert_absent "$h/state/channel-intake.check.sh" 'remove left the live check armed'
  # Removing the schedule is not discarding the ledger.
  assert_present "$h/data/channel-intake/sources.tsv" 'remove discarded the private inventory'

  # A home that never opted in cannot acquire a schedule by accident.
  printf 'enabled = false\n' >"$h/config/channel-intake"
  out=$(sched install 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a home that never opted in was given a schedule'
  assert_contains "$out" 'not opted in' 'the refusal did not name the missing opt-in'

  pass 'install and uninstall work against a temporary home and refuse a home that never opted in'
}

test_new_source_kinds_get_their_own_reads() {
  local h out code
  h="$TMP_ROOT/kinds"
  new_home "$h"
  printf 'D_DMS\tslack-dms\tDMs with the named colleagues\nCAL\tcalendar\tthe captain calendar\nA_REQ\tasana-projects\ttasks assigned to the captain\n' \
    >>"$h/data/channel-intake/sources.tsv"
  out=$(at "$h" "$T_0900" claim)
  assert_contains "$out" $'dms: D_DMS\tread each DM and group DM the coverage sentence names directly' 'a DM source was not told to read DMs directly'
  # Thursday 10 Sep: the next two working days end on Monday 14 Sep.
  assert_contains "$out" $'calendar: CAL\tfrom: 2026-09-10\tto: 2026-09-14' 'the calendar window is not the next two working days'
  assert_contains "$out" $'relist: A_REQ\tlast_relist: never' 'Asana was not handed its daily full re-list'
  at "$h" "$T_0900" complete --source A_REQ --checkpoint a1 --relisted >/dev/null
  out=$(at "$h" "$T_0915" claim --source A_REQ)
  assert_not_contains "$out" 'relist:' 'the Asana re-list ran twice in one day'
  out=$(at "$h" "$T_NEXT_0900" claim --source A_REQ)
  assert_contains "$out" $'relist: A_REQ\tlast_relist: '"$T_0900" 'the Asana re-list did not come back the next day'
  out=$(at "$h" "$T_0900" complete --source C_BRIEF --checkpoint x --relisted 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a non-Asana source recorded a re-list'
  pass 'Slack DMs, the calendar and a daily Asana re-list each get their own read on a claim'
}

test_observe_and_resolve_refuse_what_rots_the_page() {
  local h out code key
  h="$TMP_ROOT/refusals"
  new_home "$h"
  printf 'captain_names = Robin Vale\n' >>"$h/config/channel-intake"
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.40 --digest a 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a title-less observe opened an item'
  assert_contains "$out" '--title is required' 'the refusal did not name the missing title'
  # A refused title-less thread reply leaves no marker, so the next claim still offers the thread.
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023100.41 --digest a \
    --thread 1789023000.40 --reply-marker 1789023100.41 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a title-less thread reply opened an item'
  [ ! -e "$h/data/channel-intake/threads/C_BRIEF/1789023000.40" ] \
    || fail 'a refused title-less thread reply still recorded its reply marker'
  key=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.40 --digest a --class obligation \
    --title 'router question' --partner | awk '{ print $2 }')
  # A later re-read needs no title and keeps the partner mark.
  at "$h" "$T_0915" observe --source C_BRIEF --ref 1789023000.40 --digest b >/dev/null \
    || fail 'a re-read of a known item needed a title'
  assert_grep 'partner_hint=1' "$h/data/channel-intake/items/$key" 'a re-read dropped the partner mark'
  for reason in 'Kim asks - later' 'later' 'Later' 'Robin will do it later' 'This will happen later' \
    'Reply to Kim later' 'follow up in Notion later' 'Customer is waiting, Robin replies later' \
    'asked Sam to check later' 'waiting on the logs' 'She will confirm later' 'Someone will check' \
    'He will reply later' 'They will confirm' 'waiting on Him' \
    'Everything will settle later' 'Everybody will chip in' 'Whoever will pick it up' 'Mine will wait' \
    'follow up in Asana later' 'Robin will answer' 'waiting on you' 'waiting for Vale to sign off' \
    'waiting on Robin for 3 decisions' 'Robin will decide 2 options' 'waiting on you, he marked 2 units' 'waiting on you, he sat on it'; do
    out=$(at "$h" "$T_0915" resolve --item "$key" --waiting --reason "$reason" 2>&1) && code=0 || code=$?
    expect_code 2 "$code" "a dateless wait with no named hand-over was accepted: $reason"
  done
  out=$(at "$h" "$T_0915" resolve --item "$key" --waiting --reason 'Robin will answer Sat' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a bare "Sat" was accepted as a date'
  assert_contains "$out" 'a full weekday name or mon/tue/thu/fri' 'the refusal did not say which weekdays count'
  assert_contains "$out" 'a hand-over to someone named other than the captain' 'the refusal did not say a named hand-over is accepted'
  # A stated hand-over to someone else needs no date, even when it mentions him.
  for reason in 'Robin handed it to Sam' 'Quinn will send you the logs' 'routed to Nora, she will update your ticket' \
    'routed to Nora, she will confirm later' 'waiting on Paul for the RMA decision' 'Quinn will send the logs' \
    'Nora will confirm later' 'assigned to Sam' 'handed over to Paul'; do
    at "$h" "$T_0915" resolve --item "$key" --waiting --reason "$reason" >/dev/null \
      || fail "a hand-over to someone else was refused as a wait on the captain: $reason"
  done
  for reason in 'waiting on Robin until 14 Oct' 'Robin will answer by Oct 14'; do
    at "$h" "$T_0915" resolve --item "$key" --waiting --reason "$reason" >/dev/null \
      || fail "a wait with a day and month was refused: $reason"
  done
  at "$h" "$T_0915" resolve --item "$key" --waiting --reason 'Kim asks - later, back on Friday' >/dev/null \
    || fail 'a dated wait was refused'
  pass 'observe refuses untitled items and keeps a partner mark; a wait needs a date or a named hand-over to someone else'
}

test_bootstrap_surfaces_the_intake() {
  local h out
  h="$TMP_ROOT/bootstrap-hook"
  new_home "$h"
  at "$h" "$T_0900" arm-check
  rm -f "$h/state/channel-intake.check.sh" "$h/state/channel-intake.check-trust"
  # Session-start bootstrap reaches the intake through the built-in bootstrap
  # hook (bin/fm-addon.sh, hooks/bootstrap/20-channel-intake).
  out=$(FM_HOME="$h" "$ROOT/bin/fm-addon.sh" hooks bootstrap)
  assert_contains "$out" "$ROOT/hooks/bootstrap/20-channel-intake" 'the built-in bootstrap hook is not listed'
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_0900" "$ROOT/bin/fm-addon.sh" run bootstrap)
  assert_contains "$out" 'CHANNEL_INTAKE:' 'the bootstrap hook point did not surface the channel intake'
  assert_contains "$out" 'live check is absent' 'the bootstrap hook point did not report the lost live check'

  pass 'the session-start bootstrap section surfaces due sources, ready alerts and a lost live check'
}

test_team_announcements_are_information_not_asks() {
  local h out code key late edited_key edited
  h="$TMP_ROOT/announcements"
  new_home "$h"
  printf 'C_TEAM\tslack-announcements\tteam announcement channels, kept posts only\n' \
    >>"$h/data/channel-intake/sources.tsv"

  # Only an announcement source may record an update; anywhere else it would
  # quietly turn an ask into information.
  out=$(at "$h" "$T_0900" observe --source C_BRIEF --ref 1789023000.30 \
    --digest 'cabinet launch' --class update --title 'cabinet launch' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a non-announcement source accepted an update'
  assert_contains "$out" 'requires a slack-announcements source' \
    'the refusal did not name the announcement source'

  out=$(at "$h" "$T_0900" observe --source C_TEAM --ref 1789023000.31 \
    --digest 'furniture limited release' --class update --source-epoch 1789022000 \
    --title 'Furniture limited release, 50 units - live on the partner webshop 15 Oct' \
    --link 'https://example.slack.com/archives/C_TEAM/p1789023000000031')
  key=$(key_of "$out")
  [ -n "$key" ] || fail "an announcement was not recorded: $out"
  assert_contains "$(item_field "$h" "$key" class)" 'update' 'the announcement lost its class'

  # Never a ping and never owed, but news on the brief.
  out=$(at "$h" "$T_0915" notify-due)
  case "$out" in *Furniture*) fail "an announcement was notified: $out" ;; esac
  out=$(at "$h" "$T_0915" todo)
  case "$out" in *Furniture*) fail "an announcement landed on the to-do list: $out" ;; esac
  assert_contains "$(at "$h" "$T_0915" brief)" 'Furniture limited release' \
    'the brief did not carry the announcement'

  # Past the routine horizon it stays; past its own horizon it moves aside intact.
  at "$h" $((T_0900 + 86401 + 900)) tick >/dev/null
  assert_present "$h/data/channel-intake/items/$key" \
    'an announcement left the polled set at the routine horizon'
  late=$((T_0900 + 1209601 + 900))
  at "$h" "$late" tick >/dev/null
  assert_absent "$h/data/channel-intake/items/$key" \
    'an announcement never left the polled set'
  assert_present "$h/data/channel-intake/inactive/$key" \
    'a retired announcement was deleted rather than moved'

  # An edited announcement (a moved date) ages out from its last change.
  out=$(at "$h" "$T_0900" observe --source C_TEAM --ref 1789023000.32 \
    --digest 'flavour box price change' --class update --title 'Flavour box price change')
  edited_key=$(key_of "$out")
  edited=$((T_0900 + 86400))
  out=$(at "$h" "$edited" observe --source C_TEAM --ref 1789023000.32 \
    --digest 'flavour box price change, date moved' --class update \
    --title 'Flavour box price change, from 1 Nov')
  assert_contains "$out" "updated $edited_key" 'the edit did not update the same announcement'
  at "$h" "$late" tick >/dev/null
  assert_present "$h/data/channel-intake/items/$edited_key" \
    'an edited announcement left the polled set before its edit was past the horizon'
  at "$h" $((edited + 1209601 + 900)) tick >/dev/null
  assert_absent "$h/data/channel-intake/items/$edited_key" \
    'an edited announcement never left the polled set'
  assert_present "$h/data/channel-intake/inactive/$edited_key" \
    'a retired edited announcement was deleted rather than moved'

  pass 'a team announcement is recorded as information only, from an announcement source, and ages out on its own horizon'
}

# A home whose add-on still carries its own copy of the daily intake, as one did
# before the intake shipped here. The add-on's bin/ holds every script of this
# repository by symlink, so its intake tools run as copies that live in the
# add-on; its hooks and skills are real copies.
test_an_addon_copy_of_the_intake_keeps_running() {
  local h addon out entry shim before checkout
  h="$TMP_ROOT/addon-copy"
  new_home "$h"
  printf 'enabled = true\ntimezone = Europe/Amsterdam\nstart_time = 06:00\n' >"$h/config/morning-intake"
  addon="$h/addon"
  mkdir -p "$addon/bin" "$addon/hooks/bootstrap" "$addon/.agents/skills"
  for entry in "$ROOT"/bin/*; do ln -s "$entry" "$addon/bin/${entry##*/}"; done
  cp "$ROOT/hooks/bootstrap/10-morning-intake" "$ROOT/hooks/bootstrap/20-channel-intake" "$addon/hooks/bootstrap/"
  cp -R "$ROOT/.agents/opt-in-skills/intake-digest-lines" "$ROOT/.agents/opt-in-skills/daily-todo-freshness" \
    "$addon/.agents/skills/"
  printf 'path = %s\n' "$addon" >"$h/config/addon"

  # Hooks: the add-on's replace the built-ins of the same name, and run its scripts.
  out=$(FM_HOME="$h" "$ROOT/bin/fm-addon.sh" hooks bootstrap)
  assert_contains "$out" "$addon/hooks/bootstrap/10-morning-intake" 'the add-on morning hook is not listed'
  assert_contains "$out" "$addon/hooks/bootstrap/20-channel-intake" 'the add-on channel hook is not listed'
  printf '%s\n' "$out" | grep -Fq "$ROOT/hooks/bootstrap/" \
    && fail "a built-in intake hook still runs beside the add-on's: $out"
  # Tools: the live check the add-on armed names its own script, and a
  # session start leaves it that way.
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_0900" "$addon/bin/fm-channel-intake.sh" arm-check >/dev/null
  shim="$h/state/channel-intake.check.sh"
  assert_grep "$addon/bin/fm-channel-intake.sh" "$shim" 'the add-on armed a check that does not name its own script'
  before=$(cat "$shim")
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0900" "$addon/bin/fm-morning-intake.sh" run >/dev/null
  out=$(FM_HOME="$h" FM_CHANNEL_INTAKE_NOW="$T_0900" FM_MORNING_INTAKE_NOW="$T_0900" \
    "$ROOT/bin/fm-addon.sh" run bootstrap 2>&1)
  assert_contains "$out" "take them with $addon/bin/fm-channel-intake.sh claim" \
    'the channel intake line did not come from the add-on copy'
  assert_contains "$out" "$addon/bin/fm-morning-intake.sh" 'the morning intake line did not come from the add-on copy'
  assert_not_contains "$out" "$ROOT/bin/fm-" 'a built-in intake script ran beside the add-on copy'
  [ "$(cat "$shim")" = "$before" ] || fail 'a session start re-armed the add-on check onto another script'

  # Skills: the add-on's copies are linked in place of the opt-in ones, which
  # come back when the add-on goes.
  checkout="$h/checkout"
  mkdir -p "$checkout/.agents/skills"
  git init -q "$checkout"
  cp -R "$ROOT/.agents/opt-in-skills" "$checkout/.agents/opt-in-skills"
  FM_HOME="$h" "$ROOT/bin/fm-opt-in-skills.sh" sync "$checkout"
  for entry in intake-digest-lines daily-todo-freshness; do
    assert_equals "$addon/.agents/skills/$entry" "$(readlink "$checkout/.agents/skills/$entry")" \
      "the add-on $entry skill is not the one linked"
  done
  rm "$h/config/addon"
  FM_HOME="$h" "$ROOT/bin/fm-opt-in-skills.sh" sync "$checkout"
  assert_equals '../opt-in-skills/intake-digest-lines' "$(readlink "$checkout/.agents/skills/intake-digest-lines")" \
    'the built-in skill did not come back once the add-on went'
  pass 'a home whose add-on still carries the intake runs the add-on hooks, scripts, armed check and skills'
}

test_inert_without_opt_in
test_new_ask_appears_once_and_unchanged_polls_are_silent
test_edit_updates_the_same_item
test_captain_response_clears_and_never_reopens
test_interrupted_read_retries_without_data_loss
test_sleep_gap_is_caught_up_from_the_checkpoint
test_no_poll_loop_can_run_away
test_cross_source_duplicate_stays_one_item
test_notifications_are_private_verified_grouped_and_capped
test_quiet_hours_defer_but_preserve_real_severity
test_nothing_reaches_the_action_deck
test_brief_and_todo_reconcile_from_one_ledger
test_thread_replies_are_tracked_and_the_limit_is_disclosed
test_per_poll_work_is_bounded_without_losing_anything
test_ledger_writes_are_serialized
test_no_existing_fleet_is_overridden
test_local_configuration_stays_private
test_arm_check_leaves_no_unregistered_shim
test_check_signals_once_per_state
test_a_held_alert_with_nothing_due_wakes_once_per_state
test_a_held_alert_does_not_become_a_wake_loop
test_a_replaced_alert_still_wakes_the_primary
test_blocked_notifications_are_visible_rather_than_silent
test_only_a_requested_render_opens_the_page
test_unresolvable_timezone_is_refused
test_equal_quiet_bounds_are_refused
test_scan_window_bounds_the_reads
test_both_schedules_share_one_launchd_writer
test_install_and_uninstall_on_a_temp_home
test_bootstrap_surfaces_the_intake
test_an_addon_copy_of_the_intake_keeps_running
test_team_announcements_are_information_not_asks
test_new_source_kinds_get_their_own_reads
test_observe_and_resolve_refuse_what_rots_the_page

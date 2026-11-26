#!/usr/bin/env bash
# Behavior tests for the daily to-do's durable item store.
#
# Contracts under test, each through bin/fm-todo.sh and the rendered page:
#   - Verification is its own fact: an unchanged re-read and a re-sync never
#     renew it, a sweep downgrades an older check to "not re-checked since",
#     and an explicit verify makes the line current again.
#   - A page command is durable: `done` survives repeated syncs, the next
#     morning and a re-asserted sidecar, and a meaningful new ask resurfaces
#     exactly once with its reason.
#   - An edit after a ledger resolution (edited_digest) reopens the item once.
#   - A stale page revision is refused, a repeated command is harmless, and
#     `you` stays a requested handoff until firstmate accepts it.
#   - Missing or corrupt input closes nothing; a released hold closes only its
#     own item; one ask seen twice is one item, two asks stay two.
#   - A snooze ends on its day without claiming a fresh check.
#   - Only a named, fulfilled close counts as handled without you.
#   - `reopen` brings a handed-over item back to the captain's lane and
#     refuses an item that is already open.
#   - Captain holds no read made current stay in the store and off the page.
#   - Routine activity older than the sweep stays on the page in the same
#     labelled "not re-checked" fold, capped at ten rows.
#   - A routine item the ledger no longer carries closes as superseded without
#     reaching the Closed today evidence, and an unreadable ledger closes nothing.
#   - Sync prunes a retired routine record thirty days on, and nothing else:
#     a command tombstone and a closed obligation both survive it.
#   - A routine line the captain marked with mine or park is never retired by
#     the intake's absence, so it is never pruned either. A system reopen note
#     is not such a mark: a revived routine thread still retires and prunes.
#   - A partner-facing ask awaiting the captain ranks in the second tier of
#     the Needs you list, after a live outage and above older partner and
#     customer asks, deadlines, calendar meetings and every other class, oldest
#     ask first and an undated ask last; the 13 Oct page opens with its two
#     awaiting partners.
#   - Every Needs you row names the system it came from beside its severity
#     pill, and an unrecognised source gets a neutral marker instead of failing.
#   - A row merged from several inputs marks the source it presents, not the
#     input that happened to see it first.
#   - A morning action whose end time has passed closes on render as
#     superseded by auto-expiry and shows under Closed today; a future or
#     missing end time stays open, a reopened expired item stays open, and an
#     end time moved later or a re-listing with no end time brings an expired
#     item back. A UTC end time written with Z expires the same way, and a
#     line the captain marked never expires until a park on it lapses.
#   - A claim lists every open item with a source to re-check, `complete`
#     counts the ones the pass skipped, a pass raises the freshness floor
#     only for items it can re-read and never moves the closed boundary, and a
#     close under one of the captain_names counts as the captain's own.
#   - Needs you ranks partners and customers from the source (an observe
#     --partner mark, a morning partner flag, an awaiting partner) oldest ask
#     first, folds Firstmate-sourced or tooling approvals below them, and keeps
#     a mine line out of the ranked list.
#   - A captain-held backlog decision sits in the tooling fold unless the home
#     sets held_decisions_need_you, which puts it in Needs you now while a
#     tooling approval keeps its fold; a value other than true or false is
#     refused by the renderer and the intake gate.
#   - Stored titles lose relative times but keep a deadline or duration the
#     ask is about, the page computes ages in calendar days, and the coverage
#     fold names what no source reads.
#   - An add-on extends the store without a copy of it: a `todo-verbs` hook
#     takes a line typed on a row that no built-in verb takes, never an
#     untargeted line or one typed against an older revision, the first hook
#     that answers takes it and a refusal fails the run, and `mark` puts the
#     add-on's own line on the row until it clears it, without changing the
#     item's state, revision or freshness.
#   - `hand-over` moves an open ledger or morning item to waiting on a named
#     owner with its note, and refuses a closed item, an empty name, the
#     captain's own name and a stale revision.
#   - The source change an add-on records on `close` or `hand-over` does not
#     reopen the item when its next pass observes it; any later, different
#     revision does, and a hand-over with no recorded change comes back on any
#     source change. Neither a closed nor a handed-over item reopens when its
#     source resolves or parks it in the same tick, and a later edit still
#     reopens it.
#   - A ledger ask observed with --partner-awaiting-since ranks in the same
#     partner-awaiting tier as a morning one, oldest first.
#   - A helpdesk add-on's waiting, reassign and close ticket verbs run on that
#     contract alone: its own ticket changes never reopen the row, and a later
#     partner reply does.
#   - The Today list keeps the captain's order through add, first, move and
#     done, never lists his own lines for a source re-check, and carries its
#     unfinished lines over to the next day in the same order.
#   - An info or update line closes as quiet after 14 days with no new message,
#     never a colleague ask, a customer-facing or Today line, is not counted as
#     closed on the front page, comes back when its source changes, and a hand
#     reopen starts its 14 days again.
#   - The front page shows at most three "Needs you now" lines picked by the
#     rules (a customer machine down, then due today, then the longest partner
#     wait past one working day), the Today list, partners then colleagues
#     waiting, later this week, one count line each for unchecked lines and
#     held questions, and a link to the back room, which keeps every line.
#   - The front page heads the non-partner asks "Waiting on you" and never
#     names colleagues, unless the home sets colleague_headings, which brings
#     back "Colleagues asking you" without changing the back room; a value
#     other than true or false is refused by the renderer and the intake gate.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TODO="$ROOT/bin/fm-todo.sh"
RENDER="$ROOT/bin/fm-todo-render.sh"
INTAKE="$ROOT/bin/fm-channel-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600
T_1000=1789027200
T_1030=1789029000
T_1100=1789030800
T_1500=1789045200
T_NEXT_0900=$((T_0900 + 86400))
T_NEXT_1000=$((T_1000 + 86400))

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/data/channel-intake" "$h/.lavish"
  printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\n' >"$h/config/channel-intake"
  printf 'C_BRIEF\tslack-channel\tdaily brief channel\n' >"$h/data/channel-intake/sources.tsv"
  : >"$h/backlog.md"
}

intake_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"
}

todo_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$TODO" "$@"
}

render_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$RENDER" render "$@" >/dev/null
}

page() {
  cat "$1/.lavish/today-$2-all.html"
}

# The id, state or revision of the one item whose title contains $2.
field_of() {
  local h=$1 title=$2 col=$3
  todo_at "$h" "$T_1500" list | awk -F '\t' -v t="$title" -v c="$col" 'index($5, t) { print $c; exit }'
}

# The titles of the Needs you now list, in the order the page shows them.
needs_order() {
  sed -n '/<h2>Needs you now/,/<\/table>/p' <<<"$1" | grep -o 'class="what">[^<]*' | sed 's/^class="what">//'
}

sidecar() {
  local h=$1 day=$2 body=$3
  printf '{"version":2,"date":"%s","actions":[%s]}\n' "$day" "$body" >"$h/.lavish/today-$day.morning.json"
}

test_a_retired_ledger_record_closes_its_routine_item() {
  local h drop out
  h="$TMP_ROOT/retired"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref keep --digest a --title 'channel stayed chatty' >/dev/null
  drop=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref gone --digest b --title 'yesterday small talk' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  [ "$(field_of "$h" 'small talk' 2)" = open ] || fail 'a routine record did not fold in as an open item'
  # What the intake does once a routine record passes its brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$drop" "$h/data/channel-intake/inactive/$drop"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'small talk' 2)" = closed ] || fail 'a retired routine record left its item open forever'
  [ "$(field_of "$h" 'stayed chatty' 2)" = open ] || fail 'retiring one record closed another'
  out=$(page "$h" 2026-09-10)
  assert_contains "$(grep -h . "$h/data/todo/items/"*.json)" '"reason": "superseded"' \
    'the retirement closure is not labelled superseded'
  assert_not_contains "$out" 'yesterday small talk' 'a retired routine line still renders on the page'
  # Routine chatter the intake dropped was never an ask, so it is not a closure to show.
  assert_not_contains "$out" 'the intake retired it as routine' 'a retirement reached the Closed today evidence table'
  assert_not_contains "$out" '<summary>Closed today' 'a retirement was counted as something closed for you'
  # An unreadable ledger is not an absence: it closes nothing.
  mv "$h/data/channel-intake" "$h/intake.away"
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'stayed chatty' 2)" = open ] || fail 'a missing ledger closed a live item'
  mv "$h/intake.away" "$h/data/channel-intake"
  [ "$(grep -c '"reason": "superseded"' "$h/data/todo/journal")" = 1 ] || fail 'the retirement closed more than once'
  pass 'a retired routine record closes its item as superseded and an unreadable ledger closes nothing'
}

test_routine_fold_is_capped() {
  local h out n i
  h="$TMP_ROOT/chatter"
  new_home "$h"
  i=1
  while [ "$i" -le 12 ]; do
    intake_at "$h" "$T_0900" observe --source C_BRIEF --ref "chat-$i" --digest "d$i" \
      --title "channel chatter $(printf '%02d' "$i")" >/dev/null
    i=$((i + 1))
  done
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<summary>12 not re-checked in this build, oldest 10 shown</summary>' \
    'the capped fold still claims every line shows its last check'
  assert_contains "$out" '2 more not re-checked, not shown here.' 'the routine fold is not capped with a count of the rest'
  n=$(printf '%s\n' "$out" | grep -c '<td class="what">channel chatter')
  [ "$n" = 10 ] || fail "the routine fold rendered $n rows, not ten"
  pass 'the routine not re-checked fold is capped at ten rows and a count of the rest'
}

test_sync_prunes_only_retired_routine_records() {
  local h chatter gone kept
  h="$TMP_ROOT/prune"
  new_home "$h"
  chatter=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref chat --digest a --title 'old channel chatter' | awk '{ print $2 }')
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref ask --digest b --class urgent --title 'dealer needs an answer' >/dev/null
  render_at "$h" "$T_0900"
  kept=$(field_of "$h" 'dealer needs' 1)
  todo_at "$h" "$T_0900" command --item "$kept" 'done' >/dev/null
  # What the intake does once a routine record passes its brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$chatter" "$h/data/channel-intake/inactive/$chatter"
  render_at "$h" "$T_1000"
  gone=$(field_of "$h" 'old channel chatter' 1)
  [ -n "$gone" ] || fail 'the retired record never became an item'
  # A day short of the retention the record is still queryable.
  render_at "$h" "$((T_1000 + 29 * 86400))"
  [ "$(field_of "$h" 'old channel chatter' 2)" = closed ] || fail 'a retired record was pruned before its retention'
  render_at "$h" "$((T_1000 + 31 * 86400))"
  [ -z "$(field_of "$h" 'old channel chatter' 2)" ] || fail 'a retired routine record outlived its retention'
  [ ! -f "$h/data/todo/items/$gone.json" ] || fail 'the pruned record is still on disk'
  # Everything that was ever an ask survives, so done keeps suppressing a reopen.
  [ "$(field_of "$h" 'dealer needs' 2)" = closed ] || fail 'a command tombstone was pruned with the chatter'
  [ "$(grep -c '"reason": "superseded"' "$h/data/todo/journal")" = 1 ] || fail 'pruning trimmed the journal'
  pass 'sync prunes a retired routine record after thirty days and keeps every ask it ever tracked'
}

test_a_marked_routine_line_is_never_retired_by_the_intake() {
  local h claimed parked loose mine_id park_id out
  h="$TMP_ROOT/marked"
  new_home "$h"
  claimed=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref mark --digest a --title 'supplier posted a price list' | awk '{ print $2 }')
  parked=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref park --digest b --title 'shipping notice for week 38' | awk '{ print $2 }')
  loose=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref loose --digest c --title 'nobody claimed this one' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  mine_id=$(field_of "$h" 'price list' 1)
  park_id=$(field_of "$h" 'shipping notice' 1)
  todo_at "$h" "$T_0900" command --item "$mine_id" 'mine' >/dev/null
  todo_at "$h" "$T_0900" command --item "$park_id" 'park til tomorrow' >/dev/null
  # The intake retires all three once they pass the brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$claimed" "$h/data/channel-intake/inactive/$claimed"
  mv "$h/data/channel-intake/items/$parked" "$h/data/channel-intake/inactive/$parked"
  mv "$h/data/channel-intake/items/$loose" "$h/data/channel-intake/inactive/$loose"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'nobody claimed' 2)" = closed ] || fail 'an unmarked routine record was not retired'
  [ "$(field_of "$h" 'price list' 2)" = open ] || fail 'a routine line the captain claimed was auto-closed'
  [ "$(field_of "$h" 'shipping notice' 2)" = open ] || fail 'a routine line the captain parked was auto-closed'
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'supplier posted a price list' 'the claimed line vanished from the page'
  assert_contains "$out" 'shipping notice for week 38' 'the parked line vanished from the page'
  # Never auto-closed means never pruned, however long the ledger stays silent.
  render_at "$h" "$((T_1000 + 31 * 86400))"
  [ -f "$h/data/todo/items/$mine_id.json" ] || fail 'the claimed line was pruned'
  [ -f "$h/data/todo/items/$park_id.json" ] || fail 'the parked line was pruned'
  [ "$(field_of "$h" 'price list' 2)" = open ] || fail 'the claimed line closed once its park had passed'
  pass 'a routine line the captain marked is never retired by the intake, nor pruned'
}

test_a_revived_routine_thread_still_retires_and_prunes() {
  local h key id
  h="$TMP_ROOT/revived"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref thread --digest a --title 'weekly ops thread' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'weekly ops thread' 1)
  # Quiet past the brief horizon, so the intake retires it.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$key" "$h/data/channel-intake/inactive/$key"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = closed ] || fail 'the quiet thread was not retired'
  # A later message on the same ref restores the record, and the item reopens
  # with a system note. That note is the system's, not a mark the captain made.
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref thread --digest b --title 'weekly ops thread' >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = open ] || fail 'a revived routine record did not reopen its item'
  assert_contains "$(page "$h" 2026-09-10)" 'reopened' 'the reopen left no note on the line'
  # Quiet again: a reopen note must not exempt it from retirement forever.
  mv "$h/data/channel-intake/items/$key" "$h/data/channel-intake/inactive/$key"
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = closed ] || fail 'a reopen note exempted a routine line from retirement'
  render_at "$h" "$((T_1500 + 31 * 86400))"
  [ -z "$(field_of "$h" 'weekly ops thread' 2)" ] || fail 'the revived thread outlived its retention'
  [ ! -f "$h/data/todo/items/$id.json" ] || fail 'the revived thread was never pruned'
  pass 'a reopen note is not a captain mark: a revived routine thread still retires and prunes'
}

test_verification_is_never_renewed_by_sync() {
  local h out
  h="$TMP_ROOT/verification"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref v1 --digest a --class urgent --title 'dealer quote' >/dev/null
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  # An unchanged re-read after the sweep does not renew the 09:00 check.
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref v1 --digest a --class urgent --title 'dealer quote' >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'dealer quote<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a check older than the sweep was shown as current'
  todo_at "$h" "$T_1030" verify --item "$(field_of "$h" 'dealer quote' 1)" --how 'Slack thread read directly' >/dev/null
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'dealer quote<span class="prov obs">read 10:30 CEST</span>' 'an explicit verify was not recorded'
  assert_contains "$out" 'data-how="Slack thread read directly"' 'the verification method is not kept on the line for audit'
  # A later render never moves the check forward on its own.
  render_at "$h" "$T_1500"
  assert_contains "$(page "$h" 2026-09-10)" 'read 10:30 CEST' 'a re-render renewed the verification time'
  # A new day without a new read is not current.
  render_at "$h" "$T_NEXT_0900"
  assert_contains "$(page "$h" 2026-09-11)" 'not re-checked since Thu 10 Sep 10:30 CEST' \
    'yesterday'"'"'s check was treated as current today'
  pass 'verification changes only on a source read or an explicit verify, never on a sync or render'
}

test_done_survives_and_a_new_ask_resurfaces_once() {
  local h id out reopens
  h="$TMP_ROOT/done"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"k-0910","source":"firstmate-backlog","ref":"litware","class":"urgent","title":"Litware firmware call","digest":"ask-1","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  id=$(field_of "$h" 'Litware' 1)
  out=$(todo_at "$h" "$T_1000" command --item "$id" 'done')
  assert_contains "$out" "TODO_CMD: done $id" 'done was not applied'
  render_at "$h" "$T_1100"
  render_at "$h" "$T_1500"
  # Next morning the sidecar re-asserts the same ask with a new key and wording.
  sidecar "$h" 2026-09-11 '{"key":"k-0911","source":"firstmate-backlog","ref":"litware","class":"urgent","title":"Litware: still the firmware call","digest":"ask-1","updated":'"$T_NEXT_0900"'}'
  render_at "$h" "$T_NEXT_0900"
  [ "$(field_of "$h" 'Litware' 2)" = closed ] || fail 'done did not survive the next morning'
  assert_not_contains "$(page "$h" 2026-09-11)" 'id="item-'"$id"'"' 'a done item came back on the page'
  # A meaningful change of the ask reopens it once, with the reason shown.
  sidecar "$h" 2026-09-11 '{"key":"k-0911","source":"firstmate-backlog","ref":"litware","class":"urgent","title":"Litware: now a thermostat call","digest":"ask-2","updated":'"$T_NEXT_0900"'}'
  render_at "$h" "$T_NEXT_1000"
  render_at "$h" "$T_NEXT_1000"
  out=$(page "$h" 2026-09-11)
  [ "$(field_of "$h" 'Litware' 2)" = open ] || fail 'a changed ask did not reopen'
  assert_contains "$out" 'reopened: its source changed after it was closed (fulfilled)' 'the reopen reason is missing'
  reopens=$(grep -c '"to": "open"' "$h/data/todo/journal")
  [ "$reopens" = 1 ] || fail "the item reopened $reopens times, not once"
  pass 'done survives repeated syncs and the next morning; a changed ask resurfaces once with its reason'
}

test_a_sweep_reopen_hides_its_source_label() {
  local h id key out
  h="$TMP_ROOT/reopen-label"
  new_home "$h"
  # The ledger slot presents the item as "slack-channel (C_BRIEF)"; the
  # morning slot that reopens it carries the bare "C_BRIEF" label.
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref rl --digest a --class urgent --title 'pallet delivery slot' | awk '{ print $2 }')
  sidecar "$h" 2026-09-10 '{"key":"'"$key"'","source":"C_BRIEF","ref":"rl","class":"urgent","title":"pallet delivery slot","digest":"ask-1","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  id=$(field_of "$h" 'pallet delivery slot' 1)
  todo_at "$h" "$T_1000" command --item "$id" 'done' >/dev/null
  render_at "$h" "$T_1100"
  sidecar "$h" 2026-09-10 '{"key":"'"$key"'","source":"C_BRIEF","ref":"rl","class":"urgent","title":"pallet delivery slot","digest":"ask-2","updated":'"$T_1100"'}'
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'pallet delivery slot' 2)" = open ] || fail 'a changed sweep ask did not reopen'
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'reopened: its source changed after it was closed (fulfilled)' 'the reopen reason is missing'
  assert_not_contains "$out" 'reopened: C_BRIEF' 'the reopening slot label is shown on the line'
  # A manual reopen reason is shown as written, even where it mentions a label.
  todo_at "$h" "$T_1500" close --item "$id" --evidence 'slot confirmed' --actor Nora >/dev/null
  todo_at "$h" "$T_1500" reopen --item "$id" --reason 'reopened at the dock after C_BRIEF-ops asked again' >/dev/null
  render_at "$h" "$T_1500"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'reopened at the dock after C_BRIEF-ops asked again' 'a manual reopen reason was rewritten'
  assert_not_contains "$out" 'reopened at its source' 'a manual reopen was credited to a source'
  pass 'a reopen by any of its slots hides the source label, and a manual reason is shown as written'
}

test_edit_after_resolution_reopens_once() {
  local h key
  h="$TMP_ROOT/edited"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref e1 --digest a --class urgent --title 'invoice dispute' | awk '{ print $2 }')
  intake_at "$h" "$T_1000" resolve --item "$key" --reason 'credit note sent' >/dev/null
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'invoice dispute' 2)" = closed ] || fail 'a ledger resolution did not close the item'
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref e1 --digest b --class urgent --title 'invoice dispute' >/dev/null
  render_at "$h" "$T_1100"
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'invoice dispute' 2)" = open ] || fail 'an edit after resolution did not reopen the item'
  [ "$(grep -c '"to": "open"' "$h/data/todo/journal")" = 1 ] || fail 'the archived resolution re-closed or re-reopened the item'
  pass 'an edit after a ledger resolution reopens the item once and the old resolution does not re-close it'
}

test_commands_refuse_stale_pages_and_track_handoffs() {
  local h id rev out code
  h="$TMP_ROOT/commands"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref c1 --digest a --class urgent --title 'Northwind restore' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'Northwind' 1)
  rev=$(field_of "$h" 'Northwind' 4)
  assert_contains "$(page "$h" 2026-09-10)" "rev:&quot;$rev&quot;" 'the page does not carry the revision it shows'
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref c1 --digest b --class urgent --title 'Northwind restore' >/dev/null
  render_at "$h" "$T_1000"
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'drop') && code=0 || code=$?
  expect_code 1 "$code" 'a command from a stale page was applied'
  assert_contains "$out" 'refresh the page first' 'the stale refusal does not say why'
  [ "$(field_of "$h" 'Northwind' 2)" = open ] || fail 'a refused command changed the item'
  rev=$(field_of "$h" 'Northwind' 4)
  todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'you: ask Quinn for the three facts' >/dev/null
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'you: ask Quinn for the three facts')
  assert_contains "$out" 'TODO_CMD: already you' 'a repeated command was not idempotent'
  render_at "$h" "$T_1030"
  assert_contains "$(page "$h" 2026-09-10)" 'handoff requested, not yet accepted: ask Quinn for the three facts' \
    'a requested handoff was not shown as pending'
  todo_at "$h" "$T_1030" ack --item "$id" >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'Northwind' 2)" = waiting ] || fail 'an accepted handoff did not move to waiting'
  assert_contains "$(page "$h" 2026-09-10)" 'firstmate has it: ask Quinn for the three facts' 'the accepted owner is not shown'
  out=$(todo_at "$h" "$T_1100" command 'mine' 'no verb here') && code=0 || code=$?
  expect_code 1 "$code" 'a verb with no matching words was not refused'
  assert_contains "$out" 'TODO_CMD: not-a-command no verb here' 'a plain line was treated as a command'
  pass 'stale pages are refused, repeats are harmless, and a handoff stays requested until accepted'
}

test_missing_input_closes_nothing_and_release_is_scoped() {
  local h
  h="$TMP_ROOT/inputs"
  new_home "$h"
  cat >"$h/backlog.md" <<'MD'
## Queued
- [ ] fleet-a - Approve reads on unit A (since 2026-09-01) (hold: needs the captain's go (reads, not pushes)) (hold-kind: captain)
- [ ] fleet-b - Approve reads on unit B (since 2026-09-01) (hold: needs the captain's go) (hold-kind: captain)
- [ ] plain - Ordinary queued work (since 2026-09-01)
MD
  render_at "$h" "$T_0900"
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'a captain hold was not folded in'
  # A hold is never a read, so an unverified hold stays off the page.
  assert_not_contains "$(page "$h" 2026-09-10)" 'Approve reads on unit A' 'an unverified backlog hold reached the page'
  assert_not_contains "$(page "$h" 2026-09-10)" 'Ordinary queued work' 'an unheld task reached the page'
  todo_at "$h" "$T_0900" verify --item "$(field_of "$h" 'unit A' 1)" --how 'backlog hold re-read' >/dev/null
  render_at "$h" "$T_0900"
  assert_contains "$(page "$h" 2026-09-10)" 'needs the captain&#x27;s go (reads, not pushes)' 'the nested hold reason was cut'
  mv "$h/backlog.md" "$h/backlog.moved"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'a missing backlog closed a held item'
  grep -v fleet-b "$h/backlog.moved" >"$h/backlog.md"
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'unit B' 2)" = closed ] || fail 'a released hold did not close its item'
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'releasing one hold closed another'
  assert_contains "$(page "$h" 2026-09-10)" 'no longer held for you in the backlog' 'the release evidence is missing'
  cp -R "$h/data/todo" "$h/todo.before"
  printf '{broken' >"$h/.lavish/today-2026-09-10.morning.json"
  if render_at "$h" "$T_1500" 2>/dev/null; then fail 'a corrupt sidecar was accepted'; fi
  diff -r "$h/data/todo/items" "$h/todo.before/items" >/dev/null || fail 'a refused sync changed the store'
  pass 'missing or corrupt input closes nothing and a released hold closes only its own item'
}

test_identity_snooze_and_counter() {
  local h out id key
  h="$TMP_ROOT/identity"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref t1 --digest a --class urgent --title 'ticket ask one' | awk '{ print $2 }')
  sidecar "$h" 2026-09-10 '{"key":"'"$key"'","source":"C_BRIEF","ref":"t1","class":"urgent","title":"same ask from the sweep","updated":'"$T_0900"'},{"key":"second","source":"C_BRIEF","ref":"t1-b","class":"urgent","title":"ticket ask two","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  [ "$(todo_at "$h" "$T_1000" list | wc -l | tr -d ' ')" = 2 ] || fail 'one ask seen twice was not one item, or two asks merged'
  id=$(field_of "$h" 'ticket ask two' 1)
  todo_at "$h" "$T_1000" command --item "$id" 'park til tomorrow' >/dev/null
  render_at "$h" "$T_1030"
  assert_contains "$(page "$h" 2026-09-10)" 'back on 2026-09-11' 'a parked item is not listed with its date'
  render_at "$h" "$T_NEXT_0900"
  out=$(page "$h" 2026-09-11)
  assert_contains "$out" 'ticket ask two<span class="prov unv">not re-checked since' 'a snooze expiry claimed a fresh check'
  todo_at "$h" "$T_NEXT_0900" close --item "$(field_of "$h" 'ticket ask one' 1)" --evidence 'Nora answered the dealer' --actor Nora >/dev/null
  todo_at "$h" "$T_NEXT_0900" command --item "$id" 'drop' >/dev/null
  render_at "$h" "$T_NEXT_1000"
  out=$(page "$h" 2026-09-11)
  assert_contains "$out" '<summary>Closed today (2, 1 handled without you)</summary>' \
    'the closed count or the named fulfilled close is wrong'
  assert_contains "$out" 'fulfilled by Nora' 'the closing actor is not shown'
  assert_contains "$out" 'dismissed by you' 'a dismissal was not labelled as one'
  pass 'one ask seen twice dedupes, a snooze returns unverified, and only a named fulfilled close counts'
}

test_reopen_returns_a_handed_over_item_to_the_captain() {
  local h id out code
  h="$TMP_ROOT/reopen"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r1 --digest a --class urgent --title 'Quinn rollout sign-off' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'Quinn' 1)
  todo_at "$h" "$T_0900" command --item "$id" 'you: ask Quinn for the three facts' >/dev/null
  todo_at "$h" "$T_0900" ack --item "$id" >/dev/null
  [ "$(field_of "$h" 'Quinn' 2)" = waiting ] || fail 'an accepted handoff did not move to waiting'
  out=$(todo_at "$h" "$T_1000" reopen --item "$id" --reason 'Quinn bounced it back to you')
  assert_contains "$out" "reopen $id -> open" 'reopen left a handed-over item where it was'
  [ "$(field_of "$h" 'Quinn' 2)" = open ] || fail 'a waiting item did not come back to the captain lane'
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'Quinn bounced it back to you' 'the reopen reason is not on the line'
  assert_not_contains "$out" 'firstmate has it' 'the hand-over survived the reopen'
  out=$(todo_at "$h" "$T_1000" reopen --item "$id" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'reopening an already open item was a silent no-op'
  assert_contains "$out" 'is already open' 'the refusal does not say why'
  pass 'reopen brings a handed-over item back to the captain and refuses one already open'
}

test_unverified_holds_stay_off_the_page() {
  local h out n
  h="$TMP_ROOT/held"
  new_home "$h"
  printf '## Queued\n' >"$h/backlog.md"
  n=1
  while [ "$n" -le 12 ]; do
    printf -- '- [ ] hold-%02d - Approve change %02d (since 2026-09-01) (hold: needs the captain) (hold-kind: captain)\n' \
      "$n" "$n" >>"$h/backlog.md"
    n=$((n + 1))
  done
  sidecar "$h" 2026-09-10 '{"key":"k-live","source":"C_BRIEF","ref":"live-1","class":"urgent","title":"Sign the Litware quote","updated":'"$T_1000"'}'
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  [ "$(todo_at "$h" "$T_1030" list --state open | grep -c 'Approve change')" = 12 ] || fail 'the holds did not fold into the store'
  assert_contains "$out" 'Sign the Litware quote<span class="prov obs">' 'the decision read today is not on the page'
  assert_not_contains "$out" 'Approve change' 'a hold nobody re-checked reached the page'
  assert_not_contains "$out" 'held, not re-checked' 'the page still counts holds nobody re-checked'
  assert_not_contains "$out" 'Held decisions' 'the page still has a held-decisions section'
  pass 'captain holds nobody re-checked stay in the store and off the page'
}

test_routine_activity_keeps_its_not_re_checked_fold() {
  local h out
  h="$TMP_ROOT/activity"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n1 --digest a --title 'weekly partner newsletter' >/dev/null
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref n2 --digest b --title 'new partner joined the channel' >/dev/null
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<summary>Other channel activity</summary>' 'the routine activity fold is missing'
  assert_contains "$out" 'new partner joined the channel<span class="prov obs">read 10:30 CEST</span>' \
    'a routine line read after the sweep is not shown as current'
  assert_contains "$out" 'weekly partner newsletter<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a routine line older than the sweep vanished from the page'
  assert_contains "$out" '<summary>1 not re-checked in this build - each shows its last check</summary>' \
    'stale routine activity is not in the labelled fold the sections use'
  pass 'routine activity older than the sweep stays on the page in its own not re-checked fold'
}

test_partner_awaiting_asks_rank_above_every_class() {
  local h out now first syrup
  h="$TMP_ROOT/partner-first"
  new_home "$h"
  # A partner waiting thirteen days on a steer, as the morning sweep flagged it.
  syrup='{"key":"k-s","source":"helpdesk","ref":"90000000011","class":"obligation","kind":"reply","title":"Syrup availability and connectivity","why":"the partner is waiting on your steer","partner_awaiting":true,"awaiting_since":'"$((T_0900 - 86400 * 13))"',"updated":'"$T_1030"'}'
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  for now in outage-1 urgent-1 urgent-2 deadline-1; do
    intake_at "$h" "$T_1030" observe --source C_BRIEF --ref "$now" --digest "$now" --class "${now%-*}" \
      --title "fresh $now" >/dev/null
  done
  sidecar "$h" 2026-09-10 "$syrup"
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  # A live outage leads; the awaiting partner ask comes next, above the
  # deadline and urgent asks, and its row says why the partner is waiting.
  [ "$(needs_order "$out" | sed -n 1,3p)" = 'fresh outage-1
Syrup availability and connectivity
fresh deadline-1' ] && [ "$(needs_order "$out" | sed -n 4,5p | sort | tr '\n' ' ')" = 'fresh urgent-1 fresh urgent-2 ' ] || fail "the awaiting partner ask is not second tier in Needs you:
$(needs_order "$out")"
  first=$(grep -m1 'class="what">Syrup' <<<"$out")
  assert_contains "$first" 'the partner is waiting on your steer' 'the row does not say why the partner is waiting'
  assert_contains "$out" 'Syrup availability and connectivity<span class="prov obs">read 10:30 CEST</span>' \
    'the morning read did not make the line current'
  # A second awaiting partner ranks in the partner tier, after the outages,
  # oldest ask first.
  sidecar "$h" 2026-09-10 "$syrup"',{"key":"k-out","source":"C_BRIEF","ref":"m-out","class":"outage","title":"Morning outage","updated":'"$T_1030"'},{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":true,"awaiting_since":'"$((T_0900 - 3600))"',"updated":'"$T_1030"'}'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(needs_order "$out" | sed -n 3,4p)" = 'Syrup availability and connectivity
Morning partner ask' ] || fail "a morning partner ask is not in the partner tier after the live problems:
$(needs_order "$out")"
  # A calendar meeting ending today is a deadline, not a partner ask: the older
  # awaiting partner reply ranks above it, and the outage still leads.
  sidecar "$h" 2026-09-10 "$syrup"',{"key":"k-out","source":"C_BRIEF","ref":"m-out","class":"outage","title":"Morning outage","updated":'"$T_1030"'},{"key":"k-cal","source":"calendar","ref":"rma","class":"deadline","title":"RMA process meeting","ends_at":"2026-09-10T15:30:00+02:00","updated":'"$T_1030"'},{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":true,"awaiting_since":'"$((T_0900 - 86400 * 3))"',"updated":'"$T_1030"'}'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(needs_order "$out" | grep -n -x -e 'Morning outage' -e 'fresh outage-1' -e 'Morning partner ask' -e 'RMA process meeting' | cut -d: -f2 | tr '\n' '|')" = 'fresh outage-1|Morning outage|Morning partner ask|RMA process meeting|' ] \
    || fail "a calendar meeting ending today ranks above an older awaiting partner reply, or the outage does not lead:
$(needs_order "$out")"
  # An undated partner ask is not the oldest ask: it sorts after the dated one.
  sidecar "$h" 2026-09-10 "$syrup"',{"key":"k-out","source":"C_BRIEF","ref":"m-out","class":"outage","title":"Morning outage","updated":'"$T_1030"'},{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":true,"updated":'"$T_1030"'}'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(needs_order "$out" | sed -n 3,4p)" = 'Syrup availability and connectivity
Morning partner ask' ] || fail 'an undated partner ask jumped ahead of an older dated one'
  # A sidecar that spells the flag as a string would silently rank the ask like
  # any other item, so it is refused the way a bad class already is.
  cp -R "$h/data/todo" "$h/todo.before"
  sidecar "$h" 2026-09-10 '{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":"true","awaiting_since":'"$T_0900"',"updated":'"$T_1030"'}'
  if render_at "$h" "$T_1100" 2>/dev/null; then fail 'a sidecar whose partner_awaiting is a string was accepted'; fi
  sidecar "$h" 2026-09-10 '{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":true,"awaiting_since":"2026-09-10","updated":'"$T_1030"'}'
  if render_at "$h" "$T_1100" 2>/dev/null; then fail 'a sidecar whose awaiting_since is a date was accepted'; fi
  sidecar "$h" 2026-09-10 '{"key":"k-p","source":"helpdesk","ref":"90000000014","class":"obligation","kind":"reply","title":"Morning partner ask","partner_awaiting":true,"awaiting_since":'"${T_0900}000"',"updated":'"$T_1030"'}'
  if render_at "$h" "$T_1100" 2>/dev/null; then fail 'a sidecar whose awaiting_since is in milliseconds was accepted'; fi
  diff -r "$h/data/todo/items" "$h/todo.before/items" >/dev/null || fail 'a refused sidecar changed the store'
  pass 'a partner-facing ask awaiting the captain ranks right after a live outage and above deadlines and meetings, oldest first and undated last'
}

test_awaiting_partner_asks_lead_the_13_oct_page() {
  local h out t
  h="$TMP_ROOT/oct-13"
  new_home "$h"
  # Tuesday 13 Oct, 09:00: the morning sweep flagged two partners awaiting
  # Robin (since Fri and Mon), older partner and customer obligations stayed
  # open, and four internal meetings end today.
  t=$((T_0900 + 86400 * 33))
  sidecar "$h" 2026-10-13 \
'{"key":"k-m1","source":"calendar","ref":"breakfast","class":"deadline","title":"Team breakfast","ends_at":"2026-10-13T09:30:00+02:00","updated":'"$t"'},'\
'{"key":"k-m2","source":"calendar","ref":"onboarding","class":"deadline","title":"Onboarding","ends_at":"2026-10-13T13:00:00+02:00","updated":'"$t"'},'\
'{"key":"k-m3","source":"calendar","ref":"one-on-one","class":"deadline","title":"One-on-one","ends_at":"2026-10-13T14:00:00+02:00","updated":'"$t"'},'\
'{"key":"k-m4","source":"calendar","ref":"rma","class":"deadline","title":"RMA process meeting","ends_at":"2026-10-13T15:30:00+02:00","updated":'"$t"'},'\
'{"key":"k-sel","source":"helpdesk","ref":"adatum","class":"obligation","title":"Adatum service visit","partner":true,"asked_at":'"$((t - 86400 * 21))"',"updated":'"$t"'},'\
'{"key":"k-old","source":"helpdesk","ref":"old","class":"obligation","title":"Old customer obligation","partner":true,"asked_at":'"$((t - 86400 * 13))"',"updated":'"$t"'},'\
'{"key":"k-kaf","source":"helpdesk","ref":"proseware","class":"obligation","kind":"reply","title":"Proseware PCB promise","partner_awaiting":true,"awaiting_since":'"$((t - 86400))"',"updated":'"$t"'},'\
'{"key":"k-fabrikam","source":"helpdesk","ref":"fabrikam","class":"obligation","kind":"reply","title":"Fabrikam modem","partner_awaiting":true,"awaiting_since":'"$((t - 86400 * 4))"',"updated":'"$t"'}'
  render_at "$h" "$((t + 600))"
  out=$(page "$h" 2026-10-13)
  # The awaiting partners lead, oldest first, above older partner and
  # customer obligations; the meetings follow them all.
  [ "$(needs_order "$out" | sed -n 1,4p)" = 'Fabrikam modem
Proseware PCB promise
Adatum service visit
Old customer obligation' ] && [ "$(needs_order "$out" | sed -n 5,8p | sort | tr '\n' '|')" = 'Onboarding|One-on-one|RMA process meeting|Team breakfast|' ] \
    || fail "the 13 Oct page does not open with the awaiting partner asks:
$(needs_order "$out")"
  pass 'the 13 Oct page opens with the awaiting partner asks, then older partner lines, then the meetings'
}

test_each_row_marks_where_it_came_from() {
  local h out
  h="$TMP_ROOT/source-marker"
  new_home "$h"
  sidecar "$h" 2026-09-10 \
'{"key":"k-s","source":"slack-robin-mentions","ref":"m1","class":"urgent","title":"Slack line","updated":'"$T_0900"'},'\
'{"key":"k-m","source":"gmail-robin-inbox","ref":"msg-14","class":"obligation","title":"Mail line","updated":'"$T_0900"'},'\
'{"key":"k-b","source":"firstmate-backlog","ref":"litware","class":"obligation","title":"Backlog line","updated":'"$T_0900"'},'\
'{"key":"k-c","source":"captain","ref":"self","class":"obligation","title":"Captain line","updated":'"$T_0900"'},'\
'{"key":"k-u","source":"carrier-pigeon","ref":"coo","class":"obligation","title":"Pigeon line","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  marker_of() {
    grep -F "class=\"what\">$1" <<<"$out" >/dev/null || fail "row $1 is missing"
    grep -B1 -F "class=\"what\">$1" <<<"$out" | grep -o '<span class="src"[^>]*>' | head -n 1
  }
  assert_contains "$(marker_of 'Slack line')" 'title="From Slack"' 'the Slack row does not say it came from Slack'
  assert_contains "$(marker_of 'Mail line')" 'title="From Email"' 'the mail row does not say it came from Email'
  assert_contains "$(marker_of 'Backlog line')" 'title="From Firstmate"' 'the backlog row does not say it came from Firstmate'
  assert_contains "$(marker_of 'Captain line')" 'title="From You"' 'the captain row does not say it came from You'
  assert_contains "$(marker_of 'Pigeon line')" 'title="From carrier-pigeon"' 'the unknown source is not named in its marker title'
  assert_contains "$out" '</svg>Other</span>' 'the unknown source did not get the neutral marker'
  assert_contains "$out" 'data-source="carrier-pigeon"' 'the audit attribute was dropped'
  pass 'each row marks the system it came from, and an unknown source gets a neutral marker'
}

test_a_merged_row_marks_the_source_it_presents() {
  local h key out mark
  h="$TMP_ROOT/source-marker-merged"
  new_home "$h"
  printf 'M_INBOX\tgmail\tmail naming the captain\n' >>"$h/data/channel-intake/sources.tsv"
  # The ledger key is fixed by source and ref, so a scratch intake names it
  # before the real ledger has seen the ticket.
  new_home "$h/scratch"
  cp "$h/data/channel-intake/sources.tsv" "$h/scratch/data/channel-intake/sources.tsv"
  key=$(intake_at "$h/scratch" "$T_0900" observe --source M_INBOX --ref 90000000015 --digest a --class urgent --title 'Merged line' | awk '{ print $2 }')
  # The morning sweep sees it first from a Slack channel; the ledger's
  # mail record folds in later and becomes the presented source.
  sidecar "$h" 2026-09-10 '{"key":"'"$key"'","source":"C0ABCDEFGH","ref":"1789023600.000100","class":"urgent","title":"Merged line","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  intake_at "$h" "$T_1030" observe --source M_INBOX --ref 90000000015 --digest a --class urgent --title 'Merged line' >/dev/null
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(grep -c -F 'class="what">Merged line' <<<"$out")" = 1 ] || fail 'the morning line and the ledger record did not merge into one row'
  assert_contains "$out" 'data-source="gmail (M_INBOX)"' 'the merged row does not present the ledger source'
  mark=$(grep -B1 -F 'class="what">Merged line' <<<"$out" | grep -o '<span class="src"[^>]*>' | head -n 1)
  assert_contains "$mark" 'title="From Email"' 'the merged row marker does not follow its presented source'
  pass 'a row merged from a morning line and a later ledger record marks the source it presents'
}

test_time_bound_asks_expire_after_their_end() {
  local h out id code
  h="$TMP_ROOT/expiry"
  new_home "$h"
  # Ends 10:30 CEST, 11:00 CEST, and no end at all.
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"calendar","ref":"sync","class":"deadline","title":"Woodgrove monthly partner sync","ends_at":"2026-09-10T10:30:00+02:00","updated":'"$T_0900"'},{"key":"m2","source":"calendar","ref":"later","class":"deadline","title":"afternoon supplier call","ends_at":"2026-09-10T15:30:00+02:00","updated":'"$T_0900"'},{"key":"m3","source":"helpdesk","ref":"t9","class":"urgent","title":"dealer invoice reply","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'a meeting closed before its end'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(field_of "$h" 'Woodgrove' 2)" = closed ] || fail 'a meeting past its end stayed open'
  [ "$(field_of "$h" 'supplier call' 2)" = open ] || fail 'a future end time closed its item'
  [ "$(field_of "$h" 'dealer invoice' 2)" = open ] || fail 'an item with no end time was expired'
  assert_not_contains "$(needs_order "$out")" 'Woodgrove' 'an ended meeting is still in Needs you now'
  assert_contains "$out" '<summary>Closed today (1)</summary>' 'the expiry is not under Closed today'
  assert_contains "$out" 'ended at 2026-09-10 10:30 CEST' 'the expiry evidence does not name the end time'
  assert_contains "$out" 'superseded by auto-expiry' 'the expiry is not labelled as automatic'
  # A reopen is deliberate: the same end time never closes it again.
  id=$(field_of "$h" 'Woodgrove' 1)
  todo_at "$h" "$T_1100" reopen --item "$id" --reason 'still running over' >/dev/null
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'a reopened expired item was closed again'
  [ "$(grep -c '"actor": "auto-expiry"' "$h/data/todo/journal")" = 1 ] \
    || fail 'expiry closed an item more than once per end time'
  # A malformed end time refuses the sidecar and changes nothing.
  sidecar "$h" 2026-09-10 '{"key":"m4","source":"calendar","ref":"bad","class":"deadline","title":"zoneless","ends_at":"2026-09-10T10:30:00","updated":'"$T_0900"'}'
  render_at "$h" "$T_1500" 2>/dev/null && code=0 || code=$?
  [ "$code" != 0 ] || fail 'an end time without a zone was accepted'
  pass 'a time-bound ask closes by auto-expiry after its end, and a reopen or a missing end time stays open'
}

test_an_expired_item_comes_back_when_its_end_moves_later() {
  local h
  h="$TMP_ROOT/expiry-moved"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"calendar","ref":"sync","class":"deadline","title":"Woodgrove monthly partner sync","ends_at":"2026-09-10T10:30:00+02:00","updated":'"$T_0900"'}'
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'Woodgrove' 2)" = closed ] || fail 'a meeting past its end stayed open'
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"calendar","ref":"sync","class":"deadline","title":"Woodgrove monthly partner sync","ends_at":"2026-09-10T16:00:00+02:00","updated":'"$T_1100"'}'
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'a meeting moved later stayed expired'
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'a meeting moved later closed before its new end'
  pass 'an expired meeting moved later reopens and waits for its new end'
}

test_an_expired_item_relisted_without_an_end_comes_back() {
  local h
  h="$TMP_ROOT/expiry-relisted"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"helpdesk","ref":"t9","class":"deadline","title":"dealer invoice reply","ends_at":"2026-09-10T23:59:59+02:00","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  render_at "$h" "$T_NEXT_0900"
  [ "$(field_of "$h" 'dealer invoice' 2)" = closed ] || fail 'a deadline past its day stayed open'
  # The next morning sweep still owes the ask, but it is no longer due today.
  sidecar "$h" 2026-09-11 '{"key":"m1","source":"helpdesk","ref":"t9","class":"urgent","title":"dealer invoice reply","updated":'"$T_NEXT_0900"'}'
  render_at "$h" "$T_NEXT_1000"
  [ "$(field_of "$h" 'dealer invoice' 2)" = open ] || fail 'a re-listed ask with no end time stayed expired'
  assert_contains "$(needs_order "$(page "$h" 2026-09-11)")" 'dealer invoice reply' 'the re-listed ask is not in Needs you now'
  pass 'an expired ask the next sweep re-lists with no end time reopens'
}

test_expiry_leaves_marked_lines_to_the_captain() {
  local h
  h="$TMP_ROOT/expiry-marked"
  new_home "$h"
  # All three end at 10:30 CEST; the last is written in UTC with Z.
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"calendar","ref":"sync","class":"deadline","title":"Woodgrove monthly partner sync","ends_at":"2026-09-10T10:30:00+02:00","updated":'"$T_0900"'},{"key":"m2","source":"calendar","ref":"review","class":"deadline","title":"supplier review","ends_at":"2026-09-10T10:30:00+02:00","updated":'"$T_0900"'},{"key":"m3","source":"calendar","ref":"standup","class":"deadline","title":"ops standup","ends_at":"2026-09-10T08:30:00Z","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  todo_at "$h" "$T_1000" command --item "$(field_of "$h" 'Woodgrove' 1)" 'you: send the recap' >/dev/null
  todo_at "$h" "$T_1000" command --item "$(field_of "$h" 'supplier review' 1)" 'mine' >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'ops standup' 2)" = closed ] || fail 'an end time written with Z did not expire its item'
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'expiry closed an item with a pending handoff'
  [ "$(field_of "$h" 'supplier review' 2)" = open ] || fail 'expiry closed an item the captain owns'
  assert_contains "$(page "$h" 2026-09-10)" 'handoff requested' 'the pending handoff left the page at the end time'
  pass 'a Z end time expires its item, and a line the captain marked is left for him to clear'
}

test_a_lapsed_park_no_longer_holds_off_expiry() {
  local h
  h="$TMP_ROOT/expiry-parked"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"m1","source":"calendar","ref":"sync","class":"deadline","title":"Woodgrove monthly partner sync","ends_at":"2026-09-10T10:30:00+02:00","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  todo_at "$h" "$T_1000" command --item "$(field_of "$h" 'Woodgrove' 1)" 'park til tomorrow' >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'Woodgrove' 2)" = open ] || fail 'expiry closed an item parked until tomorrow'
  render_at "$h" "$T_NEXT_1000"
  [ "$(field_of "$h" 'Woodgrove' 2)" = closed ] || fail 'a lapsed park kept an ended meeting from expiring'
  assert_not_contains "$(needs_order "$(page "$h" 2026-09-11)")" 'Woodgrove' 'an ended meeting came back when its park lapsed'
  pass 'a park holds off expiry only until it lapses'
}

test_a_pass_rechecks_open_items_and_counts_the_misses() {
  local h out a b c
  h="$TMP_ROOT/recheck"
  new_home "$h"
  printf 'captain_names = Robin Vale\n' >>"$h/config/channel-intake"
  printf '## Queued\n- [ ] fleet-a - Approve reads on unit A (since 2026-09-01) (hold: needs the captain'"'"'s go) (hold-kind: captain)\n' >"$h/backlog.md"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref m-1 --digest a --class urgent --title 'quote for the dealer' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref m-2 --digest b --class urgent --title 'cover lens question' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref m-3 --digest c --class urgent --title 'invoice question' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref m-4 --digest d --class routine --title 'lunch is in the kitchen' >/dev/null
  printf 'C_TEAM\tslack-announcements\tteam announcement channels\n' >>"$h/data/channel-intake/sources.tsv"
  intake_at "$h" "$T_0900" observe --source C_TEAM --ref u-1 --digest d --class update \
    --source-epoch "$T_0900" --title 'price list changes 1 Nov' >/dev/null
  todo_at "$h" "$T_0900" sweep-start >/dev/null
  render_at "$h" "$T_0900"
  a=$(field_of "$h" 'quote for' 1)
  b=$(field_of "$h" 'cover lens' 1)
  c=$(field_of "$h" 'invoice question' 1)
  todo_at "$h" "$T_0900" verify --item "$(field_of "$h" 'unit A' 1)" --how 'backlog hold re-read' >/dev/null
  # Robin answered one himself; the pass records it under his name.
  todo_at "$h" "$T_1000" close --item "$c" --evidence 'Robin answered in the thread' --actor Robin >/dev/null
  out=$(intake_at "$h" "$T_1030" claim)
  assert_contains "$out" "recheck: $a" 'the claim did not list an open item for re-checking'
  assert_contains "$out" 'C_BRIEF:m-2' 'a re-check line does not name its source reference'
  assert_not_contains "$out" "recheck: $c" 'a closed item was listed for re-checking'
  # Routine activity was never an ask: a pass neither lists it nor counts it as a miss.
  assert_not_contains "$out" 'C_BRIEF:m-4' 'routine activity was listed for re-checking'
  assert_not_contains "$out" 'price list changes' 'a team update, never an ask, was listed for re-checking'
  # The pass starts its own freshness floor, re-reads one item and skips one.
  todo_at "$h" "$T_1030" sweep-start --pass >/dev/null
  todo_at "$h" "$T_1100" verify --item "$a" --how 'read the thread on Slack' >/dev/null
  out=$(intake_at "$h" "$T_1100" complete --source C_BRIEF --checkpoint c-1)
  assert_contains "$out" "1 of 2 listed not re-read: $b" 'complete did not count the item the pass skipped'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'quote for the dealer<span class="prov obs">read 11:00 CEST</span>' 'the re-read line is not current'
  assert_contains "$out" 'cover lens question<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a line the pass skipped still reads as current'
  # A held decision no pass can re-read answers to the morning sweep only.
  assert_not_contains "$(todo_at "$h" "$T_1100" recheck)" 'unit A' 'a held decision was listed for a pass'
  assert_contains "$out" 'Approve reads on unit A<span class="prov obs">read 09:00 CEST</span>' \
    'a pass demoted a held decision it can never re-read'
  # A pass never moves the closed fold's boundary, and his own close is his.
  assert_contains "$out" '<summary>Closed today (1)</summary>' 'an intake pass moved the closed boundary'
  assert_contains "$out" 'fulfilled by you' 'a close recorded under his name was not counted as his'
  assert_not_contains "$out" 'handled without you' 'his own close was counted as handled without him'
  # A claim that cannot list leaves no earlier pass's list behind to count against.
  mv "$h/data/todo/items" "$h/data/todo/items.off"
  intake_at "$h" "$((T_1100 + 900))" claim >/dev/null
  mv "$h/data/todo/items.off" "$h/data/todo/items"
  out=$(intake_at "$h" "$((T_1100 + 900))" complete --source C_BRIEF --checkpoint c-2)
  assert_not_contains "$out" 'listed not re-read' 'a claim with no list counted an earlier pass'"'"'s list'
  pass 'a pass lists every open item to re-check, counts the ones it skipped, keeps the closed boundary and leaves held decisions to the morning sweep'
}

test_ranking_follows_partners_and_the_oldest_ask() {
  local h out yb
  h="$TMP_ROOT/ranking"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-old --digest a --class obligation \
    --title 'tidy the internal wiki' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-relay --digest b --class obligation --partner \
    --title 'Nadia relays a dealer question' >/dev/null
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref r-cust --digest c --class obligation --partner \
    --title 'customer asks about a black screen' >/dev/null
  sidecar "$h" 2026-09-10 '{"key":"k-t","source":"firstmate","ref":"voice-pr","class":"obligation","kind":"approval","title":"merge the voice fix?","tooling":true,"updated":'"$T_1100"'},{"key":"k-f","source":"firstmate","ref":"intake-window","class":"obligation","kind":"approval","title":"widen the intake window?","updated":'"$T_1100"'},{"key":"k-y","source":"helpdesk","ref":"t-45","class":"obligation","kind":"reply","title":"consumption report the partner asked for","partner_awaiting":true,"awaiting_since":'"$((T_0900 - 86400))"',"updated":'"$T_1100"'}'
  render_at "$h" "$T_1500"
  out=$(page "$h" 2026-09-10)
  # Partners and customers lead, oldest ask first, whatever was read last;
  # the tooling approval sits in its own fold below them.
  [ "$(needs_order "$out")" = 'consumption report the partner asked for
Nadia relays a dealer question
customer asks about a black screen
tidy the internal wiki' ] || fail "Needs you is not partners first, oldest ask first:
$(needs_order "$out")"
  # A Firstmate-sourced line needs no flag to land there.
  assert_contains "$out" '<summary>Firstmate tooling approvals (2)</summary>' 'a Firstmate-sourced approval has no fold of its own'
  [ "$(grep -n 'merge the voice fix' <<<"$out" | head -n1 | cut -d: -f1)" -gt "$(grep -n 'tidy the internal wiki' <<<"$out" | head -n1 | cut -d: -f1)" ] \
    || fail 'the tooling approval ranks above a partner or customer ask'
  # mine keeps a partner ask tracked and out of the ranked list.
  yb=$(field_of "$h" 'consumption report' 1)
  todo_at "$h" "$T_1500" command --item "$yb" 'mine' >/dev/null
  render_at "$h" "$T_1500"
  out=$(page "$h" 2026-09-10)
  assert_not_contains "$(needs_order "$out")" 'consumption report' 'a line marked mine is still ranked'
  assert_contains "$out" '<summary>Yours, tracked but not surfaced (1)</summary>' 'the mine line is not tracked'
  pass 'Needs you ranks partners from the source, oldest ask first, folds tooling below, and honours mine'
}

# A captain-held backlog decision the morning sweep re-read, beside a genuine
# tooling approval and an ordinary ask that keeps Needs you a table; the held decision's fold depends on the home's setting.
held_beside_tooling() {
  local h=$1
  new_home "$h"
  cat >"$h/backlog.md" <<'MD'
## Queued
- [ ] supplier-pick - Choose the new pump supplier (since 2026-09-01) (hold: needs the captain's pick) (hold-kind: captain)
MD
  sidecar "$h" 2026-09-10 '{"key":"k-t","source":"firstmate","ref":"voice-pr","class":"obligation","kind":"approval","title":"merge the voice fix?","tooling":true,"updated":'"$T_1000"'}'
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-wiki --digest a --class obligation \
    --title 'tidy the internal wiki' >/dev/null
  render_at "$h" "$T_1000"
  todo_at "$h" "$T_1000" verify --item "$(field_of "$h" 'pump supplier' 1)" --how 'backlog hold re-read' >/dev/null
}

# The rows inside the Firstmate tooling approvals fold.
tooling_fold() {
  sed -n '/<summary>Firstmate tooling approvals/,/<\/details>/p' <<<"$1"
}

test_held_decisions_stay_in_the_tooling_fold_by_default() {
  local h out
  h="$TMP_ROOT/held-default"
  held_beside_tooling "$h"
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_not_contains "$(needs_order "$out")" 'pump supplier' 'a held decision left the tooling fold with the setting off'
  assert_contains "$out" '<summary>Firstmate tooling approvals (2)</summary>' 'the tooling fold changed with the setting off'
  assert_contains "$(tooling_fold "$out")" 'Choose the new pump supplier' 'the held decision is not in the tooling fold'
  pass 'with the setting off a held backlog decision still renders in the tooling fold'
}

test_held_decisions_need_you_when_the_home_asks() {
  local h out code
  h="$TMP_ROOT/held-needs-you"
  held_beside_tooling "$h"
  printf 'held_decisions_need_you = true\n' >>"$h/config/channel-intake"
  intake_at "$h" "$T_1030" status >/dev/null || fail 'the intake gate refused the held-decisions setting'
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$(needs_order "$out")" 'Choose the new pump supplier' 'the held decision is not in Needs you now'
  assert_not_contains "$(tooling_fold "$out")" 'pump supplier' 'the held decision is still in the tooling fold'
  assert_contains "$out" '<summary>Firstmate tooling approvals (1)</summary>' 'the tooling approval left its fold'
  assert_contains "$(tooling_fold "$out")" 'merge the voice fix?' 'the tooling approval is not in its fold'
  sed -i.bak 's/^held_decisions_need_you = true$/held_decisions_need_you = maybe/' "$h/config/channel-intake"
  render_at "$h" "$T_1100" 2>/dev/null && code=0 || code=$?
  expect_code 2 "$code" 'the renderer accepted a held-decisions value that is not true or false'
  intake_at "$h" "$T_1100" status >/dev/null 2>&1 && code=0 || code=$?
  expect_code 2 "$code" 'the intake gate accepted a held-decisions value that is not true or false'
  pass 'with the setting on a held backlog decision needs you, and tooling approvals keep their fold'
}

test_a_held_decision_shows_its_readable_reason() {
  local h out reason stored rev
  h="$TMP_ROOT/held-reason"
  new_home "$h"
  # bin/fm-captain-hold.sh stores the reason through the hold-reason encoding.
  reason='Pick the pump supplier (Contoso or Fabrikam)'
  stored=$(bash -c '. "$1" && fm_hold_reason_encode "$2"' bash "$ROOT/bin/fm-hold-reason-lib.sh" "$reason")
  printf '## Queued\n- [ ] fleet-r - Choose the pump supplier (since 2026-09-01) (hold: %s) (hold-kind: captain)\n' \
    "$stored" >"$h/backlog.md"
  render_at "$h" "$T_0900"
  rev=$(field_of "$h" 'pump supplier' 4)
  todo_at "$h" "$T_0900" verify --item "$(field_of "$h" 'pump supplier' 1)" --how 'backlog hold re-read' >/dev/null
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'Pick the pump supplier (Contoso or Fabrikam)' 'the page does not show the readable reason'
  assert_not_contains "$out" 'fm-hold-v1:' 'the page shows the stored encoded reason'
  [ "$(field_of "$h" 'pump supplier' 4)" = "$rev" ] || fail 'an unchanged reason changed the revision'
  pass 'a held decision shows its readable reason on the page'
}

test_page_bugs_stay_fixed() {
  local h out
  h="$TMP_ROOT/page-bugs"
  new_home "$h"
  # A title written three days ago with rotting relative times.
  intake_at "$h" $((T_0900 - 3 * 86400)) observe --source C_BRIEF --ref r-rot --digest a --class obligation \
    --title 'PARTNER WAITING 14 DAYS - Kai asked yesterday' >/dev/null
  # A deadline or a duration the ask is about is not a rotting relative time.
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-by --digest a1 --class obligation \
    --title 'Send the quote by tomorrow' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-ext --digest a2 --class obligation \
    --title 'Approve 30 days extension' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-ret --digest a3 --class obligation \
    --title 'Return within 14 days?' >/dev/null
  intake_at "$h" "$T_1000" complete --source C_BRIEF --checkpoint c-1 >/dev/null
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'class="what">PARTNER WAITING - Kai asked<' 'a stored title kept its relative times'
  assert_contains "$out" 'asked Mon 7 Sep, 3 days ago' 'the age was not computed at render'
  for title in 'Send the quote by tomorrow' 'Approve 30 days extension' 'Return within 14 days?'; do
    assert_contains "$out" "class=\"what\">$title<" "a title lost what the ask is about: $title"
  done
  assert_contains "$out" '<b>Not read between morning sweeps</b> - Slack DMs, Slack mentions, Calendar, Gmail inbound, Asana, phone, in person' \
    'the coverage fold does not name what is not read'
  pass 'titles lose relative times, ages are computed at render and coverage names its gaps'
}

test_a_pass_judges_a_record_from_before_the_flag_by_its_aliases() {
  local h path
  h="$TMP_ROOT/legacy-floor"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"k-h","source":"helpdesk","ref":"t-77","class":"obligation","kind":"reply","title":"dealer asks about the filter","updated":'"$T_0900"'}'
  todo_at "$h" "$T_0900" sweep-start >/dev/null
  render_at "$h" "$T_0900"
  # A record stored before the flag existed, and no longer re-observed.
  path=$(grep -l 'dealer asks about the filter' "$h"/data/todo/items/*.json)
  python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r.pop("rereadable",None); open(p,"w").write(json.dumps(r))' "$path"
  rm "$h/.lavish/today-2026-09-10.morning.json"
  todo_at "$h" "$T_1030" sweep-start --pass >/dev/null
  render_at "$h" "$T_1100"
  assert_contains "$(page "$h" 2026-09-10)" 'dealer asks about the filter<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a re-readable record a pass skipped still reads as current'
  pass 'a pass judges every stored record by its aliases, whenever it was written'
}

test_an_age_counts_calendar_days_across_a_clock_change() {
  local h asked=1774602000 now=1775203200 # Fri 27 Mar and Fri 3 Apr 2026, 10:00 local
  h="$TMP_ROOT/age-dst"
  new_home "$h"
  intake_at "$h" "$asked" observe --source C_BRIEF --ref r-dst --digest a --class obligation \
    --title 'answer the dealer about the spring order' >/dev/null
  render_at "$h" "$now"
  assert_contains "$(page "$h" 2026-04-03)" 'asked Fri 27 Mar, 7 days ago' 'an age across the spring clock change lost a day'
  pass 'an age counts calendar days across a clock change'
}


# A home's add-on whose todo-verbs hooks take a `refund` line; the second hook
# would take it too, so a call to it proves the first answer did not stop the
# offer. Every call is logged, so a line never offered leaves no trace.
addon_verbs() {  # <home>
  local h=$1
  mkdir -p "$h/addon/hooks/todo-verbs"
  printf 'path = %s\n' "$h/addon" >"$h/config/addon"
  cat >"$h/addon/hooks/todo-verbs/10-refund" <<HOOK
#!/usr/bin/env bash
printf '10 %s %s %s %s\n' "\$1" "\$FM_TODO_ITEM" "\$FM_TODO_REV" "\$FM_TODO_AT" >>"$h/verb-calls"
case "\$1" in
  refund)
    [ -f "\$FM_TODO_ITEM_FILE" ] || exit 9
    "$ROOT/bin/fm-todo.sh" mark --item "\$FM_TODO_ITEM" --name refund --text 'Refund pending in the shop' >/dev/null || exit 8
    printf 'refund %s queued\n' "\$FM_TODO_ITEM" ;;
  'refund now') printf 'refunds wait for the morning\n'; exit 1 ;;
esac
HOOK
  cat >"$h/addon/hooks/todo-verbs/20-second" <<HOOK
#!/usr/bin/env bash
printf '20 %s\n' "\$1" >>"$h/verb-calls"
[ "\$1" != refund ] || printf 'second took it\n'
HOOK
  chmod +x "$h/addon/hooks/todo-verbs"/*
}

test_an_addon_extends_the_store_through_verbs_and_marks() {
  local h id rev out code before
  h="$TMP_ROOT/addon-verbs"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref v-1 --digest a --class obligation \
    --title 'dealer asks for a refund' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'dealer asks' 1)
  rev=$(field_of "$h" 'dealer asks' 4)

  # With no add-on the line is free text, as before.
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'refund') || fail 'free text failed with no add-on'
  assert_contains "$out" 'TODO_CMD: not-a-command refund' 'a line no verb takes was not free text'

  addon_verbs "$h"
  # A targeted line against the current revision goes to the first hook that answers.
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" --at "$T_0900" 'refund') && code=0 || code=$?
  expect_code 0 "$code" "the add-on verb failed: $out"
  assert_contains "$out" "TODO_CMD: refund $id queued" 'the hook result was not reported'
  assert_grep "10 refund $id $rev $T_0900" "$h/verb-calls" 'the hook was not told the item, revision and typed time'
  assert_no_grep '20 refund' "$h/verb-calls" 'a later hook was offered a line the first hook took'
  # The mark is the add-on's own line on the row; state, revision and freshness stay.
  [ "$(field_of "$h" 'dealer asks' 2)" = open ] || fail 'a mark changed the item state'
  [ "$(field_of "$h" 'dealer asks' 4)" = "$rev" ] || fail 'a mark changed the item revision'
  render_at "$h" "$T_1000"
  assert_contains "$(page "$h" 2026-09-10)" '<span class="prov unv">Refund pending in the shop</span>' 'the mark is not on the row'
  assert_contains "$(page "$h" 2026-09-10)" 'dealer asks for a refund<span class="prov obs">read 09:00 CEST</span>' \
    'a mark changed the line freshness'

  # Never offered: an untargeted line, a line typed against an older revision,
  # or a built-in verb.
  : >"$h/verb-calls"
  out=$(todo_at "$h" "$T_1000" command 'refund') || true
  assert_contains "$out" 'TODO_CMD: not-a-command refund' 'an untargeted line was taken by a verb'
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev stale 'refund') || true
  assert_contains "$out" 'TODO_CMD: not-a-command refund' 'a line typed against an older revision was taken by a verb'
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'park til tomorrow') || fail 'a built-in verb failed beside an add-on'
  assert_contains "$out" "TODO_CMD: park $id" 'a built-in verb was not applied'
  [ ! -s "$h/verb-calls" ] || fail "a hook was offered a line it must never see: $(cat "$h/verb-calls")"

  # A line no hook takes stays free text; a refusal fails the run and says why.
  out=$(todo_at "$h" "$T_1000" command --item "$id" 'thanks, noted') || fail 'free text failed beside an add-on'
  assert_contains "$out" 'TODO_CMD: not-a-command thanks, noted' 'a line no hook took did not stay free text'
  out=$(todo_at "$h" "$T_1000" command --item "$id" 'refund now') && code=0 || code=$?
  expect_code 1 "$code" 'a refused add-on verb did not fail the run'
  assert_contains "$out" 'TODO_CMD: refused refund now :: refunds wait for the morning' 'the refusal was not reported'

  # mark refuses a bad name or an unclear request, and --clear takes it off.
  before=$(cat "$h/data/todo/items/$id.json")
  if todo_at "$h" "$T_1000" mark --item "$id" --name 'Bad Name' --text x >/dev/null 2>&1; then fail 'a mark with a bad name was accepted'; fi
  if todo_at "$h" "$T_1000" mark --item "$id" --name refund >/dev/null 2>&1; then fail 'a mark with neither --text nor --clear was accepted'; fi
  if todo_at "$h" "$T_1000" mark --item "$id" --name refund --text x --clear >/dev/null 2>&1; then fail 'a mark with both --text and --clear was accepted'; fi
  [ "$(cat "$h/data/todo/items/$id.json")" = "$before" ] || fail 'a refused mark changed the item'
  todo_at "$h" "$T_1000" mark --item "$id" --name refund --clear >/dev/null || fail 'clearing a mark failed'
  render_at "$h" "$T_1000"
  assert_not_contains "$(page "$h" 2026-09-10)" 'Refund pending in the shop' 'a cleared mark is still on the row'
  pass 'an add-on takes its own verbs on a row and marks the row, never on a stale or untargeted line'
}

test_hand_over_moves_an_item_to_waiting_on_its_owner() {
  local h led mor rev out code before
  h="$TMP_ROOT/hand-over"
  new_home "$h"
  printf 'captain_names = Robin Vale\n' >>"$h/config/channel-intake"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref h-1 --digest a --class obligation \
    --title 'dealer wants a quote' >/dev/null
  sidecar "$h" 2026-09-10 '{"key":"k-m","source":"helpdesk","ref":"t-7","class":"obligation","kind":"reply","title":"partner asks for a manual","digest":"m1","updated":'"$T_0900"'}'
  render_at "$h" "$T_0900"
  led=$(field_of "$h" 'dealer wants' 1)
  rev=$(field_of "$h" 'dealer wants' 4)
  mor=$(field_of "$h" 'manual' 1)

  before=$(cat "$h/data/todo/items/$led.json")
  out=$(todo_at "$h" "$T_1000" hand-over --item "$led" --to '  ' --note 'quote drafted' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a hand-over to nobody was accepted'
  assert_contains "$out" 'needs --to' 'the empty-name refusal does not say why'
  for name in Robin vale 'Robin Vale' captain; do
    out=$(todo_at "$h" "$T_1000" hand-over --item "$led" --to "$name" --note 'quote drafted' 2>&1) && code=0 || code=$?
    expect_code 2 "$code" "a hand-over to the captain's own name was accepted: $name"
    assert_contains "$out" 'is one of the captain_names' 'the captain-name refusal does not say why'
  done
  out=$(todo_at "$h" "$T_1000" hand-over --item "$led" --rev stale --to Sam --note 'quote drafted' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a hand-over from a stale page was accepted'
  assert_contains "$out" 'refresh the page first' 'the stale refusal does not say why'
  [ "$(cat "$h/data/todo/items/$led.json")" = "$before" ] || fail 'a refused hand-over changed the item'

  out=$(todo_at "$h" "$T_1000" hand-over --item "$led" --rev "$rev" --at "$T_0900" --to Sam \
    --note 'quote drafted, Sam sends it') || fail "a hand-over of a ledger item failed: $out"
  assert_contains "$out" "hand-over $led -> waiting" 'the hand-over did not move the ledger item to waiting'
  todo_at "$h" "$T_1000" hand-over --item "$mor" --to Alex --note 'Alex has the manual to hand' >/dev/null \
    || fail 'a hand-over of a morning-only item failed'
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<summary>Waiting on others (2)</summary>' 'the handed-over items are not waiting on others'
  assert_contains "$out" 'Sam has it: quote drafted, Sam sends it' 'the ledger hand-over note is not shown'
  assert_contains "$out" 'Alex has it: Alex has the manual to hand' 'the morning hand-over note is not shown'
  [ -z "$(needs_order "$out")" ] || fail "a handed-over item still needs you: $(needs_order "$out")"
  [ "$(field_of "$h" 'manual' 2)" = waiting ] || fail 'a re-asserted morning action took the hand-over back'

  todo_at "$h" "$T_1100" close --item "$led" --evidence 'Sam sent the quote' --actor Sam >/dev/null
  out=$(todo_at "$h" "$T_1100" hand-over --item "$led" --to Alex --note 'again' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a closed item was handed over'
  assert_contains "$out" 'is closed' 'the closed-item refusal does not say why'
  [ "$(field_of "$h" 'dealer wants' 2)" = closed ] || fail 'a refused hand-over reopened a closed item'
  pass 'hand-over moves a ledger or morning item to waiting on its owner and refuses closed, empty, captain and stale'
}

test_an_addons_own_source_change_does_not_reopen_the_item() {
  local h shut held plain mor out
  h="$TMP_ROOT/source-change"
  new_home "$h"
  for ref in g-done g-held g-plain; do
    intake_at "$h" "$T_0900" observe --source C_BRIEF --ref "$ref" --digest 'ticket=open' --class obligation \
      --title "partner ticket $ref" >/dev/null
  done
  sidecar "$h" 2026-09-10 '{"key":"k-m","source":"helpdesk","ref":"t-9","class":"obligation","kind":"reply","title":"partner ticket morning","digest":"d1","updated":'"$T_0900"'}'
  render_at "$h" "$T_0900"
  shut=$(field_of "$h" 'g-done' 1)
  held=$(field_of "$h" 'g-held' 1)
  plain=$(field_of "$h" 'g-plain' 1)
  mor=$(field_of "$h" 'ticket morning' 1)
  todo_at "$h" "$T_0900" close --item "$shut" --evidence 'ticket closed in the helpdesk' --actor helpdesk \
    --source-change 'ticket=closed' >/dev/null
  todo_at "$h" "$T_0900" hand-over --item "$held" --to Sam --note 'ticket waiting on Sam' \
    --source-change 'ticket=waiting' >/dev/null
  todo_at "$h" "$T_0900" hand-over --item "$plain" --to Sam --note 'Sam looks at it' >/dev/null
  todo_at "$h" "$T_0900" close --item "$mor" --evidence 'ticket closed in the helpdesk' --actor helpdesk \
    --source-change d2 >/dev/null

  # The add-on's next pass observes its own changes: none of them comes back.
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref g-done --digest 'ticket=closed' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref g-held --digest 'ticket=waiting' >/dev/null
  sidecar "$h" 2026-09-10 '{"key":"k-m","source":"helpdesk","ref":"t-9","class":"obligation","kind":"reply","title":"partner ticket morning","digest":"d2","updated":'"$T_1000"'}'
  render_at "$h" "$T_1000"
  render_at "$h" "$T_1030"
  [ "$(field_of "$h" 'g-done' 2)" = closed ] || fail "the add-on's own ledger change reopened a closed item"
  [ "$(field_of "$h" 'g-held' 2)" = waiting ] || fail "the add-on's own ledger change took back a hand-over"
  [ "$(field_of "$h" 'ticket morning' 2)" = closed ] || fail "the add-on's own morning digest reopened a closed item"
  assert_contains "$(page "$h" 2026-09-10)" 'Sam has it: ticket waiting on Sam' 'the hand-over note was lost'

  # A later, different revision - a partner reply after the add-on's change - brings each back.
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref g-done --digest 'ticket=closed reply=1' >/dev/null
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref g-held --digest 'ticket=waiting reply=1' >/dev/null
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref g-plain --digest 'ticket=open reply=1' >/dev/null
  sidecar "$h" 2026-09-10 '{"key":"k-m","source":"helpdesk","ref":"t-9","class":"obligation","kind":"reply","title":"partner ticket morning","digest":"d3","updated":'"$T_1100"'}'
  render_at "$h" "$T_1100"
  for ref in g-done g-held g-plain 'ticket morning'; do
    [ "$(field_of "$h" "$ref" 2)" = open ] || fail "a later source change did not reopen $ref"
  done
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'changed after it was handed to Sam' 'the reopened hand-over does not say why'
  assert_contains "$out" 'changed after it was closed (fulfilled)' 'the reopened closure does not say why'
  assert_not_contains "$out" 'Sam has it' 'a reopened hand-over kept its owner'
  pass "an add-on's recorded source change never reopens its item, and a later different revision does"
}

test_a_source_that_resolves_a_handed_over_item_wins() {
  local h res wait shut parked
  h="$TMP_ROOT/handed-over-resolved"
  new_home "$h"
  res=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-res --digest a --class obligation \
    --title 'partner ticket resolved' | awk '{ print $2 }')
  wait=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-wait --digest a --class obligation \
    --title 'partner ticket parked' | awk '{ print $2 }')
  shut=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-shut --digest a --class obligation \
    --title 'partner ticket shut' | awk '{ print $2 }')
  parked=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r-park --digest a --class obligation \
    --title 'partner ticket reassigned' | awk '{ print $2 }')
  intake_at "$h" "$T_0900" resolve --item "$parked" --waiting --reason 'handed over to Sam' >/dev/null
  render_at "$h" "$T_0900"
  [ "$(field_of "$h" 'ticket reassigned' 2)" = waiting ] || fail 'a source hand-over did not make the item waiting'
  todo_at "$h" "$T_0900" hand-over --item "$(field_of "$h" 'ticket resolved' 1)" --to Sam --note 'Sam answers it' >/dev/null
  todo_at "$h" "$T_0900" hand-over --item "$(field_of "$h" 'ticket parked' 1)" --to Sam --note 'Sam answers it' >/dev/null
  todo_at "$h" "$T_0900" hand-over --item "$(field_of "$h" 'ticket reassigned' 1)" --to Alex --note 'Alex took it over' >/dev/null
  todo_at "$h" "$T_0900" close --item "$(field_of "$h" 'ticket shut' 1)" --evidence 'answered in the helpdesk' \
    --actor helpdesk --source-change b >/dev/null
  # In one tick a reply lands and the source resolves or parks the record.
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-res --digest b >/dev/null
  intake_at "$h" "$T_1000" resolve --item "$res" --reason 'Sam answered the partner' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-wait --digest b >/dev/null
  intake_at "$h" "$T_1000" resolve --item "$wait" --waiting --reason 'handed over to Sam' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-shut --digest c >/dev/null
  intake_at "$h" "$T_1000" resolve --item "$shut" --reason 'answered in the helpdesk' >/dev/null
  # A source that stays waiting and gets a new message brings the hand-over back.
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref r-park --digest b >/dev/null
  render_at "$h" "$T_1000"
  render_at "$h" "$T_1030"
  [ "$(field_of "$h" 'ticket resolved' 2)" = closed ] || fail 'a handed-over item stayed open after its source resolved it'
  [ "$(field_of "$h" 'ticket parked' 2)" = waiting ] || fail 'a handed-over item reopened while its source set it waiting'
  [ "$(field_of "$h" 'ticket shut' 2)" = closed ] || fail 'a closed item reopened while its source resolved it in the same tick'
  [ "$(field_of "$h" 'ticket reassigned' 2)" = open ] || fail 'a new message on a waiting source did not take the hand-over back'
  [ "$(needs_order "$(page "$h" 2026-09-10)")" = 'partner ticket reassigned' ] \
    || fail "only the reopened hand-over should need you: $(needs_order "$(page "$h" 2026-09-10)")"
  # An edit after the resolution is still news and reopens the closed item.
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref r-shut --digest d >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'ticket shut' 2)" = open ] || fail 'an edit after the resolution did not reopen the item'
  pass 'a source that resolves or parks an item in the same tick as a change wins, and a later change still reopens it'
}

test_a_ledger_partner_awaiting_ask_ranks_with_the_morning_ones() {
  local h out
  h="$TMP_ROOT/ledger-awaiting"
  new_home "$h"
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref a-urgent --digest u --class urgent \
    --title 'fresh urgent' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref a-relay --digest r --class obligation --partner \
    --source-epoch "$((T_0900 - 86400 * 9))" --title 'older partner relay' >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref a-wait --digest w --class obligation \
    --partner-awaiting-since "$((T_0900 - 86400 * 2))" --title 'partner waits on the ledger' >/dev/null
  sidecar "$h" 2026-09-10 '{"key":"k-a","source":"helpdesk","ref":"t-3","class":"obligation","kind":"reply","title":"partner waits in the morning sweep","partner_awaiting":true,"awaiting_since":'"$((T_0900 - 86400 * 3))"',"updated":'"$T_1000"'}'
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  [ "$(needs_order "$out")" = 'partner waits in the morning sweep
partner waits on the ledger
older partner relay
fresh urgent' ] || fail "a ledger ask awaiting the captain is not in the partner-awaiting tier by its age:
$(needs_order "$out")"
  pass 'a ledger ask awaiting the captain ranks in the partner-awaiting tier beside a morning one, oldest first'
}

# A helpdesk add-on's ticket verbs, built only on the store's contract: the
# ticket lives in a file standing in for the helpdesk, and each verb changes it
# there and records that change on the row it moves.
addon_tickets() {  # <home>
  local h=$1
  mkdir -p "$h/addon/hooks/todo-verbs" "$h/helpdesk"
  printf 'path = %s\n' "$h/addon" >"$h/config/addon"
  printf 'helpdesk\thelpdesk\thelpdesk tickets\n' >>"$h/data/channel-intake/sources.tsv"
  printf 'state=open owner=Sam' >"$h/helpdesk/T-1"
  cat >"$h/addon/hooks/todo-verbs/10-tickets" <<'HOOK'
#!/usr/bin/env bash
ticket="$FM_HOME/helpdesk/T-1"
todo="$FM_ROOT/bin/fm-todo.sh"
owner=$(sed 's/.*owner=//' "$ticket")
case "$1" in
  waiting)
    printf 'state=waiting owner=%s' "$owner" >"$ticket"
    "$todo" hand-over --item "$FM_TODO_ITEM" --rev "$FM_TODO_REV" --at "$FM_TODO_AT" --to "$owner" \
      --note "ticket set to waiting on $owner" --source-change "$(cat "$ticket")" >/dev/null || exit 1
    printf 'waiting %s on %s\n' "$FM_TODO_ITEM" "$owner" ;;
  'reassign '*)
    name=${1#reassign }
    printf 'state=open owner=%s' "$name" >"$ticket"
    "$todo" hand-over --item "$FM_TODO_ITEM" --rev "$FM_TODO_REV" --at "$FM_TODO_AT" --to "$name" \
      --note "ticket reassigned to $name" --source-change "$(cat "$ticket")" >/dev/null || exit 1
    printf 'reassigned %s to %s\n' "$FM_TODO_ITEM" "$name" ;;
  close)
    printf 'state=closed owner=%s' "$owner" >"$ticket"
    "$todo" close --item "$FM_TODO_ITEM" --evidence 'ticket closed in the helpdesk' --actor helpdesk \
      --source-change "$(cat "$ticket")" >/dev/null || exit 1
    printf 'closed %s\n' "$FM_TODO_ITEM" ;;
esac
HOOK
  chmod +x "$h/addon/hooks/todo-verbs/10-tickets"
}

# The add-on's own intake pass: it observes the ticket as the helpdesk now has it.
ticket_pass() {  # <home> <epoch>
  intake_at "$1" "$2" observe --source helpdesk --ref T-1 --digest "$(cat "$1/helpdesk/T-1")" >/dev/null
  render_at "$1" "$2"
}

test_an_addon_runs_ticket_verbs_on_the_contract() {
  local h id rev out
  h="$TMP_ROOT/addon-tickets"
  new_home "$h"
  addon_tickets "$h"
  intake_at "$h" "$T_0900" observe --source helpdesk --ref T-1 --digest "$(cat "$h/helpdesk/T-1")" \
    --class obligation --partner --title 'partner reports a leaking tap' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'leaking tap' 1)

  rev=$(field_of "$h" 'leaking tap' 4)
  out=$(todo_at "$h" "$T_0900" command --item "$id" --rev "$rev" waiting) || fail "the waiting verb failed: $out"
  assert_contains "$out" "TODO_CMD: waiting $id on Sam" 'the waiting verb was not taken'
  ticket_pass "$h" "$T_1000"
  [ "$(field_of "$h" 'leaking tap' 2)" = waiting ] || fail "the add-on's own waiting change took the row back"
  assert_contains "$(page "$h" 2026-09-10)" 'Sam has it: ticket set to waiting on Sam' 'the ticket owner is not shown'

  rev=$(field_of "$h" 'leaking tap' 4)
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'reassign Alex') || fail "the reassign verb failed: $out"
  assert_contains "$out" "TODO_CMD: reassigned $id to Alex" 'the reassign verb was not taken'
  ticket_pass "$h" "$T_1030"
  [ "$(field_of "$h" 'leaking tap' 2)" = waiting ] || fail "the add-on's own reassignment took the row back"
  assert_contains "$(page "$h" 2026-09-10)" 'Alex has it: ticket reassigned to Alex' 'the new owner is not shown'

  rev=$(field_of "$h" 'leaking tap' 4)
  out=$(todo_at "$h" "$T_1030" command --item "$id" --rev "$rev" close) || fail "the close verb failed: $out"
  assert_contains "$out" "TODO_CMD: closed $id" 'the close verb was not taken'
  ticket_pass "$h" "$T_1100"
  [ "$(field_of "$h" 'leaking tap' 2)" = closed ] || fail "the add-on's own close reopened the row"

  # The partner writes again after the close: that is news, and the row comes back.
  printf 'state=closed owner=Alex reply=partner' >"$h/helpdesk/T-1"
  ticket_pass "$h" "$T_1500"
  [ "$(field_of "$h" 'leaking tap' 2)" = open ] || fail 'a partner reply after the close did not reopen the row'
  assert_contains "$(needs_order "$(page "$h" 2026-09-10)")" 'partner reports a leaking tap' 'the reopened row does not need you'
  pass "a helpdesk add-on's waiting, reassign and close verbs run on the contract, and only a partner reply reopens"
}

# A stand-in for bin/fm-captain-hold.sh that records what it was asked and
# files a request for every task except one it was told to refuse.
hold_stub() {  # <home>
  local h=$1
  cat >"$h/hold-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$h/hold-calls"
case "\$1" in
  binding) [ -f "$h/bound" ] && printf '(any)\n'; exit 0 ;;
  bind) : >"$h/bound"; printf 'bound: %s\n' "\$2"; exit 0 ;;
  reconcile-requests)
    while IFS= read -r id; do
      printf 'task %s\n' "\$id" >>"$h/hold-calls"
      if [ "\$id" = "\${REFUSE_TASK:-}" ]; then printf 'refused: %s (already closed)\n' "\$id"; else printf 'reconcile: %s\n' "\$id"; fi
    done
    exit 0 ;;
esac
exit 2
STUB
  chmod +x "$h/hold-stub"
}

test_done_on_a_held_decision_files_a_reconcile_request() {
  local h id out
  h="$TMP_ROOT/held-done"
  new_home "$h"
  hold_stub "$h"
  printf '## Queued\n- [ ] fleet-a - Approve reads on unit A (since 2026-09-01) (hold: needs the go) (hold-kind: captain)\n- [ ] fleet-b - Approve reads on unit B (since 2026-09-01) (hold: needs the go) (hold-kind: captain)\n' >"$h/backlog.md"
  todo_at "$h" "$T_0900" sync >/dev/null
  id=$(field_of "$h" 'unit A' 1)
  out=$(FM_TODO_CAPTAIN_HOLD="$h/hold-stub" todo_at "$h" "$T_1000" command --item "$id" 'done') \
    || fail "done on a held decision failed: $out"
  assert_contains "$out" 'held decision fleet-a: re-check requested' 'done on a held row did not file a re-check'
  assert_grep 'bind todo-page' "$h/hold-calls" 'the store did not bind its own source id on first use'
  assert_grep 'reconcile-requests --source-id todo-page' "$h/hold-calls" 'the request did not go through the reconcile intake'
  assert_grep 'task fleet-a' "$h/hold-calls" 'the held task was not named to the intake'
  [ "$(field_of "$h" 'unit A' 2)" = closed ] || fail 'done on a held row did not close the row'
  : >"$h/hold-calls"
  out=$(FM_TODO_CAPTAIN_HOLD="$h/hold-stub" REFUSE_TASK=fleet-b todo_at "$h" "$T_1000" command 'drop unit B') \
    || fail "drop on a held decision failed: $out"
  assert_contains "$out" 'held decision fleet-b: re-check not requested: already closed' 'a refused request was not reported'
  assert_no_grep 'bind todo-page' "$h/hold-calls" 'a bound store bound itself again'
  pass 'done or drop on a held decision closes the row and files a reconcile request, reporting a refusal'
}

test_the_recheck_rolls_through_every_line_in_three_working_days() {
  local h n out listed first
  h="$TMP_ROOT/rolling"
  new_home "$h"
  for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    intake_at "$h" "$T_0900" observe --source C_BRIEF --ref "r-$n" --digest "d$n" --class obligation \
      --title "ask number $n" >/dev/null
  done
  todo_at "$h" "$T_0900" sync >/dev/null
  # Twelve lines checked at once, one pass a day: a share of five.
  out=$(todo_at "$h" "$T_1000" recheck --passes-per-day 1)
  listed=$(printf '%s\n' "$out" | grep -c '^recheck: ')
  assert_equals 5 "$listed" 'a pass did not list a rolling share'
  assert_contains "$out" 'TODO_RECHECK: rolling share 5 of 12 open lines' 'the share does not say how many it left out'
  # The next pass, given the last pass's list, takes lines that list left out.
  first=$(printf '%s\n' "$out" | sed -n 's/^recheck: \([^[:space:]]*\).*/\1/p')
  # shellcheck disable=SC2086
  out=$(todo_at "$h" "$T_1100" recheck --passes-per-day 1 $first)
  for n in $(printf '%s\n' "$out" | sed -n 's/^recheck: \([^[:space:]]*\).*/\1/p'); do
    case " $(printf '%s\n' "$first" | tr '\n' ' ')" in
      *" $n "*) fail "the last pass's line came up again before the rest: $n" ;;
    esac
  done
  # Three working days on (Thursday to Tuesday), every line past the window comes up within a day.
  out=$(todo_at "$h" "$((T_1000 + 5 * 86400))" recheck --passes-per-day 1)
  listed=$(printf '%s\n' "$out" | grep -c '^recheck: ')
  assert_equals 12 "$listed" 'lines past three working days did not all come up'
  pass 'the re-check lists a rolling share, round robin, and every line within three working days'
}

test_lines_a_pass_could_not_read_do_not_hold_the_share() {
  local h n claim out seen=' ' id
  h="$TMP_ROOT/rolling-stuck"
  new_home "$h"
  printf 'C_DM\tslack-dms\tdirect messages\n' >>"$h/data/channel-intake/sources.tsv"
  # Two shares of lines from one source no pass can read, and two other lines.
  for n in 01 02 03 04 05 06 07 08 09 10; do
    intake_at "$h" "$T_0900" observe --source C_BRIEF --ref "r-$n" --digest "d$n" --class obligation \
      --title "stuck ask $n" >/dev/null
  done
  intake_at "$h" "$T_0900" observe --source C_DM --ref o-1 --digest o1 --class obligation --title 'other ask one' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_DM --ref o-2 --digest o2 --class obligation --title 'other ask two' >/dev/null
  todo_at "$h" "$T_0900" sync >/dev/null
  # Twelve lines in shares of five: three claims list every line, whatever no pass could read.
  for claim in 1 2 3; do
    out=$(intake_at "$h" "$((T_1000 + claim * 3600))" claim)
    assert_contains "$out" 'source: C_BRIEF' "claim $claim handed out no source"
    for id in $(printf '%s\n' "$out" | sed -n 's/^recheck: \([^[:space:]]*\).*/\1/p'); do
      seen="$seen$id "
    done
    intake_at "$h" "$((T_1000 + claim * 3600))" complete --source C_BRIEF --checkpoint "c-$claim" >/dev/null
    intake_at "$h" "$((T_1000 + claim * 3600))" complete --source C_DM --checkpoint "d-$claim" >/dev/null
  done
  assert_equals 12 "$(todo_at "$h" "$((T_1000 + 4 * 3600))" list --state open | grep -c .)" 'the lines did not all open'
  for id in $(todo_at "$h" "$((T_1000 + 4 * 3600))" list --state open | cut -f1); do
    case "$seen" in
      *" $id "*) ;;
      *) fail "a line never came up while two shares of unreadable lines were open: $id" ;;
    esac
  done
  pass 'lines no pass can read never hold the share: every line comes up within one round of claims'
}

test_a_new_ask_about_an_open_line_joins_it() {
  local h out
  h="$TMP_ROOT/about"
  new_home "$h"
  printf 'C_DM\tslack-dms\tdirect messages\n' >>"$h/data/channel-intake/sources.tsv"
  printf '# name regex\ndevice \\b\\d{6}\\b\nnot a pattern line [\n' >"$h/config/todo-about"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref a-1 --digest a --class obligation \
    --title 'unit 123456 shows a fault' >/dev/null
  todo_at "$h" "$T_0900" sync >/dev/null
  # The same ask from another channel joins the open line.
  intake_at "$h" "$T_1000" observe --source C_DM --ref b-1 --digest b --class urgent \
    --title 'can you look at 123456 again' >/dev/null
  # An explicit key joins too, and survives a later read that does not repeat it.
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref p-1 --digest p --class obligation \
    --title 'Quinn asks for the price list' --about Person:Quinn >/dev/null
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref p-1 --digest p2 --class obligation >/dev/null
  intake_at "$h" "$T_1000" observe --source C_DM --ref p-2 --digest q --class obligation \
    --title 'Quinn again on prices' --about person:quinn >/dev/null
  # Routine chatter about the same unit never joins an ask.
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref c-1 --digest c --class routine \
    --title 'unit 123456 was cleaned' >/dev/null
  todo_at "$h" "$T_1000" sync >/dev/null
  out=$(todo_at "$h" "$T_1000" list --state open)
  assert_equals 3 "$(printf '%s\n' "$out" | grep -c .)" "a duplicate ask became its own line: $out"
  out=$(todo_at "$h" "$T_1000" find --about device:123456)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" 'find did not name the one line about the unit'
  assert_contains "$out" 'device:123456' 'find does not show the keys'
  out=$(todo_at "$h" "$T_1000" find --about person:quinn)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" 'an explicit key did not join the asks'
  # An ask about two open lines at once is its own line.
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref a-2 --digest a2 --class obligation \
    --title 'unit 654321 needs a part' >/dev/null
  todo_at "$h" "$T_1030" sync >/dev/null
  intake_at "$h" "$T_1100" observe --source C_DM --ref a-3 --digest a3 --class obligation \
    --title 'swap the part from 654321 into 123456' >/dev/null
  todo_at "$h" "$T_1100" sync >/dev/null
  assert_equals 2 "$(todo_at "$h" "$T_1100" find --about device:123456 | grep -c .)" \
    'an ask matching two lines was attached to one of them'
  assert_equals 1 "$(todo_at "$h" "$T_1100" find --about device:123456 --about device:654321 | grep -c .)" \
    'find does not narrow to the lines about every key'
  if todo_at "$h" "$T_1100" find >/dev/null 2>&1; then fail 'find with no key was accepted'; fi
  pass 'a new ask joins the one open line about the same thing, and find names the lines about a key'
}

test_a_held_decision_never_joins_an_ask() {
  local h
  h="$TMP_ROOT/about-held"
  new_home "$h"
  printf 'device \\b\\d{6}\\b\n' >"$h/config/todo-about"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref a-1 --digest a --class obligation \
    --title 'unit 123456 shows a fault' >/dev/null
  todo_at "$h" "$T_0900" sync >/dev/null
  printf -- '- [ ] fleet-a - Approve the restore on 123456 (since 2026-09-01) (hold: needs the captain) (hold-kind: captain)\n' \
    >"$h/backlog.md"
  todo_at "$h" "$T_1000" sync >/dev/null
  assert_equals 2 "$(todo_at "$h" "$T_1000" list --state open | grep -c .)" 'a held decision joined the open ask'
  : >"$h/backlog.md"
  todo_at "$h" "$T_1100" sync >/dev/null
  [ "$(field_of "$h" 'shows a fault' 2)" = open ] || fail 'releasing a hold closed the ask it shares a key with'
  [ "$(field_of "$h" 'Approve the restore' 2)" = closed ] || fail 'a released hold did not close its own line'
  pass 'a held decision never joins an ask, so releasing it leaves the ask open'
}

test_the_add_on_refuses_a_line_when_it_would_be_added() {
  local h out
  h="$TMP_ROOT/admit"
  new_home "$h"
  mkdir -p "$h/addon/hooks/todo-admit"
  printf 'path = %s\n' "$h/addon" >"$h/config/addon"
  cat >"$h/addon/hooks/todo-admit/10-rules" <<HOOK
#!/usr/bin/env bash
printf '%s %s %s\n' "\$FM_INTAKE_SOURCE" "\$FM_INTAKE_CLASS" "\$FM_INTAKE_TITLE" >>"$h/admit-calls"
case "\$FM_INTAKE_TITLE" in
  Announcement*) printf 'announcements are never lines\n'; exit 1 ;;
esac
HOOK
  chmod +x "$h/addon/hooks/todo-admit/10-rules"
  out=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n-1 --digest a --class obligation \
    --title 'Announcement: the office closes early')
  assert_contains "$out" 'refused' 'an ask the add-on refuses was recorded'
  assert_contains "$out" 'announcements are never lines' 'the refusal does not say why'
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n-2 --digest b --class obligation \
    --title 'Quinn asks for a quote' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n-3 --digest c --class routine \
    --title 'Announcement: lunch' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n-2 --digest b2 --class obligation >/dev/null
  todo_at "$h" "$T_0900" sync >/dev/null
  out=$(todo_at "$h" "$T_0900" list)
  assert_not_contains "$out" 'office closes early' 'a refused ask reached the store'
  assert_contains "$out" 'Quinn asks for a quote' 'an admitted ask was lost'
  assert_equals 2 "$(grep -c . "$h/admit-calls")" 'the rule ran on routine chatter or on a known ask'
  pass 'an add-on rule refuses a new ask when it would be added, and never sees routine chatter or a re-read'
}

test_every_line_has_an_ask_date() {
  local h id
  h="$TMP_ROOT/ask-date"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"k-1","source":"self-dm","ref":"m-1","class":"obligation","title":"Errand with no date","updated":'"$T_0900"'}'
  todo_at "$h" "$T_1000" sync --morning-json "$h/.lavish/today-2026-09-10.morning.json" >/dev/null
  id=$(field_of "$h" 'Errand with no date' 1)
  assert_equals "$T_1000" "$(jq -r '.asked_at' "$h/data/todo/items/$id.json")" 'an undated ask has no ask date'
  pass 'an ask no source dated keeps the time the store first saw it'
}

# The titles one front-page section shows, in order, read from the written page.
front_section() {  # <page file> <heading>
  sed -n "/<h2>$2<\/h2>/,/<\/[ou]l>/p" "$1" | grep -o 'class="who">[^<]*' | sed 's/^class="who">//'
}

test_a_home_without_colleagues_reads_waiting_on_you() {
  local h t front room before code
  h="$TMP_ROOT/front-neutral"
  new_home "$h"
  t=$T_0900
  sidecar "$h" 2026-09-10 \
'{"key":"k-bill","source":"mail","ref":"bill","class":"obligation","title":"Pay the water bill","asked_at":'"$((t - 2 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-bike","source":"mail","ref":"bike","class":"obligation","kind":"reply","title":"Answer the bike rental","asked_at":'"$((t - 86400))"',"updated":'"$t"'}'
  render_at "$h" "$T_1000"
  front="$h/.lavish/today-2026-09-10.html"
  room="$h/.lavish/today-2026-09-10-all.html"
  assert_equals 'Pay the water bill|Answer the bike rental|' \
    "$(front_section "$front" 'Waiting on you' | tr '\n' '|')" 'the open asks are not under Waiting on you'
  assert_not_contains "$(cat "$front")" 'Colleagues' 'a home without colleagues was told colleagues are asking'
  assert_not_contains "$(cat "$front")" 'Partners waiting on you' 'a partners heading showed with no partner lines'

  sidecar "$h" 2026-09-10 \
'{"key":"k-bill","source":"mail","ref":"bill","class":"obligation","title":"Pay the water bill","asked_at":'"$((t - 2 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-bike","source":"mail","ref":"bike","class":"obligation","kind":"reply","title":"Answer the bike rental","asked_at":'"$((t - 86400))"',"updated":'"$t"'},'\
'{"key":"k-shop","source":"mail","ref":"shop","class":"obligation","title":"Customer asks about an order","partner":true,"asked_at":'"$((t - 86400))"',"updated":'"$t"'}'
  render_at "$h" "$T_1000"
  assert_equals 'Customer asks about an order|' \
    "$(front_section "$front" 'Partners waiting on you' | tr '\n' '|')" 'a partner line lost its own heading'
  assert_equals 'Pay the water bill|Answer the bike rental|' \
    "$(front_section "$front" 'Waiting on you' | tr '\n' '|')" 'the other asks are not under Waiting on you'
  assert_not_contains "$(cat "$front")" 'Colleagues' 'a home without the setting was told colleagues are asking'

  # The setting brings the colleague wording back on the front page and leaves the back room alone.
  before=$(cat "$room")
  printf 'colleague_headings = true\n' >>"$h/config/channel-intake"
  intake_at "$h" "$T_1000" status >/dev/null || fail 'the intake gate refused the colleague headings setting'
  render_at "$h" "$T_1000"
  assert_equals 'Pay the water bill|Answer the bike rental|' \
    "$(front_section "$front" 'Colleagues asking you' | tr '\n' '|')" 'the setting did not bring back Colleagues asking you'
  assert_equals 'Customer asks about an order|' \
    "$(front_section "$front" 'Partners waiting on you' | tr '\n' '|')" 'the setting moved the partner line'
  assert_not_contains "$(cat "$front")" '<h2>Waiting on you</h2>' 'the neutral heading stayed with the setting on'
  assert_equals "$before" "$(cat "$room")" 'the setting changed the back room'

  sed -i.bak 's/^colleague_headings = true$/colleague_headings = maybe/' "$h/config/channel-intake"
  render_at "$h" "$T_1000" 2>/dev/null && code=0 || code=$?
  expect_code 2 "$code" 'the renderer accepted a colleague headings value that is not true or false'
  intake_at "$h" "$T_1000" status >/dev/null 2>&1 && code=0 || code=$?
  expect_code 2 "$code" 'the intake gate accepted a colleague headings value that is not true or false'
  pass 'a home without colleagues reads Waiting on you, and the setting brings Colleagues back on the front page only'
}

test_the_today_list_keeps_the_captains_order() {
  local h out id front code
  h="$TMP_ROOT/today-list"
  new_home "$h"
  todo_at "$h" "$T_0900" today add 'Send the drafts' >/dev/null
  todo_at "$h" "$T_0900" today add 'Call the supplier' >/dev/null
  todo_at "$h" "$T_0900" command 'add Review the guide' >/dev/null
  out=$(todo_at "$h" "$T_0900" command 'guide first')
  assert_contains "$out" 'TODO_CMD: first ' '"X first" did not move the line'
  # "add X first" puts a new line X at the top, not a line "X first" at the end.
  todo_at "$h" "$T_0900" command 'add Ring the bank first' >/dev/null
  assert_equals 'Ring the bank|Review the guide|Send the drafts|Call the supplier|' \
    "$(todo_at "$h" "$T_0900" today list | cut -f4 | tr '\n' '|')" '"add X first" did not put a new line X at the top'
  todo_at "$h" "$T_0900" today remove "$(field_of "$h" 'Ring the bank' 1)" >/dev/null
  out=$(todo_at "$h" "$T_0900" today add 'Call the supplier')
  assert_contains "$out" '(already)' 'adding a line already on the list again was not harmless'
  assert_equals 'Review the guide|Send the drafts|Call the supplier|' \
    "$(todo_at "$h" "$T_0900" today list | cut -f4 | tr '\n' '|')" 'the list is not in the order the captain gave'
  id=$(field_of "$h" 'Send the drafts' 1)
  todo_at "$h" "$T_0900" today move "$id" --position 1 >/dev/null
  todo_at "$h" "$T_0900" command 'done supplier' >/dev/null
  assert_equals '' "$(todo_at "$h" "$T_0900" recheck | grep 'recheck:')" 'a line of the captain own was listed for a source re-check'

  # Repeating an add that says "today" finds the same line instead of making a second one.
  todo_at "$h" "$T_0900" command 'add Book the van today' >/dev/null
  todo_at "$h" "$((T_0900 + 60))" command 'add Book the van today' >/dev/null
  assert_equals 1 "$(todo_at "$h" "$T_0900" today list | cut -f4 | grep -c '^Book the van$')"     'a repeated add made a second line'
  id=$(field_of "$h" 'Book the van' 1)
  todo_at "$h" "$T_0900" today remove "$id" >/dev/null
  # A closed line is refused, the same way the page verbs refuse it.
  out=$(todo_at "$h" "$T_0900" today add "$(field_of "$h" 'Call the supplier' 1)" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'today add put a closed line on the list'
  assert_contains "$out" 'is closed' 'the refusal does not say why'

  render_at "$h" "$T_1000"
  front="$h/.lavish/today-2026-09-10.html"
  assert_not_contains "$(cat "$front")" 'not re-checked' 'a line of the captain own taken off the list was counted as not re-checked'
  assert_equals 'Send the drafts|Review the guide|' "$(front_section "$front" Today | tr '\n' '|')" \
    'the front page does not show the Today list in his order, without the done line'

  # Unfinished lines carry over to the next day in the same order; the done one leaves.
  render_at "$h" "$T_NEXT_1000"
  assert_equals 'Send the drafts|Review the guide|' \
    "$(todo_at "$h" "$T_NEXT_1000" today list | cut -f4 | tr '\n' '|')" 'the list did not carry over in order'
  assert_equals 'Send the drafts|Review the guide|' \
    "$(front_section "$h/.lavish/today-2026-09-11.html" Today | tr '\n' '|')" 'the next day page lost the order'
  pass 'the Today list keeps the captain order through add, first, move and done, and carries over to the next day'
}

test_quiet_lines_leave_after_14_days_and_come_back() {
  local h id later
  h="$TMP_ROOT/quiet"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref q-routine --digest a \
    --title 'weekly stock note' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref q-colleague --digest a --class obligation \
    --title 'colleague question' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref q-partner --digest a --partner \
    --title 'customer note' >/dev/null
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref q-listed --digest a \
    --title 'note on my list' >/dev/null
  render_at "$h" "$T_1000"
  todo_at "$h" "$T_1000" today add "$(field_of "$h" 'note on my list' 1)" >/dev/null

  later=$((T_1000 + 13 * 86400))
  render_at "$h" "$later"
  assert_equals open "$(field_of "$h" 'weekly stock note' 2)" 'a line went quiet before 14 days'

  later=$((T_1000 + 15 * 86400))
  render_at "$h" "$later"
  id=$(field_of "$h" 'weekly stock note' 1)
  assert_equals closed "$(field_of "$h" 'weekly stock note' 2)" 'a line nobody waits on stayed after 14 quiet days'
  assert_equals quiet "$(jq -r '.closure.actor' "$h/data/todo/items/$id.json")" 'the quiet close is not labelled as such'
  assert_equals open "$(field_of "$h" 'colleague question' 2)" 'a colleague ask went quiet while the colleague waits'
  assert_equals open "$(field_of "$h" 'customer note' 2)" 'a customer-facing line went quiet'
  assert_equals open "$(field_of "$h" 'note on my list' 2)" 'a line on the Today list went quiet'
  assert_contains "$(cat "$h/.lavish/today-2026-09-25.html")" '0 closed today' 'a quiet line counted as closed on the front page'

  # Reopened by hand, it stays: the 14 days start again.
  todo_at "$h" "$((later + 300))" reopen --item "$id" --reason 'the captain wants it back' >/dev/null
  render_at "$h" "$((later + 600))"
  assert_equals open "$(field_of "$h" 'weekly stock note' 2)" 'a hand-reopened line went quiet again on the next sync'
  render_at "$h" "$((later + 15 * 86400))"
  assert_equals closed "$(field_of "$h" 'weekly stock note' 2)" 'a reopened line never went quiet again'

  # The other side writes again: the line comes back.
  later=$((later + 15 * 86400))
  intake_at "$h" "$((later + 600))" observe --source C_BRIEF --ref q-routine --digest b \
    --title 'weekly stock note' >/dev/null
  render_at "$h" "$((later + 1200))"
  assert_equals open "$(field_of "$h" 'weekly stock note' 2)" 'a quiet line did not come back when its source changed'
  pass 'an info line leaves after 14 quiet days, never a colleague ask, customer or Today line, and comes back'
}

test_the_front_page_is_calm() {
  local h t front room
  h="$TMP_ROOT/front"
  new_home "$h"
  printf 'colleague_headings = true\n' >>"$h/config/channel-intake"
  t=$T_0900
  sidecar "$h" 2026-09-10 \
'{"key":"k-down","source":"helpdesk","ref":"down","class":"outage","title":"Machine down at a customer","partner":true,"updated":'"$t"'},'\
'{"key":"k-colleague-down","source":"chat","ref":"cdown","class":"outage","title":"Office tap down","updated":'"$t"'},'\
'{"key":"k-call","source":"calendar","ref":"call","class":"deadline","title":"Supplier call","ends_at":"2026-09-10T17:00:00+02:00","updated":'"$t"'},'\
'{"key":"k-p7","source":"helpdesk","ref":"p7","class":"obligation","kind":"reply","title":"Partner seven days","partner_awaiting":true,"awaiting_since":'"$((t - 7 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-p6","source":"helpdesk","ref":"p6","class":"obligation","kind":"reply","title":"Partner six days","partner_awaiting":true,"awaiting_since":'"$((t - 6 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-p1","source":"helpdesk","ref":"p1","class":"obligation","kind":"reply","title":"Partner one day","partner_awaiting":true,"awaiting_since":'"$((t - 86400))"',"updated":'"$t"'},'\
'{"key":"k-ask","source":"chat","ref":"ask","class":"urgent","title":"Colleague asks for codes","asked_at":'"$((t - 10 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-fri","source":"calendar","ref":"fri","class":"deadline","title":"Friday review","ends_at":"2026-09-11T11:00:00+02:00","updated":'"$t"'},'\
'{"key":"k-cdl","source":"chat","ref":"cdl","class":"deadline","kind":"approval","title":"Colleague approval by noon","ends_at":"2026-09-10T12:00:00+02:00","asked_at":'"$((t - 3 * 86400))"',"updated":'"$t"'},'\
'{"key":"k-mon","source":"chat","ref":"mon","class":"deadline","kind":"approval","title":"Colleague approval due Monday","ends_at":"2026-09-14T10:00:00+02:00","asked_at":'"$((t - 2 * 86400))"',"updated":'"$t"'}'
  intake_at "$h" "$((t - 2 * 86400))" observe --source C_BRIEF --ref stale --digest a --class obligation \
    --title 'Unchecked colleague line' >/dev/null
  printf -- '- [ ] fm-q1 - Pick a model for the reports (hold-kind: captain) (hold: which one) (since: 2026-09-01)\n' \
    >"$h/backlog.md"
  render_at "$h" "$T_1000"
  front="$h/.lavish/today-2026-09-10.html"
  room="$h/.lavish/today-2026-09-10-all.html"

  assert_equals 'Machine down at a customer|Supplier call|Partner seven days|' \
    "$(front_section "$front" 'Needs you now' | tr '\n' '|')" \
    'Needs you now is not the three lines the rules pick, machine down, then due today, then the longest partner wait'
  assert_equals 'Partner six days|Partner one day|' \
    "$(front_section "$front" 'Partners waiting on you' | tr '\n' '|')" 'the partners waiting are wrong'
  # A colleague deadline due today stays with the colleagues; the week ends on Sunday, so Monday waits there too.
  assert_equals 'Colleague asks for codes|Colleague approval by noon|Colleague approval due Monday|Office tap down|' \
    "$(front_section "$front" 'Colleagues asking you' | tr '\n' '|')" 'a colleague ask rose above the list or went missing'
  assert_equals 'Friday review|' "$(front_section "$front" 'Later this week' | tr '\n' '|')" \
    'later this week is not the asks ending after today and by Sunday'
  assert_contains "$(cat "$front")" '1 not re-checked in the last day' 'an unchecked line was not counted on one line'
  assert_not_contains "$(cat "$front")" 'Unchecked colleague line' 'an unchecked line rendered as a row'
  assert_contains "$(cat "$front")" '1 question from Firstmate, asked in chat' 'the held question is not one count line'
  assert_not_contains "$(cat "$front")" 'Pick a model' 'a held question rendered as a row on the front page'
  assert_contains "$(cat "$front")" 'href="today-2026-09-10-all.html"' 'the front page has no link to the back room'
  assert_contains "$(cat "$room")" 'Unchecked colleague line' 'the back room lost a line'
  assert_contains "$(cat "$room")" 'Partner seven days' 'the back room lost a line'
  pass 'the front page shows at most three lines by the rules, the list, partners then colleagues, and counts the rest'
}

test_the_today_list_keeps_the_captains_order
test_quiet_lines_leave_after_14_days_and_come_back
test_the_front_page_is_calm
test_a_home_without_colleagues_reads_waiting_on_you
test_done_on_a_held_decision_files_a_reconcile_request
test_the_recheck_rolls_through_every_line_in_three_working_days
test_lines_a_pass_could_not_read_do_not_hold_the_share
test_a_new_ask_about_an_open_line_joins_it
test_a_held_decision_never_joins_an_ask
test_the_add_on_refuses_a_line_when_it_would_be_added
test_every_line_has_an_ask_date
test_a_pass_judges_a_record_from_before_the_flag_by_its_aliases
test_an_addon_extends_the_store_through_verbs_and_marks
test_hand_over_moves_an_item_to_waiting_on_its_owner
test_an_addons_own_source_change_does_not_reopen_the_item
test_a_source_that_resolves_a_handed_over_item_wins
test_a_ledger_partner_awaiting_ask_ranks_with_the_morning_ones
test_an_addon_runs_ticket_verbs_on_the_contract
test_an_age_counts_calendar_days_across_a_clock_change
test_time_bound_asks_expire_after_their_end
test_expiry_leaves_marked_lines_to_the_captain
test_a_lapsed_park_no_longer_holds_off_expiry
test_an_expired_item_comes_back_when_its_end_moves_later
test_an_expired_item_relisted_without_an_end_comes_back
test_verification_is_never_renewed_by_sync
test_done_survives_and_a_new_ask_resurfaces_once
test_edit_after_resolution_reopens_once
test_a_sweep_reopen_hides_its_source_label
test_commands_refuse_stale_pages_and_track_handoffs
test_missing_input_closes_nothing_and_release_is_scoped
test_identity_snooze_and_counter
test_reopen_returns_a_handed_over_item_to_the_captain
test_unverified_holds_stay_off_the_page
test_routine_activity_keeps_its_not_re_checked_fold
test_a_retired_ledger_record_closes_its_routine_item
test_routine_fold_is_capped
test_sync_prunes_only_retired_routine_records
test_a_marked_routine_line_is_never_retired_by_the_intake
test_a_revived_routine_thread_still_retires_and_prunes
test_partner_awaiting_asks_rank_above_every_class
test_awaiting_partner_asks_lead_the_13_oct_page
test_each_row_marks_where_it_came_from
test_a_merged_row_marks_the_source_it_presents
test_a_pass_rechecks_open_items_and_counts_the_misses
test_ranking_follows_partners_and_the_oldest_ask
test_page_bugs_stay_fixed
test_held_decisions_stay_in_the_tooling_fold_by_default
test_held_decisions_need_you_when_the_home_asks
test_a_held_decision_shows_its_readable_reason

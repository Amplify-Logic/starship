#!/usr/bin/env bash
# Behavior tests for bin/fm-mail-answered.sh, which closes a mail ask once the
# owner has replied in its thread.
#
# Contracts under test, through the script, bin/fm-channel-intake.sh observe
# and bin/fm-todo.sh, with a fake reader that serves fixture threads:
#   - A line the owner answered, followed only by a noreply notice, closes
#     with actor mail-answered and the reply's message id as evidence.
#   - A person writing after the owner's reply keeps the line open.
#   - A line reopened after a close stays open until a newer owner reply.
#   - A promise line on the same thread is never closed, nor a line with a
#     due mark.
#   - A mixed-case thread id reaches the reader unchanged.
#   - It is inert until enabled, idle on a weekend and outside its hours, a
#     failed read closes nothing, and arm and disarm bind and remove the
#     watcher check.
# No case reads a real mailbox.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANSWERED="$ROOT/bin/fm-mail-answered.sh"
TODO="$ROOT/bin/fm-todo.sh"
INTAKE="$ROOT/bin/fm-channel-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-mail-answered-tests)

# Thursday 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600
T_1000=1789027200
T_1100=1789030800
T_1200=1789034400
# Saturday 2026-09-12, 11:00 local.
T_SAT=$((T_1100 + 2 * 86400))

# new_home <dir>: a home whose intake reads one mail source, with the check
# enabled and a fake reader. The reader logs each call to calls.log and
# prints threads/<id>.jsonl, or fails when threads/<id>.fail exists.
new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/data/channel-intake" "$h/threads"
  printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\n' >"$h/config/channel-intake"
  printf 'M_MAIL\tgmail\towner mail\n' >"$h/data/channel-intake/sources.tsv"
  : >"$h/backlog.md"
  cat >"$h/reader.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'$h/calls.log'
[ "\$1" = thread ] || exit 9
[ ! -e '$h/threads/'"\$2"'.fail' ] || exit 3
cat '$h/threads/'"\$2"'.jsonl' 2>/dev/null
EOF
  chmod +x "$h/reader.sh"
  printf 'enabled = true\nreader = %s\n' "$h/reader.sh" >"$h/config/mail-answered"
}

intake_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@" >/dev/null
}

todo_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$TODO" "$@"
}

answered_at() {
  local h=$1 now=$2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MAIL_ANSWERED_NOW="$now" FM_TODO_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$ANSWERED" check
}

# ask <home> <thread id> <title>: a mail ask asked at 09:00, synced into the store.
ask() {
  intake_at "$1" "$T_0900" observe --source M_MAIL --ref "thread-$2" --class obligation \
    --digest "ask $2" --title "$3" --source-epoch "$T_0900"
  todo_at "$1" "$T_0900" sync >/dev/null
}

# msg <id> <sent_at> <from> <from_owner> [headers-json]
msg() {
  local headers='{}'
  [ "$#" -lt 5 ] || headers=$5
  printf '{"id":"%s","sent_at":%s,"from":"%s","from_owner":%s,"headers":%s}\n' "$1" "$2" "$3" "$4" "$headers"
}

id_of() {
  todo_at "$1" "$T_1200" list | awk -F '\t' -v t="$2" 'index($5, t) { print $1; exit }'
}

state_of() {
  todo_at "$1" "$T_1200" list | awk -F '\t' -v t="$2" 'index($5, t) { print $2; exit }'
}

closure_of() {
  python3 -c 'import json, sys; c = json.load(open(sys.argv[1]))["closure"]; print(c.get("actor", ""), "|", c.get("evidence", ""))' \
    "$1/data/todo/items/$2.json"
}

test_an_owner_reply_then_a_noreply_notice_closes_the_ask() {
  local h out id
  h="$TMP_ROOT/answered"
  new_home "$h"
  ask "$h" AbC9xY 'Quinn asks for the quote'
  {
    msg q-1 "$T_0900" 'Quinn <quinn@example.com>' false
    msg o-1 "$T_1000" 'Owner <owner@example.com>' true
    msg n-1 "$T_1100" 'Shop <no-reply@shop.example>' false
  } >"$h/threads/AbC9xY.jsonl"
  out=$(answered_at "$h" "$T_1100") || fail "the check failed: $out"
  id=$(id_of "$h" 'Quinn asks for the quote')
  assert_contains "$out" "$id" 'the closing line does not name the closed line'
  assert_equals closed "$(state_of "$h" 'Quinn asks for the quote')" 'the answered ask stayed open'
  assert_equals 'mail-answered | Owner replied by mail, message o-1' "$(closure_of "$h" "$id")" 'wrong actor or evidence'
  assert_equals 'thread AbC9xY' "$(cat "$h/calls.log")" 'the reader did not get the thread id in its original case'
  out=$(answered_at "$h" "$T_1100")
  assert_equals '' "$out" 'a run that closed nothing printed'
  pass 'an owner reply followed only by a noreply notice closes the ask with actor mail-answered'
}

test_automated_messages_are_recognised_by_every_rule() {
  local h out
  h="$TMP_ROOT/automated"
  new_home "$h"
  printf 'enabled = true\nreader = %s\nskip_from = robot\n' "$h/reader.sh" >"$h/config/mail-answered"
  ask "$h" T2 'Robin asks about delivery'
  {
    msg o-1 "$T_1000" 'Owner <owner@example.com>' true
    msg a-1 "$((T_1000 + 1))" 'List <people@lists.example>' false '{"list-id":"<people.lists.example>"}'
    msg a-2 "$((T_1000 + 2))" 'Bulk <sales@shop.example>' false '{"Precedence":"Bulk"}'
    msg a-3 "$((T_1000 + 3))" 'Away <robin@example.com>' false '{"AUTO-SUBMITTED":"auto-replied"}'
    msg a-4 "$((T_1000 + 4))" 'MAILER-DAEMON@example.com' false
    msg a-5 "$((T_1000 + 5))" 'Build <ci-robot@example.com>' false
  } >"$h/threads/T2.jsonl"
  out=$(answered_at "$h" "$T_1100")
  assert_equals closed "$(state_of "$h" 'Robin asks about delivery')" "automated messages kept the ask open: $out"
  pass 'List-Id, Precedence, Auto-Submitted, a daemon address and a skip_from word all count as automated'
}

test_a_person_writing_after_the_reply_keeps_it_open() {
  local h out
  h="$TMP_ROOT/person"
  new_home "$h"
  ask "$h" T3 'Sam asks for a call'
  {
    msg o-1 "$T_1000" 'Owner <owner@example.com>' true
    msg s-2 "$T_1100" 'Sam <sam@example.com>' false '{"Auto-Submitted":"no"}'
  } >"$h/threads/T3.jsonl"
  out=$(answered_at "$h" "$T_1100")
  assert_equals '' "$out" 'a run that closed nothing printed'
  assert_equals open "$(state_of "$h" 'Sam asks for a call')" 'a reply the other side answered closed the ask'
  # The owner's own out-of-office notice is not a reply either.
  ask "$h" T4 'Kim asks for the invoice'
  msg o-2 "$T_1000" 'Owner <owner@example.com>' true '{"Auto-Submitted":"auto-replied"}' >"$h/threads/T4.jsonl"
  answered_at "$h" "$T_1100" >/dev/null
  assert_equals open "$(state_of "$h" 'Kim asks for the invoice')" "the owner's auto-reply closed the ask"
  pass 'a person writing after the reply, or only an owner auto-reply, keeps the ask open'
}

test_a_reopened_line_waits_for_a_newer_reply() {
  local h id
  h="$TMP_ROOT/reopened"
  new_home "$h"
  ask "$h" T5 'Quinn asks for the manual'
  msg o-1 "$T_1000" 'Owner <owner@example.com>' true >"$h/threads/T5.jsonl"
  answered_at "$h" "$T_1000" >/dev/null
  id=$(id_of "$h" 'Quinn asks for the manual')
  assert_equals closed "$(state_of "$h" 'Quinn asks for the manual')" 'the answered ask stayed open'
  todo_at "$h" "$T_1100" reopen --item "$id" --reason 'not really answered' >/dev/null || fail 'reopen failed'
  assert_equals '' "$(answered_at "$h" "$T_1100")" 'a reopened line closed again on the same reply'
  assert_equals open "$(state_of "$h" 'Quinn asks for the manual')" 'a reopened line closed again on the same reply'
  msg o-2 "$T_1100" 'Owner <owner@example.com>' true >>"$h/threads/T5.jsonl"
  answered_at "$h" "$T_1200" >/dev/null
  assert_equals closed "$(state_of "$h" 'Quinn asks for the manual')" 'a newer reply did not close the reopened line'
  assert_contains "$(closure_of "$h" "$id")" 'message o-2' 'the second close does not name the newer reply'
  pass 'a reopened line stays open without a newer reply and closes on one'
}

test_a_promise_or_due_line_on_the_thread_is_never_closed() {
  local h promise
  h="$TMP_ROOT/promise"
  new_home "$h"
  ask "$h" T6 'Sam asks for the report'
  # The promise in the owner's reply is its own line. Observed again under its
  # dedup key from its thread, it also carries a thread alias, and still never
  # closes on that thread's owner reply.
  intake_at "$h" "$T_1000" observe --source M_MAIL --ref promise-o-1 --class obligation \
    --title 'Sam: you promised the report' --digest 'report by Friday' --source-epoch "$T_0900" \
    --about promise:o-1 --dedup-key sam-promise
  intake_at "$h" "$T_1000" observe --source M_MAIL --ref thread-P6 --class obligation \
    --title 'Sam: you promised the report' --digest 'report by Friday' --source-epoch "$T_0900" \
    --dedup-key sam-promise
  ask "$h" T7 'Bo asks for a date'
  todo_at "$h" "$T_1000" sync >/dev/null
  promise=$(id_of "$h" 'you promised the report')
  [ -n "$promise" ] || fail 'the promise is not a line'
  grep -q 'M_MAIL:thread-P6' "$h/data/todo/items/$promise.json" || fail 'the promise line does not carry the thread alias'
  todo_at "$h" "$T_1000" mark --item "$(id_of "$h" 'Bo asks for a date')" --name due --text 2026-09-11 >/dev/null \
    || fail 'the due mark was refused'
  msg o-1 "$T_1000" 'Owner <owner@example.com>' true >"$h/threads/T6.jsonl"
  msg o-1 "$T_1000" 'Owner <owner@example.com>' true >"$h/threads/P6.jsonl"
  msg o-9 "$T_1000" 'Owner <owner@example.com>' true >"$h/threads/T7.jsonl"
  answered_at "$h" "$T_1100" >/dev/null
  assert_equals closed "$(state_of "$h" 'Sam asks for the report')" 'the answered ask stayed open'
  assert_equals open "$(state_of "$h" 'you promised the report')" 'the promise line was closed'
  assert_equals open "$(state_of "$h" 'Bo asks for a date')" 'a line with a due mark was closed'
  pass 'a promise line on the same thread and a due-marked line are never closed'
}

test_inert_idle_and_failed_reads_close_nothing() {
  local h
  h="$TMP_ROOT/idle"
  new_home "$h"
  ask "$h" T8 'Mo asks for access'
  msg o-1 "$T_1000" 'Owner <owner@example.com>' true >"$h/threads/T8.jsonl"
  printf 'reader = %s\n' "$h/reader.sh" >"$h/config/mail-answered"
  answered_at "$h" "$T_1100" >/dev/null || fail 'a disabled run failed'
  [ ! -e "$h/calls.log" ] || fail 'a disabled home called the reader'
  printf 'enabled = true\nreader = %s\nhours = 12:30-17:00\n' "$h/reader.sh" >"$h/config/mail-answered"
  answered_at "$h" "$T_1100" >/dev/null
  answered_at "$h" "$T_SAT" >/dev/null
  [ ! -e "$h/calls.log" ] || fail 'a run outside its hours or on a weekend called the reader'
  : >"$h/threads/T8.fail"
  answered_at "$h" "$((T_1200 + 3600))" >/dev/null 2>&1
  [ -s "$h/calls.log" ] || fail 'a run inside its hours did not read'
  assert_equals open "$(state_of "$h" 'Mo asks for access')" 'a failed read closed the line'
  rm -f "$h/threads/T8.fail"
  printf 'not json\n' >"$h/threads/T8.jsonl"
  answered_at "$h" "$((T_1200 + 3600))" >/dev/null 2>&1
  assert_equals open "$(state_of "$h" 'Mo asks for access')" 'a malformed read closed the line'
  printf 'enabled = true\nreader = %s\nsecret = x\n' "$h/reader.sh" >"$h/config/mail-answered"
  if answered_at "$h" "$T_1100" >/dev/null 2>&1; then fail 'an unknown config key was accepted'; fi
  pass 'it is inert until enabled, idle outside its hours and on a weekend, and a failed read closes nothing'
}

test_arm_and_disarm_bind_the_watcher_check() {
  local h out
  h="$TMP_ROOT/arm"
  new_home "$h"
  out=$(FM_HOME="$h" "$ANSWERED" arm) || fail "arm failed: $out"
  assert_present "$h/state/mail-answered.check.sh" 'arm wrote no shim'
  assert_present "$h/state/mail-answered.check-trust" 'arm bound no trust'
  assert_contains "$(cat "$h/state/mail-answered.check.sh")" "fm-mail-answered.sh check" 'the shim does not run the check'
  out=$(FM_HOME="$h" "$ANSWERED" disarm) || fail "disarm failed: $out"
  assert_absent "$h/state/mail-answered.check.sh" 'disarm left the shim'
  assert_absent "$h/state/mail-answered.check-trust" 'disarm left the trust binding'
  pass 'arm registers the watcher check and disarm removes it'
}

fm_test_run \
  test_an_owner_reply_then_a_noreply_notice_closes_the_ask \
  test_automated_messages_are_recognised_by_every_rule \
  test_a_person_writing_after_the_reply_keeps_it_open \
  test_a_reopened_line_waits_for_a_newer_reply \
  test_a_promise_or_due_line_on_the_thread_is_never_closed \
  test_inert_idle_and_failed_reads_close_nothing \
  test_arm_and_disarm_bind_the_watcher_check

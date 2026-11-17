#!/usr/bin/env bash
# Behavior tests for the direct line to a second mate (bin/fm-direct-line.sh,
# bin/fm-direct-line-lib.sh, bin/fm-pane-writer-lib.sh): resolution only
# through the registry with every home assertion, the parent-channel copy that
# comes before any typing, delivery through the real desk-voice into a
# stand-in primary pane, once per client id, mailbox ordering, the captain's
# chat answer closing a held call, the "talking with the captain" state and
# what it holds back (the steering-inbox doorbell, the pane-writer lock, the
# control plane), and the versioned JSON reads. Every home is a lab home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DL="$ROOT/bin/fm-direct-line.sh"
DESK="$ROOT/bin/fm-desk-voice.sh"
LAB="$ROOT/bin/fm-lab-home.sh"
TMP_ROOT=$(fm_test_tmproot fm-direct-line)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

export FM_DESK_VOICE_RING_DELAYS=
NOTIFY_BIN="$TMP_ROOT/notify-bin"
mkdir -p "$NOTIFY_BIN"
printf '#!/bin/sh\nexit 0\n' > "$NOTIFY_BIN/osascript"
chmod +x "$NOTIFY_BIN/osascript"
export PATH="$NOTIFY_BIN:$PATH"

new_home() {  # <name>
  "$LAB" create "$TMP_ROOT/$1" >/dev/null || return 1
  mkdir -p "$TMP_ROOT/$1/config" "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/data"
  (cd "$TMP_ROOT/$1" && pwd -P)
}

# shellcheck source=tests/desk-send-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/desk-send-fixture.sh"

# A parent lab home with <mate> registered as a local second mate at <home>.
make_parent() {  # <name> <mate-id> <mate-home>
  local parent
  parent=$(new_home "$1") || return 1
  printf -- '- %s - Music crew for one project (home: %s; scope: music work; projects: sample; added 2026-11-17)\n' \
    "$2" "$3" > "$parent/data/secondmates.md"
  printf '%s\n' "$parent"
}

# Seed <home> as second mate <id> of <parent>, opted in unless <direct> is 0.
seed_mate() {  # <home> <id> <parent> [direct]
  mkdir -p "$1/data"
  {
    printf 'You are a persistent second mate.\n\n# Charter\nMusic.\n'
    [ "${4:-1}" = 0 ] || printf '\n# Direct line to the captain\nDirect line: on\n'
  } > "$1/data/charter.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$3" > "$1/.fm-secondmate-parent"
  printf '%s' "$2" > "$1/.fm-secondmate-home"
}

dl() {  # <parent> <mate-home> <args...> -> fm-direct-line.sh against the stand-in pane
  local parent=$1 dir="$2/fixture"
  shift 2
  (
    unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
      FM_BACKEND_HERDR_BIN FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND \
      FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
    PATH="$dir/bin:$PATH" FM_FAKE_HERDR_DIR="$dir" FM_HOME="$parent" \
      FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.1 "$DL" "$@"
  )
}

typed_count() {  # <mate-home>
  herdr_calls "$1" pane send-text | wc -l | tr -d ' '
}

mailbox_count() {  # <mate-home>
  find "$1/state/desk-voice/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# A typed mate with its parent, or skip the case.
typed_fixture() {  # <name> -> "<parent>\t<mate>"
  local mate parent
  mate=$(DESK_FIXTURE_HOME_ENV=self desk_send_fixture "$1-mate") || return 1
  mate=$(cd "$mate" && pwd -P)
  parent=$(make_parent "$1-parent" music "$mate") || return 1
  seed_mate "$mate" music "$parent"
  printf '%s\t%s\n' "$parent" "$mate"
}

test_send_copies_to_the_parent_then_types_once() {
  local pair parent mate out again note talking
  pair=$(typed_fixture send) || { desk_send_skip direct-line-send; return 0; }
  IFS=$'\t' read -r parent mate <<<"$pair"
  out=$(dl "$parent" "$mate" send music --client-id deck-0001 -- "Bounce the chorus stems") \
    || fail "send failed: $out"
  assert_equals fm-direct-line-delivery.v1 "$(jq -r .schema <<<"$out")" "the delivery read is versioned"
  assert_equals typed "$(jq -r .state <<<"$out")" "the message is typed into the mate's pane"
  assert_equals copied "$(jq -r .parent_copy <<<"$out")" "the message is copied to the parent channel"
  assert_contains "$(herdr_calls "$mate" pane send-text)" "Bounce the chorus stems" "the words reach the mate's own pane"
  note=$(cat "$parent/state/music.status")
  assert_contains "$note" "note [at=" "the parent copy is a stamped note line"
  assert_contains "$note" "owner to music by direct line (msg deck-0001): Bounce the chorus stems" \
    "the parent channel carries the captain's words"
  again=$(dl "$parent" "$mate" send music --client-id deck-0001 -- "Bounce the chorus stems") \
    || fail "retry failed: $again"
  assert_equals typed "$(jq -r .state <<<"$again")" "a retried client id reports the first outcome"
  assert_equals 1 "$(typed_count "$mate")" "a retried client id types nothing more"
  assert_equals 1 "$(grep -c 'msg deck-0001' "$parent/state/music.status")" "a retried client id copies nothing more"
  talking=$(dl "$parent" "$mate" talking music) || fail "the mate must read as talking: $talking"
  assert_equals owner-message "$(jq -r .reason <<<"$talking")" "the captain's message starts the conversation"
  out=$(dl "$parent" "$mate" delivery music deck-0001) || fail "delivery read failed: $out"
  assert_equals typed "$(jq -r .state <<<"$out")" "a caller can poll the delivery"
  desk_send_done "$mate"
  pass "fm-direct-line send: copies to the parent first, types once per client id, starts the conversation"
}

test_send_refuses_without_every_assertion() {
  local mate parent other out
  mate=$(new_home refuse-mate)
  parent=$(make_parent refuse-parent music "$mate")
  seed_mate "$mate" music "$parent" 0
  if out=$(dl "$parent" "$mate" send music --client-id deck-0002 -- "hello" 2>&1); then
    fail "a charter without the opt-in must refuse: $out"
  fi
  assert_contains "$out" "does not opt in" "the refusal names the missing opt-in"
  seed_mate "$mate" music "$parent"
  printf 'drums' > "$mate/.fm-secondmate-home"
  out=$(dl "$parent" "$mate" send music --client-id deck-0002 -- "hello" 2>&1) && fail "a mismatched identity must refuse"
  assert_contains "$out" "names itself 'drums'" "the refusal names the other identity"
  other=$(new_home refuse-other-parent)
  seed_mate "$mate" music "$other"
  out=$(dl "$parent" "$mate" send music --client-id deck-0002 -- "hello" 2>&1) && fail "another parent's mate must refuse"
  assert_contains "$out" "belongs to another home" "the refusal names the foreign binding"
  out=$(dl "$parent" "$mate" send drums --client-id deck-0002 -- "hello" 2>&1) && fail "an unregistered id must refuse"
  printf -- '- music - Remote crew (host: box; root: /srv/fm; home: /srv/home; scope: music; projects: sample; added 2026-11-17)\n' \
    > "$parent/data/secondmates.md"
  out=$(dl "$parent" "$mate" send music --client-id deck-0002 -- "hello" 2>&1) && fail "a remote mate must refuse"
  assert_contains "$out" "remote second mate has no direct line" "the refusal names the remote route"
  [ ! -e "$parent/state/music.status" ] || fail "a refused send must copy nothing to the parent"
  [ ! -e "$mate/state/direct-line/deliveries" ] || fail "a refused send must record nothing"
  out=$(FM_HOME='' "$DL" list 2>&1) && fail "an unset FM_HOME must refuse"
  pass "fm-direct-line send: refuses unless the registry, identity, binding and opt-in all agree"
}

test_mailbox_keeps_the_captains_order() {
  local mate parent out
  mate=$(new_home order-mate)
  parent=$(make_parent order-parent music "$mate")
  seed_mate "$mate" music "$parent"
  # No live primary: the first message lands in the mailbox.
  out=$(dl "$parent" "$mate" send music --client-id deck-0003 -- "first") || fail "send failed: $out"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "with no live pane the message goes to the mailbox"
  out=$(dl "$parent" "$mate" send music --client-id deck-0004 -- "second") || fail "send failed: $out"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "a later message follows the undrained one"
  assert_equals 2 "$(mailbox_count "$mate")" "both wait in the mailbox, in order"
  pass "fm-direct-line send: the mailbox keeps the captain's messages in order"
}

test_typed_send_follows_an_undrained_mailbox() {
  local pair parent mate out
  pair=$(typed_fixture follow) || { desk_send_skip direct-line-follow; return 0; }
  IFS=$'\t' read -r parent mate <<<"$pair"
  mkdir -p "$mate/state/desk-voice/inbox"
  printf '{"transcript":"earlier"}\n' > "$mate/state/desk-voice/inbox/20261117T000000Z-aaaa.json"
  out=$(dl "$parent" "$mate" send music --client-id deck-0005 -- "later") || fail "send failed: $out"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "a live pane still waits behind an undrained message"
  assert_equals 0 "$(typed_count "$mate")" "nothing jumps the queue"
  desk_send_done "$mate"
  pass "fm-direct-line send: a live pane never jumps an undrained mailbox message"
}

test_chat_answer_closes_the_held_call() {
  local mate parent fakebin out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  mate=$(new_home hold-mate)
  parent=$(make_parent hold-parent music "$mate")
  seed_mate "$mate" music "$parent"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" hold mix-call \
    --title "Pick the mix" --reason "captain picks mix A or B" >/dev/null 2>&1 \
    || fail "could not hold the call in the mate home"
  PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call >/dev/null 2>&1 \
    || fail "the call must be open before the answer"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0006 --answers mix-call -- "Mix B please") \
    || fail "send with --answers failed: $out"
  assert_equals answered "$(jq -r .hold.result <<<"$out")" "the chat answer closes the held call"
  if PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call >/dev/null 2>&1; then
    fail "the held call must be closed after the chat answer"
  fi
  assert_contains "$(cat "$mate/data/backlog.md")" "Mix B please" "the captain's own words are recorded"
  pass "fm-direct-line send --answers: a chat answer closes the held call by script"
}

test_talking_holds_back_every_nudge() {
  local mate parent rec rc out holder
  mate=$(new_home talk-mate)
  parent=$(make_parent talk-parent music "$mate")
  seed_mate "$mate" music "$parent"
  printf 'kind=secondmate\nhome=%s\nwindow=fm-x:w1:p1\nbackend=herdr\n' "$mate" > "$parent/state/music.meta"
  mkdir -p "$parent/state/music.inbox"
  rec="$parent/state/music.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\n--\nhello\n' > "$rec"
  out=$(FM_HOME="$mate" "$DL" waiting --for 600) || fail "waiting failed: $out"
  assert_equals waiting-on-owner "$(jq -r .reason <<<"$out")" "a declared wait reads as talking"
  rc=0
  ( FM_HOME="$parent" STATE="$parent/state"; . "$ROOT/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_ring herdr fm-x:w1:p1 "$rec" fm-music ) || rc=$?
  assert_equals 4 "$rc" "the doorbell is deferred while the mate talks with the captain"
  FM_HOME="$mate" "$DL" waiting --clear >/dev/null || fail "waiting --clear failed"
  out=$(FM_HOME="$parent" "$DL" talking music) && fail "a cleared wait must not read as talking: $out"
  # Another writer holds the mate's pane: the doorbell defers, never interleaves.
  sleep 30 & holder=$!
  mkdir -p "$mate/state/desk-voice/.send.lock"
  printf '%s\n' "$holder" > "$mate/state/desk-voice/.send.lock/pid"
  rc=0
  ( FM_HOME="$parent" STATE="$parent/state"; . "$ROOT/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_ring herdr fm-x:w1:p1 "$rec" fm-music ) || rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_equals 4 "$rc" "the doorbell defers while another writer holds the pane"
  rm -rf "$mate/state/desk-voice/.send.lock"
  # A ship's record has no home of its own: the lock is not involved.
  ( . "$ROOT/bin/fm-direct-line-lib.sh"
    if fm_direct_line_inbox_record_home "$parent/state/ship.inbox/001.msg"; then exit 1; fi ) \
    || fail "a record for a task with no second mate home must resolve no home"
  pass "fm-direct-line: talking with the captain or a busy pane defers the parent's doorbell"
}

test_list_and_conversation_reads_are_versioned() {
  local mate parent out
  mate=$(new_home read-mate)
  parent=$(make_parent read-parent music "$mate")
  seed_mate "$mate" music "$parent"
  printf -- '- plain - Plain crew (home: %s; scope: other; projects: sample; added 2026-11-17)\n' \
    "$TMP_ROOT/none" >> "$parent/data/secondmates.md"
  out=$(FM_HOME="$parent" "$DL" list) || fail "list failed: $out"
  assert_equals fm-direct-line-mates.v1 "$(jq -r .schema <<<"$out")" "list is versioned"
  assert_equals true "$(jq -r '.mates[] | select(.id == "music") | .direct_line' <<<"$out")" "the opted-in mate is listed as direct-line"
  assert_equals false "$(jq -r '.mates[] | select(.id == "plain") | .direct_line' <<<"$out")" "another mate is not"
  out=$(FM_HOME="$parent" "$DL" conversation music) || fail "conversation failed: $out"
  assert_equals fm-web-conversation.v1 "$(jq -r .schema <<<"$out")" "the conversation read is versioned"
  assert_equals offline "$(jq -r .state <<<"$out")" "a mate with no session reads as offline"
  pass "fm-direct-line list and conversation: versioned JSON reads"
}

test_control_plane_refuses_a_talking_mate() {
  local mate parent out
  mate=$(new_home control-mate)
  parent=$(make_parent control-parent music "$mate")
  seed_mate "$mate" music "$parent"
  FM_HOME="$mate" "$DL" waiting --for 600 >/dev/null || fail "waiting failed"
  printf 'kind=secondmate\nhome=%s\nworktree=%s\nwindow=fm-x:w1:p1\nbackend=herdr\nherdr_session=fm-x\nharness=claude\n' \
    "$mate" "$mate" > "$parent/state/music.meta"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music interrupt 2>&1) && fail "a talking mate must not be interrupted: $out"
  assert_contains "$out" "talking with its owner" "the refusal names the conversation"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music relaunch 2>&1) && fail "a talking mate must not be relaunched: $out"
  assert_contains "$out" "talking with its owner" "relaunch is refused too"
  # With the captain's word the guard steps aside (this fixture's endpoint then
  # stops it, which is all this case needs to see).
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music interrupt --owner-approved 2>&1) || true
  assert_not_contains "$out" "talking with its owner" "--owner-approved passes the conversation guard"
  pass "fm-control: refuses a direct-line mate talking with the captain unless the captain asked"
}

test_send_copies_to_the_parent_then_types_once
test_send_refuses_without_every_assertion
test_mailbox_keeps_the_captains_order
test_typed_send_follows_an_undrained_mailbox
test_chat_answer_closes_the_held_call
test_talking_holds_back_every_nudge
test_list_and_conversation_reads_are_versioned
test_control_plane_refuses_a_talking_mate

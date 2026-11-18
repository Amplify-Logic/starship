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

# Seed <home> as second mate <id> of <parent>, opted in on both sides unless
# <direct> is 0 (charter and parent both off) or charter (charter only).
seed_mate() {  # <home> <id> <parent> [1|0|charter]
  mkdir -p "$1/data"
  {
    printf 'You are a persistent second mate.\n\n# Charter\nMusic.\n'
    [ "${4:-1}" = 0 ] || printf '\n# Direct line to the captain\nDirect line: on\n'
  } > "$1/data/charter.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$3" > "$1/.fm-secondmate-parent"
  printf '%s' "$2" > "$1/.fm-secondmate-home"
  [ "${4:-1}" = 1 ] || return 0
  FM_HOME="$3" "$DL" enable "$2" >/dev/null 2>&1 || true
}

# A live stand-in primary holding <home>'s session lock; prints its pid.
LIVE_PIDS_FILE="$TMP_ROOT/live-pids"
live_primary() {  # <home>
  local pid
  sleep 300 >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$LIVE_PIDS_FILE"
  mkdir -p "$1/state"
  printf '%s\n' "$pid" > "$1/state/.lock"
  printf '%s\n' "$pid"
}
stop_live_primaries() {
  local pid
  [ -f "$LIVE_PIDS_FILE" ] || return 0
  while IFS= read -r pid; do kill "$pid" 2>/dev/null; done < "$LIVE_PIDS_FILE"
  rm -f "$LIVE_PIDS_FILE"
}
trap 'stop_live_primaries; fm_test_cleanup' EXIT

# The parent-side record directory for <mate> in <parent>.
parent_dl_dir() {  # <parent> <mate>
  printf '%s/state/direct-line/%s\n' "$1" "$2"
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
  again=$(dl "$parent" "$mate" send music --client-id deck-0001 -- "Bounce the verse stems" 2>&1) \
    && fail "a reused client id with other words must refuse: $again"
  assert_contains "$again" "different message" "the refusal names the reused id"
  assert_equals 1 "$(typed_count "$mate")" "a reused client id types nothing"
  pass "fm-direct-line send: copies to the parent first, types once per client id, starts the conversation"
}

# Make <mate-home>'s stand-in pane take <secs> seconds to accept typed text,
# so a send outlives a short FM_DIRECT_LINE_SEND_TIMEOUT mid-typing.
slow_pane() {  # <mate-home> <secs>
  local fb="$1/fixture/bin"
  mv "$fb/herdr" "$fb/herdr.real"
  # shellcheck disable=SC2016 # expanded by the generated script
  printf '#!/usr/bin/env bash\n[ "${1:-} ${2:-}" != "pane send-text" ] || sleep %s\nexec "$(dirname "$0")/herdr.real" "$@"\n' \
    "$2" > "$fb/herdr"
  chmod +x "$fb/herdr"
}

test_timed_out_send_still_submits_its_words() {
  local pair parent mate out rc
  pair=$(typed_fixture slow) || { desk_send_skip direct-line-slow; return 0; }
  IFS=$'\t' read -r parent mate <<<"$pair"
  slow_pane "$mate" 3
  out=$(FM_DIRECT_LINE_SEND_TIMEOUT=1 dl "$parent" "$mate" send music --client-id deck-0030 -- "Print the stems"); rc=$?
  assert_equals 4 "$rc" "a send past its bound reports the outcome as not known yet"
  assert_equals unknown "$(jq -r .state <<<"$out")" "the record says unknown, never failed"
  assert_contains "$(cat "$mate/fixture/submitted" 2>/dev/null)" "Print the stems" \
    "the words being typed when the bound hit are still submitted with their Enter"
  assert_equals "" "$(cat "$mate/fixture/draft" 2>/dev/null)" "nothing is left unsubmitted in the composer"
  out=$(dl "$parent" "$mate" delivery music deck-0030) || fail "delivery read failed: $out"
  assert_equals typed "$(jq -r .state <<<"$out")" "a poll adopts desk-voice's finished outcome"
  desk_send_done "$mate"
  pass "fm-direct-line send: a send stopped by its bound still finishes the words and their Enter"
}

test_poll_closes_the_call_a_timed_out_answer_left_open() {
  local pair parent mate fakebin identity out rc holder lock started
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  pair=$(typed_fixture slowhold) || { desk_send_skip direct-line-slow-hold; return 0; }
  IFS=$'\t' read -r parent mate <<<"$pair"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi
  PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" hold mix-call \
    --title "Pick the mix" --reason "captain picks mix A or B" >/dev/null 2>&1 \
    || fail "could not hold the call in the mate home"
  identity=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call --identity 2>/dev/null) \
    || fail "the call must be open before the answer"
  slow_pane "$mate" 3
  out=$(PATH="$fakebin:$PATH" FM_DIRECT_LINE_SEND_TIMEOUT=1 dl "$parent" "$mate" send music --client-id deck-0031 \
    --answers mix-call --hold-identity "$identity" -- "Mix B please"); rc=$?
  assert_equals 4 "$rc" "an answer whose send hit its bound is not known yet"
  assert_equals null "$(jq -r .hold.result <<<"$out")" "the timed-out send has not answered the call"
  sleep 60 & holder=$!
  lock="$(parent_dl_dir "$parent" music)/.send.lock"
  mkdir -p "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" delivery music deck-0031) || fail "delivery read failed: $out"
  [ "$(( $(date +%s) - started ))" -lt 20 ] || fail "a poll must not wait for a busy send lock"
  assert_equals null "$(jq -r .hold.result <<<"$out")" "a poll behind a busy send lock leaves the call for a later poll"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "$lock"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" delivery music deck-0031) || fail "delivery read failed: $out"
  assert_equals typed "$(jq -r .state <<<"$out")" "the poll adopts the typed outcome"
  assert_equals answered "$(jq -r .hold.result <<<"$out")" "the poll closes the call the delivered message answers"
  assert_equals deck-0031 "$(jq -r .hold.answered_via <<<"$out")" "the record names the message that closed it"
  if PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call >/dev/null 2>&1; then
    fail "the held call must be closed after the poll"
  fi
  desk_send_done "$mate"
  pass "fm-direct-line delivery: polling a timed-out answer closes the held call by script"
}

test_busy_lock_never_reads_as_not_delivered() {
  local mate parent out rc holder lock rec
  mate=$(new_home busy-mate)
  parent=$(make_parent busy-parent music "$mate")
  seed_mate "$mate" music "$parent"
  out=$(dl "$parent" "$mate" send music --client-id deck-0032 -- "first") || fail "send failed: $out"
  sleep 30 & holder=$!
  lock="$(parent_dl_dir "$parent" music)/.send.lock"
  mkdir -p "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  out=$(FM_DIRECT_LINE_LOCK_WAIT=1 dl "$parent" "$mate" send music --client-id deck-0032 -- "first"); rc=$?
  assert_equals 0 "$rc" "a retry of a delivered id behind a busy lock reports it delivered"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "it prints the id's record"
  rec="$(parent_dl_dir "$parent" music)/deliveries/deck-0032.json"
  jq -c '.state = "sending"' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  out=$(FM_DIRECT_LINE_LOCK_WAIT=1 dl "$parent" "$mate" send music --client-id deck-0032 -- "first"); rc=$?
  assert_equals 4 "$rc" "a retry of an id still sending behind a busy lock says poll, not not-delivered"
  assert_equals sending "$(jq -r .state <<<"$out")" "it prints the record still sending"
  jq -c '.state = "failed"' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  out=$(FM_DIRECT_LINE_LOCK_WAIT=1 dl "$parent" "$mate" send music --client-id deck-0032 -- "first"); rc=$?
  assert_equals 1 "$rc" "a retry of a failed id behind a busy lock reports it not delivered"
  jq -c '.state = "mailbox"' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  out=$(FM_DIRECT_LINE_LOCK_WAIT=1 dl "$parent" "$mate" send music --client-id deck-0033 -- "second"); rc=$?
  assert_equals 2 "$rc" "a new id behind a busy lock is refused"
  assert_equals busy "$(jq -r .state <<<"$out")" "the refusal is a busy document"
  assert_equals fm-direct-line-delivery.v1 "$(jq -r .schema <<<"$out")" "the busy document is versioned"
  out=$(FM_DIRECT_LINE_LOCK_WAIT=1 dl "$parent" "$mate" send music --client-id deck-0032 -- "other words" 2>&1); rc=$?
  assert_equals 2 "$rc" "a reused id with other words is refused even behind a busy lock"
  assert_contains "$out" "different message" "the refusal names the reused id"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "$lock"
  [ ! -e "$(parent_dl_dir "$parent" music)/deliveries/deck-0033.json" ] || fail "a busy send records nothing"
  assert_equals 1 "$(mailbox_count "$mate")" "nothing more was delivered behind the busy lock"
  out=$(dl "$parent" "$mate" send music --client-id deck-0033 -- "second") || fail "the same id sends once the lock is free: $out"
  assert_equals 2 "$(mailbox_count "$mate")" "the retried id is delivered once"
  pass "fm-direct-line send: a busy lock reports the record's own outcome, or busy for a new id"
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
  seed_mate "$mate" music "$parent" charter
  out=$(dl "$parent" "$mate" send music --client-id deck-0002 -- "hello" 2>&1) \
    && fail "a mate that opted itself in, with no parent record, must refuse: $out"
  assert_contains "$out" "has not enabled it" "the refusal names the missing parent record"
  out=$(FM_HOME="$parent" "$DL" list) || fail "list failed: $out"
  assert_equals false "$(jq -r '.mates[0].direct_line' <<<"$out")" "a self-declared opt-in is not listed as direct-line"
  out=$(FM_HOME="$mate" "$DL" waiting --for 600 2>&1) && fail "a mate that opted itself in must not declare a wait: $out"
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
  [ ! -e "$(parent_dl_dir "$parent" music)/deliveries" ] || fail "a refused send must record nothing"
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
  local mate parent fakebin out identity png rc
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
  identity=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call --identity 2>/dev/null) \
    || fail "the call must be open before the answer"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0016 --answers mix-call -- "Mix B please" 2>&1) \
    && fail "an answer without the identity the captain saw must refuse: $out"
  assert_contains "$out" "--hold-identity" "the refusal names the missing identity"
  png="$TMP_ROOT/answer.png"
  printf 'png' > "$png"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0017 --answers mix-call \
    --hold-identity "$identity" --image "$png" 2>&1) && fail "an image-only answer must refuse: $out"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0018 --answers -x \
    --hold-identity "$identity" -- "Mix B" 2>&1) && fail "a task id starting with a dash must refuse: $out"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0019 --answers mix-call \
    --hold-identity "1999-01-01T00:00:00Z#0" -- "Mix A") ; rc=$?
  assert_equals 3 "$rc" "an answer to a call that changed since the captain saw it is delivered but not recorded"
  assert_equals refused "$(jq -r .hold.result <<<"$out")" "the stale answer is refused by compare-and-answer"
  out=$(PATH="$fakebin:$PATH" dl "$parent" "$mate" send music --client-id deck-0006 --answers mix-call \
    --hold-identity "$identity" -- "Mix B please") || fail "send with --answers failed: $out"
  assert_equals answered "$(jq -r .hold.result <<<"$out")" "the chat answer closes the held call"
  assert_equals deck-0006 "$(jq -r .hold.answered_via <<<"$out")" "the record names the message that closed the call"
  assert_contains "$(cat "$mate/state/desk-voice/inbox/"*.json)" "[direct line message deck-0006 answers mix-call] Mix B please" \
    "the mate sees which message answers which call"
  if PATH="$fakebin:$PATH" FM_HOME="$mate" "$ROOT/bin/fm-captain-hold.sh" open mix-call >/dev/null 2>&1; then
    fail "the held call must be closed after the chat answer"
  fi
  assert_contains "$(cat "$mate/data/backlog.md")" "Mix B please" "the captain's own words are recorded"
  assert_contains "$(cat "$mate/data/backlog.md")" "direct line to music, message deck-0006" "the decision records where the answer came from"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$DL" answered mix-call --client-id deck-0003x 2>&1) \
    && fail "the mate citing a message that never reached it must refuse: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$DL" answered other-call --client-id deck-0006 2>&1) \
    && fail "the mate citing a message that names another call must refuse: $out"
  assert_contains "$out" "does not answer other-call" "the refusal names the mismatch"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$DL" answered mix-call --client-id deck-0006) \
    || fail "the mate citing the message that closed the call must succeed: $out"
  assert_equals answered "$(jq -r .hold.result <<<"$out")" "citing the closing message reports it answered"
  pass "fm-direct-line send --answers: a chat answer closes the held call by script, only as the captain saw it"
}

test_talking_holds_back_every_nudge() {
  local mate parent rec rc out holder
  mate=$(new_home talk-mate)
  parent=$(make_parent talk-parent music "$mate")
  seed_mate "$mate" music "$parent"
  live_primary "$mate" >/dev/null
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
  local mate parent out holder
  mate=$(new_home control-mate)
  parent=$(make_parent control-parent music "$mate")
  seed_mate "$mate" music "$parent"
  live_primary "$mate" >/dev/null
  FM_HOME="$mate" "$DL" waiting --for 600 >/dev/null || fail "waiting failed"
  printf 'kind=secondmate\nhome=%s\nworktree=%s\nwindow=fm-x:w1:p1\nbackend=herdr\nherdr_session=fm-x\nharness=claude\n' \
    "$mate" "$mate" > "$parent/state/music.meta"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music interrupt 2>&1) && fail "a talking mate must not be interrupted: $out"
  assert_contains "$out" "talking with its owner" "the refusal names the conversation"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music relaunch 2>&1) && fail "a talking mate must not be relaunched: $out"
  assert_contains "$out" "talking with its owner" "relaunch is refused too"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music exit 2>&1) && fail "a talking mate must not be stopped: $out"
  assert_contains "$out" "talking with its owner" "exit is refused too"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music interrupt --owner-approved 2>&1) \
    && fail "no flag lets the first mate past the conversation: $out"
  [ ! -e "$(parent_dl_dir "$parent" music)/audit.log" ] || fail "a refused action leaves no override audit"
  [ ! -e "$mate/state/desk-voice/.send.lock" ] || fail "the control plane must release the pane-writer lock"
  # Another writer holds the pane: the control plane waits briefly, then refuses.
  FM_HOME="$mate" "$DL" waiting --clear >/dev/null || fail "waiting --clear failed"
  holder=$(live_primary "$TMP_ROOT/control-holder")
  mkdir -p "$mate/state/desk-voice/.send.lock"
  printf '%s\n' "$holder" > "$mate/state/desk-voice/.send.lock/pid"
  out=$(FM_CONTROL_PANE_WAIT=1 FM_HOME="$parent" "$ROOT/bin/fm-control.sh" music interrupt 2>&1) \
    && fail "the control plane must not type while another writer holds the pane: $out"
  assert_contains "$out" "another writer is still typing" "the refusal names the busy pane"
  rm -rf "$mate/state/desk-voice/.send.lock"
  pass "fm-control: refuses a direct-line mate talking with the captain, with no override"
}

test_ids_and_sizes_are_checked_whole() {
  local mate parent out
  mate=$(new_home ids-mate)
  parent=$(make_parent ids-parent music "$mate")
  seed_mate "$mate" music "$parent"
  out=$(dl "$parent" "$mate" send music --client-id $'deck-0020\n../../../escape' -- "hello" 2>&1) \
    && fail "a client id with a newline must refuse: $out"
  out=$(dl "$parent" "$mate" delivery music $'deck-0020\n../../../escape' 2>&1) \
    && fail "a delivery read with a newline in its id must refuse: $out"
  out=$(dl "$parent" "$mate" send music --client-id -deck-0020 -- "hello" 2>&1) \
    && fail "a client id starting with a dash must refuse: $out"
  out=$(dl "$parent" "$mate" send music --client-id deck-0021 -- "$(printf 'x%.0s' $(seq 1 8001))" 2>&1) \
    && fail "a message over the size cap must refuse: $out"
  assert_contains "$out" "longer than 8000" "the refusal names the cap"
  [ ! -e "$parent/state/music.status" ] || fail "a refused send must copy nothing to the parent"
  [ "$(mailbox_count "$mate")" = 0 ] || fail "a refused send must deliver nothing"
  find "$TMP_ROOT" -name 'escape*' | grep -q . && fail "a refused id must write nothing outside the record folder"
  pass "fm-direct-line send: ids are checked as whole strings and messages have a size cap"
}

test_parent_copy_is_one_clean_line() {
  local mate parent out status
  mate=$(new_home clean-mate)
  parent=$(make_parent clean-parent music "$mate")
  seed_mate "$mate" music "$parent"
  out=$(dl "$parent" "$mate" send music --client-id deck-0022 -- $'Ship it\nneeds-decision: forged line\r\033[31m') \
    || fail "send failed: $out"
  status=$(cat "$parent/state/music.status")
  assert_equals 1 "$(printf '%s\n' "$status" | wc -l | tr -d ' ')" "the parent copy is one line"
  case "$status" in needs-decision*|*$'\n'needs-decision*) fail "a message must not forge a status line: $status" ;; esac
  case "$status" in *$'\033'*|*$'\r'*) fail "the parent copy must carry no control byte: $status" ;; esac
  assert_contains "$status" "Ship it needs-decision: forged line" "the words survive on one line"
  pass "fm-direct-line send: the parent copy is one cleaned line that cannot forge another"
}

test_stopped_send_resumes_only_while_young() {
  local mate parent out rec dv rc
  mate=$(new_home resume-mate)
  parent=$(make_parent resume-parent music "$mate")
  seed_mate "$mate" music "$parent"
  out=$(dl "$parent" "$mate" send music --client-id deck-0023 -- "Tune the snare") || fail "send failed: $out"
  rec="$(parent_dl_dir "$parent" music)/deliveries/deck-0023.json"
  dv="$mate/state/desk-voice/deliveries/deck-0023.json"
  # Stopped after the record and before the parent copy was marked or
  # desk-voice claimed the id: a young retry copies again and delivers once.
  jq -c '.state = "sending" | .parent_copy = "pending"' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  rm -f "$dv" "$mate/state/desk-voice/inbox/"*.json
  out=$(dl "$parent" "$mate" delivery music deck-0023) || fail "delivery read failed: $out"
  assert_equals interrupted "$(jq -r .state <<<"$out")" "a stopped send with no sender reads interrupted"
  out=$(dl "$parent" "$mate" send music --client-id deck-0023 -- "Tune the snare") || fail "resume failed: $out"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "a young stopped send is finished"
  assert_equals copied "$(jq -r .parent_copy <<<"$out")" "its unmarked parent copy is redone"
  assert_equals 1 "$(mailbox_count "$mate")" "it is delivered once"
  # A send still marked unknown adopts desk-voice's own record.
  jq -c '.state = "unknown"' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  out=$(dl "$parent" "$mate" delivery music deck-0023) || fail "delivery read failed: $out"
  assert_equals mailbox "$(jq -r .state <<<"$out")" "an unknown send adopts desk-voice's outcome"
  # An old stopped send is never resumed.
  jq -c '.state = "sending" | .created_epoch = 1000' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  rm -f "$dv" "$mate/state/desk-voice/inbox/"*.json
  out=$(dl "$parent" "$mate" send music --client-id deck-0023 -- "Tune the snare"); rc=$?
  assert_equals 1 "$rc" "an old stopped send is not delivered"
  assert_equals expired "$(jq -r .state <<<"$out")" "an old stopped send expires"
  assert_equals 0 "$(mailbox_count "$mate")" "an old stopped send types nothing"
  pass "fm-direct-line send: a stopped send resumes once while young, adopts desk-voice's record, and otherwise expires"
}

test_failed_delivery_puts_talking_back() {
  local mate parent out rc
  mate=$(new_home failed-mate)
  parent=$(make_parent failed-parent music "$mate")
  seed_mate "$mate" music "$parent"
  live_primary "$mate" >/dev/null
  mkdir -p "$mate/state/desk-voice"
  printf 'not a folder\n' > "$mate/state/desk-voice/inbox"
  out=$(dl "$parent" "$mate" send music --client-id deck-0024 -- "Render it"); rc=$?
  assert_equals 1 "$rc" "an undeliverable message reports not delivered"
  assert_equals failed "$(jq -r .state <<<"$out")" "the record says failed"
  out=$(FM_HOME="$parent" "$DL" talking music) && fail "a failed delivery must not leave the mate talking: $out"
  assert_contains "$(cat "$parent/state/music.status")" "deck-0024 to music was not delivered" "the parent learns the message did not land"
  pass "fm-direct-line send: a failed delivery puts the talking mark back"
}

test_talking_is_bounded() {
  local mate parent out pid rec rc fakebin
  mate=$(new_home bound-mate)
  parent=$(make_parent bound-parent music "$mate")
  seed_mate "$mate" music "$parent"
  pid=$(live_primary "$mate")
  out=$(FM_HOME="$mate" "$DL" waiting --for 999999 2>&1) && fail "a wait past the cap must refuse: $out"
  assert_contains "$out" "at most 14400" "the refusal names the cap"
  mkdir -p "$(parent_dl_dir "$parent" music)"
  printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$(parent_dl_dir "$parent" music)/last-owner-message"
  out=$(FM_HOME="$parent" "$DL" talking music) && fail "a stamp from the future must not read as talking: $out"
  mkdir -p "$mate/state/direct-line"
  printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$mate/state/direct-line/waiting-on-owner"
  out=$(FM_HOME="$parent" "$DL" talking music) && fail "a wait beyond the cap must not read as talking: $out"
  printf '08\n' > "$(parent_dl_dir "$parent" music)/last-owner-message"
  rm -f "$mate/state/direct-line/waiting-on-owner"
  out=$(FM_HOME="$parent" "$DL" talking music 2>&1) && fail "an old stamp must not read as talking: $out"
  assert_not_contains "$out" "value too great" "a stamp with a leading zero is read as decimal"
  FM_HOME="$mate" "$DL" waiting --for 600 >/dev/null || fail "waiting failed"
  FM_HOME="$parent" "$DL" talking music >/dev/null || fail "a declared wait with a live primary reads as talking"
  # A steer that has waited past the deferral bound rings and escalates as usual.
  printf 'kind=secondmate\nhome=%s\nwindow=fm-x:w1:p1\nbackend=herdr\n' "$mate" > "$parent/state/music.meta"
  mkdir -p "$parent/state/music.inbox"
  rec="$parent/state/music.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\n--\nhello\n' > "$rec"
  touch -t 202001010000 "$rec"
  fakebin="$TMP_ROOT/bound-bin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/herdr"
  chmod +x "$fakebin/herdr"
  rc=0
  # shellcheck disable=SC2034 # STATE is read by the sourced library.
  ( unset FM_BACKEND_HERDR_BIN; PATH="$fakebin:$PATH"; FM_HOME="$parent" STATE="$parent/state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_ring herdr fm-x:w1:p1 "$rec" fm-music ) >/dev/null 2>&1 || rc=$?
  [ "$rc" != 4 ] || fail "a steer past the deferral bound must not be deferred"
  # A dead primary is not talking, so recovery may relaunch it.
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  out=$(FM_HOME="$parent" "$DL" talking music) && fail "a mate whose primary is dead must not read as talking: $out"
  pass "fm-direct-line: talking is bounded by caps, ignores future stamps, and ends with the primary"
}

test_send_copies_to_the_parent_then_types_once
test_timed_out_send_still_submits_its_words
test_poll_closes_the_call_a_timed_out_answer_left_open
test_busy_lock_never_reads_as_not_delivered
test_send_refuses_without_every_assertion
test_mailbox_keeps_the_captains_order
test_typed_send_follows_an_undrained_mailbox
test_chat_answer_closes_the_held_call
test_talking_holds_back_every_nudge
test_list_and_conversation_reads_are_versioned
test_control_plane_refuses_a_talking_mate
test_ids_and_sizes_are_checked_whole
test_parent_copy_is_one_clean_line
test_stopped_send_resumes_only_while_young
test_failed_delivery_puts_talking_back
test_talking_is_bounded

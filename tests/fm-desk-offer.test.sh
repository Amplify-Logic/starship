#!/usr/bin/env bash
# Behavior tests for bin/fm-desk-offer.sh: the desk floater's Do it offer, its
# easy-to-undo backstop, its expiry when a newer reply arrives, and the taps
# that travel to Firstmate as one line naming the offer and never act.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-desk-offer)
unset FM_STATE_OVERRIDE CI GITHUB_ACTIONS NO_MISTAKES_GATE || true

# A copy of the script in its own code root with stand-ins: fm-desk-voice.sh
# logs what it was asked to send and prints the home's send.out (failing when
# it holds "fail"); fm-speak.sh --history lists one reply per number in the
# home's replies file.
new_root() {  # <name>
  local fx="$TMP_ROOT/$1"
  mkdir -p "$fx/root/bin" "$fx/home/state"
  cp "$ROOT/bin/fm-desk-offer.sh" "$fx/root/bin/fm-desk-offer.sh"
  cat > "$fx/root/bin/fm-desk-voice.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fx/sent.log"
out=\$(cat "$fx/send.out" 2>/dev/null || printf 'sent: herdr 1-1')
[ "\$out" != fail ] || exit 1
printf '%s\n' "\$out"
EOF
  cat > "$fx/root/bin/fm-speak.sh" <<EOF
#!/usr/bin/env bash
[ "\$*" = --history ] || exit 1
n=\$(cat "$fx/replies" 2>/dev/null || printf 0)
while [ "\$n" -gt 0 ]; do printf '%s\t0\treply %s\n' "\$n" "\$n"; n=\$((n - 1)); done
EOF
  chmod +x "$fx/root/bin/"*.sh
  printf '%s\n' "$fx"
}

offer() {  # <fx> <args...>
  local fx=$1
  shift
  FM_HOME="$fx/home" "$fx/root/bin/fm-desk-offer.sh" "$@"
}

state_of() { offer "$1" status | jq -r .state; }
id_of() { offer "$1" status | jq -r .id; }

test_an_offer_is_shown_and_a_do_it_tap_sends_one_line_naming_it() {
  local fx id out
  fx=$(new_root doit)
  printf '3\n' > "$fx/replies"
  assert_equals none "$(state_of "$fx")" "no offer yet"
  out=$(offer "$fx" offer "Turn on Do Not Disturb until 6pm") || fail "the offer was refused"
  id=$(id_of "$fx")
  assert_equals "offer: $id" "$out" "the offer prints its id"
  assert_equals open "$(state_of "$fx")" "a new offer waits for a tap"
  assert_equals "Turn on Do Not Disturb until 6pm" "$(offer "$fx" status | jq -r .text)" "the line is shown"
  assert_equals 600 "$(stat -f '%Lp' "$fx/home/state/desk-voice/offer.json" 2>/dev/null \
    || stat -c '%a' "$fx/home/state/desk-voice/offer.json")" "the record is the owner's alone"

  out=$(offer "$fx" answer "do" "$id") || fail "the Do it tap failed"
  assert_equals "sent: herdr 1-1" "$out" "the tap prints the send's outcome"
  assert_equals "send --source desk-floater-offer -- Do it: Turn on Do Not Disturb until 6pm (floater offer $id)" \
    "$(cat "$fx/sent.log")" "the tap is one line of the captain's own, naming the offer"
  assert_equals accepted "$(state_of "$fx")" "a tapped offer is accepted"
  offer "$fx" answer "do" "$id" >/dev/null 2>&1 && fail "a second Do it tap must not send again"
  assert_equals 1 "$(wc -l < "$fx/sent.log" | tr -d ' ')" "only one line was sent"

  offer "$fx" working "$id" >/dev/null || fail "working was refused"
  assert_equals working "$(state_of "$fx")" "the step is being carried out"
  offer "$fx" answer stop "$id" >/dev/null || fail "the Stop tap failed"
  assert_contains "$(tail -n 1 "$fx/sent.log")" "Stop: Turn on Do Not Disturb until 6pm (floater offer $id)" "Stop names the offer"
  assert_equals stopping "$(state_of "$fx")" "a stopped step is stopping"
  offer "$fx" "done" "$id" >/dev/null || fail "done failed"
  assert_equals none "$(state_of "$fx")" "a finished offer is gone"
  pass "an offer shows, a Do it tap sends one line naming it, and Stop and done follow"
}

test_steps_that_are_not_easy_to_undo_are_refused() {
  local fx code text
  fx=$(new_root refused)
  for text in "Send the reply to the landlord" "Book the 9am table" "Delete the old exports" \
    "Submit the form" "Buy the cheaper ticket" "Finish deleting the old exports" \
    "Paying the invoice in Safari" "Submitting the expense claim" "Finish purchasing the upgrade" \
    "Publishing the draft post" "Start emailing the summary to Sam" "Erasing the spare disk"; do
    offer "$fx" offer "$text" >/dev/null 2>&1 && code=0 || code=$?
    expect_code 2 "$code" "a step that is not easy to undo: $text"
  done
  assert_equals none "$(state_of "$fx")" "nothing was recorded"
  offer "$fx" offer "" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 2 "$code" "an empty offer"
  offer "$fx" offer "Export the chart as a PNG to Downloads" >/dev/null || fail "an export is easy to undo"
  offer "$fx" offer "Open the bookmarks window in Safari" >/dev/null || fail "opening a window is easy to undo"
  pass "a step that sends, buys, books, deletes or submits is refused"
}

test_a_late_tap_never_approves_a_newer_offer() {
  local fx old new code
  fx=$(new_root late)
  offer "$fx" offer "Open the Sound settings" >/dev/null
  old=$(id_of "$fx")
  offer "$fx" offer "Switch the output to the headphones" >/dev/null
  new=$(id_of "$fx")
  offer "$fx" answer "do" "$old" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 1 "$code" "a tap for the older offer"
  offer "$fx" working "$old" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 1 "$code" "working for the older offer"
  assert_absent "$fx/sent.log" "nothing was sent"
  assert_equals open "$(state_of "$fx")" "the newer offer still waits"
  assert_equals "$new" "$(id_of "$fx")" "and is still the current one"
  pass "a late tap for an older offer never approves a newer one"
}

test_an_open_offer_expires_when_a_newer_reply_arrives() {
  local fx id code
  fx=$(new_root expiry)
  printf '5\n' > "$fx/replies"
  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  printf '6\n' > "$fx/replies"
  assert_equals open "$(state_of "$fx")" "the reply that carries the offer keeps it open"
  printf '7\n' > "$fx/replies"
  assert_equals expired "$(state_of "$fx")" "a newer reply expires it"
  offer "$fx" answer "do" "$id" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 1 "$code" "a tap on an expired offer"
  assert_absent "$fx/sent.log" "nothing was sent"
  pass "an open offer expires once a newer reply arrives"
}

age_record() {  # <fx> <seconds>
  local f="$1/home/state/desk-voice/offer.json"
  jq --argjson by "$2" '.updated_at -= $by | .created_at -= $by' "$f" > "$f.new" && mv "$f.new" "$f"
}

test_a_tap_nobody_acts_on_expires_after_thirty_minutes() {
  local fx id code
  fx=$(new_root tapped-stale)
  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  offer "$fx" answer "do" "$id" >/dev/null || fail "the tap failed"
  age_record "$fx" 1700
  assert_equals accepted "$(state_of "$fx")" "a fresh tap still waits for Firstmate"
  age_record "$fx" 200
  assert_equals expired "$(state_of "$fx")" "a tap Firstmate never took up no longer holds the bubble"
  offer "$fx" working "$id" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 1 "$code" "working on a stale tap"

  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  offer "$fx" answer "do" "$id" >/dev/null || fail "the tap failed"
  offer "$fx" working "$id" >/dev/null || fail "working was refused"
  age_record "$fx" 1900
  assert_equals working "$(state_of "$fx")" "work Firstmate is doing keeps the bubble"
  pass "a tap nobody acts on expires after thirty minutes"
}

test_not_now_sends_nothing_and_a_failed_send_can_be_tapped_again() {
  local fx id
  fx=$(new_root notnow)
  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  assert_equals declined "$(offer "$fx" answer not-now "$id")" "Not now declines"
  assert_equals none "$(state_of "$fx")" "a declined offer is gone"
  assert_absent "$fx/sent.log" "declining sends nothing"

  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  printf 'fail\n' > "$fx/send.out"
  offer "$fx" answer "do" "$id" >/dev/null 2>&1 && fail "a failed send must fail the tap"
  assert_equals open "$(state_of "$fx")" "a tap that could not be sent leaves the offer open"
  rm -f "$fx/send.out"
  offer "$fx" answer "do" "$id" >/dev/null || fail "the second tap failed"
  assert_equals accepted "$(state_of "$fx")" "the second tap is accepted"
  pass "Not now sends nothing, and a tap that could not be sent can be tapped again"
}

test_taps_never_reach_the_chat_from_an_automated_run() {
  local fx id code
  fx=$(new_root automated)
  offer "$fx" offer "Open the Sound settings" >/dev/null
  id=$(id_of "$fx")
  CI=1 offer "$fx" answer "do" "$id" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 3 "$code" "a tap under CI"
  NO_MISTAKES_GATE=1 offer "$fx" answer "do" "$id" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 3 "$code" "a tap under a no-mistakes gate"
  assert_absent "$fx/sent.log" "nothing was sent"
  assert_equals open "$(state_of "$fx")" "the offer still waits"
  pass "taps never reach the chat from an automated run"
}

test_an_offer_is_shown_and_a_do_it_tap_sends_one_line_naming_it
test_steps_that_are_not_easy_to_undo_are_refused
test_a_late_tap_never_approves_a_newer_offer
test_an_open_offer_expires_when_a_newer_reply_arrives
test_a_tap_nobody_acts_on_expires_after_thirty_minutes
test_not_now_sends_nothing_and_a_failed_send_can_be_tapped_again
test_taps_never_reach_the_chat_from_an_automated_run

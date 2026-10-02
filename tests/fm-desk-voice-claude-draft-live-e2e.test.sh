#!/usr/bin/env bash
# Real Claude Code guard for the desk floater's send past a draft.
# bin/fm-desk-voice.sh sets the captain's unsent draft aside with Claude's
# Ctrl+S stash, reads `› stashed` in Claude's footer, and relies on Claude
# putting the draft back when the message is submitted. All three are Claude's
# own rendering and keys, so this drives a real Claude in a private tmux
# server: the floater message must be submitted alone and the draft must be
# back in the chat box, never submitted.
# It also rings the same primary through the payload-proof path, first
# refusing its restored draft and then submitting only the ring text.
# Run explicitly with FM_DESK_VOICE_CLAUDE_DRAFT_LIVE=1; it submits two short
# prompts to the installed claude.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DESK_VOICE_CLAUDE_DRAFT_LIVE claude tmux

DESK="$ROOT/bin/fm-desk-voice.sh"
SOCKET="fm-desk-draft-$$"
LAB=$(fm_test_tmproot fm-desk-draft-live)
VERSION=$(claude --version 2>/dev/null | head -n 1)
DRAFT='KESTREL draft the captain has not sent'

t() { tmux -L "$SOCKET" "$@"; }
cleanup() {
  t kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

screen() { t capture-pane -p -t fm:0.0 2>/dev/null; }

# The composer verdict and text through the same backend code the floater
# uses, pointed at the private server.
composer_state() {
  TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_composer_state tmux fm:0.0' _ "$ROOT"
}

mkdir -p "$LAB/project" "$LAB/home/state" "$LAB/home/config"
git -C "$LAB/project" init -q
t new-session -d -s fm -x 120 -y 40 -c "$LAB/project" "claude --model haiku" \
  || fail "could not start claude in a private tmux server"

# Enter is pressed only once the pointer is seen on the trust option: a Down
# sent while the dialog is still drawing is dropped, and Enter would then pick
# "No, exit" and end Claude.
ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in
    *'❯ Yes, I trust this folder'*) t send-keys -t fm:0.0 Enter ;;
    *'Yes, I trust this folder'*) t send-keys -t fm:0.0 Down ;;
  esac
  if [ "$(composer_state)" = empty ]; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "Claude $VERSION never showed an empty chat box: $(screen | tail -n 8)"

t send-keys -t fm:0.0 -l "$DRAFT"
sleep 1
[ "$(composer_state)" = pending ] || fail "Claude $VERSION's typed draft did not read pending"

t display-message -p -t fm:0.0 '#{pane_pid}' > "$LAB/home/state/.lock"
# A send that falls back to the mailbox raises a macOS notification; a
# stand-in osascript keeps it off the captain's screen for a lab message.
mkdir -p "$LAB/notify-bin"
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"
chmod +x "$LAB/notify-bin/osascript"
out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
  PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" \
  "$DESK" send --source live-test 'Reply with only the word OSPREY') \
  || fail "send failed: $out"
case "$out" in
  'sent: tmux '*) ;;
  *) fail "Claude $VERSION: expected the message to be sent past the draft, got: $out" ;;
esac

answered=0
for _ in $(seq 1 60); do
  if screen | grep -q '⏺ OSPREY'; then
    answered=1
    break
  fi
  sleep 1
done
[ "$answered" = 1 ] || fail "Claude $VERSION never answered the floater message: $(screen | tail -n 12)"
sleep 1
[ "$(composer_state)" = pending ] || fail "Claude $VERSION did not put the draft back in the chat box"
count=$(screen | grep -cF "$DRAFT" || true)
[ "$count" = 1 ] || fail "Claude $VERSION: the draft must appear once, in the chat box and never submitted; found $count"
screen | grep -qF 'Reply with only the word OSPREY' \
  || fail "Claude $VERSION: the floater message was not submitted"
! screen | grep -F 'Reply with only the word OSPREY' | grep -qF KESTREL \
  || fail "Claude $VERSION: the draft was submitted with the floater message"
pass "desk floater: real Claude $VERSION submits the message alone and puts the unsent draft back"

ring() {
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" \
    "$DESK" ring "$1"
}

out=$(ring 'Reply with only the word WREN') || fail "Claude $VERSION: ring failed: $out"
[ "$out" = not-rung ] || fail "Claude $VERSION: a restored draft must refuse a ring: $out"
screen | grep -qF "$DRAFT" || fail "Claude $VERSION: refusing a ring lost the draft"
# Clear only the test's own invented draft to exercise an empty primary.
t send-keys -t fm:0.0 C-u
sleep 1
[ "$(composer_state)" = empty ] || fail "Claude $VERSION: the test draft did not clear"
out=$(ring 'Reply with only the word WREN') || fail "Claude $VERSION: ring failed: $out"
case "$out" in
  'rung: tmux '*) ;;
  *) fail "Claude $VERSION: payload-proven ring did not submit: $out" ;;
esac
answered=0
for _ in $(seq 1 60); do
  if screen | grep -q '⏺ WREN'; then answered=1; break; fi
  sleep 1
done
[ "$answered" = 1 ] || fail "Claude $VERSION: the ring never reached the model"
pass "desk ring: real Claude $VERSION refuses an unsent draft and submits the proven ring alone"

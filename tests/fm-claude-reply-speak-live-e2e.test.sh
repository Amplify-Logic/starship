#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the primary reply-speak Stop
# hook (bin/fm-claude-reply-speak.sh).
# Proves, against the real installed Claude Code and the real tracked hook
# registration, that an interactive primary turn fires the `async` Stop hook
# with the reply as `last_assistant_message`, that the hook's own ancestry walk
# finds the session holding the home lock, and that the reply reaches the
# speaker while a routine "Captain, shipshape." reply does not.
# Claude runs interactively in a private tmux server because `claude -p` exits
# without running plain `async` hooks. It runs in this checkout, which must
# already be trusted, so no trust prompt or global config write occurs; a trust
# prompt fails the guard instead of being answered.
# The register owner and the speaker are fakes, so no audio is ever played and
# Deepgram is never called. Claude keeps its existing managed authentication.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_REPLY_SPEAK_LIVE_E2E claude tmux jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.claude-reply-speak-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
SOCKET="fm-reply-speak-live-$$"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

live_fail() {
  printf 'not ok - Claude %s reply-speak live E2E: %s\n' "$CLAUDE_VERSION" "$1" >&2
  printf '%s\n' "--- pane ---" >&2
  tmux -L "$SOCKET" capture-pane -p -t live 2>/dev/null | grep -v '^$' | tail -15 >&2 || true
  exit 1
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
# Keep only the tracked reply-speak registration, with its project anchor
# pointed at the lab clone, so the hook scopes itself to that plain checkout
# and no other tracked hook (session start, supervision guards) runs.
SETTINGS="$LAB/settings.json"
jq --arg project "$PROJECT" '
  {hooks: {Stop: [{hooks: [.hooks.Stop[].hooks[]
    | select(.command | contains("fm-claude-reply-speak.sh"))
    | .command |= gsub("\\$CLAUDE_PROJECT_DIR"; $project)]}]}}
' "$ROOT/.claude/settings.json" > "$SETTINGS"
[ "$(jq '.hooks.Stop[0].hooks | length' "$SETTINGS")" = 1 ] \
  || live_fail "tracked settings do not register exactly one reply-speak Stop hook"
[ "$(jq '.hooks.Stop[0].hooks[0].async' "$SETTINGS")" = true ] \
  || live_fail "the tracked reply-speak hook is not registered async"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'enabled = true\n' > "$HOME_DIR/config/speak"
cat > "$LAB/shaper" <<'EOF'
#!/usr/bin/env bash
shift
printf '%s\n' "$*"
EOF
cat > "$LAB/speaker" <<EOF
#!/usr/bin/env bash
prev=
for a in "\$@"; do
  [ "\$prev" != -f ] || printf '%s\n' "\$(cat "\$a")" >> "$LAB/audio.log"
  prev=\$a
done
EOF
chmod +x "$LAB/shaper" "$LAB/speaker"

# The session runs in this already-trusted checkout with project settings
# excluded, so only the lab registration above is loaded from it.
tmux -L "$SOCKET" new-session -d -s live -x 200 -y 50 -c "$ROOT" \
  "env -u DEEPGRAM_API_KEY FM_HOME='$HOME_DIR' FM_DEEPGRAM_ENV_FILE=/dev/null FM_SPEAK_SHAPER='$LAB/shaper' FM_SPEAK_SAY='$LAB/speaker' FM_REPLY_SPEAK_SETTLE_MS=500 claude --model haiku --setting-sources user --settings '$SETTINGS'" \
  || live_fail "could not start the interactive session"

# The pane runs claude directly, so the pane pid is the session the hook must
# find in its ancestry: record it as the home lock holder.
PANE_PID=$(tmux -L "$SOCKET" display-message -p -t live '#{pane_pid}')
printf '%s\n' "$PANE_PID" > "$HOME_DIR/state/.lock"

wait_ready() {
  local waited=0 pane
  while [ "$waited" -lt 60 ]; do
    pane=$(tmux -L "$SOCKET" capture-pane -p -t live 2>/dev/null || true)
    case "$pane" in
      *"trust this folder"*) live_fail "Claude asked to trust the lab folder; refusing to answer it" ;;
      *"❯"*) return 0 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  live_fail "the interactive session never became ready"
}

submit() {  # <prompt>
  tmux -L "$SOCKET" send-keys -t live -l "$1"
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t live Enter
}

wait_for_audio_lines() {  # <count>
  local waited=0
  while [ "$waited" -lt 90 ]; do
    [ -f "$LAB/audio.log" ] && [ "$(wc -l < "$LAB/audio.log" | tr -d ' ')" -ge "$1" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_ready
submit 'Reply with exactly this sentence and nothing else, using no tools: Captain, the live voice check passed.'
wait_for_audio_lines 1 || live_fail "the final reply never reached the speaker"
assert_contains "$(cat "$LAB/audio.log")" "the live voice check passed" \
  "the spoken line must be the final reply"

wait_ready
submit 'Reply with exactly this sentence and nothing else, using no tools: Captain, shipshape.'
sleep 15
[ "$(wc -l < "$LAB/audio.log" | tr -d ' ')" = 1 ] \
  || live_fail "the routine shipshape reply was spoken: $(cat "$LAB/audio.log")"

printf 'ok - Claude %s live E2E spoke the final reply through the async Stop hook and kept the routine shipshape reply silent\n' "$CLAUDE_VERSION"

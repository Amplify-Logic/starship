#!/usr/bin/env bash
# Default-on live guard: a Claude worker spawned on the real Herdr binary is
# proven started by the spawn's agent-up gate, with no "pane could not be read"
# warning.
#
# The defect: Herdr 0.9.5 registers a starting Claude with its own placeholder
# agent_status `unknown` for several seconds before any lifecycle state, where
# Herdr 0.7.4 went straight from agent_not_found to idle. The adapter read that
# placeholder as unreadable, so two one-second polls in a row ended the gate
# with "The herdr pane could not be read for the claude harness; delivery
# proceeded UNVERIFIED", and the first mate reported it could not read the new
# worker's screen to confirm it had started (seen on a fresh Windows 11 WSL 2
# Starship). docs/verification/runtime-backends.md "Placeholder status at agent
# start" records the measurement.
#
# This drives the REAL bin/fm-spawn.sh with --harness claude into a real Herdr
# lab session. The claude every lab pane finds is a stand-in whose process name
# is `claude`, so Herdr registers it exactly as it registers Claude Code, and no
# model token is spent and no account is used; the lab's pane shell guarantees
# no pane can start an installed Claude Code (see the pane shell below). Its
# Claude config dir is a scratch directory, so the spawn's trust registration
# never touches the operator's own.
# On a Herdr release without the placeholder the guard still runs and passes,
# and says so.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_SPAWN_HERDR_AGENT_UP_LIVE_E2E herdr jq treehouse

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-agent-up.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-agent-up) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

WORKTREE=
CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  [ -z "$WORKTREE" ] || treehouse return --force "$WORKTREE" >/dev/null 2>&1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT

# A stand-in Claude: the long-running process is a symlink named `claude` to
# fm_agent_standin's stand-in, so the kernel records `claude` as its process
# name and Herdr's agent detection and Firstmate's process classifier both read
# it as Claude Code. `exec -a` alone is not enough: it renames argv[0] only, and
# Linux keeps the process name `sleep`, so Herdr never registers it there.
STANDIN_BIN=$(fm_agent_standin "$TMP_ROOT/standin") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}
AGENT_BIN="$TMP_ROOT/agentbin"
mkdir -p "$AGENT_BIN"
ln -s "$STANDIN_BIN" "$AGENT_BIN/claude"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "2.1.302 (Claude Code)"; exit 0 ;;
esac
exec '$AGENT_BIN/claude' 600
SH
chmod +x "$FAKEBIN/claude"

CLAUDE_DIR="$TMP_ROOT/claude-config"
mkdir -p "$CLAUDE_DIR"
printf '{}\n' > "$CLAUDE_DIR/.claude.json"

# Every pane the spawn opens starts the lab server's $SHELL as a login shell,
# and a login shell rebuilds PATH from the operator's own rc files, so the
# stand-in on fm-spawn's PATH never reaches the pane: on a host with Claude
# Code installed the pane would start the operator's real claude with the
# operator's own config, and on one without it the launch finds no claude at
# all. The lab is therefore provisioned with a pane shell that puts the
# stand-in first and points Claude at a scratch config, and reads no rc file.
PANE_SHELL_DIR="$TMP_ROOT/paneshell"
mkdir -p "$PANE_SHELL_DIR"
BASH_BIN=$(command -v bash)
cat > "$PANE_SHELL_DIR/bash" <<SH
#!$BASH_BIN
export PATH='$FAKEBIN':"\$PATH"
export CLAUDE_CONFIG_DIR='$CLAUDE_DIR'
exec '$BASH_BIN' --noprofile --norc -i
SH
chmod +x "$PANE_SHELL_DIR/bash"

SHELL="$PANE_SHELL_DIR/bash" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Prove the pane shell took before anything is launched: a lab pane must
# resolve `claude` to the stand-in, never to an installed Claude Code.
PROBE_WS=$(lab workspace create --cwd "$TMP_ROOT" --label fm-path-probe --no-focus) \
  || fail "could not create the pane-shell probe workspace"
PROBE_PANE=$(printf '%s' "$PROBE_WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PROBE_PANE" ] || fail "the pane-shell probe workspace returned no pane"
lab pane run "$PROBE_PANE" "command -v claude > '$TMP_ROOT/pane-claude'" >/dev/null \
  || fail "could not run the pane-shell probe"
for _ in $(seq 1 50); do
  [ -s "$TMP_ROOT/pane-claude" ] && break
  sleep 0.1
done
PANE_CLAUDE=$(cat "$TMP_ROOT/pane-claude" 2>/dev/null)
[ "$PANE_CLAUDE" = "$FAKEBIN/claude" ] \
  || fail "a lab pane resolves claude to '${PANE_CLAUDE:-nothing}', not the stand-in $FAKEBIN/claude"
pass "a lab pane resolves claude to the stand-in, never an installed Claude Code"

# --- scratch world ----------------------------------------------------------

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/agentup"
cat > "$HOME_DIR/data/agentup/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the agent-up gate on Herdr.

## Firstmate spec
Nothing to build.
EOF

# --- observe the registration while the spawn runs ----------------------------

STATUS_LOG="$TMP_ROOT/agent-status.log"
: > "$STATUS_LOG"
(
  meta="$HOME_DIR/state/agentup.meta"
  for _ in $(seq 1 300); do
    pane=$(grep '^herdr_pane_id=' "$meta" 2>/dev/null | cut -d= -f2-)
    if [ -n "$pane" ]; then
      lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty' >> "$STATUS_LOG"
    fi
    sleep 0.2
  done
) &
WATCH_PID=$!

SPAWN_ERR="$TMP_ROOT/spawn.err"
env PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" agentup "$PROJ" --mode no-mistakes --yolo off \
  --harness claude --backend herdr >"$TMP_ROOT/spawn.out" 2>"$SPAWN_ERR"
SPAWN_RC=$?
kill "$WATCH_PID" 2>/dev/null
wait "$WATCH_PID" 2>/dev/null

WORKTREE=$(grep '^worktree=' "$HOME_DIR/state/agentup.meta" 2>/dev/null | cut -d= -f2-)
[ "$SPAWN_RC" -eq 0 ] || fail "the claude spawn on herdr $HERDR_VERSION failed"$'\n'"$(cat "$SPAWN_ERR")"
if grep -q 'could not be read' "$SPAWN_ERR"; then
  fail "the agent-up gate could not read the starting claude worker on herdr $HERDR_VERSION (registrations seen: $(sort -u "$STATUS_LOG" | tr '\n' ' '))"$'\n'"$(cat "$SPAWN_ERR")"
fi
if grep -qx unknown "$STATUS_LOG"; then
  note "herdr $HERDR_VERSION held the placeholder 'unknown' status while claude started: the placeholder branch is exercised"
else
  note "herdr $HERDR_VERSION showed no placeholder status while claude started; the gate still proved the worker"
fi
pass "real herdr $HERDR_VERSION: a spawned claude worker is proven started, with no unreadable-pane warning"

PANE=$(grep '^herdr_pane_id=' "$HOME_DIR/state/agentup.meta" | cut -d= -f2-)
[ -n "$PANE" ] || fail "the spawn recorded no herdr pane"
STATE=$(
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$PANE"
)
[ "$STATE" = alive ] || fail "the running stand-in claude reads '$STATE' rather than alive on herdr $HERDR_VERSION"
pass "real herdr $HERDR_VERSION: the spawned worker's endpoint reads alive afterwards"

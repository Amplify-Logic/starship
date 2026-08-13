#!/usr/bin/env bash
# fm-harness-exam.sh - live worker-runtime re-verification against a real TUI.
#
# Usage:
#   bin/fm-harness-exam.sh <adapter> [options]
#   bin/fm-harness-exam.sh --list
#   bin/fm-harness-exam.sh --plan <adapter>
#
# The exam launches exactly one of the seven verified worker adapters in a
# throwaway git repository under a private HOME and a private tmux socket.
# It scores the eight runtime properties firstmate drives directly: autonomy,
# composer classification, busy signature, interrupt, turn-end hook, liveness
# marker, exit, and resume.
# Startup and trust dialogs are captured as unscored evidence because the
# source evaluation counted trust in its original core eight while the approved
# implementation scope replaced it with the liveness marker.
#
# Every probe is observed outside the runtime pane.
# Raw plain and ANSI pane captures, process listings, hook payloads, launch
# commands, results.json, and scorecard.md are retained in the output directory.
# Missing evidence fails its probe rather than being accepted as self-report.
#
# Options:
#   --model <id>        Override the adapter's default model.
#   --output <dir>      Artifact directory.
#                       Default: $FM_HOME/data/harness-exam/<adapter>-<UTC stamp>.
#   --timeout <secs>    Per-wait timeout, default 45.
#   --keep-lab          Keep the throwaway HOME and repository after the run.
#   --source-home <dir> Read credential bridges from this home, default $HOME.
#   --share-login-keychain
#                       Link the source home's macOS login keychain into the lab
#                       home. Required for adapters whose only credential lives
#                       there (cursor, and claude on macOS). Off by default.
#   --help              Print this help.
#
# Exit codes:
#   0 all eight probes passed, 1 a probe failed, 2 usage or setup error,
#   3 the lab home is not authenticated so nothing was scored.
#
# Safety:
# The autonomy probes deliberately use each adapter's unattended flag, but the
# runtime is confined to a fresh repository and private HOME.
# Only the selected adapter's authentication and configuration files are copied
# from --source-home into the isolated home.
# Those copies are read-only, so the runtime cannot write back to the source
# credential files.
# --share-login-keychain is the one exception and is therefore opt-in: it links
# the real login keychain, which the lab runtime can then read and rewrite.
# The script never updates a runtime, writes configuration, session, or artifact
# state into the source home, or uses the ambient tmux server.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTATIONS="$SCRIPT_DIR/fm-harness-exam-adapters.tsv"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

PROBES=(autonomy composer busy interrupt turn-end liveness exit resume)
TIMEOUT=45
BUSY_SECONDS=${FM_HARNESS_EXAM_BUSY_SECONDS:-20}
BUSY_SECONDS_MIN=10
STARTUP_DIALOG_LIMIT=4
KEEP_LAB=0
SHARE_LOGIN_KEYCHAIN=0
MODEL=""
OUTPUT=""
SOURCE_HOME=${HOME:-}
ADAPTER=""
MODE=run
RESULTS_TSV=""
ARTIFACTS=""
LAB_ROOT=""
LAB_HOME=""
WORKSPACE=""
TARGET=""
SESSION=exam
VERSION="unknown"
LAUNCH_CMD=""
RESUME_CMD=""
HOOK_MARKER=""
HOOK_RAW=""
RUN_FAILED=0
CLEANED=0
TMUX_SOCKET=""
TMUX_DIR=""

usage() {
  awk 'NR == 1 { next } /^#$/ { if (seen) print ""; next } /^# / { seen=1; sub(/^# /, ""); print; next } seen { exit }' "$0"
}

list_adapters() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$EXPECTATIONS"
}

load_expectation() {
  local adapter=$1 row
  row=$(awk -F '\t' -v a="$adapter" '!/^#/ && $1 == a { print; exit }' "$EXPECTATIONS")
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r ADAPTER BINARY AUTONOMY_FLAG BUSY_REGEX INTERRUPT_KEYS \
    INTERRUPT_REGEX EXIT_COMMAND RESUME_MODE ALIVE_VERDICT COMM_REGEX ARGV_REGEX \
    HOOK_KIND DEFAULT_MODEL STARTUP_DIALOG <<< "$row"
  return 0
}

print_plan() {
  local adapter=$1
  load_expectation "$adapter" || {
    echo "error: unsupported adapter '$adapter' (expected one of: $(list_adapters | paste -sd, -))" >&2
    return 2
  }
  printf 'adapter\t%s\n' "$ADAPTER"
  printf 'binary\t%s\n' "$BINARY"
  printf 'autonomy\t%s\n' "$AUTONOMY_FLAG"
  printf 'busy\t%s\n' "$BUSY_REGEX"
  printf 'interrupt\t%s\n' "$INTERRUPT_KEYS"
  printf 'interrupt_regex\t%s\n' "$INTERRUPT_REGEX"
  printf 'exit\t%s\n' "$EXIT_COMMAND"
  printf 'resume\t%s\n' "$RESUME_MODE"
  printf 'liveness\t%s\n' "$ALIVE_VERDICT"
  printf 'comm_regex\t%s\n' "$COMM_REGEX"
  printf 'argv_regex\t%s\n' "$ARGV_REGEX"
  printf 'hook\t%s\n' "$HOOK_KIND"
  printf 'model\t%s\n' "$DEFAULT_MODEL"
  printf 'dialog\t%s\n' "$STARTUP_DIALOG"
  printf 'probes\t%s\n' "$(IFS=,; echo "${PROBES[*]}")"
}

shell_quote() {
  local value=$1
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

append_arg() {
  local value=$1
  if [ -n "$LAUNCH_CMD" ]; then LAUNCH_CMD+=" "; fi
  LAUNCH_CMD+=$(shell_quote "$value")
}

copy_readonly_if_present() {
  local source=$1 destination=$2
  [ -e "$source" ] || return 0
  mkdir -p "$(dirname "$destination")"
  cp -RL "$source" "$destination"
  chmod -R a-w "$destination"
}

# bridge_login_keychain: make the source home's macOS login keychain reachable
# from the lab home, for adapters whose only credential lives there.
#
# The login keychain is HOME-RELATIVE, not session-scoped: `security
# default-keychain` under a fresh HOME reports "A default keychain could not be
# found" and `list-keychains` falls back to /Library/Keychains/System.keychain
# alone (verified 2026-08-13, macOS 25.5.0). So a keychain-authenticated runtime
# boots LOGGED OUT inside the lab, and no file copy can bridge it.
#
# This is deliberately opt-in and off by default, because it is the one bridge
# that is not a read-only copy: the lab runtime reaches the captain's REAL login
# keychain through this link and can refresh or rewrite the items it owns there.
# Every other bridge keeps the "never writes back to the source home" guarantee.
bridge_login_keychain() {
  local source="$SOURCE_HOME/Library/Keychains"
  [ "$SHARE_LOGIN_KEYCHAIN" = 1 ] || return 0
  [ -d "$source" ] || return 0
  mkdir -p "$LAB_HOME/Library"
  ln -s "$source" "$LAB_HOME/Library/Keychains"
}

prepare_credential_bridges() {
  bridge_login_keychain
  case "$ADAPTER" in
    claude)
      # The home-root ~/.claude.json holds account and onboarding state;
      # without it the lab boots as a first-run install and parks on
      # onboarding instead of reaching the probes.
      copy_readonly_if_present "$SOURCE_HOME/.claude.json" "$LAB_HOME/.claude.json"
      # File-based OAuth tokens exist only on Linux installs. On macOS the token
      # lives in the login keychain, which the lab home cannot reach without
      # --share-login-keychain (see bridge_login_keychain).
      copy_readonly_if_present "$SOURCE_HOME/.claude/.credentials.json" "$LAB_HOME/.claude/.credentials.json"
      ;;
    codex)
      copy_readonly_if_present "$SOURCE_HOME/.codex/auth.json" "$LAB_HOME/.codex/auth.json"
      copy_readonly_if_present "$SOURCE_HOME/.codex/config.toml" "$LAB_HOME/.codex/config.toml"
      ;;
    opencode) copy_readonly_if_present "$SOURCE_HOME/.local/share/opencode/auth.json" "$LAB_HOME/.local/share/opencode/auth.json" ;;
    pi) copy_readonly_if_present "$SOURCE_HOME/.pi/agent/auth.json" "$LAB_HOME/.pi/agent/auth.json" ;;
    grok)
      copy_readonly_if_present "$SOURCE_HOME/.grok/config.toml" "$LAB_HOME/.grok/config.toml"
      copy_readonly_if_present "$SOURCE_HOME/.grok/auth.json" "$LAB_HOME/.grok/auth.json"
      copy_readonly_if_present "$SOURCE_HOME/.grok/credentials" "$LAB_HOME/.grok/credentials"
      ;;
    cursor)
      # ~/.cursor/auth.json does not exist on current builds: cli-config.json
      # carries only identity (authInfo has authId/displayName/email/userId and
      # no token), and the credential itself is the login-keychain item
      # cursor-access-token. Cursor therefore needs --share-login-keychain.
      copy_readonly_if_present "$SOURCE_HOME/.cursor/cli-config.json" "$LAB_HOME/.cursor/cli-config.json"
      copy_readonly_if_present "$SOURCE_HOME/.cursor/auth.json" "$LAB_HOME/.cursor/auth.json"
      ;;
    kimi) ;;
    *) return 1 ;;
  esac
}

# lab_login_state: does the ADAPTER consider the LAB HOME authenticated?
# Prints logged-in, logged-out, or unknown. Only adapters with a cheap
# non-interactive auth probe are classified; every other adapter stays
# `unknown` and its run proceeds exactly as before.
lab_login_state() {
  local out
  case "$ADAPTER" in
    cursor)
      out=$(HOME="$LAB_HOME" "$BINARY" status 2>&1 | head -5 || true)
      case "$out" in
        *'Not logged in'*|*'not logged in'*) printf 'logged-out' ;;
        *'Logged in'*|*'logged in'*) printf 'logged-in' ;;
        *) printf 'unknown' ;;
      esac
      ;;
    *) printf 'unknown' ;;
  esac
}

# lab_auth_gate: refuse to score an unauthenticated lab.
#
# An unauthenticated runtime parks on its login screen, so every probe times
# out and the scorecard reads as eight runtime failures. That is a FALSE
# NEGATIVE certification - the dangerous direction for a tool whose whole job
# is deciding whether a build still behaves - so a setup gap stops the run
# with its own exit code instead of being scored.
lab_auth_gate() {
  local state
  state=$(lab_login_state)
  printf '%s\n' "$state" > "$ARTIFACTS/00-lab-auth-state.txt"
  [ "$state" = logged-out ] || return 0
  {
    printf 'adapter=%s\n' "$ADAPTER"
    printf 'lab_home=%s\n' "$LAB_HOME"
    printf 'share_login_keychain=%s\n' "$SHARE_LOGIN_KEYCHAIN"
    printf 'state=logged-out\n'
  } > "$ARTIFACTS/00-auth-blocked.txt"
  echo "error: the exam lab home is not authenticated for '$ADAPTER', so no probe result would mean anything" >&2
  if [ "$SHARE_LOGIN_KEYCHAIN" != 1 ]; then
    echo "hint: this adapter authenticates through the macOS login keychain, which is HOME-relative and therefore absent from the lab home; re-run with --share-login-keychain to let the lab reach the real login keychain" >&2
  else
    echo "hint: --share-login-keychain was set but the lab is still logged out; check that the source home is logged in ($BINARY status)" >&2
  fi
  return 1
}

write_hook_recorder() {
  local recorder="$LAB_ROOT/hook-recorder.sh"
  cat > "$recorder" <<EOF
#!/usr/bin/env bash
set -uo pipefail
{
  printf 'time=%s\\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'args='
  printf '%q ' "\$@"
  printf '\\nstdin=\\n'
  [ -t 0 ] || cat 2>/dev/null || true
  printf '\\n---\\n'
} >> $(shell_quote "$HOOK_RAW")
touch $(shell_quote "$HOOK_MARKER")
EOF
  chmod +x "$recorder"
}

prepare_hook() {
  local recorder="$LAB_ROOT/hook-recorder.sh" command_json hook_raw_json hook_marker_json
  write_hook_recorder
  hook_raw_json=$(jq -Rn --arg value "$HOOK_RAW" '$value')
  hook_marker_json=$(jq -Rn --arg value "$HOOK_MARKER" '$value')
  case "$HOOK_KIND" in
    claude)
      mkdir -p "$WORKSPACE/.claude"
      command_json=$(jq -Rn --arg command "$recorder" '$command')
      cat > "$WORKSPACE/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":$command_json}]}]}}
EOF
      ;;
    codex)
      : # The recorder is supplied through the launch command's notify setting.
      ;;
    opencode)
      mkdir -p "$WORKSPACE/.opencode/plugins"
      cat > "$WORKSPACE/.opencode/plugins/fm-harness-exam.js" <<EOF
import { appendFileSync, closeSync, openSync } from "node:fs";
export const FmHarnessExam = async () => ({
  event: async ({ event }) => {
    if (event.type !== "session.idle") return;
    appendFileSync($hook_raw_json, JSON.stringify(event) + "\\n");
    closeSync(openSync($hook_marker_json, "w"));
  },
});
EOF
      ;;
    pi)
      cat > "$LAB_ROOT/pi-turn-end.ts" <<EOF
import { appendFileSync, closeSync, openSync } from "node:fs";
export default function (pi: any) {
  pi.on("turn_end", (event: any) => {
    appendFileSync($hook_raw_json, JSON.stringify(event) + "\\n");
    closeSync(openSync($hook_marker_json, "w"));
  });
}
EOF
      ;;
    grok)
      mkdir -p "$LAB_HOME/.grok/hooks"
      command_json=$(jq -Rn --arg command "bash $(shell_quote "$recorder")" '$command')
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":%s}]}]}}\n' \
        "$command_json" > "$LAB_HOME/.grok/hooks/fm-harness-exam.json"
      ;;
    cursor)
      mkdir -p "$WORKSPACE/.cursor"
      command_json=$(jq -Rn --arg command "$recorder" '$command')
      printf '{"version":1,"hooks":{"stop":[{"type":"command","command":%s}]}}\n' \
        "$command_json" > "$WORKSPACE/.cursor/hooks.json"
      ;;
    kimi)
      prepare_kimi_home "$recorder"
      ;;
    *) return 1 ;;
  esac
}

prepare_kimi_home() {
  local recorder=$1 source="${FM_KIMI_SOURCE_HOME:-$SOURCE_HOME/.kimi-code}"
  mkdir -p "$LAB_HOME/.kimi-code"
  if [ -f "$source/config.toml" ]; then
    awk '
      BEGIN { skip=0 }
      /^\[\[hooks\]\]/ { skip=1; next }
      skip == 1 && /^\[/ { skip=0 }
      skip == 0 { print }
    ' "$source/config.toml" > "$LAB_HOME/.kimi-code/config.toml"
  else
    : > "$LAB_HOME/.kimi-code/config.toml"
  fi
  copy_readonly_if_present "$source/credentials" "$LAB_HOME/.kimi-code/credentials"
  copy_readonly_if_present "$source/oauth" "$LAB_HOME/.kimi-code/oauth"
  copy_readonly_if_present "$source/device_id" "$LAB_HOME/.kimi-code/device_id"
  {
    printf '\n[[hooks]]\n'
    printf 'event = "Stop"\n'
    printf 'command = "bash %s"\n' "$(shell_quote "$recorder")"
    printf 'timeout = 10\n'
  } >> "$LAB_HOME/.kimi-code/config.toml"
  chmod a-w "$LAB_HOME/.kimi-code/config.toml"
}

build_launch_command() {
  local resume=${1:-0} resume_id=${2:-} model=${MODEL:-$DEFAULT_MODEL}
  LAUNCH_CMD=""
  RESUME_CMD=""
  case "$ADAPTER" in
    claude)
      append_arg env
      append_arg CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
      append_arg claude
      append_arg --dangerously-skip-permissions
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg "$RESUME_MODE"
      ;;
    codex)
      append_arg env
      append_arg "CODEX_HOME=$LAB_HOME/.codex"
      append_arg codex
      if [ "$resume" = 0 ]; then
        append_arg --dangerously-bypass-approvals-and-sandbox
        append_arg -c
        append_arg "notify=[\"bash\",\"$LAB_ROOT/hook-recorder.sh\"]"
      else
        append_arg resume
        [ "$RESUME_MODE" = session-id ] && [ -n "$resume_id" ] || return 1
        append_arg "$resume_id"
        append_arg --dangerously-bypass-approvals-and-sandbox
        append_arg -c
        append_arg "notify=[\"bash\",\"$LAB_ROOT/hook-recorder.sh\"]"
      fi
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      ;;
    opencode)
      append_arg env
      append_arg 'OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}'
      append_arg opencode
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg "$RESUME_MODE"
      ;;
    pi)
      append_arg pi
      append_arg --session-dir
      append_arg "$LAB_ROOT/pi-sessions"
      append_arg -e
      append_arg "$LAB_ROOT/pi-turn-end.ts"
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg "$RESUME_MODE"
      ;;
    grok)
      append_arg env
      append_arg "GROK_HOME=$LAB_HOME/.grok"
      append_arg grok
      append_arg --always-approve
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg "$RESUME_MODE"
      ;;
    cursor)
      append_arg agent
      append_arg --yolo
      append_arg --workspace
      append_arg "$WORKSPACE"
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      if [ "$resume" != 0 ]; then
        [ -n "$resume_id" ] || return 1
        append_arg "--resume=$resume_id"
      fi
      ;;
    kimi)
      append_arg env
      append_arg "KIMI_CODE_HOME=$LAB_HOME/.kimi-code"
      append_arg kimi
      append_arg --yolo
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg "$RESUME_MODE"
      ;;
    *) return 1 ;;
  esac
  RESUME_CMD=$LAUNCH_CMD
}

capture_pane() {
  local stem=$1 lines=${2:-200}
  fm_backend_capture tmux "$TARGET" "$lines" > "$ARTIFACTS/$stem.txt" 2>&1 || true
  tmux capture-pane -ep -t "$TARGET" -S "-$lines" > "$ARTIFACTS/$stem.ansi" 2>&1 || true
}

capture_processes() {
  local stem=$1 tty
  tty=$(tmux display-message -p -t "$TARGET" '#{pane_tty}' 2>/dev/null || true)
  {
    tmux display-message -p -t "$TARGET" \
      'pane_pid=#{pane_pid} pane_current_command=#{pane_current_command} pane_tty=#{pane_tty}' 2>/dev/null || true
    if [ -n "$tty" ]; then
      ps -t "${tty#/dev/}" -o pid=,ppid=,pgid=,comm=,args= 2>/dev/null || true
    fi
  } > "$ARTIFACTS/$stem.processes.txt"
}

record_result() {
  local probe=$1 status=$2 summary=$3 evidence=$4
  [ -n "$RESULTS_TSV" ] || return 1
  if awk -F '\t' -v p="$probe" '$1 == p { found=1 } END { exit !found }' "$RESULTS_TSV" 2>/dev/null; then
    return 1
  fi
  summary=${summary//$'\t'/ }
  summary=${summary//$'\n'/ }
  evidence=${evidence//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$probe" "$status" "$summary" "$evidence" >> "$RESULTS_TSV"
  [ "$status" = pass ] || RUN_FAILED=1
}

record_missing_results() {
  local probe evidence=""
  if [ -f "$ARTIFACTS/00-startup-failed.ansi" ]; then
    evidence="evidence/00-startup-failed.ansi,evidence/00-startup-failed.processes.txt"
  fi
  for probe in "${PROBES[@]}"; do
    if ! awk -F '\t' -v p="$probe" '$1 == p { found=1 } END { exit !found }' "$RESULTS_TSV"; then
      record_result "$probe" fail "probe could not run after an earlier failure" "$evidence"
    fi
  done
}

render_results() {
  local jsonl="$OUTPUT/.results.jsonl" probe status summary evidence passed total
  : > "$jsonl"
  while IFS=$'\t' read -r probe status summary evidence; do
    jq -cn --arg probe "$probe" --arg status "$status" --arg summary "$summary" --arg evidence "$evidence" \
      '{probe:$probe,status:$status,pass:($status == "pass"),summary:$summary,evidence:$evidence}' >> "$jsonl"
  done < "$RESULTS_TSV"
  passed=$(awk -F '\t' '$2 == "pass" { n++ } END { print n+0 }' "$RESULTS_TSV")
  total=${#PROBES[@]}
  jq -n \
    --arg adapter "$ADAPTER" \
    --arg version "$VERSION" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workspace "$WORKSPACE" \
    --argjson passed "$passed" \
    --argjson total "$total" \
    --slurpfile probes "$jsonl" \
    '{schema_version:1,adapter:$adapter,version:$version,generated_at:$generated_at,workspace:$workspace,score:{passed:$passed,total:$total},probes:$probes}' \
    > "$OUTPUT/results.json"
  {
    printf "# Worker runtime exam: \`%s\`\n\n" "$ADAPTER"
    printf -- "- Version: \`%s\`\n" "$VERSION"
    printf -- '- Score: **%s/%s**\n' "$passed" "$total"
    printf -- "- Generated: \`%s\`\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '| Probe | Result | Evidence | Summary |\n'
    printf '|---|---|---|---|\n'
    while IFS=$'\t' read -r probe status summary evidence; do
      summary=${summary//|/\\|}
      printf "| \`%s\` | **%s** | \`%s\` | %s |\n" "$probe" "$status" "$evidence" "$summary"
    done < "$RESULTS_TSV"
    printf "\nStartup and trust handling is captured in \`evidence/00-startup-dialogs.txt\` but is not part of the eight-point score.\n"
  } > "$OUTPUT/scorecard.md"
  rm -f "$jsonl"
}

prepare_tmux_socket() {
  TMUX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-exam-tmux.XXXXXX") || return 1
  export TMUX_TMPDIR="$TMUX_DIR"
  unset TMUX
  TMUX_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
}

cleanup_lab() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ -n "$TMUX_SOCKET" ]; then tmux -S "$TMUX_SOCKET" kill-session -t "$SESSION" >/dev/null 2>&1 || true; fi
  if [ -n "$LAB_ROOT" ] && [ "$KEEP_LAB" = 0 ]; then
    chmod -R u+w "$LAB_ROOT" 2>/dev/null || true
    rm -rf "$LAB_ROOT"
  fi
  if [ -n "$TMUX_DIR" ]; then rm -rf "$TMUX_DIR"; fi
}

on_exit() { cleanup_lab; }
on_interrupt() { trap - EXIT INT TERM; cleanup_lab; exit 130; }
on_terminate() { trap - EXIT INT TERM; cleanup_lab; exit 143; }

pane_exists() {
  fm_backend_target_exists tmux "$TARGET"
}

pane_text_matches() {
  local regex=$1
  tmux capture-pane -p -t "$TARGET" 2>/dev/null | grep -qiE "$regex"
}

composer_chrome_rendered() {
  local cy row
  cy=$(tmux display-message -p -t "$TARGET" '#{cursor_y}' 2>/dev/null) || return 1
  case "$cy" in ''|*[!0-9]*) return 1 ;; esac
  if command -v fm_tmux_cursor_composer_row >/dev/null 2>&1; then
    row=$(fm_tmux_cursor_composer_row "$TARGET" 2>/dev/null || true)
    [ -z "$row" ] || cy=$row
  fi
  row=$(tmux capture-pane -p -t "$TARGET" -S "$cy" -E "$cy" 2>/dev/null) || return 1
  [ -n "${row//[[:space:]]/}" ]
}

handle_startup_dialog() {
  local text=$1
  case "$ADAPTER:$text" in
    claude:*Bypass*|claude:*bypass*)
      fm_backend_send_key tmux "$TARGET" Down >/dev/null 2>&1 || true
      fm_backend_send_key tmux "$TARGET" Enter >/dev/null 2>&1 || true
      ;;
    *) fm_backend_send_key tmux "$TARGET" Enter >/dev/null 2>&1 || true ;;
  esac
}

wait_for_composer() {
  local deadline=$((SECONDS + TIMEOUT)) state text matched handled=0 hash seen=""
  [ -e "$ARTIFACTS/00-startup-dialogs.txt" ] || : > "$ARTIFACTS/00-startup-dialogs.txt"
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane_exists || { sleep 1; continue; }
    state=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
    if [ "$state" = empty ] && composer_chrome_rendered; then return 0; fi
    text=$(fm_backend_capture tmux "$TARGET" 80 2>/dev/null || true)
    matched=$(printf '%s' "$text" | grep -iE 'trust|workspace trust|required|bypass permissions|dangerously|approval mode|choose.*theme|theme.*looks best|security notes|Claude Code can make mistakes' || true)
    if [ -n "$matched" ] && [ "$handled" -lt "$STARTUP_DIALOG_LIMIT" ]; then
      hash=$(printf '%s' "$matched" | shasum -a 256 | awk '{print $1}')
      case " $seen " in
        *" $hash "*) ;;
        *)
          printf '%s\n---\n' "$text" >> "$ARTIFACTS/00-startup-dialogs.txt"
          handle_startup_dialog "$text"
          seen="$seen $hash"
          handled=$((handled + 1))
          ;;
      esac
    fi
    sleep 1
  done
  return 1
}

wait_for() {
  local predicate=$1 deadline=$((SECONDS + TIMEOUT))
  shift
  while [ "$SECONDS" -lt "$deadline" ]; do
    "$predicate" "$@" && return 0
    pane_exists || return 1
    sleep 1
  done
  return 1
}

file_has_content() { [ -s "$1" ]; }
file_exists() { [ -e "$1" ]; }
pane_text_does_not_match() { ! pane_text_matches "$1"; }

submit_text() {
  local text=$1 verdict
  verdict=$(fm_backend_send_text_submit tmux "$TARGET" "$text" 3 0.4 1 2>/dev/null || true)
  [ "$verdict" != send-failed ] && [ "$verdict" != pending ]
}

send_key_list() {
  local list=$1 key
  IFS=',' read -r -a keys <<< "$list"
  for key in "${keys[@]}"; do
    fm_backend_send_key tmux "$TARGET" "$key" >/dev/null 2>&1 || return 1
    sleep 0.25
  done
}

agent_marker_matches() {
  local file=$1
  grep -qiE "$COMM_REGEX" "$file" && grep -qiE "$ARGV_REGEX" "$file"
}

launch_runtime() {
  local target_name=$1 command=$2 window_id
  if [ "$target_name" = main ]; then
    window_id=$(HOME="$LAB_HOME" tmux new-session -dP -F '#{window_id}' -s "$SESSION" -n main -c "$WORKSPACE" \
      "env HOME=$(shell_quote "$LAB_HOME") bash --noprofile --norc") || return 1
  else
    window_id=$(HOME="$LAB_HOME" tmux new-window -dP -F '#{window_id}' -t "$SESSION:" -n "$target_name" -c "$WORKSPACE" \
      "env HOME=$(shell_quote "$LAB_HOME") bash --noprofile --norc") || return 1
  fi
  TARGET=$window_id
  tmux set-window-option -t "$TARGET" automatic-rename off >/dev/null 2>&1 || true
  tmux set-window-option -t "$TARGET" allow-rename off >/dev/null 2>&1 || true
  sleep 0.5
  tmux send-keys -t "$TARGET" -l "$command"
  tmux send-keys -t "$TARGET" Enter
}

clear_composer() {
  local attempt state
  for attempt in 1 2 3; do
    case "$attempt" in
      1) tmux send-keys -t "$TARGET" C-u ;;
      2) tmux send-keys -t "$TARGET" C-a C-k ;;
      *) tmux send-keys -t "$TARGET" -N 64 BSpace ;;
    esac
    sleep 0.5
    state=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
    [ "$state" = empty ] && { printf '%s' "$state"; return 0; }
  done
  printf '%s' "$state"
  return 1
}

probe_composer() {
  local idle pending cleared
  idle=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
  capture_pane 02-composer-idle 80
  tmux send-keys -t "$TARGET" -l FM_EXAM_PENDING
  sleep 1
  pending=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
  capture_pane 02-composer-pending 80
  if ! cleared=$(clear_composer); then
    capture_pane 02-composer-cleared 80
    record_result composer fail "expected empty then pending then empty, got $idle then $pending then $cleared" \
      "evidence/02-composer-idle.ansi,evidence/02-composer-pending.ansi,evidence/02-composer-cleared.ansi"
    return 1
  fi
  capture_pane 02-composer-cleared 80
  if [ "$idle" = empty ] && [ "$pending" = pending ] && [ "$cleared" = empty ]; then
    record_result composer pass "idle classified empty, real unsubmitted text classified pending, and the composer cleared back to empty" \
      "evidence/02-composer-idle.ansi,evidence/02-composer-pending.ansi,evidence/02-composer-cleared.ansi"
  else
    record_result composer fail "expected empty then pending then empty, got $idle then $pending then $cleared" \
      "evidence/02-composer-idle.ansi,evidence/02-composer-pending.ansi,evidence/02-composer-cleared.ansi"
  fi
  return 0
}

probe_busy_interrupt_liveness() {
  local prompt alive_after interrupt_text busy_seen_at interrupt_elapsed
  local turn_ended=0 ended_early=0 interrupt_seen=0 busy_observed=0
  capture_pane 03-idle-negative 100
  if pane_text_matches "$BUSY_REGEX"; then
    record_result busy fail "recorded busy regex also matched the settled idle pane" "evidence/03-idle-negative.txt"
  fi
  prompt="Use the shell tool to run exactly: sleep $BUSY_SECONDS; printf 'FM_EXAM_BUSY_DONE\\n'. Do not run it in the background and do not do anything else."
  submit_text "$prompt" || true
  if wait_for pane_text_matches "$BUSY_REGEX"; then
    busy_observed=1
    busy_seen_at=$SECONDS
    capture_pane 03-busy 160
    record_result busy pass "recorded signature appeared during a real tool turn and not while idle" \
      "evidence/03-busy.ansi,evidence/03-idle-negative.txt"
  else
    busy_seen_at=$SECONDS
    capture_pane 03-busy-missing 160
    record_result busy fail "recorded signature did not appear during the deterministic long tool turn" \
      "evidence/03-busy-missing.ansi,evidence/03-idle-negative.txt"
  fi
  capture_processes 06-liveness-busy
  send_key_list "$INTERRUPT_KEYS" || true
  sleep 1
  if wait_for pane_text_does_not_match "$BUSY_REGEX"; then turn_ended=1; fi
  interrupt_elapsed=$((SECONDS - busy_seen_at))
  if [ "$turn_ended" = 1 ] && [ "$interrupt_elapsed" -lt "$((BUSY_SECONDS - 2))" ]; then
    ended_early=1
  fi
  capture_pane 04-interrupt 180
  capture_processes 04-interrupt
  alive_after=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  interrupt_text=$(cat "$ARTIFACTS/04-interrupt.txt")
  if [ "$INTERRUPT_REGEX" != - ] && printf '%s' "$interrupt_text" | grep -qiE "$INTERRUPT_REGEX"; then
    interrupt_seen=1
  fi
  printf 'busy_observed=%s\nbusy_seconds=%s\nelapsed_to_not_busy=%s\nturn_ended=%s\nended_before_natural_completion=%s\ninterrupt_regex=%s\ninterrupt_regex_matched=%s\n' \
    "$busy_observed" "$BUSY_SECONDS" "$interrupt_elapsed" "$turn_ended" "$ended_early" "$INTERRUPT_REGEX" "$interrupt_seen" \
    > "$ARTIFACTS/04-interrupt-timing.txt"
  if [ "$busy_observed" != 1 ]; then
    record_result interrupt fail "the busy signature was never observed, so no turn boundary existed for the recorded key to end" \
      "evidence/04-interrupt.ansi,evidence/04-interrupt.processes.txt,evidence/04-interrupt-timing.txt"
  elif [ "$alive_after" = "$ALIVE_VERDICT" ] && agent_marker_matches "$ARTIFACTS/04-interrupt.processes.txt" \
     && [ "$turn_ended" = 1 ] && { [ "$interrupt_seen" = 1 ] || [ "$ended_early" = 1 ]; }; then
    record_result interrupt pass "recorded key ended the ${BUSY_SECONDS}s tool turn after ${interrupt_elapsed}s while the runtime process survived" \
      "evidence/04-interrupt.ansi,evidence/04-interrupt.processes.txt,evidence/04-interrupt-timing.txt"
  else
    record_result interrupt fail "expected a live runtime plus recorded interrupt text or a turn end before the ${BUSY_SECONDS}s tool call could finish, got backend=$alive_after ended=$turn_ended elapsed=${interrupt_elapsed}s interrupt_text=$interrupt_seen" \
      "evidence/04-interrupt.ansi,evidence/04-interrupt.processes.txt,evidence/04-interrupt-timing.txt"
  fi
}

probe_autonomy() {
  local proof="$WORKSPACE/.fm-exam-autonomy" token="FM_EXAM_AUTONOMY_${RANDOM}_${RANDOM}" prompt mode_present=0
  rm -f "$HOOK_MARKER" "$HOOK_RAW" "$proof"
  if [ "$ADAPTER" = pi ] || printf '%s' "$LAUNCH_CMD" | grep -qE -- "$AUTONOMY_FLAG"; then
    mode_present=1
  fi
  printf '%s\n' "$token" > "$ARTIFACTS/resume-token.txt"
  prompt="Use the shell tool without asking for approval to run exactly: printf '%s\\n' '$token' > '$proof'. Then reply exactly $token and remember that token for this session."
  submit_text "$prompt" || true
  if [ "$mode_present" = 1 ] && wait_for file_has_content "$proof" && [ "$(cat "$proof" 2>/dev/null)" = "$token" ]; then
    capture_pane 01-autonomy 180
    printf 'launch=%s\nautonomy=%s\nproof=%s\n' "$LAUNCH_CMD" "$AUTONOMY_FLAG" "$(cat "$proof")" \
      > "$ARTIFACTS/01-autonomy-command.txt"
    record_result autonomy pass "the recorded unattended mode executed a real tool without an approval response" \
      "evidence/01-autonomy-command.txt,evidence/01-autonomy.ansi"
  else
    capture_pane 01-autonomy-failed 180
    record_result autonomy fail "the recorded unattended mode was absent or its tool proof was not created" \
      "evidence/01-autonomy-failed.ansi"
  fi
  if wait_for file_exists "$HOOK_MARKER" && [ -s "$HOOK_RAW" ]; then
    cp "$HOOK_RAW" "$ARTIFACTS/05-turn-end-payload.txt"
  fi
}

probe_turnend() {
  local evidence
  if [ -s "$ARTIFACTS/05-turn-end-payload.txt" ]; then
    record_result turn-end pass "the native per-turn hook produced an external marker and raw payload" \
      "evidence/05-turn-end-payload.txt"
  else
    capture_pane 05-turn-end-missing 180
    evidence="evidence/05-turn-end-missing.ansi"
    if [ -s "$HOOK_RAW" ]; then
      cp "$HOOK_RAW" "$ARTIFACTS/05-turn-end-late-payload.txt"
      evidence="evidence/05-turn-end-late-payload.txt,$evidence"
      record_result turn-end fail "the native hook payload arrived only after the scored autonomy-turn window" \
        "$evidence"
    else
      record_result turn-end fail "the completed turn produced no independently recorded hook evidence" \
        "$evidence"
    fi
  fi
}

probe_liveness() {
  local verdict
  verdict=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  if [ "$verdict" = "$ALIVE_VERDICT" ] && agent_marker_matches "$ARTIFACTS/06-liveness-busy.processes.txt"; then
    record_result liveness pass "backend verdict and raw process markers matched the adapter record" \
      "evidence/06-liveness-busy.processes.txt"
  else
    record_result liveness fail "expected backend=$ALIVE_VERDICT plus comm=$COMM_REGEX and argv=$ARGV_REGEX, got backend=$verdict" \
      "evidence/06-liveness-busy.processes.txt"
  fi
}

probe_exit() {
  local deadline verdict
  # Wait for the previous turn to finish first. An exit command typed while a
  # turn is still running is swallowed as follow-up text rather than executed
  # (observed on cursor: "/quit" was appended to the running prompt and the
  # runtime stayed live), which scores a working exit path as a failure.
  wait_for pane_text_does_not_match "$BUSY_REGEX" >/dev/null 2>&1 || true
  deadline=$((SECONDS + TIMEOUT))
  capture_pane 07-before-exit 100
  tmux send-keys -t "$TARGET" -l "$EXIT_COMMAND"
  sleep 1.2
  tmux send-keys -t "$TARGET" Enter
  sleep 1.5
  verdict=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  if [ "$verdict" != dead ]; then
    tmux send-keys -t "$TARGET" Enter >/dev/null 2>&1 || true
  fi
  while [ "$SECONDS" -lt "$deadline" ]; do
    verdict=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
    [ "$verdict" = dead ] && break
    sleep 1
  done
  capture_pane 07-exit 200
  if [ "$verdict" = dead ]; then
    record_result exit pass "the recorded exit command returned the pane to its shell" "evidence/07-exit.ansi"
  else
    record_result exit fail "the runtime remained live after the recorded exit command" "evidence/07-exit.ansi"
  fi
}

cursor_resume_id() {
  grep -Eo 'agent --resume[= ][0-9a-fA-F-]{20,}' "$ARTIFACTS/07-exit.txt" 2>/dev/null \
    | tail -1 | sed -E 's/.*--resume[= ]//' || true
}

codex_resume_id() {
  find "$LAB_HOME/.codex/sessions" -type f -name '*.jsonl' -print 2>/dev/null \
    | sort | tail -1 | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}' || true
}

probe_resume() {
  local token cursor_id="" restored=0 resume_evidence
  token=$(cat "$ARTIFACTS/resume-token.txt" 2>/dev/null || true)
  if [ -z "$token" ]; then
    record_result resume fail "the autonomy-turn resume nonce was never recorded, so restored-conversation evidence cannot be verified" ""
    return 0
  fi
  if [ "$RESUME_MODE" = cursor-id ]; then
    cursor_id=$(cursor_resume_id)
    if [ -z "$cursor_id" ]; then
      record_result resume fail "the exit evidence did not contain Cursor's resume id" "evidence/07-exit.txt"
      return 0
    fi
  elif [ "$RESUME_MODE" = session-id ]; then
    cursor_id=$(codex_resume_id)
    if [ -z "$cursor_id" ]; then
      record_result resume fail "the isolated Codex home did not contain a recorded session id" "evidence/07-exit.txt"
      return 0
    fi
  fi
  build_launch_command 1 "$cursor_id" || {
    record_result resume fail "could not construct the recorded resume command" ""
    return 0
  }
  printf '%s\n' "$RESUME_CMD" > "$ARTIFACTS/08-resume-command.txt"
  launch_runtime resume "$RESUME_CMD" || {
    record_result resume fail "could not launch the resume command" "evidence/08-resume-command.txt"
    return 0
  }
  if wait_for_composer; then
    capture_pane 08-resume-initial 220
    if grep -qF "$token" "$ARTIFACTS/08-resume-initial.txt"; then
      restored=1
    else
      submit_text "Reply with exactly the resume token I asked you to remember in the previous turn." || true
      if wait_for pane_text_matches "$token"; then restored=1; fi
      capture_pane 08-resume-recall 220
    fi
  fi
  if [ "$restored" = 1 ]; then
    resume_evidence="evidence/08-resume-command.txt,evidence/08-resume-initial.ansi"
    [ -f "$ARTIFACTS/08-resume-recall.ansi" ] && resume_evidence+=",evidence/08-resume-recall.ansi"
    record_result resume pass "the recorded resume path restored evidence from the prior conversation" \
      "$resume_evidence"
  else
    capture_pane 08-resume-failed 220
    record_result resume fail "the resumed runtime did not restore or recall the prior conversation token" \
      "evidence/08-resume-command.txt,evidence/08-resume-failed.ansi"
  fi
}

prepare_run() {
  local stamp base
  command -v tmux >/dev/null 2>&1 || { echo "error: tmux is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; return 1; }
  command -v "$BINARY" >/dev/null 2>&1 || { echo "error: adapter binary '$BINARY' is not installed" >&2; return 1; }
  case "$BUSY_SECONDS" in ''|*[!0-9]*) echo "error: FM_HARNESS_EXAM_BUSY_SECONDS must be a positive integer" >&2; return 1 ;; esac
  [ "$BUSY_SECONDS" -ge "$BUSY_SECONDS_MIN" ] || {
    echo "error: FM_HARNESS_EXAM_BUSY_SECONDS must be at least $BUSY_SECONDS_MIN so an interrupt stays distinguishable from natural turn completion" >&2
    return 1
  }
  [ "$TIMEOUT" -gt "$BUSY_SECONDS" ] || {
    echo "error: --timeout must exceed the $BUSY_SECONDS second busy turn" >&2
    return 1
  }
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base=${FM_HOME:-$ROOT}
  [ -n "$OUTPUT" ] || OUTPUT="$base/data/harness-exam/$ADAPTER-$stamp"
  [ ! -e "$OUTPUT" ] || { echo "error: output already exists: $OUTPUT" >&2; return 1; }
  mkdir -p "$OUTPUT/evidence"
  OUTPUT=$(cd "$OUTPUT" && pwd -P)
  ARTIFACTS="$OUTPUT/evidence"
  RESULTS_TSV="$OUTPUT/.results.tsv"
  : > "$RESULTS_TSV"
  LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-harness-exam.$ADAPTER.XXXXXX")
  # Squeeze repeated slashes: macOS TMPDIR already ends in "/", so the raw path
  # carries a "T//" that ends up inside generated hook commands. Cursor's hook
  # runner silently does not execute a command path containing "//" - the stop
  # hook simply never fired, which the turn-end probe then reported as a runtime
  # regression (verified 2026-08-13: the same recorder at the same location fired
  # as soon as the path was normalized).
  LAB_ROOT=$(printf '%s' "$LAB_ROOT" | tr -s '/')
  LAB_HOME="$LAB_ROOT/home"
  WORKSPACE="$LAB_ROOT/workspace"
  HOOK_MARKER="$LAB_ROOT/turn-ended"
  HOOK_RAW="$LAB_ROOT/turn-end.raw"
  mkdir -p "$LAB_HOME" "$WORKSPACE"
  prepare_tmux_socket || return 1
  trap on_exit EXIT
  trap on_interrupt INT
  trap on_terminate TERM
  git -C "$WORKSPACE" init -q
  printf '# Firstmate worker-runtime exam lab\n' > "$WORKSPACE/README.md"
  git -C "$WORKSPACE" add README.md
  git -C "$WORKSPACE" -c user.name='Firstmate Exam' -c user.email='exam@example.invalid' commit -qm initial
  prepare_credential_bridges || return 1
  lab_auth_gate || return 3
  prepare_hook || return 1
  VERSION=$("$BINARY" --version 2>&1 | head -1 || true)
  [ -n "$VERSION" ] || VERSION=unknown
  printf '%s\n' "$VERSION" > "$ARTIFACTS/runtime-version.txt"
  printf 'adapter=%s\nversion=%s\nlab=%s\nworkspace=%s\nstartup_dialog=%s\n' \
    "$ADAPTER" "$VERSION" "$LAB_ROOT" "$WORKSPACE" "$STARTUP_DIALOG" \
    > "$ARTIFACTS/run-context.txt"
}

run_exam() {
  local prepare_rc=0
  prepare_run || prepare_rc=$?
  # 3 is the setup-blocker code from lab_auth_gate: no scorecard is written,
  # because an unauthenticated lab produces no evidence worth scoring.
  [ "$prepare_rc" = 0 ] || { [ "$prepare_rc" = 3 ] && return 3; return 2; }
  build_launch_command 0 || return 2
  printf '%s\n' "$LAUNCH_CMD" > "$ARTIFACTS/00-launch-command.txt"
  if ! launch_runtime main "$LAUNCH_CMD"; then
    record_missing_results
    render_results
    return 1
  fi
  if ! wait_for_composer; then
    capture_pane 00-startup-failed 200
    capture_processes 00-startup-failed
    record_missing_results
    render_results
    return 1
  fi
  capture_pane 00-startup 120
  probe_autonomy
  if ! probe_composer; then
    record_missing_results
    render_results
    return 1
  fi
  probe_busy_interrupt_liveness
  probe_turnend
  probe_liveness
  probe_exit
  probe_resume
  record_missing_results
  render_results
  cleanup_lab
  if [ "$RUN_FAILED" = 0 ]; then
    printf 'PASS %s %s: %s/results.json\n' "$ADAPTER" "$VERSION" "$OUTPUT"
    return 0
  fi
  printf 'FAIL %s %s: %s/scorecard.md\n' "$ADAPTER" "$VERSION" "$OUTPUT" >&2
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --list) MODE=list; shift ;;
      --plan)
        [ "$#" -ge 2 ] || { echo "error: --plan requires an adapter" >&2; return 2; }
        MODE=plan
        ADAPTER=$2
        shift 2
        ;;
      --model)
        [ "$#" -ge 2 ] || { echo "error: --model requires a value" >&2; return 2; }
        MODEL=$2
        shift 2
        ;;
      --output)
        [ "$#" -ge 2 ] || { echo "error: --output requires a directory" >&2; return 2; }
        OUTPUT=$2
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || { echo "error: --timeout requires seconds" >&2; return 2; }
        TIMEOUT=$2
        case "$TIMEOUT" in ''|*[!0-9]*|0) echo "error: --timeout must be a positive integer" >&2; return 2 ;; esac
        shift 2
        ;;
      --keep-lab) KEEP_LAB=1; shift ;;
      --share-login-keychain) SHARE_LOGIN_KEYCHAIN=1; shift ;;
      --source-home)
        [ "$#" -ge 2 ] || { echo "error: --source-home requires a directory" >&2; return 2; }
        SOURCE_HOME=$2
        shift 2
        ;;
      --*) echo "error: unknown option '$1'" >&2; return 2 ;;
      *)
        [ -z "$ADAPTER" ] || { echo "error: unexpected argument '$1'" >&2; return 2; }
        ADAPTER=$1
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@" || return $?
  case "$MODE" in
    list) list_adapters; return 0 ;;
    plan) print_plan "$ADAPTER"; return $? ;;
  esac
  [ -n "$ADAPTER" ] || { usage >&2; return 2; }
  load_expectation "$ADAPTER" || {
    echo "error: unsupported adapter '$ADAPTER' (expected one of: $(list_adapters | paste -sd, -))" >&2
    return 2
  }
  run_exam
}

if [ "${FM_HARNESS_EXAM_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi

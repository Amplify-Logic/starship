#!/usr/bin/env bash
# Shared stand-in primary for tests that type into a first mate's own pane
# through bin/fm-desk-voice.sh: a live process the session lock accepts as a
# harness, beneath a stand-in multiplexer whose fake herdr and tmux log every
# call, so no real pane ever receives text or keys. Sourced by
# tests/fm-deepgram-desk.test.sh and tests/fm-direct-line.test.sh; the caller
# defines new_home <name> (printing a fresh home with config/ and state/) and
# DESK (the desk-voice script).

# --- desk-voice send: straight into the primary's chat pane ------------------
#
# A stand-in primary: a live process whose command line names a harness (a
# python script under a claude/ directory, or another harness's, which the
# session-lock identity accepts) and whose environment names a Herdr pane (or
# a tmux pane). It holds the fixture home's session lock, and runs beneath a
# stand-in multiplexer server. The herdr and tmux on PATH are fakes that log
# every call, so no real pane ever receives text or keys.
#
# The herdr fake draws Claude's chat box between two rules: the draft file is
# typed text, the ghost file a dim suggested prompt shown while nothing is
# typed, and the stash file a draft set aside with Ctrl+S, shown as
# `› stashed` in the footer. Its keys behave as Claude's do: Ctrl+S stashes a
# typed draft or pops the stash into an empty box, Ctrl+U clears the box, and
# Enter submits the box (the suggestion when nothing is typed) to the
# submitted log, then restores a stash into the box. Knob files bend it: wrap
# draws the box 40 columns wide, where Ctrl+U deletes one wrapped row;
# drop-head loses the first typed character; no-marker hides `› stashed`;
# narrow draws `› stashed` on a footer row of its own, as a narrow pane wraps it;
# pop-fails refuses the Ctrl+S that pops a stash; refold makes Enter redraw
# the box as a pasted-text placeholder plus the typed tail without submitting;
# late-paste holds sent text back from the box for the number of screen reads
# it names, as a busy Claude draws input late, yet handles it before any key.
# Text over 800 characters folds as Claude folds it (verified live on claude
# 2.1.283): a bracketed paste into one `[Pasted text #N]` placeholder, a typed
# burst into a placeholder plus its literal tail. Enter expands a placeholder
# back into its text.

desk_send_fixture() {  # <name> [tmux|herdr] [harness] -> home; starts the stand-in primary
  local name=$1 backend=${2:-herdr} harness=${3:-claude} home dir fb pid envs marker
  local -a pane_env
  home=$(new_home "$name")
  dir="$home/fixture"
  fb="$dir/bin"
  mkdir -p "$fb" "$dir/$harness"
  # A node linked under the harness's own name is a process whose name the
  # session-lock identity reads as that harness, as a real `claude` is.
  # Without node, a python script under the harness's directory stands in.
  if command -v node >/dev/null 2>&1; then
    ln -s "$(command -v node)" "$dir/$harness/$harness"
    set -- "$dir/$harness/$harness" -e 'setTimeout(() => {}, 60000)'
  else
    printf 'import time\ntime.sleep(60)\n' > "$dir/$harness/holder.py"
    set -- python3 "$dir/$harness/holder.py"
  fi
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/herdr.log"
draw_queued() {
  [ -e "$dir/queued" ] || return 0
  cat "$dir/queued" >> "$dir/draft"
  rm -f "$dir/queued" "$dir/queued-reads"
}
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.4","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    if [ -e "$dir/unfocused" ]; then f=false; else f=true; fi
    printf '{"result":{"pane":{"pane_id":"%s","focused":%s}}}\n' "$3" "$f" ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[]}}}\n' \
      "$4" "$(cat "$dir/shell-pid")" ;;
  "pane read")
    if [ -e "$dir/queued" ]; then
      left=$(( $(cat "$dir/queued-reads") - 1 ))
      if [ "$left" -le 0 ]; then draw_queued; else printf '%s' "$left" > "$dir/queued-reads"; fi
    fi
    case " $* " in *' ansi '*) ansi=1 ;; *) ansi=0 ;; esac
    if [ -e "$dir/modal" ]; then
      if [ "$ansi" = 1 ]; then cat "$dir/modal"; else sed $'s/\033\\[[0-9;:]*m//g' "$dir/modal"; fi
      exit 0
    fi
    # The screen is the case's capture, or a bare chat box, with its last
    # prompt row redrawn from the box's state the way Claude draws it.
    screen="$dir/screen"
    if [ ! -e "$screen" ]; then
      screen="$dir/screen.default"
      printf '%s\n' '────────────────────────────────────────' '❯' \
        '────────────────────────────────────────' '  ⏵⏵ auto mode on' > "$screen"
    fi
    esc=$'\033'
    if [ -e "$dir/stale-left" ]; then
      draft=$(cat "$dir/stale-draft")
      left=$(( $(cat "$dir/stale-left") - 1 ))
      if [ "$left" -le 0 ]; then rm -f "$dir/stale-left"; else printf '%s' "$left" > "$dir/stale-left"; fi
    else
      draft=$(cat "$dir/draft" 2>/dev/null)
    fi
    row="❯"$'\302\240'"${esc}[0m"
    if [ -n "$draft" ] && [ -e "$dir/wrap" ]; then
      row+="${esc}[38;2;255;255;255m${draft:0:40}"
      rest=${draft:40}
      while [ -n "$rest" ]; do
        row+='\n  '"${rest:0:40}"
        rest=${rest:40}
      done
      row+="${esc}[0m"
    elif [ -n "$draft" ]; then
      row+="${esc}[38;2;255;255;255m${draft}${esc}[0m"
    elif [ -e "$dir/ghost" ]; then
      row+="${esc}[2m$(cat "$dir/ghost")${esc}[0m"
    fi
    stash=0
    [ ! -e "$dir/stash" ] || [ -e "$dir/no-marker" ] || stash=1
    [ "$stash" = 0 ] || [ ! -e "$dir/narrow" ] || stash=2
    last=$(grep -n '❯' "$screen" | tail -n 1 | cut -d: -f1)
    awk -v n="$last" -v row="$row" -v stash="$stash" -v rows="$(wc -l < "$screen")" '
      NR == n { print row "\r"; next }
      NR == rows && stash == 2 { print; print "                    › stashed\r"; next }
      NR == rows && stash == 1 { sub(/\r$/, ""); print $0 "    › stashed\r"; next }
      { print }
    ' "$screen" > "$dir/screen.now"
    if [ "$ansi" = 1 ]; then cat "$dir/screen.now"; else sed $'s/\033\\[[0-9;:]*m//g' "$dir/screen.now"; fi ;;
  "pane send-text")
    [ ! -e "$dir/send-text-fails" ] || exit 1
    if [ -e "$dir/hold-send" ]; then
      : > "$dir/send-held"
      for _ in $(seq 1 150); do
        [ -e "$dir/release-send" ] && break
        sleep 0.1
      done
      [ -e "$dir/release-send" ] || exit 1
    fi
    if [ -e "$dir/drop-head" ]; then text=${4:1}; else text=$4; fi
    open=$'\033[200~' close=$'\033[201~'
    n=$(( $(cat "$dir/pastes" 2>/dev/null || echo 0) + 1 ))
    if [ "${text#"$open"}" != "$text" ] && [ "${text%"$close"}" != "$text" ]; then
      text=${text#"$open"}
      text=${text%"$close"}
      if [ "${#text}" -gt 800 ]; then
        printf '%s' "$n" > "$dir/pastes"
        printf '%s' "$text" > "$dir/paste-$n"
        text="[Pasted text #$n]"
      fi
    else
      text=${text%"$close"}
      if [ "${#text}" -gt 800 ]; then
        printf '%s' "$n" > "$dir/pastes"
        printf '%s' "${text:0:${#text}-40}" > "$dir/paste-$n"
        text="[Pasted text #$n]${text: -40}"
      fi
    fi
    if [ -e "$dir/late-paste" ]; then
      printf '%s' "$text" >> "$dir/queued"
      cp "$dir/late-paste" "$dir/queued-reads"
    else
      printf '%s' "$text" >> "$dir/draft"
    fi
    [ ! -e "$dir/type-before-enter" ] || cat "$dir/type-before-enter" >> "$dir/draft" ;;
  "pane send-keys")
    draw_queued
    case "$4" in
      ctrl+s)
        [ ! -e "$dir/no-stash" ] || exit 0
        if [ -s "$dir/draft" ]; then
          mv "$dir/draft" "$dir/stash"
          : > "$dir/draft"
        elif [ -e "$dir/stash" ]; then
          [ ! -e "$dir/pop-fails" ] || exit 1
          mv "$dir/stash" "$dir/draft"
        fi ;;
      ctrl+u)
        draft=$(cat "$dir/draft" 2>/dev/null)
        if [ -e "$dir/wrap" ] && [ "${#draft}" -gt 40 ]; then
          printf '%s' "${draft:0:$(( (${#draft} - 1) / 40 * 40 ))}" > "$dir/draft"
        else
          : > "$dir/draft"
        fi ;;
      *)
        : > "$dir/entered"
        if [ -e "$dir/swallow-enter-once" ]; then
          rm "$dir/swallow-enter-once"
          exit 0
        fi
        [ ! -e "$dir/never-works" ] || exit 0
        if [ -e "$dir/refold" ]; then
          draft=$(cat "$dir/draft")
          printf '[Pasted text #2 +3 lines]%s' "${draft: -40}" > "$dir/draft"
          exit 0
        fi
        if [ -s "$dir/draft" ]; then
          draft=$(cat "$dir/draft")
          for paste in "$dir"/paste-*; do
            [ -e "$paste" ] || continue
            draft=${draft//"[Pasted text #${paste##*-}]"/$(cat "$paste")}
          done
          printf '%s\n' "$draft" >> "$dir/submitted"
          if [ -e "$dir/stale-reads" ]; then
            printf '%s' "$draft" > "$dir/stale-draft"
            cp "$dir/stale-reads" "$dir/stale-left"
          fi
        elif [ -e "$dir/ghost" ]; then
          { cat "$dir/ghost"; printf '\n'; } >> "$dir/submitted"
        fi
        : > "$dir/draft"
        [ ! -e "$dir/stash" ] || mv "$dir/stash" "$dir/draft"
        [ ! -e "$dir/type-after-enter" ] || mv "$dir/type-after-enter" "$dir/draft" ;;
    esac ;;
  "agent get")
    if [ -e "$dir/entered" ] && [ ! -e "$dir/never-works" ] && [ ! -e "$dir/agent-idle" ]; then s=working; else s=idle; fi
    if [ -e "$dir/agent" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$(cat "$dir/agent")" "$s"
    else
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$s"
    fi ;;
esac
exit 0
SH
  # By default the tmux fake answers only the pane and front checks. Ring
  # race cases opt into the same composer model as Herdr, through tmux's
  # capture, buffer and key operations.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/tmux.log"
case "$*" in
  *'show-options -gv focus-events'*) cat "$dir/tmux-focus-events" 2>/dev/null || printf 'on\n' ;;
  *'@fm-focus-since'*) cat "$dir/tmux-focus-since" 2>/dev/null ;;
  *'#{pane_pid}'*) cat "$dir/shell-pid" ;;
  *'#{session_id} #{window_active}#{pane_active}'*) cat "$dir/tmux-active" ;;
  *'#{pane_id}'*) printf '%%9\n' ;;
  list-clients*) cat "$dir/tmux-clients" 2>/dev/null ;;
  *)
    [ -e "$dir/tmux-composer" ] || exit 1
    case "$1" in
      capture-pane) "$dir/bin/herdr" pane read --pane w7:p3 --format ansi ;;
      display-message)
        case "$*" in *'#{cursor_y}'*) printf '1\n' ;; *) exit 1 ;; esac ;;
      load-buffer) cat > "$dir/tmux-buffer" ;;
      paste-buffer) "$dir/bin/herdr" pane send-text w7:p3 "$(cat "$dir/tmux-buffer")" ;;
      send-keys)
        case "$4" in
          -l) "$dir/bin/herdr" pane send-text w7:p3 "$5" ;;
          Enter) "$dir/bin/herdr" pane send-keys w7:p3 enter ;;
          *) exit 1 ;;
        esac ;;
      *) exit 1 ;;
    esac ;;
esac
SH
  printf '#!/bin/sh\nexit 0\n' > "$fb/osascript"
  chmod +x "$fb/herdr" "$fb/tmux" "$fb/osascript"
  : > "$dir/herdr.log"
  : > "$dir/tmux.log"
  if [ "$backend" = tmux ]; then
    pane_env=(TMUX="$dir/tmux.sock,1,0" TMUX_PANE=%9)
    marker=TMUX_PANE=%9
  else
    pane_env=(HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fm-desk-send-test
      HERDR_SOCKET_PATH="$dir/herdr.sock")
    marker=HERDR_PANE_ID=w7:p3
  fi
  # The stand-in primary runs for no home unless DESK_FIXTURE_HOME_ENV names
  # one: "self" for this fixture's own home, or any other path.
  case "${DESK_FIXTURE_HOME_ENV:-}" in
    '') ;;
    self) pane_env+=(FM_HOME="$home") ;;
    *) pane_env+=(FM_HOME="$DESK_FIXTURE_HOME_ENV") ;;
  esac
  # The stand-in server is the stand-in primary's parent, as a multiplexer
  # server is the parent of the pane that hosts a real primary.
  # shellcheck disable=SC2016  # expanded by the inner shell
  env -u FM_HOME "${pane_env[@]}" bash -c \
    'out=$1; shift; "$@" >/dev/null 2>&1 & printf "%s\n" "$!" > "$out.tmp"; mv "$out.tmp" "$out"; wait' \
    _ "$dir/holder-pid" "$@" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/server-pid"
  for _ in $(seq 1 50); do
    [ -s "$dir/holder-pid" ] && break
    sleep 0.1
  done
  pid=$(cat "$dir/holder-pid" 2>/dev/null) || return 1
  printf '%s\n' "$pid" > "$home/state/.lock"
  # The pane's root process is the stand-in itself unless a case says otherwise.
  printf '%s\n' "$pid" > "$dir/shell-pid"
  : > "$dir/draft"
  for _ in $(seq 1 50); do
    if [ -r "/proc/$pid/environ" ]; then
      envs=$(tr '\0' '\n' < "/proc/$pid/environ")
    else
      envs=$(ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n')
    fi
    case "$envs" in *"$marker"*) break ;; esac
    sleep 0.1
  done
  case "$envs" in
    *"$marker"*) ;;
    *) kill "$pid" 2>/dev/null; return 1 ;;
  esac
  printf '%s\n' "$home"
}

# Each case starts its own stand-in; stop it when the case is done.
desk_send_done() {  # <home>
  kill "$(cat "$1/fixture/holder-pid")" 2>/dev/null || true
}

desk_send_skip() {  # <case>
  printf 'skip: %s: this host does not expose the stand-in primary environment\n' "$1"
}

desk_send() {  # <home> [--image <png>]... <text> -> stdout of fm-desk-voice.sh send
  local home=$1 dir="$1/fixture"
  shift
  (
    unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
      FM_BACKEND_HERDR_BIN FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
    PATH="$dir/bin:$PATH" FM_FAKE_HERDR_DIR="$dir" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.1 \
      "$DESK" send --source test-suite "$@"
  )
}

herdr_calls() {  # <home> <subcommand words...> -> matching log lines, readable
  local home=$1 pattern
  shift
  pattern=$(printf '\x1f%s' "$@")
  grep -F -- "$pattern" "$home/fixture/herdr.log" | tr '\037' ' '
}

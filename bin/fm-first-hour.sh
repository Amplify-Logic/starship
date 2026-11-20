#!/usr/bin/env bash
# fm-first-hour.sh - the first-hour checklist: every step from a blank machine
# to the first report back, each ticked from evidence on this machine, never
# from a record of having been told. A step ticks itself off the moment its
# evidence exists, so the list is always current, and --watch keeps it on
# screen, redrawn, until the last step is done.
#
# The steps, in order, and what ticks each one:
#    1. Homebrew, Node and jq       brew and jq on PATH; node and npm answer
#                                   with a version
#    2. Claude Code                 claude answers with a version
#    3. Starship's tools            `bin/fm-bootstrap.sh install-missing
#                                   --check` finds nothing to install
#    4. Signed in to GitHub         `gh auth status` succeeds
#    5. Signed in to Claude         `claude auth status` reports loggedIn true
#    6. First mate started          the home's state/ folder holds a record
#    7. Your name and tone          data/captain.md has a `Call me:` line under
#                                   `## Address and tone`
#    8. What you'd like help with   data/captain.md has a bullet under
#                                   `## What matters`
#    9. House rules                 data/captain.md has a bullet under
#                                   `## Standing rules`
#   10. Your private repository     `bin/fm-addon.sh root` succeeds
#   11. Your first project          a repository under projects/ with a first
#                                   commit, other than the private
#                                   repository's checkout
#   12. First report back           any data/<task>/report.md
#
# Below the list, one "Next:" line says how to finish the first open step.
# Steps 1 to 5 belong to the setup command and the two sign-ins, in a plain
# terminal; steps 6 to 12 to the first conversation (the first-voyage skill).
# It reads only; it installs, signs in and writes nothing.
#
# Usage:
#   fm-first-hour.sh [--watch [SECONDS]]
#   --watch   redraw the list every SECONDS (default 10) until every step is
#             done, then print it once more and exit 0
# Environment: FM_HOME selects the home (default: this code root).
#   FM_FIRST_HOUR_BOOTSTRAP names the tool check to run instead of
#   bin/fm-bootstrap.sh (a test seam).
# Exit: 0 when every step is done; 1 while any step is open; 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
BOOTSTRAP="${FM_FIRST_HOUR_BOOTSTRAP:-$SCRIPT_DIR/fm-bootstrap.sh}"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

has_version() {  # <command...>: true when the command prints a digit
  local out
  out=$(fm_run_timed 10 "$@" </dev/null 2>/dev/null | head -n 1) || return 1
  case "$out" in *[0-9]*) return 0 ;; esac
  return 1
}

# section_has <heading> <pattern>: a line matching the extended regex
# <pattern> sits under the `## <heading>` section of data/captain.md.
section_has() {
  local file="$FM_HOME/data/captain.md"
  [ -f "$file" ] || return 1
  awk -v heading="## $1" -v pattern="$2" '
    $0 == heading { inside = 1; next }
    /^## / { inside = 0 }
    inside && $0 ~ pattern { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file"
}

step_prereqs() {
  command -v brew >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && has_version node --version && has_version npm --version
}
step_claude() { has_version claude --version; }
step_tools() { FM_HOME="$FM_HOME" fm_run_timed 60 "$BOOTSTRAP" install-missing --check >/dev/null 2>&1 </dev/null; }
step_github() { command -v gh >/dev/null 2>&1 && fm_run_timed 15 gh auth status >/dev/null 2>&1 </dev/null; }
step_claude_login() {
  command -v claude >/dev/null 2>&1 || return 1
  fm_run_timed 15 claude auth status </dev/null 2>/dev/null | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'
}
step_started() { [ -d "$FM_HOME/state" ] && [ -n "$(ls -A "$FM_HOME/state" 2>/dev/null)" ]; }
step_name() { section_has 'Address and tone' '^- Call me:[[:space:]]*[^[:space:]]'; }
step_matters() { section_has 'What matters' '^- [^[:space:]]'; }
step_rules() { section_has 'Standing rules' '^- [^[:space:]]'; }
step_addon() { FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-addon.sh" root >/dev/null 2>&1; }
step_project() {
  local addon clone
  addon=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-addon.sh" root 2>/dev/null) || addon=
  for clone in "$FM_HOME"/projects/*/; do
    [ -d "$clone" ] || continue
    clone=${clone%/}
    [ -n "$addon" ] && [ "$clone" -ef "$addon" ] && continue
    # Only the folder's own repository counts: without .git here, git walks
    # up and would answer with the home's own HEAD, since a home is itself a
    # Starship clone.
    [ -e "$clone/.git" ] || continue
    git -C "$clone" rev-parse --verify --quiet HEAD >/dev/null 2>&1 && return 0
  done
  return 1
}
step_report() {
  local report
  for report in "$FM_HOME"/data/*/report.md; do
    [ -f "$report" ] && return 0
  done
  return 1
}

if [ "$(uname -s)" = Darwin ]; then
  SETUP_HINT="in a plain Terminal window (not inside Herdr), run: curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/starship/main/bin/fm-mac-setup.sh | bash"
else
  SETUP_HINT="in a plain terminal (not inside Herdr), run: curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/starship/main/bin/fm-linux-setup.sh | bash"
fi

# One step per line: <check function>|<label>|<how to finish it>.
STEPS="step_prereqs|Homebrew, Node and jq|$SETUP_HINT
step_claude|Claude Code|$SETUP_HINT
step_tools|Starship's tools|in a plain terminal (not inside Herdr), run: $ROOT/bin/fm-bootstrap.sh install-missing
step_github|Signed in to GitHub|in a new terminal window, run: gh auth login
step_claude_login|Signed in to Claude|in a new terminal window, run claude, sign in, then type /exit
step_started|First mate started|open a new terminal window and type: onboard-starship
step_name|Your name, and how you like to be talked to|say hello to your first mate; it asks your name first
step_matters|What you'd like help with|answer your first mate's second question
step_rules|House rules|answer your first mate's question about its house rules
step_addon|Your private repository|say yes when your first mate offers to make it
step_project|Your first project|give your first mate a GitHub repository, or a folder of your own work
step_report|First report back|say go when your first mate proposes the first report"

render() {
  local total=0 done_count=0 next='' lines='' fn label hint mark
  while IFS='|' read -r fn label hint; do
    [ -n "$fn" ] || continue
    total=$((total + 1))
    if "$fn"; then
      mark='[x]'
      done_count=$((done_count + 1))
    else
      mark='[ ]'
      [ -n "$next" ] || next="$label - $hint"
    fi
    lines="$lines  $mark $label
"
  done <<EOF
$STEPS
EOF
  printf 'Your first hour with Starship: %s of %s done\n\n%s\n' "$done_count" "$total" "$lines"
  if [ -n "$next" ]; then
    printf 'Next: %s\n' "$next"
    return 1
  fi
  printf 'All done: you are set up.\n'
  return 0
}

WATCH=0
INTERVAL=10
case "$#:${1:-}" in
  0:) ;;
  1:--watch) WATCH=1 ;;
  2:--watch)
    case "$2" in ''|*[!0-9]*|0) echo "fm-first-hour.sh: --watch takes a whole number of seconds" >&2; exit 2 ;; esac
    WATCH=1
    INTERVAL=$2
    ;;
  1:-h|1:--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if [ "$WATCH" = 0 ]; then
  render
  exit
fi
while :; do
  frame=$(render) && status=0 || status=$?
  printf '\033[H\033[2J%s\n' "$frame"
  [ "$status" -ne 0 ] || exit 0
  printf '\n(This list ticks itself off as each step completes. Ctrl-C closes it.)\n'
  sleep "$INTERVAL"
done

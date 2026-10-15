#!/usr/bin/env bash
# fm-opt-in-skills.sh - link the opt-in skills this home switched on into a
# checkout's skill folder, and only those.
#
# WHY. Every skill under .agents/skills/ is listed in every session of every
# home that runs this checkout, so its description costs every session tokens
# and its trigger can fire anywhere. Some skills serve one home's own setup: a
# CLI or subscription the bootstrap never installs, or the owner's own apps,
# accounts and colleagues. A teammate's fresh clone should not load them. So
# those skills live in .agents/opt-in-skills/, which no harness scans, and a
# home switches each one on with a presence flag in its private config/. sync
# then puts a relative symlink .agents/skills/<skill> -> ../opt-in-skills/<skill>
# into the checkout, so a switched-on skill is found at the same path, under the
# same name, as when it was tracked there.
#
# SKILLS AND SWITCHES. docs/configuration.md "Opt-in skills" documents which
# config/ presence flag switches each skill on; skill_table below applies it. A
# switch is a presence flag: any file or link at a skill's path turns it on,
# whatever it holds. Every skill in the table needs a matching
# /.agents/skills/<skill> line in the tracked .gitignore, so a link never makes
# the checkout read as changed.
#
# SAFETY. sync only ever creates, or removes, a symlink whose target is exactly
# ../opt-in-skills/<skill>. Anything else at that path - a real folder, a file,
# or a link pointing elsewhere - is left as it is and named on stderr. A
# checkout with no .agents/opt-in-skills/ folder (any project other than
# Firstmate, or a Firstmate copy older than this split) is left alone.
#
# WHEN. A harness lists skills once, when it starts (verified for Claude Code
# 2.1.300: a link made by its own SessionStart hook is not listed in that
# session), so a link has to exist before the session it serves:
#   - bin/fm-primary.sh syncs this home's checkout before it starts the CLI;
#   - bin/fm-update.sh syncs it right after the fast-forward, so an update that
#     moves a skill never leaves the running session without it;
#   - bin/fm-spawn.sh syncs a Firstmate task worktree before its worker starts;
#   - session-start bootstrap syncs this home's checkout on every locked
#     startup, so a switch changed by hand takes effect from the next launch.
#
# Usage:
#   fm-opt-in-skills.sh sync [<checkout>]  link or unlink every opt-in skill in
#                                          <checkout> (default: this script's
#                                          own repository) for this home
# sync prints nothing unless it leaves a path alone, and exits 0 even then, so a
# launch never fails over one skill. It exits 2 on misuse.
#
# Environment overrides, for tests and unusual layouts:
#   FM_ROOT_OVERRIDE, FM_HOME, FM_CONFIG_OVERRIDE
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '/^# Usage:/,/^# launch never fails/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# One line per skill: the skill name, then the config/ flag that switches it
# on. Plain lines rather than an array keep this readable on stock macOS bash.
skill_table() {
  cat <<'EOF'
adhd adhd
adhd-auto-fire adhd
second-opinion-auto-fire second-opinion
daily-todo-freshness daily-todo
macos-computer-use computer-use
EOF
}

note() {
  printf 'fm-opt-in-skills: %s\n' "$*" >&2
}

sync_checkout() {  # <checkout>
  local checkout=$1 skill flag link want current
  [ -d "$checkout/.agents/opt-in-skills" ] || return 0
  [ -d "$checkout/.agents/skills" ] || return 0
  while read -r skill flag; do
    [ -n "$skill" ] || continue
    [ -d "$checkout/.agents/opt-in-skills/$skill" ] || continue
    link="$checkout/.agents/skills/$skill"
    want="../opt-in-skills/$skill"
    current=
    [ ! -L "$link" ] || current=$(readlink "$link")
    if [ -e "$CONFIG/$flag" ] || [ -L "$CONFIG/$flag" ]; then
      if [ "$current" = "$want" ]; then
        continue
      elif [ -e "$link" ] || [ -L "$link" ]; then
        note "$link is not this script's link; left as it is"
      else
        ln -s "$want" "$link" 2>/dev/null || note "could not link $link"
      fi
    elif [ "$current" = "$want" ]; then
      rm -f "$link" 2>/dev/null || note "could not unlink $link"
    fi
  done <<EOF
$(skill_table)
EOF
  return 0
}

case "${1:-}" in
  sync)
    [ "$#" -le 2 ] || usage
    sync_checkout "${2:-$FM_ROOT}"
    ;;
  *) usage ;;
esac
exit 0

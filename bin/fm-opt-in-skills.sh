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
# ADD-ON SKILLS. A home with a private add-on (bin/fm-addon.sh) also gets every
# skill in the add-on's .agents/skills/<skill>/SKILL.md, linked by absolute path
# as .agents/skills/<skill> -> <add-on>/.agents/skills/<skill>. Their names are
# not known to the tracked .gitignore, so sync adds one /.agents/skills/<skill>
# line per linked skill to the repository's own info/exclude, which keeps the
# checkout reading as clean and is never removed. An add-on skill with the name
# of an opt-in skill replaces it, so a skill that moved into the add-on is
# linked once. With no add-on, or once the add-on drops a skill, sync removes
# the add-on links it finds.
#
# SAFETY. sync only ever creates, or removes, a symlink whose target is exactly
# ../opt-in-skills/<skill>, or an absolute <somewhere>/.agents/skills/<skill>
# other than the link's own path, which is the shape of an add-on link wherever
# the add-on sits, inside the home (projects/starship-addon) or beside it.
# Anything else at that path - a real folder, a file, or a link pointing
# elsewhere - is left as it is and named on stderr. A checkout with no .agents/opt-in-skills/ folder (any
# project other than Firstmate, or a Firstmate copy older than this split) is
# left alone.
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
#   fm-opt-in-skills.sh sync [<checkout>]  link or unlink every opt-in and add-on
#                                          skill in <checkout> (default: this
#                                          script's own repository) for this home
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

# addon_skills <add-on root>: the name of every skill the add-on carries.
addon_skills() {
  local entry name
  for entry in "$1"/.agents/skills/*; do
    name=${entry##*/}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    [ -f "$entry/SKILL.md" ] && printf '%s\n' "$name"
  done
}

# is_addon_link <checkout> <skill> <target>: whether a link has an add-on link's
# shape, an absolute path ending in .agents/skills/<skill> other than the link's
# own path.
is_addon_link() {
  case "$3" in
    "$1/.agents/skills/$2") return 1 ;;
    /*/.agents/skills/"$2") return 0 ;;
  esac
  return 1
}

# exclude_skill <checkout> <skill>: keep an add-on link out of git's view.
exclude_skill() {
  local exclude line="/.agents/skills/$2"
  exclude=$(git -C "$1" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  case "$exclude" in
    /*) ;;
    *) exclude="$1/$exclude" ;;
  esac
  grep -qxF "$line" "$exclude" 2>/dev/null && return 0
  { mkdir -p "$(dirname "$exclude")" && printf '%s\n' "$line" >> "$exclude"; } 2>/dev/null \
    || note "could not keep $1/.agents/skills/$2 out of git's view"
}

# unlink_stale_addon_skills <checkout> <add-on root or empty> <add-on skills>:
# remove every add-on link this home's add-on no longer provides, before the
# opt-in links are made, so an opt-in skill an add-on gave back can take its
# name again in the same sync.
unlink_stale_addon_skills() {
  local checkout=$1 root=$2 wanted=$3 skill current entry
  for entry in "$checkout"/.agents/skills/*; do
    [ -L "$entry" ] || continue
    skill=${entry##*/}
    current=$(readlink "$entry")
    is_addon_link "$checkout" "$skill" "$current" || continue
    if [ -n "$root" ] && [ "$current" = "$root/.agents/skills/$skill" ] \
      && printf '%s\n' "$wanted" | grep -qxF "$skill"; then
      continue
    fi
    rm -f "$entry" 2>/dev/null || note "could not unlink $entry"
  done
}

link_addon_skills() {  # <checkout> <add-on root or empty> <add-on skills>
  local checkout=$1 root=$2 wanted=$3 skill link want current
  [ -n "$root" ] || return 0
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    link="$checkout/.agents/skills/$skill"
    want="$root/.agents/skills/$skill"
    current=
    [ ! -L "$link" ] || current=$(readlink "$link")
    if [ "$current" != "$want" ]; then
      if [ -e "$link" ] || [ -L "$link" ]; then
        note "$link is not this script's link; left as it is"
        continue
      fi
      ln -s "$want" "$link" 2>/dev/null || { note "could not link $link"; continue; }
    fi
    exclude_skill "$checkout" "$skill"
  done <<SKILLS
$wanted
SKILLS
}

sync_checkout() {  # <checkout>
  local checkout=$1 skill flag link want current addon_root addon_names
  [ -d "$checkout/.agents/opt-in-skills" ] || return 0
  [ -d "$checkout/.agents/skills" ] || return 0
  addon_root=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-addon.sh" root 2>/dev/null) \
    || addon_root=
  addon_names=
  [ -z "$addon_root" ] || addon_names=$(addon_skills "$addon_root")
  unlink_stale_addon_skills "$checkout" "$addon_root" "$addon_names"
  while read -r skill flag; do
    [ -n "$skill" ] || continue
    [ -d "$checkout/.agents/opt-in-skills/$skill" ] || continue
    link="$checkout/.agents/skills/$skill"
    want="../opt-in-skills/$skill"
    current=
    [ ! -L "$link" ] || current=$(readlink "$link")
    if [ -n "$addon_names" ] && printf '%s\n' "$addon_names" | grep -qxF "$skill"; then
      # The add-on carries this skill now, and its own link replaces this one.
      [ "$current" != "$want" ] || rm -f "$link" 2>/dev/null || note "could not unlink $link"
    elif [ -e "$CONFIG/$flag" ] || [ -L "$CONFIG/$flag" ]; then
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
  link_addon_skills "$checkout" "$addon_root" "$addon_names"
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

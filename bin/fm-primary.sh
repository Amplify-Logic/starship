#!/usr/bin/env bash
# Launch a verified Firstmate primary profile from this tracked Starship root.
#
# Usage:
#   fm-primary.sh <profile>
#   fm-primary.sh --install-shim
#   fm-primary.sh --help
#
# Profiles and exact launch mechanics (this header/help is the single owner):
#   pi            pi --name FIRSTMATE
#                 Pi has no permission system, so no bypass flag exists or is
#                 needed.
#   claude-fable  claude --model claude-fable-5-1 --effort <value> --name FIRSTMATE
#                 --dangerously-skip-permissions
#   claude-opus   claude --model claude-opus-5 --effort <value> --name FIRSTMATE
#                 --dangerously-skip-permissions
#                 Both Claude profiles use the first trimmed line of local
#                 gitignored config/primary-effort when that file exists,
#                 otherwise xhigh.
#                 Accepted tokens: low, medium, high, xhigh, max.
#                 Any other content, including an empty token, refuses.
#   codex         codex --dangerously-bypass-hook-trust
#                 --dangerously-bypass-approvals-and-sandbox
#   astra         codex --model gpt-6-astra
#                 -c model_reasoning_effort="<value>"
#                 --dangerously-bypass-hook-trust
#                 --dangerously-bypass-approvals-and-sandbox
#                 Uses the first trimmed line of local gitignored
#                 config/astra-effort when that file exists, otherwise xhigh.
#                 Accepted tokens: low, medium, high, xhigh. max is refused,
#                 and that refusal is retained pending the separate follow-up
#                 astra-max-effort.
#   opencode      OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}
#                 opencode
#   grok          grok --permission-mode bypassPermissions
#   kimi-k3       kimi --model kimi-code/k3 --yolo
#                 Inside tmux, the launcher adds a detached one-row companion
#                 that renders docs/status-bar.md without replacing Kimi's
#                 native footer or controls.
#   cursor-grok   agent --yolo --model cursor-grok-4.6-high
#                 Cursor has no effort flag; the tier is a model-id suffix.
#                 Grok 4.6 also offers -xhigh, so -high here is a deliberate
#                 cost choice rather than the ceiling it was on Grok 4.5.
#                 Primary lifecycle hooks reuse tracked .claude/settings.json
#                 (Cursor maps SessionStart/PreToolUse/Stop onto its native
#                 events). There is no third-party status-line API, so no
#                 companion status bar is installed.
#
# Aliases: claude -> claude-fable; opus -> claude-opus; kimi -> kimi-k3;
# cursor -> cursor-grok.
# The aliases are primary-launch conveniences only.
# They never change config/crew-harness, config/secondmate-harness, dispatch
# profiles, or fm-spawn's independently verified worker-adapter set.
#
# Every launch dereferences up to 40 absolute or relative symlink hops from the
# invoked command, resolves the repository root from the resulting tracked
# script, changes to that root, refuses another live Firstmate lock holder,
# checks the selected CLI and its tracked primary integrations, installs only
# that profile's guarded status-bar surface, marks only the current terminal
# surface, then execs the CLI so sessions persist normally and the CLI exit
# status is returned with no launcher process left behind.
# Codex-backed profiles (codex and astra) refuse an explicitly logged-out
# Codex CLI, which would otherwise boot the primary to a login screen.
# Codex prints that negative on stderr and exits non-zero, so the gate reads the
# merged stream and still blocks on the message alone, never on the exit status.
# When local config/primary-handoff is present and enabled, a real launch also
# writes state/.primary-active for bin/fm-primary-handoff.sh; disabled or absent
# config leaves that marker unwritten (docs/primary-handoff.md).
#
# Kimi is verified as a PRIMARY here and, separately, as a WORKER via
# fm-spawn --harness kimi (docs/kimi-harness.md, 2026-07-23).
# Two builds are accepted without a warning, and they are deliberately different
# values: KIMI_CERTIFIED_VERSION is the last full primary certification, which is
# what docs/toolchain-manifest.tsv's kimi row transcribes, and
# KIMI_VALIDATED_VERSION is the newer build whose primary hook mechanics were
# re-verified without a full certification. Both are named below, and the launch
# check is set membership rather than one equality: once those two legitimately
# differ, a single exact-match test cannot express "unevidenced" and would always
# report one of the two accepted builds as unevidenced.
# Any other installed version WARNS and launches anyway; it does not block.
# Kimi ships a self-updater, so an exact-equality gate in front of it turned
# every publisher release into an unscheduled outage of the certified primary
# rather than a merely uncertified one - the same reasoning bin/fm-toolchain-lib.sh
# applies fleet-wide. The functional gate that remains is `kimi doctor` against
# the managed home, which fails the launch when the integration is actually
# broken instead of when a version string merely moved.
# The launcher builds a persistent isolated KIMI_CODE_HOME under this Firstmate
# home's data directory.
# It copies the selected source config, links only required authentication and
# user-resource paths, and installs a managed Firstmate plugin there.
# Kimi's ordinary SessionStart hook discards stdout; the plugin's native
# sessionStart.skill is the model-context nudge on startup, resume, and /new.
# Its hooks provide blockable PreToolUse and Stop integration.
# The source Kimi home and its live config are never edited.
#
# Cursor CLI primary support records the empirically certified agent version
# below and in docs/cursor-harness.md; any other build warns and launches.
# The launch check that can still refuse is an explicitly logged-out CLI, which
# would otherwise boot the primary to a login screen.
# Worker adapter behavior is unchanged; this profile certifies PRIMARY only.
# Never launch a cursor WORKER from the primary checkout (that checkout's
# .claude/settings.json Stop wiring is for the primary session).
#
# --install-shim creates ~/.local/bin/firstmate as a symlink to this command.
# It is idempotent only for that exact symlink and refuses every other existing
# file or symlink.
#
# Test seams:
#   FM_PRIMARY_DRY_RUN=1 prints one shell-escaped argv line instead of exec.
#   FM_PRIMARY_VISIBLE_PREFIX=LAB is accepted only inside a named fm-lab-*
#   Herdr session and visibly prefixes the role so a lab can never masquerade
#   as the captain's FIRSTMATE.
set -u

resolve_script_path() {
  local source=$1 dir target hops=0
  while [ -L "$source" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      printf 'fm-primary: refusing to resolve more than 40 symlink hops: %s\n' "$1" >&2
      return 1
    fi
    dir=$(CDPATH='' cd -P -- "$(dirname -- "$source")" && pwd -P) || return 1
    target=$(readlink "$source") || return 1
    case "$target" in
      /*) source=$target ;;
      *) source=$dir/$target ;;
    esac
  done
  printf '%s\n' "$source"
}

SCRIPT_PATH=$(resolve_script_path "${BASH_SOURCE[0]}") || exit 1
SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
FM_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
# The two Kimi builds this repo carries primary evidence for; running either one
# is quiet, anything else warns and still launches. Both are literal constants,
# never parsed from docs/toolchain-manifest.tsv, because the launcher does not
# otherwise read that file. `kimi doctor` against the managed home is the
# functional gate that can still fail a launch.
# Last full primary certification, transcribed by the manifest's kimi row.
KIMI_CERTIFIED_VERSION=0.27.0
# Newest build with primary hook evidence but no full certification
# (docs/kimi-harness.md), so it reads differently from the certified build above
# on purpose rather than as a drift bug.
KIMI_VALIDATED_VERSION=0.31.1
# Cursor's exact-match BLOCK existed only because its Stop turn-end hook was
# unverified on 2026.07.20-8cc9c0b, which made drift there unsafe rather than
# merely uncertified. Stop now fires (docs/cursor-harness.md, re-certified
# 2026-08-13 on the build below), so cursor joins the fleet-wide rule that
# bin/fm-toolchain-lib.sh applies: an unrecognized build warns and still
# launches, instead of turning every publisher release into an unscheduled
# outage of the certified primary.
CURSOR_CERTIFIED_VERSION=2026.08.11-e8db854

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-primary: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  local value=${1:-}
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

print_argv() {
  local arg first=1
  for arg in "$@"; do
    [ "$first" -eq 1 ] || printf ' '
    shell_quote "$arg"
    first=0
  done
  printf '\n'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "profile '$PROFILE' requires '$1' on PATH"
}

require_file() {
  [ -f "$FM_ROOT/$1" ] || die "profile '$PROFILE' is missing tracked primary integration: $1"
}

refuse_active_session() {
  local out
  out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status 2>&1) || die "could not inspect the Firstmate session lock: $out"
  case "$out" in
    *"held by live harness pid"*) die "another Firstmate session is active; refusing to kill, replace, or steal from it ($out)" ;;
  esac
}

install_shim() {
  local dir=${FM_PRIMARY_SHIM_DIR:-$HOME/.local/bin} target="$FM_ROOT/bin/fm-primary.sh" shim
  shim="$dir/firstmate"
  mkdir -p "$dir" || die "could not create shim directory: $dir"
  if [ -L "$shim" ]; then
    [ "$(readlink "$shim" 2>/dev/null)" = "$target" ] || die "refusing to replace a different symlink: $shim"
    printf 'firstmate shim already installed: %s -> %s\n' "$shim" "$target"
    return 0
  fi
  [ ! -e "$shim" ] || die "refusing to replace an existing file: $shim"
  ln -s "$target" "$shim" || die "could not install shim: $shim"
  printf 'installed firstmate shim: %s -> %s\n' "$shim" "$target"
}

validate_visible_prefix() {
  VISIBLE_PREFIX=${FM_PRIMARY_VISIBLE_PREFIX:-}
  [ -n "$VISIBLE_PREFIX" ] || return 0
  [ "$VISIBLE_PREFIX" = LAB ] || die "FM_PRIMARY_VISIBLE_PREFIX accepts only LAB"
  [ "${HERDR_ENV:-}" = 1 ] || die "LAB visibility is accepted only inside Herdr"
  case "${HERDR_SESSION:-}" in
    fm-lab-*) ;;
    *) die "LAB visibility requires a named fm-lab-* Herdr session, never default" ;;
  esac
}

visible_role() {
  if [ -n "${VISIBLE_PREFIX:-}" ]; then
    printf '%s · PRIMARY' "$VISIBLE_PREFIX"
  else
    printf 'FIRSTMATE'
  fi
}

# Resolve Claude primary effort from local config/primary-effort.
# An absent file defaults to xhigh. A present file must have a first line that
# trims to exactly one accepted token; anything else, including an empty token,
# refuses rather than falling back. Call this only for a Claude profile so a bad
# file cannot block other primaries.
resolve_claude_effort() {
  local file value
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-effort"
  if [ ! -f "$file" ]; then
    CLAUDE_EFFORT=xhigh
    return 0
  fi
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    low|medium|high|xhigh|max) CLAUDE_EFFORT=$value ;;
    *) die "invalid effort in $file: '$value' (accepted: low medium high xhigh max)" ;;
  esac
}

# Resolve Astra primary effort from local config/astra-effort.
# An absent file defaults to xhigh. A present file must have a first line that
# trims to exactly one accepted token; anything else, including an empty token,
# refuses rather than falling back. Call this only for the astra profile so a
# bad file cannot block other primaries.
# Accepted tokens are low, medium, high, and xhigh only. max is refused, and that
# refusal is retained pending the separate follow-up astra-max-effort rather than
# widened here.
# This deliberately stays a sibling of resolve_claude_effort rather than a shared
# parameterised helper: the accepted token sets differ on purpose, and folding
# them together would rewrite the reader the live Fable and Opus primaries
# depend on for no real saving. Revisit only if a third caller appears.
resolve_astra_effort() {
  local file value
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/astra-effort"
  if [ ! -f "$file" ]; then
    ASTRA_EFFORT=xhigh
    return 0
  fi
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    low|medium|high|xhigh) ASTRA_EFFORT=$value ;;
    *) die "invalid effort in $file: '$value' (accepted: low medium high xhigh)" ;;
  esac
}

mark_current_surface() {
  local role session pane source title
  role=$(visible_role)
  title="$role · WAITING"
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    require_command herdr
    session=${HERDR_SESSION:-default}
    pane=$HERDR_PANE_ID
    source=firstmate-primary-visible-v1
    HERDR_SESSION="$session" herdr pane report-metadata "$pane" \
      --source "$source" \
      --title "$title" \
      --display-agent "$title" \
      --state-label "working=SUPERVISING" \
      --state-label "blocked=NEEDS YOU" \
      --state-label "idle=WAITING" \
      --state-label "done=WAITING" \
      --token "fm_role=$role" \
      --token "fm_state=WAITING" \
      --session "$session" >/dev/null 2>&1 \
      || die "could not mark the current Herdr pane as $role"
  elif [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux rename-window -t "$TMUX_PANE" "$title" >/dev/null 2>&1 \
      || die "could not mark the current tmux window as $role"
  elif [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    printf '\033]2;%s\007' "$title"
  fi
}

install_primary_status_bar() {
  local command
  [ "$PROFILE" = kimi-k3 ] || return 0
  [ -n "${TMUX_PANE:-}" ] || return 0
  require_command tmux
  command="exec env FM_HOME=$(shell_quote "$FM_HOME") FM_PRIMARY_HARNESS=kimi $(shell_quote "$FM_ROOT/bin/fm-status-bar.sh") --adapter kimi --model kimi-code/k3 --effort -- --follow-pane $(shell_quote "$TMUX_PANE")"
  tmux split-window -d -v -l 1 -t "$TMUX_PANE" -c "$FM_ROOT" "$command" >/dev/null 2>&1 || {
    printf 'fm-primary: Kimi status companion unavailable; continuing with the native TUI\n' >&2
    return 0
  }
}

prepare_kimi_home() {
  local source_home managed plugin skills installed source_installed now item tmp_installed tmp_merged tmp_plugin path
  source_home=${FM_KIMI_SOURCE_HOME:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}
  managed=${FM_KIMI_PRIMARY_HOME:-$DATA/primary/kimi-k3}
  [ "$source_home" != "$managed" ] || die "managed Kimi home must differ from its source home"
  [ -f "$source_home/config.toml" ] || die "Kimi source config is missing: $source_home/config.toml"
  require_command jq
  for path in "$managed" "$managed/plugins" "$managed/plugins/managed" \
    "$managed/plugins/managed/firstmate-primary"; do
    [ ! -L "$path" ] || die "managed Kimi integration path is an unrelated symlink: $path"
  done
  mkdir -p "$managed" "$managed/plugins/managed/firstmate-primary/skills/firstmate-session-start" \
    || die "could not create managed Kimi primary home: $managed"
  chmod 0700 "$managed" 2>/dev/null || true
  plugin="$managed/plugins/managed/firstmate-primary"
  skills="$plugin/skills/firstmate-session-start"
  installed="$managed/plugins/installed.json"
  for path in "$managed/config.toml" "$managed/tui.toml" "$installed" \
    "$plugin/kimi.plugin.json" "$skills/SKILL.md"; do
    [ ! -L "$path" ] || die "managed Kimi integration file is an unrelated symlink: $path"
  done
  cp "$source_home/config.toml" "$managed/config.toml" \
    || die "could not copy Kimi config into the managed primary home"
  [ ! -f "$source_home/tui.toml" ] || cp "$source_home/tui.toml" "$managed/tui.toml" \
    || die "could not copy Kimi TUI preferences into the managed primary home"

  for item in oauth credentials device_id bin skills mcp.json; do
    [ -e "$source_home/$item" ] || [ -L "$source_home/$item" ] || continue
    if [ -L "$managed/$item" ]; then
      [ "$(readlink "$managed/$item" 2>/dev/null)" = "$source_home/$item" ] \
        || die "managed Kimi path is an unrelated symlink: $managed/$item"
    elif [ -e "$managed/$item" ]; then
      case "$item" in
        oauth|credentials|device_id) die "managed Kimi authentication path is not the expected symlink: $managed/$item" ;;
        *) continue ;;
      esac
    else
      ln -s "$source_home/$item" "$managed/$item" \
        || die "could not link Kimi resource into the managed primary home: $item"
    fi
  done

  tmp_plugin=$(mktemp "$plugin/.manifest.XXXXXX") \
    || die "could not stage the managed Kimi plugin manifest"
  jq -n \
    --arg arm "'$FM_ROOT/bin/fm-arm-pretool-check.sh' --claude" \
    --arg cd "'$FM_ROOT/bin/fm-cd-pretool-check.sh' --claude" \
    --arg stop "'$FM_ROOT/bin/fm-turnend-guard.sh'" \
    '{
      name: "firstmate-primary",
      version: "1",
      description: "Firstmate primary lifecycle integration",
      skills: "./skills/",
      sessionStart: {skill: "firstmate-session-start"},
      hooks: [
        {event: "PreToolUse", matcher: "Bash", command: $arm, timeout: 10},
        {event: "PreToolUse", matcher: "Bash", command: $cd, timeout: 10},
        {event: "Stop", command: $stop, timeout: 30}
      ]
    }' > "$tmp_plugin" \
    || { rm -f "$tmp_plugin"; die "could not render the managed Kimi plugin manifest"; }
  mv "$tmp_plugin" "$plugin/kimi.plugin.json" \
    || { rm -f "$tmp_plugin"; die "could not publish the managed Kimi plugin manifest"; }
  cat > "$skills/SKILL.md" <<'EOF'
---
name: firstmate-session-start
description: Required Firstmate primary session initialization.
---
Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.
EOF
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp_installed=$(mktemp "$managed/plugins/.installed.XXXXXX") \
    || die "could not stage the managed Kimi plugin registry"
  jq -n --arg root "$plugin" --arg installed "$now" --arg source "$FM_ROOT" '
    {
      version: 1,
      plugins: [{
        id: "firstmate-primary",
        root: $root,
        source: "local-path",
        enabled: true,
        installedAt: $installed,
        originalSource: $source
      }]
    }
  ' > "$tmp_installed" \
    || { rm -f "$tmp_installed"; die "could not render the managed Kimi plugin registry"; }
  source_installed="$source_home/plugins/installed.json"
  if [ -f "$source_installed" ]; then
    tmp_merged=$(mktemp "$managed/plugins/.installed.XXXXXX") \
      || { rm -f "$tmp_installed"; die "could not stage the merged Kimi plugin registry"; }
    jq --slurpfile managed "$tmp_installed" '
      .version = (.version // 1)
      | .plugins = (((.plugins // []) | map(select(.id != "firstmate-primary"))) + $managed[0].plugins)
    ' "$source_installed" > "$tmp_merged" \
      || { rm -f "$tmp_installed" "$tmp_merged"; die "could not merge the source and managed Kimi plugin registries"; }
    rm -f "$tmp_installed"
    mv "$tmp_merged" "$installed" \
      || { rm -f "$tmp_merged"; die "could not publish the managed Kimi plugin registry"; }
  else
    mv "$tmp_installed" "$installed" \
      || { rm -f "$tmp_installed"; die "could not publish the managed Kimi plugin registry"; }
  fi
  chmod 0600 "$managed/config.toml" "$installed" 2>/dev/null || true
  KIMI_PRIMARY_HOME=$managed
}

verify_integrations() {
  case "$PROFILE" in
    pi)
      require_file .pi/extensions/fm-primary-turnend-guard.ts
      require_file .pi/extensions/fm-primary-pi-watch.ts
      require_file .pi/extensions/fm-primary-status-bar.ts
      require_file bin/fm-status-bar.sh
      ;;
    claude-fable|claude-opus)
      require_file .claude/settings.json
      require_file bin/fm-status-bar.sh
      require_command jq
      jq -e '
        .hooks.SessionStart
        and .hooks.PreToolUse
        and .hooks.Stop
        and (.statusLine.command | contains("bin/fm-status-bar.sh --adapter claude"))
      ' "$FM_ROOT/.claude/settings.json" >/dev/null 2>&1 \
        || die "Claude primary integrations are incomplete"
      ;;
    codex|astra)
      require_file .codex/hooks.json
      require_command jq
      jq -e '.hooks.SessionStart and .hooks.PreToolUse and .hooks.Stop' "$FM_ROOT/.codex/hooks.json" >/dev/null 2>&1 \
        || die "Codex primary hooks are incomplete"
      ;;
    opencode)
      require_file .opencode/plugins/fm-primary-sessionstart-nudge.js
      require_file .opencode/plugins/fm-primary-pretool-check.js
      require_file .opencode/plugins/fm-primary-cd-check.js
      require_file .opencode/plugins/fm-primary-turnend-guard.js
      require_file .opencode/plugins/fm-primary-watch-arm.js
      ;;
    grok)
      require_file .grok/hooks/fm-primary-sessionstart-nudge.json
      require_file .grok/hooks/fm-primary-pretool-check.json
      require_file .grok/hooks/fm-primary-cd-check.json
      require_file .grok/hooks/fm-primary-turnend-guard.json
      ;;
    kimi-k3)
      require_file bin/fm-status-bar.sh
      prepare_kimi_home
      ;;
    cursor-grok)
      require_file .claude/settings.json
      require_file docs/supervision-protocols/cursor.md
      require_command jq
      jq -e '
        .hooks.SessionStart
        and .hooks.PreToolUse
        and .hooks.Stop
      ' "$FM_ROOT/.claude/settings.json" >/dev/null 2>&1 \
        || die "Cursor primary integrations are incomplete (need SessionStart, PreToolUse, and Stop in .claude/settings.json)"
      ;;
  esac
}

PROFILE=${1:-}
case "$PROFILE" in
  -h|--help|'') usage; exit 0 ;;
  --install-shim)
    [ "$#" -eq 1 ] || die "--install-shim accepts no profile or extra arguments"
    install_shim
    exit 0
    ;;
esac
[ "$#" -eq 1 ] || die "profiles accept no extra arguments; use the launched CLI's normal resume UI"
case "$PROFILE" in
  claude) PROFILE=claude-fable ;;
  opus) PROFILE=claude-opus ;;
  kimi) PROFILE=kimi-k3 ;;
  cursor) PROFILE=cursor-grok ;;
esac
case "$PROFILE" in
  pi|claude-fable|claude-opus|codex|astra|opencode|grok|kimi-k3|cursor-grok) ;;
  *) die "unknown or unverified primary profile '$PROFILE' (verified: pi claude-fable claude-opus codex astra opencode grok kimi-k3 cursor-grok)" ;;
esac

validate_visible_prefix
mkdir -p "$STATE" "$DATA" || die "could not create Firstmate private state directories"
refuse_active_session

case "$PROFILE" in
  pi) CLI=pi ;;
  claude-fable) CLI=claude; CLAUDE_MODEL=claude-fable-5-1 ;;
  claude-opus) CLI=claude; CLAUDE_MODEL=claude-opus-5 ;;
  codex) CLI=codex ;;
  astra) CLI=codex ;;
  opencode) CLI=opencode ;;
  grok) CLI=grok ;;
  kimi-k3) CLI=${FM_KIMI_BIN:-kimi} ;;
  cursor-grok) CLI=${FM_CURSOR_BIN:-agent} ;;
esac
require_command "$CLI"
verify_integrations

if [ "$PROFILE" = kimi-k3 ]; then
  version=$("$CLI" --version 2>/dev/null | head -1)
  case $version in
    "$KIMI_CERTIFIED_VERSION")
      printf 'fm-primary: Kimi %s is the certified primary build (docs/kimi-harness.md)\n' \
        "$KIMI_CERTIFIED_VERSION" >&2 ;;
    "$KIMI_VALIDATED_VERSION")
      printf 'fm-primary: Kimi %s is the newest-evidence build: hooks re-verified 2026-08-04, not a full certification (docs/kimi-harness.md)\n' \
        "$KIMI_VALIDATED_VERSION" >&2 ;;
    *)
      printf 'fm-primary: Kimi primary carries evidence for %s (certified) and %s (newest evidence); found %s (docs/kimi-harness.md) - launching anyway\n' \
        "$KIMI_CERTIFIED_VERSION" "$KIMI_VALIDATED_VERSION" "${version:-unknown}" >&2 ;;
  esac
  KIMI_CODE_HOME="$KIMI_PRIMARY_HOME" "$CLI" doctor >/dev/null 2>&1 \
    || die "managed Kimi primary integration failed 'kimi doctor'"
fi

if [ "$PROFILE" = cursor-grok ]; then
  version=$("$CLI" --version 2>/dev/null | head -1 | tr -d '\r')
  if [ "$version" != "$CURSOR_CERTIFIED_VERSION" ]; then
    printf 'fm-primary: Cursor primary is certified on %s; found %s (docs/cursor-harness.md) - launching anyway\n' \
      "$CURSOR_CERTIFIED_VERSION" "${version:-unknown}" >&2
  fi
  # Only an EXPLICIT negative blocks: "Not logged in" contains "logged in", and
  # an unreadable status is not evidence of a logged-out CLI.
  cursor_status=$("$CLI" status 2>/dev/null | head -5)
  case "$cursor_status" in
    *'Not logged in'*|*'not logged in'*)
      die "Cursor CLI is not logged in ('$CLI status'); the primary would boot to its login screen instead of a session" ;;
  esac
fi

cd "$FM_ROOT" || die "could not enter tracked Starship root: $FM_ROOT"
role=$(visible_role)

case "$PROFILE" in
  pi)
    argv=(pi --name "$role")
    ;;
  claude-fable|claude-opus)
    resolve_claude_effort
    argv=(claude --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --name "$role" --dangerously-skip-permissions)
    printf 'fm-primary: launching model %s at effort %s\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT" >&2
    ;;
  codex)
    argv=(codex --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox)
    ;;
  astra)
    resolve_astra_effort
    argv=(codex --model gpt-6-astra -c "model_reasoning_effort=\"$ASTRA_EFFORT\"" --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox)
    printf 'fm-primary: launching model gpt-6-astra at effort %s\n' "$ASTRA_EFFORT" >&2
    ;;
  opencode)
    argv=(opencode)
    ;;
  grok)
    argv=(grok --permission-mode bypassPermissions)
    ;;
  kimi-k3)
    argv=("$CLI" --model kimi-code/k3 --yolo)
    ;;
  cursor-grok)
    argv=("$CLI" --yolo --model cursor-grok-4.6-high)
    ;;
esac

if [ "${FM_PRIMARY_DRY_RUN:-0}" = 1 ]; then
  printf 'root=%s\n' "$PWD"
  printf 'profile=%s\n' "$PROFILE"
  printf 'role=%s\n' "$role"
  [ "$PROFILE" != kimi-k3 ] || printf 'KIMI_CODE_HOME=%s\n' "$KIMI_PRIMARY_HOME"
  print_argv "${argv[@]}"
  exit 0
fi

if [ "$PROFILE" = codex ] || [ "$PROFILE" = astra ]; then
  # Only an EXPLICIT negative blocks: "Not logged in" contains "logged in", and
  # an unreadable status is not evidence of a logged-out CLI.
  # Dry-run exits above so a missing credential cannot hide argv.
  # Codex reports the logged-out state on stderr and exits non-zero, so the
  # merged stream is the only place the negative can be read; the exit status
  # stays deliberately unread.
  codex_status=$("$CLI" login status 2>&1)
  case "$codex_status" in
    *'Not logged in'*|*'not logged in'*)
      die "Codex CLI is not logged in ('$CLI login status'); the primary would boot to its login screen instead of a session" ;;
  esac
fi

mark_current_surface
export FM_PRIMARY_HARNESS=${PROFILE%%-*}
export FM_PRIMARY_ROLE=$role
# When optional primary handoff is enabled, record the live profile so the
# supervisor can rotate without guessing from process args (docs/primary-handoff.md).
# Absent or disabled config/primary-handoff leaves this path inert.
if [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-handoff" ] \
  && command -v jq >/dev/null 2>&1 \
  && jq -e '.enabled == true' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-handoff" >/dev/null 2>&1; then
  {
    printf 'schema=fm-primary-active.v1\n'
    printf 'profile=%s\n' "$PROFILE"
    printf 'pid=\n'
    printf 'started_at=%s\n' "$(date +%s)"
    printf 'updated_at=%s\n' "$(date +%s)"
  } > "$STATE/.primary-active"
fi
install_primary_status_bar
case "$PROFILE" in
  opencode)
    export OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}'
    exec "${argv[@]}"
    ;;
  kimi-k3)
    export KIMI_CODE_HOME=$KIMI_PRIMARY_HOME
    export FM_PRIMARY_HARNESS=kimi
    exec "${argv[@]}"
    ;;
  cursor-grok)
    export FM_PRIMARY_HARNESS=cursor
    exec "${argv[@]}"
    ;;
  astra)
    export FM_PRIMARY_HARNESS=codex
    exec "${argv[@]}"
    ;;
  *) exec "${argv[@]}" ;;
esac

#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--outcome <text>] [--task-type <slug>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok|cursor|kimi)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   Before creating any task endpoint, every verified adapter resolves the first
#   executable in its launch template through the backend's shared executable
#   resolver and requires its cheap --version probe to succeed. The probe runs
#   with stdin closed and is bounded by a portable timeout (default 10 seconds,
#   override with FM_SPAWN_PROBE_TIMEOUT_SECS=<positive integer seconds>); a
#   probe that times out refuses the spawn loudly, naming the binary and knob.
#   The treehouse-get worktree settle loop is hard-bounded (default 60 polls,
#   1s sleep); FM_SPAWN_SETTLE_MAX_POLLS and FM_SPAWN_SETTLE_SLEEP shorten that
#   bound for tests without risking an unbounded wait.
#   For cursor, the effort axis is folded into the launch model id (see
#   cursor_model_with_effort) and that launch id is what meta model= records.
#   When agent --list-models (or FM_CURSOR_MODEL_CATALOG) is available, an
#   unknown cursor model id refuses the spawn before any endpoint is created,
#   because a missing/invalid --model leaves the worker on the account default
#   in ~/.cursor/cli-config.json while meta would still claim the requested id
#   (bin/fm-cursor-model-lib.sh; docs/cursor-harness.md). Herdr presentation
#   separately prefers the live pane footer model over meta when readable.
#   Raw launch commands are exempt because arbitrary shell syntax can depend on
#   pane-only aliases, functions, or setup that cannot be resolved safely without
#   executing the unverified command; the escape hatch therefore stays explicit.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh).
#   --outcome records an explicit concise human task outcome for supported
#   presentation surfaces; otherwise fm-task-outcome.sh resolves the structured
#   backlog title and then its documented safe fallback.
#   --task-type records an optional capability-learning slug in meta task_type=
#   (no '|' or newlines); teardown logs it, and absent it falls back to kind.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend/--outcome/--task-type applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-cursor-model-lib.sh
. "$SCRIPT_DIR/fm-cursor-model-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
OUTCOME=
TASK_TYPE=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
OUTCOME_SET=0
TASK_TYPE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      outcome) OUTCOME=$a; OUTCOME_SET=1 ;;
      task-type) TASK_TYPE=$a; TASK_TYPE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --outcome) want_value=outcome ;;
    --outcome=*) OUTCOME=${a#--outcome=}; OUTCOME_SET=1 ;;
    --task-type) want_value=task-type ;;
    --task-type=*) TASK_TYPE=${a#--task-type=}; TASK_TYPE_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$OUTCOME_SET" -eq 0 ] || [ -n "$OUTCOME" ] || { echo "error: --outcome requires a non-empty value" >&2; exit 1; }
[ "$TASK_TYPE_SET" -eq 0 ] || [ -n "$TASK_TYPE" ] || { echo "error: --task-type requires a non-empty value" >&2; exit 1; }
if [ -n "$TASK_TYPE" ]; then
  case "$TASK_TYPE" in
    *'|'*) echo "error: --task-type must not contain '|'" >&2; exit 1 ;;
  esac
  case "$TASK_TYPE" in
    *$'\n'*|*$'\r'*) echo "error: --task-type must not contain newlines" >&2; exit 1 ;;
  esac
fi
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

orca_spawn_abort_cleanup() {
  local status=$?
  [ "$ORCA_ABORT_CLEANUP" = 1 ] || return "$status"
  ORCA_ABORT_CLEANUP=0
  if [ -n "${ORCA_TERMINAL:-}" ]; then
    fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
  fi
  if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
    if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
      mkdir -p "$STATE" 2>/dev/null || true
      if [ -d "$STATE" ]; then
        {
          echo "window=$W"
          echo "worktree=${WT:-}"
          echo "project=$PROJ_ABS"
          echo "harness=$HARNESS"
          echo "kind=$KIND"
          echo "mode=${MODE:-no-mistakes}"
          echo "yolo=${YOLO:-off}"
          echo "tasktmp=${TASK_TMP:-}"
          echo "model=${MODEL:-default}"
          echo "effort=${EFFORT:-default}"
          echo "backend=orca"
          echo "orca_worktree_id=$ORCA_WORKTREE_ID"
          [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
        } > "$STATE/$ID.meta" 2>/dev/null || true
      fi
    fi
  fi
  return "$status"
}
trap 'orca_spawn_abort_cleanup || :; fm_cursor_catalog_cache_cleanup' EXIT

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  [ -z "$OUTCOME" ] || shared_args+=(--outcome "$OUTCOME")
  [ -z "$TASK_TYPE" ] || shared_args+=(--task-type "$TASK_TYPE")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok|cursor|kimi)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    # cursor (Cursor CLI, the `agent` binary): a positional prompt starts the
    # supervised interactive session. --yolo (alias of --force, "Run Everything")
    # auto-approves every tool execution, verified to run fully unattended; it is
    # the targeted equivalent of claude's --dangerously-skip-permissions.
    # --workspace pins the workspace to the task worktree so the agent can never
    # resolve a different root, and NO -w/--worktree flag is passed: worktree
    # allocation is strictly opt-in on this CLI, so firstmate's own isolated copy
    # stays the only one (verified 2026-07-19: ~/.cursor/worktrees gained no entry
    # across every launch). cursor's turn-end signal does NOT ride the launch
    # command - it is a `stop` hook in <worktree>/.cursor/hooks.json written
    # below, so the template is identical for ship/scout/secondmate.
    # Effort is folded into the MODEL ID by cursor_model_with_effort (this CLI has
    # no effort flag), so there is no __EFFORTFLAG__ here by design.
    cursor) printf '%s' 'agent --yolo --workspace __WORKTREE__ __MODELFLAG__"$(cat __BRIEF__)"' ;;
    # kimi (Kimi Code CLI): --yolo auto-approves tool execution (TUI footer token
    # `yolo`, verified 2026-07-21/2026-07-23 on 0.27.0). Cannot combine --prompt
    # with --yolo, and there is no positional interactive brief, so the brief is
    # delivered after the TUI settles (post-launch send below). Turn-end is a
    # Stop hook in a per-task isolated KIMI_CODE_HOME (project hooks do not load;
    # verified 2026-07-23). Default model is kimi-code/k3 via __MODELFLAG__.
    kimi) printf '%s' 'KIMI_CODE_HOME=__KIMIHOME__ kimi --yolo __MODELFLAG__' ;;
    *) return 1 ;;
  esac
}

launch_binary_from_command() {  # <launch-command>
  local launch_command=$1 word
  local -a words
  read -r -a words <<< "$launch_command"
  for word in "${words[@]}"; do
    case "$word" in
      [A-Za-z_]*=*) continue ;;
      *) printf '%s\n' "$word"; return 0 ;;
    esac
  done
  return 1
}

launch_binary_install_hint() {  # <binary>
  case "$1" in
    claude) printf '%s' 'npm install -g @anthropic-ai/claude-code' ;;
    codex) printf '%s' 'npm install -g @openai/codex' ;;
    opencode) printf '%s' 'npm install -g opencode-ai' ;;
    pi) printf '%s' 'npm install -g @mariozechner/pi-coding-agent' ;;
    grok) printf '%s' 'curl -fsSL https://x.ai/cli/install.sh | bash' ;;
    agent) printf '%s' 'curl https://cursor.com/install -fsS | bash' ;;
    kimi) printf '%s' 'curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash' ;;
    *) return 1 ;;
  esac
}

run_version_probe() {  # <resolved-binary> <timeout-secs>
  local resolved=$1 timeout_secs=$2 pid waited=0 limit
  set -m
  "$resolved" --version </dev/null >/dev/null 2>&1 &
  pid=$!
  set +m
  limit=$((timeout_secs * 10))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -- -"$pid" 2>/dev/null
      local grace=0
      while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 20 ]; do
        sleep 0.1
        grace=$((grace + 1))
      done
      kill -9 -- -"$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
}

preflight_verified_launch_binary() {  # <backend> <harness> <launch-command>
  local backend=$1 harness=$2 launch_command=$3 binary resolved hint probe_rc
  local timeout_secs=${FM_SPAWN_PROBE_TIMEOUT_SECS:-10}
  case "$timeout_secs" in
    ''|0|*[!0-9]*)
      echo "error: FM_SPAWN_PROBE_TIMEOUT_SECS must be a positive integer number of seconds (got '${FM_SPAWN_PROBE_TIMEOUT_SECS:-}'); refusing before creating a task endpoint" >&2
      return 1
      ;;
  esac
  binary=$(launch_binary_from_command "$launch_command") || {
    echo "error: harness '$harness' launch template has no executable; refusing before creating a task endpoint" >&2
    return 1
  }
  hint=$(launch_binary_install_hint "$binary") || {
    echo "error: harness '$harness' launch binary '$binary' has no install hint; refusing before creating a task endpoint" >&2
    return 1
  }
  if ! resolved=$(fm_backend_resolve_executable "$backend" "$binary" 2>/dev/null); then
    echo "error: harness '$harness' launch binary '$binary' was not found (install: $hint); refusing before creating a task endpoint" >&2
    return 1
  fi
  run_version_probe "$resolved" "$timeout_secs"
  probe_rc=$?
  if [ "$probe_rc" -eq 124 ]; then
    echo "error: harness '$harness' launch binary '$binary' --version probe timed out after ${timeout_secs}s (raise with FM_SPAWN_PROBE_TIMEOUT_SECS); refusing before creating a task endpoint" >&2
    return 1
  fi
  if [ "$probe_rc" -ne 0 ]; then
    echo "error: harness '$harness' launch binary '$binary' failed its --version probe (reinstall: $hint); refusing before creating a task endpoint" >&2
    return 1
  fi
}

RAW_LAUNCH=0
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    RAW_LAUNCH=1
    RAW_BINARY=$(launch_binary_from_command "$LAUNCH") || {
      echo "error: raw launch command has no executable" >&2
      exit 1
    }
    HARNESS=$(basename "$RAW_BINARY")
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac
if [ "$RAW_LAUNCH" -eq 0 ]; then
  preflight_verified_launch_binary "$BACKEND" "$HARNESS" "$LAUNCH" || exit 1
fi

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# cursor_model_with_effort: cursor is the one verified adapter with NO effort
# flag - the Cursor CLI encodes reasoning effort as a SUFFIX on the model id
# (cursor-grok-4.5-low|-medium|-high), verified 2026-07-19 on Cursor CLI
# 2026.07.16-899851b. So the effort axis is resolved into the model id here
# rather than emitted as a flag.
# An explicit model that ALREADY carries a tier suffix wins and effort is left
# out of the launch (still recorded in meta), so a captain naming an exact model
# id is never silently retiered. xhigh and max have no cursor equivalent, so they
# cap at high per the harness-adapters effort-fallback rule rather than being
# dropped silently.
cursor_model_with_effort() {  # <model> <effort>
  local model=$1 effort=$2 tier
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$model" in
    *-low|*-medium|*-high|*-low-fast|*-medium-fast|*-high-fast|*'['*)
      printf '%s' "$model"; return 0 ;;
  esac
  case "$effort" in
    low|medium|high) tier=$effort ;;
    xhigh|max) tier=high ;;
    *) printf '%s' "$model"; return 0 ;;
  esac
  printf '%s-%s' "$model" "$tier"
}

# Resolve the cursor launch model id early (effort folded into the id) so meta
# and the catalog preflight both see the same token that --model will receive.
# Acceptance is exact catalog membership: the Cursor CLI itself refuses unknown
# ids ("Cannot use this model: ..."), so a bare base id (e.g. cursor-grok-4.5)
# is valid only when `agent --list-models` lists it - some models are listed
# bare (gpt-5.2, composer-2.5), others only tier-suffixed. No prefix/parent
# acceptance, so we never record a meta model the CLI would reject.
LAUNCH_MODEL=$MODEL
# kimi worker default model matches the verified primary pin (kimi-code/k3).
if [ "$HARNESS" = kimi ] && { [ -z "$LAUNCH_MODEL" ] || [ "$LAUNCH_MODEL" = default ]; }; then
  LAUNCH_MODEL=kimi-code/k3
fi
if [ "$HARNESS" = cursor ]; then
  LAUNCH_MODEL=$(cursor_model_with_effort "$MODEL" "$EFFORT")
  if [ -n "$LAUNCH_MODEL" ] && [ "$LAUNCH_MODEL" != default ]; then
    set +e
    fm_cursor_catalog_has_model "$LAUNCH_MODEL"
    cursor_model_rc=$?
    set -e
    case "$cursor_model_rc" in
      0) ;;
      1)
        echo "error: cursor model '$LAUNCH_MODEL' is not in \`agent --list-models\` (or FM_CURSOR_MODEL_CATALOG); refusing spawn so meta cannot claim a model the worker will not run. The account default in ~/.cursor/cli-config.json would be used instead." >&2
        exit 1
        ;;
      *) ;; # catalog unavailable: soft-skip (stub agent in tests, offline)
    esac
  fi
fi

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok|cursor|kimi)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into this secondmate home (fm-config-inherit-lib.sh).
  propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
    || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a Herdr worker spawn goes through the version-gated project-workspace,
# tab-per-task sequence in bin/backends/herdr.sh.
# Workspace identity uses physical home/project metadata tokens while mutable
# labels carry human presentation.
# Secondmate primary panes retain the legacy home workspace shape.
# Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

W="fm-$ID"
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_PROJECT_KEY=
    HERDR_PROJECT_NAME=
    HERDR_PRESENTATION=0
    if fm_backend_herdr_presentation_capable; then
      HERDR_PRESENTATION=1
    fi
    TASK_OUTCOME=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-task-outcome.sh" "$ID" "$OUTCOME")
    HERDR_TAB_TITLE="WORKER · $TASK_OUTCOME · 🟡 WAITING"
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
      HERDR_TAB_TITLE=$W
    elif [ "$HERDR_PRESENTATION" -eq 1 ]; then
      HERDR_PROJECT_KEY=$PROJ_ABS_REAL
      HERDR_PROJECT_NAME=$("$FM_ROOT/bin/fm-project-display-name.sh" "$(basename "$PROJ_ABS_REAL")")
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" \
        FM_HERDR_PROJECT_KEY="$HERDR_PROJECT_KEY" \
        FM_HERDR_PROJECT_LABEL="$HERDR_PROJECT_NAME" \
        fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
    else
      HERDR_TAB_TITLE=$W
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
    fi
    # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
    # (the second field empty when this call ADOPTED a pre-existing workspace
    # rather than creating a fresh one). Split on the guaranteed single tab
    # character; the seeded tab id is threaded through to create_task
    # untouched, which is the only function permitted to prune it (never
    # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TOKEN_TASK_ID=$ID
    [ "$HERDR_PRESENTATION" -eq 1 ] || HERDR_TOKEN_TASK_ID=
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$HERDR_TAB_TITLE" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID" "$HERDR_TOKEN_TASK_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
    zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_literal "$1" "$2" ;;
    cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  esac
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # Compare against PROJ_ABS_REAL (physical), not PROJ_ABS: a symlinked project
  # prefix would otherwise make the pane's OS-level cwd read differ from
  # PROJ_ABS on the very first poll, before the pane has actually moved.
  #
  # A single read that already differs from PROJ_ABS_REAL is not proof the pane
  # settled there: on some tmux/WSL setups a brand-new window's pane_current_path
  # transiently reports an unrelated stale path (seen live as another real git
  # checkout entirely) before the shell catches up with treehouse get's cd. That
  # stale path still passes the PROJ_ABS_REAL comparison and validate_spawn_worktree
  # below (it resolves to a real, distinct worktree top-level too), so accepting it
  # on one read alone silently records the wrong worktree= in state/<id>.meta. Require
  # two consecutive reads to agree on the same non-project path before accepting it;
  # a mismatch just becomes the new candidate rather than resetting the wait, so a
  # pane that is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  #
  # Bound is hard: at most FM_SPAWN_SETTLE_MAX_POLLS polls (default 60) with
  # FM_SPAWN_SETTLE_SLEEP seconds between them (default 1; 0 allowed for tests).
  # Stability never reached still fails cleanly here - never hangs.
  settle_max_polls=${FM_SPAWN_SETTLE_MAX_POLLS:-60}
  settle_sleep=${FM_SPAWN_SETTLE_SLEEP:-1}
  case "$settle_max_polls" in
    ''|0|*[!0-9]*)
      echo "error: FM_SPAWN_SETTLE_MAX_POLLS must be a positive integer (got '${FM_SPAWN_SETTLE_MAX_POLLS:-}'); refusing before waiting on treehouse get" >&2
      exit 1
      ;;
  esac
  case "$settle_sleep" in
    ''|*[!0-9]*)
      echo "error: FM_SPAWN_SETTLE_SLEEP must be a non-negative integer number of seconds (got '${FM_SPAWN_SETTLE_SLEEP:-}'); refusing before waiting on treehouse get" >&2
      exit 1
      ;;
  esac
  candidate=""
  for _ in $(seq 1 "$settle_max_polls"); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ]; then
      p_real=$(real_path_or_raw "$p")
      if [ "$p_real" != "$PROJ_ABS_REAL" ]; then
        if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
          WT="$p"
          break
        fi
        candidate="$p_real"
      else
        candidate=""
      fi
    else
      candidate=""
    fi
    sleep "$settle_sleep"
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within ${settle_max_polls} poll(s); inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    cursor*)
      # cursor fires a `stop` hook at every turn boundary (verified live
      # 2026-07-19 on Cursor CLI 2026.07.16-899851b: two turns produced exactly
      # two hook invocations). Unlike grok, PROJECT hooks need no separate
      # hook-trust grant beyond the workspace trust the spawn already clears, so
      # the per-task hook stays inside the worktree - the least invasive accurate
      # mechanism, with no global file and no write into the captain's ~/.cursor.
      #
      # WARNING (verified from the shipped bundle): cursor ALSO ingests
      # claude-format hooks from .claude/settings.json and .claude/settings.local.json,
      # mapping claude's `Stop` onto its own `stop`. The worktree is disposable and
      # firstmate only writes .claude/settings.local.json for a claude spawn, so the
      # two never collide per task - but never launch cursor from the firstmate
      # PRIMARY checkout, whose .claude/settings.json Stop hook would then run
      # firstmate's own turn-end guard inside a worker session.
      mkdir -p "$WT/.cursor"
      cat > "$WT/.cursor/hooks.json" <<EOF
{"version":1,"hooks":{"stop":[{"type":"command","command":"touch '$TURNEND'"}]}}
EOF
      exclude_path '.cursor/hooks.json'
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# kimi isolated worker home (always): auth + config for KIMI_CODE_HOME. Stop
# turn-end hook only for non-secondmate (same skip as other harness turn-end hooks).
if [ "$HARNESS" = kimi ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  # kimi fires a native Stop hook at every turn boundary (verified 2026-07-23
  # on Kimi Code 0.27.0: UserPromptSubmit then Stop with stop_hook_active=false
  # after a completed TUI turn). Project-local config/plugin hooks under the
  # worktree do NOT load (same lab: marker stayed empty). Hooks live in
  # KIMI_CODE_HOME/config.toml, so fm-spawn builds a per-task isolated home
  # under state/ (never edits the captain's ~/.kimi-code), links auth from the
  # source home, and installs one Stop command that touches TURNEND.
  KIMI_WORKER_HOME="$STATE_REAL/$ID.kimi-home"
  KIMI_SOURCE_HOME=${FM_KIMI_SOURCE_HOME:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}
  mkdir -p "$KIMI_WORKER_HOME/hooks"
  if [ -f "$KIMI_SOURCE_HOME/config.toml" ]; then
    # Strip source [[hooks]] blocks so captain/herdr hooks are not duplicated
    # into the worker home; keep providers/models/auth settings.
    awk '
      BEGIN { skip=0 }
      /^\[\[hooks\]\]/ { skip=1; next }
      skip==1 {
        if ($0 ~ /^\[/ && $0 !~ /^\[\[hooks\]\]/) { skip=0; print; }
        next
      }
      { print }
    ' "$KIMI_SOURCE_HOME/config.toml" > "$KIMI_WORKER_HOME/config.toml"
  else
    : > "$KIMI_WORKER_HOME/config.toml"
  fi
  for _kimi_link in credentials oauth device_id; do
    if [ -e "$KIMI_SOURCE_HOME/$_kimi_link" ] && [ ! -e "$KIMI_WORKER_HOME/$_kimi_link" ]; then
      ln -s "$KIMI_SOURCE_HOME/$_kimi_link" "$KIMI_WORKER_HOME/$_kimi_link"
    fi
  done
  if [ "$KIND" != secondmate ]; then
    cat > "$KIMI_WORKER_HOME/hooks/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
touch $(shell_quote "$TURNEND") 2>/dev/null || true
exit 0
EOF
    chmod +x "$KIMI_WORKER_HOME/hooks/fm-turn-end.sh"
    {
      printf '\n[[hooks]]\n'
      printf 'event = "Stop"\n'
      printf 'command = "bash %s"\n' "$(shell_quote "$KIMI_WORKER_HOME/hooks/fm-turn-end.sh")"
      printf 'timeout = 10\n'
    } >> "$KIMI_WORKER_HOME/config.toml"
  fi
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  # cursor records the folded launch model id (what --model actually receives).
  # When that differs from the intake model token, model_requested= keeps the
  # pre-fold value for audit.
  if [ "$HARNESS" = cursor ] && [ -n "$LAUNCH_MODEL" ]; then
    echo "model=$LAUNCH_MODEL"
    if [ -n "$MODEL" ] && [ "$MODEL" != default ] && [ "$MODEL" != "$LAUNCH_MODEL" ]; then
      echo "model_requested=$MODEL"
    fi
  elif [ "$HARNESS" = kimi ] && [ -n "$LAUNCH_MODEL" ]; then
    echo "model=$LAUNCH_MODEL"
  else
    echo "model=${MODEL:-default}"
  fi
  echo "effort=${EFFORT:-default}"
  [ -z "$TASK_TYPE" ] || echo "task_type=$TASK_TYPE"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
    if [ "$KIND" != secondmate ] && [ "$HERDR_PRESENTATION" -eq 1 ]; then
      echo "herdr_workspace_managed=1"
      echo "herdr_project_key=$HERDR_PROJECT_KEY"
      echo "herdr_project_name=$HERDR_PROJECT_NAME"
      echo "outcome=$TASK_OUTCOME"
    fi
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0
if [ "$BACKEND" = herdr ] && [ "${HERDR_PRESENTATION:-0}" -eq 1 ]; then
  "$FM_ROOT/bin/fm-visible-status.sh" "$ID" >/dev/null 2>&1 || true
fi

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
# LAUNCH_MODEL was resolved earlier (cursor effort fold + catalog preflight).
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$LAUNCH_MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__WORKTREE__/$(shell_quote "$WT")}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
if [ "$HARNESS" = kimi ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  sq_kimihome=$(shell_quote "$STATE_REAL/$ID.kimi-home")
  LAUNCH=${LAUNCH//__KIMIHOME__/$sq_kimihome}
fi
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
spawn_send_key "$T" Enter
# kimi: no positional interactive brief and --prompt cannot combine with --yolo
# (verified 2026-07-21/2026-07-23). Deliver the brief after the TUI settles.
if [ "$HARNESS" = kimi ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  sleep "${FM_KIMI_BRIEF_SETTLE_SECS:-2}"
  spawn_send_literal "$T" "$(cat "$BRIEF")"
  sleep 0.5
  spawn_send_key "$T" Enter
fi

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"

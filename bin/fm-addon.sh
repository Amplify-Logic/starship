#!/usr/bin/env bash
# fm-addon.sh - this home's private add-on: one checkout of a separate,
# usually private repository whose skills and hooks run on top of the shared
# Starship code, so a home's own tools stay out of the shared repository and
# the two never merge into each other.
#
# WHY. Everything tracked here ships to every home. Tools that serve one home
# only (its own accounts, devices, apps, or other work) belong in a repository
# that only that home pulls. An add-on keeps this repository's layout, so a tool
# moves between the two by moving its files:
#   .agents/skills/<skill>/SKILL.md   linked into the home's checkout by
#                                     bin/fm-opt-in-skills.sh
#   hooks/<point>/<name>              run or sourced at the hook points below
#   bin/, docs/, tests/, ...          whatever its hooks and skills use
#
# CONFIG. The private, gitignored config/addon holds `key = value` lines;
# blank lines and lines starting with # are ignored:
#   path = <checkout>   required: an absolute path, ~/..., or a path relative to
#                       FM_HOME, such as projects/starship-addon
#   origin = <url>      optional: what `install` clones when the checkout is
#                       missing
# With no config/addon there is no add-on, and every command below behaves as
# if the add-on had no skills and no hooks, so such a home runs exactly as it
# did before add-ons existed.
#
# HOOK POINTS. Hooks come from two places: this repository's own hooks/<point>/
# (built-in hooks, for a shared tool that runs at a hook point) and the add-on's
# hooks/<point>/. An add-on hook with the same name as a built-in replaces it,
# so a tool never runs twice. Hooks run in name order, so a numeric prefix such
# as 10- sets the order.
#   bootstrap      executables run by session-start bootstrap among its
#                  read-only checks; their output lands in the startup digest.
#   session-start  executables run where the session-start digest prints the
#                  operating instructions, on the full and the re-emit path;
#                  their output is printed under ADD-ON INSTRUCTIONS.
#   sentinel       executables run by bin/fm-supervision-sentinel.sh to decide
#                  whether a home with no crew task in flight still needs
#                  watching: each prints one line naming the work it watches
#                  over, or nothing.
#   watcher        bash files named <name>.sh, sourced once into bin/fm-watch.sh
#                  when it starts, with FM_HOOK_ROOT set; hook W1 there owns the
#                  guarded functions such a file may define.
#   deck-staging   executables run by bin/fm-deck.sh on every frame; each prints
#                  one JSON array of staging run records, which the deck joins
#                  and bin/fm-deck-render.py places in the sections that own
#                  each run's state.
#   todo-verbs     executables bin/fm-todo.sh offers a to-do page line typed
#                  against one row that no built-in page command takes; the
#                  first that prints a result takes it (its header owns the
#                  contract).
#   todo-page      executables bin/fm-todo-render.sh runs on every render of
#                  the day's to-do page; each prints an HTML section placed on
#                  the page (its header owns the contract).
# Executable hooks run with stdin from /dev/null and with FM_HOME, FM_ROOT (this
# repository) and FM_HOOK_ROOT (the repository holding the hook) exported, plus
# any arguments given to `run`. Each is bounded by FM_ADDON_HOOK_TIMEOUT seconds
# (default 20). A hook that fails or runs out of time is named on stderr and
# never stops the caller or the hooks after it. Only entries whose names start
# with a letter or digit and hold letters, digits, dot, dash and underscore are
# hooks; anything else, and anything that is not a regular executable file (a
# readable <name>.sh file for watcher), is ignored.
#
# Usage:
#   fm-addon.sh root                 print the add-on checkout; exits 1 when no
#                                    add-on is configured and 3 when config/addon
#                                    is unusable or names a missing checkout
#   fm-addon.sh hooks <point>        print <hook root><TAB><hook path> per hook
#   fm-addon.sh run <point> [args]   run every hook of an executable point
#   fm-addon.sh install              clone origin into path when the checkout is
#                                    missing; a present checkout is left as it is
#   fm-addon.sh create [--name <repo>]
#                                    give a home with no add-on its own: a private
#                                    repository on the signed-in GitHub account
#                                    (default name starship-<login>), started from
#                                    a minimal starter, kept at projects/<repo>,
#                                    with config/addon naming it; a usable add-on
#                                    is left as it is. Exits 0 with the add-on
#                                    ready, 1 when it cannot be made, and 4 when
#                                    GitHub is not signed in, printing the sign-in
#                                    steps instead of skipping
#   fm-addon.sh guards               make sure this home cannot publish anything
#                                    personal by mistake, one line per guard: the
#                                    role is user (no publishing to the Starship
#                                    repository), an add-on is configured, the
#                                    pre-push leak check is installed on this
#                                    checkout and the add-on, and config/leak-words
#                                    exists (written with one comment line when
#                                    missing). Exits 1 when any guard is not in
#                                    place, on a `guard problem:` line naming it
#   fm-addon.sh first-project        whether this home may add a project now:
#                                    exits 1, naming the private repository as
#                                    what comes first, when data/projects.md
#                                    registers no project yet and root fails;
#                                    exits 0 silently otherwise, and always in a
#                                    secondmate home. The project-management add
#                                    and create paths ask it before they clone or
#                                    register anything, so a new owner's first
#                                    project never comes before their add-on
# Exits 2 on misuse. Keeping the add-on current is bin/fm-update.sh's job.
#
# STARTER. create starts a new add-on with a README.md saying what goes where
# and empty .agents/skills/, hooks/ and bin/ folders, each holding a .gitkeep.
# Every GitHub step goes through the GitHub CLI's own sign-in (gh auth status).
# The add-on's pre-push leak check is installed before its first push. A
# repository of that name that already exists is reused, cloned when the
# checkout is missing, only while it is private; a public one is refused.
#
# Environment overrides, for tests and unusual layouts:
#   FM_HOME, FM_ROOT_OVERRIDE, FM_CONFIG_OVERRIDE, FM_ADDON_HOOK_TIMEOUT
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Built-in hooks live beside this script, whatever FM_ROOT_OVERRIDE names.
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ADDON_CONFIG="$CONFIG/addon"
HOOK_TIMEOUT="${FM_ADDON_HOOK_TIMEOUT:-20}"
HOOK_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {  # [exit-status]
  sed -n '/^# Usage:/,/^# Exits 2 on misuse/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

note() {
  printf 'fm-addon: %s\n' "$*" >&2
}

# config_value <key>: the last value given for <key> in config/addon.
config_value() {
  awk -F= -v want="$1" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      if (key != want) next
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      found = value
    }
    END { if (found != "") print found }
  ' "$ADDON_CONFIG"
}

# config_problem: name the first line of config/addon this script cannot use.
config_problem() {
  awk -F= '
    /^[[:space:]]*(#|$)/ { next }
    index($0, "=") == 0 { print "line " NR " is not key = value"; exit }
    {
      key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      if (key != "path" && key != "origin") { print "line " NR " has unknown key " key; exit }
    }
  ' "$ADDON_CONFIG"
}

# expand_path <path>: absolute as given, ~/ under HOME, anything else under FM_HOME.
expand_path() {
  local tilde='~'
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    "$tilde") printf '%s\n' "$HOME" ;;
    "$tilde"/*) printf '%s/%s\n' "$HOME" "${1#"$tilde"/}" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$1" ;;
  esac
}

# Sets ADDON_ROOT to the canonical checkout and returns 0; returns 1 with no
# config/addon, or 3 with ADDON_PROBLEM naming why the configured add-on is
# unusable. ADDON_PATH holds the configured path, expanded, whenever one is set.
ADDON_ROOT=
ADDON_PATH=
ADDON_PROBLEM=
resolve_addon() {
  local problem raw
  ADDON_ROOT=
  ADDON_PATH=
  ADDON_PROBLEM=
  [ -e "$ADDON_CONFIG" ] || [ -L "$ADDON_CONFIG" ] || return 1
  if [ ! -f "$ADDON_CONFIG" ] || [ ! -r "$ADDON_CONFIG" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG is not a readable file"
    return 3
  fi
  problem=$(config_problem)
  if [ -n "$problem" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG $problem"
    return 3
  fi
  raw=$(config_value path)
  if [ -z "$raw" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG has no path = line"
    return 3
  fi
  ADDON_PATH=$(expand_path "$raw")
  if [ ! -d "$ADDON_PATH" ]; then
    ADDON_PROBLEM="the add-on checkout $ADDON_PATH is missing; run bin/fm-addon.sh install"
    return 3
  fi
  ADDON_ROOT=$(cd "$ADDON_PATH" && pwd -P) || {
    ADDON_PROBLEM="the add-on checkout $ADDON_PATH cannot be entered"
    return 3
  }
  if [ "$ADDON_ROOT" = "$(cd "$CODE_ROOT" && pwd -P)" ]; then
    ADDON_ROOT=
    ADDON_PROBLEM="$ADDON_CONFIG names this Firstmate checkout itself, not an add-on"
    return 3
  fi
  return 0
}

valid_point() {
  case "$1" in
    bootstrap|session-start|sentinel|watcher|deck-staging|todo-verbs|todo-page) return 0 ;;
  esac
  return 1
}

# is_hook <point> <path>: whether <path> is a hook for <point>.
is_hook() {
  local point=$1 path=$2 name
  name=${path##*/}
  [[ $name =~ $HOOK_NAME_RE ]] || return 1
  [ -f "$path" ] || return 1
  if [ "$point" = watcher ]; then
    case "$name" in *.sh) ;; *) return 1 ;; esac
    [ -r "$path" ]
  else
    [ -x "$path" ]
  fi
}

# list_hooks <point>: <root><TAB><path> per hook in name order, built-ins first
# considered and replaced by an add-on hook of the same name.
list_hooks() {
  local point=$1 rank root entry status=0
  resolve_addon || status=$?
  [ "$status" -ne 3 ] || note "$ADDON_PROBLEM"
  {
    rank=0
    for root in "$CODE_ROOT" ${ADDON_ROOT:+"$ADDON_ROOT"}; do
      for entry in "$root/hooks/$point"/*; do
        is_hook "$point" "$entry" || continue
        printf '%s\t%s\t%s\t%s\n' "${entry##*/}" "$rank" "$root" "$entry"
      done
      rank=1
    done
  } | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n \
    | awk -F '\t' '
        $1 != name && name != "" { print kept }
        { name = $1; kept = $3 "\t" $4 }
        END { if (name != "") print kept }
      '
}

run_hooks() {
  local point=$1 root hook rc
  shift
  export FM_HOME
  FM_ROOT=$CODE_ROOT
  export FM_ROOT
  while IFS="$(printf '\t')" read -r root hook; do
    [ -n "$hook" ] || continue
    rc=0
    fm_run_timed "$HOOK_TIMEOUT" env FM_HOOK_ROOT="$root" "$hook" "$@" </dev/null || rc=$?
    if fm_timed_out "$rc"; then
      note "$point hook $hook ran out of time after ${HOOK_TIMEOUT}s"
    elif [ "$rc" -ne 0 ]; then
      note "$point hook $hook failed (exit $rc)"
    fi
  done <<EOF
$(list_hooks "$point")
EOF
  return 0
}

install_addon() {
  local status=0 origin out
  resolve_addon || status=$?
  case "$status" in
    0)
      printf 'add-on: present at %s\n' "$ADDON_ROOT"
      return 0
      ;;
    1)
      note "no add-on is configured; write $ADDON_CONFIG first (docs/configuration.md \"Private add-on\")"
      return 1
      ;;
  esac
  if [ -z "$ADDON_PATH" ] || [ -e "$ADDON_PATH" ] || [ -L "$ADDON_PATH" ]; then
    note "$ADDON_PROBLEM"
    return 1
  fi
  origin=$(config_value origin)
  if [ -z "$origin" ]; then
    note "$ADDON_CONFIG has no origin = line, so there is nothing to clone into $ADDON_PATH"
    return 1
  fi
  mkdir -p "$(dirname "$ADDON_PATH")" || { note "cannot create the parent of $ADDON_PATH"; return 1; }
  if ! out=$(GIT_TERMINAL_PROMPT=0 git clone --quiet -- "$origin" "$ADDON_PATH" 2>&1 </dev/null); then
    note "cloning $origin failed: ${out%%$'\n'*}; a private add-on needs a GitHub sign-in that git can use (gh auth login, then gh auth setup-git)"
    return 1
  fi
  printf 'add-on: cloned %s into %s\n' "$origin" "$ADDON_PATH"
}

# write_starter <dir>: the minimal add-on a new home starts from.
write_starter() {
  local dir=$1 sub
  for sub in .agents/skills hooks bin; do
    mkdir -p "$dir/$sub" && : > "$dir/$sub/.gitkeep" || return 1
  done
  cat > "$dir/README.md" <<'EOF'
# Starship add-on

This private repository holds your own changes to Starship: the skills, hooks and scripts that serve only you.
Starship's shared code stays exactly the public version, and this repository sits on top of it.

- `.agents/skills/<skill>/SKILL.md` - your own skills; each one is linked into your Starship home and loads like a built-in skill.
- `hooks/<point>/<name>` - your own hooks, run at Starship's hook points; `bin/fm-addon.sh` in Starship lists the points.
- `bin/` - scripts your skills and hooks use.
- `leak-words` (optional) - words that must never appear in public Starship, one per line, added to your home's own list.

Keep this repository private.
To change Starship for yourself, ask your first mate: the change lands here, never in public Starship.
EOF
}

# signed_in: whether gh is installed and signed in to github.com; otherwise
# names the sign-in steps.
signed_in() {
  local steps="run gh auth login, press Enter at each question, then gh auth setup-git, and ask again; your own private repository is made on your own GitHub account"
  if ! command -v gh >/dev/null 2>&1; then
    note "install the GitHub CLI (gh) and sign in to GitHub first: $steps"
    return 1
  fi
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    note "sign in to GitHub first: $steps"
    return 1
  fi
}

# origin_is <checkout> <owner/repo>: whether the checkout's origin is that
# repository.
origin_is() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  case "$url" in
    */"$2" | *:"$2") return 0 ;;
  esac
  return 1
}

# start_checkout <path> <login>: the starter, committed in a new repository.
start_checkout() {
  local path=$1 login=$2 id=()
  write_starter "$path" || { note "cannot write the starter into $path"; return 1; }
  git init -q -b main "$path" || { note "git init failed in $path"; return 1; }
  # With no git identity yet, the starter commit is signed with a placeholder
  # address, because a real one must never sit in this public script.
  git -C "$path" config user.email >/dev/null 2>&1 \
    || id=(-c "user.name=$login" -c "user.email=$login@example.invalid")
  { git -C "$path" add -A && git ${id[@]+"${id[@]}"} -C "$path" commit -q -m "Start the Starship add-on"; } || {
    note "the first commit in $path failed"
    return 1
  }
}

create_addon() {
  local name=$1 status=0 login slug rel path visibility
  resolve_addon || status=$?
  case "$status" in
    0)
      printf 'add-on: present at %s\n' "$ADDON_ROOT"
      return 0
      ;;
    3)
      if [ -n "$ADDON_PATH" ] && [ ! -e "$ADDON_PATH" ] && [ ! -L "$ADDON_PATH" ] && [ -n "$(config_value origin)" ]; then
        install_addon
        return
      fi
      note "$ADDON_PROBLEM"
      return 1
      ;;
  esac
  signed_in || return 4
  if ! login=$(gh api user --jq .login 2>/dev/null) || [ -z "$login" ]; then
    note "gh is signed in but cannot read the account name (gh api user); check gh auth status"
    return 1
  fi
  [ -n "$name" ] || name="starship-$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { note "$name is not a GitHub repository name"; return 1; }
  slug="$login/$name"
  rel="projects/$name"
  path="$FM_HOME/$rel"

  if visibility=$(gh repo view "$slug" --json visibility --jq .visibility 2>/dev/null); then
    if [ "$visibility" != PRIVATE ]; then
      note "github.com/$slug already exists and is not private, so it cannot be this home's add-on; make it private or pick another name with --name"
      return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
      if ! origin_is "$path" "$slug"; then
        note "$path is in the way: it is not a checkout of github.com/$slug; move it aside or pick another name with --name"
        return 1
      fi
      "$SCRIPT_DIR/fm-leak-prepush.sh" install "$path" addon >&2 || true
      if ! git -C "$path" push -q -u origin HEAD </dev/null >/dev/null 2>&1; then
        note "$path could not be pushed to github.com/$slug; push it by hand, then run create again"
        return 1
      fi
    else
      mkdir -p "$(dirname "$path")" || { note "cannot create $(dirname "$path")"; return 1; }
      if ! gh repo clone "$slug" "$path" </dev/null >/dev/null 2>&1; then
        note "cloning github.com/$slug into $path failed; check gh auth status and gh auth setup-git"
        return 1
      fi
    fi
  else
    if [ -e "$path" ] || [ -L "$path" ]; then
      # Only a starter an interrupted create left behind, with no remote yet.
      if [ ! -d "$path/.git" ] || git -C "$path" remote get-url origin >/dev/null 2>&1; then
        note "$path is in the way: move it aside or pick another name with --name"
        return 1
      fi
    else
      start_checkout "$path" "$login" || return 1
    fi
    "$SCRIPT_DIR/fm-leak-prepush.sh" install "$path" addon >&2 || true
    if ! gh repo create "$name" --private --source "$path" --remote origin --push \
      --description "Private Starship add-on" </dev/null >/dev/null 2>&1; then
      note "creating the private repository github.com/$slug failed; check gh auth status, then run create again"
      return 1
    fi
  fi

  mkdir -p "$CONFIG" || { note "cannot create $CONFIG"; return 1; }
  if ! printf 'path = %s\norigin = https://github.com/%s\n' "$rel" "$slug" > "$ADDON_CONFIG"; then
    note "cannot write $ADDON_CONFIG"
    return 1
  fi
  resolve_addon || { note "$ADDON_PROBLEM"; return 1; }
  printf 'add-on: ready at %s, from the private repository github.com/%s\n' "$ADDON_ROOT" "$slug"
}

# push_check <checkout> <kind>: install the pre-push leak check, then confirm it.
push_check() {
  local out
  "$SCRIPT_DIR/fm-leak-prepush.sh" install "$1" "$2" >/dev/null 2>&1 || true
  if out=$("$SCRIPT_DIR/fm-leak-prepush.sh" status "$1" "$2"); then
    printf 'guard: the pre-push leak check is installed on %s\n' "$1"
    return 0
  fi
  printf 'guard problem: %s\n' "$out"
  return 1
}

check_guards() {
  local problems=0 role status=0 words="$CONFIG/leak-words"
  role=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-role.sh" report 2>/dev/null) || role=
  case "$role" in
    "fm-role: user"*)
      printf 'guard: the role is user, so this home never publishes to the Starship repository on its own\n'
      ;;
    *)
      printf 'guard problem: the role is not user (%s), so this home may publish to the Starship repository; remove %s unless this home maintains Starship\n' \
        "${role:-unreadable}" "$CONFIG/firstmate-role"
      problems=1
      ;;
  esac

  push_check "$CODE_ROOT" starship || problems=1
  resolve_addon || status=$?
  case "$status" in
    0) push_check "$ADDON_ROOT" addon || problems=1 ;;
    1)
      printf 'guard problem: no add-on is configured, so this home has no private place for its own changes; run bin/fm-addon.sh create\n'
      problems=1
      ;;
    *)
      printf 'guard problem: %s\n' "$ADDON_PROBLEM"
      problems=1
      ;;
  esac

  if [ -f "$words" ]; then
    printf 'guard: the private word list %s is in place\n' "$words"
  elif [ -e "$words" ] || [ -L "$words" ]; then
    printf 'guard problem: %s is not a regular file\n' "$words"
    problems=1
  elif mkdir -p "$CONFIG" \
    && printf '%s\n' "# One word or phrase per line that must never appear in public Starship, such as the names of people, customers and private projects." > "$words"; then
    printf 'guard: the private word list %s was started, empty\n' "$words"
  else
    printf 'guard problem: cannot write %s\n' "$words"
    problems=1
  fi
  return "$problems"
}

# first_project: refuse a home's first project while it has no usable add-on.
first_project() {
  local data="${FM_DATA_OVERRIDE:-$FM_HOME/data}" status=0
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    return 0
  fi
  if [ -f "$data/projects.md" ] && grep -q '^- ' "$data/projects.md"; then
    return 0
  fi
  resolve_addon || status=$?
  [ "$status" -ne 0 ] || return 0
  note "the first project waits for this home's own private repository (first-voyage step 4): with the owner's yes, run bin/fm-addon.sh create, then add the project${ADDON_PROBLEM:+ ($ADDON_PROBLEM)}"
  return 1
}

case "${1:-}" in
  root)
    [ "$#" -eq 1 ] || usage
    status=0
    resolve_addon || status=$?
    case "$status" in
      0) printf '%s\n' "$ADDON_ROOT" ;;
      3) note "$ADDON_PROBLEM" ;;
    esac
    exit "$status"
    ;;
  hooks)
    if [ "$#" -ne 2 ] || ! valid_point "$2"; then usage; fi
    list_hooks "$2"
    ;;
  run)
    if [ "$#" -lt 2 ] || ! valid_point "$2" || [ "$2" = watcher ]; then usage; fi
    shift
    run_hooks "$@"
    ;;
  install)
    [ "$#" -eq 1 ] || usage
    install_addon
    ;;
  create)
    shift
    create_name=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name)
          [ "$#" -ge 2 ] || usage
          create_name=$2
          shift 2
          ;;
        *) usage ;;
      esac
    done
    create_addon "$create_name"
    ;;
  guards)
    [ "$#" -eq 1 ] || usage
    check_guards
    ;;
  first-project)
    [ "$#" -eq 1 ] || usage
    first_project
    ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac

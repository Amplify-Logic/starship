#!/usr/bin/env bash
# tests/fm-addon.test.sh - bin/fm-addon.sh: a home's private add-on.
#
# With no config/addon a home runs only the code checkout's built-in hooks. This
# checkout ships only the daily intake's two bootstrap hooks, which stay silent
# until the home switches the intake on, so a home with no add-on gets no
# output at any point.
# A configured add-on's hooks join the built-ins in name order, an add-on hook
# replaces a built-in of the same name, a failing or slow hook never stops the
# caller or the hooks after it, watcher hooks are sourced into bin/fm-watch.sh
# rather than run, an unusable config/addon is named with its repair, and
# install clones a missing checkout from the configured origin. create gives a
# home with no add-on its own private repository from the starter, through a
# stand-in for the GitHub CLI, guards confirms a new home cannot publish
# anything personal by mistake, and first-project holds a home's first project
# back until that private repository exists.
#
# Every case uses a throwaway home and add-on, so no case reads or writes this
# home; built-in hooks are exercised in a throwaway code checkout holding a copy
# of the script.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADDON="$ROOT/bin/fm-addon.sh"
TMP_ROOT=$(fm_test_tmproot fm-addon)
fm_git_identity fmtest fmtest@example.invalid

# new_home <name>: an empty operational home; echoes its path.
new_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' "$home"
}

# new_addon <home>: an add-on checkout beside <home>, named by its config/addon.
new_addon() {
  local addon
  addon="$(dirname "$1")/addon"
  mkdir -p "$addon/hooks"
  printf 'path = %s\n' "$addon" > "$1/config/addon"
  printf '%s\n' "$addon"
}

# add_hook <add-on> <point> <name> <body>: an executable hook.
add_hook() {
  mkdir -p "$1/hooks/$2"
  printf '#!/usr/bin/env bash\n%s\n' "$4" > "$1/hooks/$2/$3"
  chmod +x "$1/hooks/$2/$3"
}

addon() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$ADDON" "$@"
}

# new_code <name>: a throwaway code checkout holding this script and the library
# it sources, so a case can give it built-in hooks; echoes its canonical path.
new_code() {
  local code="$TMP_ROOT/$1/code"
  mkdir -p "$code/bin" "$code/hooks"
  cp "$ADDON" "$ROOT/bin/fm-timeout-lib.sh" "$code/bin/"
  (cd "$code" && pwd -P)
}

addon_at() {  # <code> <home> <args...>
  local code=$1 home=$2
  shift 2
  env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$code/bin/fm-addon.sh" "$@"
}

test_no_addon_means_no_hooks() {
  local home out code point
  home=$(new_home none)
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 1 "$code" "root with no config/addon"
  assert_equals "" "$out" "root with no add-on must print nothing"
  assert_equals "$(printf '%s\t%s\n%s\t%s' \
    "$ROOT" "$ROOT/hooks/bootstrap/10-morning-intake" "$ROOT" "$ROOT/hooks/bootstrap/20-channel-intake")" \
    "$(addon "$home" hooks bootstrap 2>&1)" "a home with no add-on must list only the shipped intake bootstrap hooks"
  for point in session-start sentinel watcher deck-staging todo-verbs todo-page; do
    assert_equals "" "$(addon "$home" hooks "$point" 2>&1)" "a home with no add-on must list no $point hook"
  done
  for point in bootstrap session-start sentinel deck-staging todo-page; do
    out=$(addon "$home" run "$point" 2>&1); code=$?
    expect_code 0 "$code" "run $point with nothing to run"
    assert_equals "" "$out" "a home with no add-on must get no $point output"
  done
  pass "with no config/addon a home gets no hook output at any point, and the shipped intake hooks stay silent"
}

test_built_in_hooks_run_with_no_addon() {
  local code home
  code=$(new_code built-in)
  home=$(new_home built-in)
  add_hook "$code" bootstrap 20-second 'echo second'
  add_hook "$code" bootstrap 10-first 'echo first'
  assert_equals "$(printf '%s\t%s\n%s\t%s' \
    "$code" "$code/hooks/bootstrap/10-first" "$code" "$code/hooks/bootstrap/20-second")" \
    "$(addon_at "$code" "$home" hooks bootstrap)" "a home with no add-on must list exactly the built-in hooks"
  assert_equals "$(printf 'first\nsecond')" "$(addon_at "$code" "$home" run bootstrap 2>&1)" \
    "a home with no add-on must run the built-in hooks in name order"
  pass "with no config/addon the code checkout's built-in hooks run in name order"
}

test_addon_hooks_join_in_name_order_and_replace_built_ins() {
  local code home addon out
  code=$(new_code order)
  home=$(new_home order)
  add_hook "$code" bootstrap 10-built-in 'echo built-in'
  add_hook "$code" bootstrap 20-replaced 'echo the built-in that must not run'
  addon=$(new_addon "$home")
  # shellcheck disable=SC2016 # The hook body expands its own variables.
  add_hook "$addon" bootstrap 05-first 'printf "first root=%s hook=%s home=%s args=%s\n" "$FM_ROOT" "$FM_HOOK_ROOT" "$FM_HOME" "$*"'
  add_hook "$addon" bootstrap 20-replaced 'echo "replaced the built-in"'
  add_hook "$addon" bootstrap .hidden 'echo hidden'
  add_hook "$addon" bootstrap 'has space' 'echo spaced'
  printf '#!/usr/bin/env bash\necho not-executable\n' > "$addon/hooks/bootstrap/30-not-executable"
  mkdir -p "$addon/hooks/bootstrap/40-a-directory"
  addon=$(cd "$addon" && pwd -P)

  out=$(addon_at "$code" "$home" hooks bootstrap)
  assert_equals "$(printf '%s\t%s\n%s\t%s\n%s\t%s' \
    "$addon" "$addon/hooks/bootstrap/05-first" \
    "$code" "$code/hooks/bootstrap/10-built-in" \
    "$addon" "$addon/hooks/bootstrap/20-replaced")" "$out" \
    "add-on hooks must join the built-ins in name order, replace the one of their name, and skip non-hooks"

  out=$(addon_at "$code" "$home" run bootstrap one two 2>&1)
  assert_equals "$(printf 'first root=%s hook=%s home=%s args=one two\nbuilt-in\nreplaced the built-in' "$code" "$addon" "$home")" \
    "$out" "every hook must run once, in order, with its roots, the home, and the arguments"
  pass "add-on hooks join the built-ins in name order and replace a built-in of the same name"
}

test_failing_and_slow_hooks_never_stop_the_caller() {
  local home addon out err code started elapsed
  home=$(new_home failing)
  addon=$(new_addon "$home")
  add_hook "$addon" session-start 10-fails 'echo partial; exit 3'
  add_hook "$addon" session-start 20-slow 'sleep 30; echo late'
  add_hook "$addon" session-start 30-after 'echo after'
  # shellcheck disable=SC2016 # The hook body expands its own variables.
  add_hook "$addon" session-start 40-reads-input 'if IFS= read -r line; then echo "read: $line"; fi'
  started=$(date +%s)
  out=$(printf 'not for hooks\n' | FM_ADDON_HOOK_TIMEOUT=2 addon "$home" run session-start 2>"$TMP_ROOT/failing.err"); code=$?
  elapsed=$(( $(date +%s) - started ))
  err=$(cat "$TMP_ROOT/failing.err")
  expect_code 0 "$code" "run must not fail over a hook"
  assert_equals "$(printf 'partial\nafter')" "$out" "the hooks after a failing or slow one must still run, and no hook reads the caller's input"
  assert_contains "$err" "session-start hook $addon/hooks/session-start/10-fails failed (exit 3)" "a failing hook must be named"
  assert_contains "$err" "hooks/session-start/20-slow ran out of time after 2s" "a slow hook must be named"
  [ "$elapsed" -lt 25 ] || fail "a slow hook must be cut off at its bound, took ${elapsed}s"
  pass "a failing or slow hook is named and never stops the caller or the hooks after it"
}

test_watcher_hooks_are_sourced_into_the_watcher() {
  local home addon out code
  home=$(new_home watcher)
  addon=$(new_addon "$home")
  mkdir -p "$addon/hooks/watcher"
  cat > "$addon/hooks/watcher/50-mine.sh" <<'SH'
# shellcheck shell=bash
fm_addon_test_root=$FM_HOOK_ROOT
fm_addon_test_input=$(cat)
fm_addon_test_marker() { printf 'marker from %s\n' "$fm_addon_test_root"; }
SH
  add_hook "$addon" watcher 60-not-a-library 'echo no'
  addon=$(cd "$addon" && pwd -P)

  out=$(addon "$home" hooks watcher)
  assert_equals "$(printf '%s\t%s' "$addon" "$addon/hooks/watcher/50-mine.sh")" \
    "$out" "watcher hooks are the readable .sh files, and nothing else"
  addon "$home" run watcher >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "watcher hooks are sourced by the watcher, never run"

  # shellcheck disable=SC2016 # The child shell expands its own variables.
  out=$(printf 'watcher input\n' | env -u FM_CONFIG_OVERRIDE FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/bin/fm-watch.sh" || exit 3
      fm_addon_test_marker
      printf "input=[%s]\n" "$fm_addon_test_input"
      [ -z "${FM_HOOK_ROOT:-}" ] && echo "hook root cleared"
    ' _ "$ROOT" 2>&1)
  assert_contains "$out" "marker from $addon" "the watcher must source the add-on's hook with FM_HOOK_ROOT set to the add-on"
  assert_contains "$out" "input=[]" "a sourced hook must read no input"
  assert_contains "$out" "hook root cleared" "FM_HOOK_ROOT must not outlive the hook loading"
  pass "watcher hooks are sourced into the watcher, never run"
}

test_unusable_config_is_named_with_its_repair() {
  local home out code
  home=$(new_home config)
  printf 'path = addon\nbogus = 1\n' > "$home/config/addon"
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 3 "$code" "an unknown key"
  assert_contains "$out" "config/addon line 2 has unknown key bogus" "an unknown key must be named with its line"

  printf '# only a comment\norigin = https://example.invalid/x\n' > "$home/config/addon"
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 3 "$code" "no path line"
  assert_contains "$out" "has no path = line" "a config/addon with no path must say so"

  printf 'path = addon\n' > "$home/config/addon"
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 3 "$code" "a missing checkout"
  assert_contains "$out" "the add-on checkout $home/addon is missing; run bin/fm-addon.sh install" \
    "a relative path must resolve under FM_HOME and a missing checkout must name install"
  out=$(addon "$home" run bootstrap 2>&1); code=$?
  expect_code 0 "$code" "run with an unusable add-on"
  assert_contains "$out" "is missing; run bin/fm-addon.sh install" "run must name an unusable add-on"

  mkdir -p "$home/addon"
  assert_equals "$(cd "$home/addon" && pwd -P)" "$(addon "$home" root)" "a present relative checkout must resolve"
  mkdir -p "$TMP_ROOT/config/fakehome/my-addon"
  assert_equals "$(cd "$TMP_ROOT/config/fakehome/my-addon" && pwd -P)" \
    "$(printf 'path = ~/my-addon\n' > "$home/config/addon"; HOME="$TMP_ROOT/config/fakehome" addon "$home" root)" \
    "a ~/ path must resolve under HOME"

  printf 'path = %s\n' "$ROOT" > "$home/config/addon"
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 3 "$code" "this checkout as its own add-on"
  assert_contains "$out" "names this Firstmate checkout itself, not an add-on" "this checkout must never be its own add-on"
  pass "an unusable config/addon is named with its repair, and paths resolve under FM_HOME or HOME"
}

test_install_clones_a_missing_checkout() {
  local home origin out code
  home=$(new_home install)
  out=$(addon "$home" install 2>&1); code=$?
  expect_code 1 "$code" "install with no config/addon"
  assert_contains "$out" "no add-on is configured" "install with no add-on must say so"

  origin="$TMP_ROOT/install/addon.git"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$TMP_ROOT/install/seed" 2>/dev/null
  mkdir -p "$TMP_ROOT/install/seed/hooks/bootstrap"
  printf '#!/usr/bin/env bash\necho installed hook\n' > "$TMP_ROOT/install/seed/hooks/bootstrap/50-installed"
  chmod +x "$TMP_ROOT/install/seed/hooks/bootstrap/50-installed"
  git -C "$TMP_ROOT/install/seed" add -A
  git -C "$TMP_ROOT/install/seed" commit -qm a1
  git -C "$TMP_ROOT/install/seed" push -q origin main

  printf 'path = projects/my-addon\n' > "$home/config/addon"
  out=$(addon "$home" install 2>&1); code=$?
  expect_code 1 "$code" "install with no origin"
  assert_contains "$out" "has no origin = line" "a missing checkout with no origin must say so"

  printf 'path = projects/my-addon\norigin = %s\n' "file://$origin" > "$home/config/addon"
  out=$(addon "$home" install 2>&1); code=$?
  expect_code 0 "$code" "install of a missing checkout"
  assert_contains "$out" "add-on: cloned file://$origin into $home/projects/my-addon" "install must report the clone"
  assert_contains "$(addon "$home" run bootstrap)" "installed hook" "the installed add-on's hooks must run"
  out=$(addon "$home" install 2>&1); code=$?
  expect_code 0 "$code" "install of a present checkout"
  assert_contains "$out" "add-on: present at" "a present checkout must be left as it is"
  pass "install clones a missing checkout from its origin and leaves a present one alone"
}

test_misuse_exits_2() {
  local home code
  home=$(new_home misuse)
  addon "$home" 2>/dev/null; code=$?
  expect_code 2 "$code" "no subcommand"
  addon "$home" hooks nowhere 2>/dev/null; code=$?
  expect_code 2 "$code" "an unknown hook point"
  addon "$home" run 2>/dev/null; code=$?
  expect_code 2 "$code" "run with no point"
  addon "$home" root extra 2>/dev/null; code=$?
  expect_code 2 "$code" "root with an argument"
  addon "$home" first-project extra 2>/dev/null; code=$?
  expect_code 2 "$code" "first-project with an argument"
  addon "$home" --help 2>/dev/null; code=$?
  expect_code 0 "$code" "--help"
  pass "misuse exits 2 and --help exits 0"
}

# fake_gh <dir>: a stand-in for the GitHub CLI whose account, sign-in and
# repositories live under <dir>/gh: `signed-in` marks the sign-in, `login`
# holds the account name, and remotes/<owner>/<repo>.git is a bare repository
# beside a .visibility file. Every call is logged to <dir>/gh/calls. Echoes the
# directory to put first on PATH.
fake_gh() {
  local dir=$1 bin
  bin=$(fm_fakebin "$dir")
  mkdir -p "$dir/gh/remotes"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
state=${FAKE_GH_STATE:?}
printf '%s\n' "$*" >> "$state/calls"
login=$(cat "$state/login" 2>/dev/null)
case "$1 $2" in
  "auth status") [ -e "$state/signed-in" ] ;;
  "api user") [ -e "$state/signed-in" ] && printf '%s\n' "$login" ;;
  "repo view")
    [ -d "$state/remotes/$3.git" ] || { echo "Could not resolve to a Repository" >&2; exit 1; }
    cat "$state/remotes/$3.visibility"
    ;;
  "repo clone") git clone -q "$state/remotes/$3.git" "$4" ;;
  "repo create")
    name=$3 source='' visibility=PUBLIC
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --private) visibility=PRIVATE ;;
        --source) source=$2; shift ;;
      esac
      shift
    done
    remote="$state/remotes/$login/$name.git"
    mkdir -p "$(dirname "$remote")"
    git init -q --bare -b main "$remote"
    printf '%s\n' "$visibility" > "$state/remotes/$login/$name.visibility"
    git -C "$source" remote add origin "$remote"
    git -C "$source" push -q -u origin HEAD
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$bin/gh"
  printf '%s\n' "$bin"
}

# gh_remote <dir> <owner/repo> <visibility>: a repository that already exists
# on the stand-in GitHub, holding one commit with a README.
gh_remote() {
  local remote="$1/gh/remotes/$2.git" seed="$1/seed-${2//\//-}"
  mkdir -p "$(dirname "$remote")"
  git init -q --bare -b main "$remote"
  printf '%s\n' "$3" > "$1/gh/remotes/$2.visibility"
  git init -q -b main "$seed"
  printf '# existing\n' > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -qm existing
  git -C "$seed" push -q "$remote" main
}

# addon_gh <dir> <home> <args...>: this script with the stand-in GitHub of <dir>.
addon_gh() {
  local dir=$1 home=$2 bin
  shift 2
  bin=$(fm_fakebin "$dir")
  env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$bin:$PATH" FAKE_GH_STATE="$dir/gh" \
    FM_HOME="$home" "$ADDON" "$@"
}

test_create_without_github_sign_in_stops_with_the_sign_in_steps() {
  local dir="$TMP_ROOT/create-no-sign-in" home out code
  home=$(new_home create-no-sign-in)
  fake_gh "$dir" >/dev/null
  printf 'someone\n' > "$dir/gh/login"
  out=$(addon_gh "$dir" "$home" create 2>&1); code=$?
  expect_code 4 "$code" "create with GitHub not signed in"
  assert_contains "$out" "sign in to GitHub first: run gh auth login" "create must name the sign-in steps"
  assert_absent "$home/config/addon" "create must not write config/addon without a repository"
  assert_absent "$home/projects" "create must not start a checkout without a repository"
  assert_not_contains "$(cat "$dir/gh/calls")" "repo create" "create must not try to make a repository"
  pass "create with GitHub not signed in stops with the sign-in steps and writes nothing"
}

test_create_makes_a_private_repository_from_the_starter() {
  local dir="$TMP_ROOT/create-new" home out code checkout remote
  home=$(new_home create-new)
  fake_gh "$dir" >/dev/null
  printf 'Someone\n' > "$dir/gh/login"
  : > "$dir/gh/signed-in"
  out=$(addon_gh "$dir" "$home" create 2>&1); code=$?
  expect_code 0 "$code" "create on a signed-in account with no add-on"
  checkout="$home/projects/starship-someone"
  remote="$dir/gh/remotes/Someone/starship-someone.git"
  assert_equals "$(printf 'path = projects/starship-someone\norigin = https://github.com/Someone/starship-someone')" \
    "$(cat "$home/config/addon")" "create must name the new checkout and its repository in config/addon"
  assert_contains "$out" "add-on: ready at $(cd "$checkout" && pwd -P), from the private repository github.com/Someone/starship-someone" \
    "create must report the ready add-on"
  assert_equals "PRIVATE" "$(cat "$dir/gh/remotes/Someone/starship-someone.visibility")" "the repository must be private"
  assert_equals "$(printf '.agents/skills/.gitkeep\nREADME.md\nbin/.gitkeep\nhooks/.gitkeep')" \
    "$(git -C "$checkout" ls-files | LC_ALL=C sort)" "the starter must hold the README and the three empty folders"
  assert_contains "$(cat "$checkout/README.md")" "Keep this repository private." "the starter README must say to keep it private"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$(git -C "$remote" rev-parse main)" \
    "the starter commit must be pushed to the new repository"
  "$ROOT/bin/fm-leak-prepush.sh" status "$checkout" addon >/dev/null
  expect_code 0 "$?" "the add-on's pre-push leak check must be installed"
  assert_equals "$(cd "$checkout" && pwd -P)" "$(addon "$home" root)" "the new add-on must load"

  out=$(addon_gh "$dir" "$home" create 2>&1); code=$?
  expect_code 0 "$code" "create with the add-on present"
  assert_contains "$out" "add-on: present at" "a second create must leave the add-on as it is"
  assert_equals "1" "$(grep -c '^repo create' "$dir/gh/calls")" "a second create must not make another repository"
  pass "create makes a private repository from the starter, pushes it, and points config/addon at it"
}

test_create_reuses_only_a_private_repository_of_that_name() {
  local dir="$TMP_ROOT/create-existing" home out code
  home=$(new_home create-existing)
  fake_gh "$dir" >/dev/null
  printf 'someone\n' > "$dir/gh/login"
  : > "$dir/gh/signed-in"
  gh_remote "$dir" someone/starship-someone PUBLIC
  out=$(addon_gh "$dir" "$home" create 2>&1); code=$?
  expect_code 1 "$code" "create over a public repository of that name"
  assert_contains "$out" "github.com/someone/starship-someone already exists and is not private" \
    "create must refuse a public repository"
  assert_absent "$home/config/addon" "a refused create must not write config/addon"

  gh_remote "$dir" someone/my-tools PRIVATE
  out=$(addon_gh "$dir" "$home" create --name my-tools 2>&1); code=$?
  expect_code 0 "$code" "create over a private repository of that name"
  assert_equals "# existing" "$(cat "$home/projects/my-tools/README.md")" "create must clone the existing repository"
  assert_contains "$(cat "$home/config/addon")" "origin = https://github.com/someone/my-tools" \
    "config/addon must name the existing repository"
  assert_not_contains "$(cat "$dir/gh/calls")" "repo create" "create must not make a repository that exists"

  out=$(addon_gh "$dir" "$home" create --name 'bad name' 2>&1); code=$?
  expect_code 0 "$code" "create with an add-on already present ignores the name"
  rm "$home/config/addon"
  out=$(addon_gh "$dir" "$home" create --name 'bad name' 2>&1); code=$?
  expect_code 1 "$code" "create with a name GitHub cannot take"
  assert_contains "$out" "is not a GitHub repository name" "a bad name must be named"
  pass "create clones an existing private repository of that name and refuses a public one"
}

test_create_checks_a_present_checkout_before_pushing_it() {
  local dir="$TMP_ROOT/create-present" home out code checkout remote key
  home=$(new_home create-present)
  fake_gh "$dir" >/dev/null
  printf 'someone\n' > "$dir/gh/login"
  : > "$dir/gh/signed-in"
  gh_remote "$dir" someone/my-tools PRIVATE
  remote="$dir/gh/remotes/someone/my-tools.git"
  checkout="$home/projects/my-tools"
  mkdir -p "$home/projects"
  git clone -q "$remote" "$checkout"
  key="$(printf 'sk')_live_$(printf 's7r%.0s' 1 2 3 4 5 6)"
  printf 'use %s here\n' "$key" > "$checkout/keys.md"
  git -C "$checkout" add -A
  git -C "$checkout" commit -qm keyed
  out=$(addon_gh "$dir" "$home" create --name my-tools 2>&1); code=$?
  expect_code 1 "$code" "create over a present checkout holding a key"
  assert_contains "$out" "could not be pushed to github.com/someone/my-tools" "create must name the refused push"
  assert_equals "1" "$(git -C "$remote" rev-list --count main)" "the key must never reach the repository"
  assert_absent "$home/config/addon" "a refused push must not write config/addon"

  git -C "$checkout" reset -q --hard HEAD~1
  printf 'my own tool\n' > "$checkout/tool.md"
  git -C "$checkout" add -A
  git -C "$checkout" commit -qm tool
  out=$(addon_gh "$dir" "$home" create --name my-tools 2>&1); code=$?
  expect_code 0 "$code" "create over a present clean checkout"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$(git -C "$remote" rev-parse main)" \
    "create must push the present checkout"
  assert_contains "$(cat "$home/config/addon")" "origin = https://github.com/someone/my-tools" \
    "config/addon must name the existing repository"
  pass "create installs the leak check on a present checkout before pushing it"
}

# new_code_repo <name>: a throwaway Starship checkout, a git main working tree,
# holding the scripts guards runs; echoes its canonical path.
new_code_repo() {
  local code
  code=$(new_code "$1")
  cp "$ROOT/bin/fm-role.sh" "$ROOT/bin/fm-role-lib.sh" "$ROOT/bin/fm-leak-prepush.sh" \
    "$ROOT/bin/fm-leak-shapes.py" "$ROOT/bin/fm_secret_shapes.py" "$code/bin/"
  git -C "$code" init -q -b main
  git -C "$code" add -A
  git -C "$code" commit -qm code
  printf '%s\n' "$code"
}

test_guards_confirm_a_new_home_cannot_publish_by_mistake() {
  local code home addon out rc
  code=$(new_code_repo guards)
  home=$(new_home guards)
  out=$(addon_at "$code" "$home" guards 2>&1); rc=$?
  expect_code 1 "$rc" "guards with no add-on"
  assert_contains "$out" "guard problem: no add-on is configured" "guards must name a missing add-on"
  assert_contains "$out" "guard: the private word list $home/config/leak-words was started, empty" \
    "guards must start the word list"
  assert_equals "" "$(grep -v '^#' "$home/config/leak-words")" "the started word list must hold no word"

  addon=$(new_addon "$home")
  git -C "$addon" init -q -b main
  addon=$(cd "$addon" && pwd -P)
  out=$(addon_at "$code" "$home" guards 2>&1); rc=$?
  expect_code 0 "$rc" "guards on a new home with an add-on"
  assert_contains "$out" "guard: the role is user" "guards must confirm the user role"
  assert_contains "$out" "guard: the pre-push leak check is installed on $code" "guards must confirm the Starship check"
  assert_contains "$out" "guard: the pre-push leak check is installed on $addon" "guards must confirm the add-on check"
  "$code/bin/fm-leak-prepush.sh" status "$code" starship >/dev/null
  expect_code 0 "$?" "the Starship checkout's pre-push check must be installed"
  "$code/bin/fm-leak-prepush.sh" status "$addon" addon >/dev/null
  expect_code 0 "$?" "the add-on's pre-push check must be installed"

  printf 'kept-word\n' > "$home/config/leak-words"
  out=$(addon_at "$code" "$home" guards 2>&1); rc=$?
  expect_code 0 "$rc" "guards a second time"
  assert_contains "$out" "guard: the private word list $home/config/leak-words is in place" "a present list must be kept"
  assert_equals "kept-word" "$(cat "$home/config/leak-words")" "guards must never rewrite a word list"

  printf 'maintainer github.com/example/starship\n' > "$home/config/firstmate-role"
  out=$(addon_at "$code" "$home" guards 2>&1); rc=$?
  expect_code 1 "$rc" "guards on a home that may publish"
  assert_contains "$out" "guard problem: the role is not user (fm-role: maintainer github.com/example/starship" \
    "guards must name a publishing role"
  pass "guards confirm the user role, install and confirm both pre-push checks, and start the word list"
}

# The redirect case of first setup: an owner who declines step 4 and asks to go
# straight to a project ("skip it and add my project <address>"). The add path
# asks first-project before it clones or registers anything, and on a home
# with no project yet that answer is no until the private repository exists.
test_first_project_waits_for_the_private_repository() {
  local home addon out rc
  home=$(new_home first-project)
  printf '# Captain preferences\n' > "$home/data/captain.md"
  out=$(addon "$home" first-project 2>&1); rc=$?
  expect_code 1 "$rc" "first-project on a new home with no add-on"
  assert_contains "$out" "the first project waits for this home's own private repository" \
    "first-project must name the private repository as what comes first"
  assert_contains "$out" "bin/fm-addon.sh create" "first-project must name the step that makes it"

  printf '# Projects\n\n' > "$home/data/projects.md"
  printf 'path = projects/missing\n' > "$home/config/addon"
  out=$(addon "$home" first-project 2>&1); rc=$?
  expect_code 1 "$rc" "first-project with an empty registry and an unusable add-on"
  assert_contains "$out" "the first project waits for this home's own private repository" \
    "an unusable add-on must hold the first project back too"

  addon=$(new_addon "$home")
  out=$(addon "$home" first-project 2>&1); rc=$?
  expect_code 0 "$rc" "first-project once the add-on exists"
  assert_equals "" "$out" "first-project must stay quiet when the project may be added"

  rm -f "$home/config/addon"
  printf '%s\n' '- blog [no-mistakes] - the blog (added 2026-11-15)' >> "$home/data/projects.md"
  out=$(addon "$home" first-project 2>&1); rc=$?
  expect_code 0 "$rc" "first-project on a home that already has a project"

  home=$(new_home first-project-secondmate)
  : > "$home/.fm-secondmate-home"
  out=$(addon "$home" first-project 2>&1); rc=$?
  expect_code 0 "$rc" "first-project in a secondmate home"
  pass "first-project holds a home's first project back until its private repository exists"
}

test_no_addon_means_no_hooks
test_built_in_hooks_run_with_no_addon
test_addon_hooks_join_in_name_order_and_replace_built_ins
test_failing_and_slow_hooks_never_stop_the_caller
test_watcher_hooks_are_sourced_into_the_watcher
test_unusable_config_is_named_with_its_repair
test_install_clones_a_missing_checkout
test_misuse_exits_2
test_create_without_github_sign_in_stops_with_the_sign_in_steps
test_create_makes_a_private_repository_from_the_starter
test_create_reuses_only_a_private_repository_of_that_name
test_create_checks_a_present_checkout_before_pushing_it
test_guards_confirm_a_new_home_cannot_publish_by_mistake
test_first_project_waits_for_the_private_repository

echo "# fm-addon.test.sh: all assertions passed"

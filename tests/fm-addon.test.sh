#!/usr/bin/env bash
# tests/fm-addon.test.sh - bin/fm-addon.sh: a home's private add-on.
#
# With no config/addon a home runs only this checkout's built-in hooks. A
# configured add-on's hooks join them in name order, an add-on hook replaces a
# built-in of the same name, a failing or slow hook never stops the caller or
# the hooks after it, watcher hooks are sourced into bin/fm-watch.sh rather than
# run, an unusable config/addon is named with its repair, and install clones a
# missing checkout from the configured origin.
#
# Every case uses a throwaway home and add-on, so no case reads or writes this
# home; the built-in hooks under test are this checkout's real hooks/ entries.
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

test_no_addon_runs_only_the_built_in_hooks() {
  local home out code
  home=$(new_home none)
  out=$(addon "$home" root 2>&1); code=$?
  expect_code 1 "$code" "root with no config/addon"
  assert_equals "" "$out" "root with no add-on must print nothing"
  assert_equals "$(printf '%s\t%s\n%s\t%s' \
    "$ROOT" "$ROOT/hooks/bootstrap/10-morning-intake" "$ROOT" "$ROOT/hooks/bootstrap/20-channel-intake")" \
    "$(addon "$home" hooks bootstrap)" "a home with no add-on must list exactly the built-in bootstrap hooks"
  out=$(addon "$home" run bootstrap 2>&1); code=$?
  expect_code 0 "$code" "run with nothing to report"
  assert_equals "" "$out" "a home that never opted in to an intake must get no bootstrap output"
  assert_equals "" "$(addon "$home" run sentinel 2>&1)" "an idle home must report no sentinel work"
  assert_equals "" "$(addon "$home" run session-start 2>&1)" "a home with no add-on has no session-start output"
  pass "with no config/addon only this checkout's built-in hooks run, and they stay silent"
}

test_addon_hooks_join_in_name_order_and_replace_built_ins() {
  local home addon out
  home=$(new_home order)
  addon=$(new_addon "$home")
  # shellcheck disable=SC2016 # The hook body expands its own variables.
  add_hook "$addon" bootstrap 05-first 'printf "first root=%s hook=%s home=%s args=%s\n" "$FM_ROOT" "$FM_HOOK_ROOT" "$FM_HOME" "$*"'
  add_hook "$addon" bootstrap 20-channel-intake 'echo "replaced the built-in"'
  add_hook "$addon" bootstrap .hidden 'echo hidden'
  add_hook "$addon" bootstrap 'has space' 'echo spaced'
  printf '#!/usr/bin/env bash\necho not-executable\n' > "$addon/hooks/bootstrap/30-not-executable"
  mkdir -p "$addon/hooks/bootstrap/40-a-directory"
  addon=$(cd "$addon" && pwd -P)

  out=$(addon "$home" hooks bootstrap)
  assert_equals "$(printf '%s\t%s\n%s\t%s\n%s\t%s' \
    "$addon" "$addon/hooks/bootstrap/05-first" \
    "$ROOT" "$ROOT/hooks/bootstrap/10-morning-intake" \
    "$addon" "$addon/hooks/bootstrap/20-channel-intake")" "$out" \
    "add-on hooks must join the built-ins in name order, replace the one of their name, and skip non-hooks"

  out=$(addon "$home" run bootstrap one two 2>&1)
  assert_equals "$(printf 'first root=%s hook=%s home=%s args=one two\nreplaced the built-in' "$ROOT" "$addon" "$home")" \
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
  assert_equals "$(printf '%s\t%s\n%s\t%s' \
    "$ROOT" "$ROOT/hooks/watcher/10-glasses-file-event.sh" "$addon" "$addon/hooks/watcher/50-mine.sh")" \
    "$out" "watcher hooks are the readable .sh files of both places, in name order"
  addon "$home" run watcher >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "watcher hooks are sourced by the watcher, never run"

  # shellcheck disable=SC2016 # The child shell expands its own variables.
  out=$(printf 'watcher input\n' | env -u FM_CONFIG_OVERRIDE FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/bin/fm-watch.sh" || exit 3
      fm_addon_test_marker
      printf "input=[%s]\n" "$fm_addon_test_input"
      command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1 && echo "built-in hook loaded"
      [ -z "${FM_HOOK_ROOT:-}" ] && echo "hook root cleared"
    ' _ "$ROOT" 2>&1)
  assert_contains "$out" "marker from $addon" "the watcher must source the add-on's hook with FM_HOOK_ROOT set to the add-on"
  assert_contains "$out" "input=[]" "a sourced hook must read no input"
  assert_contains "$out" "built-in hook loaded" "the built-in glasses file-event hook must still load beside it"
  assert_contains "$out" "hook root cleared" "FM_HOOK_ROOT must not outlive the hook loading"
  pass "watcher hooks of both places are sourced into the watcher, never run"
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
  addon "$home" --help 2>/dev/null; code=$?
  expect_code 0 "$code" "--help"
  pass "misuse exits 2 and --help exits 0"
}

test_no_addon_runs_only_the_built_in_hooks
test_addon_hooks_join_in_name_order_and_replace_built_ins
test_failing_and_slow_hooks_never_stop_the_caller
test_watcher_hooks_are_sourced_into_the_watcher
test_unusable_config_is_named_with_its_repair
test_install_clones_a_missing_checkout
test_misuse_exits_2

echo "# fm-addon.test.sh: all assertions passed"

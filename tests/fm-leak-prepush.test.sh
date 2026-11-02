#!/usr/bin/env bash
# Behavior tests for bin/fm-leak-prepush.sh, the pre-push leak check a home
# installs on its Starship checkout and on its private add-on. Every case pushes
# with real git to a bare remote and asserts both the exit status and what the
# remote ended up holding.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREPUSH="$ROOT/bin/fm-leak-prepush.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-leak-prepush)
fm_git_identity fmtest fmtest@example.invalid

# cap <word>: the word with a capital first letter. The invented names below
# are written in small letters here so this file never adds a name-shaped word
# of its own; each test capitalises its name at run time.
cap() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# make_home <dir>: a Starship checkout carrying the guard and this check, whose
# main is on the bare origin <dir>.origin.git, with a private word list in its
# ignored config/ that holds no word the cases use unless they add one.
make_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/docs" "$home/config"
  cp "$ROOT/bin/fm-leak-guard.sh" "$ROOT/bin/fm-leak-lib.sh" "$ROOT/bin/fm-leak-shapes.py" \
    "$ROOT/bin/fm_secret_shapes.py" "$ROOT/bin/fm-addon.sh" "$ROOT/bin/fm-timeout-lib.sh" \
    "$PREPUSH" "$home/bin/"
  printf '# Notes\nThe theme stays.\n' > "$home/docs/notes.md"
  printf '/config/\n' > "$home/.gitignore"
  git -C "$home" init -q -b main
  git -C "$home" add -A
  git -C "$home" commit -q -m init
  git init -q --bare "$home.origin.git"
  git -C "$home" remote add origin "$home.origin.git"
  git -C "$home" push -q origin main
  printf 'unrelated-word\n' > "$home/config/leak-words"
}

# add_line <repo> <path> <text> [message]: commit one more line to the path.
add_line() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >> "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "${4:-add}"
}

# push <repo> <args...>: a plain git push with no inherited FM_HOME, as typed by
# hand; output in PUSH_OUT, status in PUSH_RC.
push() {
  local repo=$1
  shift
  PUSH_RC=0
  PUSH_OUT=$(env -u FM_HOME git -C "$repo" push "$@" 2>&1) || PUSH_RC=$?
}

# on_remote <bare> <branch>: whether the bare remote holds the branch.
on_remote() {
  git -C "$1" rev-parse -q --verify "refs/heads/$2" >/dev/null
}

refused() {  # <label> <bare> <branch>
  [ "$PUSH_RC" -ne 0 ] || fail "$1 was accepted: $PUSH_OUT"
  assert_contains "$PUSH_OUT" "fm-leak-prepush: push refused" "$1 was refused without the check naming itself"
  ! on_remote "$2" "$3" || fail "$1 still reached the remote"
}

accepted() {  # <label> <bare> <branch>
  [ "$PUSH_RC" -eq 0 ] || fail "$1 was refused: $PUSH_OUT"
  on_remote "$2" "$3" || fail "$1 did not reach the remote"
}

test_hand_push_of_a_new_name_is_refused() {
  local home="$TMP_ROOT/names" name
  name=$(cap qverblox)
  make_home "$home"
  git -C "$home" checkout -q -b feature
  add_line "$home" docs/notes.md "ask $name about the theme."

  # The gap this closes: with no hook, a plain push carries the new name out.
  push "$home" origin feature:refs/heads/before
  accepted "a push with no hook installed" "$home.origin.git" before

  # The same change as a commit the remote does not hold yet.
  git -C "$home" commit -q --amend -m "add again"
  "$PREPUSH" install "$home" starship || fail "install failed"
  push "$home" origin feature
  refused "a hand push of a never-seen name" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "LEAK_HIT: new-name: docs/notes.md:3: $name" "the refusal did not show the guard's own hit line"
  assert_contains "$PUSH_OUT" "$home/config/leak-names-approved" "the refusal did not say where an approval is recorded"

  # One approval lets it through, and the pass says what it read.
  printf '%s\n' qverblox > "$home/config/leak-names-approved"
  push "$home" origin feature
  accepted "a push once the name is approved" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "fm-leak-prepush: leak check passed" "a clean push did not say it was checked"
  pass "leak prepush: a plain git push of a never-seen name is refused until the owner approves it"
}

# The guard's full scan runs over the files the branch changes: a private word
# and a key are placed, never printed, and a file the branch leaves alone is
# not read.
test_changed_files_get_the_full_scan() {
  local home="$TMP_ROOT/scan" key
  key="$(printf 'SOMETHING_API')_KEY=$(printf 'k3y%.0s' 1 2 3 4 5 6 7)"
  make_home "$home"
  "$PREPUSH" install "$home" starship || fail "install failed"
  git -C "$home" checkout -q -b feature
  add_line "$home" docs/keys.md "use $key here"
  push "$home" origin feature
  refused "a push adding a key" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "LEAK_HIT: token: docs/keys.md:1:" "the key was not placed"
  assert_not_contains "$PUSH_OUT" "$key" "the refusal printed the key"

  git -C "$home" reset -q --hard main
  add_line "$home" docs/notes.md "the zorbel plan."
  printf 'zorbel\n' > "$home/config/leak-words"
  push "$home" origin feature
  refused "a push adding a private word" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "LEAK_HIT: private-word: docs/notes.md:3:" "the private word was not placed"
  assert_not_contains "$PUSH_OUT" "zorbel" "the refusal printed the private word"

  # A listed word already on origin/main in a file the branch leaves alone is
  # not this push's to refuse.
  printf 'theme\n' > "$home/config/leak-words"
  git -C "$home" reset -q --hard main
  add_line "$home" docs/other.md "a clean line."
  push "$home" origin feature
  accepted "a push that leaves the listed file alone" "$home.origin.git" feature
  pass "leak prepush: the guard's full scan reads the changed files, placing words and keys without printing them"
}

# Worktrees share the checkout's hooks, and a fleet pane's own pre-push wrapper
# chains to the hook rather than replacing it.
test_task_worktree_and_pane_wrapper_are_checked() {
  local home="$TMP_ROOT/tree" tree="$TMP_ROOT/tree-task" hooks="$TMP_ROOT/tree-pane-hooks" name
  name=$(cap vellicort)
  make_home "$home"
  "$PREPUSH" install "$home" starship || fail "install failed"
  git -C "$home" fetch -q origin
  git -C "$home" worktree add -q -b task "$tree" main
  add_line "$tree" docs/notes.md "ask $name."
  push "$tree" origin task
  refused "a push from a task worktree" "$home.origin.git" task
  assert_contains "$PUSH_OUT" "new-name: docs/notes.md:3: $name" "the worktree push did not run the guard"

  "$STRIP" install "$hooks" "$tree" || fail "the pane wrapper did not install"
  PUSH_RC=0
  PUSH_OUT=$(env -u FM_HOME GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    git -C "$tree" push origin task 2>&1) || PUSH_RC=$?
  refused "a push through a fleet pane's hooks" "$home.origin.git" task
  assert_contains "$PUSH_OUT" "new-name: docs/notes.md:3: $name" "the pane wrapper did not chain to the leak check"
  pass "leak prepush: task worktrees share the hook, and a fleet pane's wrapper chains to it"
}

test_existing_hook_is_kept_and_chained() {
  local home="$TMP_ROOT/chain" log="$TMP_ROOT/chain.log" hooks before name out
  name=$(cap drasmelt)
  make_home "$home"
  hooks="$home/.git/hooks"
  # shellcheck disable=SC2016 # The hook expands these when git runs it.
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$1" "$(cat)" >> %q\n' "$log" > "$hooks/pre-push"
  chmod +x "$hooks/pre-push"
  "$PREPUSH" install "$home" starship || fail "install over an existing hook failed"
  [ -x "$hooks/pre-push.fm-chained" ] || fail "the existing hook was not kept as pre-push.fm-chained"
  before=$(cat "$hooks/pre-push" "$hooks/pre-push.fm-chained")
  "$PREPUSH" install "$home" starship || fail "a second install failed"
  [ "$(cat "$hooks/pre-push" "$hooks/pre-push.fm-chained")" = "$before" ] || fail "a second install changed the hooks"

  git -C "$home" checkout -q -b clean
  add_line "$home" docs/notes.md "a clean line."
  push "$home" origin clean
  accepted "a clean push" "$home.origin.git" clean
  grep -q "^origin refs/heads/clean " "$log" || fail "the chained hook did not get git's arguments and ref lines"

  add_line "$home" docs/notes.md "ask $name."
  : > "$log"
  push "$home" origin clean
  refused "a push of a new name" "$home.origin.git" no-such-branch
  [ ! -s "$log" ] || fail "a refused push still ran the chained hook"

  # A second foreign hook is never overwritten or dropped.
  printf '#!/bin/sh\nexit 0\n' > "$hooks/pre-push"
  out=$("$PREPUSH" install "$home" starship) && fail "install over two foreign hooks succeeded"
  assert_contains "$out" "LEAK_PREPUSH: $home:" "install did not name the checkout it could not install on"
  grep -q 'exit 0' "$hooks/pre-push" || fail "install replaced a second foreign hook"
  pass "leak prepush: an existing pre-push hook is kept, chained after a pass and skipped on a refusal"
}

test_gate_push_and_escape() {
  local home="$TMP_ROOT/gate" gate="$TMP_ROOT/gate-mirror.git" name
  name=$(cap tromvell)
  make_home "$home"
  "$PREPUSH" install "$home" starship || fail "install failed"
  git init -q --bare "$gate"
  git -C "$home" remote add no-mistakes "$gate"
  git -C "$home" checkout -q -b feature
  add_line "$home" docs/notes.md "ask $name."
  push "$home" no-mistakes feature
  accepted "a push to the pipeline's gate" "$gate" feature
  assert_contains "$PUSH_OUT" "validation pipeline's gate" "the gate push did not say why it was not checked here"

  FM_PUSH_LEAK_CHECK=off push "$home" origin feature
  refused "a push with an unknown escape value" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "is not 'skip'" "an unknown escape value was not named"

  FM_PUSH_LEAK_CHECK=skip push "$home" origin feature
  accepted "a push with the named escape" "$home.origin.git" feature
  assert_contains "$PUSH_OUT" "LEAK CHECK SKIPPED for this push to origin" "the escape was not loud"
  pass "leak prepush: the pipeline's gate is left to its lint step, and the one-push escape is named and loud"
}

test_only_new_commits_at_the_checked_out_commit() {
  local home="$TMP_ROOT/refs" name
  name=$(cap kelvorn)
  make_home "$home"
  "$PREPUSH" install "$home" starship || fail "install failed"
  git -C "$home" checkout -q -b other
  add_line "$home" docs/notes.md "ask $name."
  git -C "$home" checkout -q main

  push "$home" origin other
  refused "a branch with new commits that is not checked out" "$home.origin.git" other
  assert_contains "$PUSH_OUT" "refs/heads/other brings commits origin does not have yet" "the refusal did not name the ref"

  # Commits the remote already holds, and a deletion, publish nothing new.
  printf 'ask %s.\n' "$name" >> "$home/docs/notes.md"
  push "$home" origin main:refs/heads/copy
  accepted "a push of commits the remote already has" "$home.origin.git" copy
  push "$home" origin --delete copy
  [ "$PUSH_RC" -eq 0 ] || fail "a deletion was refused: $PUSH_OUT"
  pass "leak prepush: only new commits are checked, and they must be the checked-out commit"
}

# The add-on is private and holds its own words and names; only key, token
# and customer data shapes refuse there.
test_addon_keeps_its_own_words() {
  local addon="$TMP_ROOT/addon" key
  key="$(printf 'sk')_live_$(printf 's7r%.0s' 1 2 3 4 5 6)"
  fm_git_init_commit "$addon"
  git init -q --bare "$addon.origin.git"
  git -C "$addon" remote add origin "$addon.origin.git"
  git -C "$addon" push -q origin main
  git -C "$addon" remote set-head origin main
  "$PREPUSH" install "$addon" addon || fail "install on the add-on failed"
  printf 'qverblox\n' > "$addon/leak-words"
  add_line "$addon" docs/team.md "$(cap qverblox) and $(cap zandrelt) run the qverblox plan."
  add_line "$addon" tests/fm-keys.test.sh "fixture $key"
  push "$addon" origin main
  accepted "an add-on push of its own words and names" "$addon.origin.git" main
  assert_contains "$PUSH_OUT" "leak check passed" "the add-on push was not checked"

  add_line "$addon" docs/keys.md "use $key here"
  push "$addon" origin main:refs/heads/keyed
  refused "an add-on push adding a key" "$addon.origin.git" keyed
  assert_contains "$PUSH_OUT" "LEAK_HIT: token: docs/keys.md:1:" "the key was not placed"
  assert_not_contains "$PUSH_OUT" "$key" "the refusal printed the key"

  git -C "$addon" reset -q --hard HEAD~1
  add_line "$addon" docs/team.md "call +31 6 0000 0000 after nine."
  push "$addon" origin main:refs/heads/phoned
  refused "an add-on push adding a phone number" "$addon.origin.git" phoned
  assert_contains "$PUSH_OUT" "LEAK_HIT: phone: docs/team.md:" "the phone number was not named"
  pass "leak prepush: the add-on refuses keys and customer data but never its own words or names"
}

test_install_skips_copies_it_does_not_own() {
  local repo="$TMP_ROOT/own" tree="$TMP_ROOT/own-tree" bare="$TMP_ROOT/own-bare.git" out
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add -q --detach "$tree" HEAD
  out=$("$PREPUSH" install "$tree" starship) || fail "install on a linked worktree failed: $out"
  mkdir -p "$repo/sub"
  out=$("$PREPUSH" install "$repo/sub" starship) || fail "install on a subdirectory failed: $out"
  git init -q --bare "$bare"
  out=$("$PREPUSH" install "$bare" starship) || fail "install on a bare repository failed: $out"
  [ -z "$out" ] || fail "a skipped install printed: $out"
  [ ! -e "$repo/.git/hooks/pre-push" ] || fail "a linked worktree or subdirectory installed its primary's hook"
  [ ! -e "$bare/hooks/pre-push" ] || fail "a bare repository got the hook"

  git -C "$repo" config core.hooksPath .githooks
  out=$("$PREPUSH" install "$repo" starship) && fail "install into a hooks path inside the checkout succeeded"
  assert_contains "$out" "LEAK_PREPUSH: $repo: core.hooksPath points inside the checkout" "the tracked hooks path was not named"
  [ ! -e "$repo/.githooks/pre-push" ] || fail "install wrote into the checkout's tracked files"
  pass "leak prepush: install covers only a main working tree's own hooks and never writes into tracked files"
}

test_bootstrap_installs_on_home_and_addon() {
  local home="$TMP_ROOT/boot" addon="$TMP_ROOT/boot-addon" out
  fm_git_init_commit "$home"
  fm_git_init_commit "$addon"
  mkdir -p "$home/config"
  printf 'path = %s\n' "$addon" > "$home/config/addon"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "bootstrap failed: $out"
  assert_not_contains "$out" "LEAK_PREPUSH" "bootstrap could not install the hook"
  grep -q 'fm-leak-prepush hook (starship)' "$home/.git/hooks/pre-push" 2>/dev/null \
    || fail "bootstrap did not install the hook on the home's checkout"
  grep -q 'fm-leak-prepush hook (addon)' "$addon/.git/hooks/pre-push" 2>/dev/null \
    || fail "bootstrap did not install the add-on's hook"
  pass "leak prepush: session-start bootstrap installs the hook on the home's checkout and its add-on"
}

fm_test_run \
  test_hand_push_of_a_new_name_is_refused \
  test_changed_files_get_the_full_scan \
  test_task_worktree_and_pane_wrapper_are_checked \
  test_existing_hook_is_kept_and_chained \
  test_gate_push_and_escape \
  test_only_new_commits_at_the_checked_out_commit \
  test_addon_keeps_its_own_words \
  test_install_skips_copies_it_does_not_own \
  test_bootstrap_installs_on_home_and_addon

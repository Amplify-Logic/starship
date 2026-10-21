#!/usr/bin/env bash
# Behavior tests for bin/fm-leak-guard.sh's private word list: a home's own
# names and plans, listed in its gitignored config/leak-words, fail the scan in
# every tracked file, tests/ included, while a home with no list scans exactly
# as before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-leak-guard)

# make_repo <dir>: a committed checkout carrying the guard, a test fixture that
# names a person, and a clean doc.
make_repo() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  cp "$ROOT/bin/fm-leak-guard.sh" "$ROOT/bin/fm-leak-lib.sh" "$repo/bin/"
  printf 'run_hook "Captain, Robin approved the draft."\n' > "$repo/tests/fm-x.test.sh"
  printf '# Notes\nThe robin-egg blue theme stays.\n' > "$repo/docs/notes.md"
  printf '/config/\n' > "$repo/.gitignore"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m init
}

# guard <repo> [env assignments...] [-- guard arguments...]: runs the repo's
# guard with no inherited FM_HOME; output in GUARD_OUT, status in GUARD_STATUS.
guard() {
  local repo=$1 envs=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  GUARD_STATUS=0
  GUARD_OUT=$(env -u FM_HOME ${envs[@]+"${envs[@]}"} "$repo/bin/fm-leak-guard.sh" "$@" 2>&1) || GUARD_STATUS=$?
}

# word_home <dir> <list text>: a home whose config/leak-words holds the text.
word_home() {
  mkdir -p "$1/config"
  printf '%b' "$2" > "$1/config/leak-words"
}

test_no_list_scans_as_before() {
  local repo="$TMP_ROOT/plain"
  make_repo "$repo"
  guard "$repo"
  [ "$GUARD_STATUS" -eq 0 ] || fail "a home with no word list failed the scan: $GUARD_OUT"
  assert_not_contains "$GUARD_OUT" "private" "a home with no word list still reported on private words"
  pass "leak guard: with no private word list the scan is unchanged"
}

test_listed_word_fails_in_tests() {
  local repo="$TMP_ROOT/listed" home="$TMP_ROOT/listed-home"
  make_repo "$repo"
  word_home "$home" '# Notes\n\n  ROBIN  \n'
  guard "$repo" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a listed name in tests/ did not fail the scan: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "LEAK_HIT: private-word: tests/fm-x.test.sh: 1:" "the hit did not name the test file and line"
  assert_contains "$GUARD_OUT" "private words" "the failure did not say private words were found"
  # A dash ends a word, so robin-egg in the doc is a hit too.
  assert_contains "$GUARD_OUT" "LEAK_HIT: private-word: docs/notes.md: 2:" "a whole word joined by a dash was missed"
  assert_not_contains "$GUARD_OUT" "docs/notes.md: 1:" "a comment line in the list was used as a phrase"
  pass "leak guard: a listed word fails the scan in tests/ too, case-insensitively and as a whole word"
}

test_partial_words_do_not_hit() {
  local repo="$TMP_ROOT/partial" home="$TMP_ROOT/partial-home"
  make_repo "$repo"
  word_home "$home" 'rob\napproved the\n'
  guard "$repo" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a listed phrase did not fail the scan: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "tests/fm-x.test.sh" "a listed phrase was missed"
  assert_not_contains "$GUARD_OUT" "docs/notes.md" "a listed word matched inside a longer word"
  word_home "$home" 'rob\n'
  guard "$repo" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 0 ] || fail "a word that only appears inside longer words failed the scan: $GUARD_OUT"
  pass "leak guard: phrases match and a word never matches inside a longer one"
}

test_list_found_from_home_and_from_a_task_worktree() {
  local repo="$TMP_ROOT/home-repo" home="$TMP_ROOT/other-home" tree="$TMP_ROOT/task-tree"
  make_repo "$repo"
  mkdir -p "$repo/config" "$home/config"
  printf 'robin\n' > "$repo/config/leak-words"
  printf 'nobody-here\n' > "$home/config/leak-words"

  # A task worktree has no config/ of its own; it reads its primary checkout's.
  git -C "$repo" worktree add -q --detach "$tree" HEAD
  guard "$tree"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a task worktree did not read its home's word list: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "private-word: tests/fm-x.test.sh" "the worktree scan missed the listed name"

  # An explicit FM_HOME wins over the checkout's own home.
  guard "$tree" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 0 ] || fail "FM_HOME's word list was not the one read: $GUARD_OUT"
  pass "leak guard: the list comes from FM_HOME, else the checkout's primary home"
}

# A no-mistakes validation copy is a worktree of the gate's own bare mirror, so
# it belongs to no home; the guard then reads the default home's list.
test_list_found_from_a_validation_copy() {
  local repo="$TMP_ROOT/gate-src" mirror="$TMP_ROOT/gate/abc123.git" tree="$TMP_ROOT/gate-run" user="$TMP_ROOT/user"
  make_repo "$repo"
  git clone -q --bare "$repo" "$mirror"
  git -C "$mirror" worktree add -q --detach "$tree" HEAD
  word_home "$user/starship" 'robin\n'
  guard "$tree" HOME="$user"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a validation copy did not read the default home's word list: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "private-word: tests/fm-x.test.sh" "the validation copy scan missed the listed name"
  rm "$user/starship/config/leak-words"
  guard "$tree" HOME="$user"
  [ "$GUARD_STATUS" -eq 0 ] || fail "a validation copy with no default home list failed: $GUARD_OUT"
  pass "leak guard: a validation copy that belongs to no home reads the default home's list"
}

test_private_words_mode() {
  local repo="$TMP_ROOT/words-only" home="$TMP_ROOT/words-only-home" empty="$TMP_ROOT/words-only-empty"
  make_repo "$repo"
  printf 'contact someone@acme-mail.com\n' > "$repo/docs/contact.md"
  git -C "$repo" add -A

  # No list: silent success, and the other patterns are not this mode's job.
  mkdir -p "$empty"
  guard "$repo" FM_HOME="$empty" -- --private-words
  [ "$GUARD_STATUS" -eq 0 ] || fail "the word-only check failed with no list: $GUARD_OUT"
  [ -z "$GUARD_OUT" ] || fail "the word-only check printed with no list: $GUARD_OUT"

  word_home "$home" 'robin\n'
  guard "$repo" FM_HOME="$home" -- --private-words
  [ "$GUARD_STATUS" -eq 1 ] || fail "the word-only check passed a listed word: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "private-word: tests/fm-x.test.sh" "the word-only check missed the listed name"
  assert_not_contains "$GUARD_OUT" "LEAK_HIT: email" "the word-only check also ran the email scan"
  pass "leak guard: --private-words checks only the list and is silent without one"
}

# The AI co-author addresses bin/fm-git-strip-ai-trailers.sh strips are vendor
# bots, not people, so docs may name them; a person's address still fails.
test_vendor_bot_emails_pass() {
  local repo="$TMP_ROOT/bots" addr
  make_repo "$repo"
  for addr in noreply@anthropic.com noreply@openai.com copilot@github.com noreply@commandcode.ai; do
    printf 'Co-authored-by: Bot <%s>\n' "$addr" >> "$repo/docs/trailers.md"
  done
  git -C "$repo" add -A
  guard "$repo"
  [ "$GUARD_STATUS" -eq 0 ] || fail "a vendor bot address failed the scan: $GUARD_OUT"
  printf 'contact someone@acme-mail.com\n' >> "$repo/docs/trailers.md"
  guard "$repo"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a person's address passed the scan: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "LEAK_HIT: email: docs/trailers.md: 5:" "the hit did not name the person's address line"
  pass "leak guard: vendor bot co-author addresses pass and a person's address still fails"
}

test_no_list_scans_as_before
test_listed_word_fails_in_tests
test_partial_words_do_not_hit
test_list_found_from_home_and_from_a_task_worktree
test_list_found_from_a_validation_copy
test_private_words_mode
test_vendor_bot_emails_pass

echo "# fm-leak-guard.test.sh: all assertions passed"

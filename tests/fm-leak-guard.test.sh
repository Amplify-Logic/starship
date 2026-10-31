#!/usr/bin/env bash
# Behavior tests for bin/fm-leak-guard.sh's private word list: a home's own
# names and plans, listed in its gitignored config/leak-words, fail the scan in
# every tracked file, tests/ included, while a home with no list scans exactly
# as before. A home's private add-on may carry more words in its own leak-words
# file, and a secondmate home inherits the merged list beside its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-leak-guard)

# make_repo <dir>: a committed checkout carrying the guard, a test fixture that
# names a person, and a clean doc.
make_repo() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  cp "$ROOT/bin/fm-leak-guard.sh" "$ROOT/bin/fm-leak-lib.sh" "$ROOT/bin/fm-leak-shapes.py" \
    "$ROOT/bin/fm-addon.sh" "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
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

# addon_home <home> <add-on list text or -> : a home whose config/addon names
# an add-on checkout under it; with list text, the add-on carries leak-words.
addon_home() {
  local home=$1
  mkdir -p "$home/config" "$home/projects/team-addon"
  printf 'path = projects/team-addon\n' > "$home/config/addon"
  [ "$2" = - ] || printf '%b' "$2" > "$home/projects/team-addon/leak-words"
}

test_addon_list_adds_words() {
  local repo="$TMP_ROOT/addon" home="$TMP_ROOT/addon-home" draft="$TMP_ROOT/addon-draft.txt"
  make_repo "$repo"

  # An add-on with no leak-words file changes nothing.
  addon_home "$home" -
  guard "$repo" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 0 ] || fail "an add-on with no word list failed the scan: $GUARD_OUT"
  assert_not_contains "$GUARD_OUT" "private" "an add-on with no word list still reported on private words"

  # The add-on's words alone fail the scan, in tracked files and in draft text.
  addon_home "$home" '# team names\nRobin\n'
  guard "$repo" FM_HOME="$home"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a word only on the add-on's list passed the scan: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "LEAK_HIT: private-word: tests/fm-x.test.sh: 1:" "the add-on's word was missed"
  printf 'Robin reviewed the plan with Quillon.\n' > "$draft"
  guard "$repo" FM_HOME="$home" -- --text "$draft"
  [ "$GUARD_STATUS" -eq 1 ] || fail "draft text holding the add-on's word passed: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "LEAK_HIT: private-word: $draft: Robin" "the draft check did not name the add-on's word"

  # Both lists apply together.
  word_home "$home" 'quillon\n'
  guard "$repo" FM_HOME="$home" -- --text "$draft"
  assert_contains "$GUARD_OUT" ": Robin" "the add-on's word was dropped beside the home's list"
  assert_contains "$GUARD_OUT" ": Quillon" "the home's word was dropped beside the add-on's list"

  # A home list whose last line has no newline keeps both lists' words apart.
  word_home "$home" 'quillon'
  guard "$repo" FM_HOME="$home" -- --text "$draft"
  [ "$GUARD_STATUS" -eq 1 ] || fail "a home list with no final newline let the draft pass: $GUARD_OUT"
  assert_contains "$GUARD_OUT" ": Robin" "the add-on's first word joined the home's unterminated last word"
  assert_contains "$GUARD_OUT" ": Quillon" "the home's unterminated last word joined the add-on's first word"

  # An unusable add-on is named, adds nothing, and leaves the home's list working.
  printf 'path = projects/missing-addon\n' > "$home/config/addon"
  guard "$repo" FM_HOME="$home" -- --text "$draft"
  [ "$GUARD_STATUS" -eq 1 ] || fail "the home's own list stopped working beside an unusable add-on: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "add-on" "an unusable add-on was not named"
  assert_not_contains "$GUARD_OUT" ": Robin" "a word was read from an unusable add-on"
  pass "leak guard: a private add-on's leak-words file adds its words to the home's list"
}

# A secondmate home inherits the primary's merged list as its
# config/leak-words.inherited, loses only that file when the primary has none,
# keeps its own config/leak-words untouched throughout, and never gets the
# words in a reread.
test_secondmate_inherits_merged_list() {
  local primary="$TMP_ROOT/inherit-primary" mate="$TMP_ROOT/inherit-mate" report="$TMP_ROOT/inherit-report"
  addon_home "$primary" 'Robin\n'
  word_home "$primary" 'quillon\n'
  word_home "$mate" 'ferrowind\n'
  (
    # shellcheck source=bin/fm-config-inherit-lib.sh
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    : > "$report"
    FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary/config" "$mate/config" "$primary" \
      || fail "propagation failed"
    grep -qx Robin "$mate/config/leak-words.inherited" || fail "the inherited list lost the add-on's word"
    grep -qx quillon "$mate/config/leak-words.inherited" || fail "the inherited list lost the home's word"
    [ "$(cat "$mate/config/leak-words")" = ferrowind ] || fail "inheritance changed the secondmate's own list"
    [ "$(awk -F '\t' '$1 == "leak-words.inherited" { print $2 }' "$report")" = pushed ] \
      || fail "the inherited list was not reported as pushed: $(cat "$report")"
    [ -z "$(fm_config_reread_changed_items "$report")" ] \
      || fail "a word list change asked for a reread that would inline its words"
    instruction="$TMP_ROOT/inherit-instruction"
    ! fm_config_write_reread_instruction "$mate" "$report" "$instruction" \
      || fail "a reread instruction was written for a word list change"

    printf 'path = projects/missing-addon\n' > "$primary/config/addon"
    : > "$report"
    ! FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary/config" "$mate/config" "$primary" \
      2>/dev/null || fail "propagation succeeded while the primary's add-on was unusable"
    [ "$(awk -F '\t' '$1 == "leak-words.inherited" { print $2 }' "$report")" = error ] \
      || fail "an unusable add-on was not reported as a word list error: $(cat "$report")"
    grep -qx Robin "$mate/config/leak-words.inherited" \
      || fail "an unusable add-on stripped the add-on's word from the secondmate"
    printf 'path = projects/team-addon\n' > "$primary/config/addon"

    rm "$primary/config/leak-words" "$primary/projects/team-addon/leak-words"
    propagate_inheritable_config "$primary/config" "$mate/config" "$primary" || fail "absence propagation failed"
    [ ! -e "$mate/config/leak-words.inherited" ] || fail "the primary's removed list stayed in the secondmate home"
    [ "$(cat "$mate/config/leak-words")" = ferrowind ] \
      || fail "a primary with no words removed or changed the secondmate's own list"
  ) || exit 1
  # The secondmate's guard reads its own list and the inherited one together.
  local repo="$TMP_ROOT/inherit-repo" draft="$TMP_ROOT/inherit-draft.txt"
  make_repo "$repo"
  printf 'Robin\n' > "$mate/config/leak-words.inherited"
  printf 'Ferrowind wrote this.\n' > "$draft"
  guard "$repo" FM_HOME="$mate"
  [ "$GUARD_STATUS" -eq 1 ] || fail "the secondmate's guard did not read its inherited list: $GUARD_OUT"
  guard "$repo" FM_HOME="$mate" -- --text "$draft"
  [ "$GUARD_STATUS" -eq 1 ] || fail "the secondmate's guard dropped its own list beside the inherited one: $GUARD_OUT"
  pass "leak guard: a secondmate home inherits the primary's merged word list beside its own and never sees it in a reread"
}

# The remote route converges every other inherited item while the primary's
# add-on is unusable, keeps the secondmate's last inherited list, and names
# the problem without failing the push.
test_remote_route_keeps_list_on_unusable_addon() {
  local primary="$TMP_ROOT/remote-primary" mate="$TMP_ROOT/remote-mate" fakebin="$TMP_ROOT/remote-bin" out status
  addon_home "$primary" 'Robin\n'
  mkdir -p "$primary/data" "$mate/config" "$fakebin"
  printf -- '- remote-words - Test route (host: words-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-31)\n' \
    "$ROOT" "$mate" > "$primary/data/secondmates.md"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = words-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fakebin/ssh"
  remote_push() {
    FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$primary/config" \
      FM_DATA_OVERRIDE="$primary/data" FM_INHERITABLE_CONFIG="launch-env-allowlist leak-words.inherited" \
      FM_SSH_BIN="$fakebin/ssh" "$ROOT/bin/fm-remote-inherit-push.sh" remote-words "$1" 2>&1
  }
  printf 'FM_FIRST\n' > "$primary/config/launch-env-allowlist"
  out=$(remote_push 1); status=$?
  [ "$status" -eq 0 ] || fail "the remote push failed: $out"
  grep -qx Robin "$mate/config/leak-words.inherited" || fail "the remote route did not inherit the add-on's word: $out"

  printf 'path = projects/missing-addon\n' > "$primary/config/addon"
  printf 'FM_SECOND\n' > "$primary/config/launch-env-allowlist"
  out=$(remote_push 2); status=$?
  [ "$status" -eq 0 ] || fail "an unusable add-on failed the whole remote push: $out"
  [ "$(cat "$mate/config/launch-env-allowlist")" = FM_SECOND ] \
    || fail "an unusable add-on stopped another inherited item on the remote route: $out"
  grep -qx Robin "$mate/config/leak-words.inherited" \
    || fail "an unusable add-on shrank the remote secondmate's inherited list: $out"
  assert_contains "$out" "error: config/leak-words.inherited" "the remote push did not name the word list problem"
  assert_not_contains "$out" "Robin" "the remote push printed a word"
  pass "leak guard: the remote route keeps the inherited list and converges the rest while the add-on is unusable"
}

# cap <word>: the word with a capital first letter. The invented names below
# are written in small letters here so this file never adds a name-shaped word
# of its own; each test capitalises its name at run time.
cap() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# branch_repo <dir>: make_repo on a main branch, then a feature branch to add to.
branch_repo() {
  make_repo "$1"
  git -C "$1" branch -M main
  git -C "$1" checkout -q -b feature
}

# add_line <repo> <path> <text>: commit one more line to the path.
add_line() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >> "$1/$2"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m add
}

test_new_name_refuses_until_approved() {
  local repo="$TMP_ROOT/names" home="$TMP_ROOT/names-home" name
  name=$(cap qverblox)
  branch_repo "$repo"
  word_home "$home" 'unrelated-word\n'
  add_line "$repo" docs/notes.md "ask $name about the theme."
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 1 ] || fail "a new name in an added line did not refuse: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "LEAK_HIT: new-name: docs/notes.md:3: $name" "the hit did not name the word and where it is"
  assert_contains "$GUARD_OUT" "$home/config/leak-names-approved" "the refusal did not say where an approval is recorded"

  # One approval, in any case, lets it through; the file is never printed.
  printf '# approved once\n%s\n' qverblox > "$home/config/leak-names-approved"
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 0 ] || fail "an approved name still refused: $GUARD_OUT"
  assert_not_contains "$GUARD_OUT" "approved once" "the approvals file was printed"

  # In tests/ too, since a fixture is where a real name slips in.
  add_line "$repo" tests/fm-y.test.sh "run_hook \"$(cap zandrelt) said yes\""
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 1 ] || fail "a new name in a test fixture did not refuse: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "new-name: tests/fm-y.test.sh:1: $(cap zandrelt)" "the fixture name was missed"
  pass "leak guard: a new name refuses, naming the word and line, until the owner approves it once"
}

test_known_words_and_code_identifiers_pass() {
  local repo="$TMP_ROOT/known" home="$TMP_ROOT/known-home"
  branch_repo "$repo"
  word_home "$home" 'unrelated-word\n'
  # Robin and Notes are in the base already (Robin in tests/, notes in small
  # letters); the rest are code identifiers, not name-shaped words.
  add_line "$repo" docs/notes.md 'Robin keeps the Notes; set FM_HOME, call fmLeakGuard, read README and v2Config.'
  add_line "$repo" bin/tool.py "class $(cap qverblox)Panel($(cap base)View): pass"
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 0 ] || fail "known words or code identifiers refused: $GUARD_OUT"
  assert_contains "$GUARD_OUT" "PASS" "a clean branch did not say it passed"

  # Without a list or approvals file, as in CI, the check is silent.
  add_line "$repo" docs/notes.md "ask $(cap qverblox) again."
  guard "$repo" FM_HOME="$TMP_ROOT/known-bare" -- --new-names
  [ "$GUARD_STATUS" -eq 0 ] && [ -z "$GUARD_OUT" ] || fail "the check ran without a list: $GUARD_OUT"
  # An approvals file alone turns it on.
  mkdir -p "$TMP_ROOT/known-approvals/config"
  printf 'unrelated\n' > "$TMP_ROOT/known-approvals/config/leak-names-approved"
  guard "$repo" FM_HOME="$TMP_ROOT/known-approvals" -- --new-names
  [ "$GUARD_STATUS" -eq 1 ] || fail "an approvals file alone did not turn the check on: $GUARD_OUT"

  # A checkout with no main to compare against cannot pass unchecked.
  git -C "$repo" branch -q -m main trunk
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 2 ] || fail "a checkout with no merge base did not refuse: $GUARD_OUT"
  guard "$repo" FM_HOME="$home" -- --new-names --base trunk
  [ "$GUARD_STATUS" -eq 1 ] || fail "--base did not select the merge base: $GUARD_OUT"
  pass "leak guard: words already in the repository and code identifiers pass, and the check is silent without a list"
}

# Invented values only: none of these reaches a real account, number or person.
SHAPE_LINES='ping U0QZXW1234 in the thread.
see https://qverblox-team.slack.com/archives/C0QZXW1234 for it.
record https://app-eu1.hubspot.com/contacts/9990001/record/0-1/42 here.
call +31 6 0000 0000 after nine.
pay NL51 ZZZZ 0123 4567 89 by then.'

test_data_shapes_refuse() {
  local repo="$TMP_ROOT/shapes" home="$TMP_ROOT/shapes-home" kind
  branch_repo "$repo"
  word_home "$home" 'unrelated-word\n'
  add_line "$repo" docs/contact.md "$SHAPE_LINES"
  add_line "$repo" tests/fm-z.test.sh "$SHAPE_LINES"
  guard "$repo" FM_HOME="$home" -- --new-names
  [ "$GUARD_STATUS" -eq 1 ] || fail "customer data shapes in added lines did not refuse: $GUARD_OUT"
  for kind in slack-id slack-link hubspot-link phone iban; do
    assert_contains "$GUARD_OUT" "LEAK_HIT: $kind: docs/contact.md:" "an added $kind was missed"
  done
  assert_not_contains "$GUARD_OUT" "tests/fm-z.test.sh" "a shape in tests/ fixtures refused"

  # The full scan CI runs refuses each shape too, with no list at all.
  guard "$repo"
  [ "$GUARD_STATUS" -eq 1 ] || fail "the full scan passed customer data shapes: $GUARD_OUT"
  for kind in slack-id slack-link hubspot-link phone iban; do
    assert_contains "$GUARD_OUT" "LEAK_HIT: $kind: docs/contact.md:" "the full scan missed the $kind"
  done
  assert_not_contains "$GUARD_OUT" "tests/fm-z.test.sh" "the full scan refused a shape in tests/"

  # Look-alikes pass: a broken IBAN check digit, a time zone, a version, a shared
  # Slack host and a word in capitals with a digit.
  printf 'NL50 ZZZZ 0123 4567 89, UTC+0100, +1.2.3, https://app.slack.com/client, CONTAINER2\n' > "$repo/docs/contact.md"
  git -C "$repo" add -A
  guard "$repo"
  [ "$GUARD_STATUS" -eq 0 ] || fail "look-alikes of customer data refused: $GUARD_OUT"
  pass "leak guard: Slack ids and links, HubSpot links, phone numbers and IBANs refuse outside tests/, look-alikes pass"
}

test_no_list_scans_as_before
test_listed_word_fails_in_tests
test_partial_words_do_not_hit
test_list_found_from_home_and_from_a_task_worktree
test_list_found_from_a_validation_copy
test_private_words_mode
test_vendor_bot_emails_pass
test_addon_list_adds_words
test_secondmate_inherits_merged_list
test_remote_route_keeps_list_on_unusable_addon
test_new_name_refuses_until_approved
test_known_words_and_code_identifiers_pass
test_data_shapes_refuse

echo "# fm-leak-guard.test.sh: all assertions passed"

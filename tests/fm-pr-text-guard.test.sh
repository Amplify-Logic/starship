#!/usr/bin/env bash
# tests/fm-pr-text-guard.test.sh - keeping a home's private words out of the
# text a worker publishes to a public repository's pull requests: the draft
# check (bin/fm-leak-guard.sh --text), the Claude worker hook that refuses a
# publishing command (bin/fm-pr-text-guard.py), the hook bin/fm-spawn.sh
# installs, and the instruction the ship brief carries. Only gh is faked, so
# no case reaches the network; it answers public for a repository named in
# FAKE_GH_PUBLIC, private for one named in FAKE_GH_PRIVATE_REPOS, otherwise
# from FAKE_GH_PRIVATE, and logs every call.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LEAK="$ROOT/bin/fm-leak-guard.sh"
HOOK="$ROOT/bin/fm-pr-text-guard.py"
TMP_ROOT=$(fm_test_tmproot fm-pr-text-guard)

command -v python3 >/dev/null 2>&1 || fail "python3 is required"

HOME_WORDS="$TMP_ROOT/home"
mkdir -p "$HOME_WORDS/config"
printf '# people\nRobin\nacme corp\n' > "$HOME_WORDS/config/leak-words"
NO_LIST="$TMP_ROOT/no-list-home"
mkdir -p "$NO_LIST/config"

FAKEBIN="$TMP_ROOT/fakebin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[ "${1:-} ${2:-}" = "repo view" ] || exit 0
# The second answer line is the repository's owner/repo: the one named, else
# FAKE_GH_DEFAULT_REPO for gh's default in the working directory.
name=${3:-}
case "$name" in --*|'') name=${FAKE_GH_DEFAULT_REPO:-o/default} ;; esac
case " ${FAKE_GH_PUBLIC:-} " in
  *" ${3:-} "*) printf 'false\n%s\n' "$name"; exit 0 ;;
esac
case " ${FAKE_GH_PRIVATE_REPOS:-} " in
  *" ${3:-} "*) printf 'true\n%s\n' "$name"; exit 0 ;;
esac
if [ "${FAKE_GH_PRIVATE:-}" = unreadable ]; then
  echo "HTTP 404: Not Found" >&2
  exit 1
fi
printf '%s\n%s\n' "${FAKE_GH_PRIVATE:-false}" "$name"
EOF
chmod +x "$FAKEBIN/gh"

WORK="$TMP_ROOT/work"
mkdir -p "$WORK"

# leak_text <home> [args...]: the draft check, run from WORK; output in OUT,
# status in STATUS. Stdin is passed through.
leak_text() {
  local home=$1
  shift
  STATUS=0
  OUT=$(cd "$WORK" && FM_HOME="$home" "$LEAK" --text "$@" 2>&1) || STATUS=$?
}

# hook <home> <command> [cwd]: the PreToolUse hook on that Bash command; its
# stdout in OUT. FAKE_GH_PRIVATE is inherited.
hook() {
  local home=$1 command=$2 cwd=${3:-$WORK}
  OUT=$(jq -cn --arg c "$command" --arg cwd "$cwd" \
      '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}' \
    | PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$GH_LOG" python3 "$HOOK" hook --home "$home") \
    || fail "the hook exited nonzero for: $command"
}

expect_allow() {  # <home> <command> <why> [cwd]
  hook "$1" "$2" "${4:-}"
  assert_equals "" "$OUT" "$3"
}

# expect_refuse <home> <command> <why> [cwd]: the deny reason in REASON.
expect_refuse() {
  hook "$1" "$2" "${4:-}"
  [ -n "$OUT" ] || fail "$3 (got no output)"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' \
    >/dev/null || fail "$3 (got: $OUT)"
  REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
}

test_draft_check_places_each_listed_word() {
  printf 'Fix the sync that robin reported\n' > "$WORK/title.txt"
  printf 'Body\n\nAsked by ACME Corp, and Robin again.\n' > "$WORK/body.md"
  leak_text "$HOME_WORDS" title.txt
  [ "$STATUS" -eq 1 ] || fail "a title with a listed word must fail: $OUT"
  assert_contains "$OUT" "LEAK_HIT: private-word: title.txt:1:19" "the hit must name the file, line and column"
  assert_contains "$OUT" "1 word from the private word list" "the failure must count the words"
  assert_not_contains "$OUT" "robin" "the check must never print a listed word"
  leak_text "$HOME_WORDS" body.md
  [ "$STATUS" -eq 1 ] || fail "a body with listed words must fail: $OUT"
  assert_contains "$OUT" "body.md:3:10" "a listed phrase must be found whatever its case"
  assert_contains "$OUT" "body.md:3:25" "every listed word must be placed"
  assert_contains "$OUT" "2 words from the private word list" "the failure must count every word"
  assert_contains "$OUT" "rewrite it without them" "the failure must say what to do"
  assert_not_contains "$OUT" "ACME" "the check must never print a listed phrase"
  assert_not_contains "$OUT" "Robin" "the check must never print a listed word"
  STATUS=0
  OUT=$(printf 'Thanks, Robin - looks good.\n' | FM_HOME="$HOME_WORDS" "$LEAK" --text 2>&1) || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "a comment on stdin with a listed word must fail: $OUT"
  assert_contains "$OUT" "LEAK_HIT: private-word: stdin:1:9" "stdin must be named as the source"
  [ "$(printf '%s\n' "$OUT" | grep -c '^LEAK_HIT')" -eq 1 ] || fail "a word must be placed once: $OUT"
  # Checking the word list file itself never prints the list.
  leak_text "$HOME_WORDS" "$HOME_WORDS/config/leak-words"
  [ "$STATUS" -eq 1 ] || fail "the word list checked as a draft must fail: $OUT"
  assert_not_contains "$OUT" "Robin" "checking the word list must not print its words"
  assert_not_contains "$OUT" "robin" "checking the word list must not print its words"
  pass "the draft check places and counts every listed word in a title, body or comment, never printing one"
}

test_draft_check_finds_token_shapes() {
  local key
  # Built at run time so this file holds no token shape.
  key="$(printf 'sk')_live_$(printf 'q9Z%.0s' 1 2 3 4 5 6 7)"
  printf 'Deploy notes\nSTRIPE_SECRET_API_KEY=%s\n' "$(printf 'Q1w2E3r4%.0s' 1 2 3)" > "$WORK/keys.md"
  printf 'paste %s here\n' "$key" > "$WORK/stripe.md"
  for home in "$HOME_WORDS" "$NO_LIST"; do
    leak_text "$home" keys.md stripe.md
    [ "$STATUS" -eq 1 ] || fail "draft text holding token shapes must fail in $home: $OUT"
    assert_contains "$OUT" "LEAK_HIT: token: keys.md:2:15" "an API key assignment in capitals must be found"
    assert_contains "$OUT" "LEAK_HIT: token: stripe.md:1:7" "a Stripe live key must be found"
    assert_contains "$OUT" "2 token shapes" "the failure must count the tokens"
    assert_not_contains "$OUT" "Q1w2E3r4" "the check must never print a token"
    assert_not_contains "$OUT" "$key" "the check must never print a token"
  done
  leak_text "$NO_LIST" title.txt
  [ "$STATUS" -eq 0 ] || fail "a clean text in a home with no list must pass: $OUT"
  assert_equals "" "$OUT" "a clean text in a home with no list must say nothing"
  pass "the draft check finds and places token shapes, with or without a word list, never printing one"
}

test_draft_check_passes_clean_text_and_partial_words() {
  printf 'The robins-egg theme and acme corporation stay.\n' > "$WORK/clean.md"
  leak_text "$HOME_WORDS" clean.md
  [ "$STATUS" -eq 0 ] || fail "words only inside longer words must pass: $OUT"
  assert_contains "$OUT" "PASS" "a clean text must say it passed"
  STATUS=0
  OUT=$(printf 'clean\n' | FM_HOME="$HOME_WORDS" "$LEAK" --text - 2>&1) || STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "clean stdin must pass: $OUT"
  STATUS=0
  OUT=$(cd "$WORK" && printf 'clean\n' | FM_HOME="$HOME_WORDS" "$LEAK" --text - clean.md 2>&1) || STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "clean stdin and a clean file must pass: $OUT"
  [ -f "$WORK/clean.md" ] || fail "checking stdin before a file must not delete the file"
  leak_text "$HOME_WORDS" missing.md
  [ "$STATUS" -eq 2 ] || fail "an unreadable draft must not pass as clean: $OUT"
  pass "the draft check passes clean text and words that only appear inside longer words"
}

test_draft_check_without_a_list_is_silent() {
  leak_text "$NO_LIST" body.md
  [ "$STATUS" -eq 0 ] || fail "a home with no list must pass: $OUT"
  assert_equals "" "$OUT" "a home with no list must check nothing and say nothing"
  pass "the draft check passes silently in a home with no list"
}

test_hook_refuses_title_body_and_comment_on_a_public_repo() {
  export FAKE_GH_PRIVATE=false
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/public --title "Sync fix for Robin" --body "Details"' \
    "a listed word in a PR title must be refused"
  assert_contains "$REASON" "contains 1 word from this home's private word list (the command, line 1)" \
    "the refusal must count the word and say where it is"
  assert_not_contains "$REASON" "Robin" "the refusal must never name the word"
  assert_contains "$REASON" "o/public, a public repository" "the refusal must name the public repository"
  assert_contains "$REASON" "--text <file>" "the refusal must say how to check a draft"
  expect_refuse "$HOME_WORDS" "gh-axi pr edit 7 --repo o/public --body-file $WORK/body.md" \
    "a listed word in a body file must be refused"
  assert_contains "$REASON" "2 words from this home's private word list" "every listed word in the file must be counted"
  assert_contains "$REASON" "body.md, line 3)" "the refusal must name the file and line the words are on"
  assert_not_contains "$REASON" "ACME" "the refusal must never name a listed phrase"
  expect_refuse "$HOME_WORDS" 'gh pr create -R o/public -t "Sync fix" -F body.md' \
    "a body file given with -F must be read relative to the working directory"
  expect_refuse "$HOME_WORDS" "gh pr comment 7 --repo o/public --body \"\$(cat <<'X'
Thanks robin
X
)\"" "a listed word in a heredoc comment must be refused"
  # shellcheck disable=SC2016 # The variable expands inside the checked command, not here.
  expect_refuse "$HOME_WORDS" 'BODY="acme corp asked"; gh issue comment 3 --repo o/public --body "$BODY"' \
    "a word set in a variable earlier in the same command must be refused"
  expect_refuse "$HOME_WORDS" 'gh api repos/o/public/issues/3/comments -f body="hi Robin"' \
    "a comment sent through gh api must be refused"
  assert_contains "$REASON" "o/public" "the API path must name the repository"
  unset FAKE_GH_PRIVATE
  pass "a Claude worker's PR title, body and comment with a listed word are refused on a public repository"
}

test_hook_refuses_token_shapes_and_never_prints_a_listed_word() {
  local key
  export FAKE_GH_PRIVATE=false
  # Built at run time so this file holds no token shape.
  key="gl$(printf 'pat')-$(printf 'Xy7%.0s' 1 2 3 4 5 6 7)"
  for home in "$HOME_WORDS" "$NO_LIST"; do
    expect_refuse "$home" "gh pr comment 7 --repo o/public --body 'use $key for the mirror'" \
      "a token shape in a comment must be refused, with or without a word list"
    assert_contains "$REASON" "contains 1 live key or token shape (the command, line 1)" \
      "the refusal must count the token and say where it is"
    assert_not_contains "$REASON" "$key" "the refusal must never print the token"
  done
  # The command a reviewer once ran: a gh api call beside a grep that named the
  # word list file. The refusal places the words and prints none of them.
  expect_refuse "$HOME_WORDS" \
    "gh api repos/o/public/issues/3/comments -f body=done; grep -c x $HOME_WORDS/config/leak-words" \
    "a publishing command that names the word list file must be refused"
  assert_contains "$REASON" "leak-words, lines 2 and 3)" "the refusal must say the words are in the named list file"
  assert_not_contains "$REASON" "Robin" "the refusal must not print the word list"
  assert_not_contains "$REASON" "ACME" "the refusal must not print the word list"
  unset FAKE_GH_PRIVATE
  pass "a token shape is refused on a public repository with or without a list, and a refusal never prints a word or token"
}

# A file a publishing command merely names, such as a test fixture holding
# synthetic keys, is not published, so its token shapes do not count; a file
# it sends as content does.
test_hook_checks_token_shapes_only_in_sent_files() {
  local key home
  export FAKE_GH_PRIVATE=false
  # Built at run time so this file holds no token shape.
  key="gl$(printf 'pat')-$(printf 'Xy7%.0s' 1 2 3 4 5 6 7)"
  mkdir -p "$WORK/tests"
  printf 'redact %s\nand %s\n' "$key" "$key" > "$WORK/tests/redaction.test.sh"
  for home in "$HOME_WORDS" "$NO_LIST"; do
    expect_allow "$home" 'gh pr create --repo o/public --title "Cover redaction" --body "Adds a case to tests/redaction.test.sh"' \
      "a body that only mentions a fixture with synthetic keys must pass in $home"
    expect_refuse "$home" 'gh pr create --repo o/public --title "Cover redaction" --body-file tests/redaction.test.sh' \
      "a fixture sent with --body-file must have its token shapes checked in $home"
    assert_contains "$REASON" "2 live key or token shapes (" "the refusal must count the sent file's tokens"
    assert_contains "$REASON" "redaction.test.sh, lines 1 and 2)" "the refusal must place the sent file's tokens"
    assert_not_contains "$REASON" "$key" "the refusal must never print a token"
    expect_refuse "$home" 'gh pr comment 7 --repo o/public -F tests/redaction.test.sh' \
      "a fixture sent with -F must have its token shapes checked in $home"
    expect_refuse "$home" 'gh pr comment 7 --repo o/public --body-file=tests/redaction.test.sh' \
      "a fixture sent with --body-file= must have its token shapes checked in $home"
    expect_refuse "$home" 'gh api repos/o/public/issues/3/comments --input tests/redaction.test.sh' \
      "a fixture sent with --input must have its token shapes checked in $home"
    expect_refuse "$home" 'gh api repos/o/public/issues/3/comments -f "body=@tests/redaction.test.sh"' \
      "a fixture sent as an @file field must have its token shapes checked in $home"
    # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
    expect_refuse "$home" 'gh pr create --repo o/public -t x --body "$(cat tests/redaction.test.sh)"' \
      "a fixture sent through \$(cat file) must have its token shapes checked in $home"
    # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
    expect_refuse "$home" 'gh pr create --repo o/public -t x --body "$(<tests/redaction.test.sh)"' \
      "a fixture sent through \$(<file) must have its token shapes checked in $home"
    # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
    expect_refuse "$home" 'gh pr create --repo o/public -t x --body "$(< tests/redaction.test.sh)"' \
      "a fixture sent through \$(< file) must have its token shapes checked in $home"
    # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
    expect_refuse "$home" 'gh pr comment 7 --repo o/public --body-file - <<EOF
See $(cat tests/redaction.test.sh)
EOF' "a \$(cat file) in an unquoted heredoc body runs, so its tokens must be checked in $home"
    # shellcheck disable=SC2016 # The substitution is quoted text in the checked command.
    expect_allow "$home" "gh pr comment 7 --repo o/public --body 'Reproduce with \$(cat tests/redaction.test.sh)'" \
      "a cat inside single quotes is only mentioned, so it must stay words-only in $home"
    # shellcheck disable=SC2016 # The backticks are quoted text in the checked command.
    expect_allow "$home" "gh pr comment 7 --repo o/public --body-file - <<'EOF'
Reproduce with \`cat tests/redaction.test.sh\`
EOF" "a cat inside a quoted heredoc body is only mentioned, so it must stay words-only in $home"
    # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
    expect_refuse "$home" 'gh pr comment 7 --repo o/public --body "`cat tests/redaction.test.sh`"' \
      "a fixture sent through a backtick cat must have its token shapes checked in $home"
    expect_refuse "$home" 'gh pr comment 7 --repo o/public --body-file - < tests/redaction.test.sh' \
      "a fixture redirected into --body-file - must have its token shapes checked in $home"
    expect_refuse "$home" 'gh api repos/o/public/issues/3/comments --input - < tests/redaction.test.sh' \
      "a fixture redirected into --input - must have its token shapes checked in $home"
    expect_refuse "$home" 'cat tests/redaction.test.sh | gh pr comment 7 --repo o/public --body-file -' \
      "a fixture piped from cat into --body-file - must have its token shapes checked in $home"
    assert_contains "$REASON" "2 live key or token shapes (" "the piped file's tokens must be counted"
    expect_allow "$home" 'cat tests/redaction.test.sh | wc -l; gh pr comment 7 --repo o/public --body "Counted"' \
      "a fixture piped into another command is not sent in $home"
  done
  expect_allow "$NO_LIST" 'gh pr create --repo o/public --fill && cat tests/redaction.test.sh' \
    "a home with no list must pass --fill even when the command names a fixture with synthetic keys"
  printf 'redact %s for Robin\n' "$key" > "$WORK/tests/named.test.sh"
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/public --title "Cover redaction" --body "See tests/named.test.sh"' \
    "a listed word in a merely named file must still be refused"
  assert_contains "$REASON" "contains 1 word from this home's private word list (" "the named file's word must count"
  assert_not_contains "$REASON" "token shape" "the named file's token shape must not count"
  unset FAKE_GH_PRIVATE
  pass "token shapes count only in the command and the files it sends, while a named file's listed words still count"
}

test_hook_reads_body_files_however_they_are_named() {
  export FAKE_GH_PRIVATE=false
  printf 'Thanks Robin\n' > "$WORK/pr.md"
  # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/public -t x --body "$(cat pr.md)"' \
    "a body read through \$(cat file) must be checked"
  expect_refuse "$HOME_WORDS" 'gh pr comment 7 --repo o/public --body-file - < pr.md' \
    "a body redirected into --body-file - must be checked"
  expect_refuse "$HOME_WORDS" 'cat pr.md | gh pr comment 7 --repo o/public --body-file -' \
    "a body piped into --body-file - must be checked"
  # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
  expect_refuse "$HOME_WORDS" 'gh api repos/o/public/issues/3/comments -F "body=@pr.md"' \
    "a field read from a file must be checked"
  for fill in --fill -f --fill-first --fill-verbose; do
    expect_refuse "$HOME_WORDS" "gh pr create --repo o/public $fill" \
      "gh pr create $fill takes unchecked commit messages and must be refused on a public repository"
    assert_contains "$REASON" "--fill" "the refusal must name --fill as the reason"
  done
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/public -fd' "a --fill combined with other short flags must count"
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/public --fill=true' "a --fill given a value must count"
  expect_allow "$HOME_WORDS" 'git push -f origin fm/x && gh pr create --repo o/public --title t --body-file clean.md' \
    "a -f given to another command is not --fill"
  expect_allow "$HOME_WORDS" 'gh pr create --repo o/public --title "Fix lock" --body "Stop calling rm -f on the lock"' \
    "a -f inside the body text is not --fill"
  expect_refuse "$HOME_WORDS" 'gh pr new --repo o/public --fill' "the pr new alias with --fill must count"
  expect_refuse "$HOME_WORDS" 'gh pr -R o/public create --fill' "a --fill after a repo flag between pr and create must count"
  assert_contains "$REASON" "--fill" "the refusal must name --fill as the reason"
  expect_refuse "$HOME_WORDS" 'gh pr --repo=o/public new --fill' "a --fill after --repo= between pr and new must count"
  expect_refuse "$HOME_WORDS" "gh pr create --repo o/public --fill # it's ready" \
    "a --fill whose command cannot be parsed because of a trailing comment must still be refused"
  assert_contains "$REASON" "--fill" "the refusal must name --fill as the reason"
  expect_refuse "$HOME_WORDS" "# it's ready
gh pr create --fill --repo o/public" "a --fill whose command cannot be parsed because of a comment line must still be refused"
  assert_contains "$REASON" "--fill" "the refusal must name --fill as the reason"
  expect_refuse "$HOME_WORDS" 'gh pr new --repo o/public --title "Fix for Robin" --body x' \
    "a listed word through the pr new alias must be refused"
  expect_refuse "$HOME_WORDS" 'gh issue new --repo o/public --title "Fix for Robin" --body x' \
    "a listed word through the issue new alias must be refused"
  expect_refuse "$HOME_WORDS" 'gh pr reopen 7 --repo o/public --comment "reopening for Robin"' \
    "a reopening comment on a PR must be checked"
  expect_refuse "$HOME_WORDS" 'gh issue reopen 3 --repo o/public --comment "reopening for Robin"' \
    "a reopening comment on an issue must be checked"
  export FAKE_GH_PRIVATE=true
  expect_allow "$HOME_WORDS" 'gh pr create --repo o/work --fill' "--fill may publish to a private repository"
  unset FAKE_GH_PRIVATE
  expect_allow "$NO_LIST" 'gh pr create --repo o/public --fill' "--fill passes in a home with no list"
  pass "body files read through \$(cat), a redirect, a pipe or field=@file are checked, and --fill is refused on a public repository"
}

test_hook_finds_the_repository_from_urls_and_gh_repo() {
  export FAKE_GH_PRIVATE=true FAKE_GH_PUBLIC="github.com/o/public o/public"
  expect_refuse "$HOME_WORDS" 'gh pr comment https://github.com/o/public/pull/7 --body "thanks Robin"' \
    "a PR URL on a public repository must be the target, not the private working directory"
  assert_contains "$REASON" "github.com/o/public, a public repository" "the refusal must name the URL's repository"
  expect_refuse "$HOME_WORDS" 'gh issue comment https://github.com/o/public/issues/3 --body "thanks Robin"' \
    "an issue URL must be the target"
  expect_refuse "$HOME_WORDS" 'GH_REPO=o/public gh pr comment 7 --body "thanks Robin"' \
    "a GH_REPO assignment must be the target"
  expect_refuse "$HOME_WORDS" 'gh api -X POST repos/o/public/issues/3/comments -f body="thanks Robin"' \
    "the gh api endpoint after a flag and its value must be the target"
  expect_allow "$HOME_WORDS" 'gh pr comment https://github.com/o/work/pull/7 --body "thanks Robin"' \
    "a URL on a private repository may hold listed words"
  export FAKE_GH_PRIVATE=false FAKE_GH_PUBLIC='' FAKE_GH_PRIVATE_REPOS="github.com/o/private o/private"
  expect_refuse "$HOME_WORDS" 'gh pr comment 7 --body "Follows https://github.com/o/private/pull/3, thanks Robin"' \
    "a private URL in the body text must not replace the public repository the comment reaches"
  assert_contains "$REASON" "the repository this command reaches, a public repository" "the refusal must name gh's default"
  expect_refuse "$HOME_WORDS" 'gh issue comment 3 --body "see repos/o/private/pulls and GH_REPO=o/private, thanks Robin"' \
    "an API path or GH_REPO in the body text must not replace the target"
  export FAKE_GH_PRIVATE=true FAKE_GH_PUBLIC="github.com/o/public o/public" FAKE_GH_PRIVATE_REPOS=''
  expect_refuse "$HOME_WORDS" 'gh pr review --approve https://github.com/o/public/pull/7 --body "thanks Robin"' \
    "a PR URL after a flag must still be the target"
  expect_refuse "$HOME_WORDS" "gh pr comment 7 --repo o/public --body-file - <<'EOF'
It's fixed, thanks Robin
EOF" "a command whose words cannot be parsed must not fall back to the private default"
  assert_contains "$REASON" "could not read which repository" "the refusal must say the target is unknown"
  assert_not_contains "$REASON" "blocked:" "an unparsable command must be rewritten, not stop the worker"
  assert_contains "$REASON" "unmatched quote in a heredoc or comment" "the refusal must say why the command could not be read"
  assert_contains "$REASON" "--body-file <file> and an explicit --repo" "the refusal must say how to make the command readable"
  expect_refuse "$HOME_WORDS" 'gh pr -Ro/public comment 7 --body "thanks Robin"' \
    "a repo flag with its value attached must still be checked"
  assert_contains "$REASON" "o/public, a public repository" "the refusal must name the attached repository"
  expect_refuse "$HOME_WORDS" 'gh pr comment 7 -R=o/public --body "thanks Robin"' \
    "a repo flag attached with = must still be checked"
  assert_contains "$REASON" "to o/public, a public repository" "the refusal must name the repository without the ="
  expect_refuse "$HOME_WORDS" "# post it; it's for the PR
gh pr comment 7 --repo o/private --body \"thanks Robin\"" "an apostrophe in a comment line makes the command unparsable"
  assert_contains "$REASON" "could not read which repository" "the refusal must say the target is unknown"
  expect_refuse "$HOME_WORDS" "gh pr comment 7 --repo o/private --body 'Tracked in
#12'
gh pr comment 3 --repo o/public --body-file - <<'EOF'
Thanks Robin, it's merged
EOF" "a quoted line starting with # must not hide a later public comment"
  expect_refuse "$HOME_WORDS" 'gh pr create --title Fix#12 --body "thanks Robin" --repo o/public' \
    "a # inside a word must not hide the --repo after it"
  assert_contains "$REASON" "o/public, a public repository" "the refusal must name the repository after the #"
  expect_refuse "$HOME_WORDS" 'timeout 60 gh pr comment 7 --repo o/public --body "thanks Robin"' \
    "a gh word behind a wrapper must still be checked against its --repo"
  # shellcheck disable=SC2016 # The loop variable expands inside the checked command, not here.
  expect_refuse "$HOME_WORDS" 'for n in 7 8; do GH_REPO=o/public gh pr comment $n --body "thanks Robin"; done' \
    "a gh word behind a reserved word must still be checked against its GH_REPO"
  expect_refuse "$HOME_WORDS" "gh pr list --json number -q '.[].number' | while read n; do gh pr comment \"\$n\" --repo o/public --body \"thanks Robin\"; done" \
    "a gh word inside a while-read loop must still be checked against its --repo"
  expect_refuse "$HOME_WORDS" 'gh pr view 7 --repo o/private && timeout 60 gh pr comment 7 --repo o/public --body "thanks Robin"' \
    "a private repository read first must not hide a public one commented on later"
  assert_contains "$REASON" "o/public, a public repository" "the refusal must name the public repository"
  unset FAKE_GH_PRIVATE FAKE_GH_PUBLIC FAKE_GH_PRIVATE_REPOS
  pass "a PR or issue URL, GH_REPO and the gh api endpoint name repositories the text reaches, and body text never hides one"
}

test_hook_refuses_the_pipeline_intent_on_a_public_github_repo() {
  local repo="$TMP_ROOT/nm-repo" other="$TMP_ROOT/nm-other"
  git init -q "$repo" && git -C "$repo" remote add origin git@github.com:o/public.git
  git init -q "$other" && git -C "$other" remote add origin https://gitlab.example/o/work.git
  export FAKE_GH_PRIVATE=false
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "a listed word in the pipeline intent must be refused" "$repo"
  assert_contains "$REASON" "o/public" "the refusal must name origin's repository"
  expect_refuse "$HOME_WORDS" 'no-mistakes axi respond --action answer --message "ask acme corp"' \
    "a listed word in a gate answer must be refused" "$repo"
  expect_allow "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "an origin off github.com cannot be checked and must pass" "$other"
  expect_allow "$HOME_WORDS" 'no-mistakes axi run --intent "fix the sync"' "a clean intent must pass" "$repo"
  printf 'Robin wants the sync fixed\n' > "$repo/intent.txt"
  # shellcheck disable=SC2016 # The substitution runs inside the checked command, not here.
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "$(cat intent.txt)"' \
    "an intent read from a file must be checked" "$repo"
  local private="$TMP_ROOT/nm-private"
  git init -q "$private" && git -C "$private" remote add origin git@github.com:o/private.git
  FAKE_GH_PRIVATE_REPOS=o/private expect_allow "$HOME_WORDS" \
    'no-mistakes axi run --intent "Robin wants the worker to run gh pr comment after the merge"' \
    "a gh command named inside a private origin's intent must not stop the pipeline" "$private"
  expect_allow "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the worker to run gh pr comment after the merge"' \
    "a gh command named inside the intent of an origin off GitHub must not be checked" "$other"
  local alias="$TMP_ROOT/nm-alias" bare="$TMP_ROOT/nm-bare" dotless="$TMP_ROOT/nm-dotless"
  git init -q "$alias" && git -C "$alias" remote add origin git@github-work:o/public.git
  git init -q "$dotless" && git -C "$dotless" remote add origin git@work:o/public.git
  git init -q "$bare"
  git -C "$repo" remote add upstream git@github.com:o/private.git
  : > "$GH_LOG"
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "origin on github.com must be checked by name, whatever gh's default is" "$repo"
  assert_equals "repo view o/public --json isPrivate,nameWithOwner --jq .isPrivate, .nameWithOwner" "$(cat "$GH_LOG")" "gh must read origin's repository by name"
  : > "$GH_LOG"
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "an origin behind an SSH host alias must be checked by its owner/repo" "$alias"
  assert_equals "repo view o/public --json isPrivate,nameWithOwner --jq .isPrivate, .nameWithOwner" "$(cat "$GH_LOG")" "gh must read the aliased origin by name"
  : > "$GH_LOG"
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "a dotless SSH alias that does not name GitHub must still be checked" "$dotless"
  assert_equals "repo view o/public --json isPrivate,nameWithOwner --jq .isPrivate, .nameWithOwner" "$(cat "$GH_LOG")" "gh must read the dotless alias by name"
  export FAKE_GH_PRIVATE=true
  expect_allow "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "an aliased origin gh reads as private may hold listed words" "$alias"
  unset FAKE_GH_PRIVATE
  expect_refuse "$HOME_WORDS" 'no-mistakes axi run --intent "Robin wants the sync fixed"' \
    "a checkout with no origin cannot be told apart and must be refused" "$bare"
  assert_contains "$REASON" "origin remote" "the refusal must name the unreadable origin"
  pass "the pipeline intent and gate answers are checked against origin's repository on GitHub, however origin is named"
}

test_hook_passes_clean_private_and_unrelated_commands() {
  : > "$GH_LOG"
  export FAKE_GH_PRIVATE=false
  expect_allow "$HOME_WORDS" 'gh pr create --repo o/public --title "Sync fix" --body "Details"' "clean text must pass"
  assert_equals "" "$(cat "$GH_LOG")" "a clean command must cost no visibility read"
  for command in 'gh pr view 7 --repo o/public --comments' 'grep -rn Robin docs' 'git commit -m "Robin"' \
    'gh api repos/o/public/pulls/7' 'gh pr list --search "Robin"'; do
    expect_allow "$HOME_WORDS" "$command" "a command that publishes nothing must pass: $command"
  done
  export FAKE_GH_PRIVATE=true
  expect_allow "$HOME_WORDS" 'gh pr create --repo o/work --title "Sync fix for Robin" --body x' \
    "a private repository may hold listed words"
  export FAKE_GH_PRIVATE=unreadable
  expect_refuse "$HOME_WORDS" 'gh pr create --repo o/gone --title "Sync fix for Robin" --body x' \
    "an unreadable visibility must refuse"
  assert_contains "$REASON" "could not confirm the repository is private" "the refusal must say why"
  assert_contains "$REASON" "HTTP 404" "the refusal must carry gh's reason"
  assert_contains "$REASON" "1 word from this home's private word list (the command, line 1)" "the refusal must place the listed word"
  assert_not_contains "$REASON" "Robin" "the refusal must never name the listed word"
  assert_contains "$REASON" "o/gone: gh repo view failed" "the refusal must name the unreadable repository"
  assert_contains "$REASON" "Rewrite those lines without it" "the refusal must say how to retry"
  assert_contains "$REASON" "blocked:" "a private repository that cannot be read must leave the worker a way to stop"
  assert_not_contains "$REASON" "explicit --repo" "an unreadable repository must not suggest a retry that cannot help"
  unset FAKE_GH_PRIVATE
  expect_allow "$NO_LIST" 'gh pr create --repo o/public --title "Sync fix for Robin" --body x' \
    "a home with no list must pass everything but a token shape"
  hook "$HOME_WORDS" '' && assert_equals "" "$OUT" "an empty command must pass"
  local long_body
  long_body=$(printf 'A clean sentence about the sync fix and why it holds now. %.0s' $(seq 25))$(printf 'x%.0s' $(seq 300))
  export FAKE_GH_PRIVATE=false
  expect_allow "$HOME_WORDS" "gh pr create --repo o/public --title t --body \"$long_body\"" \
    "a long clean inline body must pass in a home with a list"
  expect_allow "$NO_LIST" "gh pr create --repo o/public --title t --body \"$long_body\"" \
    "a long clean inline body must pass in a home with no list"
  unset FAKE_GH_PRIVATE
  OUT=$(printf 'not json' | python3 "$HOOK" hook --home "$HOME_WORDS") || fail "an unreadable payload must not crash the hook"
  assert_equals "" "$OUT" "an unreadable payload must pass"
  OUT=$(jq -cn '{tool_name: "Read", tool_input: {file_path: "/x/Robin"}}' | python3 "$HOOK" hook --home "$HOME_WORDS")
  assert_equals "" "$OUT" "another tool must pass untouched"
  pass "clean text, private repositories, unrelated commands and a home with no list all pass"
}

test_spawn_installs_the_hook() {
  local case_dir="$TMP_ROOT/spawn" home proj wt fakebin settings cmd
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  printf 'Robin\n' > "$home/config/leak-words"
  fm_git_worktree "$proj" "$wt" "wt-prtext"
  fm_test_spawn_brief "$home" prtext
  fm_test_run_spawn "$home" "$wt" "$fakebin" prtext "$proj" --mode no-mistakes --yolo off >"$case_dir/spawn.out" 2>&1 \
    || fail "a claude spawn failed: $(cat "$case_dir/spawn.out")"
  settings="$wt/.claude/settings.local.json"
  cmd=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command | select(test("fm-pr-text-guard[.]py"))] | if length == 1 then .[0] else error("not exactly one") end' \
    "$settings") || fail "every claude worker must get exactly one PR text hook: $(cat "$settings")"
  OUT=$(jq -cn --arg cwd "$WORK" '{tool_name: "Bash", tool_input: {command: "gh pr create --repo o/public --title \"for Robin\" --body x"}, cwd: $cwd}' \
    | PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$GH_LOG" FAKE_GH_PRIVATE=false bash -c "$cmd")
  assert_contains "$OUT" '"deny"' "the installed hook must read the home's own list and refuse"
  : > "$home/config/leak-words"
  OUT=$(jq -cn --arg cwd "$WORK" '{tool_name: "Bash", tool_input: {command: "gh pr create --repo o/public --title \"for Robin\" --body x"}, cwd: $cwd}' \
    | PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$GH_LOG" FAKE_GH_PRIVATE=false bash -c "$cmd")
  assert_equals "" "$OUT" "the installed hook must read the home's list live"
  pass "every claude worker gets the PR text hook, reading its home's list on every command"
}

# A first mate or second mate session is not spawned, so the tracked
# .claude/settings.json runs the check for it. The registered command runs here
# exactly as Claude Code runs it, from a home that is a copy of this checkout.
test_first_and_second_mate_sessions_get_the_hook() {
  local case_dir="$TMP_ROOT/primary" primary mate task cmd script publish payload
  primary="$case_dir/home"
  mate="$case_dir/mate"
  task="$case_dir/task"
  mkdir -p "$primary/bin" "$primary/config"
  for script in fm-pr-text-pretool-check.sh fm-primary-scope-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh \
    fm-hook-host-lib.sh fm-pr-text-guard.py fm-leak-guard.sh fm-leak-lib.sh fm-leak-shapes.py fm_secret_shapes.py \
    fm-addon.sh fm-timeout-lib.sh; do
    cp "$ROOT/bin/$script" "$primary/bin/"
  done
  printf '# Home\n' > "$primary/AGENTS.md"
  printf '/config/\n/.fm-secondmate-home\n' > "$primary/.gitignore"
  git -C "$primary" init -q
  git -C "$primary" add -A
  git -C "$primary" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git -C "$primary" worktree add -q --detach "$mate" HEAD
  git -C "$primary" worktree add -q --detach "$task" HEAD
  mkdir -p "$mate/config"
  printf 'mate-1\n' > "$mate/.fm-secondmate-home"
  printf 'Robin\n' > "$primary/config/leak-words"
  printf 'Robin\n' > "$mate/config/leak-words"
  cmd=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("fm-pr-text-pretool-check[.]sh"))] | if length == 1 then .[0] else error("not exactly one") end' \
    "$ROOT/.claude/settings.json") || fail "the tracked Claude settings must register the PR text check exactly once"
  publish='gh pr create --repo o/public --title "for Robin" --body x'

  # session <project dir> [env...]: the registered hook on the publishing
  # command, as a session in that directory; output in OUT.
  session() {
    local dir=$1
    shift
    payload=$(jq -cn --arg c "$publish" --arg cwd "$WORK" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}')
    OUT=$(printf '%s' "$payload" | env -u FM_TASK_ID -u FM_HOME PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$GH_LOG" \
      FAKE_GH_PRIVATE=false CLAUDE_PROJECT_DIR="$dir" "$@" bash -c "$cmd") || fail "the hook exited nonzero in $dir"
  }

  session "$primary"
  assert_contains "$OUT" '"deny"' "a first mate session must have its publishing command checked"
  assert_contains "$OUT" "1 word from this home's private word list (the command, line 1)" \
    "the first mate's refusal must count the word and place it"
  assert_not_contains "$OUT" "Robin" "the first mate's refusal must never name the word"
  session "$mate"
  assert_contains "$OUT" '"deny"' "a second mate session must have its publishing command checked"
  session "$primary" FM_TASK_ID=t-1
  assert_equals "" "$OUT" "a ship or scout worker already has its own check and must not be checked twice"
  session "$task"
  assert_equals "" "$OUT" "a task copy that is not a home must not be checked"
  payload=$(jq -cn --arg c "$publish" '{tool_name: "Bash", tool_input: {command: $c}, cursor_version: "1"}')
  OUT=$(printf '%s' "$payload" | env -u FM_TASK_ID -u FM_HOME PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$GH_LOG" \
    FAKE_GH_PRIVATE=false CLAUDE_PROJECT_DIR="$primary" bash -c "$cmd")
  assert_equals "" "$OUT" "a payload Cursor delivered must pass, because the check answers only in Claude's shape"
  : > "$primary/config/leak-words"
  session "$primary"
  assert_equals "" "$OUT" "a first mate with no word list must pass a clean command"
  pass "the tracked Claude settings check a first mate's and a second mate's PR text, and leave workers and other copies alone"
}

test_ship_brief_tells_the_worker_to_check() {
  local home="$TMP_ROOT/brief-home" id brief check
  mkdir -p "$home/data" "$home/config"
  printf 'Robin\n' > "$home/config/leak-words"
  for id_mode in "brief-prtext-nm:no-mistakes" "brief-prtext-direct:direct-PR"; do
    id=${id_mode%%:*}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "${id_mode##*:}" >/dev/null 2>&1 \
      || fail "$id: scaffold failed"
    brief="$home/data/$id/brief.md"
    assert_grep "## Public PR text" "$brief" "$id: brief missing the PR text instruction"
    assert_grep "issues/<number>/comments" "$brief" "$id: the read-back must cover the PR's comments"
    assert_grep "pulls/<number>/comments" "$brief" "$id: the read-back must cover review comments"
    # shellcheck disable=SC2016 # The pattern matches literal backticks in the brief.
    check=$(sed -n 's/.*and run `\(.*\) --text <file>`.*/\1/p' "$brief")
    [ -n "$check" ] || fail "$id: brief does not name the check command"
    OUT=$(printf 'for robin\n' | bash -c "$check --text" 2>&1) && fail "$id: the brief's command must find the home's word: $OUT"
    assert_contains "$OUT" "stdin:1:5" "$id: the brief's command must read this home's list"
  done
  assert_grep "The one exception to keeping the captain's words" "$home/data/brief-prtext-nm/brief.md" \
    "a no-mistakes brief must state the public-repository exception to the verbatim intent"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-prtext-local some-proj --mode local-only >/dev/null 2>&1 \
    || fail "local-only scaffold failed"
  assert_no_grep "## Public PR text" "$home/data/brief-prtext-local/brief.md" \
    "a local-only brief opens no PR and must not carry the PR text instruction"
  pass "direct-PR and no-mistakes briefs tell the worker to check PR text with this home's list"
}

# cap <word>: the word with a capital first letter. The invented name below is
# written in small letters here so this file never adds a name-shaped word of
# its own; each test capitalises it at run time.
cap() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# A copy of this repository's guard in a checkout whose origin is o/starship-copy,
# so what counts as this repository, and what it already holds, is fixed here.
COPY="$TMP_ROOT/starship-copy"
mkdir -p "$COPY/bin" "$COPY/docs"
cp "$ROOT/bin/fm-pr-text-guard.py" "$ROOT/bin/fm-leak-guard.sh" "$ROOT/bin/fm-leak-lib.sh" \
  "$ROOT/bin/fm-leak-shapes.py" "$ROOT/bin/fm_secret_shapes.py" "$ROOT/bin/fm-addon.sh" "$ROOT/bin/fm-timeout-lib.sh" "$COPY/bin/"
printf 'The Sync fix and its Details.\n' > "$COPY/docs/notes.md"
git -C "$COPY" init -q
git -C "$COPY" add -A
git -C "$COPY" -c user.name=t -c user.email=t@example.invalid commit -q -m init
git -C "$COPY" remote add origin https://github.com/o/starship-copy.git
HOME_APPROVED="$TMP_ROOT/approved-home"
mkdir -p "$HOME_APPROVED/config"
cp "$HOME_WORDS/config/leak-words" "$HOME_APPROVED/config/"
printf 'qverblox\n' > "$HOME_APPROVED/config/leak-names-approved"

test_draft_check_names_new_words_and_shapes() {
  local name
  name=$(cap qverblox)
  printf 'ask %s about the Sync fix\n' "$name" > "$WORK/draft.md"
  STATUS=0
  OUT=$(cd "$WORK" && FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text --new-names draft.md 2>&1) || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "a new name in draft text for this repository must fail: $OUT"
  assert_contains "$OUT" "LEAK_HIT: new-name: draft.md: $name" "the hit must name the source and the new word"
  assert_not_contains "$OUT" "new-name: draft.md: Sync" "a word the repository already holds must pass"
  STATUS=0
  OUT=$(cd "$WORK" && FM_HOME="$HOME_APPROVED" "$COPY/bin/fm-leak-guard.sh" --text --new-names draft.md 2>&1) || STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "an approved name must pass: $OUT"
  STATUS=0
  OUT=$(cd "$WORK" && FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text draft.md 2>&1) || STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "plain --text checks only the private list: $OUT"
  STATUS=0
  OUT=$(printf 'call +31 6 0000 0000 or pay NL51ZZZZ0123456789\n' \
    | FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text --new-names 2>&1) || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "customer data shapes in draft text must fail: $OUT"
  assert_contains "$OUT" "LEAK_HIT: phone: stdin: +31 6 0000 0000" "a phone number must be named"
  assert_contains "$OUT" "LEAK_HIT: iban: stdin: NL51ZZZZ0123456789" "an IBAN must be named"
  pass "the draft check with --new-names names new words and customer data shapes, and passes known and approved words"
}

# No part of a listed word or phrase is ever printed as a new word by the draft
# check, not even when the word list file itself is checked.
test_draft_check_never_names_a_listed_phrase_as_new() {
  local home="$TMP_ROOT/phrase-home" first second
  first=$(cap qverblox)
  second=$(cap logistics)
  mkdir -p "$home/config"
  printf '%s %s\n' "$first" "$second" > "$home/config/leak-words"
  printf 'ask %s %s today\n' "$first" "$second" > "$WORK/phrase.md"
  for source in phrase.md "$home/config/leak-words"; do
    STATUS=0
    OUT=$(cd "$WORK" && FM_HOME="$home" "$COPY/bin/fm-leak-guard.sh" --text --new-names "$source" 2>&1) || STATUS=$?
    [ "$STATUS" -eq 1 ] || fail "a listed phrase in $source must fail: $OUT"
    assert_contains "$OUT" "LEAK_HIT: private-word: " "the listed phrase in $source must be placed"
    assert_not_contains "$OUT" "$first" "a word of the listed phrase in $source must never be printed"
    assert_not_contains "$OUT" "$second" "a word of the listed phrase in $source must never be printed"
  done
  printf 'ask %s alone\n' "$first" > "$WORK/alone.md"
  STATUS=0
  OUT=$(cd "$WORK" && FM_HOME="$home" "$COPY/bin/fm-leak-guard.sh" --text --new-names alone.md 2>&1) || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "a lone word of a listed phrase must still be new: $OUT"
  assert_contains "$OUT" "LEAK_HIT: new-name: alone.md: $first" "a lone word of a listed phrase must be named as new"
  pass "the draft check never names a word of a listed phrase as new, while a lone word of one still is"
}

test_hook_refuses_new_words_only_for_this_repository() {
  local name pipeline="$TMP_ROOT/nm-copy"
  name=$(cap qverblox)
  export FAKE_GH_PUBLIC="o/starship-copy o/public"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    "gh pr create --repo o/starship-copy --title \"Sync fix for $name\" --body x" \
    "a new word in a PR for this public repository must be refused"
  assert_contains "$REASON" "\"$name\"" "the refusal must name the new word"
  assert_contains "$REASON" "never appeared in this Starship repository" "the refusal must say why"
  assert_contains "$REASON" "needs-decision:" "the refusal must say how to ask for an approval"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$HOME_WORDS" \
    "gh pr create --repo o/public --title \"Sync fix for $name\" --body x" \
    "another public repository may hold words new to this one"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$HOME_APPROVED" \
    "gh pr create --repo o/starship-copy --title \"Sync fix for $name\" --body x" \
    "an approved word must pass"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$HOME_WORDS" \
    'gh pr create --repo o/starship-copy --title "Sync fix" --body "Details"' \
    "words this repository already holds must pass"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    'gh pr comment 7 --repo o/starship-copy --body "reach me on +31 6 0000 0000"' \
    "a phone number in a comment on this repository must be refused"
  assert_contains "$REASON" '"+31 6 0000 0000"' "the refusal must name the shape"
  unset FAKE_GH_PUBLIC
  export FAKE_GH_PRIVATE=false
  FAKE_GH_DEFAULT_REPO=o/starship-copy HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    "gh pr create --title \"Sync fix for $name\" --body x" \
    "gh's default repository is checked by the name gh reports for it"
  FAKE_GH_DEFAULT_REPO=o/elsewhere HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$HOME_WORDS" \
    "gh pr create --title \"Sync fix for $name\" --body x" \
    "gh's default repository that is not this one may hold new words"
  git init -q "$pipeline" && git -C "$pipeline" remote add origin git@github.com:o/starship-copy.git
  git -C "$pipeline" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    "no-mistakes axi run --intent \"ask $name about the Sync fix\"" \
    "a new word in the pipeline intent for this repository must be refused" "$pipeline"
  assert_contains "$REASON" "\"$name\"" "the pipeline refusal must name the new word"
  assert_contains "$REASON" "never appeared in this Starship repository" "the pipeline refusal must say why"
  FM_PR_TEXT_GUARD_BUDGET=0.01 HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    "no-mistakes axi run --intent \"ask $name about the Sync fix\"" \
    "a check that runs out of time must refuse, not pass" "$pipeline"
  assert_contains "$REASON" "PR text check failed" "running out of time must say the check failed"
  unset FAKE_GH_PRIVATE
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$NO_LIST" \
    "gh pr create --repo o/starship-copy --title \"Sync fix for $name\" --body x" \
    "a home with no list or approvals checks nothing"
  pass "a Claude worker's new words and customer data shapes are refused only for this public repository"
}

# worker_checkout <dir> <origin url>: a clone of COPY with that origin whose
# branch adds a file that names the invented word, as a worker's branch would.
worker_checkout() {
  git clone -q "$COPY" "$1"
  git -C "$1" remote set-url origin "$2"
  git -C "$1" checkout -q -b feature
  printf 'The %s panel.\n' "$(cap qverblox)" > "$1/docs/panel.md"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m panel
}

test_branch_words_count_as_known() {
  local name worker="$TMP_ROOT/worker" other="$TMP_ROOT/other-worker"
  name=$(cap qverblox)
  worker_checkout "$worker" git@github.com:o/starship-copy.git
  worker_checkout "$other" https://github.com/o/elsewhere.git
  printf 'adds the %s panel\n' "$name" > "$WORK/branch-draft.md"
  STATUS=0
  OUT=$(cd "$worker" && FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text --new-names "$WORK/branch-draft.md" 2>&1) \
    || STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "a word the branch being published holds must pass in its checkout: $OUT"
  STATUS=0
  OUT=$(cd "$other" && FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text --new-names "$WORK/branch-draft.md" 2>&1) \
    || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "a checkout of another repository must not make a word known: $OUT"
  assert_contains "$OUT" "LEAK_HIT: new-name: $WORK/branch-draft.md: $name" "the new word must be named"
  git init -q "$TMP_ROOT/fresh-worker"
  git -C "$TMP_ROOT/fresh-worker" remote add origin git@github.com:o/starship-copy.git
  STATUS=0
  OUT=$(cd "$TMP_ROOT/fresh-worker" && FM_HOME="$HOME_WORDS" "$COPY/bin/fm-leak-guard.sh" --text --new-names "$WORK/branch-draft.md" 2>&1) \
    || STATUS=$?
  [ "$STATUS" -eq 1 ] || fail "a checkout of this repository with no commit yet must hold no words, not break the check: $OUT"
  assert_contains "$OUT" "LEAK_HIT: new-name: $WORK/branch-draft.md: $name" "the new word must be named from a fresh checkout"

  export FAKE_GH_PUBLIC=o/starship-copy
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_allow "$HOME_WORDS" \
    "gh pr create --repo o/starship-copy --title \"Add the $name panel\" --body x" \
    "a word the worker's own branch holds must pass the hook run from that checkout" "$worker"
  HOOK="$COPY/bin/fm-pr-text-guard.py" expect_refuse "$HOME_WORDS" \
    "gh pr create --repo o/starship-copy --title \"Add the $name panel\" --body x" \
    "a word only another repository's checkout holds must still be refused" "$other"
  assert_contains "$REASON" "\"$name\"" "the refusal must name the new word"
  unset FAKE_GH_PUBLIC
  pass "words in the branch being published count as known to the draft check and the hook"
}

test_draft_check_places_each_listed_word
test_draft_check_finds_token_shapes
test_draft_check_passes_clean_text_and_partial_words
test_draft_check_without_a_list_is_silent
test_hook_refuses_title_body_and_comment_on_a_public_repo
test_hook_refuses_token_shapes_and_never_prints_a_listed_word
test_hook_checks_token_shapes_only_in_sent_files
test_hook_reads_body_files_however_they_are_named
test_hook_finds_the_repository_from_urls_and_gh_repo
test_hook_refuses_the_pipeline_intent_on_a_public_github_repo
test_hook_passes_clean_private_and_unrelated_commands
test_spawn_installs_the_hook
test_first_and_second_mate_sessions_get_the_hook
test_ship_brief_tells_the_worker_to_check
test_draft_check_names_new_words_and_shapes
test_draft_check_never_names_a_listed_phrase_as_new
test_hook_refuses_new_words_only_for_this_repository
test_branch_words_count_as_known

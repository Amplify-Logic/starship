#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) agent co-author and session trailers are stripped from the squash body
#   (j) a human co-author in the squash body is preserved
#   (k) a squash body with no trailer is passed through unchanged
#   (l) a caller-supplied body is sanitized the same way, in every flag form
#   (m) a non-squash merge composes no body at all
#   (n) a body flag with no value refuses the merge
#   (o) an unreadable or null default body refuses the merge
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file and copying any
# --body-file content to a second log, and gh mock answering headRefOid for
# fm-pr-check.sh's pr_head lookup and the forge's default squash body from
# $case_dir/default-body.txt. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
prev=
for arg in "$@"; do
  [ "$prev" = --body-file ] && cat -- "$arg" > "$FM_TEST_GH_AXI_BODY"
  prev=$arg
done
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    case " \$* " in
      *viewerMergeBodyText*)
        [ -f '$case_dir/default-body-unavailable' ] && exit 1
        [ -f '$case_dir/default-body-null' ] && { echo null; exit 0; }
        [ -f '$case_dir/default-body.txt' ] && cat '$case_dir/default-body.txt'
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# The forge's default squash body for one case, as GitHub would compose it.
set_default_body() {
  local case_dir=$1
  cat > "$case_dir/default-body.txt"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_BODY="$case_dir/gh-axi.body" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qE '^pr merge 9 --repo example/repo --squash --body-file /' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, default --squash, and a composed body"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qE '^pr merge 15 --repo example/repo --squash --delete-branch --body-file /' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qE '^pr merge 126 --repo my-org/my-repo --squash --body-file /' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_strips_agent_coauthor_trailers() {
  local case_dir
  case_dir=$(make_case strip-agent-trailers)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  set_default_body "$case_dir" <<'BODY'
* fix(bin): keep the squash message honest

The branch tip was cleaned, so the merge must not put the trailer back.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016aDXQL1djK388yyNv89SfB

* no-mistakes: apply CI fixes

---------

Co-authored-by: Cursor <cursoragent@cursor.com>
Co-authored-by: Codex <codex@openai.com>
Co-authored-by: Copilot <175728472+Copilot@users.noreply.github.com>
Co-authored-by: ChatGPT <chatgpt@example.invalid>
Co-authored-by: Vendor Service <noreply@mail.openai.com>
Co-authored-by: Vendor Service <no-reply@cursor.com>
BODY

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "strip-agent-trailers: fm-pr-merge failed"

  ! grep -qi 'co-authored-by' "$case_dir/gh-axi.body" \
    || fail "strip-agent-trailers: an agent co-author trailer reached the squash message"
  ! grep -qi 'claude-session' "$case_dir/gh-axi.body" \
    || fail "strip-agent-trailers: a session trailer reached the squash message"
  cat > "$case_dir/expected-body.txt" <<'EXPECTED'
* fix(bin): keep the squash message honest

The branch tip was cleaned, so the merge must not put the trailer back.

* no-mistakes: apply CI fixes
EXPECTED
  diff "$case_dir/expected-body.txt" "$case_dir/gh-axi.body" > "$case_dir/body.diff" 2>&1 \
    || fail "strip-agent-trailers: the stripped message lost content or left the emptied trailer block behind: $(cat "$case_dir/body.diff")"
  pass "fm-pr-merge strips agent co-author and session trailers from the squash message"
}

test_keeps_human_coauthor_trailer() {
  local case_dir
  case_dir=$(make_case keep-human-trailer)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"
  set_default_body "$case_dir" <<'BODY'
* fix(bin): land a change two people wrote

---------

Co-authored-by: Dana Verhoeven <dana@example.com>
Co-authored-by: Sam Okafor <9182734+sokafor@users.noreply.github.com>
Co-authored-by: Abbott Botha <abbott.botha@example.com>
Co-authored-by: J Bot-Smith <j@example.com>
Co-authored-by: Claude Opus 5 <noreply@anthropic.com>
Co-authored-by: Copilot <175728472+Copilot@users.noreply.github.com>
BODY

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "keep-human-trailer: fm-pr-merge failed"

  assert_grep 'Co-authored-by: Dana Verhoeven <dana@example.com>' "$case_dir/gh-axi.body" \
    "keep-human-trailer: a human co-author was stripped"
  assert_grep 'Co-authored-by: Sam Okafor <9182734+sokafor@users.noreply.github.com>' "$case_dir/gh-axi.body" \
    "keep-human-trailer: a human co-author on the GitHub privacy domain was stripped"
  assert_grep 'Co-authored-by: Abbott Botha <abbott.botha@example.com>' "$case_dir/gh-axi.body" \
    "keep-human-trailer: a human whose name merely contains the letters bot was stripped"
  assert_grep 'Co-authored-by: J Bot-Smith <j@example.com>' "$case_dir/gh-axi.body" \
    "keep-human-trailer: a human whose hyphenated surname contains Bot as a word was stripped"
  assert_no_grep 'anthropic' "$case_dir/gh-axi.body" \
    "keep-human-trailer: the agent co-author survived alongside the humans"
  assert_no_grep 'Copilot' "$case_dir/gh-axi.body" \
    "keep-human-trailer: the Copilot agent on the GitHub privacy domain survived alongside the humans"
  assert_grep '---------' "$case_dir/gh-axi.body" \
    "keep-human-trailer: the separator was dropped from a trailer block that still has trailers"
  pass "fm-pr-merge preserves human co-authors in the squash message"
}

test_body_without_trailers_unchanged() {
  local case_dir
  case_dir=$(make_case body-unchanged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  set_default_body "$case_dir" <<'BODY'
* fix(bin): do one thing

A body with no trailer at all, mentioning cursor keys and gpt only in prose.

* fix(bin): do the other thing

---
BODY

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "body-unchanged: fm-pr-merge failed"

  diff "$case_dir/default-body.txt" "$case_dir/gh-axi.body" > "$case_dir/body.diff" 2>&1 \
    || fail "body-unchanged: a trailer-free squash message was rewritten: $(cat "$case_dir/body.diff")"
  pass "fm-pr-merge passes a trailer-free squash message through unchanged"
}

test_caller_supplied_body_is_sanitized() {
  local case_dir
  case_dir=$(make_case caller-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"
  printf '%s\n' 'A body the caller wrote.' '' 'Co-authored-by: Grok <grok@x.ai>' \
    > "$case_dir/caller-body.txt"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    -- --body-file "$case_dir/caller-body.txt" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "caller-body: fm-pr-merge failed"

  assert_grep 'A body the caller wrote.' "$case_dir/gh-axi.body" \
    "caller-body: the caller's own text was lost"
  ! grep -qi 'co-authored-by' "$case_dir/gh-axi.body" \
    || fail "caller-body: an agent co-author trailer reached the squash message"
  grep -qE '^pr merge 34 --repo example/repo --squash --body-file /' "$case_dir/gh-axi.log" \
    || fail "caller-body: the caller's body flag was forwarded alongside the sanitized copy"
  pass "fm-pr-merge sanitizes a caller-supplied merge body"
}

test_non_squash_merge_composes_no_body() {
  local case_dir
  case_dir=$(make_case no-body-for-merge-commit)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "no-body-for-merge-commit: fm-pr-merge failed"

  grep -qxF 'pr merge 35 --repo example/repo --rebase' "$case_dir/gh-axi.log" \
    || fail "no-body-for-merge-commit: a rebase merge was given a composed commit body"
  pass "fm-pr-merge composes no commit body for a non-squash merge"
}

test_unreadable_default_body_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case default-body-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/default-body-unavailable"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "default-body-unavailable: fm-pr-merge should refuse"
  assert_grep "could not read the pull request's squash commit message" "$case_dir/stderr" \
    "default-body-unavailable: refusal did not name the unreadable commit message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "default-body-unavailable: the merge ran with a message this path could not sanitize"
  pass "fm-pr-merge refuses to merge when the squash message cannot be read"
}

test_short_body_flag_is_sanitized() {
  local case_dir body
  case_dir=$(make_case caller-short-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  : > "$case_dir/gh-axi.log"
  body=$(printf '%s\n' 'A short-flag body.' '' 'Co-authored-by: Claude <noreply@anthropic.com>')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 \
    -- -b"$body" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "caller-short-body: fm-pr-merge failed"

  assert_grep 'A short-flag body.' "$case_dir/gh-axi.body" \
    "caller-short-body: the caller's own text was lost"
  ! grep -qi 'co-authored-by' "$case_dir/gh-axi.body" \
    || fail "caller-short-body: an agent co-author trailer reached the squash message"
  grep -qE '^pr merge 37 --repo example/repo --squash --body-file /' "$case_dir/gh-axi.log" \
    || fail "caller-short-body: the caller's -b flag was forwarded alongside the sanitized copy"
  pass "fm-pr-merge sanitizes a body given through the attached -b short flag"
}

test_short_body_file_flag_is_sanitized() {
  local case_dir
  case_dir=$(make_case caller-short-body-file)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1313131313131313131313131313131313131313
  : > "$case_dir/gh-axi.log"
  printf '%s\n' 'A body from a file.' '' 'Co-authored-by: Gemini <gemini@example.invalid>' \
    > "$case_dir/caller-body.txt"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/38 \
    -- -F "$case_dir/caller-body.txt" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "caller-short-body-file: fm-pr-merge failed"

  assert_grep 'A body from a file.' "$case_dir/gh-axi.body" \
    "caller-short-body-file: the caller's own text was lost"
  ! grep -qi 'co-authored-by' "$case_dir/gh-axi.body" \
    || fail "caller-short-body-file: an agent co-author trailer reached the squash message"
  grep -qE '^pr merge 38 --repo example/repo --squash --body-file /' "$case_dir/gh-axi.log" \
    || fail "caller-short-body-file: the caller's -F flag was forwarded alongside the sanitized copy"
  pass "fm-pr-merge sanitizes a body given through the -F short flag"
}

test_body_flag_without_value_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case body-flag-no-value)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1414141414141414141414141414141414141414
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/39 -- --body \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "body-flag-no-value: fm-pr-merge should refuse"
  assert_grep 'a merge body flag is missing its value' "$case_dir/stderr" \
    "body-flag-no-value: refusal did not name the missing body value"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "body-flag-no-value: the merge ran with an empty body in place of the missing value"
  pass "fm-pr-merge refuses a body flag that has no value"
}

test_null_default_body_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case default-body-null)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1515151515151515151515151515151515151515
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/default-body-null"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "default-body-null: fm-pr-merge should refuse"
  assert_grep "could not read the pull request's squash commit message" "$case_dir/stderr" \
    "default-body-null: refusal did not name the unreadable commit message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "default-body-null: the merge ran with the literal word null as its message"
  pass "fm-pr-merge refuses to merge when the squash message is null"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_strips_agent_coauthor_trailers
test_keeps_human_coauthor_trailer
test_body_without_trailers_unchanged
test_caller_supplied_body_is_sanitized
test_non_squash_merge_composes_no_body
test_unreadable_default_body_refuses_merge
test_short_body_flag_is_sanitized
test_short_body_file_flag_is_sanitized
test_body_flag_without_value_refuses_merge
test_null_default_body_refuses_merge

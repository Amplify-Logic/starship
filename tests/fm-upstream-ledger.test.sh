#!/usr/bin/env bash
# Behavior tests for the ported ledger in bin/fm-upstream-lib.sh: the reported
# upstream-drift figure must be what is actually still outstanding, and must
# FALL as batches land rather than only ever rising.
#
# Contracts under test:
#   - Class 2: a fork body quoting an upstream subject with its (#<pr>) subtracts
#     that commit from the count and from the listed subjects.
#   - Class 3: a fork message quoting the upstream sha subtracts that commit.
#   - Class 1: an explicit `ported` ledger record subtracts a hand-integration
#     that left no machine-readable reference.
#   - Class 1 wins: a `not-ported` record restores a commit the derivation
#     matched, so a false positive can be retired without code changes.
#   - The count falls when another batch lands.
#   - A fully delivered delta is silent.
#   - A fork PR number colliding numerically with an upstream PR number does not
#     subtract anything.
#   - No ledger evidence at all reports the raw count, exactly as before.
#   - The tracked docs/upstream-ported-ledger.txt parses and is not a stored total.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$ROOT/bin/fm-tangle-lib.sh"
# shellcheck source=bin/fm-upstream-lib.sh disable=SC1091
. "$ROOT/bin/fm-upstream-lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-upstream-ledger-tests)

# Build a fork world: bare upstream, bare origin, and a working fork clone with
# an upstream remote. Echoes the world dir.
new_world() {
  local name=$1 w seed
  w="$TMP_ROOT/$name"
  mkdir -p "$w"
  seed="$w/seed"
  mkdir -p "$seed"
  git -C "$seed" init -q
  git -C "$seed" checkout -q -b main
  printf 'v1\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm 'c1 initial'
  git clone -q --bare "$seed" "$w/upstream.git"
  git clone -q --bare "$seed" "$w/origin.git"
  git clone -q "$w/origin.git" "$w/repo"
  git -C "$w/repo" remote add upstream "file://$w/upstream.git"
  git -C "$w/repo" remote set-head upstream main >/dev/null 2>&1 || true
  git -C "$w/repo" remote set-head origin main >/dev/null 2>&1 || true
  mkdir -p "$w/home"
  printf '%s\n' "$w"
}

# Advance upstream by <n> commits whose subjects carry upstream PR numbers,
# shaped exactly like real ones: "<text> (#<700+i>)".
bump_upstream() {
  local w=$1 n=$2 i work
  work="$w/upstream-work"
  rm -rf "$work"
  git clone -q "$w/upstream.git" "$work"
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'u%s\n' "$i" >> "$work/README.md"
    git -C "$work" add README.md
    git -C "$work" commit -qm "fix(bin): upstream change $i (#$((700 + i)))"
    i=$((i + 1))
  done
  git -C "$work" push -q origin main
}

# Add one fork-only commit with <subject> and <body> to the fork checkout.
fork_commit() {
  local w=$1 subject=$2 body=$3
  printf '%s\n' "$subject" >> "$w/repo/fork-work.txt"
  git -C "$w/repo" add fork-work.txt
  git -C "$w/repo" commit -q -m "$subject" -m "$body"
}

# Full sha of the upstream commit whose subject carries "(#<pr>)".
upstream_sha_for_pr() {
  local w=$1 pr=$2
  git -C "$w/repo" log --format='%H%x09%s' -n 50 "refs/remotes/upstream/main" 2>/dev/null \
    | awk -F'\t' -v pat="(#$pr)" 'index($2, pat) > 0 { print $1; exit }'
}

run_check() {
  local w=$1
  shift
  FM_UPSTREAM_LS_TIMEOUT=5 FM_UPSTREAM_FETCH_TIMEOUT=5 \
    fm_upstream_check "$w/repo" "$w/home" "$@"
}

# Reported "N commits behind" figure from one check run, or empty when silent.
reported_count() {
  printf '%s\n' "$1" | awk '/^UPSTREAM: / { print $2; exit }'
}

test_raw_count_without_any_evidence() {
  local w out
  w=$(new_world raw)
  bump_upstream "$w" 4
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  assert_contains "$out" "UPSTREAM: 4 commits behind upstream/main" \
    "a fork with no port evidence must report the raw count"
  assert_not_contains "$out" "already delivered here" \
    "no ledger evidence must not print an accounting clause"
  pass "reports the raw count when no port evidence exists"
}

test_subject_reference_subtracts() {
  local w out
  w=$(new_world subject-ref)
  bump_upstream "$w" 4
  # A squash merge preserves each ported commit's original subject in the body.
  fork_commit "$w" 'port upstream batch (#12)' \
    '* fix(bin): upstream change 2 (#702)

Ported wholesale.'
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "a quoted upstream subject must be subtracted from the count"
  assert_contains "$out" "4 upstream commits, 1 already delivered here" \
    "the accounting clause must report the raw and delivered figures"
  assert_not_contains "$out" "upstream change 2 (#702)" \
    "a delivered commit must not stay in the listed subjects"
  assert_contains "$out" "upstream change 3 (#703)" \
    "an outstanding commit must stay in the listed subjects"
  pass "a quoted upstream subject subtracts that commit"
}

test_sha_reference_subtracts() {
  local w out sha
  w=$(new_world sha-ref)
  bump_upstream "$w" 4
  git -C "$w/repo" fetch -q upstream main
  sha=$(upstream_sha_for_pr "$w" 703)
  [ -n "$sha" ] || fail "fixture could not resolve the upstream sha for #703"
  # A hand-port that reworded the subject leaves only the sha behind.
  fork_commit "$w" 'hand-port the settle fix (#13)' \
    "Reworded for this fork's diverged tree.

(cherry picked from commit $sha)"
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "a quoted upstream sha must be subtracted from the count"
  assert_not_contains "$out" "upstream change 3 (#703)" \
    "the sha-referenced commit must not stay in the listed subjects"
  pass "a quoted upstream sha subtracts that commit"
}

test_override_ported_subtracts_untraceable_port() {
  local w out sha ledger
  w=$(new_world override-ported)
  bump_upstream "$w" 4
  git -C "$w/repo" fetch -q upstream main
  sha=$(upstream_sha_for_pr "$w" 701)
  [ -n "$sha" ] || fail "fixture could not resolve the upstream sha for #701"
  # A hand-integration that names neither the sha nor the upstream PR number.
  fork_commit "$w" 'fix(bin): integrate the settle requirement (#14)' \
    'Hand-integrated the requirement into this fork without a cherry-pick.'
  ledger="$w/ledger.txt"
  cat > "$ledger" <<EOF
# comment line, ignored
$sha  ported  fork #14 hand-integrated it with no machine-readable reference
EOF
  out=$(FM_UPSTREAM_LEDGER="$ledger" run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "an explicit ported override must be subtracted from the count"
  assert_not_contains "$out" "upstream change 1 (#701)" \
    "the overridden commit must not stay in the listed subjects"
  pass "an explicit ported override subtracts an untraceable hand-integration"
}

test_override_not_ported_restores_a_false_positive() {
  local w out sha ledger
  w=$(new_world override-not-ported)
  bump_upstream "$w" 4
  git -C "$w/repo" fetch -q upstream main
  sha=$(upstream_sha_for_pr "$w" 702)
  [ -n "$sha" ] || fail "fixture could not resolve the upstream sha for #702"
  # The fork mentions the commit only to record that it declined to take it.
  fork_commit "$w" 'docs: record a declined upstream change (#15)' \
    "* fix(bin): upstream change 2 (#702)

Reviewed and deliberately NOT taken; see the note above."
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "the derivation should have matched this mention (fixture precondition)"
  ledger="$w/ledger.txt"
  printf '%s  not-ported  reviewed and declined; the mention is not a port\n' "$sha" > "$ledger"
  out=$(FM_UPSTREAM_LEDGER="$ledger" run_check "$w")
  assert_contains "$out" "UPSTREAM: 4 commits behind upstream/main" \
    "a not-ported override must beat the derived match and restore the commit"
  assert_contains "$out" "upstream change 2 (#702)" \
    "the restored commit must reappear in the listed subjects"
  pass "a not-ported override retires a derived false positive"
}

test_count_falls_when_another_batch_lands() {
  local w before after
  w=$(new_world falls)
  bump_upstream "$w" 6
  before=$(reported_count "$(FM_UPSTREAM_LEDGER='' run_check "$w")")
  [ "$before" = 6 ] || fail "expected 6 outstanding before any batch landed, got '$before'"
  # Land a batch exactly as this fork does: one squash commit whose body quotes
  # each ported upstream subject.
  fork_commit "$w" 'contrib: port upstream batch B (#16)' \
    '* fix(bin): upstream change 1 (#701)

* fix(bin): upstream change 2 (#702)

* fix(bin): upstream change 3 (#703)'
  after=$(reported_count "$(FM_UPSTREAM_LEDGER='' run_check "$w")")
  [ "$after" = 3 ] || fail "expected 3 outstanding after a 3-commit batch landed, got '$after'"
  [ "$after" -lt "$before" ] || fail "the reported figure did not fall after a batch landed"
  pass "the reported figure falls as batches land"
}

test_silent_when_every_upstream_commit_is_delivered() {
  local w out
  w=$(new_world all-delivered)
  bump_upstream "$w" 2
  fork_commit "$w" 'contrib: port everything upstream had (#17)' \
    '* fix(bin): upstream change 1 (#701)

* fix(bin): upstream change 2 (#702)'
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  [ -z "$out" ] || fail "a fully delivered upstream delta must be silent, got: $out"
  pass "silent when every unmerged upstream commit is already delivered"
}

test_fork_pr_number_does_not_collide_with_upstream() {
  local w out
  w=$(new_world collision)
  bump_upstream "$w" 3
  # The fork's own PR number happens to equal an upstream PR number. Matching a
  # bare (#702) token would wrongly subtract; matching the whole subject does not.
  fork_commit "$w" 'fix(fork): unrelated fork work (#702)' \
    'Nothing to do with upstream; the number is a coincidence.'
  out=$(FM_UPSTREAM_LEDGER='' run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "a colliding fork PR number must not subtract an upstream commit"
  assert_not_contains "$out" "already delivered here" \
    "a colliding fork PR number must not produce an accounting clause"
  pass "a fork PR number colliding with an upstream one subtracts nothing"
}

test_tracked_ledger_parses_and_stores_no_total() {
  local ledger records
  ledger="$ROOT/docs/upstream-ported-ledger.txt"
  [ -f "$ledger" ] || fail "docs/upstream-ported-ledger.txt is missing"
  # Every non-comment record must be "<sha> <ported|not-ported> <evidence>".
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    printf '%s\n' "$line" \
      | grep -qE '^[0-9a-f]{7,40}[[:space:]]+(ported|not-ported)[[:space:]]+[^[:space:]]' \
      || fail "malformed ledger record: $line"
  done < "$ledger"
  records=$(grep -cE '^[0-9a-f]{7,40}[[:space:]]' "$ledger" || true)
  [ "$records" -ge 1 ] || fail "the tracked ledger has no records to review"
  # A stored total would be the exact dishonesty this replaces.
  assert_grep 'DO NOT list a commit whose port the derivation already finds' "$ledger" \
    "the tracked ledger lost its derived-first rule"
  pass "the tracked ledger parses and holds records, not a stored total"
}

test_raw_count_without_any_evidence
test_subject_reference_subtracts
test_sha_reference_subtracts
test_override_ported_subtracts_untraceable_port
test_override_not_ported_restores_a_false_positive
test_count_falls_when_another_batch_lands
test_silent_when_every_upstream_commit_is_delivered
test_fork_pr_number_does_not_collide_with_upstream
test_tracked_ledger_parses_and_stores_no_total

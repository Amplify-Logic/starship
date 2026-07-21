#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-lib.sh: read-only fork upstream-drift
# detection used by session-start bootstrap.
#
# Contracts under test:
#   - Behind an upstream remote: one UPSTREAM: line with count and subjects.
#   - No upstream remote configured: silent.
#   - Offline / unreachable upstream: silent.
#   - Origin and upstream share a URL (not a fork): silent.
#   - Already current with upstream tip: silent.
#   - Secondmate home marker: silent.
#   - Never merges; the only git write is a remote-tracking ref fetch.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$ROOT/bin/fm-tangle-lib.sh"
# shellcheck source=bin/fm-upstream-lib.sh disable=SC1091
. "$ROOT/bin/fm-upstream-lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-upstream-tests)

# Build a fork world:
#   upstream.git  - bare, the third-party tip
#   origin.git    - bare, the fork's origin (starts at the same commit)
#   home/repo     - clone of origin with an upstream remote
# Echoes the world dir.
new_fork_world() {
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

# Advance the upstream bare repo by <n> commits with distinct subjects.
bump_upstream() {
  local w=$1 n=$2 i work
  work="$w/upstream-work"
  rm -rf "$work"
  git clone -q "$w/upstream.git" "$work"
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'u%s\n' "$i" >> "$work/README.md"
    git -C "$work" add README.md
    git -C "$work" commit -qm "upstream-fix-$i noteworthy subject"
    i=$((i + 1))
  done
  git -C "$work" push -q origin main
}

run_check() {
  local w=$1
  shift
  FM_UPSTREAM_LS_TIMEOUT=5 FM_UPSTREAM_FETCH_TIMEOUT=5 \
    fm_upstream_check "$w/repo" "$w/home" "$@"
}

test_reports_commits_behind_with_subjects() {
  local w out
  w=$(new_fork_world behind)
  bump_upstream "$w" 3
  out=$(run_check "$w")
  assert_contains "$out" "UPSTREAM: 3 commits behind upstream/main" \
    "behind fork did not report commit count"
  assert_contains "$out" "upstream-fix-3 noteworthy subject" \
    "behind fork did not include a commit subject"
  assert_contains "$out" "upstream-fix-1 noteworthy subject" \
    "behind fork omitted an earlier subject"
  # Ensure we did not merge into the local checkout.
  [ "$(git -C "$w/repo" rev-parse HEAD)" = "$(git -C "$w/origin.git" rev-parse main)" ] \
    || fail "check merged or moved local HEAD"
  pass "reports N commits behind with subjects"
}

test_silent_without_upstream_remote() {
  local w out
  w=$(new_fork_world no-upstream)
  git -C "$w/repo" remote remove upstream
  bump_upstream "$w" 2
  out=$(run_check "$w")
  [ -z "$out" ] || fail "no-upstream home emitted noise: $out"
  pass "silent when no upstream remote is configured"
}

test_silent_when_offline() {
  local w out
  w=$(new_fork_world offline)
  git -C "$w/repo" remote set-url upstream "file://$w/missing-upstream.git"
  out=$(run_check "$w")
  [ -z "$out" ] || fail "offline probe emitted noise: $out"
  pass "silent when upstream is unreachable"
}

test_silent_when_origin_equals_upstream() {
  local w out origin_url work
  w=$(new_fork_world not-fork)
  origin_url=$(git -C "$w/repo" remote get-url origin)
  # Same URL via file:// form must still count as not-a-fork after normalize.
  git -C "$w/repo" remote set-url upstream "file://$w/origin.git"
  [ "$(fm_upstream_normalize_url "$origin_url")" = "$(fm_upstream_normalize_url "file://$w/origin.git")" ] \
    || fail "normalize failed to equate path-form origin with file:// upstream"
  # Advance origin so there is something to be behind if the equality guard failed.
  work="$w/origin-work"
  git clone -q "$w/origin.git" "$work"
  printf 'x\n' >> "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -qm 'should-not-report'
  git -C "$work" push -q origin main
  # Repo stays on old tip; equality guard must still silence.
  out=$(run_check "$w")
  [ -z "$out" ] || fail "same-URL origin/upstream emitted noise: $out"
  pass "silent when origin and upstream share a URL"
}

test_silent_when_current() {
  local w out tip
  w=$(new_fork_world current)
  bump_upstream "$w" 2
  # Fast-forward the local repo to upstream tip without going through origin.
  tip=$(git -C "$w/upstream.git" rev-parse main)
  git -C "$w/repo" fetch -q upstream main
  git -C "$w/repo" checkout -q --detach "$tip"
  out=$(run_check "$w")
  [ -z "$out" ] || fail "current tip emitted noise: $out"
  pass "silent when HEAD already contains the upstream tip"
}

test_silent_for_secondmate_home() {
  local w out
  w=$(new_fork_world secondmate)
  bump_upstream "$w" 2
  printf 'domain\n' > "$w/home/.fm-secondmate-home"
  out=$(run_check "$w")
  [ -z "$out" ] || fail "secondmate home emitted noise: $out"
  pass "silent for secondmate homes"
}

test_bootstrap_wires_upstream_line() {
  local w fakebin out
  w=$(new_fork_world bootstrap-wire)
  bump_upstream "$w" 2
  # Minimal toolchain so bootstrap reaches the upstream check without MISSING noise.
  fakebin=$(fm_fakebin "$w/fakebin")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && exit 0
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.31.2'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' '0.1.1'; exit 0; }
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  mkdir -p "$w/home/config" "$w/home/state" "$w/home/data" "$w/home/projects"
  # FM_ROOT_OVERRIDE is the git repo under test; scripts still load from ROOT
  # via the invoked fm-bootstrap.sh path (SCRIPT_DIR), not from FM_ROOT.
  out=$(
    PATH="$fakebin:/usr/bin:/bin" \
    FM_ROOT_OVERRIDE="$w/repo" \
    FM_HOME="$w/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_UPSTREAM_LS_TIMEOUT=5 \
    FM_UPSTREAM_FETCH_TIMEOUT=5 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true
  )
  assert_contains "$out" "UPSTREAM: 2 commits behind upstream/main" \
    "bootstrap did not surface UPSTREAM line"
  pass "bootstrap wires the UPSTREAM diagnostic"
}

test_skill_and_agents_trigger_mention_upstream() {
  assert_grep 'UPSTREAM' "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
    "bootstrap-diagnostics skill lost UPSTREAM handling"
  assert_grep '`UPSTREAM:`' "$ROOT/AGENTS.md" \
    "AGENTS.md bootstrap-diagnostics trigger lost UPSTREAM"
  pass "skill and AGENTS.md trigger mention UPSTREAM"
}

test_reports_commits_behind_with_subjects
test_silent_without_upstream_remote
test_silent_when_offline
test_silent_when_origin_equals_upstream
test_silent_when_current
test_silent_for_secondmate_home
test_bootstrap_wires_upstream_line
test_skill_and_agents_trigger_mention_upstream

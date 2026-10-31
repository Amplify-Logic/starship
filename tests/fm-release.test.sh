#!/usr/bin/env bash
# Tests for bin/fm-release.sh, the maintainer-only release cut, and the release
# naming in bin/fm-release-lib.sh.
#
# The guarantees under test:
#   - Only a maintainer home whose scope names this origin may cut a release.
#   - A release is cut only on a default-branch tip whose every reported check
#     finished green; a red, still-running, or silent tip refuses.
#   - The notes are the release's own CHANGELOG.md section, which must exist.
#   - The name is starship-YYYY.MM, or the next .N fix release when that month
#     already has one, and a tip that already carries a release refuses.
# No test reaches a real forge: gh is a fake that records what it was asked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASE="$ROOT/bin/fm-release.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-release-tests)
URL=https://github.com/acme/starship

# A bare origin reachable under a GitHub-shaped URL, a maintainer home cloned
# from it, and a fake gh whose check answers come from files in fake/.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/fakebin" "$w/fake"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf '# Changelog\n\n## Unreleased\n\n## starship-2026.11\n\n- Calmer updates.\n\n## starship-2026.10\n\n- Older notes.\n' \
    > "$w/seed/CHANGELOG.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/home"
  git -C "$w/home" remote set-url origin "$URL"
  git -C "$w/home" config "url.$w/origin.git.insteadOf" "$URL"
  mkdir -p "$w/home/config"
  printf 'maintainer github.com/acme/starship\n' > "$w/home/config/firstmate-role"
  printf '{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}\n' > "$w/fake/runs"
  printf '{"state":"pending","total_count":0,"statuses":[]}\n' > "$w/fake/status"
  cat > "$w/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  "api --hostname")
    case "$*" in
      *check-runs*) cat "$FAKE/runs" ;;
      */status*) cat "$FAKE/status" ;;
      *) exit 1 ;;
    esac
    ;;
  "release create")
    notes=
    while [ $# -gt 0 ]; do
      [ "$1" = --notes-file ] && notes=$2
      shift
    done
    cp "$notes" "$FAKE/notes"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$w/fakebin/gh"
  printf '%s\n' "$w"
}

run_release() {  # <world> [args...]
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" FAKE="$w/fake" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/home" \
    FM_RELEASE_MONTH=2026.11 "$RELEASE" "$@" 2>&1
}

created() {  # <world>
  grep '^release create' "$1/fake/calls" 2>/dev/null
}

test_green_main_is_released_with_its_changelog_notes() {
  local w out sha
  w=$(new_world green)
  sha=$(git -C "$w/seed" rev-parse HEAD)

  out=$(run_release "$w" --dry-run) || fail "a dry run on a green main failed: $out"
  assert_contains "$out" "would run: gh release create starship-2026.11 --repo github.com/acme/starship --target $sha" \
    "the dry run names the release, the repository, and the commit"
  [ -z "$(created "$w")" ] || fail "a dry run must not create a release"

  out=$(run_release "$w") || fail "a release on a green main failed: $out"
  assert_contains "$(created "$w")" "release create starship-2026.11 --repo github.com/acme/starship --target $sha --title starship-2026.11" \
    "the release is created on the default-branch tip"
  [ "$(cat "$w/fake/notes")" = "- Calmer updates." ] \
    || fail "the notes must be exactly the release's CHANGELOG.md section, got: $(cat "$w/fake/notes")"
  pass "a green main is released with its own CHANGELOG.md section as notes"
}

test_refuses_unless_every_check_is_green() {
  local w out
  w=$(new_world red)
  printf '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"failure"}]}\n' > "$w/fake/runs"
  out=$(run_release "$w") && fail "a red main must refuse"
  assert_contains "$out" "not all green: lint" "the refusal names the red check"

  printf '{"check_runs":[{"name":"ci","status":"in_progress","conclusion":null}]}\n' > "$w/fake/runs"
  out=$(run_release "$w") && fail "a still-running main must refuse"
  assert_contains "$out" "not all green: ci" "the refusal names the unfinished check"

  printf '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}\n' > "$w/fake/runs"
  printf '{"state":"failure","total_count":1,"statuses":[{"context":"deploy","state":"failure"}]}\n' > "$w/fake/status"
  out=$(run_release "$w") && fail "a failed commit status must refuse"
  assert_contains "$out" "not all green: deploy" "the refusal names the failed status"

  printf '{"check_runs":[]}\n' > "$w/fake/runs"
  printf '{"state":"pending","total_count":0,"statuses":[]}\n' > "$w/fake/status"
  out=$(run_release "$w") && fail "a main with no reported checks must refuse"
  assert_contains "$out" "no checks have reported" "the refusal says nothing reported"

  [ -z "$(created "$w")" ] || fail "a refused release still reached the forge"
  pass "a release refuses unless every reported check finished green"
}

test_refuses_without_maintainer_scope_for_this_origin() {
  local w out
  w=$(new_world role)
  rm "$w/home/config/firstmate-role"
  out=$(run_release "$w") && fail "a user home must refuse"
  assert_contains "$out" "needs this home's maintainer role" "the refusal names the role"

  printf 'maintainer github.com/someone/else\n' > "$w/home/config/firstmate-role"
  out=$(run_release "$w") && fail "a maintainer of another repository must refuse"
  assert_contains "$out" "is not the maintainer scope" "the refusal names the scope mismatch"
  [ ! -s "$w/fake/calls" ] || fail "a refused role still called the forge"
  pass "only a maintainer of this origin may cut a release"
}

test_refuses_without_changelog_section() {
  local w out
  w=$(new_world notes)
  out=$(PATH="$w/fakebin:$PATH" FAKE="$w/fake" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/home" \
    FM_RELEASE_MONTH=2026.12 "$RELEASE" 2>&1) && fail "a release with no notes must refuse"
  assert_contains "$out" 'no notes under "## starship-2026.12"' "the refusal names the missing section"
  pass "a release refuses without its own CHANGELOG.md section"
}

test_fix_release_name_and_already_released_tip() {
  local w out
  w=$(new_world fix)
  git -C "$w/seed" tag starship-2026.11
  git -C "$w/seed" push -q origin refs/tags/starship-2026.11
  out=$(run_release "$w") && fail "a tip that is already a release must refuse"
  assert_contains "$out" "is already release starship-2026.11" "the refusal names the existing release"

  printf '\n## starship-2026.11.1\n\n- A fix.\n' >> "$w/seed/CHANGELOG.md"
  git -C "$w/seed" commit -qam fix
  git -C "$w/seed" push -q origin main
  out=$(run_release "$w") || fail "a fix release failed: $out"
  assert_contains "$(created "$w")" "release create starship-2026.11.1 " "a second release in one month is the .1 fix release"
  [ "$(cat "$w/fake/notes")" = "- A fix." ] || fail "the fix release must carry its own notes"
  pass "a second release in one month is named as a fix release"
}

test_green_main_is_released_with_its_changelog_notes
test_refuses_unless_every_check_is_green
test_refuses_without_maintainer_scope_for_this_origin
test_refuses_without_changelog_section
test_fix_release_name_and_already_released_tip

echo "# all fm-release tests passed"

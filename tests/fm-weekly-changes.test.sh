#!/usr/bin/env bash
# Behavior tests for the opt-in weekly "what changed" page and its schedule.
#
# Contracts under test:
#   - A home with no `enabled = true` line is completely inert and reads nothing.
#   - The page groups the week's merged pull requests by registered project,
#     busiest first, each shown by its "In short" section (else its title
#     without a "feat(scope):" prefix) with a link, plus the changelog bullets
#     added that week; quiet projects and unreadable ones are named with why.
#   - Each weekly slot is written once, after its local time; before it, the
#     previous week's slot is the one due.
#   - When GitHub cannot be read for any project nothing is written, so the next
#     run retries; when only some fail, the page is written and names them.
#   - Text from GitHub is escaped, and a changelog failure only adds a note.
#   - The lead sentence counts only projects where a pull request landed, not
#     ones where only the changelog moved.
#   - Local configuration is validated and unknown keys (days among them, since
#     a page always covers seven days) are refused.
#   - Old pages are pruned and status names the newest page.
#   - The schedule renders, installs and removes against a temporary home and a
#     fake launchd transport, and refuses a home that never opted in.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE="$ROOT/bin/fm-weekly-changes.py"
SCHEDULE="$ROOT/bin/fm-weekly-changes-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-weekly-changes-tests)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# Europe/Amsterdam is UTC+1 in November; the default slot is Monday 07:00 local.
T_WED=1794996000         # Wednesday 2026-11-18 11:00 local
T_MON_EARLY=1794807000   # Monday 2026-11-16 06:30 local, before that day's slot

FAKE_GH_DIR="$TMP_ROOT/gh"
mkdir -p "$FAKE_GH_DIR"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh: answers from fixture files under $FAKE_GH_DIR and logs every call.
printf '%s\n' "$*" >>"$FAKE_GH_DIR/calls.log"
[ ! -e "$FAKE_GH_DIR/fail-all" ] || { echo 'could not connect' >&2; exit 1; }
if [ "$1 $2" = "pr list" ]; then
  repo=$4
  [ ! -e "$FAKE_GH_DIR/fail-${repo//\//_}" ] || { echo 'not found' >&2; exit 1; }
  cat "$FAKE_GH_DIR/${repo//\//_}.prs.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "$1" = api ]; then
  if [ "$2" = -H ]; then
    [ ! -e "$FAKE_GH_DIR/fail-changelog" ] || { echo 'server error' >&2; exit 1; }
    cat "$FAKE_GH_DIR/changelog-${4##*ref=}.md"
    exit 0
  fi
  path=${2%%\?*}
  repo=${path#repos/}; repo=${repo%/commits}
  until=${2##*until=}; until=${until%%&*}
  sha=$(awk -v u="$until" '$1 <= u { s = $2 } END { print s }' "$FAKE_GH_DIR/${repo//\//_}.commits" 2>/dev/null)
  if [ -n "$sha" ]; then printf '[{"sha":"%s"}]\n' "$sha"; else echo '[]'; fi
  exit 0
fi
echo "fake gh: unexpected call: $*" >&2
exit 3
SH
chmod +x "$FAKEBIN/gh"

cat >"$FAKE_GH_DIR/acme_alpha.prs.json" <<'JSON'
[
  {"number":10,"title":"Old change","url":"https://github.com/acme/alpha/pull/10","mergedAt":"2026-11-08T12:00:00Z","body":"# In short\n\nLast week's change."},
  {"number":13,"title":"feat: week page","url":"https://github.com/acme/alpha/pull/13","mergedAt":"2026-11-13T09:00:00Z","body":"# In short\n\n<!-- One or two sentences. -->\nThe [week page](https://example.com/x) shows **plain** words.\n\n# See it\n\nOpen it.\n\n<details>\n<summary>Technical detail</summary>\n\n## What Changed\n\n- internals\n</details>"},
  {"number":11,"title":"feat(bin): add photo drop","url":"https://github.com/acme/alpha/pull/11","mergedAt":"2026-11-10T09:00:00Z","body":"# In short\n\nYou can now drop a photo on the page.\n\n# See it\n\nDrag one in."},
  {"number":12,"title":"fix: stop the double <b>reminder</b>","url":"https://github.com/acme/alpha/pull/12","mergedAt":"2026-11-12T15:00:00Z","body":"No template here. <script>alert(1)</script>"}
]
JSON
cat >"$FAKE_GH_DIR/acme_beta-app.prs.json" <<'JSON'
[{"number":5,"title":"chore: tidy the settings screen","url":"https://github.com/acme/beta-app/pull/5","mergedAt":"2026-11-14T08:00:00Z","body":""}]
JSON
cat >"$FAKE_GH_DIR/acme_coderoot.prs.json" <<'JSON'
[{"number":7,"title":"feat: x","url":"https://github.com/acme/coderoot/pull/7","mergedAt":"2026-11-11T08:00:00Z","body":"## In short\nSetup is <one> step now.\n## Risk\nLow."}]
JSON
printf '2026-11-01T00:00:00Z sha-old\n2026-11-12T00:00:00Z sha-new\n' >"$FAKE_GH_DIR/acme_alpha.commits"
printf '# Changelog\n\n- **Old entry.** Detail.\n' >"$FAKE_GH_DIR/changelog-sha-old.md"
cat >"$FAKE_GH_DIR/changelog-sha-new.md" <<'MD'
# Changelog

- **Photos can be dropped on the page.** More detail follows here.
- **Old entry.** Detail.
  - a nested line that is not a highlight
- A plain bullet with a [link](https://example.com/y).
MD

# The code root stands in for the firstmate repository registered as a project.
CODE_ROOT="$TMP_ROOT/coderoot"

git_copy() {  # <dir> [origin]
  mkdir -p "$1"
  git -C "$1" init -q
  [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"
}

git_copy "$CODE_ROOT" https://github.com/acme/coderoot.git

new_home() {  # <dir> [enabled]
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/data" "$h/projects"
  if [ "${2:-true}" = true ]; then
    printf 'enabled = true\n' >"$h/config/weekly-changes"
  fi
  cat >"$h/data/projects.md" <<'EOF'
- alpha [no-mistakes +yolo label=Alpha] - The alpha app (added 2026-01-01)
- beta-app [direct-PR] - The beta app (added 2026-01-01)
- quiet-one - Nothing happens here (added 2026-01-01)
- local-thing [local-only] - A local repository (added 2026-01-01)
- gone [direct-PR] - Registered with no copy (added 2026-01-01)
- firstmate [no-mistakes alias=coderoot label=Fleet] - This repository (added 2026-01-01)
EOF
  git_copy "$h/projects/alpha" https://github.com/acme/alpha.git
  git_copy "$h/projects/beta-app" git@github.com:acme/beta-app.git
  git_copy "$h/projects/quiet-one" https://github.com/acme/quiet-one
  git_copy "$h/projects/local-thing"
}

page() {  # <home> <now> <args...>
  local h=$1 now=$2
  shift 2
  PATH="$FAKEBIN:$PATH" TZ=Europe/Amsterdam FM_HOME="$h" FM_ROOT_OVERRIDE="$CODE_ROOT" \
    FM_WEEKLY_CHANGES_NOW="$now" FAKE_GH_DIR="$FAKE_GH_DIR" "$PAGE" "$@"
}

gh_calls() {
  local n
  n=$(grep -c . "$FAKE_GH_DIR/calls.log" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

test_inert_without_opt_in() {
  local h out code before
  h="$TMP_ROOT/no-optin"
  new_home "$h" false
  before=$(gh_calls)
  out=$(page "$h" "$T_WED" run) && code=0 || code=$?
  expect_code 0 "$code" 'run on a home with no config'
  [ -z "$out" ] || fail "un-enrolled home produced output: $out"
  assert_absent "$h/data/weekly-changes" 'un-enrolled home wrote a page'
  assert_equals "$before" "$(gh_calls)" 'un-enrolled home read GitHub'

  printf 'enabled = false\n' >"$h/config/weekly-changes"
  page "$h" "$T_WED" run >/dev/null || fail 'run with enabled = false failed'
  assert_absent "$h/data/weekly-changes" 'a home with enabled = false wrote a page'
  pass 'a home that never opted in stays inert'
}

test_weekly_page_content() {
  local h html before
  h="$TMP_ROOT/content"
  new_home "$h"
  page "$h" "$T_WED" run >/dev/null || fail 'run failed'
  assert_present "$h/data/weekly-changes/pages/2026-11-16.html" 'the slot page was not written'
  html=$(cat "$h/data/weekly-changes/latest.html")
  assert_equals "$html" "$(cat "$h/data/weekly-changes/pages/2026-11-16.html")" 'latest is not the newest page'

  assert_contains "$html" 'Monday 9 to Monday 16 November 2026' 'the week range is not in plain words'
  assert_contains "$html" '5 changes landed across 3 projects.' 'the lead sentence is wrong'
  assert_contains "$html" 'You can now drop a photo on the page.' 'the In short section was not used'
  assert_contains "$html" 'The week page shows plain words.' 'the In short section was not cleaned'
  assert_contains "$html" 'Stop the double reminder' 'the title fallback did not drop its prefix and markup'
  assert_contains "$html" 'Setup is &lt;one&gt; step now.' 'a level-two In short heading was not read or text was not escaped'
  assert_contains "$html" 'Tidy the settings screen' 'a project read through an ssh origin is missing'
  assert_contains "$html" 'href="https://github.com/acme/alpha/pull/11"' 'a change has no link'
  assert_not_contains "$html" "Last week's change." 'a change merged before the week was listed'
  assert_not_contains "$html" '<script>' 'text from GitHub was not escaped'
  assert_not_contains "$html" 'internals' 'the folded technical detail leaked into the summary'

  # Busiest project first, then by name; the code root stands in for Fleet.
  printf '%s' "$html" | awk '/<h2>/' | tr -d '\n' | grep -q 'Alpha.*Beta App.*Fleet' \
    || fail "projects are not busiest first: $(printf '%s' "$html" | grep '<h2>')"
  assert_contains "$html" '<span>3 changes</span>' 'the busiest project count is wrong'
  # Within a project, oldest first: photo (Tue) before reminder (Thu) before page (Fri).
  printf '%s' "$html" | tr -d '\n' | grep -q 'drop a photo.*double reminder.*week page shows' \
    || fail 'changes are not in the order they landed'

  assert_contains "$html" 'Photos can be dropped on the page.' 'a new changelog lead is missing'
  assert_contains "$html" 'A plain bullet with a link.' 'a plain changelog bullet is missing'
  assert_not_contains "$html" 'Old entry.' 'an old changelog bullet was shown as new'
  assert_not_contains "$html" 'nested line' 'a nested changelog line was shown'

  assert_contains "$html" 'Nothing landed in Quiet One.' 'the quiet project is not named'
  assert_contains "$html" 'Local Thing was not read: it is not on GitHub.' 'a non-GitHub project is not explained'
  assert_contains "$html" 'Gone was not read: it has no copy on this computer.' 'a project with no copy is not explained'

  before=$(gh_calls)
  page "$h" "$T_WED" run >/dev/null || fail 'second run failed'
  assert_equals "$before" "$(gh_calls)" 'a second run in the same week read GitHub again'
  pass 'the page groups the week by project with plain summaries, links and highlights'
}

test_slot_before_its_time() {
  local h
  h="$TMP_ROOT/early"
  new_home "$h"
  page "$h" "$T_MON_EARLY" run >/dev/null || fail 'early run failed'
  assert_present "$h/data/weekly-changes/pages/2026-11-09.html" 'before the slot time the previous week was not due'
  assert_absent "$h/data/weekly-changes/pages/2026-11-16.html" 'a page was written before its slot time'
  printf 'enabled = true\nweekday = Monday\ntime = 06:00\n' >"$h/config/weekly-changes"
  page "$h" "$T_MON_EARLY" run >/dev/null || fail 'run with an earlier time failed'
  assert_present "$h/data/weekly-changes/pages/2026-11-16.html" 'the configured time was not honoured'
  pass 'each slot is written once its local time has passed'
}

test_failures() {
  local h out code
  h="$TMP_ROOT/fail-all"
  new_home "$h"
  : >"$FAKE_GH_DIR/fail-all"
  out=$(page "$h" "$T_WED" run 2>&1) && code=0 || code=$?
  rm -f "$FAKE_GH_DIR/fail-all"
  expect_code 1 "$code" 'run when GitHub cannot be read at all'
  assert_contains "$out" 'nothing written' 'the failure did not say nothing was written'
  assert_absent "$h/data/weekly-changes/latest.html" 'a page was written when nothing could be read'
  page "$h" "$T_WED" run >/dev/null || fail 'the retry failed'
  assert_present "$h/data/weekly-changes/pages/2026-11-16.html" 'the next run did not retry the slot'

  h="$TMP_ROOT/fail-some"
  new_home "$h"
  : >"$FAKE_GH_DIR/fail-acme_beta-app"
  : >"$FAKE_GH_DIR/fail-changelog"
  page "$h" "$T_WED" run >/dev/null && code=0 || code=$?
  rm -f "$FAKE_GH_DIR/fail-acme_beta-app" "$FAKE_GH_DIR/fail-changelog"
  expect_code 0 "$code" 'run when one project cannot be read'
  out=$(cat "$h/data/weekly-changes/latest.html")
  assert_contains "$out" 'Beta App was not read: GitHub could not be reached for it.' 'a failed project is not named'
  assert_contains "$out" 'Its changelog could not be read this time.' 'a changelog failure is not noted'
  assert_contains "$out" 'You can now drop a photo on the page.' 'a changelog failure dropped the changes'
  pass 'a total failure writes nothing and retries; a partial one is named on the page'
}

test_lead_ignores_changelog_only_projects() {
  local h html
  h="$TMP_ROOT/changelog-only"
  new_home "$h"
  cp "$FAKE_GH_DIR/acme_alpha.commits" "$FAKE_GH_DIR/acme_quiet-one.commits"
  page "$h" "$T_WED" run >/dev/null || fail 'run failed'
  rm -f "$FAKE_GH_DIR/acme_quiet-one.commits"
  html=$(cat "$h/data/weekly-changes/latest.html")
  assert_contains "$html" '<h2>Quiet One <span>0 changes</span></h2>' 'the changelog-only project has no section'
  assert_contains "$html" '5 changes landed across 3 projects.' 'the lead counted a project where no change landed'
  pass 'the lead sentence counts only projects where a change landed'
}

test_configuration_is_validated() {
  local h out code
  h="$TMP_ROOT/config"
  new_home "$h"
  for bad in 'colour = blue' 'weekday = someday' 'time = 7am' 'days = 7' 'enabled = yes' 'interval_seconds = -1'; do
    printf '%s\n' "$bad" >"$h/config/weekly-changes"
    out=$(page "$h" "$T_WED" status 2>&1) && code=0 || code=$?
    expect_code 2 "$code" "config line '$bad'"
  done
  printf '# a comment\nenabled = true\nweekday = friday\ntime = 17:30\ninterval_seconds = 600\n' \
    >"$h/config/weekly-changes"
  out=$(page "$h" "$T_WED" status) || fail 'status failed on a valid config'
  assert_contains "$out" 'weekday: friday' 'the weekday was not read'
  assert_equals 600 "$(page "$h" "$T_WED" interval)" 'interval did not print the configured cadence'
  pass 'configuration is validated and unknown keys are refused'
}

test_pruning_and_status() {
  local h i
  h="$TMP_ROOT/prune"
  new_home "$h"
  assert_contains "$(page "$h" "$T_WED" status)" 'latest: none yet' 'status named a page before any was written'
  mkdir -p "$h/data/weekly-changes/pages"
  for i in $(seq 10 39); do : >"$h/data/weekly-changes/pages/2025-01-$i.html"; done
  page "$h" "$T_WED" run >/dev/null || fail 'run failed'
  assert_equals 26 "$(find "$h/data/weekly-changes/pages" -name '*.html' | wc -l | tr -d ' ')" 'old pages were not pruned to 26'
  assert_present "$h/data/weekly-changes/pages/2026-11-16.html" 'pruning removed the newest page'
  assert_contains "$(page "$h" "$T_WED" status)" "latest: $h/data/weekly-changes/latest.html" 'status did not name the newest page'
  pass 'old pages are pruned and status names the newest'
}

test_schedule_on_a_temp_home() {
  local h out code agents fakebin
  h="$TMP_ROOT/schedule"
  new_home "$h" false
  agents="$TMP_ROOT/LaunchAgents"
  mkdir -p "$agents"
  fakebin="$TMP_ROOT/launchd-fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
FAKE
  chmod +x "$fakebin/launchctl"

  schedule() {
    FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WEEKLY_CHANGES_LAUNCH_AGENTS_DIR="$agents" \
    FM_WEEKLY_CHANGES_LAUNCHCTL="$fakebin/launchctl" \
    FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
      "$SCHEDULE" "$@"
  }

  out=$(schedule render)
  assert_contains "$out" '<integer>3600</integer>' 'the default cadence is not hourly'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the schedule does not run at load'
  assert_contains "$out" '<string>run</string>' 'the schedule does not call run'
  assert_contains "$out" 'fm-weekly-changes.py' 'the schedule does not call the page owner'
  assert_contains "$out" 'dev.firstmate.weekly-changes.' 'the label is not the per-home label'

  if [ "$(uname)" = Darwin ]; then
    out=$(schedule install 2>&1) && code=0 || code=$?
    expect_code 2 "$code" 'install on a home that never opted in'
    assert_contains "$out" 'not opted in' 'the refusal did not say why'
    [ -z "$(ls -A "$agents")" ] || fail 'a refused install wrote a LaunchAgent'

    printf 'enabled = true\ninterval_seconds = 900\n' >"$h/config/weekly-changes"
    out=$(schedule install) || fail 'install failed'
    assert_contains "$out" 'interval_seconds: 900' 'install did not use the configured cadence'
    ls "$agents"/dev.firstmate.weekly-changes.*.plist >/dev/null 2>&1 || fail 'install wrote no LaunchAgent'
    assert_contains "$(cat "$TMP_ROOT/launchctl.log")" 'bootstrap' 'install did not load the agent'
    schedule remove >/dev/null || fail 'remove failed'
    [ -z "$(ls -A "$agents")" ] || fail 'remove left the LaunchAgent behind'
  fi
  pass 'the schedule renders, refuses an un-enrolled home, and installs against a temp home'
}

test_inert_without_opt_in
test_weekly_page_content
test_slot_before_its_time
test_failures
test_lead_ignores_changelog_only_projects
test_configuration_is_validated
test_pruning_and_status
test_schedule_on_a_temp_home

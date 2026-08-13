#!/usr/bin/env bash
# Behavior tests for the in-terminal overlay helper and, above all, for the ways
# it steps aside: a missing viewer must never fail the caller that only wanted to
# put something in front of the captain.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERLAY="$ROOT/bin/fm-overlay.sh"
TMP_ROOT=$(fm_test_tmproot fm-overlay)
# A TMPDIR with a trailing slash leaves a doubled separator in the temp root,
# which the helper collapses when it resolves a source path. Compare against the
# same collapsed form rather than against the raw string.
TMP_ROOT=${TMP_ROOT//\/\//\/}
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/herdr-calls.txt"
LISTING="$TMP_ROOT/plugin-list.json"
PANE_STATUS="$TMP_ROOT/pane-status"

mkdir -p "$HOME_DIR/data/sample-report-r1" "$HOME_DIR/data/goals" "$HOME_DIR/config"
printf '# Sample\n\nWhat the scout found.\n' > "$HOME_DIR/data/sample-report-r1/report.md"
printf 'not markdown\n' > "$HOME_DIR/data/plain.txt"
printf '# Atelier\n\nThe end state.\n' > "$HOME_DIR/data/goals/atelier-workspace.md"
printf '# Notes\n\nBeside the report.\n' > "$HOME_DIR/data/sample-report-r1/notes.md"

cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = list ]; then
  cat "$LISTING"
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = pane ]; then
  exit "\$(cat "$PANE_STATUS")"
fi
exit 0
SH
chmod +x "$FAKEBIN/herdr"
printf '0\n' > "$PANE_STATUS"
printf '{"result":{"plugins":[]}}\n' > "$LISTING"

overlay() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HERDR_BIN="$FAKEBIN/herdr" "$OVERLAY" "$@"
}

with_viewer() {
  cat > "$LISTING" <<'JSON'
{"result":{"plugins":[
  {"id":"some-unrelated-plugin","name":"Token dashboard","enabled":true,"panes":[{"id":"main"}]},
  {"id":"herdr-file-viewer","name":"File viewer","enabled":true,"panes":[{"id":"viewer"}]}
]}}
JSON
}

test_a_non_herdr_terminal_steps_aside_with_a_link() {
  local out status
  out=$(FM_BACKEND=tmux overlay sample-report-r1 2>&1)
  status=$?
  expect_code 0 "$status" "a non-herdr terminal must not fail the caller"
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" \
    "the fallback did not name where to read the same thing"
  assert_contains "$out" "not herdr" "the fallback did not say why there is no overlay"
  pass "a terminal that is not herdr steps aside and prints the link"
}

test_a_missing_herdr_steps_aside_with_a_link() {
  local out status
  out=$(FM_BACKEND=herdr FM_HERDR_BIN="$TMP_ROOT/no-such-herdr" FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" "$OVERLAY" sample-report-r1 2>&1)
  status=$?
  expect_code 0 "$status" "a missing herdr must not fail the caller"
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" "no link was offered"
  pass "a missing herdr steps aside and prints the link"
}

test_no_installed_viewer_steps_aside_and_installs_nothing() {
  local out status
  printf '{"result":{"plugins":[]}}\n' > "$LISTING"
  out=$(FM_BACKEND=herdr overlay sample-report-r1 2>&1)
  status=$?
  expect_code 0 "$status" "an absent viewer must not fail the caller"
  assert_contains "$out" "no file-viewer plugin is installed" "the reason was not reported"
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" "no link was offered"
  assert_no_grep "plugin install" "$CALLS" "the overlay helper must never install a plugin"
  assert_no_grep "plugin pane open" "$CALLS" "no pane should be opened without a viewer"
  pass "an absent viewer steps aside, and nothing is ever installed"
}

test_an_installed_viewer_opens_an_overlay_pane() {
  local out status
  with_viewer
  out=$(FM_BACKEND=herdr overlay sample-report-r1 2>&1)
  status=$?
  expect_code 0 "$status" "opening an overlay should succeed"
  assert_grep "plugin pane open --plugin herdr-file-viewer --entrypoint viewer --placement overlay" \
    "$CALLS" "the verified herdr invocation was not used"
  assert_grep "--env FM_OVERLAY_FILE=$HOME_DIR/data/sample-report-r1/report.md" "$CALLS" \
    "the exact file was not handed to the viewer"
  assert_contains "$out" "opened report.md in the overlay pane" "the caller was not told what happened"
  assert_no_grep "plugin install" "$CALLS" "the overlay helper must never install a plugin"
  pass "an installed viewer is discovered and opened as an overlay pane"
}

test_an_explicit_plugin_and_placement_win() {
  with_viewer
  FM_BACKEND=herdr overlay sample-report-r1 --plugin chosen-one --entrypoint side --placement popup >/dev/null 2>&1
  assert_grep "plugin pane open --plugin chosen-one --entrypoint side --placement popup" "$CALLS" \
    "an explicit plugin, entrypoint and placement were not honoured"
  pass "an explicit plugin, entrypoint and placement override discovery"
}

test_a_refused_pane_steps_aside_with_a_link() {
  local out status
  with_viewer
  printf '3\n' > "$PANE_STATUS"
  out=$(FM_BACKEND=herdr overlay sample-report-r1 2>&1)
  status=$?
  printf '0\n' > "$PANE_STATUS"
  expect_code 0 "$status" "a refused pane must not fail the caller"
  assert_contains "$out" "the viewer pane did not open" "the refusal was not reported"
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" "no link was offered"
  pass "a pane that refuses to open steps aside and prints the link"
}

test_link_only_never_touches_the_terminal() {
  local out
  with_viewer
  out=$(FM_BACKEND=herdr overlay sample-report-r1 --link-only 2>&1)
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" "link-only printed no link"
  [ ! -s "$CALLS" ] || fail "link-only must not call herdr at all"
  pass "link-only prints the link and leaves the terminal alone"
}

test_a_plain_markdown_path_falls_back_to_its_own_path() {
  local out file
  file="$TMP_ROOT/loose-note.md"
  printf '# Loose\n' > "$file"
  out=$(FM_BACKEND=tmux overlay "$file" 2>&1)
  assert_contains "$out" "$file" "a file outside the records should fall back to its own path"
  pass "a Markdown file outside the records falls back to its own path"
}

# Only data/<task-id>/report.md has a chart-room view. Everything else under the
# records - a goal charter the captain is handed, a note filed beside a report -
# must be named by its own path rather than by a link that leads to nothing.
test_only_a_task_report_earns_a_chart_room_link() {
  local out file
  file="$HOME_DIR/data/sample-report-r1/report.md"
  out=$(FM_BACKEND=tmux overlay "$file" 2>&1)
  assert_contains "$out" "http://127.0.0.1:4390/report/sample-report-r1" \
    "a task report given by path lost its chart-room link"

  file="$HOME_DIR/data/goals/atelier-workspace.md"
  out=$(FM_BACKEND=tmux overlay "$file" 2>&1)
  assert_contains "$out" "$file" "a goal charter should fall back to its own path"
  assert_not_contains "$out" "/report/goals" "a goal charter must not be given a report link that 404s"

  file="$HOME_DIR/data/sample-report-r1/notes.md"
  out=$(FM_BACKEND=tmux overlay "$file" 2>&1)
  assert_contains "$out" "$file" "a note beside a report should fall back to its own path"
  assert_not_contains "$out" "/report/sample-report-r1" \
    "a note beside a report must not be given that report's link"
  pass "only data/<task-id>/report.md earns a chart-room link; the rest name their own path"
}

test_a_missing_or_wrong_source_is_a_real_error() {
  local out status
  out=$(overlay no-such-task-q9 2>&1)
  status=$?
  expect_code 1 "$status" "a missing source must be a real error, not a silent link"
  assert_contains "$out" "no Markdown source found" "the missing source was not named"
  out=$(overlay "$HOME_DIR/data/plain.txt" 2>&1)
  status=$?
  expect_code 1 "$status" "a non-Markdown source must be refused"
  assert_contains "$out" "refusing non-Markdown file" "the refusal did not say why"
  pass "a missing or non-Markdown source refuses instead of pretending"
}

test_a_non_herdr_terminal_steps_aside_with_a_link
test_a_missing_herdr_steps_aside_with_a_link
test_no_installed_viewer_steps_aside_and_installs_nothing
test_an_installed_viewer_opens_an_overlay_pane
test_an_explicit_plugin_and_placement_win
test_a_refused_pane_steps_aside_with_a_link
test_link_only_never_touches_the_terminal
test_a_plain_markdown_path_falls_back_to_its_own_path
test_only_a_task_report_earns_a_chart_room_link
test_a_missing_or_wrong_source_is_a_real_error

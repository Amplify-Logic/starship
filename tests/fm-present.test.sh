#!/usr/bin/env bash
# Behavior tests for once-only captain-action presentation routing.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRESENT="$ROOT/bin/fm-present.sh"
TMP_ROOT=$(fm_test_tmproot fm-present-tests)
TMP_ROOT="$(cd "$(dirname "$TMP_ROOT")" && pwd -P)/$(basename "$TMP_ROOT")"
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
REPORT_LOG="$TMP_ROOT/report.log"
DECISION_LOG="$TMP_ROOT/decision.log"
OPEN_LOG="$TMP_ROOT/open.log"
mkdir -p "$HOME_DIR/data/sample-report" "$HOME_DIR/state" "$FAKEBIN" "$TMP_ROOT/artifacts/folder"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT HUP INT TERM

printf '# Sample report\n\nInitial finding.\n' > "$HOME_DIR/data/sample-report/report.md"
printf 'plain artifact\n' > "$TMP_ROOT/artifacts/result.txt"
printf 'folder artifact\n' > "$TMP_ROOT/artifacts/folder/item.txt"

cat > "$FAKEBIN/fm-read" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_PRESENT_REPORT_LOG"
[ "${FM_PRESENT_FAIL_REPORT:-0}" != 1 ] || exit 1
[ "${FM_PRESENT_SIGNAL_REPORT:-0}" != 1 ] || { kill -TERM "$PPID"; exit 1; }
[ -z "${FM_PRESENT_REPORT_DELAY:-}" ] || sleep "$FM_PRESENT_REPORT_DELAY"
printf 'http://127.0.0.1:4389/session/report\n'
SH

cat > "$FAKEBIN/fm-decision-surface" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_PRESENT_DECISION_LOG"
case "${1:-}" in
  generate)
    mkdir -p "$FM_HOME/.lavish"
    cat > "$FM_HOME/.lavish/captain-decisions.html" <<'HTML'
<script id="fm-decision-data" type="application/json">{"generated_at":"changes-each-generation","decisions":[{"id":"hold-choice","origin":"choice-origin","key":"route","reason":"Choose north or south"},{"id":"hold-retry","origin":"retry-origin","key":"retry","reason":"Retry the presentation"}]}</script>
HTML
    ;;
  open)
    [ "${FM_PRESENT_FAIL_DECISION:-0}" != 1 ] || exit 1
    printf 'http://127.0.0.1:4388/session/decision\n'
    ;;
esac
SH

cat > "$FAKEBIN/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_PRESENT_OPEN_LOG"
if [ "${FM_PRESENT_FAIL_OPEN:-0}" = 1 ]; then
  exit 1
fi
if [ "${FM_PRESENT_FAIL_REVEAL:-0}" = 1 ] && [ "${1:-}" = -R ]; then
  exit 1
fi
SH
chmod +x "$FAKEBIN/fm-read" "$FAKEBIN/fm-decision-surface" "$FAKEBIN/open" "$PRESENT"

run_present() {
  FM_HOME="$HOME_DIR" \
    FM_PRESENT_GUI="${FM_PRESENT_TEST_GUI:-1}" \
    FM_PRESENT_READ_BIN="$FAKEBIN/fm-read" \
    FM_PRESENT_DECISION_BIN="$FAKEBIN/fm-decision-surface" \
    FM_PRESENT_OPEN_BIN="$FAKEBIN/open" \
    FM_PRESENT_REPORT_LOG="$REPORT_LOG" \
    FM_PRESENT_DECISION_LOG="$DECISION_LOG" \
    FM_PRESENT_OPEN_LOG="$OPEN_LOG" \
    "$PRESENT" "$@"
}

report_out=$(run_present report sample-report)
assert_contains "$report_out" "http://127.0.0.1:4389/session/report" "report did not route through fm-read"
[ "$(cat "$REPORT_LOG")" = sample-report ] || fail "report route changed its owner input"

decision_out=$(run_present decision choice-origin)
assert_contains "$decision_out" "http://127.0.0.1:4388/session/decision" "decision did not route through the decision surface"
assert_grep 'generate' "$DECISION_LOG" "decision route did not generate the existing surface"
assert_grep "open --page $HOME_DIR/.lavish/captain-decisions.html" "$DECISION_LOG" \
  "decision route did not open the generated private page"

file_out=$(run_present reveal "$TMP_ROOT/artifacts/result.txt")
[ "$file_out" = "$TMP_ROOT/artifacts/result.txt" ] || fail "file reveal did not print its full path"
assert_grep "-R $TMP_ROOT/artifacts/result.txt" "$OPEN_LOG" "file reveal did not use open -R"
folder_out=$(run_present reveal "$TMP_ROOT/artifacts/folder")
[ "$folder_out" = "$TMP_ROOT/artifacts/folder" ] || fail "folder reveal did not print its full path"
assert_grep "$TMP_ROOT/artifacts/folder" "$OPEN_LOG" "folder reveal did not use open on the folder"
pass "report, decision, file reveal, and folder reveal select their existing owners"

report_calls=$(wc -l < "$REPORT_LOG" | tr -d ' ')
dedupe_out=$(run_present report sample-report)
[ "$dedupe_out" = "$HOME_DIR/data/sample-report/report.md" ] || fail "deduplicated report did not print its source path"
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" = "$report_calls" ] || fail "unchanged report stole focus twice"
receipts=$(find "$HOME_DIR/state" -name '.fm-present-*.receipt' -type f | wc -l | tr -d ' ')
[ "$receipts" -ge 4 ] || fail "presentation routes did not leave digest-bound receipts"
printf '\nChanged finding.\n' >> "$HOME_DIR/data/sample-report/report.md"
run_present report sample-report >/dev/null
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" -eq $((report_calls + 1)) ] \
  || fail "changed report was suppressed by an older receipt"
pass "artifact digest and milestone receipts suppress only unchanged re-notifications"

printf '\nAway-only change.\n' >> "$HOME_DIR/data/sample-report/report.md"
touch "$HOME_DIR/state/.afk"
before_away=$(wc -l < "$REPORT_LOG" | tr -d ' ')
afk_out=$(run_present report sample-report)
[ "$afk_out" = "$HOME_DIR/data/sample-report/report.md" ] || fail "away suppression did not print the report path"
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" = "$before_away" ] || fail "away mode opened a report"
rm "$HOME_DIR/state/.afk"
run_present report sample-report >/dev/null
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" -eq $((before_away + 1)) ] \
  || fail "away suppression incorrectly consumed the once-only receipt"
pass "away mode prints the artifact and neither opens nor receipts it"

printf 'headless artifact\n' > "$TMP_ROOT/artifacts/headless.txt"
before_headless=$(wc -l < "$OPEN_LOG" | tr -d ' ')
headless_out=$(FM_PRESENT_TEST_GUI=0 run_present reveal "$TMP_ROOT/artifacts/headless.txt")
[ "$headless_out" = "$TMP_ROOT/artifacts/headless.txt" ] || fail "headless fallback did not print the full path"
[ "$(wc -l < "$OPEN_LOG" | tr -d ' ')" = "$before_headless" ] || fail "headless fallback invoked a GUI command"
pass "headless presentation prints the artifact and exits successfully"

printf 'fallback text\n' > "$TMP_ROOT/artifacts/fallback.txt"
FM_PRESENT_FAIL_REVEAL=1 run_present reveal "$TMP_ROOT/artifacts/fallback.txt" >/dev/null
assert_grep "-R $TMP_ROOT/artifacts/fallback.txt" "$OPEN_LOG" "plain-text fallback skipped reveal-first routing"
assert_grep "-t $TMP_ROOT/artifacts/fallback.txt" "$OPEN_LOG" "failed reveal did not use open -t for plain text"
pass "open -t is used only after plain-text reveal fails"

printf '\nRetry after failure.\n' >> "$HOME_DIR/data/sample-report/report.md"
before_failed_report=$(wc -l < "$REPORT_LOG" | tr -d ' ')
FM_PRESENT_FAIL_REPORT=1 run_present report sample-report >/dev/null
run_present report sample-report >/dev/null
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" -eq $((before_failed_report + 2)) ] \
  || fail "failed report presentation consumed its receipt"

before_failed_decision=$(grep -c '^open ' "$DECISION_LOG")
FM_PRESENT_FAIL_DECISION=1 run_present decision retry-origin >/dev/null
run_present decision retry-origin >/dev/null
[ "$(grep -c '^open ' "$DECISION_LOG")" -eq $((before_failed_decision + 2)) ] \
  || fail "failed decision presentation consumed its receipt"

printf 'retry reveal\n' > "$TMP_ROOT/artifacts/retry.txt"
before_failed_reveal=$(wc -l < "$OPEN_LOG" | tr -d ' ')
FM_PRESENT_FAIL_OPEN=1 run_present reveal "$TMP_ROOT/artifacts/retry.txt" >/dev/null
run_present reveal "$TMP_ROOT/artifacts/retry.txt" >/dev/null
[ "$(wc -l < "$OPEN_LOG" | tr -d ' ')" -eq $((before_failed_reveal + 3)) ] \
  || fail "failed reveal presentation consumed its receipt"
pass "failed owner and open presentations remain retryable"

printf '\nConcurrent claim.\n' >> "$HOME_DIR/data/sample-report/report.md"
before_concurrent=$(wc -l < "$REPORT_LOG" | tr -d ' ')
FM_PRESENT_REPORT_DELAY=0.2 run_present report sample-report >/dev/null &
first_pid=$!
FM_PRESENT_REPORT_DELAY=0.2 run_present report sample-report >/dev/null &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" -eq $((before_concurrent + 1)) ] \
  || fail "concurrent presentation bypassed the atomic receipt claim"

printf '\nInterrupted claim.\n' >> "$HOME_DIR/data/sample-report/report.md"
before_interrupted=$(wc -l < "$REPORT_LOG" | tr -d ' ')
if FM_PRESENT_SIGNAL_REPORT=1 run_present report sample-report >/dev/null 2>&1; then
  fail "interrupted presentation unexpectedly succeeded"
fi
run_present report sample-report >/dev/null
[ "$(wc -l < "$REPORT_LOG" | tr -d ' ')" -eq $((before_interrupted + 2)) ] \
  || fail "interrupted presentation consumed its receipt"
pass "atomic claims deduplicate concurrency and interruptions remain retryable"

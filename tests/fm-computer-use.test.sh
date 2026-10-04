#!/usr/bin/env bash
# tests/fm-computer-use.test.sh - bin/fm-computer-use.sh: the pinned Peekaboo
# check and installer, the compact element list, the settle wait, the dialog
# classifier, the focus and dialog guard, and its transcription fact.
#
# Nothing here reads the real screen or runs a real peekaboo: every peekaboo is
# a fake on a private PATH, every screen state is a --facts file, and the
# installer is pointed at a local archive through the FM_TEST_SEAM seam with a
# private HOME, so no case can touch the host's ~/.local.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CU="$ROOT/bin/fm-computer-use.sh"
FIX="$ROOT/tests/fixtures/computer-use"
TMP_ROOT=$(fm_test_tmproot fm-computer-use)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# fake_peekaboo <dir> <version-line> [exit-code]: answers --version with the
# given line (on stderr when it fails, as a dyld failure does).
fake_peekaboo() {
  mkdir -p "$1"
  cat > "$1/peekaboo" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  if [ "${3:-0}" = 0 ]; then printf '%s\n' '$2'; else printf '%s\n' '$2' >&2; fi
  exit ${3:-0}
fi
exit 0
SH
  chmod 0755 "$1/peekaboo"
}

run_check() {  # <path-dir> -> prints "rc|output"
  local out rc
  out=$(PATH="$1:$BASE_PATH" "$CU" check 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

test_check_reports_absent_wrong_and_broken() {
  local d
  d="$TMP_ROOT/check-none"; mkdir -p "$d"
  assert_equals "1|peekaboo absent - pinned 4.5.0" "$(run_check "$d")" "an absent peekaboo must be reported with the pin"
  d="$TMP_ROOT/check-pinned"; fake_peekaboo "$d" "Peekaboo 4.5.0 (main/a1d48b28a, built: 2026-09-22T08:33:35-07:00)"
  assert_equals "0|" "$(run_check "$d")" "the pinned version must pass silently"
  d="$TMP_ROOT/check-newer"; fake_peekaboo "$d" "Peekaboo 4.6.0 (main/abc, built: 2026-09-26)"
  assert_equals "1|peekaboo 4.6.0 installed, pinned 4.5.0" "$(run_check "$d")" "another version must be reported, newer included"
  d="$TMP_ROOT/check-dev"; fake_peekaboo "$d" "peekaboo development build"
  assert_equals "1|peekaboo unrecognised installed, pinned 4.5.0" "$(run_check "$d")" "an unparseable version must be reported"
  d="$TMP_ROOT/check-broken"; fake_peekaboo "$d" "dyld[1]: Symbol not found: _swift_initBorrow" 134
  assert_equals "1|peekaboo does not start: dyld[1]: Symbol not found: _swift_initBorrow" "$(run_check "$d")" \
    "a binary that fails to start must be reported with its first error line"
  pass "check is silent only for the pinned version and names absent, other, unrecognised and broken copies"
}

# make_archive <dir> <version-line>: a release-shaped archive holding a fake peekaboo.
make_archive() {
  local stage="$1/stage"
  mkdir -p "$stage/peekaboo-macos-arm64"
  fake_peekaboo "$stage/peekaboo-macos-arm64" "$2"
  printf 'fixture\n' > "$stage/peekaboo-macos-arm64/libswiftCompatibilitySpan.dylib"
  tar -czf "$1/peekaboo.tar.gz" -C "$stage" peekaboo-macos-arm64
  rm -rf "$stage"
}

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

test_install_verifies_and_links_user_level() {
  local d home out rc digest
  d="$TMP_ROOT/install"; home="$d/home"; mkdir -p "$home"
  make_archive "$d" "Peekaboo 4.5.0 (fixture)"
  digest=$(sha "$d/peekaboo.tar.gz")

  out=$(HOME="$home" FM_TEST_PEEKABOO_TARBALL_URL="file://$d/peekaboo.tar.gz" \
    FM_TEST_PEEKABOO_TARBALL_SHA256=0000000000000000000000000000000000000000000000000000000000000000 "$CU" install 2>&1)
  rc=$?
  assert_equals 4 "$rc" "a digest mismatch must fail the install"
  assert_contains "$out" "sha256 mismatch" "a digest mismatch must say so"
  [ ! -e "$home/.local/bin/peekaboo" ] || fail "a failed install must leave nothing linked"

  out=$(HOME="$home" FM_TEST_PEEKABOO_TARBALL_URL="file://$d/peekaboo.tar.gz" FM_TEST_PEEKABOO_TARBALL_SHA256="$digest" "$CU" install 2>&1) \
    || fail "a verified archive must install: $out"
  [ -L "$home/.local/bin/peekaboo" ] || fail "install must link ~/.local/bin/peekaboo"
  assert_equals "$home/.local/lib/peekaboo/4.5.0/peekaboo" "$(readlink "$home/.local/bin/peekaboo")" "the link must point into the versioned directory"
  [ -f "$home/.local/lib/peekaboo/4.5.0/libswiftCompatibilitySpan.dylib" ] || fail "the bundled library must sit beside the binary"
  assert_equals "0|" "$(run_check "$home/.local/bin")" "the installed copy must pass the check"

  out=$(HOME="$home" FM_TEST_PEEKABOO_TARBALL_URL="file://$d/missing.tar.gz" "$CU" install 2>&1) \
    || fail "a second install must be a no-op: $out"
  assert_contains "$out" "already installed" "a second install must say it is already installed"

  home="$d/foreign"; mkdir -p "$home/.local/bin"
  printf '#!/bin/sh\necho mine\n' > "$home/.local/bin/peekaboo"
  chmod 0755 "$home/.local/bin/peekaboo"
  out=$(HOME="$home" FM_TEST_PEEKABOO_TARBALL_URL="file://$d/peekaboo.tar.gz" FM_TEST_PEEKABOO_TARBALL_SHA256="$digest" "$CU" install 2>&1)
  assert_equals 4 "$?" "a foreign peekaboo must not be replaced"
  assert_contains "$out" "is not this installer's link" "the refusal must say why"
  assert_equals "mine" "$("$home/.local/bin/peekaboo")" "the foreign copy must be untouched"
  pass "install verifies the pinned digest, links a versioned user-level copy, is idempotent, and never replaces a foreign copy"
}

test_elements_render_compactly() {
  local out
  out=$("$CU" elements --from "$FIX/see-settings.json") || fail "elements must render the fixture"
  assert_equals "app: Ableton Live 12 | window: Settings | dialog: no | snapshot: ps1_fixture0001 | elements: 7/7" \
    "$(printf '%s\n' "$out" | sed -n 1p)" "the header must name the app, window, dialog state, snapshot and counts"
  assert_contains "$out" "elem_2 button 'close button'" "an actionable element keeps a role-description label"
  assert_contains "$out" "elem_3 button 'Link, Tempo & MIDI' (selected)" "selected state must show"
  assert_contains "$out" "elem_4 button 'Plug-Ins' (disabled)" "disabled state must show"
  assert_contains "$out" "elem_5 checkbox 'VST3_System_Folders_Toggle' = 1" "a label that repeats the value must fall back to the identifier"
  assert_contains "$out" "elem_6 text 'Control Surface 1'" "readable text must be listed with its text"
  assert_contains "$out" "elem_8 popUpButton 'Control Surface' = AbletonMCP" "a value must follow its label"
  assert_not_contains "$out" "elem_1 " "a bare layout group must be left out by default"
  assert_not_contains "$out" "elem_7 " "a bare cell must be left out by default"
  out=$("$CU" elements --from "$FIX/see-settings.json" --all --max 2)
  assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "elements: 2/9" "--all with --max must count every element and cap the list"
  assert_equals 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "--max must cap the listed lines"
  printf '{"data":{}}' > "$TMP_ROOT/empty.json"
  "$CU" elements --from "$TMP_ROOT/empty.json" >/dev/null 2>&1 && fail "output without ui_elements must fail"
  pass "elements renders one compact line per useful element with state, and refuses malformed output"
}

# see_json <n> [app]: a successful `see --json` read holding <n> labelled buttons.
see_json() {
  python3 - "$1" "${2:-Demo}" <<'PY'
import json, sys
n, app = int(sys.argv[1]), sys.argv[2]
els = [{"id": f"elem_{i}", "role": "button", "label": f"Button {i}", "is_actionable": True} for i in range(1, n + 1)]
print(json.dumps({"success": True, "data": {"application_name": app, "window_title": "W", "is_dialog": False,
      "snapshot_id": "s1", "screenshot_annotated": "/tmp/fm-cu-shot_annotated.png", "ui_elements": els}}))
PY
}

see_error() {  # <message>: a failed `see --json` read as Peekaboo prints it.
  python3 -c 'import json, sys; print(json.dumps({"success": False, "data": None, "error": {"message": sys.argv[1], "code": "INTERACTION_FAILED"}}))' "$1"
}

# fake_see <dir>: a peekaboo whose `see` answers from <dir>/<mode>-<app>.json
# (mode tree for --no-screenshot reads, shot otherwise), exiting 1 when the
# answer is a failure. Every call's arguments are appended to <dir>/calls.
fake_see() {
  mkdir -p "$1"
  cat > "$1/peekaboo" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/calls"
[ "\${1:-}" = see ] || exit 0
app="" mode=shot prev=""
for a in "\$@"; do
  [ "\$prev" = --app ] && app=\$a
  [ "\$a" = --no-screenshot ] && mode=tree
  prev=\$a
done
f="$1/\$mode-\$app.json"
if [ ! -f "\$f" ]; then
  printf '{"success":false,"data":null,"error":{"message":"Application %s not found"}}\n' "\$app"
  exit 1
fi
cat "\$f"
grep -q '"success": false' "\$f" && exit 1
exit 0
SH
  chmod 0755 "$1/peekaboo"
}

test_elements_read_the_list_without_a_screenshot() {
  local d out err rc
  d="$TMP_ROOT/tree-first"; fake_see "$d"
  see_json 8 > "$d/tree-Demo.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Demo) || fail "a readable list must render: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "elements: 8/8" "the element list must render"
  assert_not_contains "$(sed -n 1p <<<"$out")" "screenshot:" "a full list must not take a screenshot"
  assert_equals 1 "$(wc -l < "$d/calls" | tr -d ' ')" "a full list must take one read"
  assert_contains "$(cat "$d/calls")" "--tree --no-screenshot" "the first read must skip the screenshot"

  d="$TMP_ROOT/hidden"; fake_see "$d"
  see_error "Window not found: accessible window for PID 82064" > "$d/tree-WhatsApp.json"
  err=$(PATH="$d:$BASE_PATH" "$CU" elements --app WhatsApp 2>&1 >/dev/null)
  rc=$?
  assert_equals 1 "$rc" "an unreadable window must fail"
  assert_equals "fm-computer-use.sh: peekaboo could not read WhatsApp: Window not found: accessible window for PID 82064" "$err" \
    "a failed read must pass Peekaboo's own reason through"

  d="$TMP_ROOT/truncated"; fake_see "$d"
  see_json 8 | python3 -c 'import json, sys; doc = json.load(sys.stdin); doc["data"]["truncation"] = {"incomplete_accessibility_read": False, "max_element_count_reached": True, "warning": "Warning: AX tree truncated at element count 1000. Narrow the target."}; print(json.dumps(doc))' > "$d/tree-Finder.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Finder) || fail "a truncated read must still render: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "elements: 8/8 | partial: Warning: AX tree truncated at element count 1000. Narrow the target." \
    "a successful read Peekaboo marks partial must say so in the header"
  assert_equals 1 "$(wc -l < "$d/calls" | tr -d ' ')" "a partial read must not be retried"

  d="$TMP_ROOT/read-only"; fake_see "$d"
  see_json 8 | python3 -c 'import json, sys; doc = json.load(sys.stdin); doc["data"]["snapshot_reusable"] = False; print(json.dumps(doc))' > "$d/tree-Demo.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Demo) || fail "a read-only snapshot must still render: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "| snapshot: s1 (read-only) | elements: 8/8" "a snapshot Peekaboo calls not reusable must be marked read-only"
  pass "elements reads the element list without a screenshot, marks a partial or read-only list, and passes Peekaboo's reason through"
}

test_elements_take_a_screenshot_only_when_asked_or_thin() {
  local d out err rc
  d="$TMP_ROOT/thin"; fake_see "$d"
  see_json 2 > "$d/tree-Live.json"
  see_json 3 Live > "$d/shot-Live.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Live) || fail "a thin list with an image must succeed: $out"
  assert_equals "app: Live | window: W | dialog: no | snapshot: s1 | elements: 3/3 | screenshot: /tmp/fm-cu-shot_annotated.png" \
    "$(sed -n 1p <<<"$out")" "a thin list must be replaced by the annotated image read and name its image"
  assert_contains "$(sed -n 2p "$d/calls")" "--annotate --path" "the image read must be annotated and saved"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Live --thin 0)
  assert_not_contains "$(sed -n 1p <<<"$out")" "screenshot:" "--thin 0 must never take an image"

  d="$TMP_ROOT/asked"; fake_see "$d"
  see_json 8 > "$d/tree-Demo.json"
  see_json 8 > "$d/shot-Demo.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Demo --screenshot) || fail "an asked-for image must succeed: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "| screenshot: /tmp/fm-cu-shot_annotated.png" "--screenshot must take the image on a full list"

  d="$TMP_ROOT/thin-hidden"; fake_see "$d"
  see_json 2 > "$d/tree-Notes.json"
  see_error "Desktop observation target was not found: shareable window for Notes. reason=window minimized" > "$d/shot-Notes.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Notes 2>"$TMP_ROOT/thin-hidden.err")
  rc=$?
  assert_equals 0 "$rc" "a thin list whose window cannot be imaged must still succeed"
  assert_contains "$(sed -n 1p <<<"$out")" "elements: 2/2" "the element list must still be printed"
  assert_contains "$(cat "$TMP_ROOT/thin-hidden.err")" "no window image of Notes: Desktop observation target was not found" "the image failure must give Peekaboo's reason"
  err=$(PATH="$d:$BASE_PATH" "$CU" elements --app Notes --screenshot 2>&1 >/dev/null)
  rc=$?
  assert_equals 1 "$rc" "an asked-for image that cannot be taken must fail"
  assert_contains "$err" "window minimized" "the asked-for image failure must give Peekaboo's reason"
  pass "elements takes an annotated window image only when asked or when the list is thin, and keeps the list when the image fails"
}

test_elements_resolve_an_ambiguous_name_to_its_bundle_id() {
  local d out err long
  long="Multiple apps match 'Arc'. Did you mean: $(printf 'Helper %s, ' $(seq 1 80))Arc"
  d="$TMP_ROOT/ambiguous"; fake_see "$d"
  see_error "$long" > "$d/tree-Arc.json"
  see_json 18 Arc > "$d/tree-company.thebrowser.Browser.json"
  fake_osascript "$d" 0 company.thebrowser.Browser
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Arc) || fail "an ambiguous name with one running app must resolve: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "app: Arc (company.thebrowser.Browser) | " "the resolved read must name the bundle id to act with"
  assert_contains "$(sed -n 2p "$d/calls")" "--app company.thebrowser.Browser" "the retry must read by bundle id"
  see_json 18 Arc > "$d/shot-company.thebrowser.Browser.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" elements --app Arc --screenshot) || fail "a resolved name must take its image by bundle id: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "app: Arc (company.thebrowser.Browser) | " "the image read must name the bundle id too"

  d="$TMP_ROOT/ambiguous-two"; fake_see "$d"
  see_error "$long" > "$d/tree-Arc.json"
  fake_osascript "$d" 0 "$(printf 'one.app\ntwo.app')"
  err=$(PATH="$d:$BASE_PATH" "$CU" elements --app Arc 2>&1 >/dev/null) && fail "a name matching two running apps must not guess"
  assert_contains "$err" "peekaboo could not read Arc: Multiple apps match 'Arc'" "the refusal must give Peekaboo's reason"
  assert_contains "$err" "... - pass the bundle id instead" "a long reason must be cut and say what to pass instead"
  [ "${#err}" -lt 420 ] || fail "a long reason must be cut, got ${#err} characters"
  pass "elements retries an ambiguous app name by the bundle id of its one running app, and never guesses between two"
}

test_front_reads_the_frontmost_window() {
  local d out
  d="$TMP_ROOT/front"; fake_see "$d"
  see_json 9 Notes > "$d/tree-frontmost.json"
  out=$(PATH="$d:$BASE_PATH" "$CU" front) || fail "front must read the frontmost window: $out"
  assert_contains "$(sed -n 1p <<<"$out")" "app: Notes | " "the header must name the app in front"
  assert_contains "$(cat "$d/calls")" "see --app frontmost --tree --no-screenshot" "front must read the frontmost app without a screenshot"
  PATH="$d:$BASE_PATH" "$CU" front --app Notes >/dev/null 2>&1; assert_equals 2 "$?" "front must refuse --app"
  pass "front reads whatever window is in front without a screenshot"
}

# fake_see_sequence <dir> <n-changing>: a peekaboo whose `see` returns a list
# that changes for the first <n-changing> reads and then stays the same.
fake_see_sequence() {
  mkdir -p "$1"
  cat > "$1/peekaboo" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = see ] || exit 0
printf '%s\n' "\$*" >> "$1/calls"
n=\$(cat "$1/count" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$1/count"
label="Loading \$n"
[ "$2" != never ] && [ "\$n" -gt "$2" ] && label=Ready
printf '{"data":{"application_name":"Demo","window_title":"W","is_dialog":false,"snapshot_id":"s%s","ui_elements":[{"id":"elem_1","role":"button","label":"%s","is_actionable":true}]}}\n' "\$n" "\$label"
SH
  chmod 0755 "$1/peekaboo"
}

test_settle_waits_for_two_equal_reads() {
  local d out rc
  d="$TMP_ROOT/settle"; fake_see_sequence "$d" 2
  out=$(PATH="$d:$BASE_PATH" "$CU" settle --app Demo --timeout 5 --interval 0.05) || fail "a list that stops changing must settle: $out"
  assert_contains "$out" "elem_1 button 'Ready'" "settle must print the settled list"
  assert_equals 4 "$(cat "$d/count")" "settle must stop at the first two equal reads (snapshot ids differ)"
  assert_equals 4 "$(grep -c -- '--no-screenshot' "$d/calls")" "settle must re-read the list without screenshots, even a thin one"
  d="$TMP_ROOT/settle-never"; fake_see_sequence "$d" never
  out=$(PATH="$d:$BASE_PATH" "$CU" settle --app Demo --timeout 1 --interval 0.05 2>&1)
  rc=$?
  assert_equals 3 "$rc" "a list that keeps changing must time out with exit 3"
  assert_contains "$out" "did not settle within 1s" "the timeout must say so"
  pass "settle returns on the first two matching reads and times out on a list that never settles"
}

test_dialog_kinds() {
  local label text want got n=0
  while IFS='^' read -r label text want; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    got=$("$CU" dialog-kind "$text")
    assert_equals "$want" "$got" "$label"
  done <<'ROWS'
privacy prompt^"Ableton Live 12" would like to access files in your Desktop folder. Don't Allow Allow^privacy
password prompt^Terminal wants to use your password. Cancel OK^privacy
save on close^Save changes to "Demo Song" before closing? Don't Save Cancel Save^save
replace export^A file named "Mixdown.wav" already exists. Do you want to replace it? Cancel Replace^replace
delete^Are you sure you want to delete "Take 3"? Cancel Delete^destructive
quit^Do you want to quit Ableton Live? Cancel Quit^quit
software update restart^macOS Tahoe 26.6 is available. Your Mac will restart to install it. Later Install Now^quit
plain notice^Plug-in scan complete. OK^other
ROWS
  [ "$n" -eq 8 ] || fail "the classifier table must run every row"
  pass "dialog-kind classifies privacy, save, replace, destructive, quit and other dialogs"
}

facts() {  # <file> <json>
  printf '%s\n' "$2" > "$TMP_ROOT/$1"
  printf '%s\n' "$TMP_ROOT/$1"
}

run_guard() {  # <facts-file> [args...] -> "rc|output"
  local f=$1 out rc
  shift
  out=$("$CU" guard --facts "$f" "$@" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

test_guard_decisions() {
  local calm dialog_save dialog_privacy busy mic unknown_mic noidle out
  calm=$(facts calm.json '{"frontmost_app":"Live","frontmost_bundle":"com.ableton.live","focused_role":"AXTextField","focused_label":"Search (Cmd+F)","dialogs":[],"idle_seconds":12.5,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  out=$(run_guard "$calm" --app Live)
  assert_equals "0|allow: Live in front, idle 12.5s, microphone off" "$out" "a calm screen with the right app must allow"
  out=$(run_guard "$calm" --app com.ableton.live); assert_equals 0 "${out%%|*}" "a bundle id must match the frontmost app"
  out=$(run_guard "$calm" --app Finder)
  assert_equals "1|refuse: Live is in front, not Finder" "$out" "another frontmost app must refuse"
  out=$(run_guard "$calm" --app Live --field search); assert_equals 0 "${out%%|*}" "a matching focused field must allow"
  out=$(run_guard "$calm" --app Live --field Tempo)
  assert_equals "1|refuse: the focused element is 'AXTextField Search (Cmd+F)', not 'Tempo'" "$out" "a different focused field must refuse"

  busy=$(facts busy.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":0.4,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  assert_equals "1|refuse: the keyboard or mouse was used 0.4s ago and no 3s quiet window came within 0s" "$(run_guard "$busy" --app Live --wait 0)" \
    "recent input must refuse once the wait is spent, without blaming anyone"
  out=$(run_guard "$busy" --app Live --quiet 0); assert_equals 0 "${out%%|*}" "--quiet 0 must accept any idle time"

  mic=$(facts mic.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":30,"microphone_in_use":true,"desk_transcription_in_flight":false}')
  assert_equals "1|refuse: the microphone is in use (dictation or a call)" "$(run_guard "$mic" --app Live)" "dictation must refuse"
  unknown_mic=$(facts unknown-mic.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":30,"microphone_in_use":null,"desk_transcription_in_flight":false}')
  assert_equals "1|refuse: could not tell whether the microphone is in use" "$(run_guard "$unknown_mic" --app Live)" \
    "an unreadable microphone state must refuse"
  noidle=$(facts noidle.json '{"frontmost_app":"Live","dialogs":[],"microphone_in_use":false,"desk_transcription_in_flight":false}')
  assert_equals "1|refuse: could not tell when the keyboard or mouse was last used" "$(run_guard "$noidle" --app Live)" \
    "an unreadable idle time must refuse"

  dialog_save=$(facts save.json '{"frontmost_app":"Live","dialogs":[{"app":"Live","title":"","text":["Save changes to \"Demo Song\" before closing?"],"buttons":["Don'"'"'t Save","Cancel","Save"]}],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  out=$(run_guard "$dialog_save" --app Live)
  assert_equals 1 "${out%%|*}" "an open save dialog must refuse"
  assert_contains "$out" "a save dialog is open in Live" "the refusal must name the dialog kind and app"
  assert_contains "$out" "[Don't Save, Cancel, Save]" "the refusal must list the buttons"
  out=$(run_guard "$dialog_save" --app Live --allow-dialog save)
  assert_equals "0|allow: Live in front, idle 30.0s, microphone off, allowed dialog: save" "$out" "an explicitly allowed save dialog must allow"

  dialog_privacy=$(facts privacy.json '{"frontmost_app":"Live","dialogs":[{"app":"UserNotificationCenter","title":"","text":["\"Ableton Live 12\" would like to access files in your Desktop folder."],"buttons":["Don'"'"'t Allow","Allow"]}],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  out=$(run_guard "$dialog_privacy" --app Live --allow-dialog save)
  assert_contains "$out" "refuse: a privacy dialog is open in UserNotificationCenter" "allowing one kind must not allow another"
  out=$(run_guard "$(facts two-dialogs.json '{"frontmost_app":"Live","dialogs":[{"app":"Live","title":"","text":[],"buttons":[]},{"app":"Live","title":"Save changes before closing?","text":[],"buttons":["Save"]},{"app":"UserNotificationCenter","title":"","text":["\"Live\" would like to access files in your Desktop folder."],"buttons":["Allow"]}],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')" \
    --app Live --allow-dialog other --allow-dialog save)
  assert_contains "$out" "1|refuse: a privacy dialog is open in UserNotificationCenter" "every dialog must be classified on its own, an empty one included"

  assert_equals "1|refuse: could not read the screen state" "$(run_guard "$(facts bad.json 'not json')" --app Live)" \
    "an unreadable state must refuse"
  assert_contains "$(run_guard "$TMP_ROOT/absent.json" --app Live)" "refuse: could not read the screen state" "a missing facts file must refuse"
  "$CU" guard --facts "$calm" >/dev/null 2>&1; assert_equals 2 "$?" "guard without --app is a usage error"
  "$CU" guard --facts "$calm" --app Live --allow-dialog anything >/dev/null 2>&1; assert_equals 2 "$?" "an unknown dialog kind is a usage error"
  pass "guard allows only the expected app, idle input, a quiet microphone and allowed dialogs, and refuses whatever it cannot read"
}

test_guard_waits_for_quiet_input() {
  local busy calm busy_mic out
  busy=$(facts wait-busy.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":0.4,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  calm=$(facts wait-calm.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":1.2,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  out=$(run_guard "$busy" --facts "$calm" --app Live --quiet 1)
  assert_equals "0|allow: Live in front, idle 1.2s, microphone off" "$out" "input that stops within the wait must allow on a later read"
  out=$(run_guard "$busy" --app Live --quiet 1 --wait 1)
  assert_equals "1|refuse: the keyboard or mouse was used 0.4s ago and no 1s quiet window came within 1s" "$out" \
    "input that keeps arriving must refuse once the wait is spent"
  busy_mic=$(facts wait-mic.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":0.4,"microphone_in_use":true,"desk_transcription_in_flight":false}')
  out=$(run_guard "$busy_mic" --facts "$calm" --app Live --quiet 1)
  assert_equals "1|refuse: the microphone is in use (dictation or a call)" "$out" "a live microphone must refuse at once, not wait"
  pass "guard waits a bounded time for a quiet input window and refuses only if input keeps arriving"
}

test_guard_refuses_during_desk_transcription() {
  local stt unknown out
  stt=$(facts stt.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":true}')
  assert_equals "1|refuse: a desk dictation is being transcribed" "$(run_guard "$stt" --app Live)" \
    "a dictation that is still being transcribed must refuse"
  unknown=$(facts stt-unknown.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":30,"microphone_in_use":false}')
  assert_equals "1|refuse: could not tell whether a desk dictation is being transcribed" "$(run_guard "$unknown" --app Live)" \
    "an unknown transcription state must refuse"
  pass "guard refuses while a desk dictation is in flight or when it cannot tell"
}

# fake_osascript <dir> <exit-code> [stdout]: records its last argument (the app
# an activation names) and prints <stdout>.
fake_osascript() {
  mkdir -p "$1"
  printf '%s\n' "${3:-}" > "$1/stdout"
  cat > "$1/osascript" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${@: -1}" >> "$1/activated"
cat "$1/stdout"
exit $2
SH
  chmod 0755 "$1/osascript"
}

run_activate() {  # <fake-dir> [args...] -> "rc|output"
  local d=$1 out rc
  shift
  out=$(PATH="$d:$BASE_PATH" "$CU" guard --activate "$@" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

test_guard_activate_checks_before_and_after() {
  local d notes notes_mic live live_dialog live_busy out
  notes=$(facts act-notes.json '{"frontmost_app":"Notes","focused_role":"AXTextArea","focused_label":"Body","dialogs":[],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  notes_mic=$(facts act-notes-mic.json '{"frontmost_app":"Notes","dialogs":[],"idle_seconds":30,"microphone_in_use":true,"desk_transcription_in_flight":false}')
  live=$(facts act-live.json '{"frontmost_app":"Live","focused_role":"AXTextField","focused_label":"Search","dialogs":[],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  live_dialog=$(facts act-live-dialog.json '{"frontmost_app":"Live","dialogs":[{"app":"UserNotificationCenter","title":"","text":["\"Ableton Live 12\" would like to access files in your Desktop folder."],"buttons":["Allow"]}],"idle_seconds":30,"microphone_in_use":false,"desk_transcription_in_flight":false}')

  d="$TMP_ROOT/act-mic"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --facts "$notes_mic" --facts "$live")
  assert_equals "1|refuse: the microphone is in use (dictation or a call)" "$out" "dictation in the captain's app must refuse before activation"
  [ ! -e "$d/activated" ] || fail "a refused pre-check must not activate the app"

  d="$TMP_ROOT/act-ok"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --field search --facts "$notes" --facts "$live")
  assert_equals "0|allow: Live in front, idle 30.0s, microphone off" "$out" "a calm screen must activate the app and allow"
  assert_equals "Live" "$(cat "$d/activated")" "the activation must name the app"

  d="$TMP_ROOT/act-dialog"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --facts "$notes" --facts "$live_dialog")
  assert_contains "$out" "1|refuse: a privacy dialog is open in UserNotificationCenter" "a dialog that appears on activation must refuse"

  live_busy=$(facts act-live-busy.json '{"frontmost_app":"Live","dialogs":[],"idle_seconds":0.1,"microphone_in_use":false,"desk_transcription_in_flight":false}')
  d="$TMP_ROOT/act-busy"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --wait 0 --facts "$notes" --facts "$live_busy")
  assert_equals "1|refuse: the keyboard or mouse was used 0.1s ago and no 3s quiet window came within 0s" "$out" \
    "input that arrives during activation must refuse"
  assert_equals "Live" "$(cat "$d/activated")" "the busy read must be the one taken after activation"
  d="$TMP_ROOT/act-busy-then-calm"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --quiet 1 --facts "$notes" --facts "$live_busy" --facts "$live")
  assert_equals "0|allow: Live in front, idle 30.0s, microphone off" "$out" "input after activation that stops within the wait must allow"

  d="$TMP_ROOT/act-stuck"; fake_osascript "$d" 0
  out=$(run_activate "$d" --app Live --wait 0 --facts "$notes")
  assert_equals "1|refuse: Notes is in front, not Live" "$out" "an app that never comes to the front must refuse"

  d="$TMP_ROOT/act-fail"; fake_osascript "$d" 1
  out=$(run_activate "$d" --app Live --facts "$notes" --facts "$live")
  assert_equals "1|refuse: could not bring Live to the front" "$out" "a failed activation must refuse"
  pass "guard --activate checks the captain's screen before activating, then re-checks the front app, input, dialogs and field"
}

test_facts_report_desk_transcription() {
  local d pid out
  d="$TMP_ROOT/facts"
  fake_osascript "$d" 0 '{"frontmost_app":"Live","frontmost_bundle":"com.ableton.live","focused_role":null,"focused_label":null,"dialogs":[]}'
  printf '#!/usr/bin/env bash\nwhile :; do sleep 0.1; done\n' > "$d/fm-deepgram-stt.sh"
  chmod 0755 "$d/fm-deepgram-stt.sh"
  "$d/fm-deepgram-stt.sh" &
  pid=$!
  out=$(PATH="$d:$BASE_PATH" "$CU" facts)
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_equals "True" "$(printf '%s' "$out" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("desk_transcription_in_flight"))')" \
    "a running fm-deepgram-stt.sh must show as a transcription in flight"
  pass "facts report a running desk transcription"
}

test_check_reports_absent_wrong_and_broken
test_install_verifies_and_links_user_level
test_elements_render_compactly
test_elements_read_the_list_without_a_screenshot
test_elements_take_a_screenshot_only_when_asked_or_thin
test_elements_resolve_an_ambiguous_name_to_its_bundle_id
test_front_reads_the_frontmost_window
test_settle_waits_for_two_equal_reads
test_dialog_kinds
test_guard_decisions
test_guard_waits_for_quiet_input
test_guard_refuses_during_desk_transcription
test_guard_activate_checks_before_and_after
test_facts_report_desk_transcription

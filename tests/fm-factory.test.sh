#!/usr/bin/env bash
# The Factory pane: bin/fm-factory.py and bin/fm-factory-pane.sh.
#
# A fixture home with neutral sample factories and a fixture fleet snapshot go
# in; the record (--data) and the screen as text (--plain) that come out are
# checked word for word. The writing keys are pressed in the real live view
# under a pseudo-terminal against a stand-in inbox that records each note, and
# the Herdr calls behind the factory tab and the plugin run against a fake
# herdr that records them, so no crew, pane or Herdr server is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-factory)
BINDIR="$TMP_ROOT/bin"
mkdir -p "$BINDIR"
FACTORY="$ROOT/bin/fm-factory.py"
PANE="$ROOT/bin/fm-factory-pane.sh"
NOW=1794643200   # 2026-11-14T08:00:00Z
export TZ=UTC FM_FACTORY_NOW=$NOW FM_FACTORY_PEEK=

# A stand-in inbox: `note` records its arguments and body, `receipts` answers
# with the notes recorded so far, the shape bin/fm-inbox.sh receipts prints.
cat > "$BINDIR/inbox" <<'SH'
#!/usr/bin/env bash
log="$FM_FACTORY_TEST_NOTES"
case "$1" in
  note)
    shift
    rid=
    while [ "$#" -gt 0 ]; do
      case "$1" in --request-id) rid=$2; shift ;; esac
      shift
    done
    body=$(cat)
    python3 - "$log" "$rid" "$body" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"request_id": sys.argv[2], "body": sys.argv[3], "at": "2026-11-14T07:59:00Z"}) + "\n")
PY
    printf '{"outcome":"created"}\n'
    ;;
  receipts)
    python3 - "$log" <<'PY'
import json, os, sys
notes = [json.loads(l) for l in open(sys.argv[1])] if os.path.exists(sys.argv[1]) else []
print(json.dumps({"pending": notes, "handled": []}))
PY
    ;;
esac
SH
chmod +x "$BINDIR/inbox"
export FM_FACTORY_INBOX="$BINDIR/inbox"

# A fake herdr that records every call and answers with the shapes Herdr 0.9.5
# returns for the calls the factory tab and the plugin make.
cat > "$BINDIR/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FACTORY_TEST_CALLS"
n=$(wc -l < "$FM_FACTORY_TEST_CALLS" | tr -d ' ')
case "$1 $2" in
  'tab create')
    [ -z "${FM_FACTORY_TEST_NO_TAB:-}" ] || { printf '{"result":{}}\n'; exit 0; }
    printf '{"result":{"tab":{"tab_id":"w1:t7"},"root_pane":{"pane_id":"w1:p20"}}}\n' ;;
  'pane split') printf '{"result":{"pane":{"pane_id":"w1:p3%s"}}}\n' "$n" ;;
  'tab get') [ -z "${FM_FACTORY_TEST_TAB_GONE:-}" ] || exit 1; printf '{"result":{"tab":{"tab_id":"%s"}}}\n' "$3" ;;
  'plugin pane')
    printf '{"result":{"plugin_pane":{"plugin_id":"starship.factory","pane":{"pane_id":"w1:p9"}}}}\n' ;;
  'plugin config-dir') printf '%s\n' "$FM_FACTORY_TEST_CONFIG" ;;
esac
exit 0
SH
chmod +x "$BINDIR/herdr"

CASE=0
reset_case() {
  CASE=$((CASE + 1))
  HOME_FIX="$TMP_ROOT/case$CASE/home"
  CALLS="$TMP_ROOT/case$CASE/calls"
  mkdir -p "$HOME_FIX/state" "$HOME_FIX/data"
  : > "$CALLS"
  export FM_HOME="$HOME_FIX" FM_FACTORY_TEST_CALLS="$CALLS" FM_FACTORY_TEST_NOTES="$TMP_ROOT/case$CASE/notes"
  export FM_FACTORY_SNAPSHOT="$HOME_FIX/snapshot.json" FM_FACTORY_TEST_CONFIG="$TMP_ROOT/case$CASE/config"
  unset FM_FACTORY_TEST_NO_TAB FM_FACTORY_TEST_TAB_GONE HERDR_BIN_PATH HERDR_PANE_ID HERDR_TAB_ID \
    HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
}

write_projects() {
  cat > "$HOME_FIX/data/projects.md" <<'MD'
- sample-shop [no-mistakes label=Shop] - an online shop for handmade cups (added 2026-11-01)
- shop-api [no-mistakes alias=orders] - the shop's order service (added 2026-11-01)
- garden-journal [direct-PR] - a phone journal for a vegetable garden (added 2026-11-02)
- recipe-box [direct-PR] - a small recipe app (added 2026-11-03)
MD
}

write_registry() {
  cat > "$HOME_FIX/data/factories.md" <<'MD'
# Factories

## Sample Shop
about: online shop for handmade cups
projects: sample-shop, shop-api

Rules:
- English only.
- Anything that touches payments waits for your yes.

Learned:
- 2026-11-12: Search results read better with the price on the first line.

## Garden Journal
projects: garden-journal

## Recipe Box
projects: recipe-box
MD
}

# write_world [quiet]: the sample fleet. Every live task carries the canonical
# current-state line the snapshot would, so each state word below comes from
# the status bar's own fold.
write_world() {
  write_projects
  python3 - "$HOME_FIX" "$NOW" "${1:-}" <<'PY'
import json, os, sys
home, now, quiet = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "quiet"
state = os.path.join(home, "state")

def meta(tid, mode="no-mistakes", started=None, kind="ship"):
    path = os.path.join(state, tid + ".meta")
    open(path, "w").write("kind=%s\nmode=%s\nyolo=off\nspawn_gen=s%d.1.1\n" % (kind, mode, started or now - 1800))
    return path

def status(tid, lines):
    path = os.path.join(state, tid + ".status")
    open(path, "w").write("\n".join(lines) + "\n")
    os.utime(path, (now - 3600, now - 3600))
    return path

def task(tid, cs, detail, project, kind="ship", mode="no-mistakes", started=None, lines=(), decisions=None, pr=None):
    m = meta(tid, mode, started, kind)
    s = status(tid, list(lines) or ["working [at=%d]: set up" % (now - 3000)])
    return {"id": tid, "kind": kind, "project": "/projects/" + project,
            "current_state": {"state": cs[0], "source": cs[1], "detail": detail,
                              "raw": "state: %s · source: %s · %s" % (cs[0], cs[1], detail)},
            "paths": {"meta": {"path": m}, "status_log": {"path": s}},
            "hints": {"open_decisions": decisions or []}, "pr": {"url": pr}}

def row(rid, title, repo, st="in_flight", **extra):
    base = {"id": rid, "title": title, "repo": repo, "state": st, "structured": True, "kind": "ship",
            "captain_actionable": False, "hold_kind": None, "hold_bucket": None, "hold_reason": None,
            "hold_set": None, "hold_until": None, "unresolved_blocker_ids": [], "since": "2026-11-13",
            "completion": {"verb": None, "date": None}, "pr_url": None}
    base.update(extra)
    return base

def busy(tid, ts):
    open(os.path.join(state, tid + ".busy-state"), "w").write(
        "v1 gen=g1 seq=2 state=busy source=claude-hook event=user-prompt-submit ts=%d\n" % ts)

tasks, rows = [], []
tasks.append(task("shop-search", ("working", "pane"), "harness busy (claude-hook)", "sample-shop",
                  started=now - 47 * 60))
busy("shop-search", now - (40 * 60 if quiet else 60))
if not quiet:
    step = os.path.join(state, "shop-search.step")
    open(step, "w").write("running the search tests: 41 of 58 passed\n")
    os.utime(step, (now - 120, now - 120))
rows.append(row("shop-search", "Search that forgives typos", "sample-shop"))
tasks.append(task("shop-checkout", ("working", "run-step"), "ci running", "orders", started=now - 112 * 60))
rows.append(row("shop-checkout", "Pay with a saved card", "shop-api"))
tasks.append(task("shop-images", ("blocked", "status-log"), "cannot reach the image store", "sample-shop",
                  lines=["blocked [at=%d]: cannot reach the image store" % (now - 1200)]))
rows.append(row("shop-images", "Sharper cup photos", "sample-shop"))
tasks.append(task("shop-labels", ("paused", "status-log"), "waiting on the carrier until 2026-11-14T09:30Z",
                  "sample-shop"))
rows.append(row("shop-labels", "Print shipping labels", "sample-shop"))
tasks.append(task("shop-old", ("unknown", "none"), "worktree gone (torn down?)", "sample-shop"))
rows.append(row("shop-old", "Old banner swap", "sample-shop"))
rows.append(row("shop-gift", "Gift wrap at checkout", "sample-shop", "queued"))
rows.append(row("shop-reviews", "Reviews under each cup", "sample-shop", "queued"))
rows.append(row("shop-later", "Discount codes", "sample-shop", "queued", hold_kind="future",
                hold_reason="after the holidays"))
summary = ("The harvest chart can open on this week or this season. "
           "Options: 1 this week (recommended), 2 this season, 3 both side by side. See /tmp/x/report.md")
tasks.append(task("garden-chart", ("parked", "status-log"), summary, "garden-journal",
                  lines=["needs-decision [at=%d] [key=chart-range]: %s" % (now - 3 * 3600, summary)],
                  decisions=[{"key": "chart-range", "verb": "needs-decision", "summary": summary}]))
rows.append(row("garden-chart", "Harvest chart", "garden-journal"))
tasks.append(task("garden-share", ("done", "status-log"), "PR https://example.invalid/g/pull/12 ready",
                  "garden-journal", mode="direct-PR", pr="https://example.invalid/g/pull/12",
                  lines=["done [at=%d]: PR https://example.invalid/g/pull/12 ready" % (now - 109 * 60)]))
rows.append(row("garden-share", "Share a garden page as a picture", "garden-journal"))
tasks.append(task("recipe-start", ("done", "status-log"), "PR merged", "recipe-box", mode="direct-PR",
                  lines=["done [at=%d]: finished" % (now - 2 * 3600)]))
rows.append(row("recipe-start", "Calmer start screen", "recipe-box", "done",
                completion={"verb": "merged", "date": "2026-11-14"}))
rows.append(row("shop-provider", "Which payment provider for the shop", "sample-shop", "queued", kind="captain",
                captain_actionable=True, hold_kind="captain", hold_bucket="live", hold_set="2026-11-13T23:00:00Z",
                hold_reason="Saved cards need a provider. Options: A the current one, B a cheaper new one, "
                            "C wait until after the holidays."))
json.dump({"schema": "fm-fleet-snapshot.v1", "generated": "2026-11-14T08:00:00Z", "tasks": tasks,
           "backlog": {"records": rows}}, open(os.path.join(home, "snapshot.json"), "w"), indent=1)
PY
}

data() { python3 "$FACTORY" --data; }
# has_line <screen> <line with runs of spaces squeezed to one> <msg>
has_line() {
  printf '%s\n' "$1" | tr -s ' ' | grep -qxF -- "$2" || fail "$3 (missing line: '$2')"$'\n'"$1"
}
q() { jq -r "$1" "$TMP_ROOT/case$CASE/record.json"; }
take_record() { data > "$TMP_ROOT/case$CASE/record.json" || fail "--data failed"; }

test_the_record_words_every_state() {
  reset_case
  write_registry
  write_world
  take_record
  assert_equals "$(q .schema)" "fm-factory.v1" "schema"
  assert_equals "$(q .count_line)" "2 jobs running · 3 need you · 1 idle" "count line"
  assert_equals "$(q '[.factories[] | .name] | join(",")')" "Sample Shop,Garden Journal,Recipe Box" "factories"
  local shop='.factories[] | select(.id == "sample-shop") | .jobs[]'
  assert_equals "$(q "[$shop | \"\(.id)=\(.state)/\(.step // \"-\")\"] | join(\" \")")" \
    "shop-search=running/building shop-checkout=running/checking shop-provider=waiting on you/- shop-images=stuck/- shop-labels=waiting/- shop-old=stopped/- shop-gift=next/- shop-reviews=later/- shop-later=on hold/-" \
    "every shop job state is a word"
  assert_equals "$(q "$shop | select(.id == \"shop-search\") | .doing")" "running the search tests: 41 of 58 passed" \
    "a stated step is the doing sentence"
  assert_equals "$(q "$shop | select(.id == \"shop-search\") | .sign_of_life_from")" "a turn" "sign of life source"
  assert_equals "$(q "$shop | select(.id == \"shop-checkout\") | .doing")" "waiting for the online checks" \
    "the checks say what they are doing"
  assert_equals "$(q "$shop | select(.id == \"shop-labels\") | .until")" "1794648600" "a wait says when it tries again"
  assert_equals "$(q '[.needs_you[] | "\(.id):\(.kind)"] | join(" ")')" \
    "garden-chart:question shop-provider:question garden-share:finished work" "needs you, questions first"
  assert_equals "$(q '.needs_you[0].options | map("\(.key) \(.label) \(.suggested)") | join("; ")')" \
    "1 this week true; 2 this season false; 3 both side by side false" "options are parsed with the suggestion"
  assert_equals "$(q '.needs_you[0].why')" "The harvest chart can open on this week or this season. See" \
    "the why keeps no path"
  assert_equals "$(q '.needs_you[0].suggested_by')" "the crew" "a worker's suggestion is the crew's"
  assert_equals "$(q '.needs_you[1].options | map(.key) | join("")')" "ABC" "lettered options"
  assert_equals "$(q '.needs_you[2].pr')" "https://example.invalid/g/pull/12" "finished work names its change"
  assert_equals "$(q '[.needs_you[].for] | unique | join(",")')" "you" "every waiting item names who it is for"
  assert_equals "$(q '.factories[] | select(.id == "recipe-box") | "\(.state) \(.idle_since)"')" "idle 1794636000" \
    "an idle factory knows since when"
  assert_equals "$(q '[.feed[] | "\(.word)|\(.actor)"] | join(" ")')" \
    "stuck|Sample Shop finished|Garden Journal finished|Recipe Box asked you|Garden Journal" "the feed, newest first"
  pass "factory record: every state is a word, needs you is ordered, the feed reads newest first"
}

test_the_plain_screen_is_the_record_as_text() {
  reset_case
  write_registry
  write_world
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" " S T A R S H I P  │  2 jobs running  ·  3 need you  ·  1 idle" "count line"
  assert_equals "$(printf '%s\n' "$out" | grep -F ' ▸ ● ' | tr -s ' ')" \
    " ▸ ● Harvest chart: a question for you Garden Journal · waiting 3 h" "the cursor starts on the first question"
  assert_contains "$out" "       1  this week  · the crew suggests this" "suggested option"
  assert_contains "$out" "       t  Talk it through" "talk it through"
  assert_contains "$out" "       ✓ planning ••••• ▸ building •••••   checking ·····   ready for you" "four steps"
  assert_contains "$out" "       running the search tests: 41 of 58 passed" "doing this minute"
  has_line "$out" " ● Sharper cup photos stuck" "a stuck job"
  has_line "$out" " ● Print shipping labels waiting · tries again 09:30" "a waiting job"
  has_line "$out" " next Gift wrap at checkout · then 2 more" "next in line"
  has_line "$out" " Recipe Box idle since 06:00 · nothing in line Starship steers" "an idle factory is one row"
  has_line "$out" " 06:00 Recipe Box finished Calmer start screen is finished." "feed row"
  assert_contains "$out" " ↑↓ move · 1/2/3 answer · enter open · t talk · s who steers · q quit" "keys"
  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop) || fail "--plain --factory failed"
  assert_contains "$out" " RULES THIS CREW FOLLOWS" "rules heading"
  assert_contains "$out" "   · Anything that touches payments waits for your yes." "a rule"
  assert_contains "$out" "   12 Nov  Search results read better with the price on the first line." "a lesson"
  has_line "$out" " · 1 on hold" "held work folds into a count"
  pass "factory record: the plain screen carries every state as a word"
}

test_a_job_with_no_sign_of_life_reads_quiet() {
  reset_case
  write_registry
  write_world quiet
  take_record
  assert_equals "$(q '.factories[0].jobs[0] | "\(.quiet) \(.doing)"')" "true at work, no step reported yet" \
    "a quiet job"
  assert_equals "$(q '.factories[0].jobs[1].quiet')" "false" "a job in the checks never reads quiet"
  assert_contains "$(python3 "$FACTORY" --plain --width 92)" "       quiet for 40 min, no sign of life" \
    "the screen says so in words"
  pass "factory record: a stalled job says how long it has been quiet"
}

test_without_a_registry_each_project_is_a_factory() {
  reset_case
  write_world
  take_record
  assert_equals "$(q .factories_from)" "projects" "fallback source"
  assert_equals "$(q '[.factories[] | "\(.id)=\(.name)"] | join(" ")')" \
    "sample-shop=Shop shop-api=Shop Api garden-journal=Garden Journal recipe-box=Recipe Box" \
    "one factory per project, named by its label or its name"
  assert_equals "$(q '.factories[] | select(.id == "shop-api") | [.jobs[].id] | join(",")')" "shop-checkout" \
    "an alias maps work to its project"
  pass "factory registry: with no registry every registered project is its own factory"
}

test_work_no_factory_claims_is_still_shown() {
  reset_case
  write_registry
  write_world
  sed -i.bak 's/^projects: garden-journal$/projects: something-else/' "$HOME_FIX/data/factories.md"
  take_record
  assert_equals "$(q '.factories[] | select(.id == "other-work") | [.jobs[].id] | join(",")')" \
    "garden-chart,garden-share" \
    "unclaimed work lands in Other work"
  pass "factory registry: work no factory claims is shown under Other work"
}

# drive_keys <keys...>: press keys in the real live view under a pty, one per
# half second, then q.
drive_keys() {
  python3 - "$FACTORY" "$@" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", sys.argv[1], "view"])
def drain(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                return
drain(1.0)
for key in sys.argv[2:] + ["q"]:
    os.write(fd, {"ENTER": b"\r", "DOWN": b"\x1b[B", "ESC": b"\x1b"}.get(key, key.encode()))
    drain(0.35)
os.waitpid(pid, 0)
PY
}

test_writing_keys_go_through_the_inbox_and_act_on_the_highlighted_row() {
  reset_case
  write_registry
  write_world
  drive_keys 2 ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" "factory.garden-journal.answer.garden-chart.2" \
    "the answer acts on the highlighted question"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "Answer for Harvest chart: 2 this season" "answer body"
  : > "$FM_FACTORY_TEST_NOTES"
  drive_keys A ESC
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a letter for another question sends nothing; esc cancels"
  drive_keys 2 x
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "any key but enter cancels the answer"
  drive_keys DOWN DOWN k ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" "factory.garden-journal.keep.garden-share" "keep"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "https://example.invalid/g/pull/12" "keep names the change"
  pass "factory pane: answer and keep go to Starship's inbox for the highlighted row only, after enter"
}

test_a_note_reaches_starship_through_the_real_inbox() {
  reset_case
  write_registry
  write_world
  touch "$HOME_FIX/state/.afk"   # the inbox then rings no primary session
  (unset FM_FACTORY_INBOX; drive_keys 2 ENTER)
  local note
  note=$(cat "$HOME_FIX"/state/inbox/*.note 2>/dev/null)
  assert_contains "$note" "request_id=factory.garden-journal.answer.garden-chart.2" "the note is saved under its id"
  assert_contains "$note" "Answer for Harvest chart: 2 this season" "the note carries the answer"
  (unset FM_FACTORY_INBOX; drive_keys 2 ENTER)
  assert_equals "$(find "$HOME_FIX/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "1" \
    "the same answer twice is one note"
  pass "factory pane: an answer is a captain inbox note, saved once under its request id"
}

test_talking_never_changes_who_steers() {
  reset_case
  write_registry
  write_world
  drive_keys DOWN DOWN DOWN t "Price on the first line" ENTER
  assert_contains "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" "factory.sample-shop.talk." "talk note"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "To the Sample Shop crew: Price on the first line" \
    "talk body"
  assert_absent "$HOME_FIX/state/factory/steer.log" "talking changed who steers"
  drive_keys DOWN DOWN DOWN s
  assert_contains "$(cat "$HOME_FIX/state/factory/steer.log")" "$(printf '\tsample-shop\tyou')" "s takes the helm"
  assert_contains "$(tail -n 1 "$FM_FACTORY_TEST_NOTES" | jq -r .body)" "I steer Sample Shop myself from now on." \
    "Starship is told"
  take_record
  assert_equals "$(q '.factories[0].steered_by')" "you" "the record shows who steers"
  assert_equals "$(q '[.feed[] | select(.actor == "you") | .word] | join(",")')" "took the helm" \
    "the change shows in the feed"
  assert_equals "$(q '[.factories[0].talk[] | "\(.who): \(.said)"] | join(" | ")')" \
    "you: Price on the first line" "the talk keeps its history"
  drive_keys DOWN DOWN DOWN s
  take_record
  assert_equals "$(q '.factories[0].steered_by')" "Starship" "s hands it back"
  pass "factory pane: talking goes to Starship and never moves the helm; only s does, both ways"
}

test_enter_opens_the_factory_tab_with_its_live_workers() {
  reset_case
  write_registry
  write_world
  local out cmd
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=w1:t1 HERDR_SOCKET_PATH=/run/a.sock \
    python3 "$FACTORY" open-tab sample-shop 2>&1) || fail "open-tab failed: $out"
  cmd=$(sed -n 2p "$CALLS")
  assert_equals "$(sed -n 1p "$CALLS")" "tab create --workspace w1 --label Sample Shop --focus" "the tab"
  assert_contains "$cmd" "pane run w1:p20 " "the page runs in the tab's first pane"
  assert_contains "$cmd" "fm-factory-pane.sh run --factory sample-shop --origin-tab w1:t1" "the page command"
  assert_equals "$(sed -n 3p "$CALLS")" "pane split w1:p20 --direction right --no-focus" "workers on the right"
  assert_contains "$(sed -n 4p "$CALLS")" "fm-factory-pane.sh follow shop-search" "a live copy of a worker"
  assert_equals "$(sed -n 5p "$CALLS")" "pane split w1:p33 --direction down --no-focus" "stacked"
  assert_equals "$(grep -c 'follow ' "$CALLS")" "4" "each worker with a pane, stopped ones left out"
  assert_equals "$(tail -n 1 "$CALLS")" "pane focus w1:p20" "focus on the page"
  : > "$CALLS"
  HERDR_BIN_PATH="$BINDIR/herdr" HERDR_SOCKET_PATH=/run/a.sock python3 "$FACTORY" open-tab sample-shop \
    || fail "second open-tab failed"
  assert_equals "$(cat "$CALLS")" "$(printf 'tab get w1:t7\ntab focus w1:t7')" "an open tab is focused, not doubled"
  pass "factory tab: enter opens the factory's tab with its page left and live workers right, once"
}

test_open_tab_stops_when_herdr_does_not_name_the_tab() {
  reset_case
  write_registry
  write_world
  local out
  if out=$(FM_FACTORY_TEST_NO_TAB=1 HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" open-tab sample-shop 2>&1); then
    fail "open-tab succeeded without a tab"
  fi
  assert_contains "$out" "Herdr opened a tab but did not name it" "the reason"
  assert_equals "$(grep -c 'pane run' "$CALLS")" "0" "nothing ran in an unknown pane"
  pass "factory tab: a tab Herdr does not name is left alone"
}

test_the_plugin_installs_opens_and_removes() {
  reset_case
  local out pid
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" bash "$PANE" install 2>&1) || fail "install failed: $out"
  assert_grep "plugin link $ROOT/herdr-plugins/starship-factory" "$CALLS" "install links the plugin"
  assert_equals "$(cat "$FM_FACTORY_TEST_CONFIG/home")" "$HOME_FIX" "install records the home"
  : > "$CALLS"
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p2 bash "$PANE" open 2>&1) || fail "open failed: $out"
  assert_equals "$(cat "$CALLS")" "plugin pane open --plugin starship.factory --entrypoint factory --placement split --direction right --target-pane w1:p2 --focus --env FM_HOME=$HOME_FIX" \
    "open puts the pane to the right"
  mkdir -p "$FM_FACTORY_TEST_CONFIG/panes"
  sleep 300 &
  pid=$!
  printf 'pane=w1:p9\n' > "$FM_FACTORY_TEST_CONFIG/panes/$pid"
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" bash "$PANE" remove 2>&1) || fail "remove failed: $out"
  kill -0 "$pid" 2>/dev/null || fail "remove stopped a process that was not a Factory pane"
  kill "$pid" 2>/dev/null
  assert_grep 'plugin unlink starship.factory' "$CALLS" "remove unlinks the plugin"
  assert_absent "$FM_FACTORY_TEST_CONFIG/panes/$pid" "the stale record is cleared"
  pass "factory pane: install links and records the home, open splits right, remove stops only its own panes"
}

fm_test_run \
  test_the_record_words_every_state \
  test_the_plain_screen_is_the_record_as_text \
  test_a_job_with_no_sign_of_life_reads_quiet \
  test_without_a_registry_each_project_is_a_factory \
  test_work_no_factory_claims_is_still_shown \
  test_writing_keys_go_through_the_inbox_and_act_on_the_highlighted_row \
  test_a_note_reaches_starship_through_the_real_inbox \
  test_talking_never_changes_who_steers \
  test_enter_opens_the_factory_tab_with_its_live_workers \
  test_open_tab_stops_when_herdr_does_not_name_the_tab \
  test_the_plugin_installs_opens_and_removes

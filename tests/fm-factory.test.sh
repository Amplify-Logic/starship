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
export TZ=UTC FM_FACTORY_NOW=$NOW FM_FACTORY_PEEK='' FM_SNAPSHOT_NOW=2026-11-14T08:00:00Z
# The owner's calls read the backlog through the tasks-axi adapter; this
# stand-in serves each case's fixture backlog (FM_TEST_AXI_BACKLOG).
fm_install_markdown_tasks_axi "$TMP_ROOT/axibin"
export PATH="$TMP_ROOT/axibin:$PATH"

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
  'pane get')
    [ ! -e "${FM_FACTORY_TEST_PANE_GET_FAILS:-}" ] || exit 1
    printf '{"result":{"pane":{"pane_id":"%s","focused":%s},"type":"pane_info"}}\n' "$3" \
      "${FM_FACTORY_TEST_FOCUSED:-false}" ;;
esac
exit 0
SH
chmod +x "$BINDIR/herdr"

# A test clock for the live pane: with FM_FACTORY_TEST_CLOCK naming a file of
# seconds, python run with PYTHONPATH=$CLOCK_SITE reads the time that far ahead.
CLOCK_SITE="$TMP_ROOT/clock-site"
mkdir -p "$CLOCK_SITE"
cat > "$CLOCK_SITE/sitecustomize.py" <<'PY'
import os
import time

if os.environ.get("FM_FACTORY_TEST_CLOCK"):
    _real_time, _offset_path = time.time, os.environ["FM_FACTORY_TEST_CLOCK"]

    def _test_time():
        with open(_offset_path) as handle:
            return _real_time() + float(handle.read())

    time.time = _test_time
PY

# A stand-in for bin/fm-tap-desk.sh shapes: the options and recommendation each
# held decision's tap card shows, from the case's fixture file.
cat > "$BINDIR/shapes" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/shapes.json"
SH
chmod +x "$BINDIR/shapes"
export FM_FACTORY_SHAPES="$BINDIR/shapes"

# edit-world drop <task> | reask <task> <at>: change the fleet while the pane
# runs (a task leaves, or its held question is held again later), then refresh
# the record the way the background refresh does.
cat > "$BINDIR/edit-world" <<SH
#!/usr/bin/env bash
python3 - "\$FM_FACTORY_SNAPSHOT" "\$@" <<'PY'
import json, sys
path, how, args = sys.argv[1], sys.argv[2], sys.argv[3:]
world = json.load(open(path))
if how == "drop":
    world["tasks"] = [t for t in world["tasks"] if t["id"] != args[0]]
elif how == "reask":
    import os, time
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(args[1])))
    for row in world["backlog"]["records"]:
        if row["id"] == args[0]:
            row["hold_set"] = stamp
    shapes_path = os.path.join(os.path.dirname(path), "shapes.json")
    shapes = json.load(open(shapes_path))
    for shape in shapes["decisions"]:
        if shape["id"] == args[0]:
            shape["held_since"], shape["identity"] = stamp, stamp + "#0"
    json.dump(shapes, open(shapes_path, "w"))
json.dump(world, open(path, "w"))
PY
exec python3 "$FACTORY" refresh
SH
chmod +x "$BINDIR/edit-world"

CASE=0
reset_case() {
  CASE=$((CASE + 1))
  HOME_FIX="$TMP_ROOT/case$CASE/home"
  CALLS="$TMP_ROOT/case$CASE/calls"
  mkdir -p "$HOME_FIX/state" "$HOME_FIX/data"
  : > "$CALLS"
  export FM_HOME="$HOME_FIX" FM_FACTORY_TEST_CALLS="$CALLS" FM_FACTORY_TEST_NOTES="$TMP_ROOT/case$CASE/notes"
  export FM_FACTORY_SNAPSHOT="$HOME_FIX/snapshot.json" FM_FACTORY_TEST_CONFIG="$TMP_ROOT/case$CASE/config"
  export FM_TEST_AXI_BACKLOG="$HOME_FIX/snapshot.json"
  unset FM_FACTORY_TEST_NO_TAB FM_FACTORY_TEST_TAB_GONE FM_FACTORY_TEST_FOCUSED HERDR_BIN_PATH HERDR_PANE_ID HERDR_TAB_ID \
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
import json, os, sys, time
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
                  "sample-shop",
                  lines=["paused [at=%d]: waiting on the carrier until 2026-11-14T09:30Z" % (now - 900)]))
rows.append(row("shop-labels", "Print shipping labels", "sample-shop"))
# A review finding the checks put to Starship (ask-user) is the checks' work.
tasks.append(task("shop-coupons", ("parked", "run-step"),
                  "parked at review: 1 finding(s) · ask-user: authority decision · run: r7", "sample-shop",
                  started=now - 20 * 60,
                  lines=["needs-decision [at=%d] [key=nm-r7-review]: ask-user findings=f1" % (now - 600)]))
rows.append(row("shop-coupons", "Gift cards at checkout", "sample-shop"))
tasks.append(task("shop-old", ("unknown", "none"), "worktree gone (torn down?)", "sample-shop"))
rows.append(row("shop-old", "Old banner swap", "sample-shop"))
rows.append(row("shop-gift", "Gift wrap at checkout", "sample-shop", "queued"))
rows.append(row("shop-reviews", "Reviews under each cup", "sample-shop", "queued"))
rows.append(row("shop-later", "Discount codes", "sample-shop", "queued", hold_kind="future",
                hold_reason="after the holidays"))
# The worker asked Starship, and Starship held the question for the owner:
# only the held decision is his.
summary = ("The harvest chart can open on this week or this season. "
           "Options: 1 this week (recommended), 2 this season, 3 both side by side. See /tmp/x/report.md")
asked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 3 * 3600))
tasks.append(task("garden-chart", ("parked", "status-log"), summary, "garden-journal",
                  lines=["needs-decision [at=%d] [key=chart-range]: %s" % (now - 4 * 3600, summary)],
                  decisions=[{"key": "chart-range", "verb": "needs-decision", "summary": summary}]))
rows.append(row("garden-chart", "Harvest chart", "garden-journal", captain_actionable=True, hold_kind="captain",
                hold_bucket="live", hold_set=asked_at, hold_reason=summary))
# A worker's own question Starship answers: never the owner's.
tasks.append(task("recipe-search", ("parked", "status-log"), "needs-decision: index titles only?", "recipe-box",
                  lines=["needs-decision [at=%d] [key=index]: index titles only?" % (now - 1800)],
                  decisions=[{"key": "index", "verb": "needs-decision", "summary": "index titles only?"}]))
rows.append(row("recipe-search", "Search recipes", "recipe-box"))
tasks.append(task("garden-water", ("failed", "status-log"), "the reminder test failed", "garden-journal",
                  lines=["failed [at=%d]: the reminder test failed" % (now - 40 * 60)]))
rows.append(row("garden-water", "Garden reminders", "garden-journal"))
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
                hold_reason="Saved cards need a provider."))
# An undated decision past the aging threshold no longer waits on the owner.
rows.append(row("recipe-units", "Metric or cups in the recipes", "garden-journal", "queued", kind="captain",
                captain_actionable=False, hold_kind="captain", hold_bucket="aged", hold_set="2026-10-01T09:00:00Z",
                hold_reason=None))
# A decision deferred to a date is not the owner's call until then.
rows.append(row("shop-tax", "Charge tax abroad", "sample-shop", "queued", kind="captain",
                hold_kind="captain", hold_bucket="dated", hold_set="2026-11-12T09:00:00Z",
                hold_reason="Ask again next month.", hold_until="2026-12-01"))
shapes = {"schema": "fm-tap-shapes.v1", "not_shown": [], "decisions": [
    {"id": "garden-chart", "identity": asked_at + "#0", "title": "Harvest chart", "question": summary,
     "options": ["this week", "this season", "both side by side"], "recommended_option": "this week",
     "recommendation": "this week", "held_since": asked_at},
    # Its options were recorded with fm-tap-desk.sh mark; its reason names none.
    {"id": "shop-provider", "identity": "2026-11-13T23:00:00Z#0", "title": "Which payment provider for the shop",
     "question": "Saved cards need a provider.",
     "options": ["the current one", "a cheaper new one", "wait until after the holidays"],
     "recommended_option": "", "recommendation": "Stay with the current one until the holidays are over.",
     "held_since": "2026-11-13T23:00:00Z"},
    {"id": "recipe-units", "identity": "2026-10-01T09:00:00Z#0", "title": "Metric or cups in the recipes",
     "question": "", "options": [], "recommended_option": "", "recommendation": "",
     "held_since": "2026-10-01T09:00:00Z"}]}
json.dump(shapes, open(os.path.join(home, "shapes.json"), "w"), indent=1)
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
  assert_equals "$(q .count_line)" "3 jobs running · 3 need you · 1 idle" "count line"
  assert_equals "$(q '[.factories[] | .name] | join(",")')" "Sample Shop,Garden Journal,Recipe Box" "factories"
  local shop='.factories[] | select(.id == "sample-shop") | .jobs[]'
  assert_equals "$(q "[$shop | \"\(.id)=\(.state)/\(.step // \"-\")\"] | join(\" \")")" \
    "shop-search=running/building shop-checkout=running/checking shop-coupons=running/checking shop-provider=waiting on you/- shop-images=stuck/- shop-labels=waiting/- shop-old=stopped/- shop-gift=next/- shop-reviews=later/- shop-later=on hold/- shop-tax=on hold until 2026-12-01/-" \
    "every shop job state is a word"
  assert_equals "$(q "$shop | select(.id == \"shop-coupons\") | .doing")" "answering the 1 point the checks found" \
    "a review finding the checks put to Starship is the checks' work"
  assert_equals "$(q '.factories[] | select(.id == "recipe-box") | .jobs[] | select(.id == "recipe-search") | .state')" \
    "with Starship" "a worker's own question is Starship's to answer"
  assert_equals "$(q "$shop | select(.id == \"shop-search\") | .doing")" "running the search tests: 41 of 58 passed" \
    "a stated step is the doing sentence"
  assert_equals "$(q "$shop | select(.id == \"shop-search\") | .sign_of_life_from")" "a turn" "sign of life source"
  assert_equals "$(q "$shop | select(.id == \"shop-checkout\") | .doing")" "waiting for the online checks" \
    "the checks say what they are doing"
  assert_equals "$(q "$shop | select(.id == \"shop-labels\") | .until")" "1794648600" "a wait says when it tries again"
  assert_equals "$(q '[.needs_you[] | "\(.id):\(.kind)"] | join(" ")')" \
    "garden-chart:question shop-provider:question garden-share:finished work" \
    "needs you is the owner's calls, questions first"
  assert_equals "$(q '.needs_you[0].options | map("\(.key) \(.label) \(.suggested)") | join("; ")')" \
    "1 this week true; 2 this season false; 3 both side by side false" "the card's options with its suggestion"
  assert_equals "$(q '.needs_you[0].why')" "The harvest chart can open on this week or this season." \
    "the why keeps no option list and no path"
  assert_equals "$(q '.needs_you[0].suggested_by')" "Starship" "the suggestion is Starship's"
  assert_equals "$(q '.needs_you[1].options | map(.label) | join(", ")')" \
    "the current one, a cheaper new one, wait until after the holidays" "options recorded with the tap desk's mark"
  assert_equals "$(q '.needs_you[1].recommendation')" "Stay with the current one until the holidays are over." \
    "a recommendation that is no option is still shown"
  assert_equals "$(q '[.needs_you[] | select(.id == "recipe-units")] | length')" "0" \
    "an aged hold is not the owner's call, as the bearings Captain's Call reads it"
  assert_equals "$(q '.needs_you[2].pr')" "https://example.invalid/g/pull/12" "finished work names its change"
  assert_equals "$(q '[.needs_you[].for] | unique | join(",")')" "you" "every waiting item names who it is for"
  assert_equals "$(q '.factories[] | select(.id == "recipe-box") | "\(.state) \(.idle_since)"')" "idle 1794636000" \
    "an idle factory knows since when"
  assert_equals "$(q '[.feed[] | "\(.word)|\(.actor)"] | join(" ")')" \
    "failed|Garden Journal PR ready|Garden Journal finished|Recipe Box asked you|Garden Journal landed|Recipe Box asked you|Sample Shop" \
    "the feed, newest first: outcomes and the owner's calls only"
  pass "factory record: every state is a word, needs you is ordered, the feed reads newest first"
}

test_the_plain_screen_is_the_record_as_text() {
  reset_case
  write_registry
  write_world
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" " S T A R S H I P  │  3 jobs running  ·  3 need you  ·  1 idle" "count line"
  assert_equals "$(printf '%s\n' "$out" | grep -F ' ▸ ● ' | tr -s ' ')" \
    " ▸ ● Harvest chart Garden Journal · waiting 3 h" "the cursor starts on the first question"
  assert_contains "$out" "       1  this week  · Starship suggests this" "suggested option"
  assert_contains "$out" "       Starship suggests: Stay with the current one until the holidays are over." \
    "a recommendation of its own"
  assert_not_contains "$out" "None" "a missing value printed as None"
  assert_contains "$out" "       t  Talk it through" "talk it through"
  assert_contains "$out" "       ✓ planning ••••• ▸ building •••••   checking ·····   ready for you" "four steps"
  assert_contains "$out" "       running the search tests: 41 of 58 passed" "doing this minute"
  has_line "$out" " ● Sharper cup photos stuck" "a stuck job"
  has_line "$out" " ● Print shipping labels waiting · tries again 09:30" "a waiting job"
  has_line "$out" " next Gift wrap at checkout · then 2 more" "next in line"
  has_line "$out" " Recipe Box idle since 06:00 · nothing in line Starship steers" "an idle factory is one row"
  has_line "$out" " 06:00 Recipe Box finished Calmer start screen is finished." "feed row"
  has_line "$out" " 06:11 Garden Journal PR ready Share a garden page as a picture has its PR ready." "a PR ready row"
  local feed
  feed=$(printf '%s\n' "$out" | sed -n '/SINCE YOU LAST LOOKED/,$p')
  assert_not_contains "$feed" "tries again" "a worker's pause reached the feed"
  assert_not_contains "$feed" "Search recipes" "a worker's own question reached the feed"
  assert_not_contains "$feed" "Gift cards" "a review finding Starship decides reached the feed"
  assert_not_contains "$feed" "stuck" "a blocker reached the feed"
  assert_contains "$out" " ↑↓ move · 1/2/3 answer · enter open · t talk · s who steers · q quit" "keys"
  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop) || fail "--plain --factory failed"
  assert_contains "$out" " RULES THIS CREW FOLLOWS" "rules heading"
  assert_contains "$out" "   · Anything that touches payments waits for your yes." "a rule"
  assert_contains "$out" "   12 Nov  Search results read better with the price on the first line." "a lesson"
  has_line "$out" " · 2 on hold" "held work folds into a count"
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

test_a_changing_pane_is_a_sign_of_life() {
  reset_case
  write_registry
  write_world quiet
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$TMP_ROOT/case$CASE/pane" > "$BINDIR/peek$CASE"
  chmod +x "$BINDIR/peek$CASE"
  export FM_FACTORY_PEEK="$BINDIR/peek$CASE"
  printf 'reading the search module\n' > "$TMP_ROOT/case$CASE/pane"
  take_record
  assert_equals "$(q '.factories[0].jobs[0] | "\(.quiet) \(.sign_of_life_from)"')" "true a turn" \
    "a first sight of a pane says nothing about when it last changed"
  printf 'running the tests\n' > "$TMP_ROOT/case$CASE/pane"
  take_record
  assert_equals "$(q '.factories[0].jobs[0] | "\(.quiet) \(.sign_of_life_from) \(.last_sign_of_life)"')" \
    "false pane activity $NOW" "a pane whose text changed is alive"
  export FM_FACTORY_PEEK=
  pass "factory record: a worker's pane text changing is a sign of life; a first sight is not"
}

# Ready work the owner re-held until a later date is no call of his until then:
# its job reads as on hold, and it is not under NEEDS YOU.
test_ready_work_held_until_a_date_is_not_ready_for_you() {
  reset_case
  write_registry
  write_world
  local snap
  snap=$(jq '(.backlog.records[] | select(.id == "garden-share")) += {hold_kind: "captain", hold_bucket: "dated",
    hold_reason: "Merge after the release.", hold_set: "2026-11-13T09:00:00Z", hold_until: "2026-12-01"}' \
    "$FM_FACTORY_SNAPSHOT") || fail "could not hold the ready work"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
  take_record
  assert_equals "$(q '.factories[] | .jobs[] | select(.id == "garden-share") | "\(.state)|\(.step // "-")"')" \
    "on hold until 2026-12-01|-" "ready work held until a date read as ready for the owner"
  assert_equals "$(q '[.needs_you[] | select(.id == "garden-share")] | length')" "0" \
    "ready work held until a date is under NEEDS YOU"
  assert_equals "$(q .count_line)" "3 jobs running · 2 need you · 1 idle" "count line"
  pass "factory record: ready work the owner held until a date reads on hold, not ready for you"
}

# A home whose backlog is not markdown has no rows in the snapshot's markdown
# read; its held decisions still reach NEEDS YOU through the tasks-axi adapter.
test_held_decisions_come_through_a_non_markdown_adapter() {
  reset_case
  write_registry
  write_world
  jq '.backlog' "$FM_FACTORY_SNAPSHOT" > "$HOME_FIX/adapter-backlog.json"
  jq '.backlog = {path: "data/backlog.md", present: false, records: []}' "$FM_FACTORY_SNAPSHOT" \
    > "$HOME_FIX/snapshot.next" && mv "$HOME_FIX/snapshot.next" "$FM_FACTORY_SNAPSHOT"
  export FM_TEST_AXI_BACKLOG="$HOME_FIX/adapter-backlog.json"
  take_record
  assert_equals "$(q '[.needs_you[] | "\(.id):\(.kind)"] | join(" ")')" \
    "garden-chart:question shop-provider:question garden-share:finished work" \
    "the adapter's held decisions are not under NEEDS YOU"
  assert_equals "$(q .counts.need_you)" "3" "the adapter's held decisions are not counted"
  # The adapter backlog may carry no hold time; the tap shapes' held_since,
  # written with milliseconds, still says how long the decision has waited.
  jq '(.records[] | select(.id == "shop-provider")) |= del(.hold_set)' "$FM_TEST_AXI_BACKLOG" \
    > "$HOME_FIX/adapter.next" && mv "$HOME_FIX/adapter.next" "$FM_TEST_AXI_BACKLOG"
  jq '(.decisions[] | select(.id == "shop-provider")).held_since = "2026-11-13T23:00:00.000Z"' "$HOME_FIX/shapes.json" \
    > "$HOME_FIX/shapes.next" && mv "$HOME_FIX/shapes.next" "$HOME_FIX/shapes.json"
  take_record
  assert_equals "$(q '.needs_you[] | select(.id == "shop-provider") | .since')" "1794610800" \
    "a held_since with milliseconds lost the decision's waiting time"
  # Ready work held there until a date reads on hold, exactly as on a markdown home.
  local held
  held=$(jq '(.records[] | select(.id == "garden-share")) += {hold_kind: "captain", hold_reason: "Merge after the release.",
    hold_set: "2026-11-13T09:00:00Z", hold_until: "2026-12-01"}' "$FM_TEST_AXI_BACKLOG") || fail "could not hold the ready work"
  printf '%s\n' "$held" > "$FM_TEST_AXI_BACKLOG"
  take_record
  assert_equals "$(q '.factories[] | .jobs[] | select(.id == "garden-share") | .state')" "on hold until 2026-12-01" \
    "ready work held until a date on a non-markdown backlog lost its held word"
  assert_equals "$(q '[.needs_you[] | .id] | join(" ")')" "garden-chart shop-provider" \
    "ready work held until a date on a non-markdown backlog is under NEEDS YOU"
  pass "factory record: held decisions on a non-markdown backlog reach NEEDS YOU through the adapter"
}

# A ship spawned without a mode records no mode= at all; its ready report is
# still the ready report, read as the status bar reads an empty mode.
test_a_ship_with_no_mode_still_reports_its_pr_ready() {
  reset_case
  write_registry
  write_world
  printf 'kind=ship\nyolo=off\nspawn_gen=s%d.1.1\n' $((NOW - 1800)) > "$HOME_FIX/state/garden-share.meta"
  printf 'done [at=%d]: PR https://example.invalid/g/pull/12 checks green\n' $((NOW - 109 * 60)) \
    > "$HOME_FIX/state/garden-share.status"
  take_record
  assert_equals "$(q '[.feed[] | select(.job == "garden-share") | .word] | join(",")')" "PR ready" \
    "a ship with no mode lost its ready report"
  pass "factory feed: a ship with no recorded mode still reports its PR ready"
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
    "garden-chart,garden-share,garden-water,recipe-units" \
    "unclaimed work lands in Other work"
  pass "factory registry: work no factory claims is shown under Other work"
}

# write_crowded_world: the sample fleet plus more calls for the owner than a
# small pane holds: a question whose title lists several calls and whose
# option is long, a title with no space to break at, and four more plain ones.
write_crowded_world() {
  write_world
  python3 - "$HOME_FIX" "$NOW" <<'PY'
import json, os, sys, time
home, now = sys.argv[1], int(sys.argv[2])
snap_path, shapes_path = os.path.join(home, "snapshot.json"), os.path.join(home, "shapes.json")
snap, shapes = json.load(open(snap_path)), json.load(open(shapes_path))
def held(rid, title, repo, minutes_ago, reason):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - minutes_ago * 60))
    snap["backlog"]["records"].append({
        "id": rid, "title": title, "repo": repo, "state": "queued", "structured": True, "kind": "captain",
        "captain_actionable": True, "hold_kind": "captain", "hold_bucket": "live", "hold_reason": reason,
        "hold_set": stamp, "hold_until": None, "unresolved_blocker_ids": [], "since": "2026-11-13",
        "completion": {"verb": None, "date": None}, "pr_url": None})
    return stamp
stamp = held("shop-packaging", "Packaging: three calls from the supplier visit (recycled boxes now or after "
             "the holidays, tell the printer today or on return, ask about the ribbon colour)", "sample-shop", 1,
             "Three calls from the supplier visit, each small but each holding up the holiday orders.")
shapes["decisions"].append({
    "id": "shop-packaging", "identity": stamp + "#0", "title": snap["backlog"]["records"][-1]["title"],
    "question": snap["backlog"]["records"][-1]["hold_reason"],
    "options": ["order the recycled boxes now, before the printer closes for the holidays and the price goes up",
                "wait until January"],
    "recommended_option": "", "recommendation": "", "held_since": stamp})
held("shop-rename", "Rename-the-whole-catalogue-to-the-new-house-style-and-redirect-every-old-link", "sample-shop",
     2, "The catalogue needs one name.")
for index, title in enumerate(["Which courier for parcels going abroad after the new year",
                               "Whether the shop shows prices with tax or without it for visitors from abroad",
                               "Opening hours over the holidays for the shop and the order service",
                               "A thank-you card in every parcel, or only in the first order"]):
    held("shop-extra-%d" % index, title, "sample-shop", 3 + index, "Needs your view.")
json.dump(snap, open(snap_path, "w"), indent=1)
json.dump(shapes, open(shapes_path, "w"), indent=1)
PY
}

# screen_of <capture> <rows> <cols>: what a terminal shows after the last
# complete frame the pane drew: home, clear, line feeds, erase-in-line and
# colour codes, with autowrap off as the pane sets it, so a character written
# in the last column stays under the cursor until something erases it.
screen_of() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
rows, cols = int(sys.argv[2]), int(sys.argv[3])
frames = re.findall(r"\x1b\[\?2026h(.*?)\x1b\[\?2026l", data, re.S)
if not frames:
    sys.exit("screen_of: no complete frame in the capture")
grid = [[" "] * cols for _ in range(rows)]
r = c = 0
for token in re.findall(r"\x1b\[[0-9;?<]*[ -/]*[@-~]|\x1b.|[\s\S]", frames[-1]):
    if token.startswith("\x1b["):
        final, params = token[-1], token[2:-1]
        if final == "H":
            parts = [int(p) for p in params.split(";") if p.isdigit()] or [1, 1]
            r, c = parts[0] - 1, (parts[1] - 1 if len(parts) > 1 else 0)
        elif final == "J" and params == "2":
            grid = [[" "] * cols for _ in range(rows)]
        elif final == "K":
            for x in range(c, cols):
                grid[r][x] = " "
    elif token == "\r":
        c = 0
    elif token == "\n":
        r = min(r + 1, rows - 1)
    elif not token.startswith("\x1b") and token.isprintable():
        grid[r][c] = token
        c = min(c + 1, cols - 1)
print("\n".join("".join(line).rstrip() for line in grid))
PY
}

test_a_small_pane_shows_its_height_and_says_what_is_below() {
  reset_case
  write_registry
  write_crowded_world
  local out widest flat
  out=$(python3 "$FACTORY" --plain --width 70 --height 40) || fail "--plain --height failed"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "40" "the screen is the pane's height"
  widest=$(printf '%s\n' "$out" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')
  [ "$widest" -le 70 ] || fail "a line is wider than the pane ($widest)"$'\n'"$out"
  assert_contains "$(printf '%s\n' "$out" | tail -1)" "q quit" "the keys stay on the bottom line"
  assert_contains "$out" "more lines below" "the screen does not say there is more below"
  assert_not_contains "$out" "more lines above" "the first screen says something is above it"
  # The opened card shows its whole title and each option in full, wrapped.
  flat=$(printf '%s\n' "$out" | sed -n '/Packaging/,/Talk it through/p' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$flat" "Packaging: three calls from the supplier visit (recycled boxes now or after the holidays, tell the printer today or on return, ask about the ribbon colour)" \
    "the card's title is cut off"
  assert_contains "$flat" "1 order the recycled boxes now, before the printer closes for the holidays and the price goes up" \
    "the card's option is cut off"
  assert_not_contains "$flat" "…" "an opened card cut its words short"
  # A one-line row ends on a whole word and says it was shortened.
  has_line "$out" " ● Whether the shop shows prices with tax or without it for…" \
    "a one-line row is cut mid-word or without an ellipsis"
  out=$(python3 "$FACTORY" --plain --width 140 --height 80) || fail "--plain at the small font failed"
  widest=$(printf '%s\n' "$out" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')
  [ "$widest" -le 140 ] || fail "a line is wider than the small-font pane ($widest)"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "80" "the small-font screen is the pane's height"
  pass "factory pane: a small pane fits its width and height, wraps an opened card, and says what is below"
}

test_a_small_pane_scrolls_to_everything() {
  reset_case
  write_registry
  write_crowded_world
  local dir="$TMP_ROOT/case$CASE" first expected
  export FM_FACTORY_TEST_SIZE=40x70
  # Before any key is pressed, so both read the same last look. The clock
  # stands still and no look ever ends, so the feed's heading is LAST 12 HOURS.
  expected=$(python3 "$FACTORY" --plain --width 70 --height 40)
  drive_keys "SNAP:$dir/first"
  first=$(screen_of "$dir/first" 40 70)
  assert_equals "$first" "$expected" "the live pane does not draw what --plain --height prints"
  assert_not_contains "$first" "LAST 12 HOURS" "the fixture is too small to need scrolling"
  # Highlighting the title with no space to break at opens its card, which
  # breaks that title across lines rather than clipping it.
  drive_keys DOWN DOWN "SNAP:$dir/opened"
  assert_contains "$(screen_of "$dir/opened" 40 70 | sed -n '/Rename-the/,/Talk it through/p' | sed 's/^ *//' \
    | tr -d '\n')" "Rename-the-whole-catalogue-to-the-new-house-style-and-redirect-every-old-link" \
    "an opened card clipped a title with no space in it"
  drive_keys PGDN PGDN PGDN PGDN PGDN PGDN "SNAP:$dir/paged" PGUP PGUP PGUP PGUP PGUP PGUP "SNAP:$dir/back"
  assert_contains "$(screen_of "$dir/paged" 40 70)" "LAST 12 HOURS" "page down never reached the feed"
  assert_contains "$(screen_of "$dir/paged" 40 70)" "more lines above" "the screen does not say there is more above"
  assert_contains "$(screen_of "$dir/back" 40 70)" " NEEDS YOU" "page up never came back to the top"
  local wheel=() downs=()
  for _ in $(seq 1 20); do wheel+=(WHEELDOWN); done
  drive_keys "${wheel[@]}" CLICK "SNAP:$dir/wheeled"
  assert_contains "$(screen_of "$dir/wheeled" 40 70)" "LAST 12 HOURS" "the mouse wheel never reached the feed"
  # The highlight moving past the bottom scrolls with it, and the arrows keep
  # scrolling once the last row is highlighted.
  for _ in $(seq 1 40); do downs+=(DOWN); done
  drive_keys "${downs[@]:0:10}" "SNAP:$dir/follow" "${downs[@]}" "SNAP:$dir/walked"
  assert_contains "$(screen_of "$dir/follow" 40 70)" " ▸ " "the highlight scrolled out of sight"
  assert_contains "$(screen_of "$dir/walked" 40 70)" "LAST 12 HOURS" "the arrows never reached the feed"
  unset FM_FACTORY_TEST_SIZE
  pass "factory pane: a small pane scrolls with page keys, the mouse wheel and the highlight"
}

test_a_narrow_talk_box_always_shows_what_is_typed() {
  reset_case
  write_registry
  write_crowded_world
  local dir="$TMP_ROOT/case$CASE" screen
  export FM_FACTORY_TEST_SIZE=40x70
  # The highlighted question's title is wider than the pane, so the box's
  # label wraps and the typed text and its cursor keep a line of their own.
  drive_keys DOWN t "half typed note" "SNAP:$dir/talk" ESC
  screen=$(screen_of "$dir/talk" 40 70)
  assert_contains "$screen" "About Packaging: three calls" "the talk box is not about the highlighted question"
  assert_contains "$screen" "ask about the ribbon colour)" "the talk box cut its label short"
  assert_contains "$screen" "▸ half typed note_" "the talk box hid what was typed"
  unset FM_FACTORY_TEST_SIZE
  pass "factory pane: a narrow talk box wraps a long label and always shows the typed text"
}

# drive_keys <keys...>: once the first screen is up, press keys in the real
# live view under a pty (FM_FACTORY_TEST_SIZE rows x columns, default 50x100),
# one per third of a second, then q. A `SH:<command>` step runs the command
# instead and waits for the pane to pick up the refreshed record; a
# `SNAP:<file>` step saves what the pane draws next; a `WAIT:<seconds>` step
# leaves the pane alone that long. With DRIVE_PANE=1 the view runs as Herdr
# starts it, through fm-factory-pane.sh run.
drive_keys() {
  python3 - "$FACTORY" "$PANE" "$@" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    rows, cols = (int(n) for n in os.environ.get("FM_FACTORY_TEST_SIZE", "50x100").split("x"))
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    if os.environ.get("DRIVE_PANE") == "1":
        os.execvp("bash", ["bash", sys.argv[2], "run"])
    os.execvp("python3", ["python3", sys.argv[1], "view"])
def drain(seconds, until=None):
    end, seen = time.monotonic() + seconds, b""
    while time.monotonic() < end and not (until and until in seen):
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
    return seen
drain(20, until=b"q quit")
for key in sys.argv[3:] + ["q"]:
    if key.startswith("SH:"):
        subprocess.run(key[3:], shell=True, check=True, stdout=subprocess.DEVNULL)
        drain(3.6)
        continue
    if key.startswith("SNAP:"):
        open(key[5:], "wb").write(drain(1.0))
        continue
    if key.startswith("WAIT:"):
        drain(float(key[5:]))
        continue
    os.write(fd, {"ENTER": b"\r", "DOWN": b"\x1b[B", "UP": b"\x1b[A", "ESC": b"\x1b", "PGDN": b"\x1b[6~",
                  "PGUP": b"\x1b[5~", "WHEELDOWN": b"\x1b[<65;10;10M", "WHEELUP": b"\x1b[<64;10;10M",
                  "CLICK": b"\x1b[<0;10;10M\x1b[<0;10;10m"}.get(key, key.encode()))
    drain(0.35)
# Keep reading the pty while the pane exits, so its last writes never block.
end = time.monotonic() + 15
while True:
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.monotonic() >= end:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        sys.exit("drive_keys: the pane did not exit after q")
    drain(0.5)
PY
}

test_writing_keys_go_through_the_inbox_and_act_on_the_highlighted_row() {
  reset_case
  write_registry
  write_world
  drive_keys 2 ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.answer.garden-chart.$((NOW - 3 * 3600)).2" \
    "the answer acts on the highlighted question"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "Answer for Harvest chart: 2 this season" "answer body"
  : > "$FM_FACTORY_TEST_NOTES"
  drive_keys A ESC
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a letter for another question sends nothing; esc cancels"
  drive_keys 2 x
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "any key but enter cancels the answer"
  drive_keys DOWN DOWN k ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.keep.garden-share.$((NOW - 109 * 60))" "keep names the item and when it became ready"
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
  assert_contains "$note" "request_id=factory.garden-journal.answer.garden-chart.$((NOW - 3 * 3600)).2" \
    "the note is saved under its id"
  assert_contains "$note" "Answer for Harvest chart: 2 this season" "the note carries the answer"
  (unset FM_FACTORY_INBOX; drive_keys 2 ENTER)
  assert_equals "$(find "$HOME_FIX/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "1" \
    "the same answer twice is one note"
  "$BINDIR/edit-world" reask garden-chart $((NOW - 600)) >/dev/null || fail "edit-world failed"
  (unset FM_FACTORY_INBOX; drive_keys 2 ENTER)
  assert_equals "$(find "$HOME_FIX/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "2" \
    "the same question asked again later is a new note"
  assert_contains "$(cat "$HOME_FIX"/state/inbox/*.note)" \
    "request_id=factory.garden-journal.answer.garden-chart.$((NOW - 600)).2" \
    "the new note names when the question was asked again"
  pass "factory pane: an answer is a captain inbox note, saved once per question under its request id"
}

# park-world <id>: defer a held decision to a date, as firstmate parks it: the
# fixture backlog row as tasks-axi rewrites it, then the parking command itself
# through bin/fm-tasks-axi.sh, whose write the stand-in adapter takes as done.
cat > "$BINDIR/park-world" <<SH
#!/usr/bin/env bash
python3 - "\$FM_FACTORY_SNAPSHOT" "\$1" <<'PY'
import json, sys
path, ident = sys.argv[1], sys.argv[2]
world = json.load(open(path))
for row in world["backlog"]["records"]:
    if row["id"] == ident:
        row.update(hold_bucket="dated", hold_until="2099-01-01", captain_actionable=False)
json.dump(world, open(path, "w"))
PY
exec bash "$ROOT/bin/fm-tasks-axi.sh" hold "\$1" --until 2099-01-01 >/dev/null
SH
chmod +x "$BINDIR/park-world"

# watch_pane <first> <next> <command>: run the live overview under a pty, and
# once it shows <first>, run <command> and print how many seconds pass until
# it shows <next> (or `never`).
watch_pane() {
  python3 - "$FACTORY" "$@" <<'PY'
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time
factory, first, nxt, command = sys.argv[1:5]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 100, 0, 0))
    os.execvp("python3", ["python3", factory, "view"])
seen = b""
def drain(seconds, until=None, start=0):
    global seen
    end = time.time() + seconds
    while time.time() < end:
        if until and until.encode() in re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", seen[start:]):
            return True
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
    return False
result = "no first screen"
if drain(20, until=first):
    mark = len(seen)
    began = time.time()
    subprocess.run(command, shell=True, check=True)
    result = "%.1f" % (time.time() - began) if drain(15, until=nxt, start=mark) else "never"
print(result)
os.write(fd, b"q")
end = time.time() + 15
while True:   # keep reading so its last writes drain and it can exit
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.time() >= end:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        break
    drain(0.3)
PY
}

# On 2026-11-15 the owner parked a held decision and it stayed on screen: the
# pane refreshed its record only every twenty seconds, and a whole refresh
# reads every worker. A changed call now rebuilds the record on its own.
test_a_parked_decision_leaves_the_live_pane_within_seconds() {
  local took
  reset_case
  write_registry
  write_world
  python3 "$FACTORY" refresh || fail "the first record could not be built"
  took=$(watch_pane '3 need you' '2 need you' "$BINDIR/park-world garden-chart") \
    || fail "the live pane could not be driven"
  case "$took" in
    never|'no first screen'|'') fail "the live pane still showed the parked decision: $took" ;;
  esac
  awk -v t="$took" 'BEGIN { exit !(t < 4.5) }' || fail "the live pane took ${took}s to drop the parked decision"
  cp "$HOME_FIX/state/factory/record.json" "$TMP_ROOT/case$CASE/record.json" || fail "the pane wrote no record"
  assert_equals "$(q '[.needs_you[].id] | join(" ")')" "shop-provider garden-share" \
    "the parked decision is still in the record"
  assert_equals "$(q '[.factories[] | select(.id == "sample-shop") | .jobs[] | select(.id == "shop-search") | .state] | join("")')" \
    "running" "the workers were lost from the record"
  pass "factory pane: a parked decision leaves the live pane within seconds, without a whole refresh (${took}s)"
}

# A calls rebuild that read the fleet before a full refresh finished must not
# put the older workers back over the newer record.
test_a_calls_rebuild_on_an_older_reading_keeps_the_newer_record() {
  local basis epoch
  reset_case
  basis="$HOME_FIX/state/factory/basis.json"
  write_registry
  write_world
  python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  epoch=$(jq -r .snapshot_epoch "$HOME_FIX/state/factory/record.json")
  if ! { jq '.taken_epoch -= 100
      | .snapshot.tasks |= map(if .id == "shop-search" then .current_state.state = "unknown" else . end)' \
    "$basis" > "$basis.old" && mv "$basis.old" "$basis"; }; then
    fail "the older reading could not be staged"
  fi
  python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls could not be rebuilt"
  cp "$HOME_FIX/state/factory/record.json" "$TMP_ROOT/case$CASE/record.json" || fail "the record is gone"
  assert_equals "$(q .snapshot_epoch)" "$epoch" "the record went back to the older reading"
  assert_equals "$(q '[.factories[] | select(.id == "sample-shop") | .jobs[] | select(.id == "shop-search") | .state] | join("")')" \
    "running" "the older workers replaced the newer ones"
  pass "factory pane: a calls rebuild on an older reading keeps the newer record"
}

test_the_highlight_and_open_boxes_follow_the_record() {
  reset_case
  write_registry
  write_world
  drive_keys DOWN DOWN DOWN "SH:$BINDIR/edit-world drop garden-share" s
  assert_equals "$(cut -f2- "$HOME_FIX/state/factory/steer.log")" "$(printf 'sample-shop\tyou')" \
    "s acts on the highlighted factory after a row above it left"
  reset_case
  write_registry
  write_world
  : > "$FM_FACTORY_TEST_NOTES"
  local screen="$TMP_ROOT/case$CASE/screen"
  drive_keys DOWN DOWN c "Bigger picture" "SH:$BINDIR/edit-world drop garden-share" s q 2 k ENTER "SNAP:$screen" ESC
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a talk box whose work left sends nothing"
  assert_absent "$HOME_FIX/state/factory/steer.log" "keys typed into the box never steer"
  assert_contains "$(cat "$screen")" "Bigger picturesq2k" "the pane still runs and the box keeps every typed key"
  assert_contains "$(cat "$screen")" "This was settled elsewhere, so nothing will be sent" "the box says why"
  drive_keys 2 "SH:$BINDIR/edit-world reask garden-chart $((NOW - 600))" ENTER
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a pending answer closes when its question is asked again"
  pass "factory pane: the highlight stays on its row; a talk box whose row left keeps its text and sends nothing"
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
  assert_equals "$(q '[.feed[] | select(.actor == "you") | .word][0]')" "took the helm" \
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

# The desk restarts a factory page Herdr brought back as a plain shell, then
# asks for the live worker copies beside it again.
test_workers_splits_live_copies_beside_a_page_pane() {
  reset_case
  write_registry
  write_world
  local out
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" workers sample-shop --page w1:p4 2>&1) \
    || fail "workers failed: $out"
  assert_equals "$(sed -n 1p "$CALLS")" "pane split w1:p4 --direction right --no-focus" "the first copy beside the page"
  assert_contains "$(sed -n 2p "$CALLS")" "fm-factory-pane.sh follow shop-search" "a live copy of a worker"
  assert_equals "$(grep -c 'follow ' "$CALLS")" "4" "each worker with a pane, stopped ones left out"
  assert_equals "$(grep -c -E '^(tab |pane focus)' "$CALLS")" "0" "workers opened or focused a tab or pane"
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" workers sample-shop 2>&1) \
    && fail "workers ran without a page pane"
  if out=$(HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" workers no-such --page w1:p4 2>&1); then
    fail "workers succeeded for an unknown factory"
  fi
  assert_contains "$out" "no factory no-such" "the reason"
  pass "factory tab: workers splits a live copy of each running worker beside a page pane"
}

test_a_live_copy_shows_text_at_the_top_of_a_taller_pane() {
  reset_case
  write_registry
  write_world
  # The worker's pane holds its text on the first line and blank rows below,
  # the way an inline agent early in its session looks to bin/fm-peek.sh.
  # shellcheck disable=SC2016 # $(seq 30) must expand when the stub runs
  printf '#!/usr/bin/env bash\nprintf "waiting for the captain\\n"; for i in $(seq 30); do echo; done\n' \
    > "$BINDIR/peek$CASE"
  chmod +x "$BINDIR/peek$CASE"
  local screen
  screen=$(FM_FACTORY_PEEK="$BINDIR/peek$CASE" python3 - "$FACTORY" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 80, 0, 0))
    os.execvp("python3", ["python3", sys.argv[1], "follow", "shop-search"])
# Read until the first frame's header has drawn, then the rest of that frame.
end, seen = time.time() + 30, b""
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            seen += os.read(fd, 65536)
        except OSError:
            break
    if b"live copy" in seen:
        end = min(end, time.time() + 0.5)
os.kill(pid, signal.SIGTERM)
while True:   # keep reading so its last writes drain and it can exit
    try:
        if not os.read(fd, 65536):
            break
    except OSError:
        break
os.waitpid(pid, 0)
sys.stdout.write(seen.decode("utf-8", "replace"))
PY
)
  assert_contains "$screen" "live copy" "the copy draws"
  assert_contains "$screen" "waiting for the captain" "the worker's text shows, not the blank rows below it"
  pass "factory tab: a worker's live copy shows its text even when blank rows follow it"
}

test_a_factory_tab_opens_no_live_copy_for_parked_held_or_finished_work() {
  reset_case
  write_registry
  write_world
  # Garden Journal: a worker whose question waits on the owner, a failed
  # worker, and work ready for the owner. Only the ready work has ended.
  HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" open-tab garden-journal >/dev/null 2>&1 \
    || fail "open-tab garden-journal failed"
  assert_equals "$(grep -o 'follow [a-z-]*' "$CALLS" | tr '\n' ' ')" "follow garden-chart follow garden-water " \
    "a worker waiting on the owner lost its copy, or ready work got one"
  # Sample Shop with room under the cap: a parked worker gets no copy either.
  reset_case
  write_registry
  write_world
  "$BINDIR/edit-world" drop shop-search >/dev/null || fail "edit-world failed"
  "$BINDIR/edit-world" drop shop-checkout >/dev/null || fail "edit-world failed"
  HERDR_BIN_PATH="$BINDIR/herdr" python3 "$FACTORY" open-tab sample-shop >/dev/null 2>&1 \
    || fail "open-tab sample-shop failed"
  assert_equals "$(grep -o 'follow [a-z-]*' "$CALLS" | tr '\n' ' ')" "follow shop-coupons follow shop-images " \
    "a parked or stopped worker got a live copy"
  pass "factory tab: live copies open only for workers at work, never for parked, held or finished jobs"
}

# follow_until_exit <task-id> <seconds> [SH:<command>]: a worker's live copy
# under a pty; once it draws, run the command, then wait up to <seconds> for the
# copy to exit, printing what it drew. Exit 3 when it never exited.
follow_until_exit() {
  python3 - "$FACTORY" "$@" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
factory, task, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
step = sys.argv[4] if len(sys.argv) > 4 else ""
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 80, 0, 0))
    os.execvp("python3", ["python3", factory, "follow", task])
seen, stepped, end, code = b"", False, time.time() + 30, None
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            seen += os.read(fd, 65536)
        except OSError:
            pass
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        code = status
        break
    if not stepped and b"live copy" in seen:
        stepped = True
        if step.startswith("SH:"):
            subprocess.run(step[3:], shell=True, check=True, stdout=subprocess.DEVNULL)
        end = time.time() + seconds
if code is None:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
sys.stdout.write(seen.decode("utf-8", "replace"))
sys.exit(3 if code is None else 0)
PY
}

test_a_live_copy_closes_when_its_job_ends() {
  reset_case
  write_registry
  write_world
  python3 "$FACTORY" refresh || fail "refresh failed"
  local out
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p31 \
    follow_until_exit shop-search 6 "SH:$BINDIR/edit-world drop shop-search") \
    || fail "a live copy stayed open after its job ended"$'\n'"$out"
  assert_equals "$(cat "$CALLS")" "pane close w1:p31" "the copy closed its own pane"
  : > "$CALLS"
  # A copy opened on work that is already ready for the owner closes at once.
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p32 follow_until_exit garden-share 6) \
    || fail "a live copy of finished work stayed open"$'\n'"$out"
  assert_equals "$(cat "$CALLS")" "pane close w1:p32" "the finished job's copy closed its pane"
  # A worker still at work keeps its copy.
  : > "$CALLS"
  if HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p33 follow_until_exit shop-checkout 5 >/dev/null; then
    fail "a live copy of a worker at work closed"
  fi
  assert_equals "$(cat "$CALLS")" "" "a working job's copy closed a pane"
  pass "factory tab: a live copy closes its pane when its job ends, and stays while the worker works"
}

# code_copy <dir>: a code root whose bin/ links to this one's, except the
# Factory pane's two scripts, which are real copies a case can change under a
# running pane the way an update rewrites them.
code_copy() {
  local f
  mkdir -p "$1/bin"
  for f in "$ROOT"/bin/*; do
    ln -s "$f" "$1/bin/${f##*/}"
  done
  rm "$1/bin/fm-factory.py" "$1/bin/fm-factory-pane.sh"
  cp "$ROOT/bin/fm-factory.py" "$ROOT/bin/fm-factory-pane.sh" "$1/bin/"
}

test_a_running_factory_pane_picks_up_changed_code() {
  reset_case
  write_registry
  write_world
  local code="$TMP_ROOT/case$CASE/code" screen
  code_copy "$code"
  screen=$(FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" python3 - "$code" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
code = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 100, 0, 0))
    os.execvp("bash", ["bash", os.path.join(code, "bin", "fm-factory-pane.sh"), "run"])
def drain(seconds, until):
    end, seen = time.time() + seconds, b""
    while time.time() < end and until not in seen:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
    return seen
first = drain(20, b"q quit")
# The update lands: a new fm-factory.py moved into place, as git writes it.
path = os.path.join(code, "bin", "fm-factory.py")
text = open(path).read().replace('"q quit"', '"q leave"')
open(path + ".new", "w").write(text)
os.rename(path + ".new", path)
after = drain(3, b"q leave")
alive = os.waitpid(pid, os.WNOHANG)[0] == 0
record = os.path.exists(os.path.join(os.environ["FM_FACTORY_PANE_CONFIG_DIR"], "panes", str(pid)))
os.kill(pid, signal.SIGTERM)
end = time.time() + 5
while time.time() < end and os.waitpid(pid, os.WNOHANG)[0] == 0:
    drain(0.2, b"\0never")
print("first=%s after=%s alive=%s record=%s" % (b"q quit" in first, b"q leave" in after, alive, record))
PY
)
  assert_equals "$screen" "first=True after=True alive=True record=True" \
    "a running Factory pane did not reload its changed code in place"
  pass "factory pane: a running pane reloads in place within a redraw when its code changes"
}

test_a_factory_pane_waits_for_an_open_talk_box_before_reloading() {
  reset_case
  write_registry
  write_world
  local code="$TMP_ROOT/case$CASE/code" screen
  code_copy "$code"
  screen=$(FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" python3 - "$code" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
code = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 100, 0, 0))
    os.execvp("bash", ["bash", os.path.join(code, "bin", "fm-factory-pane.sh"), "run"])
def drain(seconds, until):
    end, seen = time.time() + seconds, b""
    while time.time() < end and until not in seen:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
    return seen
drain(20, b"q quit")
for key in (b"\x1b[B", b"\x1b[B", b"\x1b[B", b"t"):
    os.write(fd, key)
    drain(0.3, b"\0never")
os.write(fd, b"Half a thought")
drain(3, b"Half a thought")
path = os.path.join(code, "bin", "fm-factory.py")
text = open(path).read().replace('"q quit"', '"q leave"')
open(path + ".new", "w").write(text)
os.rename(path + ".new", path)
during = drain(2, b"q leave")
os.write(fd, b"\x1b")
after = drain(3, b"q leave")
os.kill(pid, signal.SIGTERM)
end = time.time() + 5
while time.time() < end and os.waitpid(pid, os.WNOHANG)[0] == 0:
    drain(0.2, b"\0never")
print("held=%s after=%s" % (b"q leave" not in during and b"Half a thought" in during, b"q leave" in after))
PY
)
  assert_equals "$screen" "held=True after=True" \
    "a Factory pane reloaded under an open talk box, or never reloaded once it closed"
  pass "factory pane: a reload waits for an open talk box to close, then happens"
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

# The bridge strip opens the pane on one item of NEEDS YOU: a new pane starts
# its highlight there, and a pane already showing in the tab moves to it.
# The bridge strip moving the pane to a call brings that call into sight,
# even after the owner scrolled the pane by hand.
test_a_scrolled_pane_shows_the_item_it_is_moved_to() {
  reset_case
  write_registry
  write_crowded_world
  local dir="$TMP_ROOT/case$CASE"
  export FM_FACTORY_TEST_SIZE=40x70 HERDR_BIN_PATH="$BINDIR/herdr" HERDR_TAB_ID=w1:t1 HERDR_SOCKET_PATH=/run/a.sock
  DRIVE_PANE=1 HERDR_PANE_ID=w1:p9 drive_keys PGDN PGDN PGDN PGDN PGDN PGDN "SNAP:$dir/paged" \
    "SH:HERDR_PANE_ID=w1:p3 bash $PANE open --item shop-packaging" "SNAP:$dir/moved"
  assert_not_contains "$(screen_of "$dir/paged" 40 70)" "● Packaging: three calls" \
    "the fixture did not scroll the item out of sight"
  assert_contains "$(screen_of "$dir/moved" 40 70)" "▸ ● Packaging: three calls" \
    "the pane moved to the item but left it out of sight"
  unset FM_FACTORY_TEST_SIZE HERDR_BIN_PATH HERDR_TAB_ID HERDR_SOCKET_PATH
  pass "factory pane: moving a scrolled pane to an item brings that item into sight"
}

test_open_on_an_item_puts_the_highlight_on_it() {
  local out pid
  reset_case
  write_registry
  write_world
  export HERDR_BIN_PATH="$BINDIR/herdr" HERDR_TAB_ID=w1:t1 HERDR_SOCKET_PATH=/run/a.sock
  out=$(HERDR_PANE_ID=w1:p2 bash "$PANE" open --item garden-share 2>&1) || fail "open --item failed: $out"
  assert_equals "$(tail -n 1 "$CALLS")" "plugin pane open --plugin starship.factory --entrypoint factory --placement split --direction right --target-pane w1:p2 --focus --env FM_HOME=$HOME_FIX --env FM_FACTORY_ITEM=garden-share" \
    "open --item does not hand the item to the new pane"
  # Started on the item, keep acts on it with no move: it is the second item.
  DRIVE_PANE=1 FM_FACTORY_ITEM=garden-share HERDR_PANE_ID=w1:p9 drive_keys k ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.keep.garden-share.$((NOW - 109 * 60))" "the highlight did not start on the item"
  : > "$FM_FACTORY_TEST_NOTES"
  # A pane already showing in this tab moves its highlight; no second pane opens.
  : > "$CALLS"
  DRIVE_PANE=1 HERDR_PANE_ID=w1:p9 drive_keys "SH:HERDR_PANE_ID=w1:p3 bash $PANE open --item garden-share" k ENTER
  assert_no_grep 'plugin pane open' "$CALLS" "a second Factory pane opened in a tab that shows one"
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.keep.garden-share.$((NOW - 109 * 60))" "the open pane did not move to the item"
  assert_equals "$(find "$FM_FACTORY_TEST_CONFIG/focus" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "the pane left the request behind"
  # Another tab's pane, or a factory's own page, is not this tab's overview.
  : > "$CALLS"
  mkdir -p "$FM_FACTORY_TEST_CONFIG/panes"
  bash -c "exec -a 'fm-factory-pane.sh run --factory sample-shop' sleep 30" &
  pid=$!
  printf 'pane=w1:p5\ntab=w1:t1\nsession=/run/a.sock\nview=page\n' > "$FM_FACTORY_TEST_CONFIG/panes/$pid"
  out=$(HERDR_PANE_ID=w1:p2 bash "$PANE" open --item garden-share 2>&1) || fail "open --item failed: $out"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_grep 'plugin pane open' "$CALLS" "a factory's page was taken for the overview"
  pass "factory pane: open on an item starts the highlight there, or moves the pane already in the tab to it"
}

# The look mark as the pane left it, while the pane still runs.
look_mark() { tr '\n' ' ' < "$HOME_FIX/state/factory/last-look" 2>/dev/null | sed 's/ $//'; }

test_since_you_last_looked_follows_the_owners_last_look() {
  reset_case
  write_registry
  write_world
  local out mark="$TMP_ROOT/case$CASE/mark"
  take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$((NOW - 12 * 3600)) 12 hours" \
    "with no look recorded the feed covers the last 12 hours"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " LAST 12 HOURS" "with no look recorded the feed says it is the last 12 hours"
  assert_not_contains "$out" "SINCE YOU LAST LOOKED" "the feed claimed a look nobody recorded"
  # The owner presses a key at 06:30 and the pane keeps running.
  FM_FACTORY_NOW=$((NOW - 5400)) drive_keys DOWN "SH:cp '$HOME_FIX/state/factory/last-look' '$mark'"
  assert_equals "$(head -n 1 "$mark" 2>/dev/null)" "$((NOW - 5400))" "a key press records a look while the pane runs"
  take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$((NOW - 5400)) last look" \
    "an hour and a half later the feed starts at the last look"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " SINCE YOU LAST LOOKED, 06:30" "the feed names when the owner last looked"
  assert_not_contains "$out" "has its PR ready" "an outcome from before the last look is still listed"
  has_line "$out" " 07:20 Garden Journal failed Garden reminders failed; Starship is on it." \
    "an outcome after the last look is listed"
  # Coming back starts a new look; while it lasts the feed keeps its start.
  drive_keys DOWN
  assert_equals "$(look_mark)" "$NOW $((NOW - 5400))" "a new look keeps when the one before it ended"
  FM_FACTORY_NOW=$((NOW + 300)) take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$((NOW - 5400)) last look" \
    "pressing keys while looking does not empty the feed"
  # A look older than two days is capped and says so.
  printf '%s\n' "$((NOW - 72 * 3600))" > "$HOME_FIX/state/factory/last-look"
  take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$((NOW - 48 * 3600)) 48 hours" \
    "a look older than two days is capped at 48 hours"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " LAST 48 HOURS" "a capped feed says it is the last 48 hours"
  pass "factory pane: SINCE YOU LAST LOOKED starts at the owner's last look, and says when it does not"
}

test_focusing_the_pane_for_a_while_is_a_look() {
  reset_case
  write_registry
  write_world
  local mark="$TMP_ROOT/case$CASE/mark"
  export HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p9
  drive_keys "WAIT:9" "SH:cp '$HOME_FIX/state/factory/last-look' '$mark' 2>/dev/null || :"
  assert_absent "$mark" "an unfocused pane recorded a look"
  # The look before this one ended at 06:30.
  printf '%s\n' "$((NOW - 5400))" > "$HOME_FIX/state/factory/last-look"
  FM_FACTORY_TEST_FOCUSED=true drive_keys "WAIT:9" "SH:cp '$HOME_FIX/state/factory/last-look' '$mark'"
  assert_equals "$(tr '\n' ' ' < "$mark" 2>/dev/null | sed 's/ $//')" "$NOW $((NOW - 5400))" \
    "a pane focused for a few seconds records a look"
  assert_grep 'pane get w1:p9' "$CALLS" "the pane asks Herdr whether it is focused"
  pass "factory pane: the pane focused for a few seconds counts as a look, an unfocused one does not"
}

# clock_ahead <seconds>: a drive_keys step that moves the pane's test clock on.
clock_ahead() {
  local clock="$TMP_ROOT/case$CASE/clock"
  printf "SH:awk '{print \$1 + %d}' '%s' > '%s.new' && mv '%s.new' '%s'" "$1" "$clock" "$clock" "$clock" "$clock"
}

test_focus_alone_keeps_a_look_going_for_15_minutes() {
  reset_case
  write_registry
  write_world
  local out look="$HOME_FIX/state/factory/last-look" clock="$TMP_ROOT/case$CASE/clock" latest stamp
  local later="$TMP_ROOT/case$CASE/later" all_day="$TMP_ROOT/case$CASE/all-day"
  mkdir -p "$HOME_FIX/state/factory"
  # The look before this one ended at 06:30.
  printf '%s\n' "$((NOW - 5400))" > "$look"
  # The pane runs on a test clock that starts at 08:00 and moves on when told.
  printf '%s\n' "$((NOW - $(date +%s)))" > "$clock"
  export HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p9
  FM_FACTORY_NOW='' FM_FACTORY_TEST_CLOCK="$clock" PYTHONPATH="$CLOCK_SITE" FM_FACTORY_TEST_FOCUSED=true \
    drive_keys "WAIT:9" "$(clock_ahead 840)" "WAIT:4" "$(clock_ahead 360)" "WAIT:4" "SH:cp '$look' '$later'" \
    "$(clock_ahead 28800)" "WAIT:4" "SH:cp '$look' '$all_day'"
  latest=$(head -n 1 "$later" 2>/dev/null)
  { [ "${latest:-0}" -ge $((NOW + 840)) ] && [ "$latest" -lt $((NOW + 900)) ]; } ||
    fail "focus alone did not keep recording the look until 15 minutes in (mark: $(tr '\n' ' ' < "$later"))"
  assert_equals "$(sed -n 2p "$later")" "$((NOW - 5400))" "the focused look keeps when the look before it ended"
  assert_equals "$(cat "$all_day")" "$(cat "$later")" "a pane left focused all day kept recording a look"
  cp "$later" "$look"
  FM_FACTORY_NOW=$((NOW + 1200)) take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$((NOW - 5400)) last look" \
    "twenty minutes into the focus the feed keeps its start"
  FM_FACTORY_NOW=$((NOW + 8 * 3600)) take_record
  assert_equals "$(q '"\(.since_epoch) \(.since_from)"')" "$latest last look" \
    "after a day of focus the feed starts where focus stopped counting"
  stamp=$(python3 -c 'import sys, time; print(time.strftime("%H:%M", time.gmtime(int(sys.argv[1]))))' "$latest")
  out=$(FM_FACTORY_NOW=$((NOW + 8 * 3600)) python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " SINCE YOU LAST LOOKED, $stamp" "the heading moves on to where focus stopped counting"
  assert_not_contains "$out" "07:20 Garden Journal failed" "an outcome from before the focus is still listed"
  pass "factory pane: focus alone keeps a look going for 15 minutes, then the heading moves on"
}

test_a_failed_focus_reading_does_not_start_a_new_focus() {
  reset_case
  write_registry
  write_world
  local look="$HOME_FIX/state/factory/last-look" clock="$TMP_ROOT/case$CASE/clock"
  local fails="$TMP_ROOT/case$CASE/pane-get-fails" capped="$TMP_ROOT/case$CASE/capped" after="$TMP_ROOT/case$CASE/after"
  mkdir -p "$HOME_FIX/state/factory"
  printf '%s\n' "$((NOW - 5400))" > "$look"
  printf '%s\n' "$((NOW - $(date +%s)))" > "$clock"
  export HERDR_BIN_PATH="$BINDIR/herdr" HERDR_PANE_ID=w1:p9
  # Focus holds past the 15 minutes focus alone counts, then Herdr fails to
  # answer for a few seconds and answers focused again.
  FM_FACTORY_NOW='' FM_FACTORY_TEST_CLOCK="$clock" PYTHONPATH="$CLOCK_SITE" FM_FACTORY_TEST_FOCUSED=true \
    FM_FACTORY_TEST_PANE_GET_FAILS="$fails" \
    drive_keys "WAIT:9" "$(clock_ahead 960)" "WAIT:4" "SH:cp '$look' '$capped'" \
    "SH:touch '$fails'" "WAIT:5" "SH:rm -f '$fails'" "WAIT:10" "SH:cp '$look' '$after'"
  [ "$(head -n 1 "$capped" 2>/dev/null)" -ge "$NOW" ] 2>/dev/null ||
    fail "the focused pane recorded no look before the cap (mark: $(tr '\n' ' ' < "$capped"))"
  assert_grep 'pane get w1:p9' "$CALLS" "the pane asks Herdr whether it is focused"
  assert_equals "$(cat "$after")" "$(cat "$capped")" "a failed focus reading started a new focus and recorded a look"
  pass "factory pane: a failed focus reading from Herdr does not start a new focus"
}

fm_test_run \
  test_the_record_words_every_state \
  test_the_plain_screen_is_the_record_as_text \
  test_a_job_with_no_sign_of_life_reads_quiet \
  test_a_changing_pane_is_a_sign_of_life \
  test_ready_work_held_until_a_date_is_not_ready_for_you \
  test_held_decisions_come_through_a_non_markdown_adapter \
  test_a_ship_with_no_mode_still_reports_its_pr_ready \
  test_without_a_registry_each_project_is_a_factory \
  test_work_no_factory_claims_is_still_shown \
  test_a_small_pane_shows_its_height_and_says_what_is_below \
  test_a_small_pane_scrolls_to_everything \
  test_a_narrow_talk_box_always_shows_what_is_typed \
  test_since_you_last_looked_follows_the_owners_last_look \
  test_focusing_the_pane_for_a_while_is_a_look \
  test_focus_alone_keeps_a_look_going_for_15_minutes \
  test_a_failed_focus_reading_does_not_start_a_new_focus \
  test_writing_keys_go_through_the_inbox_and_act_on_the_highlighted_row \
  test_a_note_reaches_starship_through_the_real_inbox \
  test_the_highlight_and_open_boxes_follow_the_record \
  test_a_parked_decision_leaves_the_live_pane_within_seconds \
  test_a_calls_rebuild_on_an_older_reading_keeps_the_newer_record \
  test_talking_never_changes_who_steers \
  test_enter_opens_the_factory_tab_with_its_live_workers \
  test_a_live_copy_shows_text_at_the_top_of_a_taller_pane \
  test_a_factory_tab_opens_no_live_copy_for_parked_held_or_finished_work \
  test_a_live_copy_closes_when_its_job_ends \
  test_a_running_factory_pane_picks_up_changed_code \
  test_a_factory_pane_waits_for_an_open_talk_box_before_reloading \
  test_open_tab_stops_when_herdr_does_not_name_the_tab \
  test_workers_splits_live_copies_beside_a_page_pane \
  test_the_plugin_installs_opens_and_removes \
  test_open_on_an_item_puts_the_highlight_on_it \
  test_a_scrolled_pane_shows_the_item_it_is_moved_to

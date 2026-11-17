#!/usr/bin/env bash
# The Factory pane: bin/fm-factory.py and bin/fm-factory-pane.sh.
#
# A fixture home with neutral sample factories and a fixture fleet snapshot go
# in; the record (--data) and the screen as text (--plain) that come out are
# checked word for word. The writing keys are pressed in the real live view
# under a pseudo-terminal against a stand-in inbox that records each note, the
# talk box listens to a stand-in microphone that writes real samples and a
# stand-in for the speech service, and the Herdr calls behind the factory tab
# and the plugin run against a fake herdr that records them, so no crew, pane,
# microphone or Herdr server is touched.
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
# An idle machine unless a case says otherwise, so the host's own load never spaces rebuilds out.
export FM_FACTORY_LOADAVG=0
# The real tasks-axi, when installed, for the case that files a real reconcile
# request; every other case reads through the stand-in below.
REAL_TASKS_AXI=$(command -v tasks-axi || true)
# No microphone unless a case names one, so the talk box is typed on every host.
export FM_FACTORY_MIC=''
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
    if [ -n "${FM_FACTORY_TEST_INBOX_FAIL:-}" ]; then
      echo "fm-inbox: the inbox is not writable" >&2
      exit 1
    fi
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

# A stand-in for bin/fm-captain-hold.sh: `reconcile-requests` records its
# arguments and the task ids on stdin and keeps one request per task in the
# case's home, and `reconcile list` prints those requests the way the real one
# does. FM_FACTORY_TEST_UNBOUND makes the intake refuse an unbound source.
cat > "$BINDIR/captain-hold" <<'SH'
#!/usr/bin/env bash
reqs="$FM_HOME/reconcile.requests"
case "$1 ${2:-}" in
  'reconcile-requests '*)
    printf '%s\n' "$*" >> "$FM_HOME/captain-hold.calls"
    if [ -n "${FM_FACTORY_TEST_UNBOUND:-}" ]; then
      echo "fm-captain-hold: source factory-pane is not bound; no reconcile requests were created" >&2
      exit 1
    fi
    while IFS= read -r id; do
      printf 'stdin=%s\n' "$id" >> "$FM_HOME/captain-hold.calls"
      grep -q "^$id"$'\t' "$reqs" 2>/dev/null \
        || printf '%s\t%s\n' "$id" "${FM_FACTORY_TEST_REQUESTED:-2026-11-14T07:00:00Z}" >> "$reqs"
      printf 'reconcile: %s\n' "$id"
    done
    ;;
  'reconcile list')
    [ ! -f "$reqs" ] || awk -F'\t' '{ print $1 "\trequested=" $2 "\tsource=the pane" }' "$reqs"
    printf 'reconcile-requests: %s\n' "$( [ -f "$reqs" ] && wc -l < "$reqs" | tr -d ' ' || echo 0)"
    ;;
esac
SH
chmod +x "$BINDIR/captain-hold"
export FM_FACTORY_CAPTAIN_HOLD="$BINDIR/captain-hold"
# A stand-in inbox that takes nothing: every note is refused with a reason.
cat > "$BINDIR/inbox-down" <<'SH'
#!/usr/bin/env bash
case "$1" in
  note) cat >/dev/null; echo "fm-inbox: the inbox folder is locked" >&2; exit 1 ;;
  receipts) printf '{"pending":[],"handled":[]}\n' ;;
esac
SH
chmod +x "$BINDIR/inbox-down"

# A stand-in microphone: 16 kHz mono 16-bit samples on stdout, as the pane's
# recorder writes them. FM_FACTORY_TEST_MIC picks what it hears: `speech` (a
# second of speech, then quiet), `soft` (a quiet room, then a second of a soft
# voice at a level 2.5 times that room's, then the room again), `hum` (seventy
# seconds of a quiet room and no speech), `waiting` (fifty seconds of it),
# `dead` (seventy seconds of no sound at all), `room80` and `room150` (seventy
# seconds of a steady room at that level, of 32768) or `talking` (speech that
# never stops). It then stays
# running, so only the pane stopping it ends it; its pid goes to
# FM_FACTORY_TEST_MIC_PID.
cat > "$BINDIR/mic" <<'PY'
#!/usr/bin/env python3
import math, os, sys, time
mode = os.environ.get("FM_FACTORY_TEST_MIC", "speech")
open(os.environ["FM_FACTORY_TEST_MIC_PID"], "w").write(str(os.getpid()))
out = sys.stdout.buffer
def tenth(peak):
    return b"".join(int(peak * math.sin(i / 5.0)).to_bytes(2, "little", signed=True) for i in range(1600))
try:
    if mode == "talking":
        # Twice as fast as a clock, paced by the clock rather than by sleep
        # alone: a host whose short sleeps run long still gets that speed.
        loud, began, sent = tenth(8000), time.monotonic(), 0
        while True:
            owed = int((time.monotonic() - began) / 0.05) + 1
            if owed > sent:
                out.write(loud * (owed - sent)); out.flush(); sent = owed
            time.sleep(0.05)
    out.write({"speech": tenth(8000) * 10 + tenth(40) * 60, "hum": tenth(40) * 700,
               "soft": tenth(40) * 20 + tenth(100) * 10 + tenth(40) * 60,
               "room80": tenth(80 * math.sqrt(2)) * 700, "room150": tenth(150 * math.sqrt(2)) * 700,
               "waiting": tenth(40) * 500, "dead": tenth(0) * 700}[mode])
    out.flush()
    time.sleep(120)
except BrokenPipeError:
    pass
PY
chmod +x "$BINDIR/mic"

# A stand-in for the speech service, run as the pane runs bin/fm-deepgram-stt.sh:
# it keeps a copy of the recording it was handed and prints what was said, or
# fails when FM_FACTORY_TEST_STT_FAILS is set, or prints no words when
# FM_FACTORY_TEST_STT_EMPTY is set. FM_FACTORY_TEST_STT_LOG gets one
# line per recording handed over, the seconds of sound in it, and
# FM_FACTORY_TEST_STT_ANSWERED one line per recording it answered;
# FM_FACTORY_TEST_STT_SLOW makes it take that many seconds to answer.
cat > "$BINDIR/stt" <<'SH'
#!/usr/bin/env bash
[ -s "$1" ] || { echo "no recording" >&2; exit 2; }
cp "$1" "$FM_FACTORY_TEST_HEARD"
python3 -c 'import sys, wave
w = wave.open(sys.argv[1]); print("%.1f" % (w.getnframes() / w.getframerate()))' "$1" >> "$FM_FACTORY_TEST_STT_LOG"
[ -z "${FM_FACTORY_TEST_STT_SLOW:-}" ] || sleep "$FM_FACTORY_TEST_STT_SLOW"
[ -z "${FM_FACTORY_TEST_STT_FAILS:-}" ] || { echo "fm-deepgram-stt: the speech service did not answer" >&2; exit 1; }
echo answered >> "$FM_FACTORY_TEST_STT_ANSWERED"
[ -z "${FM_FACTORY_TEST_STT_EMPTY:-}" ] || exit 0
printf 'ask the supplier   about the ribbon first\n'
SH
chmod +x "$BINDIR/stt"

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

# The count line is the overview reading the bridge strip and the status bar
# show (fm_fleet_status_counts). This stand-in for its canonical reader answers
# each task with the current-state line of the case's fixture snapshot, and the
# reading is taken inline, so the overview folds exactly the fleet the pane draws.
cat > "$BINDIR/crew-state" <<'SH'
#!/usr/bin/env bash
exec python3 -c '
import json, sys
for task in json.load(open(sys.argv[1])).get("tasks") or []:
    if task.get("id") == sys.argv[2]:
        print((task.get("current_state") or {}).get("raw") or "state: unknown · source: none · no reading")
        sys.exit(0)
sys.exit(1)
' "$FM_FACTORY_SNAPSHOT" "$1"
SH
chmod +x "$BINDIR/crew-state"
export FM_FLEET_STATE_READER="$BINDIR/crew-state" FM_FLEET_STATE_NO_CACHE=1

# A stand-in for bin/fm-tap-desk.sh shapes: the options and recommendation each
# held decision's tap card shows, from the case's fixture file.
cat > "$BINDIR/shapes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/shapes.calls"
cat "$FM_HOME/shapes.json"
SH
chmod +x "$BINDIR/shapes"
export FM_FACTORY_SHAPES="$BINDIR/shapes"

# A counting inbox: every rebuild of the record, whole or of the owner's calls
# only, reads the inbox receipts once, so each read is logged to
# $FM_HOME/reads as `start <time> <pid>` and `end <time> <pid>`;
# FM_FACTORY_TEST_READ_SLOW makes each read take that many seconds.
cat > "$BINDIR/counting-inbox" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = receipts ]; then
  stamp() { python3 -c 'import time; print("%.3f" % time.time())'; }
  printf 'start %s %s\n' "$(stamp)" "$$" >> "$FM_HOME/reads"
  [ -z "${FM_FACTORY_TEST_READ_SLOW:-}" ] || sleep "$FM_FACTORY_TEST_READ_SLOW"
  "$(dirname "$0")/inbox" "$@"
  rc=$?
  printf 'end %s %s\n' "$(stamp)" "$$" >> "$FM_HOME/reads"
  exit "$rc"
fi
exec "$(dirname "$0")/inbox" "$@"
SH
chmod +x "$BINDIR/counting-inbox"

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
  export FM_FACTORY_TEST_MIC_PID="$TMP_ROOT/case$CASE/mic.pid" FM_FACTORY_TEST_HEARD="$TMP_ROOT/case$CASE/heard.wav"
  export FM_FACTORY_TEST_STT_LOG="$TMP_ROOT/case$CASE/stt.log" FM_FACTORY_TEST_STT_ANSWERED="$TMP_ROOT/case$CASE/stt.answered"
  export FM_FACTORY_MIC=''
  unset FM_FACTORY_TEST_MIC FM_FACTORY_TEST_STT_FAILS FM_FACTORY_TEST_STT_SLOW FM_FACTORY_TEST_STT_EMPTY FM_FACTORY_STT
  unset FM_FACTORY_TEST_NO_TAB FM_FACTORY_TEST_TAB_GONE FM_FACTORY_TEST_UNBOUND FM_FACTORY_TEST_FOCUSED HERDR_BIN_PATH HERDR_PANE_ID HERDR_TAB_ID \
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
                completion={"verb": "merged", "date": "2026-11-14"}, pr_url="https://example.invalid/r/pull/3"))
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
  assert_equals "$(q .count_line)" "2 busy · 2 decisions for you · 1 ready to merge · 1 idle" "count line"
  assert_equals "$(q '[.factories[] | .name] | join(",")')" "Sample Shop,Garden Journal,Recipe Box" "factories"
  local shop='.factories[] | select(.id == "sample-shop") | .jobs[]'
  assert_equals "$(q "[$shop | \"\(.id)=\(.state)/\(.step // \"-\")\"] | join(\" \")")" \
    "shop-search=busy/building shop-checkout=busy/checking shop-provider=decision for you/- shop-images=needs a look/- shop-coupons=needs a look/- shop-labels=waiting/- shop-old=stopped/- shop-gift=next/- shop-reviews=later/- shop-later=on hold/- shop-tax=on hold until 2026-12-01/-" \
    "every shop job state is a word"
  assert_equals "$(q '.factories[] | select(.id == "recipe-box") | .jobs[] | select(.id == "recipe-search") | .state')" \
    "needs a look" "a worker's own question is Starship's to answer, as the status bar counts it"
  assert_equals "$(q '.factories[] | select(.id == "garden-journal") | .jobs[] | select(.id == "garden-water") | .state')" \
    "failed" "failed work reads failed, as the overview names it"
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
  assert_equals "$(q "[$shop | select(.queue != null) | \"\(.id)=\(.queue)\"] | join(\" \")")" \
    "shop-provider=waits on you shop-gift=in line shop-reviews=in line shop-later=on hold shop-tax=deferred" \
    "every job nobody has started says where it stands in the queue"
  assert_equals "$(q "[$shop | select(.started != null) | .queue] | unique | tostring")" "[null]" \
    "a job with a worker is counted in the queue"
  pass "factory record: every state is a word, needs you is ordered, the feed reads newest first"
}

# A PR a second mate has ready for the owner's merge word is listed in NEEDS
# YOU beside this home's own, named by the mate, in the factory of its
# repository, from what a local or a remote mate reports to this home; a PR
# merged or closed is not.
test_a_second_mates_ready_pr_needs_you() {
  reset_case
  write_registry
  write_world
  cat > "$TMP_ROOT/case$CASE/pr-reader" <<'SH'
#!/usr/bin/env bash
case "$1" in */pull/45) echo closed ;; *) echo open ;; esac
SH
  chmod +x "$TMP_ROOT/case$CASE/pr-reader"
  export FM_SECONDMATE_PR_READER="$TMP_ROOT/case$CASE/pr-reader"
  printf 'kind=secondmate\nmode=secondmate\nwindow=tmux:near\nhome=/homes/near\n' > "$HOME_FIX/state/near.meta"
  cat > "$HOME_FIX/state/near.status" <<'LOG'
done [key=child-outcome-garden-notes-done-0a0b0c0d] [at=1794640000]: child garden-notes done: checks green pr=https://example.invalid/o/garden-journal/pull/41 mode=no-mistakes yolo=off
done [key=child-outcome-garden-old-done-0a0b0c0d] [at=1794640100]: child garden-old done: checks green pr=https://example.invalid/o/garden-journal/pull/42 mode=no-mistakes yolo=off
done [key=merged-garden-old] [at=1794640200]: merged garden-old https://example.invalid/o/garden-journal/pull/42 external
LOG
  printf 'kind=secondmate\nmode=secondmate\nwindow=remote:far\nhome=/homes/far\nremote_host=far-host\n' > "$HOME_FIX/state/far.meta"
  cat > "$HOME_FIX/state/far.status" <<'LOG'
done [key=child-outcome-fleet-count-done-0a0b0c0d] [at=1794640300]: child fleet-count done: checks green pr=https://example.invalid/o/tools/pull/44 mode=no-mistakes yolo=off
done [key=child-outcome-fleet-gone-done-0a0b0c0d] [at=1794640400]: child fleet-gone done: checks green pr=https://example.invalid/o/tools/pull/45 mode=no-mistakes yolo=off
LOG
  take_record
  assert_equals "$(q '[.needs_you[] | "\(.id):\(.kind):\(.factory):\(.mate // "-")"] | join(" ")')" \
    "garden-chart:question:garden-journal:- shop-provider:question:sample-shop:- garden-share:finished work:garden-journal:- far:fleet-count:finished work:other-work:far near:garden-notes:finished work:garden-journal:near" \
    "a second mate's ready PRs need you, named by the mate, in their repository's factory"
  assert_equals "$(q '.needs_you[] | select(.id == "near:garden-notes") | "\(.ask)|\(.pr)"')" \
    "garden-notes is ready for you to look at|https://example.invalid/o/garden-journal/pull/41" "a second mate's PR"
  assert_equals "$(q .count_line)" "2 busy · 2 decisions for you · 3 ready to merge · 1 idle" "the count holds the second mates' PRs"
  local out
  out=$(python3 "$FACTORY" --plain --width 120) || fail "--plain failed"
  has_line "$out" " ● garden-notes is ready for you to look at Garden Journal · from near · ready 53 min" \
    "the screen names the second mate and how long its PR has been ready"
  # Each done outcome is its own asking, as this home's own work is: a keep
  # sent for one does not read as the answer to the next.
  assert_equals "$(q '.needs_you[] | select(.id == "far:fleet-count") | .since')" "1794640300" \
    "a second mate's PR became ready when its done outcome was reported"
  printf '{"request_id": "factory.other-work.keep.far:fleet-count.1794640300", "body": "keep", "at": "2026-11-14T07:59:00Z"}\n' \
    > "$FM_FACTORY_TEST_NOTES"
  take_record
  assert_equals "$(q '.needs_you[] | select(.id == "far:fleet-count") | .answered.at')" "$((NOW - 60))" \
    "a keep on a second mate's PR reads as answered"
  printf 'done [key=child-outcome-fleet-count-done-6c7d8e9f] [at=1794641000]: child fleet-count done: checks green again pr=https://example.invalid/o/tools/pull/44 mode=no-mistakes yolo=off\n' \
    >> "$HOME_FIX/state/far.status"
  take_record
  assert_equals "$(q '.needs_you[] | select(.id == "far:fleet-count") | "\(.since) \(.answered)"')" "1794641000 null" \
    "a later done outcome is a new asking, not answered by the keep sent for the one before"
  # A GitLab merge request in a subgroup is filed under its repository's factory.
  printf 'done [key=child-outcome-garden-lab-done-1a2b3c4d] [at=1794641100]: child garden-lab done: checks green pr=https://gitlab.example.invalid/g/sub/garden-journal/-/merge_requests/5 mode=no-mistakes yolo=off\n' \
    >> "$HOME_FIX/state/near.status"
  take_record
  assert_equals "$(q '.needs_you[] | select(.id == "near:garden-lab") | .factory')" "garden-journal" \
    "a second mate's GitLab merge request is not filed under its repository's factory"
  unset FM_SECONDMATE_PR_READER
  pass "factory record: a second mate's ready PR needs you, named by the mate, each done outcome a new asking, and a merged or closed one does not"
}

test_the_plain_screen_is_the_record_as_text() {
  reset_case
  write_registry
  write_world
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" " STARSHIP  │  2 busy  ·  2 decisions for you  ·  1 ready to merge  ·  1 idle" "count line"
  assert_equals "$(printf '%s\n' "$out" | grep -F ' ▸ ● ' | tr -s ' ')" \
    " ▸ ● Harvest chart Garden Journal · waiting 3 h" "the cursor starts on the first question"
  assert_contains "$out" "       1  this week  · Starship suggests this" "suggested option"
  assert_not_contains "$out" "None" "a missing value printed as None"
  assert_contains "$out" "       t  Talk it through · typed" "talk it through, and how"
  assert_contains "$out" "       x  Already settled?" "a question offers already settled"
  assert_contains "$out" "       ✓ planning ••••• ▸ building •••••   checking ·····   ready to merge" "four steps"
  assert_contains "$out" "       running the search tests: 41 of 58 passed" "doing this minute"
  has_line "$out" " ● Sharper cup photos needs a look" "a blocked job"
  has_line "$out" " ● Print shipping labels waiting · tries again 09:30" "a waiting job"
  has_line "$out" " next Gift wrap at checkout · then 2 more" "next in line"
  has_line "$out" " Recipe Box idle since 06:00 · nothing queued Starship steers" "an idle factory is one row"
  has_line "$out" " 06:00 Recipe Box finished Calmer start screen is finished." "feed row"
  has_line "$out" " 06:11 Garden Journal PR ready Share a garden page as a picture has its PR ready." "a PR ready row"
  local feed
  feed=$(printf '%s\n' "$out" | sed -n '/SINCE YOU LAST LOOKED/,$p')
  assert_not_contains "$feed" "tries again" "a worker's pause reached the feed"
  assert_not_contains "$feed" "Search recipes" "a worker's own question reached the feed"
  assert_not_contains "$feed" "Gift cards" "a review finding Starship decides reached the feed"
  assert_not_contains "$feed" "Sharper cup photos" "a blocker reached the feed"
  assert_contains "$out" " ↑↓ move · 1/2/3 answer · x settled? · enter open · t talk (typed) · s who steers · q quit" "keys"
  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop) || fail "--plain --factory failed"
  assert_contains "$out" " RULES THIS CREW FOLLOWS" "rules heading"
  assert_contains "$out" "   · Anything that touches payments waits for your yes." "a rule"
  assert_contains "$out" "   12 Nov  Search results read better with the price on the first line." "a lesson"
  has_line "$out" " · 1 on hold · 1 deferred to a date" "the rest of the queue folds into a count per queue word"
  pass "factory record: the plain screen carries every state as a word"
}

# A factory's rules reach its jobs' briefs only while they fit the cap
# bin/fm-brief.sh applies, so its page shows their size against that cap, in
# the same count the brief's profile lookup reports: plain under it, marked
# near it, and said plainly to be left out over it. No rules, no size line.
test_a_factory_page_shows_its_rules_size_against_the_cap() {
  reset_case
  write_projects
  local near over out
  near=$(python3 -c 'print("é" * 1497)')
  over=$(printf '%01498d' 0)
  {
    printf '%s\n' '## Sample Shop' 'projects: sample-shop' '' 'Rules:' '- English only.' \
      '- Anything that touches payments waits for your yes.' ''
    printf '%s\n' '## Garden Journal' 'projects: garden-journal' '' 'Rules:' "- $near" ''
    printf '%s\n' '## Recipe Box' 'projects: recipe-box' '' 'Rules:' "- $over" ''
    printf '%s\n' '## Shop Api' 'projects: shop-api'
  } > "$HOME_FIX/data/factories.md"
  write_world
  take_record
  assert_equals "$(q '[.factories[] | "\(.id)=\(.rules_size)"] | join(" ")') cap=$(q .rules_cap)" \
    "sample-shop=69 garden-journal=1500 recipe-box=1501 shop-api=0 cap=1500" "each factory's rules size and the cap"
  assert_equals "$(python3 "$FACTORY" profile recipe-box --data-dir "$HOME_FIX/data" | head -n 1)" "1501 1500 Recipe Box" \
    "the brief's profile lookup reports the size the page shows"

  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop) || fail "--plain --factory sample-shop failed"
  has_line "$out" " rules 69 / 1,500 characters" "rules under the cap show their size"
  assert_not_contains "$out" "the cap" "rules under the cap were marked"
  out=$(python3 "$FACTORY" --plain --width 92 --factory garden-journal) || fail "--plain --factory garden-journal failed"
  has_line "$out" " rules 1,500 / 1,500 characters · near the cap; past it its jobs get none of these rules" \
    "rules at the cap are marked near it"
  out=$(python3 "$FACTORY" --plain --width 92 --factory recipe-box) || fail "--plain --factory recipe-box failed"
  has_line "$out" " rules 1,501 / 1,500 characters · over the cap, so its jobs get none of these rules" \
    "rules over the cap are said to be left out"
  out=$(python3 "$FACTORY" --plain --width 92 --factory shop-api) || fail "--plain --factory shop-api failed"
  assert_contains "$out" "none written down yet" "a factory with no rules"
  assert_not_contains "$out" "characters" "a factory with no rules showed a size"
  pass "factory page: rules show their size against the brief's cap, marked near it and over it"
}

# On 2026-11-15 the owner was told the backlog held about a hundred queued jobs
# and found nothing on the pane that said so: it showed only a per-project
# "N in line". The whole queue is now counted under the count line, by what
# will start it, and each factory keeps its own count.
test_the_whole_queue_is_counted_in_sight() {
  reset_case
  write_registry
  write_world
  local out snap
  take_record
  assert_equals "$(q .queue_line)" "6 queued · 2 in line · 1 on hold · 3 wait on you, 1 of them deferred to a date" \
    "the queue line"
  assert_equals "$(q '.queue | "\(.total) \(.starts_on_its_own) \(.in_line) \(.on_hold) \(.waits_on_you) \(.deferred)"')" \
    "6 0 2 1 3 1" "the queue's counts"
  assert_equals "$(q '[.factories[] | "\(.id)=\(.queue.total)/\(.queue.in_line)"] | join(" ")')" \
    "sample-shop=5/2 garden-journal=1/0 recipe-box=0/0" "each factory keeps its own count"
  out=$(python3 "$FACTORY" --plain --width 92 --height 30) || fail "--plain failed"
  assert_equals "$(printf '%s\n' "$out" | sed -n 2p)" \
    " 6 queued  ·  2 in line  ·  1 on hold  ·  3 wait on you, 1 of them deferred to a date" \
    "the queue is not the line under the count line"
  has_line "$out" " Sample Shop 5 queued · 2 in line Starship steers" "a factory at work does not say its own queue"
  # In a narrow pane the line wraps between counts, never inside one.
  out=$(python3 "$FACTORY" --plain --width 60 --height 30) || fail "--plain failed"
  assert_equals "$(printf '%s\n' "$out" | sed -n 2,3p)" \
    " 6 queued  ·  2 in line  ·  1 on hold
           ·  3 wait on you, 1 of them deferred to a date" "a narrow queue line broke inside a count"
  # Work that waits on other work, or on a date still ahead, starts on its own;
  # a date that has passed starts nothing.
  snap=$(jq '.backlog.records += [
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-ribbons" | .title = "Ribbon colours" | .blocked_by_ids = ["shop-gift"]
        | .unresolved_blocker_ids = ["shop-gift"]),
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-spring" | .title = "Spring catalogue" | .hold_kind = "future"
        | .hold_reason = "Starts with the spring range." | .hold_until = "2027-03-01"),
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-last-range" | .title = "Catalogue for the last range" | .hold_kind = "future"
        | .hold_reason = "Was to start with the last range." | .hold_until = "2026-09-01")]' \
    "$FM_FACTORY_SNAPSHOT") || fail "could not add the waiting work"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
  take_record
  assert_equals "$(q '[.factories[0].jobs[] | select(.id | test("ribbons|spring|last-range")) | "\(.id)=\(.queue)/\(.state)"] | join(" ")')" \
    "shop-ribbons=starts on its own/waits on other work shop-spring=starts on its own/on hold until 2027-03-01 shop-last-range=on hold/on hold" \
    "work that waits on other work or on a date"
  assert_equals "$(q .queue_line)" \
    "9 queued · 2 start on their own · 2 in line · 2 on hold · 3 wait on you, 1 of them deferred to a date" \
    "the queue line with work that starts on its own"
  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop) || fail "--plain --factory failed"
  has_line "$out" " 8 queued · 2 start on their own · 2 in line · 2 on hold" "a factory's page does not open its work with its queue"
  has_line "$out" " · 2 wait on you, 1 of them deferred to a date" "a factory's page lost who its queue waits on"
  has_line "$out" " · 2 start on their own · 2 on hold · 1 deferred to a date" "the rest of the queue is not folded by queue word"
  # A call for the owner that other open work blocks waits on that work, not
  # on the owner; only an aged call is an older call; any other is just one more.
  snap=$(jq '.backlog.records += [
      (.backlog.records[] | select(.id == "shop-tax")
        | .id = "shop-ribbon-maker" | .title = "Which ribbon maker" | .hold_until = null | .hold_bucket = "blocked"
        | .blocked_by_ids = ["shop-gift"] | .unresolved_blocker_ids = ["shop-gift"]),
      (.backlog.records[] | select(.id == "shop-tax")
        | .id = "shop-banner-words" | .title = "Banner wording" | .hold_until = null | .hold_bucket = "aged"
        | .hold_set = "2026-10-01T09:00:00Z"),
      (.backlog.records[] | select(.id == "shop-tax")
        | .id = "shop-gift-note" | .title = "Gift note wording" | .hold_until = null | .hold_reason = null
        | .hold_bucket = null)]' "$FM_FACTORY_SNAPSHOT") || fail "could not add the held calls"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
  take_record
  assert_equals "$(q '[.factories[0].jobs[] | select(.id | test("ribbon-maker|banner-words|gift-note")) | "\(.id)=\(.queue)"] | join(" ")')" \
    "shop-ribbon-maker=waits on other work shop-banner-words=older call shop-gift-note=waits on you" \
    "held calls are not told apart by what they wait on"
  assert_equals "$(q .queue_line)" \
    "12 queued · 2 start on their own · 2 in line · 2 on hold · 1 waits on other work · 5 wait on you, 1 of them deferred to a date" \
    "a call blocked by other work is counted as waiting on the owner"
  out=$(python3 "$FACTORY" --plain --width 92 --factory sample-shop | tr '\n' ' ' | tr -s ' ') || fail "--plain --factory failed"
  assert_contains "$out" "· 1 waits on other work · 1 more waits on you · 1 older call waits on you · 1 deferred to a date" \
    "the factory page calls every held call an older call"
  pass "factory queue: the whole queue is counted under the count line, by what starts it, and per factory"
}

# On 2026-11-17 the owner saw "41 start on their own" folded on a factory's
# page and could open none of them. They were parked until a date: looked at
# again then, never started by themselves. Parked work now says until when,
# and the folded count line opens on every job it stands for.
add_parked_work() {
  local snap
  snap=$(jq '.backlog.records += [
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-wrap-paper" | .title = "Wrapping paper samples" | .hold_kind = "parked"
        | .hold_reason = "Look again next month." | .hold_until = "2026-12-01"),
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-tags" | .title = "Gift tag colours" | .hold_kind = "parked"
        | .hold_reason = "Look again next month." | .hold_until = "2026-12-01"
        | .blocked_by_ids = ["shop-gift"] | .unresolved_blocker_ids = ["shop-gift"]),
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-new-year" | .title = "New year banner" | .hold_kind = "parked"
        | .hold_reason = "Look again after the holidays." | .hold_until = "2027-01-05"),
      (.backlog.records[] | select(.id == "shop-gift")
        | .id = "shop-summer" | .title = "Spring sale page" | .hold_kind = "parked"
        | .hold_reason = "Was to be looked at in September." | .hold_until = "2026-09-01")]' \
    "$FM_FACTORY_SNAPSHOT") || fail "could not add the parked work"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
}

test_parked_work_says_until_when_it_is_parked() {
  reset_case
  write_registry
  write_world
  add_parked_work
  local out
  take_record
  assert_equals "$(q '[.factories[0].jobs[] | select(.id | test("wrap-paper|tags|new-year|shop-summer")) | "\(.id)=\(.queue)/\(.parked_until)"] | join(" ")')" \
    "shop-wrap-paper=parked/2026-12-01 shop-tags=parked/2026-12-01 shop-new-year=parked/2027-01-05 shop-summer=on hold/null" \
    "parked work, even parked work that also waits on other work, does not read parked until its date"
  assert_equals "$(q '.queue | "\(.starts_on_its_own) \(.parked) \([.parked_until[] | "\(.until)=\(.count)"] | join(","))"')" \
    "0 3 2026-12-01=2,2027-01-05=1" "the queue does not count the parked per date"
  assert_equals "$(q .queue_line)" \
    "10 queued · 3 parked, soonest 1 Dec · 2 in line · 2 on hold · 3 wait on you, 1 of them deferred to a date" \
    "the queue line does not say until when work is parked"
  assert_not_contains "$(q .queue_line)" "on their own" "parked work reads as starting on its own"
  out=$(python3 "$FACTORY" --plain --width 120 --factory sample-shop) || fail "--plain --factory failed"
  has_line "$out" " · 3 parked, soonest 1 Dec · 2 on hold · 1 deferred to a date" \
    "the folded count line does not say until when work is parked"
  assert_not_contains "$out" "Wrapping paper samples" "a folded job was listed before its line was opened"
  pass "factory queue: parked work says until when it is parked, never that it starts on its own"
}

test_a_folded_count_line_opens_on_every_job_it_stands_for() {
  reset_case
  write_registry
  write_world
  add_parked_work
  local dir="$TMP_ROOT/case$CASE" screen
  # The factory's page has one call for the owner, then the folded line.
  DRIVE_FACTORY=sample-shop drive_keys DOWN "SNAP:$dir/on-fold" ENTER "SNAP:$dir/listed" ESC "SNAP:$dir/hidden"
  screen=$(screen_of "$dir/on-fold" 50 100)
  has_line "$screen" " ▸ · 3 parked, soonest 1 Dec · 2 on hold · 1 deferred to a date" \
    "the folded count line cannot be highlighted"
  assert_contains "$screen" "enter list them" "the keys line does not say enter lists the folded jobs"
  screen=$(screen_of "$dir/listed" 50 100)
  has_line "$screen" " 3 parked, soonest 1 Dec" "the list has no heading per count"
  has_line "$screen" " · Wrapping paper samples parked until 1 Dec" "a parked job is not listed with its date"
  has_line "$screen" " · Gift tag colours parked until 1 Dec" "a parked job that also waits on other work is not listed"
  has_line "$screen" " · New year banner parked until 5 Jan 2027" "a job parked to another date is not listed"
  has_line "$screen" " · Spring sale page on hold" "a job on hold is not listed with its queue word"
  has_line "$screen" " · Charge tax abroad deferred" "a deferred call is not listed with its queue word"
  assert_contains "$screen" "esc hide the list" "the keys line does not say esc hides the list"
  assert_not_contains "$screen" "esc back" "the keys line names esc for going back while esc hides the list"
  screen=$(screen_of "$dir/hidden" 50 100)
  assert_not_contains "$screen" "Wrapping paper samples" "esc did not hide the list"
  has_line "$screen" " ▸ · 3 parked, soonest 1 Dec · 2 on hold · 1 deferred to a date" \
    "esc left the factory's page instead of hiding the list"
  pass "factory pane: enter on a folded count line lists every job it stands for, esc hides them"
}

test_an_opened_list_closes_when_its_folded_work_is_gone() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE" screen
  # Sample Shop folds one job on hold and one deferred call; both leave while the list is open.
  DRIVE_FACTORY=sample-shop drive_keys DOWN ENTER "SNAP:$dir/listed" \
    "SH:jq '.backlog.records |= map(select(.id != \"shop-later\" and .id != \"shop-tax\"))' '$FM_FACTORY_SNAPSHOT' > '$dir/w' && mv '$dir/w' '$FM_FACTORY_SNAPSHOT' && python3 '$FACTORY' refresh" \
    "SNAP:$dir/emptied" ESC "SNAP:$dir/back"
  assert_contains "$(screen_of "$dir/listed" 50 100)" "esc hide the list" "the folded list did not open"
  screen=$(screen_of "$dir/emptied" 50 100)
  assert_not_contains "$screen" "Charge tax abroad" "the folded work did not leave the page"
  assert_not_contains "$screen" "esc hide the list" "the keys line offers to hide a list that is gone"
  assert_contains "$screen" "esc back" "the keys line does not say esc goes back once the list is gone"
  assert_contains "$(screen_of "$dir/back" 50 100)" "enter open" "the first esc after the list was gone did not go back"
  pass "factory pane: an opened folded list closes when its folded work is gone, so esc goes back"
}

# The backlog file cannot tell a blocker that was finished and archived from
# one still open, so on the owner's backlog ten jobs read as waiting on other
# work that waited on nothing. The backlog's own reading decides.
test_a_blocker_that_was_finished_and_archived_holds_nothing_up() {
  reset_case
  write_registry
  write_world
  local snap
  # The backlog file still names the blocker; the backlog's own reading knows it is done.
  jq '.backlog' "$FM_FACTORY_SNAPSHOT" > "$HOME_FIX/adapter-backlog.json"
  export FM_TEST_AXI_BACKLOG="$HOME_FIX/adapter-backlog.json"
  snap=$(jq '(.backlog.records[] | select(.id == "shop-reviews"))
      += {blocked_by_ids: ["shop-archived-long-ago"], unresolved_blocker_ids: ["shop-archived-long-ago"]}' \
    "$FM_FACTORY_SNAPSHOT") || fail "could not stage the archived blocker"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
  take_record
  assert_equals "$(q '.factories[0].jobs[] | select(.id == "shop-reviews") | "\(.queue)/\(.state)"')" "in line/later" \
    "a job whose blocker was finished and archived reads as waiting on other work"
  assert_equals "$(q .queue.starts_on_its_own)" "0" "an archived blocker was counted as work that starts on its own"
  pass "factory queue: a blocker that was finished and archived holds nothing up"
}

# The first two calls used to open as cards wherever the highlight was, so a
# list of calls pushed the floor out of sight. Only the highlighted call opens.
test_only_the_highlighted_call_opens_as_a_card() {
  reset_case
  write_registry
  write_world
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" "       1  this week  · Starship suggests this" "the highlighted call is not open"
  has_line "$out" " ● Which payment provider for the shop Sample Shop · waiting 9 h" \
    "the second call is not one line with its factory and its wait"
  assert_not_contains "$out" "Stay with the current one" "a call that is not highlighted opened as a card"
  assert_equals "$(printf '%s\n' "$out" | grep -c 'Talk it through')" "1" "more than one call is open"
  out=$(python3 "$FACTORY" --plain --width 92 --item shop-provider) || fail "--plain --item failed"
  has_line "$out" " ● Harvest chart Garden Journal · waiting 3 h" "the call the highlight left stayed open"
  assert_contains "$out" "       Starship suggests: Stay with the current one until the holidays are over." \
    "the highlighted call does not show its recommendation"
  assert_equals "$(printf '%s\n' "$out" | grep -c 'Talk it through')" "1" "more than one call is open"
  # A factory's own page follows the same rule.
  out=$(python3 "$FACTORY" --plain --width 92 --factory garden-journal) || fail "--plain --factory failed"
  assert_contains "$out" "       1  this week  · Starship suggests this" "the page's highlighted call is not open"
  has_line "$out" " ● Share a garden page as a picture is ready to merge ready 1 h 49 min" \
    "the page's other call is not one line"
  pass "factory pane: only the highlighted call opens as a card; every other call is one line"
}

# On 2026-11-15 the feed listed jobs as finished that had only been closed.
# Finished work is work the backlog holds a merged change, a landing or a
# report for; anything else that was closed reads closed.
test_closed_work_reads_closed_and_only_delivered_work_reads_finished() {
  reset_case
  write_registry
  write_world
  local snap out
  snap=$(jq '(.backlog.records[] | select(.id == "shop-gift")) as $row
    | def closed($id; $title; $more): $row + {id: $id, title: $title, state: "done",
        completion: {verb: "done", date: "2026-11-14"}} + $more;
    .backlog.records += [
      closed("shop-dropped"; "Stamp card at checkout"; {}),
      closed("shop-superseded"; "Old checkout redesign"; {pr_url: "https://example.invalid/s/pull/4"}),
      closed("shop-merged"; "Faster cart"; {completion: {verb: "merged", date: "2026-11-14"},
        pr_url: "https://example.invalid/s/pull/5"}),
      closed("shop-local"; "Tidy the price list"; {local_note: "local main"}),
      closed("shop-scout"; "Why the cart is slow"; {kind: "scout", completion: {verb: "reported", date: "2026-11-14"},
        report_path: "data/shop-scout/report.md"}),
      closed("shop-call"; "Free shipping over fifty"; {kind: "captain", hold_kind: "captain",
        hold_reason: "Free shipping needs a floor."})]' "$FM_FACTORY_SNAPSHOT") || fail "could not close the work"
  printf '%s\n' "$snap" > "$FM_FACTORY_SNAPSHOT"
  take_record
  assert_equals "$(q '[.feed[] | select(.job | test("^shop-(dropped|superseded|merged|local|scout|call)$")) | "\(.job)=\(.word)"] | sort | join(" ")')" \
    "shop-call=closed shop-dropped=closed shop-local=landed shop-merged=landed shop-scout=finished shop-superseded=closed" \
    "the word each closed job reads"
  out=$(python3 "$FACTORY" --plain --width 110) || fail "--plain failed"
  has_line "$out" " today Sample Shop closed Stamp card at checkout was closed; no change or report on record." \
    "a job closed with nothing built does not read closed"
  has_line "$out" " today Sample Shop closed Old checkout redesign was closed; no change or report on record." \
    "a job closed with its change unmerged does not read closed"
  has_line "$out" " today Sample Shop closed Free shipping over fifty was closed." "an answered call does not read closed"
  has_line "$out" " today Sample Shop landed Faster cart is in." "a merged change does not read landed"
  has_line "$out" " today Sample Shop finished Why the cart is slow is finished." "a report does not read finished"
  assert_not_contains "$(printf '%s\n' "$out" | grep -E 'Stamp card at checkout|Old checkout|Free shipping')" "finished" \
    "work that was only closed reads finished"
  pass "factory feed: closed work reads closed; only a merged change, a landing or a report reads landed or finished"
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
  assert_equals "$(q .count_line)" "2 busy · 2 decisions for you · 0 ready to merge · 1 idle" "count line"
  pass "factory record: ready work the owner held until a date reads on hold, not ready to merge"
}

# The pane can read a ship as ready before the shared overview reading lists it
# ready; until the overview does, the job is busy at checking, not ready to merge.
test_ready_work_the_overview_has_not_listed_reads_busy() {
  reset_case
  write_registry
  write_world
  local ready
  ready=$(cat "$FM_FACTORY_SNAPSHOT")
  jq '(.tasks[] | select(.id == "garden-share").current_state) |= (.state = "working" | .source = "pane"
    | .detail = "harness busy (claude-hook)" | .raw = "state: working · source: pane · harness busy (claude-hook)")' \
    "$FM_FACTORY_SNAPSHOT" > "$HOME_FIX/snapshot.next" && mv "$HOME_FIX/snapshot.next" "$FM_FACTORY_SNAPSHOT"
  printf '%s\n' "$ready" > "$HOME_FIX/ready.json"
  overview_cached true || fail "the overview could not be cached before the ship was ready"
  cp "$HOME_FIX/ready.json" "$FM_FACTORY_SNAPSHOT"
  FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 data \
    > "$TMP_ROOT/case$CASE/record.json" || fail "--data failed"
  assert_equals "$(q '.factories[] | .jobs[] | select(.id == "garden-share") | "\(.state)|\(.step // "-")"')" \
    "busy|checking" "ready work the overview has not listed read as ready to merge"
  assert_equals "$(q '[.needs_you[] | select(.id == "garden-share")] | length')" "0" \
    "ready work the overview has not listed is under NEEDS YOU"
  assert_equals "$(q .counts.ready_to_merge)" "0" "the count line counted ready work the overview has not listed"
  assert_equals "$(q '.count_line | contains("0 ready to merge")')" "true" "count line"
  take_record
  assert_equals "$(q '.factories[] | .jobs[] | select(.id == "garden-share") | "\(.state)|\(.step // "-")"')" \
    "ready to merge|ready to merge" "ready work the overview lists did not read ready to merge"
  assert_equals "$(q .counts.ready_to_merge)" "1" "the count line missed ready work the overview lists"
  pass "factory record: ready work reads busy until the shared overview lists it, then ready to merge"
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
  assert_equals "$(q '"\(.counts.decisions) \(.counts.ready_to_merge)"')" "2 1" "the adapter's held decisions are not counted"
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

# A brand-new home: no work, no projects, no fixture reading. The pane reads
# the fleet and the backlog for itself, through the stand-in that answers an
# empty backlog the way tasks-axi does, and again through the real tasks-axi
# when it is installed.
test_a_new_home_with_no_work_opens_empty() {
  reset_case
  unset FM_FACTORY_SNAPSHOT FM_TEST_AXI_BACKLOG
  fm_test_tasks_toml "$HOME_FIX/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_FIX/data/backlog.md"
  local screen path paths=("$PATH")
  [ -z "$REAL_TASKS_AXI" ] || paths+=("$(dirname "$REAL_TASKS_AXI"):$PATH")
  for path in "${paths[@]}"; do
    screen=$(PATH="$path" python3 "$FACTORY" --plain --fresh 2>&1) \
      || fail "the pane did not open on a new home with $(PATH="$path" command -v tasks-axi): $screen"
    assert_contains "$screen" "NOTHING NEEDS YOU" "a new home shows an empty pane"
  done
  [ -n "$REAL_TASKS_AXI" ] || echo "skip: tasks-axi not found; the new home was read through the stand-in only"
  pass "factory pane: a brand-new home with no work opens and shows an empty pane"
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
  # A one-line row keeps its factory and its wait, ends its title on a whole
  # word, and says it was shortened.
  has_line "$out" " ● Whether the shop shows prices with… Sample Shop · waiting 4 min" \
    "a one-line row is cut mid-word, without an ellipsis, or lost how long it waits"
  # The highlighted card shows its whole title and each option in full, wrapped.
  out=$(python3 "$FACTORY" --plain --width 70 --height 40 --item shop-packaging) || fail "--plain --item failed"
  flat=$(printf '%s\n' "$out" | sed -n '/Packaging/,/Talk it through/p' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$flat" "Packaging: three calls from the supplier visit (recycled boxes now or after the holidays, tell the printer today or on return, ask about the ribbon colour)" \
    "the card's title is cut off"
  assert_contains "$flat" "1 order the recycled boxes now, before the printer closes for the holidays and the price goes up" \
    "the card's option is cut off"
  assert_not_contains "$flat" "…" "an opened card cut its words short"
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
  local dir="$TMP_ROOT/case$CASE" screen widest
  export FM_FACTORY_TEST_SIZE=40x70
  # The box floats just under the highlighted question's card, names what it
  # is about and how it takes words, and shows every typed character with the
  # cursor at its end, broken across lines where the field ends.
  drive_keys DOWN t "half typed note that is longer than the seventy columns this pane has to show it in" \
    "SNAP:$dir/talk" ESC
  screen=$(screen_of "$dir/talk" 40 70)
  assert_contains "$(printf '%s\n' "$screen" | sed -n '/Already settled/{n;p;}')" "╭─ Tell Starship · about Packaging" \
    "the talk box does not open just under the highlighted question"
  assert_contains "$screen" "typed · no desk voice ─╮" "the talk box does not say it is typed"
  assert_contains "$screen" "│  ▸ half typed note that is longer than the seventy columns" \
    "the talk box hid the start of what was typed"
  assert_contains "$screen" "this pane has to show it in_" "the talk box hid the end of what was typed"
  has_line "$screen" " ENTER send ESC close without sending" "the keys line does not say what sends and what cancels"
  widest=$(printf '%s\n' "$screen" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')
  [ "$widest" -le 70 ] || fail "the talk box is wider than the pane ($widest)"
  unset FM_FACTORY_TEST_SIZE
  pass "factory pane: the talk box floats under the highlighted card and shows everything typed"
}

# drive_keys <keys...>: once the first screen is up, press keys in the real
# live view under a pty (FM_FACTORY_TEST_SIZE rows x columns, default 50x100),
# one per third of a second, then q. A `SH:<command>` step runs the command
# instead and waits for the pane to pick up the refreshed record; a
# `SNAP:<file>` step saves what the pane draws next; a `WAIT:<seconds>` step
# leaves the pane alone that long. With DRIVE_PANE=1 the view runs as Herdr
# starts it, through fm-factory-pane.sh run; with DRIVE_FACTORY=<id> it opens
# on that factory's page.
drive_keys() {
  overview_cached python3 - "$FACTORY" "$PANE" "$@" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    rows, cols = (int(n) for n in os.environ.get("FM_FACTORY_TEST_SIZE", "50x100").split("x"))
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    if os.environ.get("DRIVE_PANE") == "1":
        os.execvp("bash", ["bash", sys.argv[2], "run"])
    factory = os.environ.get("DRIVE_FACTORY")
    os.execvp("python3", ["python3", sys.argv[1], "view"] + (["--factory", factory] if factory else []))
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
# A busy host can take well over 20 seconds to read the fleet for the first
# screen. Keys sent before it is up are thrown away when the pane makes its
# terminal raw, so wait for it, and stop loudly if it never comes.
if b"q quit" not in drain(120, until=b"q quit"):
    os.kill(pid, 9)
    while not os.waitpid(pid, os.WNOHANG)[0]:
        drain(0.2)
    sys.exit("drive_keys: the pane drew no first screen within 120 seconds")
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
    try:
        os.write(fd, {"ENTER": b"\r", "DOWN": b"\x1b[B", "UP": b"\x1b[A", "ESC": b"\x1b", "PGDN": b"\x1b[6~",
                      "PGUP": b"\x1b[5~", "WHEELDOWN": b"\x1b[<65;10;10M", "WHEELUP": b"\x1b[<64;10;10M",
                      "CLICK": b"\x1b[<0;10;10M\x1b[<0;10;10m"}.get(key, key.encode()))
    except OSError:
        break   # a key before this one already quit the pane
    drain(0.35)
# Keep reading the pty while the pane exits, so its last writes never block.
end = time.monotonic() + 15
while True:
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.monotonic() >= end:
        # Keep reading while it dies: a killed pane cannot finish exiting
        # until what it wrote to the pty has been read.
        os.kill(pid, 9)
        while not os.waitpid(pid, os.WNOHANG)[0]:
            drain(0.2)
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
  drive_keys DOWN DOWN k ENTER
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.keep.garden-share.$((NOW - 109 * 60))" "keep names the item and when it became ready"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "https://example.invalid/g/pull/12" "keep names the change"
  pass "factory pane: answer and keep go to Starship's inbox for the highlighted row only, after enter"
}

# On 2026-11-15 the owner pressed an option key, did not see the one faint
# confirmation line at the top of the pane, pressed something else, and his
# answer was dropped without a word. The confirmation now sits on the card and
# on the keys line, only enter or esc ends it, and the pane says what happened.
test_an_answer_is_never_dropped_silently() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE" screen out
  drive_keys 2 "SNAP:$dir/asked" x q DOWN "SNAP:$dir/held" 3 "SNAP:$dir/changed" ENTER "SNAP:$dir/sent"
  screen=$(screen_of "$dir/asked" 50 100)
  assert_contains "$(printf '%s\n' "$screen" | sed -n '/Already settled/{n;p;}' | sed -E 's/(─)+/─/g')" \
    "╭─ Your answer · Harvest chart ─ not sent yet ─╮" "no box under the card says the answer is not sent yet"
  assert_contains "$screen" "│  2 this season " "the box does not show the answer picked"
  assert_contains "$screen" "enter sends it to Starship · esc cancels " \
    "the box does not say which key sends the answer"
  assert_not_contains "$screen" "another option key" "the box offers to change the answer while it waits"
  has_line "$screen" " ▸ 2 this season" "the picked option is not marked on the card"
  has_line "$screen" " ENTER send answer 2 to Starship ESC cancel" "the keys line does not say what sends the answer"
  screen=$(screen_of "$dir/held" 50 100)
  has_line "$screen" " Press enter to send answer 2, or esc to cancel." "a stray key was not answered with what to press"
  assert_contains "$screen" "│  2 this season " "a stray key closed the confirmation"
  screen=$(screen_of "$dir/changed" 50 100)
  has_line "$screen" " Press enter to send answer 2, or esc to cancel." "another option key was not answered with what to press"
  assert_contains "$screen" "│  2 this season " "another option key changed the answer waiting to be sent"
  assert_not_contains "$screen" "│  3 both side by side " "another option key changed the answer waiting to be sent"
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.answer.garden-chart.$((NOW - 3 * 3600)).2" "one answer went, the first one picked"
  screen=$(screen_of "$dir/sent" 50 100)
  has_line "$screen" " ✓ SENT to Starship: answer 2, this season (Harvest chart)" "the pane does not say the answer was sent"
  has_line "$screen" " ▸ ● Harvest chart Garden Journal · answered 08:00, waiting for Starship" \
    "the card does not say it was answered"
  has_line "$screen" " ✓ 2 this season" "the answered option is not marked on the card"
  # The record carries it too, so the card keeps saying so after a restart,
  # until the call is settled and leaves the list.
  take_record
  assert_equals "$(q '.needs_you[0].answered | "\(.key) \(.at)"')" "2 $((NOW - 60))" \
    "the record does not carry when a call was answered"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " ▸ ● Harvest chart Garden Journal · answered 07:59, waiting for Starship" \
    "an answered call still reads as waiting"
  has_line "$out" " ✓ 2 this season" "the answered option is not marked on the card"
  assert_equals "$(q '[.needs_you[1:][] | .answered] | unique | tostring')" "[null]" "a call nobody answered reads as answered"
  : > "$FM_FACTORY_TEST_NOTES"
  drive_keys 2 ESC "SNAP:$dir/cancelled"
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "esc sent the answer"
  has_line "$(screen_of "$dir/cancelled" 50 100)" " Not sent: answer 2 was cancelled." "a cancelled answer is not said to be unsent"
  reset_case
  write_registry
  write_world
  FM_FACTORY_INBOX="$BINDIR/inbox-down" drive_keys 2 ENTER "SNAP:$dir/refused"
  screen=$(screen_of "$dir/refused" 50 100 | tr '\n' ' ' | tr -s ' ')
  assert_contains "$screen" "✗ NOT SENT: fm-inbox: the inbox folder is locked. Nothing reached Starship; press the key again." \
    "a note the inbox refused is not said to be unsent"
  assert_not_contains "$screen" "answered 0" "a refused answer reads as answered"
  pass "factory pane: an answer waits for enter in plain sight, and the pane says sent, not sent or cancelled"
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
  overview_cached python3 - "$FACTORY" "$@" <<'PY'
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
        while not os.waitpid(pid, os.WNOHANG)[0]:
            drain(0.2)
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
  overview_cached python3 "$FACTORY" refresh || fail "the first record could not be built"
  took=$(watch_pane '2 decisions for you' '1 decision for you' "$BINDIR/park-world garden-chart") \
    || fail "the live pane could not be driven"
  case "$took" in
    never|'no first screen'|'') fail "the live pane still showed the parked decision: $took" ;;
  esac
  awk -v t="$took" 'BEGIN { exit !(t < 4.5) }' || fail "the live pane took ${took}s to drop the parked decision"
  cp "$HOME_FIX/state/factory/record.json" "$TMP_ROOT/case$CASE/record.json" || fail "the pane wrote no record"
  assert_equals "$(q '[.needs_you[].id] | join(" ")')" "shop-provider garden-share" \
    "the parked decision is still in the record"
  assert_equals "$(q '[.factories[] | select(.id == "sample-shop") | .jobs[] | select(.id == "shop-search") | .state] | join("")')" \
    "busy" "the workers were lost from the record"
  pass "factory pane: a parked decision leaves the live pane within seconds, without a whole refresh (${took}s)"
}

# The rest after a whole refresh is for whole refreshes: right after a slow one
# on a busy machine, a call the owner parks still leaves NEEDS YOU within seconds.
test_a_parked_call_leaves_the_pane_within_seconds_after_a_slow_refresh() {
  local took
  reset_case
  write_registry
  write_world
  python3 "$FACTORY" refresh || fail "the first record could not be built"
  printf '{"ended": %s, "took": 90, "failed": false}\n' "$(date +%s)" > "$HOME_FIX/state/factory/rebuild.last" \
    || fail "the slow refresh could not be recorded"
  took=$(FM_FACTORY_LOADAVG=100000 watch_pane '2 decisions for you' '1 decision for you' "$BINDIR/park-world garden-chart") \
    || fail "the live pane could not be driven"
  case "$took" in
    never|'no first screen'|'') fail "the live pane still showed the parked call: $took" ;;
  esac
  awk -v t="$took" 'BEGIN { exit !(t < 4.5) }' || fail "the live pane took ${took}s to drop the parked call"
  pass "factory pane: a parked call leaves the pane within seconds after a slow refresh (${took}s)"
}

# Without a fleet reading to start from, a background rebuild of the owner's
# calls is a whole refresh, so it waits out the rest after the last one and
# records its own.
test_a_calls_rebuild_without_a_reading_rests_like_a_whole_refresh() {
  local last
  reset_case
  last="$HOME_FIX/state/factory/rebuild.last"
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  rm -f "$HOME_FIX/state/factory/basis.json"
  printf '{"ended": %s, "took": 90, "failed": false}\n' "$(date +%s)" > "$last" \
    || fail "the slow refresh could not be recorded"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls rebuild failed"
  assert_equals "0" "$(grep -c '^start' "$HOME_FIX/reads")" "a calls rebuild without a reading did not wait out the rest"
  [ ! -e "$HOME_FIX/state/factory/basis.json" ] || fail "a calls rebuild without a reading refreshed during the rest"
  rm -f "$last"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls rebuild failed"
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  [ -s "$HOME_FIX/state/factory/basis.json" ] || fail "a calls rebuild without a reading made none"
  assert_equals "false" "$(jq -r .failed "$last" 2>/dev/null)" "the whole refresh it ran recorded no rest"
  pass "factory pane: a calls rebuild without a reading rests like a whole refresh"
}

# While a whole refresh's rest lasts and there is no fleet reading to rebuild
# the owner's calls on, a pane whose calls moved starts no process at all: it
# would only find there is nothing it may do yet.
test_a_pane_with_no_reading_starts_nothing_while_it_rests() {
  local shim spawns real
  reset_case
  write_registry
  write_world
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  rm -f "$HOME_FIX/state/factory/basis.json"
  printf '{"ended": %s, "took": 90, "failed": false}\n' "$(date +%s)" > "$HOME_FIX/state/factory/rebuild.last" \
    || fail "the slow refresh could not be recorded"
  date +%s.$$.moved > "$HOME_FIX/state/.owner-calls-changed"
  shim="$TMP_ROOT/case$CASE/shim" spawns="$TMP_ROOT/case$CASE/spawns" real=$(command -v python3)
  mkdir -p "$shim" && : > "$spawns"
  cat > "$shim/python3" <<SH
#!/bin/sh
case "\${1:-}" in *fm-factory.py) printf '%s\n' "\${2:-}" >> "$spawns" ;; esac
exec "$real" "\$@"
SH
  chmod +x "$shim/python3"
  PATH="$shim:$PATH" FM_FACTORY_NOW='' open_panes 1 5 || fail "the pane could not be opened"
  assert_equals "view" "$(sort -u "$spawns" | tr '\n' ' ' | sed 's/ $//')" "a resting pane with no reading started a rebuild process"
  pass "factory pane: a pane with no reading starts nothing while it rests"
}

# A fleet reading that is there but unreadable is found by the rebuild of the
# owner's calls itself, which refreshes whole once no rest is owed, so an open
# pane whose calls moved still gets a reading back.
test_a_pane_with_an_unreadable_reading_gets_one_back() {
  local basis
  reset_case
  basis="$HOME_FIX/state/factory/basis.json"
  write_registry
  write_world
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  printf 'not a reading\n' > "$basis"
  rm -f "$HOME_FIX/state/factory/rebuild.last"
  date +%s.$$.moved > "$HOME_FIX/state/.owner-calls-changed"
  FM_FACTORY_NOW='' open_panes 1 5 || fail "the pane could not be opened"
  python3 -c 'import os, sys, time
end = time.time() + 60
while not os.path.exists(sys.argv[1]) and time.time() < end:
    time.sleep(0.2)' "$HOME_FIX/state/factory/rebuild.last"
  [ -s "$HOME_FIX/state/factory/rebuild.last" ] || fail "the pane never refreshed whole after an unreadable reading"
  assert_equals "object" "$(jq -r '.snapshot | type' "$basis" 2>/dev/null)" "the unreadable reading was never replaced"
  pass "factory pane: a pane with an unreadable reading gets one back"
}

# Panes opened together on a home with no record build one first record
# between them, not one each side by side.
test_panes_opened_with_no_record_build_one_first_record() {
  local first
  reset_case
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_NOW='' FM_FACTORY_TEST_READ_SLOW=1 open_panes 3 1 || fail "the panes could not be opened"
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  first=$(awk '/^mark$/ { exit } $1 == "start" { n++ } END { print n + 0 }' "$HOME_FIX/reads")
  assert_equals "1" "$first" "panes opened together built more than one first record"
  pass "factory pane: panes opened with no record build one first record"
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
    "busy" "the older workers replaced the newer ones"
  pass "factory pane: a calls rebuild on an older reading keeps the newer record"
}

# open_panes <count> <seconds> [command]: open <count> live overviews of the
# case's home side by side, each under its own pty, and once every one shows
# its first screen write `mark` to $FM_HOME/reads, leave them open <seconds>
# (running <command> every half second when one is given), then quit them all.
open_panes() {
  python3 - "$FACTORY" "$@" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
factory, count, seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
command = sys.argv[4] if len(sys.argv) > 4 else ""
panes = []
for _ in range(count):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 100, 0, 0))
        os.execvp("python3", ["python3", factory, "view"])
    panes.append([pid, fd, b""])
def drain(seconds):
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        ready, _, _ = select.select([p[1] for p in panes], [], [], min(left, 0.1))
        for pane in panes:
            if pane[1] in ready:
                try:
                    pane[2] = (pane[2] + os.read(pane[1], 65536))[-200000:]
                except OSError:
                    pass
began = time.monotonic()
while not all(b"q quit" in p[2] for p in panes) and time.monotonic() - began < 120:
    drain(0.2)
if not all(b"q quit" in p[2] for p in panes):
    for pane in panes:
        os.kill(pane[0], 9)
    sys.exit("open_panes: a pane drew no first screen within 120 seconds")
with open(os.path.join(os.environ["FM_HOME"], "reads"), "a") as log:
    log.write("mark\n")
end = time.monotonic() + seconds
while time.monotonic() < end:
    if command:
        subprocess.run(command, shell=True, check=True)
    drain(0.5)
for pane in panes:
    try:
        os.write(pane[1], b"q")
    except OSError:
        pass
end = time.monotonic() + 15
while panes:
    for pane in list(panes):
        if os.waitpid(pane[0], os.WNOHANG)[0]:
            panes.remove(pane)
        elif time.monotonic() > end:
            os.kill(pane[0], 9)
    drain(0.2)
PY
}

# reads_after_mark: how many reads started once the panes were all up.
reads_after_mark() {
  awk '/^mark$/ { m = 1; next } m && $1 == "start" { n++ } END { print n + 0 }' "$HOME_FIX/reads"
}

# most_at_once: the most reads that were under way at the same moment.
most_at_once() {
  awk '$1 == "start" || $1 == "end" { print $2, ($1 == "start" ? 1 : -1) }' "$HOME_FIX/reads" | sort -n -k1,1 -k2,2 |
    awk '{ n += $2; if (n > most) most = n } END { print most + 0 }'
}

# On 2026-11-16 six open panes kept a laptop's load average above 500. Every
# rebuild read the pending reconcile requests through
# `fm-captain-hold.sh reconcile list`, which moved the owner's calls signal as
# it exited, so each rebuild asked for the next one and an open pane with
# nothing changing rebuilt for as long as it stayed open.
test_an_open_pane_reads_nothing_again_while_nothing_changes() {
  reset_case
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_CAPTAIN_HOLD='' FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null \
    || fail "the first record could not be built"
  FM_FACTORY_CAPTAIN_HOLD='' FM_FACTORY_NOW='' open_panes 1 8 || fail "the pane could not be opened"
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  assert_equals "0" "$(reads_after_mark)" "an open pane rebuilt its record while nothing changed"
  pass "factory pane: an open pane reads nothing again while nothing changes"
}

# Several panes open on one home share one rebuild at a time, whichever kind,
# however often they each ask for one.
test_open_panes_never_rebuild_side_by_side() {
  reset_case
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=0 FM_FACTORY_TEST_READ_SLOW=1 open_panes 3 8 \
    "date +%s.\$\$.\$RANDOM > '$HOME_FIX/state/.owner-calls-changed'; touch '$HOME_FIX/state/shop-search.status'" \
    || fail "the panes could not be opened"
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  [ "$(reads_after_mark)" -ge 1 ] || fail "the panes never rebuilt while their calls and workers changed"
  assert_equals "1" "$(most_at_once)" "two rebuilds ran at once"
  pass "factory pane: open panes never rebuild side by side ($(reads_after_mark) rebuild reads)"
}

# A whole refresh reads every worker, so once the record is old the pane
# starts one only when a status, record or backlog file changed, or once the
# record reaches FM_FACTORY_MAX_AGE.
test_a_whole_refresh_waits_for_a_change_in_what_it_reads() {
  reset_case
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=1 FM_FACTORY_MAX_AGE=600 open_panes 1 6 || fail "the pane could not be opened"
  assert_equals "0" "$(reads_after_mark)" "an old record with nothing changed under it was rebuilt"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=1 FM_FACTORY_MAX_AGE=600 open_panes 1 6 \
    "[ -e '$HOME_FIX/touched' ] || { touch '$HOME_FIX/touched' '$HOME_FIX/state/garden-water.status'; }" \
    || fail "the pane could not be opened"
  [ "$(reads_after_mark)" -ge 1 ] || fail "a changed status file did not rebuild the record"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=1 FM_FACTORY_MAX_AGE=2 open_panes 1 6 || fail "the pane could not be opened"
  [ "$(reads_after_mark)" -ge 1 ] || fail "a record past its longest age was never rebuilt"
  rm -f "$HOME_FIX/state/factory/rebuild.last"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=1 FM_FACTORY_MAX_AGE=2 FM_FACTORY_LOADAVG=100000 open_panes 1 6 \
    || fail "the pane could not be opened"
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  assert_equals "0" "$(reads_after_mark)" "a busy machine rebuilt a record only for its age"
  pass "factory pane: a whole refresh waits for a change in what it reads, or the record's longest age on an idle machine"
}

# A busy machine gets room: once a whole refresh ends, the next one waits at
# least a minute, however often the workers' records move.
test_a_busy_machine_spaces_rebuilds_out() {
  local busy idle
  reset_case
  write_registry
  write_world
  export FM_FACTORY_INBOX="$BINDIR/counting-inbox"
  FM_FACTORY_NOW='' python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  local toucher="touch '$HOME_FIX/state/shop-search.status'"
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=0 open_panes 1 14 "$toucher" \
    || fail "the pane could not be opened"
  idle=$(reads_after_mark)
  : > "$HOME_FIX/reads"
  FM_FACTORY_NOW='' FM_FACTORY_TTL=0 FM_FACTORY_LOADAVG=100000 open_panes 1 8 "$toucher" \
    || fail "the pane could not be opened"
  busy=$(reads_after_mark)
  export FM_FACTORY_INBOX="$BINDIR/inbox"
  [ "$idle" -ge 2 ] || fail "an idle machine did not keep the workers current ($idle rebuild reads)"
  [ "$busy" -le 2 ] || fail "a busy machine still rebuilt $busy times in 8 seconds"
  pass "factory pane: a busy machine spaces rebuilds out ($idle reads idle, $busy busy)"
}

# A question held since the last whole refresh has its options read once, not
# again by every rebuild of the owner's calls, and the screen stays the same.
test_a_question_held_since_the_last_refresh_is_read_once() {
  local first second later
  reset_case
  write_registry
  write_world
  python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  later=$(date -u -r "$((NOW - 600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((NOW - 600))" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg at "$later" '(.backlog.records[] | select(.id == "garden-chart")).hold_set = $at' \
    "$FM_FACTORY_SNAPSHOT" > "$FM_FACTORY_SNAPSHOT.new" && mv "$FM_FACTORY_SNAPSHOT.new" "$FM_FACTORY_SNAPSHOT"
  jq --arg at "$later" '(.decisions[] | select(.id == "garden-chart")) |= (.held_since = $at | .identity = ($at + "#0"))' \
    "$HOME_FIX/shapes.json" > "$HOME_FIX/shapes.new" && mv "$HOME_FIX/shapes.new" "$HOME_FIX/shapes.json"
  : > "$HOME_FIX/shapes.calls"
  python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls could not be rebuilt"
  first=$(jq -S 'del(.read_at)' "$HOME_FIX/state/factory/record.json") || fail "the record is gone"
  python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls could not be rebuilt again"
  second=$(jq -S 'del(.read_at)' "$HOME_FIX/state/factory/record.json") || fail "the record is gone"
  assert_equals "garden-chart" "$(cat "$HOME_FIX/shapes.calls")" "the question's options were not read exactly once"
  assert_equals "$first" "$second" "the record changed between two rebuilds of the same records"
  assert_equals "$((NOW - 600))" "$(printf '%s' "$first" | jq -r '.needs_you[] | select(.id == "garden-chart") | .since')" \
    "the question held again does not read as held again"
  assert_equals "this week" "$(printf '%s' "$first" | jq -r '.needs_you[] | select(.id == "garden-chart") | .options[0].label')" \
    "the question held again lost its options"
  pass "factory pane: a question held since the last whole refresh has its options read once"
}

# The pane reads the fleet with `fm-fleet-snapshot.sh --light`; on a real home
# it draws exactly the record the whole `--json` snapshot gives it.
test_the_light_snapshot_gives_the_pane_the_record_the_whole_one_does() {
  local light whole
  reset_case
  write_registry
  write_projects
  unset FM_TEST_AXI_BACKLOG
  cat > "$HOME_FIX/data/backlog.md" <<'MD'
## In flight
- [ ] cup-search - Search cups by glaze (repo: sample-shop) (kind: ship) (since 2026-11-13)

## Queued
- [ ] cup-gift - Gift wrapping at checkout (repo: sample-shop) (kind: ship) (since 2026-11-12) (hold: Wrap by default or as an option?) (hold-kind: captain)
  Captain hold set: 2026-11-13T09:00:00Z
- [ ] garden-rows - Rows view for the beds (repo: garden-journal) (kind: ship) (since 2026-11-12)

## Done
- [x] recipe-print - Print a recipe card (repo: recipe-box) (kind: ship) (merged 2026-11-13)
MD
  fm_write_meta "$HOME_FIX/state/cup-search.meta" "project=sample-shop" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working [at=%s]: wiring the glaze filter\n' "$((NOW - 1200))" > "$HOME_FIX/state/cup-search.status"
  printf '{"schema":"fm-tap-shapes.v1","decisions":[{"id":"cup-gift","identity":"2026-11-13T09:00:00Z#0","title":"Gift wrapping at checkout","question":"Wrap by default or as an option?","options":["by default","as an option"],"recommended_option":"as an option","recommendation":"as an option","held_since":"2026-11-13T09:00:00Z"}],"not_shown":[]}\n' \
    > "$HOME_FIX/shapes.json"
  bash "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$HOME_FIX/whole.json" || fail "the whole snapshot failed"
  # The overview's stand-in reader folds the same fleet in both runs; only the
  # pane's own snapshot differs.
  printf '#!/usr/bin/env bash\nFM_FACTORY_SNAPSHOT=%q exec %q "$@"\n' "$HOME_FIX/whole.json" "$BINDIR/crew-state" \
    > "$TMP_ROOT/case$CASE/crew-state"
  chmod +x "$TMP_ROOT/case$CASE/crew-state"
  light=$(unset FM_FACTORY_SNAPSHOT; FM_FLEET_STATE_READER="$TMP_ROOT/case$CASE/crew-state" python3 "$FACTORY" --data --fresh) \
    || fail "the pane could not read the light snapshot"
  whole=$(FM_FACTORY_SNAPSHOT="$HOME_FIX/whole.json" python3 "$FACTORY" --data --fresh) \
    || fail "the pane could not read the whole snapshot"
  printf '%s' "$light" | jq -e '([.needs_you[] | select(.id == "cup-gift")] | length) == 1
    and ([.. | objects | select(.id? == "cup-search")] | length) > 0' >/dev/null \
    || fail "the light record lost the held question or the running job: $light"
  assert_equals "$(printf '%s' "$whole" | jq -S 'del(.read_at)')" "$(printf '%s' "$light" | jq -S 'del(.read_at)')" \
    "the pane drew a different record from the light snapshot"
  pass "factory pane: the light snapshot gives the pane the record the whole one does"
}

# A whole refresh reads the held questions' options again only when they may
# have changed: while the owner's calls signal stands still it keeps the last
# refresh's, for at most FM_FACTORY_MAX_AGE, and the screen is the same.
test_a_whole_refresh_reads_the_options_again_only_when_the_calls_moved() {
  local first second
  reset_case
  write_registry
  write_world
  export FM_FACTORY_MAX_AGE=300
  python3 "$FACTORY" refresh >/dev/null || fail "the first record could not be built"
  first=$(jq -S 'del(.read_at)' "$HOME_FIX/state/factory/record.json") || fail "the record is gone"
  : > "$HOME_FIX/shapes.calls"
  python3 "$FACTORY" refresh >/dev/null || fail "the second refresh failed"
  second=$(jq -S 'del(.read_at)' "$HOME_FIX/state/factory/record.json") || fail "the record is gone"
  assert_equals "" "$(cat "$HOME_FIX/shapes.calls")" "a refresh with the calls unchanged read the options again"
  assert_equals "$first" "$second" "the kept options changed the record"
  bash -c '. "$1/fm-owner-calls-signal-lib.sh" && fm_owner_calls_touch "$2"' _ "$ROOT/bin" "$HOME_FIX/state"
  python3 "$FACTORY" refresh >/dev/null || fail "the refresh after a call changed failed"
  grep -q garden-chart "$HOME_FIX/shapes.calls" || fail "a refresh after a call changed kept the old options"
  assert_equals "1" "$(wc -l < "$HOME_FIX/shapes.calls" | tr -d ' ')" \
    "a refresh after a call changed read the options more than once"
  assert_equals "$(printf '%s' "$first" | jq -S 'del(.calls_signal)')" \
    "$(jq -S 'del(.read_at, .calls_signal)' "$HOME_FIX/state/factory/record.json")" \
    "options read beside the fleet reading changed the record"
  : > "$HOME_FIX/shapes.calls"
  FM_FACTORY_NOW=$((NOW + 300)) python3 "$FACTORY" refresh >/dev/null || fail "the late refresh failed"
  grep -q garden-chart "$HOME_FIX/shapes.calls" || fail "options older than FM_FACTORY_MAX_AGE were kept"
  unset FM_FACTORY_MAX_AGE
  pass "factory pane: a whole refresh reads the options again only when the calls moved"
}

# Already settled? only asks: it files a reconcile request for the highlighted
# call and wakes Starship with a note naming it, and the card reads checking
# until Starship closes the call, notes it, or holds it again with new words.
test_already_settled_asks_starship_to_recheck_the_call() {
  reset_case
  write_registry
  write_world
  local screen="$TMP_ROOT/case$CASE/screen" out
  drive_keys x "SNAP:$screen"
  assert_equals "$(head -n 1 "$HOME_FIX/captain-hold.calls")" \
    "reconcile-requests --source-id factory-pane --source the Factory pane's Already settled? key" \
    "the key files through the reconcile intake under the pane's source"
  assert_equals "$(sed -n 2p "$HOME_FIX/captain-hold.calls")" "stdin=garden-chart" "it names the highlighted call"
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.settled.garden-chart.$((NOW - 3600))" "the wake note is named for the one request"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "Already settled? Harvest chart" "the wake names the call"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" \
    "The owner thinks this held call is already settled" "the wake says the owner thinks it is settled"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "Re-read the conversation now and record it in this turn" \
    "the wake asks Starship to re-read and record now"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" \
    "retitling it with bin/fm-tasks-axi.sh update garden-chart --title '<new title>', then holding it again with bin/fm-captain-hold.sh hold garden-chart --reason '<new reason>'" \
    "the wake names the supported route to rewrite the call"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "(from the Factory pane; item garden-chart)" \
    "the wake names the item"
  assert_contains "$(cat "$screen")" "Asked Starship to check whether Harvest chart is already settled." "the pane says so"
  assert_contains "$(cat "$screen")" "Starship is re-reading what you said about this" "the card reads checking at once"
  take_record
  assert_equals "$(q '[.needs_you[] | "\(.id)=\(.checking)"] | join(" ")')" \
    "garden-chart=true shop-provider=false garden-share=false" "only the asked call is checking"
  # The fast rebuild of the owner's calls reads the reconcile requests too.
  python3 "$FACTORY" refresh-calls >/dev/null || fail "the calls could not be rebuilt"
  cp "$HOME_FIX/state/factory/record.json" "$TMP_ROOT/case$CASE/record.json" || fail "the record is gone"
  assert_equals "$(q '[.needs_you[] | select(.checking) | .id] | join(" ")')" "garden-chart" \
    "a fast calls rebuild dropped checking"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " ▸ ● Harvest chart checking · Garden Journal · waiting 3 h" "the card head reads checking"
  has_line "$out" " checking Starship is re-reading what you said about this" "the checking row"
  assert_not_contains "$(printf '%s\n' "$out" | sed -n '/Harvest chart/,/Which payment/p')" "x  Already settled?" \
    "a checking card offers the key again"
  assert_contains "$out" " ↑↓ move · 1/2/3 answer · enter open · t talk (typed) · s who steers · q quit" \
    "a checking card leaves x settled? out of the footer"
  # Pressed again while checking: it says so and files and sends nothing.
  local calls_before notes_before
  calls_before=$(wc -l < "$HOME_FIX/captain-hold.calls" | tr -d ' ')
  notes_before=$(wc -l < "$FM_FACTORY_TEST_NOTES" | tr -d ' ')
  drive_keys x "SNAP:$screen"
  assert_contains "$(cat "$screen")" "Starship is already checking this." "a press while checking says so"
  assert_equals "$(wc -l < "$HOME_FIX/captain-hold.calls" | tr -d ' ')" "$calls_before" \
    "a press while checking filed a request"
  assert_equals "$(wc -l < "$FM_FACTORY_TEST_NOTES" | tr -d ' ')" "$notes_before" "a press while checking sent a note"
  # Starship closes or notes the call: its request leaves and checking clears.
  : > "$HOME_FIX/reconcile.requests"
  take_record
  assert_equals "$(q '.needs_you[0].checking')" "false" "checking cleared when the request was retired"
  # Held again with new words after the request: the card is the new call.
  drive_keys x
  "$BINDIR/edit-world" reask garden-chart $((NOW - 600)) >/dev/null || fail "edit-world failed"
  take_record
  assert_equals "$(q '.needs_you[0] | "\(.id) \(.checking)"')" "garden-chart false" \
    "a call held again since the request is not checking"
  # Finished work has no such key, and a refused request wakes no one.
  : > "$FM_FACTORY_TEST_NOTES"
  : > "$HOME_FIX/captain-hold.calls"
  drive_keys DOWN DOWN x
  assert_equals "$(cat "$HOME_FIX/captain-hold.calls")" "" "x on finished work filed a request"
  : > "$HOME_FIX/reconcile.requests"
  FM_FACTORY_TEST_UNBOUND=1 drive_keys x "SNAP:$screen"
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a refused request still woke Starship"
  assert_contains "$(cat "$screen")" "Not asked: the pane is not set up to ask this; run bin/fm-factory-pane.sh install" \
    "the refusal says how to fix it"
  pass "factory pane: x files a reconcile request for the highlighted call, wakes Starship, and reads checking until settled"
}

# A wake note that failed to save leaves the request filed and the card
# checking, but the next press still sends it; only then is a press refused.
test_already_settled_retries_a_wake_that_failed() {
  reset_case
  write_registry
  write_world
  local screen="$TMP_ROOT/case$CASE/screen"
  FM_FACTORY_TEST_INBOX_FAIL=1 drive_keys x "SNAP:$screen"
  assert_contains "$(cat "$screen")" "Not sent: fm-inbox: the inbox is not writable" "the failed note is reported"
  assert_equals "$(wc -l < "$HOME_FIX/reconcile.requests" | tr -d ' ')" "1" "the request was filed"
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES" 2>/dev/null)" "" "a failed note was saved"
  take_record
  assert_equals "$(q '.needs_you[0] | "\(.id) \(.checking)"')" "garden-chart true" "the pending request reads checking"
  drive_keys x "SNAP:$screen"
  assert_contains "$(cat "$screen")" "Asked Starship to check whether Harvest chart is already settled." \
    "a press after the failed note asks again"
  assert_equals "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" \
    "factory.garden-journal.settled.garden-chart.$((NOW - 3600))" "the retry sends the wake note"
  drive_keys x "SNAP:$screen"
  assert_contains "$(cat "$screen")" "Starship is already checking this." "a press once the note is saved says so"
  assert_equals "$(wc -l < "$FM_FACTORY_TEST_NOTES" | tr -d ' ')" "1" "a press once the note is saved sent another"
  pass "factory pane: a wake note that failed is sent by the next press, and only a sent one blocks a press"
}

# A refresh already under way when x is pressed read the reconcile requests
# before this one was filed, and the press cannot start another. The record
# it writes must not turn the card back to offering x; a record read after
# the press still decides.
test_already_settled_outlasts_a_refresh_read_before_the_press() {
  reset_case
  write_registry
  write_world
  local screen="$TMP_ROOT/case$CASE/screen" stale="$TMP_ROOT/case$CASE/stale.json"
  local holder
  python3 "$FACTORY" --data --fresh >/dev/null || fail "--data failed"
  cp "$HOME_FIX/state/factory/record.json" "$stale"
  # A rebuild under way holds the home's rebuild lock; this one holds it until
  # the end of the case.
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(600)' "$HOME_FIX/state/factory/rebuild.lock" "$TMP_ROOT/case$CASE/held" &
  holder=$!
  while [ ! -e "$TMP_ROOT/case$CASE/held" ]; do sleep 0.1; done
  drive_keys x "SH:cp '$stale' '$HOME_FIX/state/factory/record.json'" "SNAP:$screen"
  assert_contains "$(cat "$screen")" "Starship is re-reading what you said about this" \
    "the card still reads checking after a record read before the press"
  assert_not_contains "$(cat "$screen")" "x settled?" "a record read before the press offered x again"
  # Starship retires the new request at once: the record read after it decides.
  : > "$HOME_FIX/reconcile.requests"
  : > "$FM_FACTORY_TEST_NOTES"
  python3 "$FACTORY" --data --fresh >/dev/null || fail "--data failed"
  drive_keys x "SH:: > '$HOME_FIX/reconcile.requests'; python3 '$FACTORY' --data --fresh >/dev/null" "SNAP:$screen"
  assert_contains "$(cat "$screen")" "x settled?" "a record read after the press that has no request offers x again"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  pass "factory pane: a card stays checking through a refresh that read the requests before the press"
}

# The same key against the real captain-hold intake, the real inbox and a
# real backlog: starting the pane binds nothing, installing it binds its
# source, the request lands, and Starship's reconcile note or evidence close
# clears it.
test_already_settled_files_a_real_reconcile_request() {
  if [ -z "$REAL_TASKS_AXI" ]; then
    echo "skip: tasks-axi not found; the real reconcile request case did not run"
    return 0
  fi
  reset_case
  write_registry
  (unset FM_FACTORY_CAPTAIN_HOLD FM_FACTORY_INBOX FM_TEST_AXI_BACKLOG
   local hold="$ROOT/bin/fm-captain-hold.sh" out real_dir held
   real_dir=$(dirname "$REAL_TASKS_AXI")
   export PATH="$real_dir:$PATH" FM_CAPTAIN_HOLD_NOW=2026-11-14T07:30:00Z
   fm_test_tasks_toml "$HOME_FIX/.tasks.toml"
   printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_FIX/data/backlog.md"
   printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-11-14T08:00:00Z","tasks":[],"backlog":{"records":[]}}\n' \
     > "$FM_FACTORY_SNAPSHOT"
   printf '{"decisions":[]}\n' > "$HOME_FIX/shapes.json"
   touch "$HOME_FIX/state/.afk"   # the inbox then rings no primary session
   FM_CAPTAIN_HOLD_NOW=2026-11-14T07:00:00Z bash "$hold" hold chart-range --title "Harvest chart" \
     --reason "Week or season?" --repo garden-journal >/dev/null || fail "hold failed"
   DRIVE_PANE=1 drive_keys x
   bash "$hold" binding factory-pane >/dev/null 2>&1 && fail "starting the pane bound its source"
   assert_not_contains "$(bash "$hold" reconcile list)" "chart-range" "an unbound pane filed a request"
   out=$(HERDR_BIN_PATH="$BINDIR/herdr" bash "$PANE" install 2>&1) || fail "install failed: $out"
   assert_contains "$(bash "$hold" binding factory-pane)" "(any)" "installing the pane bound its source"
   DRIVE_PANE=1 drive_keys x
   out=$(bash "$hold" reconcile list)
   assert_contains "$out" "chart-range"$'\t'"requested=2026-11-14T07:30:00Z" "the request is on record"
   assert_contains "$out" "source=the Factory pane's Already settled? key" "the request names the pane"
   assert_contains "$(cat "$HOME_FIX"/state/inbox/*.note)" \
     "request_id=factory.garden-journal.settled.chart-range.$((NOW - 1800))" "the wake is a captain inbox note"
   assert_equals "$(python3 "$FACTORY" --data --fresh | jq -r '.needs_you[0] | "\(.id) \(.checking)"')" \
     "chart-range true" "the card reads checking"
   # Starship acknowledges the wake and only rewords the hold, so the request
   # stays pending from before the call was last held; a press still wakes it.
   for note in "$HOME_FIX"/state/inbox/*.note; do
     bash "$ROOT/bin/fm-inbox.sh" drain --ack "$(basename "$note" .note)" >/dev/null || fail "ack failed"
   done
   FM_CAPTAIN_HOLD_NOW=2026-11-14T07:40:00Z bash "$hold" hold chart-range --reason "Season only?" >/dev/null \
     || fail "reword failed"
   assert_contains "$(bash "$hold" reconcile list)" "chart-range"$'\t'"requested=2026-11-14T07:30:00Z" \
     "the reword left the request pending"
   held=$(python3 "$FACTORY" --data --fresh | jq -r '.needs_you[0] | "\(.id) \(.checking) \(.since)"')
   assert_equals "${held% *}" "chart-range false" "a call held again since the request offers the key again"
   [ "${held##* }" -gt $((NOW - 1800)) ] || fail "the reword did not move when the call was held: $held"
   DRIVE_PANE=1 drive_keys x
   assert_contains "$(cat "$HOME_FIX"/state/inbox/*.note 2>/dev/null)" \
     "request_id=factory.garden-journal.settled.chart-range.${held##* }" \
     "a press on the reworded call is a new wake named for when it was held again"
   assert_equals "$(python3 "$FACTORY" --data --fresh | jq -r '.needs_you[0] | "\(.id) \(.checking)"')" \
     "chart-range true" "the reworded call reads checking after the press"
   printf 'Only the season part is still open.\n' > "$HOME_FIX/note.txt"
   bash "$hold" reconcile note chart-range --note-file "$HOME_FIX/note.txt" >/dev/null || fail "reconcile note failed"
   assert_equals "$(python3 "$FACTORY" --data --fresh | jq -r '.needs_you[0] | "\(.id) \(.checking)"')" \
     "chart-range false" "a reconcile note clears checking and keeps the call"
   FM_CAPTAIN_HOLD_NOW=2026-11-14T07:45:00Z DRIVE_PANE=1 drive_keys x
   assert_equals "$(find "$HOME_FIX/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "2" \
     "a new request after the note is a new wake"
   printf 'Settled in chat: the week view.\n' > "$HOME_FIX/evidence.txt"
   bash "$hold" reconcile close chart-range --evidence-file "$HOME_FIX/evidence.txt" >/dev/null \
     || fail "reconcile close failed"
   assert_equals "$(python3 "$FACTORY" --data --fresh | jq -r '.needs_you | length')" "0" \
     "a call closed with evidence leaves NEEDS YOU") || exit 1
  pass "factory pane: x files a real reconcile request through the bound pane source; a note or close clears it"
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

# wav_seconds <file>: how long a recording is, proving it is a real WAV file
# at the rate the speech service is sent.
wav_seconds() {
  python3 -c 'import sys, wave
w = wave.open(sys.argv[1]); print("%d %d %.1f" % (w.getnchannels(), w.getframerate(), w.getnframes() / w.getframerate()))' "$1"
}

mic_stopped() { ! kill -0 "$(cat "$FM_FACTORY_TEST_MIC_PID" 2>/dev/null)" 2>/dev/null; }

# On 2026-11-15 the owner pressed t and spoke, as he does to the desk voice;
# the box only took typing, so nothing he said was sent. Where this machine has
# a microphone recorder and the speech key, t now listens first.
test_t_listens_first_and_sends_when_speech_stops() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE" screen out
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" "       t  Talk it through · by voice" "the card does not say t takes voice"
  assert_contains "$out" " · t talk (voice) · " "the keys do not say t takes voice"
  # A second of speech, then quiet: it is written down and sent with no key.
  FM_FACTORY_TEST_MIC=speech drive_keys t "WAIT:2" "SNAP:$dir/sent"
  assert_contains "$(jq -r .request_id "$FM_FACTORY_TEST_NOTES")" "factory.garden-journal.talk.garden-chart." \
    "what was said about the highlighted question was not sent"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "About Harvest chart: ask the supplier about the ribbon first" "the note does not carry what was said"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "(spoken into the Factory pane; item garden-chart)" \
    "the note does not say it was spoken"
  screen=$(screen_of "$dir/sent" 50 100)
  has_line "$screen" " ✓ SENT to Starship: (voice) \"ask the supplier about the ribbon first\"" \
    "the pane does not say what it heard and sent"
  # The speech service was handed a real recording of the speech and the quiet
  # that ended it, the recorder was stopped, and no recording is left behind.
  assert_equals "$(wav_seconds "$FM_FACTORY_TEST_HEARD")" "1 16000 3.0" "the recording handed to the speech service"
  mic_stopped || fail "the recorder was left running after the note was sent"
  assert_equals "$(find "$HOME_FIX/state/factory" -name 'talk-*.wav' | wc -l | tr -d ' ')" "0" \
    "a recording was left behind after it was sent"
  # Speech that does not stop is sent on enter; the box says it is listening.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:2" "SNAP:$dir/listening" ENTER "WAIT:2"
  screen=$(screen_of "$dir/listening" 50 100)
  assert_contains "$(printf '%s\n' "$screen" | sed -n '/Already settled/{n;p;}')" "╭─ Tell Starship · about Harvest chart" \
    "no box opened under the card"
  assert_contains "$screen" "● listening 0:" "the box does not say it is listening"
  # The words appear in the box while he is still speaking.
  assert_contains "$screen" "│  ask the supplier about the ribbon first_" "the words are not shown while he speaks"
  assert_contains "$screen" "sends when you stop speaking, or on enter · esc cancels · type to write it instead" \
    "the box does not say how a spoken note is sent"
  has_line "$screen" " ENTER send what you said ESC cancel or type instead" "the keys line does not say what sends a spoken note"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "About Harvest chart: ask the supplier about the ribbon first" "enter did not send what was said"
  mic_stopped || fail "the recorder was left running after enter"
  # A soft voice, two and a half times as loud as the room, counts as speech:
  # it is sent two seconds after it stops, with no key and no minute's wait.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_MIC=soft drive_keys t "WAIT:2"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "About Harvest chart: ask the supplier about the ribbon first" "a soft voice was not taken as speech"
  assert_equals "$(wav_seconds "$FM_FACTORY_TEST_HEARD")" "1 16000 5.0" \
    "a soft voice did not end two seconds after it stopped"
  # Talking to a crew listens too.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_MIC=speech drive_keys DOWN DOWN DOWN t "WAIT:2"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "To the Sample Shop crew: ask the supplier about the ribbon first" "what was said to a crew was not sent"
  pass "factory pane: t listens first where the desk voice is set up, and sends when speech stops or on enter"
}

# Showing the words while speaking must not cost more the longer the note
# runs: only the newest few seconds are written down, a couple of seconds
# apart, and the whole note once at the end.
test_live_words_send_a_short_window_and_back_off_when_they_fail() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE" screen
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  # The stand-in talks twice as fast as a clock: eight seconds here is a note
  # of about sixteen.
  FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:8" "SNAP:$dir/long" ENTER "WAIT:2"
  sed '$d' "$FM_FACTORY_TEST_STT_LOG" | awk '$1 > 8.05 { long = 1 } END { exit long }' \
    || fail "a writing made to show the words held more than the newest 8 seconds: $(tr '\n' ' ' < "$FM_FACTORY_TEST_STT_LOG")"
  awk 'END { exit !($1 >= 12) }' "$FM_FACTORY_TEST_STT_LOG" \
    || fail "the note was not written down whole at the end: $(tr '\n' ' ' < "$FM_FACTORY_TEST_STT_LOG")"
  [ "$(wc -l < "$FM_FACTORY_TEST_STT_LOG" | tr -d ' ')" -le 7 ] \
    || fail "the words were written down more often than every two seconds: $(tr '\n' ' ' < "$FM_FACTORY_TEST_STT_LOG")"
  assert_contains "$(screen_of "$dir/long" 50 100)" "│  … ask the supplier about the ribbon first_" \
    "a long note does not show that its first words have scrolled away"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "About Harvest chart: ask the supplier about the ribbon first" "the whole note was not sent"
  # A speech service that fails is asked again only after a wait, not at once.
  reset_case
  write_registry
  write_world
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  FM_FACTORY_TEST_STT_FAILS=1 FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:7" ESC
  [ "$(wc -l < "$FM_FACTORY_TEST_STT_LOG" | tr -d ' ')" -le 2 ] \
    || fail "a failed writing was tried again at once: $(wc -l < "$FM_FACTORY_TEST_STT_LOG") tries in 7 seconds"
  assert_absent "$FM_FACTORY_TEST_NOTES" "a cancelled note was sent"
  pass "factory pane: live words send only the newest seconds, the whole note once, and back off after a failure"
}

# A note cancelled while it was being written down used to be written down and
# uploaded anyway once the writing under way returned, and left its recording.
test_a_spoken_note_cancelled_while_written_down_goes_nowhere() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE"
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  FM_FACTORY_TEST_STT_SLOW=3 FM_FACTORY_TEST_MIC=talking \
    drive_keys t "WAIT:1.5" ENTER "WAIT:0.5" "SNAP:$dir/writing" ESC "WAIT:6"
  assert_contains "$(screen_of "$dir/writing" 50 100)" "writing it down" "enter did not start writing the note down"
  assert_absent "$FM_FACTORY_TEST_NOTES" "a cancelled note was sent"
  assert_absent "$FM_FACTORY_TEST_STT_ANSWERED" "the speech service went on writing down a note that was cancelled"
  assert_equals "$(find "$HOME_FIX/state/factory" -name 'talk-*' | wc -l | tr -d ' ')" "0" \
    "a cancelled recording was left on disk"
  mic_stopped || fail "the recorder was left running after the note was cancelled"
  # Quitting while it is written down leaves nothing either.
  reset_case
  write_registry
  write_world
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  FM_FACTORY_TEST_STT_SLOW=3 FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:1.5" ENTER "WAIT:0.5" $'\003'
  sleep 5
  assert_absent "$FM_FACTORY_TEST_STT_ANSWERED" "the speech service went on writing down a note after the pane quit"
  assert_equals "$(find "$HOME_FIX/state/factory" -name 'talk-*' | wc -l | tr -d ' ')" "0" \
    "a recording was left on disk after the pane quit"
  pass "factory pane: a spoken note cancelled while it is written down is not uploaded and leaves no recording"
}

test_a_spoken_note_that_cannot_be_sent_says_so_and_falls_back_to_typing() {
  reset_case
  write_registry
  write_world
  local dir="$TMP_ROOT/case$CASE" screen kept
  export FM_FACTORY_MIC="$BINDIR/mic" FM_FACTORY_STT="$BINDIR/stt"
  # Fifty seconds without speech does not end it: it is still listening for
  # someone getting ready or speaking quietly.
  FM_FACTORY_TEST_MIC=waiting drive_keys t "WAIT:2" "SNAP:$dir/waiting" ESC
  assert_contains "$(screen_of "$dir/waiting" 50 100)" "● listening 0:5" "it stopped listening before a minute without speech"
  assert_absent "$FM_FACTORY_TEST_HEARD" "a recording still listening went to the speech service"
  # After a minute without speech it stops listening and keeps what it
  # recorded: nothing goes to the speech service until enter asks for it.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_MIC=hum drive_keys t "WAIT:3" "SNAP:$dir/held" ESC
  screen=$(screen_of "$dir/held" 50 100)
  assert_contains "$screen" "recorded 1:00" "a minute without speech did not keep the recording"
  assert_contains "$(printf '%s\n' "$screen" | tr '\n' ' ' | tr -s ' ')" \
    "Nothing counted as speech. Press enter to write down what was recorded, or type it instead. Esc cancels." \
    "a recording without speech does not say how to write it down"
  assert_absent "$FM_FACTORY_TEST_HEARD" "a recording without speech went to the speech service on its own"
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a recording without speech was sent on its own"
  mic_stopped || fail "the recorder was left running after a minute without speech"
  FM_FACTORY_TEST_MIC=hum drive_keys t "WAIT:3" ENTER "WAIT:2"
  assert_equals "$(wav_seconds "$FM_FACTORY_TEST_HEARD")" "1 16000 60.0" "enter did not write the kept minute down"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES" | sed -n 1p)" \
    "About Harvest chart: ask the supplier about the ribbon first" "the words enter wrote down were not sent"
  # A steady room loud enough to clear the quietest speech is the room, not
  # speech: it is held the same way, and nothing leaves the machine.
  for room in room80 room150; do
    : > "$FM_FACTORY_TEST_NOTES"
    rm -f "$FM_FACTORY_TEST_HEARD"
    FM_FACTORY_TEST_MIC=$room drive_keys t "WAIT:3" "SNAP:$dir/$room" ESC
    assert_contains "$(screen_of "$dir/$room" 50 100)" "recorded 1:00" "a steady $room was taken as speech"
    assert_absent "$FM_FACTORY_TEST_HEARD" "a steady $room went to the speech service"
    assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "a steady $room was sent"
  done
  # When that sound holds no words, nothing is sent and the box stays open for typing.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_STT_EMPTY=1 FM_FACTORY_TEST_MIC=hum drive_keys t "WAIT:3" ENTER "WAIT:2" "SNAP:$dir/quiet" \
    "typed instead" ENTER
  screen=$(screen_of "$dir/quiet" 50 100)
  has_line "$screen" " ✗ NOT SENT: no words were heard in what you said. Type it instead, or press esc." \
    "a recording with no words in it is not said to be unsent"
  assert_contains "$(printf '%s\n' "$screen" | sed -E 's/(─)+/─/g')" "╭─ Tell Starship · about Harvest chart ─ typed ─╮" \
    "the box did not fall back to typing"
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" \
    "$(printf 'About Harvest chart: typed instead\n\n(from the Factory pane; item garden-chart)')" \
    "the typed fallback was not sent as typed"
  mic_stopped || fail "the recorder was left running after it heard nothing"
  # A microphone this terminal may not use gives no sound at all, and says so.
  : > "$FM_FACTORY_TEST_NOTES"
  rm -f "$FM_FACTORY_TEST_HEARD"
  FM_FACTORY_TEST_MIC=dead drive_keys t "WAIT:3" "SNAP:$dir/dead" ESC
  assert_contains "$(screen_of "$dir/dead" 50 100 | tr '\n' ' ' | tr -s ' ')" \
    "✗ NOT SENT: the microphone gave no sound. Type it instead, or check that this terminal may use the microphone." \
    "a silent microphone is not named"
  assert_absent "$FM_FACTORY_TEST_HEARD" "a recording with no sound in it went to the speech service"
  # Typing while it listens drops the recording and types instead.
  FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:1" "written, not spoken" ENTER
  assert_equals "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" \
    "$(printf 'About Harvest chart: written, not spoken\n\n(from the Factory pane; item garden-chart)')" \
    "typing while it listens did not take over"
  mic_stopped || fail "the recorder was left running after typing took over"
  # Esc while it listens sends nothing and says so.
  : > "$FM_FACTORY_TEST_NOTES"
  FM_FACTORY_TEST_MIC=talking drive_keys t "WAIT:1" ESC "SNAP:$dir/dropped"
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "esc sent a spoken note"
  has_line "$(screen_of "$dir/dropped" 50 100)" " Not sent: what you said was dropped." "a dropped recording is not said to be unsent"
  mic_stopped || fail "the recorder was left running after esc"
  # Speech the service cannot write down is not sent, and its recording is
  # kept with the desk voice's unsent recordings rather than lost.
  FM_FACTORY_TEST_STT_FAILS=1 FM_FACTORY_TEST_MIC=speech drive_keys t "WAIT:3" "SNAP:$dir/failed" ESC
  assert_equals "$(cat "$FM_FACTORY_TEST_NOTES")" "" "words that could not be written down were sent"
  screen=$(screen_of "$dir/failed" 50 100 | tr '\n' ' ' | tr -s ' ')
  assert_contains "$screen" "✗ NOT SENT: what you said could not be written down (fm-deepgram-stt: the speech service did not answer). The recording is saved with the desk voice's unsent recordings. Type it instead." \
    "a failed transcription is not said to be unsent"
  kept=$(find "$HOME_FIX/state/desk-voice/unsent" -name '*.wav' 2>/dev/null | head -n 1)
  [ -n "$kept" ] || fail "the recording that could not be written down was lost"
  assert_equals "$(wav_seconds "$kept")" "1 16000 3.0" "the kept recording"
  assert_contains "$(bash "$ROOT/bin/fm-desk-voice.sh" recordings)" "dictate" "the kept recording is not listed as a dictation"
  pass "factory pane: a spoken note that cannot be sent says why, keeps its recording, and falls back to typing"
}

test_enter_opens_the_factory_tab_with_its_live_workers() {
  reset_case
  write_registry
  write_world
  local out cmd
  out=$(HERDR_BIN_PATH="$BINDIR/herdr" HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=w1:t1 HERDR_SOCKET_PATH=/run/a.sock \
    FM_FACTORY_MAX_AGE=900 python3 "$FACTORY" open-tab sample-shop 2>&1) || fail "open-tab failed: $out"
  cmd=$(sed -n 2p "$CALLS")
  assert_contains "$cmd" "FM_FACTORY_MAX_AGE=900 " "the page keeps a custom safety refresh age"
  assert_contains "$(sed -n 4p "$CALLS")" "FM_FACTORY_MAX_AGE=900 " "a live worker copy keeps a custom safety refresh age"
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
  assert_equals "$(grep -o 'follow [a-z-]*' "$CALLS" | tr '\n' ' ')" "follow shop-images follow shop-coupons " \
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
# overview_cached <command...>: run <command> the way a live pane reads the
# overview, from a cache read now with the workers' own refresh an hour away, so
# the pane's once-a-second overview read stays a cache read and only the owner's
# calls can move it.
overview_cached() {
  bash -c '. "$1/bin/fm-fleet-status-lib.sh"; _fm_fleet_collect "$2" "$(date +%s)" "$3"' \
    _ "$ROOT" "$HOME_FIX/state" "$FM_FLEET_STATE_READER" > "$HOME_FIX/state/.status-fleet-state" \
    || { echo "overview_cached: the overview could not be read into its cache" >&2; return 1; }
  FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 "$@"
}

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
  screen=$(FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" overview_cached python3 - "$code" <<'PY'
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

test_a_factory_pane_waits_while_its_code_is_empty() {
  reset_case
  write_registry
  write_world
  local code="$TMP_ROOT/case$CASE/code" screen
  code_copy "$code"
  screen=$(FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" overview_cached python3 - "$code" <<'PY'
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
path = os.path.join(code, "bin", "fm-factory.py")
text = open(path).read().replace('"q quit"', '"q leave"')
# The update has created the new file but not yet written it.
open(path + ".new", "w").close()
os.rename(path + ".new", path)
drain(2, b"\0never")
alive = os.waitpid(pid, os.WNOHANG)[0] == 0
open(path + ".new", "w").write(text)
os.rename(path + ".new", path)
after = drain(3, b"q leave")
os.kill(pid, signal.SIGTERM)
end = time.time() + 5
while time.time() < end and os.waitpid(pid, os.WNOHANG)[0] == 0:
    drain(0.2, b"\0never")
print("alive=%s after=%s" % (alive, b"q leave" in after))
PY
)
  assert_equals "$screen" "alive=True after=True" \
    "a Factory pane reloaded onto an empty file, or never reloaded once it was written"
  pass "factory pane: a running pane keeps its code while an update's file is still empty, then reloads"
}

test_a_factory_pane_reloads_code_that_changed_while_it_first_read_the_fleet() {
  reset_case
  write_registry
  write_world
  local code="$TMP_ROOT/case$CASE/code" screen
  code_copy "$code"
  # No record yet, so the pane reads the fleet before it first draws; the
  # update lands in the middle of that reading.
  cat > "$TMP_ROOT/case$CASE/shapes" <<SH
#!/usr/bin/env bash
python3 - "$code/bin/fm-factory.py" <<'PY'
import os, sys
path = sys.argv[1]
text = open(path).read()
if '"q quit"' in text:
    open(path + ".new", "w").write(text.replace('"q quit"', '"q leave"'))
    os.rename(path + ".new", path)
PY
exec "$BINDIR/shapes" "\$@"
SH
  chmod +x "$TMP_ROOT/case$CASE/shapes"
  screen=$(FM_FACTORY_SHAPES="$TMP_ROOT/case$CASE/shapes" FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" \
    overview_cached python3 - "$code" <<'PY'
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
seen = drain(25, b"q leave")
os.kill(pid, signal.SIGTERM)
end = time.time() + 5
while time.time() < end and os.waitpid(pid, os.WNOHANG)[0] == 0:
    drain(0.2, b"\0never")
print("reloaded=%s" % (b"q leave" in seen))
PY
)
  assert_equals "$screen" "reloaded=True" \
    "a Factory pane kept running old code after an update landed while it first read the fleet"
  pass "factory pane: code that changes while the pane first reads the fleet is still reloaded"
}

test_a_factory_pane_waits_for_an_open_talk_box_before_reloading() {
  reset_case
  write_registry
  write_world
  local code="$TMP_ROOT/case$CASE/code" screen
  code_copy "$code"
  screen=$(FM_FACTORY_PANE_CONFIG_DIR="$TMP_ROOT/case$CASE/config" overview_cached python3 - "$code" <<'PY'
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
os.write(fd, b"\r")
sent = drain(3, b"SENT to Starship")
sent += drain(2, b"q leave")
after = drain(15, b"q leave")
os.kill(pid, signal.SIGTERM)
end = time.time() + 5
while time.time() < end and os.waitpid(pid, os.WNOHANG)[0] == 0:
    drain(0.2, b"\0never")
print("held=%s told=%s after=%s" % (b"q leave" not in during and b"Half a thought" in during,
                                    b"SENT to Starship" in sent and b"q leave" not in sent, b"q leave" in after))
PY
)
  assert_equals "$screen" "held=True told=True after=True" \
    "a Factory pane reloaded under an open talk box or its sent notice, or never reloaded after"
  assert_contains "$(jq -r .body "$FM_FACTORY_TEST_NOTES")" "Half a thought" "the talk box did not send its text"
  pass "factory pane: a reload waits for an open talk box and its notice, then happens"
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
  assert_equals "$(bash "$ROOT/bin/fm-captain-hold.sh" binding factory-pane)" "(any)" \
    "install binds the Already settled? key's source"
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
  bash "$ROOT/bin/fm-captain-hold.sh" binding factory-pane >/dev/null 2>&1 \
    && fail "remove left the Already settled? key's source bound"
  pass "factory pane: install links and records the home, binds its reconcile source, open splits right, remove stops only its own panes and unbinds it"
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

# give_reports: a report for the finished work, a page with no report for a
# running job, and a report the provider question's hold reason names beside
# one outside data/ and one that does not exist.
give_reports() {
  mkdir -p "$HOME_FIX/data/garden-share" "$HOME_FIX/data/shop-search" "$HOME_FIX/data/provider-scout"
  printf '# Share as a picture\n' > "$HOME_FIX/data/garden-share/report.md"
  printf '<!doctype html><title>Search</title>\n' > "$HOME_FIX/data/shop-search/page.html"
  printf '# Providers compared\n' > "$HOME_FIX/data/provider-scout/report.md"
  python3 - "$HOME_FIX/snapshot.json" <<'PY2'
import json, sys
path = sys.argv[1]
snap = json.load(open(path))
for row in snap["backlog"]["records"]:
    if row["id"] == "shop-provider":
        row["hold_reason"] = ("Saved cards need a provider. See data/provider-scout/report.md, "
                              "/tmp/elsewhere/report.md and data/missing-scout/report.md.")
json.dump(snap, open(path, "w"), indent=1)
PY2
}

test_read_shows_only_where_there_is_something_to_read() {
  reset_case
  write_registry
  write_world
  local out
  take_record
  assert_equals "$(q '[.needs_you[].read[], .factories[].jobs[].read[]] | length')" "0" \
    "an item with no report had something to read"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_not_contains "$out" "Read the report" "a Read line showed with no report"
  give_reports
  take_record
  assert_equals "$(q '.needs_you[] | select(.id == "garden-share") | .read | join(",")')" "garden-share" \
    "finished work with a report reads its task"
  assert_equals "$(q '.needs_you[] | select(.id == "shop-provider") | .read | join(",")')" \
    "$(cd "$HOME_FIX/data/provider-scout" && pwd -P)/report.md" \
    "a question reads the report its hold reason names under data/, and no other"
  assert_equals "$(q '.needs_you[] | select(.id == "garden-chart") | .read | length')" "0" \
    "a report named outside the home's data/ was offered"
  assert_equals "$(q '.factories[].jobs[] | select(.id == "shop-search") | .read | join(",")')" "shop-search" \
    "a job with only a page of its own has something to read"
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_equals "$(printf '%s\n' "$out" | grep -c '^       r  Read the report$')" "2" \
    "the search job and the finished work's job each show one Read line under the folded cards"
  assert_not_contains "$out" "r read" "the keys offered r on a question with nothing to read"
  out=$(python3 "$FACTORY" --plain --width 92 --item shop-provider) || fail "--plain --item failed"
  assert_equals "$(printf '%s\n' "$out" | grep -c '^       r  Read the report$')" "3" \
    "the opened provider card did not show its Read line"
  assert_contains "$out" "r read" "the keys did not offer r on a question with something to read"
  pass "factory pane: Read shows only on a card or job with a report or page under the home's data/"
}

test_r_and_a_click_read_through_the_reader() {
  reset_case
  write_registry
  write_world
  give_reports
  local log="$TMP_ROOT/case$CASE/read.log" screen="$TMP_ROOT/case$CASE/screen" line
  cat > "$TMP_ROOT/case$CASE/reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FACTORY_TEST_READ"
SH
  chmod +x "$TMP_ROOT/case$CASE/reader"
  export FM_FACTORY_READ="$TMP_ROOT/case$CASE/reader" FM_FACTORY_TEST_READ="$log"
  drive_keys r
  [ ! -s "$log" ] || fail "r read something for a question with nothing to read: $(cat "$log")"
  drive_keys DOWN r
  assert_equals "$(cat "$log")" "$(cd "$HOME_FIX/data/provider-scout" && pwd -P)/report.md" \
    "r did not read the highlighted question's report"
  : > "$log"
  python3 "$FACTORY" --plain --width 100 --height 50 > "$screen" || fail "--plain failed"
  # The Read line under the search job, which only a click can reach.
  line=$(awk '/Search that forgives typos/ { job = 1 } job && /^       r  Read the report$/ { print NR; exit }' "$screen")
  [ -n "$line" ] || fail "no Read line in sight to click"$'\n'"$(cat "$screen")"
  drive_keys $'\x1b[<0;12;'"$line"$'M\x1b[<0;12;'"$line"'m'
  assert_equals "$(cat "$log")" "shop-search" "a click on a job's Read line did not read that job"
  : > "$log"
  drive_keys $'\x1b[<0;12;3M\x1b[<0;12;3m'
  [ ! -s "$log" ] || fail "a click off any Read line read something: $(cat "$log")"
  printf '#!/usr/bin/env bash\necho "no way to open the page" >&2\nexit 1\n' > "$TMP_ROOT/case$CASE/reader"
  drive_keys DOWN r "SNAP:$screen"
  assert_contains "$(tr -d '\033' < "$screen")" "did not open: no way to open the page" \
    "a reader that failed went unsaid"
  unset FM_FACTORY_READ FM_FACTORY_TEST_READ
  pass "factory pane: r reads the highlighted call and a click reads the Read line it lands on, in the background"
}

test_r_on_a_factory_reads_only_a_job_it_draws() {
  reset_case
  write_registry
  write_world
  give_reports
  mkdir -p "$HOME_FIX/data/recipe-search"
  printf '# Calmer start screen\n' > "$HOME_FIX/data/recipe-search/report.md"
  local log="$TMP_ROOT/case$CASE/read.log"
  cat > "$TMP_ROOT/case$CASE/reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FACTORY_TEST_READ"
SH
  chmod +x "$TMP_ROOT/case$CASE/reader"
  export FM_FACTORY_READ="$TMP_ROOT/case$CASE/reader" FM_FACTORY_TEST_READ="$log"
  take_record
  assert_equals "$(q '.factories[] | select(.id == "recipe-box") | .jobs[0] | "\(.state)|\(.read | join(","))"')" \
    "needs a look|recipe-search" "the idle factory's finished work has a report to read"
  # The stops run: three calls, then Sample Shop, Garden Journal and Recipe Box.
  drive_keys DOWN DOWN DOWN DOWN DOWN r
  [ ! -s "$log" ] || fail "r on an idle factory read a job it draws no Read line for: $(cat "$log")"
  drive_keys DOWN DOWN DOWN DOWN r
  assert_equals "$(cat "$log")" "garden-share" "r on a factory did not read the job whose Read line it draws"
  : > "$log"
  drive_keys DOWN DOWN DOWN DOWN DOWN $'\r' r
  assert_equals "$(cat "$log")" "recipe-search" "r on a factory's own page did not read the job the page draws"
  unset FM_FACTORY_READ FM_FACTORY_TEST_READ
  pass "factory pane: r on a factory reads only a job the screen draws a Read line for"
}

# add_routine_runs [project]: a day of a recurring reminder pass in Garden
# Journal, or the project named, each pass its own job: two finished with a
# report, one failed, one running now.
add_routine_runs() {
  python3 - "$HOME_FIX" "$NOW" "${1:-garden-journal}" <<'PY'
import json, os, sys
home, now, project = sys.argv[1], int(sys.argv[2]), sys.argv[3]
state, path = os.path.join(home, "state"), os.path.join(home, "snapshot.json")
world = json.load(open(path))

def task(tid, cs, detail, started, lines, kind="scout"):
    meta = os.path.join(state, tid + ".meta")
    open(meta, "w").write("kind=%s\nmode=no-mistakes\nyolo=off\nspawn_gen=s%d.1.1\n" % (kind, started))
    status = os.path.join(state, tid + ".status")
    open(status, "w").write("\n".join(lines) + "\n")
    os.utime(status, (now - 3600, now - 3600))
    world["tasks"].append({"id": tid, "kind": kind, "project": "/projects/" + project,
                           "current_state": {"state": cs[0], "source": cs[1], "detail": detail,
                                             "raw": "state: %s · source: %s · %s" % (cs[0], cs[1], detail)},
                           "paths": {"meta": {"path": meta}, "status_log": {"path": status}},
                           "hints": {"open_decisions": []}, "pr": {"url": None}})

def row(rid, title, st="in_flight", **extra):
    base = {"id": rid, "title": title, "repo": project, "state": st, "structured": True, "kind": "scout",
            "captain_actionable": False, "hold_kind": None, "hold_bucket": None, "hold_reason": None,
            "hold_set": None, "hold_until": None, "unresolved_blocker_ids": [], "since": "2026-11-14",
            "completion": {"verb": None, "date": None}, "pr_url": None}
    base.update(extra)
    world["backlog"]["records"].append(base)

for tid, at in (("remind-0600", now - 7200), ("remind-0700", now - 3600)):
    task(tid, ("done", "status-log"), "report written", at, ["done [at=%d]: report written" % (at + 600)])
    row(tid, "Reminder pass %s" % tid[-4:], "done", completion={"verb": "reported", "date": "2026-11-14"})
task("remind-0715", ("failed", "status-log"), "the weather service did not answer", now - 2700,
     ["failed [at=%d]: the weather service did not answer" % (now - 2400)])
row("remind-0715", "Reminder pass 0715")
task("remind-0750", ("working", "pane"), "harness busy (claude-hook)", now - 600,
     ["working [at=%d]: set up" % (now - 590)])
open(os.path.join(state, "remind-0750.busy-state"), "w").write(
    "v1 gen=g1 seq=2 state=busy source=claude-hook event=user-prompt-submit ts=%d\n" % (now - 60))
row("remind-0750", "Reminder pass 0750")
json.dump(world, open(path, "w"), indent=1)
PY
}

# mark_routine <project> <value>: give the factory of that project a
# `routine:` line in the registry.
mark_routine() {
  python3 -c 'import sys; p, project, value = sys.argv[1:]; t = open(p).read()
line = "projects: %s\n" % project
open(p, "w").write(t.replace(line, line + "routine: %s\n" % value))' "$HOME_FIX/data/factories.md" "$1" "$2"
}

test_routine_runs_fold_into_one_line_and_stay_out_of_the_feed() {
  reset_case
  write_registry
  # The registry marks Garden Journal's reminder passes as routine.
  mark_routine garden-journal "Reminder pass"
  write_world
  add_routine_runs
  take_record
  local garden='.factories[] | select(.id == "garden-journal")'
  assert_equals "$(q "$garden | .routine | join(\",\")")" "Reminder pass" "the factory's routine mark"
  assert_equals "$(q "[$garden | .jobs[] | select(.routine != null) | .id] | sort | join(\" \")")" \
    "remind-0715 remind-0750" "each live reminder pass is routine"
  assert_equals "$(q "$garden | .routine_runs[0] | \"\(.kind)|\(.today)|\(.last_word)|\(.last)|\(.running)|\(.folded | join(\",\"))\"")" \
    "Reminder pass|4|started|1794642600|1|remind-0750" "the routine line: runs today, the last, and what it folds"
  assert_equals "$(q '[.feed[] | select(.job // "" | startswith("remind-")) | "\(.job)=\(.word)"] | join(" ")')" \
    "remind-0715=failed" "only the failed reminder pass is in the feed"
  assert_equals "$(q '[.feed[] | select(.job // "" | startswith("remind-") | not) | "\(.word)|\(.actor)"] | join(" ")')" \
    "failed|Garden Journal PR ready|Garden Journal finished|Recipe Box asked you|Garden Journal landed|Recipe Box asked you|Sample Shop" \
    "the rest of the feed is as before"
  assert_equals "$(q .count_line)" "3 busy · 2 decisions for you · 1 ready to merge · 1 idle" \
    "the count line is not the overview's figures beside the folded pass"
  assert_equals "$(q "$garden | .crew.busy")" "0" "a folded pass does not keep the crew busy"
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  has_line "$out" " ↻ Reminder pass 4 runs today · last started 07:50 busy" "the routine line"
  assert_not_contains "$out" "Reminder pass 0750" "the running pass folds into the routine line"
  assert_not_contains "$out" "Reminder pass 0600" "a finished pass is in the feed"
  has_line "$out" " ● Reminder pass 0715 failed" "a failed pass shows as usual"
  has_line "$out" " 07:20 Garden Journal failed Reminder pass 0715 failed; Starship is on it." \
    "a failed pass is in the feed"
  pass "factory pane: routine runs fold into one line, and only a failed one reaches the feed"
}

test_a_folded_pass_counts_as_idle_and_hides_no_other_card() {
  reset_case
  write_registry
  mark_routine recipe-box "Reminder pass"
  write_world
  add_routine_runs recipe-box
  take_record
  local recipe='.factories[] | select(.id == "recipe-box")'
  assert_equals "$(q "$recipe | .routine_runs[0] | \"\(.last_word)|\(.last)|\(.running)\"")" \
    "started|1794642600|1" "the routine line: a pass started at 07:50 runs now"
  assert_equals "$(q "$recipe | \"\(.state)|\(.idle_since)|\(.crew.busy)\"")" "idle|1794642600|0" \
    "the factory is idle since its last pass, not since an older event in the feed"
  assert_equals "$(q .count_line)" "3 busy · 2 decisions for you · 1 ready to merge · 1 idle" \
    "the count line is not the overview's figures beside the folded pass"
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" "Recipe Box   idle since 07:50" "the factory reads idle since its last pass, as the count line counts it"
  has_line "$out" " ● Reminder pass 0715 failed" "the failed pass keeps its row while the next one runs folded"
  has_line "$out" " ↻ Reminder pass 4 runs today · last started 07:50 busy" "the routine line"
  assert_not_contains "$out" "Reminder pass 0750" "the running pass folds into the routine line"
  pass "factory pane: a folded pass counts as idle and hides no other card"
}

test_a_routine_line_is_yes_no_or_title_kinds() {
  local value want
  while IFS='|' read -r value want; do
    reset_case
    write_registry
    mark_routine garden-journal "$value"
    write_world
    add_routine_runs
    take_record
    assert_equals "$(q '[.factories[] | select(.id == "garden-journal") | .jobs[] | select(.routine != null)
      | "\(.id)=\(.routine)"] | sort | join(" ")')" "$want" "routine: $value"
  done <<'CASES'
YES|garden-chart=Routine work garden-share=Routine work garden-water=Routine work recipe-units=Routine work remind-0715=Routine work remind-0750=Routine work
No|
true|
remind|
reminder PASS, Garden rem, Garden|garden-water=Garden remind-0715=reminder PASS remind-0750=reminder PASS
CASES
  pass "factory pane: a routine line is yes, no, or kinds matched by a job's title"
}

test_without_a_routine_mark_every_run_shows_as_before() {
  reset_case
  write_registry
  write_world
  add_routine_runs
  take_record
  assert_equals "$(q '[.factories[] | .routine_runs | length] | add')" "0" "no routine line without a mark"
  assert_equals "$(q '[.factories[].jobs[] | select(.routine != null)] | length')" "0" \
    "no job is routine without a mark"
  assert_equals "$(q '[.feed[] | select(.job // "" | startswith("remind-")) | "\(.job)=\(.word)"] | join(" ")')" \
    "remind-0715=failed remind-0700=finished remind-0600=finished remind-0600=closed remind-0700=closed" \
    "every pass reaches the feed"
  local out
  out=$(python3 "$FACTORY" --plain --width 92) || fail "--plain failed"
  assert_contains "$out" "     ● Reminder pass 0750" "the running pass has its own card"
  assert_not_contains "$out" "↻" "a routine line without a mark"
  has_line "$out" " 07:10 Garden Journal finished Reminder pass 0700 is finished." "a finished pass is in the feed"
  pass "factory pane: without a routine mark every run shows as before"
}

fm_test_run \
  test_the_light_snapshot_gives_the_pane_the_record_the_whole_one_does \
  test_the_record_words_every_state \
  test_a_second_mates_ready_pr_needs_you \
  test_the_plain_screen_is_the_record_as_text \
  test_a_factory_page_shows_its_rules_size_against_the_cap \
  test_the_whole_queue_is_counted_in_sight \
  test_parked_work_says_until_when_it_is_parked \
  test_a_folded_count_line_opens_on_every_job_it_stands_for \
  test_an_opened_list_closes_when_its_folded_work_is_gone \
  test_a_blocker_that_was_finished_and_archived_holds_nothing_up \
  test_only_the_highlighted_call_opens_as_a_card \
  test_closed_work_reads_closed_and_only_delivered_work_reads_finished \
  test_routine_runs_fold_into_one_line_and_stay_out_of_the_feed \
  test_a_folded_pass_counts_as_idle_and_hides_no_other_card \
  test_a_routine_line_is_yes_no_or_title_kinds \
  test_without_a_routine_mark_every_run_shows_as_before \
  test_a_job_with_no_sign_of_life_reads_quiet \
  test_a_changing_pane_is_a_sign_of_life \
  test_ready_work_held_until_a_date_is_not_ready_for_you \
  test_ready_work_the_overview_has_not_listed_reads_busy \
  test_held_decisions_come_through_a_non_markdown_adapter \
  test_a_ship_with_no_mode_still_reports_its_pr_ready \
  test_without_a_registry_each_project_is_a_factory \
  test_a_new_home_with_no_work_opens_empty \
  test_work_no_factory_claims_is_still_shown \
  test_a_small_pane_shows_its_height_and_says_what_is_below \
  test_a_small_pane_scrolls_to_everything \
  test_a_narrow_talk_box_always_shows_what_is_typed \
  test_since_you_last_looked_follows_the_owners_last_look \
  test_focusing_the_pane_for_a_while_is_a_look \
  test_focus_alone_keeps_a_look_going_for_15_minutes \
  test_a_failed_focus_reading_does_not_start_a_new_focus \
  test_writing_keys_go_through_the_inbox_and_act_on_the_highlighted_row \
  test_an_answer_is_never_dropped_silently \
  test_t_listens_first_and_sends_when_speech_stops \
  test_live_words_send_a_short_window_and_back_off_when_they_fail \
  test_a_spoken_note_cancelled_while_written_down_goes_nowhere \
  test_a_spoken_note_that_cannot_be_sent_says_so_and_falls_back_to_typing \
  test_a_note_reaches_starship_through_the_real_inbox \
  test_already_settled_asks_starship_to_recheck_the_call \
  test_already_settled_retries_a_wake_that_failed \
  test_already_settled_outlasts_a_refresh_read_before_the_press \
  test_already_settled_files_a_real_reconcile_request \
  test_read_shows_only_where_there_is_something_to_read \
  test_r_and_a_click_read_through_the_reader \
  test_r_on_a_factory_reads_only_a_job_it_draws \
  test_the_highlight_and_open_boxes_follow_the_record \
  test_a_parked_decision_leaves_the_live_pane_within_seconds \
  test_a_parked_call_leaves_the_pane_within_seconds_after_a_slow_refresh \
  test_a_calls_rebuild_on_an_older_reading_keeps_the_newer_record \
  test_a_calls_rebuild_without_a_reading_rests_like_a_whole_refresh \
  test_a_pane_with_no_reading_starts_nothing_while_it_rests \
  test_panes_opened_with_no_record_build_one_first_record \
  test_a_pane_with_an_unreadable_reading_gets_one_back \
  test_an_open_pane_reads_nothing_again_while_nothing_changes \
  test_open_panes_never_rebuild_side_by_side \
  test_a_whole_refresh_waits_for_a_change_in_what_it_reads \
  test_a_busy_machine_spaces_rebuilds_out \
  test_a_question_held_since_the_last_refresh_is_read_once \
  test_a_whole_refresh_reads_the_options_again_only_when_the_calls_moved \
  test_talking_never_changes_who_steers \
  test_enter_opens_the_factory_tab_with_its_live_workers \
  test_a_live_copy_shows_text_at_the_top_of_a_taller_pane \
  test_a_factory_tab_opens_no_live_copy_for_parked_held_or_finished_work \
  test_a_live_copy_closes_when_its_job_ends \
  test_a_running_factory_pane_picks_up_changed_code \
  test_a_factory_pane_waits_while_its_code_is_empty \
  test_a_factory_pane_reloads_code_that_changed_while_it_first_read_the_fleet \
  test_a_factory_pane_waits_for_an_open_talk_box_before_reloading \
  test_open_tab_stops_when_herdr_does_not_name_the_tab \
  test_workers_splits_live_copies_beside_a_page_pane \
  test_the_plugin_installs_opens_and_removes \
  test_open_on_an_item_puts_the_highlight_on_it \
  test_a_scrolled_pane_shows_the_item_it_is_moved_to

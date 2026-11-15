#!/usr/bin/env bash
# The desk command: bin/fm-desk.py (`starship`).
#
# A fake herdr keeps a whole session (workspaces, tabs, panes and what each
# pane runs) in a JSON file and logs every call, so the desk's reading, its
# missing-only plan and its idempotence are checked against a session that
# changes as the desk acts. Fake bridge, Factory pane and factory-tab scripts
# add their panes to that session the way the real ones do; a fake process
# list stands in for the Herdr clients, and a fake osascript for Terminal.
# No real Herdr or Terminal is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-desk)
DESK="$ROOT/bin/fm-desk.py"
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE/bin" "$FAKE/tools"

# --- the fake herdr ---------------------------------------------------------
cat > "$FAKE/bin/herdr" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_HERDR_STATE"]
args = sys.argv[1:]
with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
    log.write(" ".join(args) + "\n")
session = os.environ.get("HERDR_SESSION", "")
if args[:1] == ["--session"]:
    session, args = args[1], args[2:]
with open(state_path) as f:
    st = json.load(f)
def save():
    with open(state_path, "w") as f:
        json.dump(st, f)
def out(obj):
    print(json.dumps(obj))
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default
def new_id(prefix):
    st["n"] += 1
    return "%s%d" % (prefix, st["n"])
def new_pane(tab, label=None, cmd="-zsh"):
    pane = {"pane_id": new_id("w:p"), "tab_id": tab["tab_id"], "label": label, "cmd": [cmd]}
    tab["panes"].append(pane)
    return pane
def tabs_of(wsid):
    return next(w for w in st["workspaces"] if w["workspace_id"] == wsid)["tabs"]
def all_tabs():
    return [t for w in st["workspaces"] for t in w["tabs"]]
def find_pane(pid):
    return next(p for t in all_tabs() for p in t["panes"] if p["pane_id"] == pid)
if session != st["session"]:
    sys.stderr.write("fake herdr: no session %s\n" % session); sys.exit(1)
cmd = " ".join(args[:2])
if cmd == "session list":
    out({"sessions": [{"name": st["session"], "default": st["session"] == "default",
                       "running": st["running"], "socket_path": "/fake/%s.sock" % st["session"]}]})
    sys.exit(0)
if args[:1] == ["server"]:
    st["running"] = True; save(); sys.exit(0)
if not st["running"]:
    sys.stderr.write("fake herdr: server not running\n"); sys.exit(1)
if cmd == "workspace list":
    out({"result": {"workspaces": [{"workspace_id": w["workspace_id"], "label": w["label"]} for w in st["workspaces"]]}})
elif cmd == "workspace create":
    ws = {"workspace_id": new_id("w"), "label": opt("--label"), "tabs": []}
    tab = {"tab_id": new_id("w:t"), "label": "1", "panes": []}
    ws["tabs"].append(tab); st["workspaces"].append(ws)
    root = new_pane(tab)
    save(); out({"result": {"workspace": {"workspace_id": ws["workspace_id"]}, "tab": {"tab_id": tab["tab_id"]},
                            "root_pane": {"pane_id": root["pane_id"]}}})
elif cmd == "tab list":
    out({"result": {"tabs": [{"tab_id": t["tab_id"], "label": t["label"]} for t in tabs_of(opt("--workspace"))]}})
elif cmd == "tab create":
    tab = {"tab_id": new_id("w:t"), "label": opt("--label"), "panes": []}
    tabs_of(opt("--workspace")).append(tab); root = new_pane(tab)
    save(); out({"result": {"tab": {"tab_id": tab["tab_id"]}, "root_pane": {"pane_id": root["pane_id"]}}})
elif cmd == "tab rename":
    next(t for t in all_tabs() if t["tab_id"] == args[2])["label"] = args[3]
    save(); out({"result": {}})
elif cmd in ("tab focus", "tab get"):
    out({"result": {}})
elif cmd == "pane list":
    panes = []
    for t in tabs_of(opt("--workspace")):
        for p in t["panes"]:
            entry = {"pane_id": p["pane_id"], "tab_id": t["tab_id"], "label": p.get("label")}
            if p.get("agent_session"):
                entry["agent_session"] = p["agent_session"]
            panes.append(entry)
    out({"result": {"panes": panes}})
elif cmd == "pane process-info":
    p = find_pane(opt("--pane"))
    # A shell whose startup file runs a command directly hands its foreground
    # to that command until the startup is done.
    cmds = [p["startup"]["cmd"]] if p.get("startup", {}).get("reads") else p["cmd"]
    out({"result": {"process_info": {"foreground_processes": [{"cmdline": c} for c in cmds]}}})
elif cmd == "pane read":             # a pane's screen: its "screen", else a shell prompt
    p = find_pane(args[2])
    if p.get("startup", {}).get("reads"):  # still in its startup: nothing on screen for that many reads
        p["startup"]["reads"] -= 1; save(); sys.exit(0)
    if len(p.get("screens") or []) > 1:   # a shell still starting: one screen per read
        p["screen"] = p["screens"].pop(0); save()
    elif p.get("screens"):
        p["screen"] = p["screens"][0]
    sys.stdout.write(p.get("screen", "lars@mac ~ % \n\n" if p["cmd"][0].lstrip("-") in ("zsh", "bash") else "%s\n" % p["cmd"][0]))
elif cmd == "pane run":
    p = find_pane(args[2])
    p["cmd"] = [args[3]]; save(); out({"result": {}})
elif cmd == "pane close":
    for t in all_tabs():
        t["panes"] = [p for p in t["panes"] if p["pane_id"] != args[2]]
    save(); out({"result": {}})
elif args[0] == "_add-pane":          # fake scripts: <tab> <label> <cmd>
    tab = next(t for t in all_tabs() if t["tab_id"] == args[1])
    new_pane(tab, args[2], args[3]); save()
elif args[0] == "_split":             # fake scripts: <pane> <cmd>, a new pane in that pane's tab
    tab = next(t for t in all_tabs() if any(p["pane_id"] == args[1] for p in t["panes"]))
    new_pane(tab, None, args[2]); save()
elif args[0] == "_add-tab":           # fake scripts: <workspace> <label> <cmd>
    tab = {"tab_id": new_id("w:t"), "label": args[2], "panes": []}
    tabs_of(args[1]).append(tab); new_pane(tab, None, args[3]); save(); print(tab["tab_id"])
else:
    sys.stderr.write("fake herdr: unknown call %s\n" % " ".join(args)); sys.exit(2)
PY
chmod +x "$FAKE/bin/herdr"

# --- fake bridge, Factory pane and factory tab scripts ----------------------
cat > "$FAKE/tools/fm-bridge-strip.sh" <<'SH'
#!/usr/bin/env bash
echo "bridge $*" >> "$FAKE_HERDR_CALLS"
"$HERDR_BIN_PATH" _add-pane "$HERDR_TAB_ID" "Starship bridge" "bash ../../bin/fm-bridge-strip.sh run"
SH
cat > "$FAKE/tools/fm-factory-pane.sh" <<'SH'
#!/usr/bin/env bash
echo "factory-pane $*" >> "$FAKE_HERDR_CALLS"
"$HERDR_BIN_PATH" _add-pane "$HERDR_TAB_ID" "Factories" "bash ../../bin/fm-factory-pane.sh run"
SH
cat > "$FAKE/tools/fm-factory.py" <<'PY'
import os, subprocess, sys
names = dict(line.strip().split("=", 1) for line in open(os.environ["FAKE_FACTORY_NAMES"]) if "=" in line)
fid = sys.argv[2]
if sys.argv[1] == "workers":          # workers <fid> --page <pane>: a live copy of each running job
    page = sys.argv[sys.argv.index("--page") + 1]
    with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
        log.write("factory-workers %s page=%s\n" % (fid, page))
    for line in open(os.environ["FAKE_FACTORY_JOBS"]):
        job_fid, _, job = line.strip().partition("=")
        if job_fid == fid:
            subprocess.run([os.environ["HERDR_BIN_PATH"], "_split", page,
                            "bash x/fm-factory-pane.sh follow %s" % job], check=True)
    sys.exit(0)
with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
    log.write("factory-tab %s origin=%s\n" % (fid, os.environ.get("HERDR_TAB_ID", "")))
tab = subprocess.run([os.environ["HERDR_BIN_PATH"], "_add-tab", os.environ["HERDR_WORKSPACE_ID"], names[fid],
                      "bash x/fm-factory-pane.sh run --factory %s" % fid], check=True,
                     capture_output=True, text=True).stdout.strip()
# The real open-tab records the tab it opened and the session it lives in.
records = os.path.join(os.environ["FM_HOME"], "state", "factory", "tabs")
os.makedirs(records, exist_ok=True)
with open(os.path.join(records, fid), "w") as record:
    record.write("%s\n%s\n" % (tab, os.environ.get("HERDR_SOCKET_PATH", "")))
PY

# --- fake process list and Terminal -----------------------------------------
cat > "$FAKE/bin/osascript" <<'PY'
#!/usr/bin/env python3
import os, shlex, sys
script = sys.stdin.read()
args = sys.argv[2:]
if "do script" in script:
    with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
        log.write("terminal open %s\n" % "|".join(args))
    words = shlex.split(args[0])[1:]
    words[0] = "herdr"
    with open(os.environ["FAKE_PS"], "a") as ps:
        n = sum(1 for _ in open(os.environ["FAKE_PS"]))
        ps.write("%d ttys%03d %s\n" % (900 + n, 100 + n, " ".join(words)))
    print("/dev/ttys%03d" % (100 + n))
else:
    print(open(os.environ["FAKE_TERMINAL_TABS"]).read(), end="")
PY
chmod +x "$FAKE/bin/osascript"

CASE=0
new_case() {  # <running:true|false>
  CASE=$((CASE + 1))
  C="$TMP_ROOT/case$CASE"
  mkdir -p "$C/home/config" "$C/home/state"
  export FM_HOME="$C/home" FAKE_HERDR_STATE="$C/state.json" FAKE_HERDR_CALLS="$C/calls" \
    FAKE_PS="$C/ps" FAKE_TERMINAL_TABS="$C/terminal" FAKE_FACTORY_NAMES="$C/factories" FAKE_FACTORY_JOBS="$C/jobs" \
    HERDR_BIN_PATH="$FAKE/bin/herdr" HERDR_CONFIG_PATH="$C/herdr-config.toml" \
    FM_DESK_BIN="$FAKE/tools" FM_DESK_PS="cat $C/ps" FM_DESK_OSASCRIPT="$FAKE/bin/osascript" FM_DESK_WAIT=3
  unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION
  printf '{"session": "default", "running": %s, "workspaces": [], "n": 0}\n' "$1" > "$FAKE_HERDR_STATE"
  : > "$FAKE_HERDR_CALLS"; : > "$FAKE_PS"; : > "$FAKE_TERMINAL_TABS"; : > "$FAKE_FACTORY_JOBS"
  printf 'sample-shop=Sample Shop\nrecipe-box=Recipe Box\ngarden-journal=Garden Journal\n' > "$FAKE_FACTORY_NAMES"
  printf '[ui]\nwindow_title = "desk"\n\n[theme]\nname = "tokyo-night"\n' > "$HERDR_CONFIG_PATH"
}

layout() {  # [extra lines]
  {
    printf 'workspace = starship\nsidebar = collapsed\nfirstmate = firstmate claude-opus\n'
    printf 'tab = Sample Shop | factory sample-shop\ntab = Recipe Box | factory recipe-box\ntab = Notes\n'
    printf 'view = Big Profile | 13\nview = Small Profile | 10\n'
    [ -z "${1:-}" ] || printf '%s\n' "$1"
  } > "$FM_HOME/config/desk-layout"
}

desk() { python3 "$DESK" "$@"; }

# state_query <python expression over st>: read the fake session.
state_query() {
  python3 -c "import json,sys; st=json.load(open(sys.argv[1])); print($1)" "$FAKE_HERDR_STATE"
}

test_an_empty_session_gets_the_whole_desk_in_order() {
  new_case true
  layout
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "  done: make Herdr start with the sidebar collapsed
  done: create the workspace starship
  done: start the first mate (firstmate claude-opus)
  done: show the Starship bridge
  done: show the Factory pane
  done: open the Sample Shop tab
  done: open the Recipe Box tab
  done: open the Notes tab
  done: open view 1 in Terminal (profile Big Profile, size 13)
  done: open view 2 in Terminal (profile Small Profile, size 10)" "open did not build the whole desk in order"
  assert_contains "$out" "10 thing(s) started" "open did not report what it started"
  assert_equals "1|Sample Shop|Recipe Box|Notes" "$(state_query '"|".join(t["label"] for t in st["workspaces"][0]["tabs"])')" \
    "open did not build the tabs in layout order"
  assert_equals "firstmate claude-opus|Starship bridge|Factories" \
    "$(state_query '"|".join(p.get("label") or p["cmd"][0] for p in st["workspaces"][0]["tabs"][0]["panes"])')" \
    "the first tab is not the first mate, the bridge and the Factory pane"
  assert_grep "bridge open --pane w:p3" "$FAKE_HERDR_CALLS" "the bridge was not put above the first mate's pane"
  assert_grep "factory-pane open --pane w:p3" "$FAKE_HERDR_CALLS" "the Factory pane was not put beside the first mate"
  assert_grep "factory-tab sample-shop origin=w:t2" "$FAKE_HERDR_CALLS" "a factory tab did not open through open-tab from the first tab"
  assert_grep "terminal open exec $FAKE/bin/herdr|Big Profile|13" "$FAKE_HERDR_CALLS" "view 1 did not open with its profile and size"
  assert_grep "terminal open exec $FAKE/bin/herdr|Small Profile|10" "$FAKE_HERDR_CALLS" "view 2 did not open with its profile and size"
  assert_grep "tab focus w:t2" "$FAKE_HERDR_CALLS" "focus did not go back to the first tab"
  pass "desk: an empty session gets the whole desk, in layout order"
}

test_a_second_run_changes_nothing() {
  new_case true
  layout
  desk open >/dev/null || fail "first open failed"
  cp "$FAKE_HERDR_STATE" "$C/after-first.json"
  : > "$FAKE_HERDR_CALLS"
  local out
  out=$(desk open) || fail "second open failed"
  assert_contains "$out" "The desk was already open; nothing changed." "a second run did not say it changed nothing"
  cmp -s "$FAKE_HERDR_STATE" "$C/after-first.json" || fail "a second run changed the session"
  assert_no_regex ' (create|run|focus) ' "$FAKE_HERDR_CALLS" "a second run created, ran or focused something"
  assert_no_grep "terminal open" "$FAKE_HERDR_CALLS" "a second run opened another Terminal view"
  pass "desk: a second run changes nothing"
}

test_every_herdr_call_names_the_default_session() {
  new_case true
  layout
  desk open >/dev/null || fail "open failed"
  local bad
  bad=$(grep -v -E '^(--session default |bridge |factory-pane |factory-tab |terminal |_add-)' "$FAKE_HERDR_CALLS" || true)
  [ -z "$bad" ] || fail "a Herdr call did not name the session: $bad"
  : > "$FAKE_HERDR_CALLS"
  HERDR_SESSION=other HERDR_SOCKET_PATH=/live.sock HERDR_PANE_ID=w9:p9 HERDR_TAB_ID=w9:t9 desk open >/dev/null \
    || fail "a run from inside another pane failed"
  bad=$(grep -v -E '^--session default ' "$FAKE_HERDR_CALLS" || true)
  [ -z "$bad" ] || fail "a run from inside another pane reached another session: $bad"
  pass "desk: every Herdr call names the default session"
}

# A restart brings the layout back with plain shells where the plugin panes and
# factory pages ran, and Herdr itself resumes the recorded first mate.
restored_session() {
  cat > "$FAKE_HERDR_STATE" <<'JSON'
{"session": "default", "running": true, "n": 50, "workspaces": [
 {"workspace_id": "w1", "label": "starship", "tabs": [
  {"tab_id": "w1:t1", "label": "1", "panes": [
   {"pane_id": "w1:p2", "tab_id": "w1:t1", "label": "Starship bridge", "cmd": ["-zsh"]},
   {"pane_id": "w1:p1", "tab_id": "w1:t1", "label": null, "cmd": ["-zsh"],
    "agent_session": {"agent": "claude", "kind": "id", "value": "abc"}},
   {"pane_id": "w1:p3", "tab_id": "w1:t1", "label": "Factories", "cmd": ["-zsh"]}]},
  {"tab_id": "w1:t4", "label": "Sample Shop", "panes": [
   {"pane_id": "w1:p4", "tab_id": "w1:t4", "label": null, "cmd": ["-zsh"]},
   {"pane_id": "w1:p5", "tab_id": "w1:t4", "label": null, "cmd": ["-zsh"]}]},
  {"tab_id": "w1:t6", "label": "Recipe Box", "panes": [
   {"pane_id": "w1:p6", "tab_id": "w1:t6", "label": null, "cmd": ["vim notes.md"]}]},
  {"tab_id": "w1:t7", "label": "Notes", "panes": [
   {"pane_id": "w1:p7", "tab_id": "w1:t7", "label": null, "cmd": ["-zsh"]}]}]},
 {"workspace_id": "w2", "label": "a worker", "tabs": [
  {"tab_id": "w2:t1", "label": "1", "panes": [
   {"pane_id": "w2:p1", "tab_id": "w2:t1", "label": null, "cmd": ["-zsh"]}]}]}]}
JSON
}

test_a_restored_session_gets_its_dead_panes_started_in_place() {
  new_case true
  layout
  restored_session
  printf '1 ttys001 herdr\n2 ttys002 herdr --session default\n3 ?? herdr server\n' > "$FAKE_PS"
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "start the Starship bridge again in its pane" "the dead bridge pane was not restarted"
  assert_contains "$out" "start the Factory pane again in its pane" "the dead Factory pane was not restarted"
  assert_contains "$out" "start the Sample Shop page again in its tab" "the dead Sample Shop page was not restarted"
  assert_contains "$out" "note: the Recipe Box tab is showing something else; it was left as it is" \
    "a tab running something else was not reported"
  assert_grep "pane run w1:p2 exec env FM_HOME=$FM_HOME HERDR_BIN_PATH=$FAKE/bin/herdr bash $FAKE/tools/fm-bridge-strip.sh run" \
    "$FAKE_HERDR_CALLS" "the bridge was not restarted inside its own pane"
  assert_grep "pane run w1:p4 exec env FM_HOME=$FM_HOME HERDR_BIN_PATH=$FAKE/bin/herdr bash $FAKE/tools/fm-factory-pane.sh run --factory sample-shop --origin-tab w1:t1" \
    "$FAKE_HERDR_CALLS" "the Sample Shop page was not restarted in the tab's first pane"
  assert_no_grep "pane run w1:p1 " "$FAKE_HERDR_CALLS" "the pane Herdr resumes the first mate in was typed into"
  assert_no_grep "pane run w1:p5 " "$FAKE_HERDR_CALLS" "a second pane of a factory tab was typed into"
  assert_no_grep "pane run w1:p6 " "$FAKE_HERDR_CALLS" "a pane running something else was typed into"
  assert_no_grep "w2" "$FAKE_HERDR_CALLS" "another workspace was touched"
  assert_no_regex ' create ' "$FAKE_HERDR_CALLS" "a restored session had something created"
  assert_equals "--session default pane close w1:p5" "$(grep ' close ' "$FAKE_HERDR_CALLS")" \
    "something besides the factory tab's leftover shell was closed"
  assert_no_grep "terminal open" "$FAKE_HERDR_CALLS" "views were opened although two clients already show the session"
  pass "desk: a restored session gets its dead panes started in place, and nothing else"
}

test_a_session_that_is_not_running_is_started_before_any_view() {
  new_case false
  layout
  local out first_view started
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "  done: start Herdr" "open did not say Herdr was started"
  started=$(grep -n -- '--session default server' "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  first_view=$(grep -n 'terminal open' "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  [ -n "$started" ] || fail "Herdr was not started"
  [ -n "$first_view" ] && [ "$started" -lt "$first_view" ] || fail "a view opened before Herdr was started"
  [ "$(state_query 'len(st["workspaces"])')" = 1 ] || fail "the started session did not get exactly one workspace"
  pass "desk: a session that is not running is started before any view attaches"
}

test_views_count_the_clients_already_showing_the_session() {
  new_case true
  layout
  printf '7 ttys007 /opt/bin/herdr --session default\n8 ttys008 herdr --session other\n9 ?? herdr server\n' > "$FAKE_PS"
  desk open >/dev/null || fail "open failed"
  assert_no_grep "Big Profile" "$FAKE_HERDR_CALLS" "view 1 was opened although a client already shows the session"
  assert_grep "terminal open exec $FAKE/bin/herdr|Small Profile|10" "$FAKE_HERDR_CALLS" "the missing second view was not opened"
  pass "desk: views count only the clients already showing this session"
}

test_a_busy_first_pane_is_never_typed_into() {
  new_case true
  layout
  desk open >/dev/null || fail "first open failed"
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["workspaces"][0]["tabs"][0]["panes"][0]["cmd"] = ["htop"]
json.dump(st, open(sys.argv[1], "w"))
PY
  : > "$FAKE_HERDR_CALLS"
  local out
  out=$(desk open) || fail "open failed"
  assert_no_grep "pane run" "$FAKE_HERDR_CALLS" "a pane running something else was typed into"
  assert_contains "$out" "nothing changed" "a busy first-mate pane was treated as missing"
  pass "desk: a pane running something other than a shell is never typed into"
}

# A restored shell counts as a bare shell while it is still starting, and a
# shell whose owner has typed ahead is still the foreground; only the screen
# tells them apart from a shell waiting at an empty prompt.
set_screens() {  # <pane id>=<screen> ...: give panes of the fake session what they show
  python3 - "$FAKE_HERDR_STATE" "$@" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
screens = dict(arg.split("=", 1) for arg in sys.argv[2:])
for w in st["workspaces"]:
    for t in w["tabs"]:
        for p in t["panes"]:
            if p["pane_id"] in screens:
                p["screen"] = screens[p["pane_id"]]
json.dump(st, open(sys.argv[1], "w"))
PY
}

test_a_pane_with_input_typed_after_its_prompt_is_left_alone() {
  new_case true
  layout
  restored_session
  printf '1 ttys001 herdr\n2 ttys002 herdr --session default\n' > "$FAKE_PS"
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
del st["workspaces"][0]["tabs"][0]["panes"][1]["agent_session"]
json.dump(st, open(sys.argv[1], "w"))
PY
  set_screens "w1:p1=lars@mac ~ % vim -u NONE
" "w1:p2=lars@mac ~ % ls
" "w1:p4=❯ git status
"
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_no_grep "pane run w1:p1 " "$FAKE_HERDR_CALLS" "the first mate was typed after input waiting in its pane"
  assert_no_grep "pane run w1:p2 " "$FAKE_HERDR_CALLS" "the bridge was typed after input waiting in its pane"
  assert_no_grep "pane run w1:p4 " "$FAKE_HERDR_CALLS" "a factory page was typed after input waiting in its pane"
  assert_contains "$out" "note: the first mate's pane has input waiting or no prompt yet; it was left alone" \
    "typed-ahead input in the first mate's pane was not reported"
  assert_contains "$out" "note: the Starship bridge's pane has input waiting or no prompt yet; it was left alone" \
    "typed-ahead input in the bridge's pane was not reported"
  assert_contains "$out" "note: the Sample Shop tab's pane has input waiting or no prompt yet; it was left alone" \
    "typed-ahead input in a factory tab's pane was not reported"
  assert_grep "pane run w1:p3 " "$FAKE_HERDR_CALLS" "a pane at an empty prompt was not restarted"
  pass "desk: a pane with input typed after its prompt is left alone and reported"
}

test_a_shell_still_starting_is_left_alone() {
  new_case true
  layout
  restored_session
  printf '1 ttys001 herdr\n2 ttys002 herdr --session default\n' > "$FAKE_PS"
  set_screens "w1:p3=" "w1:p4=Last login: Sun Nov 15 09:12:01 on ttys004

"
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_no_grep "pane run w1:p3 " "$FAKE_HERDR_CALLS" "a Factory pane whose shell shows nothing yet was typed into"
  assert_no_grep "pane run w1:p4 " "$FAKE_HERDR_CALLS" "a factory page whose shell shows no prompt yet was typed into"
  assert_contains "$out" "note: the Factory pane's pane has input waiting or no prompt yet; it was left alone" \
    "a Factory pane with no prompt yet was not reported"
  assert_contains "$out" "note: the Sample Shop tab's pane has input waiting or no prompt yet; it was left alone" \
    "a factory tab with no prompt yet was not reported"
  assert_grep "pane run w1:p2 " "$FAKE_HERDR_CALLS" "a pane at an empty prompt was not restarted"
  pass "desk: a shell still starting, with no prompt yet, is left alone and reported"
}

test_a_restored_shell_is_given_time_to_reach_its_prompt() {
  new_case true
  layout
  restored_session
  printf '1 ttys001 herdr\n2 ttys002 herdr --session default\n' > "$FAKE_PS"
  # Just after a restart every restored shell runs its startup at once: the
  # bridge's pane shows nothing for its first reads, then its prompt.
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
bridge = st["workspaces"][0]["tabs"][0]["panes"][0]
bridge["screens"] = ["", "", "Last login: Sun Nov 15 09:12:01 on ttys004\n", "", "lars@mac ~ % \n"]
json.dump(st, open(sys.argv[1], "w"))
PY
  : > "$FAKE_PS"
  local out revive view
  # The desk stops waiting as soon as the prompt shows, so a generous limit
  # costs nothing here and keeps a slow, loaded machine from running it out.
  out=$(FM_DESK_WAIT=60 desk open) || fail "open failed: $out"
  assert_contains "$out" "start the Starship bridge again in its pane" "a shell that reached its prompt late was not restarted"
  revive=$(grep -n "pane run w1:p2 " "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  view=$(grep -n "terminal open" "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  [ -n "$revive" ] && [ -n "$view" ] && [ "$revive" -lt "$view" ] \
    || fail "a view opened while a restored shell was still starting"
  assert_not_contains "$out" "the Starship bridge's pane has input waiting" "a shell still starting was given up on"
  pass "desk: a restored shell is given time to reach its prompt, and views wait for it"
}

# A shell whose startup file runs a command directly (a slow tool, a
# sleep) shows that command, not the shell, in its foreground while the screen
# is still empty; it is starting too, not busy.
test_a_restored_shell_running_a_startup_command_is_waited_for() {
  new_case true
  layout
  restored_session
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
main, shop = st["workspaces"][0]["tabs"][0], st["workspaces"][0]["tabs"][1]
del main["panes"][1]["agent_session"]
for pane in main["panes"] + shop["panes"][:1]:
    pane["startup"] = {"cmd": "sleep 6", "reads": 3}
json.dump(st, open(sys.argv[1], "w"))
PY
  : > "$FAKE_PS"
  local out pane revive view
  out=$(FM_DESK_WAIT=60 desk open) || fail "open failed: $out"
  assert_contains "$out" "start the first mate (firstmate claude-opus)" "a first mate pane running its startup was given up on"
  assert_contains "$out" "start the Starship bridge again in its pane" "a bridge pane running its startup was given up on"
  assert_contains "$out" "start the Factory pane again in its pane" "a Factory pane running its startup was given up on"
  assert_contains "$out" "start the Sample Shop page again in its tab" "a factory page running its startup was given up on"
  assert_not_contains "$out" "has input waiting or no prompt yet" "a pane that finished its startup was reported as left alone"
  view=$(grep -n "terminal open" "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  for pane in w1:p1 w1:p2 w1:p3 w1:p4; do
    revive=$(grep -n "pane run $pane " "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
    [ -n "$revive" ] && [ -n "$view" ] && [ "$revive" -lt "$view" ] \
      || fail "a view opened before $pane finished its startup and was started"
  done
  pass "desk: a restored shell running a startup command is waited for, and views wait for it"
}

# open-tab splits a live copy of each running worker beside a factory's page,
# and Herdr brings those copies back as plain shells after a restart.
test_a_restored_factory_tab_gets_its_worker_copies_back() {
  new_case true
  layout
  restored_session
  printf '1 ttys001 herdr\n2 ttys002 herdr --session default\n' > "$FAKE_PS"
  printf 'sample-shop=shop-search\n' > "$FAKE_FACTORY_JOBS"
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
shop = st["workspaces"][0]["tabs"][1]
shop["panes"] += [{"pane_id": "w1:p8", "tab_id": "w1:t4", "label": None, "cmd": ["-zsh"]},
                  {"pane_id": "w1:p9", "tab_id": "w1:t4", "label": None, "cmd": ["-zsh"], "screen": "lars@mac ~ % ls\n"}]
json.dump(st, open(sys.argv[1], "w"))
PY
  local out page closed workers
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "start the Sample Shop page again in its tab" "the dead Sample Shop page was not restarted"
  assert_grep "pane close w1:p5" "$FAKE_HERDR_CALLS" "a leftover idle shell beside the page was not closed"
  assert_grep "pane close w1:p8" "$FAKE_HERDR_CALLS" "a second leftover idle shell beside the page was not closed"
  assert_no_grep "pane close w1:p9" "$FAKE_HERDR_CALLS" "a leftover shell holding typed-ahead input was closed"
  assert_contains "$out" "note: a leftover pane in the Sample Shop tab is not a shell waiting at an empty prompt; it was left open" \
    "a leftover shell holding typed-ahead input was not reported"
  page=$(grep -n "pane run w1:p4 " "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  closed=$(grep -n "pane close w1:p5" "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  workers=$(grep -n "factory-workers sample-shop page=w1:p4" "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  [ -n "$page" ] && [ -n "$closed" ] && [ -n "$workers" ] && [ "$page" -lt "$closed" ] && [ "$closed" -lt "$workers" ] \
    || fail "the page, the leftover shells and the worker copies were not handled in that order"
  assert_equals "page|-zsh|bash x/fm-factory-pane.sh follow shop-search" \
    "$(state_query '"|".join("page" if "fm-factory-pane.sh run" in p["cmd"][0] else p["cmd"][0] for p in st["workspaces"][0]["tabs"][1]["panes"])')" \
    "the Sample Shop tab is not its page, the kept shell and one worker copy"
  assert_equals "--session default pane close w1:p5
--session default pane close w1:p8" "$(grep ' close ' "$FAKE_HERDR_CALLS")" "a pane outside the restarted factory tab was closed"
  : > "$FAKE_HERDR_CALLS"
  out=$(desk open) || fail "second open failed: $out"
  assert_contains "$out" "The desk was already open; nothing changed." "a second run after the restart changed something"
  assert_no_grep "factory-workers" "$FAKE_HERDR_CALLS" "worker copies were added again to a tab whose page runs"
  pass "desk: a restored factory tab gets its leftover idle shells closed and its worker copies back"
}

# Only the panes the desk would type into or close are waited for.
test_a_pane_the_desk_would_not_touch_never_makes_it_wait() {
  new_case true
  layout
  desk open >/dev/null || fail "first open failed"
  python3 - "$FAKE_HERDR_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
tabs = st["workspaces"][0]["tabs"]
for tab, pid in ((tabs[0], "x:p1"), (tabs[1], "x:p2")):
    tab["panes"].append({"pane_id": pid, "tab_id": tab["tab_id"], "label": None, "cmd": ["-zsh"],
                         "screen": "lars@mac ~ % ls\n"})
json.dump(st, open(sys.argv[1], "w"))
PY
  : > "$FAKE_HERDR_CALLS"
  local out
  out=$(FM_DESK_WAIT=20 desk open) || fail "open failed: $out"
  # Waiting reads the desk again every second; a run that does not wait reads it once.
  assert_equals "1" "$(grep -c 'session list' "$FAKE_HERDR_CALLS")" \
    "the desk waited on shells it would neither type into nor close"
  assert_contains "$out" "The desk was already open; nothing changed." "a shell the desk does not touch changed the run"
  assert_no_regex ' (run|close) ' "$FAKE_HERDR_CALLS" "a shell holding typed-ahead input was typed into or closed"
  pass "desk: a shell the desk would not type into or close never makes it wait"
}

test_the_sidebar_setting_changes_only_its_own_line() {
  new_case true
  layout
  desk open >/dev/null || fail "open failed"
  assert_equals '[ui]
sidebar_start_collapsed = true
window_title = "desk"

[theme]
name = "tokyo-night"' "$(cat "$HERDR_CONFIG_PATH")" "the sidebar line was not added under [ui] alone"
  sed -i.bak 's/^sidebar = collapsed$/sidebar = open/' "$FM_HOME/config/desk-layout"
  desk open >/dev/null || fail "second open failed"
  assert_grep "sidebar_start_collapsed = false" "$HERDR_CONFIG_PATH" "an existing sidebar line was not changed in place"
  [ "$(grep -c sidebar_start_collapsed "$HERDR_CONFIG_PATH")" = 1 ] || fail "the sidebar line was duplicated"
  printf 'onboarding = false\n' > "$HERDR_CONFIG_PATH"
  sed -i.bak '/^sidebar = /d' "$FM_HOME/config/desk-layout"
  desk open >/dev/null || fail "third open failed"
  assert_equals 'onboarding = false' "$(cat "$HERDR_CONFIG_PATH")" "Herdr's config changed without a sidebar setting"
  sed -i.bak '1i\
sidebar = collapsed
' "$FM_HOME/config/desk-layout"
  desk open >/dev/null || fail "fourth open failed"
  assert_equals 'onboarding = false

[ui]
sidebar_start_collapsed = true' "$(cat "$HERDR_CONFIG_PATH")" "a config without [ui] did not get one"
  pass "desk: the sidebar setting changes only its own line of Herdr's config"
}

test_a_bad_or_missing_layout_stops_with_the_reason() {
  new_case true
  local out status
  out=$(desk open 2>&1); status=$?
  expect_code 2 "$status" "a missing layout"
  assert_contains "$out" "starship layout >" "a missing layout did not say how to write one"
  printf 'workspace = starship\nview = Big | huge\n' > "$FM_HOME/config/desk-layout"
  out=$(desk open 2>&1); status=$?
  expect_code 2 "$status" "a bad view size"
  assert_contains "$out" "line 2: a view's font size is a whole number" "a bad line was not named"
  printf 'workspace = starship\ntab = Sample Shop | page sample-shop\n' > "$FM_HOME/config/desk-layout"
  out=$(desk open 2>&1); status=$?
  expect_code 2 "$status" "a bad tab"
  printf 'workspace = starship\nworkspace = other\n' > "$FM_HOME/config/desk-layout"
  out=$(desk open 2>&1); status=$?
  expect_code 2 "$status" "a setting given twice"
  assert_contains "$out" "workspace is set twice" "a repeated setting was not named"
  [ ! -s "$FAKE_HERDR_CALLS" ] || fail "a bad layout still reached Herdr"
  pass "desk: a bad or missing layout stops before Herdr with the reason"
}

test_layout_reads_the_running_desk_back() {
  new_case true
  layout
  desk open >/dev/null || fail "open failed"
  mkdir -p "$FM_HOME/state/factory/tabs"
  local shop recipes
  shop=$(state_query 'next(t["tab_id"] for t in st["workspaces"][0]["tabs"] if t["label"] == "Sample Shop")')
  recipes=$(state_query 'next(t["tab_id"] for t in st["workspaces"][0]["tabs"] if t["label"] == "Recipe Box")')
  # The factory's own tab records name each tab and the session it lives in;
  # a record from another session names the same tab id in vain.
  printf '%s\n/fake/default.sock\n' "$shop" > "$FM_HOME/state/factory/tabs/sample-shop"
  printf '%s\n/fake/default.sock\n' "$recipes" > "$FM_HOME/state/factory/tabs/recipe-box"
  printf '%s\n/fake/other.sock\n' "$shop" > "$FM_HOME/state/factory/tabs/garden-journal"
  printf '/dev/ttys100\tBig Profile\t13.0\n/dev/ttys101\tSmall Profile\t10\n/dev/ttys555\tBasic\t11\n' > "$FAKE_TERMINAL_TABS"
  local out
  out=$(desk layout) || fail "layout failed"
  assert_contains "$out" "workspace = starship
sidebar = collapsed
firstmate = firstmate claude-opus
tab = Sample Shop | factory sample-shop
tab = Recipe Box | factory recipe-box
tab = Notes
view = Big Profile | 13
view = Small Profile | 10" "layout did not read the desk back"
  assert_not_contains "$out" "Basic" "layout listed a Terminal tab that shows no Herdr client"
  printf '%s\n' "$out" > "$FM_HOME/config/desk-layout"
  : > "$FAKE_HERDR_CALLS"
  out=$(desk open) || fail "open on the read-back layout failed"
  assert_contains "$out" "nothing changed" "the read-back layout does not describe the running desk"
  pass "desk: layout reads the running desk back as a layout that opens it unchanged"
}

# open-tab names a factory's tab after the registry, which need not match the
# layout's label; the tab open-tab recorded is that factory's tab all the same.
test_a_factory_tab_is_found_by_its_record_whatever_its_label() {
  new_case true
  printf 'tab = Shop | factory sample-shop\n' > "$FM_HOME/config/desk-layout"
  local out
  out=$(desk open) || fail "first open failed: $out"
  assert_not_contains "$out" "has not shown up yet" "the opened factory tab was not recognised"
  assert_equals "1|Sample Shop" "$(state_query '"|".join(t["label"] for t in st["workspaces"][0]["tabs"])')" \
    "the factory tab was not opened once"
  : > "$FAKE_HERDR_CALLS"
  out=$(desk open) || fail "second open failed: $out"
  assert_contains "$out" "The desk was already open; nothing changed." "a factory tab labelled otherwise was opened again"
  assert_no_grep "factory-tab" "$FAKE_HERDR_CALLS" "open-tab ran again for a tab that is open"
  pass "desk: a factory tab is found by open-tab's record, whatever the layout labels it"
}

test_a_workspace_the_desk_creates_gets_its_main_tab_named() {
  new_case true
  layout "main = Bridge"
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_grep "tab rename w:t2 Bridge" "$FAKE_HERDR_CALLS" "the new workspace's first tab was not named after main"
  assert_equals "Bridge|Sample Shop|Recipe Box|Notes" "$(state_query '"|".join(t["label"] for t in st["workspaces"][0]["tabs"])')" \
    "the main tab is not the first tab, named after main"
  assert_equals "firstmate claude-opus|Starship bridge|Factories" \
    "$(state_query '"|".join(p.get("label") or p["cmd"][0] for p in st["workspaces"][0]["tabs"][0]["panes"])')" \
    "the named main tab is not the first mate, the bridge and the Factory pane"
  : > "$FAKE_HERDR_CALLS"
  out=$(desk open) || fail "second open failed: $out"
  assert_contains "$out" "The desk was already open; nothing changed." "a second run with main set changed something"
  pass "desk: a workspace the desk creates gets its first tab named after main, and a second run changes nothing"
}

test_an_existing_tab_is_never_renamed_to_main() {
  new_case true
  layout
  desk open >/dev/null || fail "first open failed"
  printf 'main = Bridge\n' >> "$FM_HOME/config/desk-layout"
  : > "$FAKE_HERDR_CALLS"
  local out
  out=$(desk open) || fail "open with main set failed: $out"
  assert_contains "$out" "The desk was already open; nothing changed." "main set without a tab carrying it did not fall back to the first tab"
  assert_no_grep "rename" "$FAKE_HERDR_CALLS" "an existing tab was renamed"
  assert_equals "1" "$(state_query 'st["workspaces"][0]["tabs"][0]["label"]')" "the existing first tab lost its label"
  pass "desk: main falls back to the first tab and never renames an existing one"
}

test_a_renamed_main_tab_that_is_not_first_is_found_by_its_label() {
  new_case true
  cat > "$FAKE_HERDR_STATE" <<'JSON'
{"session": "default", "running": true, "n": 50, "workspaces": [
 {"workspace_id": "w1", "label": "starship", "tabs": [
  {"tab_id": "w1:t1", "label": "Scratch", "panes": [
   {"pane_id": "w1:p1", "tab_id": "w1:t1", "label": null, "cmd": ["-zsh"]}]},
  {"tab_id": "w1:t2", "label": "Bridge", "panes": [
   {"pane_id": "w1:p2", "tab_id": "w1:t2", "label": "Starship bridge", "cmd": ["bash ../../bin/fm-bridge-strip.sh run"]},
   {"pane_id": "w1:p3", "tab_id": "w1:t2", "label": null, "cmd": ["firstmate claude-opus"]},
   {"pane_id": "w1:p4", "tab_id": "w1:t2", "label": "Factories", "cmd": ["bash ../../bin/fm-factory-pane.sh run"]}]}]}]}
JSON
  printf 'main = Bridge\nfirstmate = firstmate claude-opus\ntab = Scratch\n' > "$FM_HOME/config/desk-layout"
  local out
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "The desk was already open; nothing changed." "a renamed main tab that is not first was not found"
  assert_no_regex ' (run|rename|create) ' "$FAKE_HERDR_CALLS" "the desk acted on a desk that is already open"
  out=$(desk layout) || fail "layout failed"
  assert_contains "$out" "main = Bridge" "layout did not name the main tab"
  assert_contains "$out" "tab = Scratch" "layout did not list the first tab beside the main tab"
  assert_not_contains "$out" "tab = Bridge" "layout listed the main tab as another tab"
  printf '%s\n' "$out" > "$FM_HOME/config/desk-layout"
  : > "$FAKE_HERDR_CALLS"
  out=$(desk open) || fail "open on the read-back layout failed: $out"
  assert_contains "$out" "nothing changed" "the read-back layout with main does not describe the running desk"
  pass "desk: a renamed main tab that is not first is found by its label and read back by layout"
}

test_install_command_links_starship_and_keeps_a_foreign_one() {
  new_case true
  local dir="$C/localbin" out status py
  py=$(command -v python3)
  # Another `starship` on PATH, such as the starship.rs shell prompt, is never
  # hidden behind the link nor left to hide it.
  mkdir -p "$C/prompt"; printf '#!/bin/sh\necho prompt\n' > "$C/prompt/starship"; chmod +x "$C/prompt/starship"
  out=$(PATH="$C/prompt:/usr/bin:/bin" FM_DESK_COMMAND_DIR="$dir" "$py" "$DESK" install-command 2>&1); status=$?
  expect_code 1 "$status" "another starship on PATH"
  assert_contains "$out" "is already on PATH ($C/prompt/starship)" "the starship on PATH was not named"
  [ ! -e "$dir/starship" ] && [ ! -L "$dir/starship" ] || fail "install-command linked over another starship on PATH"
  out=$(PATH="/usr/bin:/bin" FM_DESK_COMMAND_DIR="$dir" "$py" "$DESK" install-command) || fail "install-command failed: $out"
  [ -L "$dir/starship" ] || fail "install-command made no link"
  assert_equals "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DESK")" \
    "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dir/starship")" "the link does not point at the desk"
  out=$(PATH="$dir:/usr/bin:/bin" FM_DESK_COMMAND_DIR="$dir" "$py" "$DESK" install-command) \
    || fail "a second install-command failed"
  assert_contains "$out" "already opens the desk" "a second install-command did not see its own link"
  rm "$dir/starship"; printf 'other\n' > "$dir/starship"
  out=$(PATH="/usr/bin:/bin" FM_DESK_COMMAND_DIR="$dir" "$py" "$DESK" install-command 2>&1); status=$?
  expect_code 1 "$status" "a foreign starship"
  assert_equals "other" "$(cat "$dir/starship")" "a foreign starship command was replaced"
  pass "desk: install-command links starship and never replaces or shadows another one"
}

fm_test_run \
  test_an_empty_session_gets_the_whole_desk_in_order \
  test_a_second_run_changes_nothing \
  test_every_herdr_call_names_the_default_session \
  test_a_restored_session_gets_its_dead_panes_started_in_place \
  test_a_session_that_is_not_running_is_started_before_any_view \
  test_views_count_the_clients_already_showing_the_session \
  test_a_busy_first_pane_is_never_typed_into \
  test_a_pane_with_input_typed_after_its_prompt_is_left_alone \
  test_a_shell_still_starting_is_left_alone \
  test_a_restored_shell_is_given_time_to_reach_its_prompt \
  test_a_restored_shell_running_a_startup_command_is_waited_for \
  test_a_restored_factory_tab_gets_its_worker_copies_back \
  test_a_pane_the_desk_would_not_touch_never_makes_it_wait \
  test_the_sidebar_setting_changes_only_its_own_line \
  test_a_bad_or_missing_layout_stops_with_the_reason \
  test_layout_reads_the_running_desk_back \
  test_a_factory_tab_is_found_by_its_record_whatever_its_label \
  test_a_workspace_the_desk_creates_gets_its_main_tab_named \
  test_an_existing_tab_is_never_renamed_to_main \
  test_a_renamed_main_tab_that_is_not_first_is_found_by_its_label \
  test_install_command_links_starship_and_keeps_a_foreign_one

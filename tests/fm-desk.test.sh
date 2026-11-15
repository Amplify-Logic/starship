#!/usr/bin/env bash
# The desk command: bin/fm-desk.py (`starship`).
#
# A fake herdr keeps a whole session (workspaces, tabs, panes and what each
# pane runs) in a JSON file and logs every call, so the desk's reading, its
# missing-only plan and its idempotence are checked against a session that
# changes as the desk acts. Fake bridge, Factory pane and factory-tab scripts
# add their panes to that session the way the real ones do; a fake process
# list stands in for the Herdr clients, and a fake osascript for Terminal.
# No real Herdr, Terminal or LaunchAgent is touched.
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
    out({"result": {"process_info": {"foreground_processes": [{"cmdline": c} for c in p["cmd"]]}}})
elif cmd == "pane run":
    p = find_pane(args[2])
    p["cmd"] = [args[3]]; save(); out({"result": {}})
elif args[0] == "_add-pane":          # fake scripts: <tab> <label> <cmd>
    tab = next(t for t in all_tabs() if t["tab_id"] == args[1])
    new_pane(tab, args[2], args[3]); save()
elif args[0] == "_add-tab":           # fake scripts: <workspace> <label> <cmd>
    tab = {"tab_id": new_id("w:t"), "label": args[2], "panes": []}
    tabs_of(args[1]).append(tab); new_pane(tab, None, args[3]); save()
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
with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
    log.write("factory-tab %s origin=%s\n" % (fid, os.environ.get("HERDR_TAB_ID", "")))
subprocess.run([os.environ["HERDR_BIN_PATH"], "_add-tab", os.environ["HERDR_WORKSPACE_ID"], names[fid],
                "bash x/fm-factory-pane.sh run --factory %s" % fid], check=True)
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
new_case() {  # <session> <running:true|false>
  CASE=$((CASE + 1))
  C="$TMP_ROOT/case$CASE"
  mkdir -p "$C/home/config" "$C/home/state"
  export FM_HOME="$C/home" FAKE_HERDR_STATE="$C/state.json" FAKE_HERDR_CALLS="$C/calls" \
    FAKE_PS="$C/ps" FAKE_TERMINAL_TABS="$C/terminal" FAKE_FACTORY_NAMES="$C/factories" \
    HERDR_BIN_PATH="$FAKE/bin/herdr" HERDR_CONFIG_PATH="$C/herdr-config.toml" \
    FM_DESK_BIN="$FAKE/tools" FM_DESK_PS="cat $C/ps" FM_DESK_OSASCRIPT="$FAKE/bin/osascript" \
    FM_DESK_LAUNCH_AGENTS="$C/LaunchAgents" FM_DESK_LAUNCHCTL="true" FM_DESK_WAIT=3
  unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION
  printf '{"session": "%s", "running": %s, "workspaces": [], "n": 0}\n' "$1" "$2" > "$FAKE_HERDR_STATE"
  : > "$FAKE_HERDR_CALLS"; : > "$FAKE_PS"; : > "$FAKE_TERMINAL_TABS"
  printf 'sample-shop=Sample Shop\nrecipe-box=Recipe Box\ngarden-journal=Garden Journal\n' > "$FAKE_FACTORY_NAMES"
  printf '[ui]\nwindow_title = "desk"\n\n[theme]\nname = "tokyo-night"\n' > "$HERDR_CONFIG_PATH"
}

layout() {  # <session> [extra lines]
  {
    printf 'session = %s\nworkspace = starship\nsidebar = collapsed\nfirstmate = firstmate claude-opus\n' "$1"
    printf 'tab = Sample Shop | factory sample-shop\ntab = Recipe Box | factory recipe-box\ntab = Notes\n'
    printf 'view = Big Profile | 13\nview = Small Profile | 10\n'
    [ -z "${2:-}" ] || printf '%s\n' "$2"
  } > "$FM_HOME/config/desk-layout"
}

desk() { python3 "$DESK" "$@"; }

# state_query <python expression over st>: read the fake session.
state_query() {
  python3 -c "import json,sys; st=json.load(open(sys.argv[1])); print($1)" "$FAKE_HERDR_STATE"
}

test_an_empty_session_gets_the_whole_desk_in_order() {
  new_case lab true
  layout lab
  local plan out
  plan=$(desk plan) || fail "plan failed"
  assert_contains "$plan" "  - make Herdr start with the sidebar collapsed
  - create the workspace starship
  - start the first mate (firstmate claude-opus)
  - show the Starship bridge
  - show the Factory pane
  - open the Sample Shop tab
  - open the Recipe Box tab
  - open the Notes tab
  - open view 1 in Terminal (profile Big Profile, size 13)
  - open view 2 in Terminal (profile Small Profile, size 10)" "plan did not list the whole desk in order"
  [ "$(state_query 'len(st["workspaces"])')" = 0 ] || fail "plan changed the session"
  out=$(desk open) || fail "open failed: $out"
  assert_contains "$out" "10 thing(s) started" "open did not report what it started"
  assert_equals "1|Sample Shop|Recipe Box|Notes" "$(state_query '"|".join(t["label"] for t in st["workspaces"][0]["tabs"])')" \
    "open did not build the tabs in layout order"
  assert_equals "firstmate claude-opus|Starship bridge|Factories" \
    "$(state_query '"|".join(p.get("label") or p["cmd"][0] for p in st["workspaces"][0]["tabs"][0]["panes"])')" \
    "the first tab is not the first mate, the bridge and the Factory pane"
  assert_grep "bridge open --pane w:p3" "$FAKE_HERDR_CALLS" "the bridge was not put above the first mate's pane"
  assert_grep "factory-pane open --pane w:p3" "$FAKE_HERDR_CALLS" "the Factory pane was not put beside the first mate"
  assert_grep "factory-tab sample-shop origin=w:t2" "$FAKE_HERDR_CALLS" "a factory tab did not open through open-tab from the first tab"
  assert_grep "terminal open exec $FAKE/bin/herdr --session lab|Big Profile|13" "$FAKE_HERDR_CALLS" "view 1 did not open with its profile and size"
  assert_grep "terminal open exec $FAKE/bin/herdr --session lab|Small Profile|10" "$FAKE_HERDR_CALLS" "view 2 did not open with its profile and size"
  assert_grep "tab focus w:t2" "$FAKE_HERDR_CALLS" "focus did not go back to the first tab"
  pass "desk: an empty session gets the whole desk, in layout order"
}

test_a_second_run_changes_nothing() {
  new_case lab true
  layout lab
  desk open >/dev/null || fail "first open failed"
  cp "$FAKE_HERDR_STATE" "$C/after-first.json"
  : > "$FAKE_HERDR_CALLS"
  local out
  out=$(desk open) || fail "second open failed"
  assert_contains "$out" "The desk was already open; nothing changed." "a second run did not say it changed nothing"
  cmp -s "$FAKE_HERDR_STATE" "$C/after-first.json" || fail "a second run changed the session"
  assert_no_regex ' (create|run|focus) ' "$FAKE_HERDR_CALLS" "a second run created, ran or focused something"
  assert_no_grep "terminal open" "$FAKE_HERDR_CALLS" "a second run opened another Terminal view"
  out=$(desk plan)
  assert_contains "$out" "would change nothing" "plan after the desk is open is not empty"
  pass "desk: a second run changes nothing"
}

test_every_herdr_call_names_the_layouts_session() {
  new_case lab true
  layout lab
  desk open >/dev/null || fail "open failed"
  local bad
  bad=$(grep -v -E '^(--session lab |bridge |factory-pane |factory-tab |terminal |_add-)' "$FAKE_HERDR_CALLS" || true)
  [ -z "$bad" ] || fail "a Herdr call did not name the session: $bad"
  HERDR_SOCKET_PATH=/live.sock HERDR_PANE_ID=w9:p9 HERDR_TAB_ID=w9:t9 desk plan >/dev/null \
    || fail "a run from inside another pane failed"
  pass "desk: every Herdr call names the layout's session"
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
  new_case default true
  layout default
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
  assert_no_regex ' (create|close) ' "$FAKE_HERDR_CALLS" "a restored session had something created or closed"
  assert_no_grep "terminal open" "$FAKE_HERDR_CALLS" "views were opened although two clients already show the session"
  pass "desk: a restored session gets its dead panes started in place, and nothing else"
}

test_a_session_that_is_not_running_is_started_before_any_view() {
  new_case lab false
  layout lab
  local plan out first_view started
  plan=$(desk plan)
  assert_contains "$plan" "  - start Herdr" "plan did not say Herdr would be started"
  assert_contains "$plan" "note: the rest of the desk is filled in once Herdr is running" "plan did not say the rest follows"
  out=$(desk open) || fail "open failed: $out"
  started=$(grep -n -- '--session lab server' "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  first_view=$(grep -n 'terminal open' "$FAKE_HERDR_CALLS" | head -1 | cut -d: -f1)
  [ -n "$started" ] || fail "Herdr was not started"
  [ -n "$first_view" ] && [ "$started" -lt "$first_view" ] || fail "a view opened before Herdr was started"
  [ "$(state_query 'len(st["workspaces"])')" = 1 ] || fail "the started session did not get exactly one workspace"
  pass "desk: a session that is not running is started before any view attaches"
}

test_views_count_the_clients_already_showing_the_session() {
  new_case lab true
  layout lab
  printf '7 ttys007 /opt/bin/herdr --session lab\n8 ttys008 herdr --session other\n9 ttys009 herdr\n' > "$FAKE_PS"
  desk open >/dev/null || fail "open failed"
  assert_no_grep "Big Profile" "$FAKE_HERDR_CALLS" "view 1 was opened although a client already shows the session"
  assert_grep "terminal open exec $FAKE/bin/herdr --session lab|Small Profile|10" "$FAKE_HERDR_CALLS" "the missing second view was not opened"
  pass "desk: views count only the clients already showing this session"
}

test_a_busy_first_pane_is_never_typed_into() {
  new_case lab true
  layout lab
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

test_the_sidebar_setting_changes_only_its_own_line() {
  new_case lab true
  layout lab
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
  new_case lab true
  local out status
  out=$(desk open 2>&1); status=$?
  expect_code 2 "$status" "a missing layout"
  assert_contains "$out" "starship layout >" "a missing layout did not say how to write one"
  printf 'session = lab\nview = Big | huge\n' > "$FM_HOME/config/desk-layout"
  out=$(desk plan 2>&1); status=$?
  expect_code 2 "$status" "a bad view size"
  assert_contains "$out" "line 2: a view's font size is a whole number" "a bad line was not named"
  printf 'session = lab\ntab = Sample Shop | page sample-shop\n' > "$FM_HOME/config/desk-layout"
  out=$(desk plan 2>&1); status=$?
  expect_code 2 "$status" "a bad tab"
  printf 'session = lab\nsession = other\n' > "$FM_HOME/config/desk-layout"
  out=$(desk plan 2>&1); status=$?
  expect_code 2 "$status" "a setting given twice"
  assert_contains "$out" "session is set twice" "a repeated setting was not named"
  [ ! -s "$FAKE_HERDR_CALLS" ] || fail "a bad layout still reached Herdr"
  pass "desk: a bad or missing layout stops before Herdr with the reason"
}

test_layout_reads_the_running_desk_back() {
  new_case lab true
  layout lab
  desk open >/dev/null || fail "open failed"
  mkdir -p "$FM_HOME/state/factory/tabs"
  local shop recipes
  shop=$(state_query 'next(t["tab_id"] for t in st["workspaces"][0]["tabs"] if t["label"] == "Sample Shop")')
  recipes=$(state_query 'next(t["tab_id"] for t in st["workspaces"][0]["tabs"] if t["label"] == "Recipe Box")')
  # The factory's own tab records name each tab and the session it lives in;
  # a record from another session names the same tab id in vain.
  printf '%s\n/fake/lab.sock\n' "$shop" > "$FM_HOME/state/factory/tabs/sample-shop"
  printf '%s\n/fake/lab.sock\n' "$recipes" > "$FM_HOME/state/factory/tabs/recipe-box"
  printf '%s\n/fake/other.sock\n' "$shop" > "$FM_HOME/state/factory/tabs/garden-journal"
  printf '/dev/ttys100\tBig Profile\t13.0\n/dev/ttys101\tSmall Profile\t10\n/dev/ttys555\tBasic\t11\n' > "$FAKE_TERMINAL_TABS"
  local out
  out=$(desk layout) || fail "layout failed"
  assert_contains "$out" "session = lab
workspace = starship
sidebar = collapsed
firstmate = firstmate claude-opus
bridge = on
factory = on
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

test_login_start_is_off_until_turned_on() {
  new_case lab true
  layout lab
  local out plist="$C/LaunchAgents/com.firstmate.starship-desk.plist"
  out=$(desk login status)
  assert_contains "$out" "does not open at login" "login start was on before it was turned on"
  desk login on >/dev/null || fail "login on failed"
  assert_present "$plist" "login on wrote no LaunchAgent"
  python3 - "$plist" "$DESK" "$FM_HOME" <<'PY' || fail "the LaunchAgent does not run the desk for this home"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "com.firstmate.starship-desk"
assert p["ProgramArguments"][1:] == [sys.argv[2], "open"], p["ProgramArguments"]
assert p["RunAtLoad"] is True
assert p["EnvironmentVariables"]["FM_HOME"] == sys.argv[3]
PY
  out=$(desk login status)
  assert_contains "$out" "opens at login" "status did not see the LaunchAgent"
  desk login off >/dev/null || fail "login off failed"
  assert_absent "$plist" "login off left the LaunchAgent"
  pass "desk: login start is off until turned on, and off removes it"
}

test_install_command_links_starship_and_keeps_a_foreign_one() {
  new_case lab true
  local dir="$C/localbin" out status
  out=$(FM_DESK_COMMAND_DIR="$dir" desk install-command) || fail "install-command failed: $out"
  [ -L "$dir/starship" ] || fail "install-command made no link"
  assert_equals "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DESK")" \
    "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dir/starship")" "the link does not point at the desk"
  out=$(FM_DESK_COMMAND_DIR="$dir" desk install-command) || fail "a second install-command failed"
  assert_contains "$out" "already opens the desk" "a second install-command did not see its own link"
  rm "$dir/starship"; printf 'other\n' > "$dir/starship"
  out=$(FM_DESK_COMMAND_DIR="$dir" desk install-command 2>&1); status=$?
  expect_code 1 "$status" "a foreign starship"
  assert_equals "other" "$(cat "$dir/starship")" "a foreign starship command was replaced"
  pass "desk: install-command links starship and never replaces another one"
}

fm_test_run \
  test_an_empty_session_gets_the_whole_desk_in_order \
  test_a_second_run_changes_nothing \
  test_every_herdr_call_names_the_layouts_session \
  test_a_restored_session_gets_its_dead_panes_started_in_place \
  test_a_session_that_is_not_running_is_started_before_any_view \
  test_views_count_the_clients_already_showing_the_session \
  test_a_busy_first_pane_is_never_typed_into \
  test_the_sidebar_setting_changes_only_its_own_line \
  test_a_bad_or_missing_layout_stops_with_the_reason \
  test_layout_reads_the_running_desk_back \
  test_login_start_is_off_until_turned_on \
  test_install_command_links_starship_and_keeps_a_foreign_one

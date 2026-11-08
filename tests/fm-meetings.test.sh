#!/usr/bin/env bash
# Behavior tests for bin/fm-meetings.sh, the meeting intake, and its two
# sources in bin/fm_meeting_sources.py (docs/meetings.md).
#
# Every case drives the real entry point against a scratch home. The Anarlog
# source is exercised through a fake `anarlog` command that serves invented
# meetings from fixture files and logs every call, and the call-recorder source
# through an invented data/calls/archive, so no case reads a real meeting,
# records audio, or opens an app. The intake model, the inbox and the desk
# speaker are fakes that record what they were handed. Time is pinned through
# FM_MEETINGS_NOW.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBJECT="$ROOT/bin/fm-meetings.sh"
TMP_ROOT=$(fm_test_tmproot fm-meetings)
FAKES="$TMP_ROOT/fakes"
NOW=1793000000
mkdir -p "$FAKES"

# The fake Anarlog CLI. Fixtures live in $FAKE_ANARLOG_DIR:
#   list.json                 the `meetings list` data array
#   meetings/<id>.json        one meeting as `meetings export --format json` returns it,
#                             plus optional processing_status and recording_import
#   meetings/<id>.md          the Markdown export
#   jobs/<job>.json           an import job's status (absent: still transcribing)
#   import-fails              when present, every import is refused
#   list-fails                when present, every list call fails
#   export-fails              when present, every export call fails
#   doctor-fails              when present, every doctor call fails
# Every call is appended to calls.log; imports also to imports.jsonl.
cat > "$FAKES/anarlog" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, sys
base = os.environ["FAKE_ANARLOG_DIR"]
args = sys.argv[1:]
with open(os.path.join(base, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
as_json = "--json" in args
args = [a for a in args if a != "--json"]
def out(command, data):
    print(json.dumps({"schema_version": "1", "command": command, "data": data}))
def fail(message):
    print(json.dumps({"error": {"code": "invalid", "exit_code": 1, "message": message}, "schema_version": "1"}, indent=2))
    sys.exit(1)
def meeting(mid):
    path = os.path.join(base, "meetings", mid + ".json")
    if not os.path.exists(path):
        fail("meeting not found")
    with open(path) as handle:
        return json.load(handle)
if args[0] == "doctor":
    if os.path.exists(os.path.join(base, "doctor-fails")):
        fail("doctor could not read the database")
    out("doctor", {"ready": True, "database": {"path": os.path.join(base, "app.db")}})
    sys.exit(0)
assert args[0] == "meetings" and args[1:3] == ["--source", "local"], args
verb, rest = args[3], args[4:]
if verb == "list":
    if os.path.exists(os.path.join(base, "list-fails")):
        fail("database is locked")
    with open(os.path.join(base, "list.json")) as handle:
        items = json.load(handle)
    if "--query" in rest:
        query = rest[rest.index("--query") + 1].lower()
        items = [i for i in items if query in i["title"].lower()]
    out("meetings.list", items)
elif verb == "get":
    data = meeting(rest[0])
    for key in ("transcripts", "attachments", "capture_pending", "speakers"):
        data.pop(key, None)
    data.setdefault("processing_status", None)
    data.setdefault("recording_import", None)
    out("meetings.get", data)
elif verb == "export":
    if os.path.exists(os.path.join(base, "export-fails")):
        fail("database is locked")
    data = meeting(rest[0])
    if rest[rest.index("--format") + 1] == "markdown":
        with open(os.path.join(base, "meetings", rest[0] + ".md")) as handle:
            sys.stdout.write(handle.read())
    else:
        data.pop("processing_status", None)
        data.pop("recording_import", None)
        out("meetings.export", data)
elif verb == "import":
    if os.path.exists(os.path.join(base, "import-fails")):
        fail("Open the updated Anarlog desktop app before importing recordings")
    key = rest[rest.index("--request-key") + 1]
    tag = hashlib.sha1(key.encode()).hexdigest()[:8]
    record = {"file": rest[0], "title": rest[rest.index("--title") + 1], "request_key": key}
    with open(os.path.join(base, "imports.jsonl"), "a") as log:
        log.write(json.dumps(record) + "\n")
    out("meetings.import", {"job_id": "job-" + tag, "meeting_id": "imp-" + tag,
                            "processing_status": "queued", "summary_status": "pending", "error": None})
elif verb == "import-status":
    path = os.path.join(base, "jobs", rest[0] + ".json")
    status = {"processing_status": "transcribing", "error": None}
    if os.path.exists(path):
        with open(path) as handle:
            status = json.load(handle)
    out("meetings.import_status", dict({"job_id": rest[0], "meeting_id": "", "summary_status": "pending"}, **status))
else:
    fail("unexpected command " + verb)
PY

# The fake intake model: saves the prompt and answers with $FAKE_MODEL_OUTPUT.
cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
cat > "$FAKE_MODEL_DIR/prompt.$(date +%s%N 2>/dev/null || date +%s).txt"
printf 'called\n' >> "$FAKE_MODEL_DIR/calls"
printf '{"type":"result","structured_output":%s}\n' "$(cat "$FAKE_MODEL_OUTPUT")"
SH

# The fake inbox records each note's request id and body, and forgets one by
# its request id.
cat > "$FAKES/inbox" <<'SH'
#!/usr/bin/env bash
if [ "$1" = forget ]; then
  [ ! -e "$FAKE_INBOX_DIR/$2" ] || { rm -f "$FAKE_INBOX_DIR/$2"; echo "forgot $2"; }
  exit 0
fi
[ "$1" = note ] && [ "$2" = --request-id ] && [ "$4" = - ] || { echo "bad inbox call: $*" >&2; exit 2; }
mkdir -p "$FAKE_INBOX_DIR"
if [ -e "$FAKE_INBOX_DIR/$3" ]; then echo "replay $3"; exit 0; fi
cat > "$FAKE_INBOX_DIR/$3"
echo "queued $3"
SH

# The fake desk speaker records each spoken line, and reports itself off when
# a <spoken>.off marker exists.
cat > "$FAKES/speak" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --enabled ]; then
  if [ -e "$FAKE_SPOKEN.off" ]; then echo disabled; else echo enabled; fi
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_SPOKEN"
SH
chmod +x "$FAKES/anarlog" "$FAKES/claude" "$FAKES/inbox" "$FAKES/speak"

# fixture.py writes invented Anarlog meetings with timestamps relative to NOW.
cat > "$FAKES/fixture.py" <<'PY'
import datetime, json, os, sys
base, now = sys.argv[1], int(sys.argv[2])
def iso(offset):
    return datetime.datetime.fromtimestamp(now + offset, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
spec = json.loads(sys.argv[3])
os.makedirs(os.path.join(base, "meetings"), exist_ok=True)
mid = spec["id"]
ended = spec.get("ended", -900)
meeting = {
    "id": mid, "title": spec.get("title", "Garden planning"), "kind": "meeting", "status": "active",
    "created_at": iso(ended - 1800), "updated_at": iso(spec.get("updated", ended)),
    "started_at": iso(ended - 1800), "ended_at": "" if spec.get("unfinished") else iso(ended),
    "timezone": "", "language": "", "series_id": "", "folder_path": None,
    "note": {"id": mid, "kind": "note", "title": "", "markdown": spec.get("note", "Talk about the garden shed."),
             "template_id": "", "sort_order": 0, "created_at": iso(ended - 1800), "updated_at": iso(ended)},
    "summaries": [] if spec.get("no_summary") else [{"id": "s-" + mid, "kind": "summary", "title": "Summary",
        "markdown": spec.get("summary", "Robin and the captain agreed to compare shed kits."),
        "template_id": "", "sort_order": 0, "created_at": iso(ended), "updated_at": iso(ended)}],
    "participants": spec.get("participants", [{"human_id": "self", "display_name": "Captain", "email": ""}]),
    "action_items": [{"text": t, "status": "open"} for t in spec.get("action_items", [])],
    "transcripts": [{"id": "t-" + mid, "source": spec.get("source", "live"), "provider": "soniqo",
                     "model": spec.get("model", "soniqo-parakeet-streaming"), "language": spec.get("language", "en"),
                     "started_at_ms": 0, "ended_at_ms": None, "memo": "", "text": "", "words": [], "speaker_hints": []}]
                   if not spec.get("no_transcript") else [],
    "speakers": [{"human_id": "self", "name": "Captain", "is_self": True}],
    "attachments": spec.get("attachments", []),
    "capture_pending": spec.get("capture_pending", False),
}
if "recording_import" in spec:
    meeting["recording_import"] = spec["recording_import"]
    meeting["processing_status"] = spec["recording_import"]["processing_status"]
with open(os.path.join(base, "meetings", mid + ".json"), "w") as handle:
    json.dump(meeting, handle)
transcript = spec.get("transcript", "Captain: Let us compare three shed kits.\n\nRobin: Sounds good.")
with open(os.path.join(base, "meetings", mid + ".md"), "w") as handle:
    handle.write(f"# {meeting['title']}\n\n- ID: `{mid}`\n\n## Notes\n\n{meeting['note']['markdown']}\n\n"
                 + "".join(f"## Summary\n\n{s['markdown']}\n\n" for s in meeting["summaries"])
                 + (f"## Transcript\n\n{transcript}" if transcript else ""))
listing = []
path = os.path.join(base, "list.json")
if os.path.exists(path):
    with open(path) as handle:
        listing = [i for i in json.load(handle) if i["id"] != mid]
if not spec.get("unlisted"):
    listing.insert(0, {k: meeting[k] for k in ("id", "title", "kind", "status", "created_at", "updated_at",
                                               "started_at", "ended_at", "series_id", "folder_path")})
with open(path, "w") as handle:
    json.dump(listing, handle)
PY

# new_home <name> [<config lines>]: a scratch home opted in to the Anarlog
# source, with its own fake Anarlog data and recorders.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/anarlog/jobs" "$home/model" "$home/inbox"
  printf 'enabled = true\nsource = anarlog\n' > "$home/config/meetings"
  printf '[]\n' > "$home/anarlog/list.json"
  : > "$home/anarlog/calls.log"
  printf '%s\n' "$home"
}

# meeting <home> <json-spec>: add or replace one invented Anarlog meeting.
meeting() {
  python3 "$FAKES/fixture.py" "$1/anarlog" "$NOW" "$2"
}

# run <home> <now-offset> <args...>: run the subject in <home> at NOW + offset.
run() {
  local home=$1 offset=$2
  shift 2
  env FM_HOME="$home" FM_MEETINGS_NOW=$((NOW + offset)) \
    FM_MEETINGS_ANARLOG="$FAKES/anarlog" FAKE_ANARLOG_DIR="$home/anarlog" \
    FM_MEETINGS_CLAUDE="$FAKES/claude" FAKE_MODEL_DIR="$home/model" FAKE_MODEL_OUTPUT="$home/model/output.json" \
    FM_MEETINGS_INBOX="$FAKES/inbox" FAKE_INBOX_DIR="$home/inbox" \
    FM_MEETINGS_SPEAK="$FAKES/speak" FAKE_SPOKEN="$home/spoken.txt" \
    "$SUBJECT" "$@"
}

# baseline <home>: arm-time record well before the fixtures' meetings ended.
baseline() {
  mkdir -p "$1/state/meetings"
  printf '{"version":1,"baseline":%s,"meetings":{},"notices":{}}\n' $((NOW - 86400)) \
    > "$1/state/meetings/records.json"
}

model_says() {
  printf '%s\n' "$2" > "$1/model/output.json"
}

phase_of() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["meetings"].get(sys.argv[2], {}).get("phase", ""))' \
    "$1/state/meetings/records.json" "$2"
}

# stamp_at <now-offset>: the call recorder's stamp for a call started then.
stamp_at() {
  python3 -c 'import sys,time; print(time.strftime("%Y%m%d-%H%M%S", time.localtime(int(sys.argv[1]))))' $((NOW + $1))
}

# archived_call <home> <stamp> <transcript lines...>: one archived call recorded
# by the call recorder, with its end-of-call notes unless NO_NOTES is set.
archived_call() {
  local home=$1 stamp=$2 archive
  archive="$home/data/calls/archive"
  shift 2
  mkdir -p "$archive"
  printf '# 2026-01-01 10:00:00 UTC recording started (mic) after everyone on the call agreed to be recorded\n' \
    > "$archive/$stamp-transcript.txt"
  printf '%s\n' "$@" >> "$archive/$stamp-transcript.txt"
  [ -n "${NO_NOTES:-}" ] || printf '%s\n' '{"summary": "The call settled the shed plan.", "items": [
    {"id": "S-1", "kind": "next_step", "status": "confirmed", "text": "Compare the shed kits", "owner": "Unassigned"},
    {"id": "S-2", "kind": "next_step", "status": "withdrawn", "text": "Paint the fence", "owner": "Unassigned"},
    {"id": "D-1", "kind": "decision", "status": "confirmed", "text": "A wooden shed", "owner": ""}]}' \
    > "$archive/$stamp-notes.json"
}

test_help_and_usage() {
  local out rc=0
  out=$("$SUBJECT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "fm-meetings.sh intake" "--help lists intake"
  rc=0
  out=$("$SUBJECT" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action exits 2"
  assert_contains "$out" "unknown action" "an unknown action is named"
  pass "fm-meetings: help and usage"
}

test_intake_is_off_until_config_enables_it() {
  local home out rc=0
  home=$(new_home off)
  rm -f "$home/config/meetings"
  out=$(FM_HOME="$home" "$SUBJECT" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm refuses on a home that has not opted in"
  assert_contains "$out" "the meeting intake is off" "arm says the intake is off"
  assert_contains "$out" "enabled = true in config/meetings" "and how to turn it on"
  assert_absent "$home/state/meetings.check.sh" "no check shim is written while off"
  assert_absent "$home/state/meetings.check-trust" "no trust binding is written while off"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "an armed check prints nothing while off"
  rc=0
  out=$(run "$home" 0 intake 2>&1) || rc=$?
  expect_code 1 "$rc" "intake refuses while off"
  assert_contains "$out" "the meeting intake is off" "intake says the intake is off"
  out=$(run "$home" 0 status)
  assert_contains "$out" "intake: off; sources: call-recorder" "status says it is off and names the default source"
  printf 'enabled = maybe\n' > "$home/config/meetings"
  rc=0
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 1 "$rc" "a value that is not true or false is refused"
  assert_contains "$out" "enabled must be true or false" "and named"
  printf 'enabled = true\nsource = notes-app\n' > "$home/config/meetings"
  rc=0
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown source is refused"
  assert_contains "$out" "unknown source notes-app (known: anarlog, call-recorder)" "and the known sources are listed"
  pass "fm-meetings: nothing runs until config/meetings turns the intake on"
}

test_arm_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(new_home arm)
  out=$(FM_HOME="$home" "$SUBJECT" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/meetings.check.sh" "arm names the shim"
  assert_present "$home/state/meetings.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/meetings.check.sh")" "fm-meetings.sh check" "the shim runs the check"
  assert_contains "$(cat "$home/state/meetings.check.sh")" "FM_HOME=$home" "the shim pins the home"
  assert_grep '"baseline"' "$home/state/meetings/records.json" "arm records the arming time"
  out=$(FM_HOME="$home" "$SUBJECT" arm 2>&1) || fail "re-arm must succeed: $out"
  out=$(FM_HOME="$home" "$SUBJECT" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/meetings.check.sh" "disarm removes the shim"
  assert_absent "$home/state/meetings.check-trust" "disarm removes the trust binding"
  assert_present "$home/state/meetings/records.json" "disarm keeps the meeting records"
  pass "fm-meetings: arm binds the check, disarm removes it and keeps the records"
}

test_meetings_before_arming_are_left_alone() {
  local home out
  home=$(new_home before-arm)
  meeting "$home" '{"id":"m-old","ended":-900,"source":"batch_transcription","model":"soniqo-parakeet-batch"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "the first poll sets the baseline and announces nothing"
  assert_equals baseline "$(phase_of "$home" m-old)" "a meeting that ended before arming is left alone"
  pass "fm-meetings: meetings that ended before arming are left alone"
}

test_native_batch_meeting_is_announced_once() {
  local home out
  home=$(new_home native)
  baseline "$home"
  meeting "$home" '{"id":"m-native","title":"Shed plans","ended":-60,"source":"batch_transcription","model":"soniqo-parakeet-batch"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a meeting that changed a minute ago is still settling"
  out=$(run "$home" 300 check)
  assert_contains "$out" "meetings: 1 meeting(s) ready for intake - run $ROOT/bin/fm-meetings.sh intake" "a settled meeting is announced with the command to run"
  assert_contains "$out" "; ready: Shed plans" "the wake line names the meeting"
  out=$(run "$home" 600 check)
  assert_equals "" "$out" "it is announced only once"
  assert_no_grep "import" "$home/anarlog/calls.log" "Anarlog's own batch transcript needs no speaker pass"
  pass "fm-meetings: a meeting Anarlog already ran its batch pass on is announced once"
}

test_meeting_whose_first_read_fails_is_retried() {
  local home out
  home=$(new_home first-read)
  baseline "$home"
  meeting "$home" '{"id":"m-late","title":"Late find","ended":-900,"source":"batch_transcription"}'
  touch "$home/anarlog/export-fails"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a meeting whose first read fails is not announced"
  assert_equals waiting "$(phase_of "$home" m-late)" "it stays waiting for the next poll"
  rm -f "$home/anarlog/export-fails"
  out=$(run "$home" 300 check)
  assert_contains "$out" "ready: Late find" "the next poll retries it and announces it"
  pass "fm-meetings: a meeting whose first read fails is retried on the next poll"
}

test_capture_pending_and_missing_summary_wait() {
  local home out
  home=$(new_home pending)
  baseline "$home"
  meeting "$home" '{"id":"m-pend","title":"Still saving","ended":-900,"capture_pending":true,"source":"batch_transcription"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a capture Anarlog is still finishing is not announced"
  meeting "$home" '{"id":"m-pend","title":"Still saving","ended":-300,"no_summary":true,"source":"batch_transcription"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a meeting without its summary waits for it"
  out=$(run "$home" 400 check)
  assert_contains "$out" "Still saving" "after ten minutes it goes ahead without a summary"
  pass "fm-meetings: pending captures and missing summaries wait"
}

test_live_only_meeting_gets_a_speaker_pass() {
  local home out child job
  home=$(new_home speaker-pass)
  baseline "$home"
  # Anarlog keeps a meeting's folder under sessions/, inside any meeting folders.
  mkdir -p "$home/anarlog/sessions/Trips/m-live"
  printf 'RIFF-fake-audio' > "$home/anarlog/sessions/Trips/m-live/audio.wav"
  meeting "$home" '{"id":"m-live","title":"Road trip","ended":-900,"transcript":"Captain: Firstmate, do it: plan the route along the river.\n\nRobin: Fine by me.\n\nCaptain: We should compare the shed kits. first made do it.\n\nCaptain: And plan the route back home. Firstmate, do it.","attachments":[{"id":"a1","relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav","size_bytes":15,"sha256":""}]}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "nothing is announced while the speaker pass runs"
  assert_grep '"request_key": "fm-meetings-speakers-m-live"' "$home/anarlog/imports.jsonl" "the recording is imported for Anarlog's batch pass"
  assert_grep '"title": "Road trip (speaker pass)"' "$home/anarlog/imports.jsonl" "the speaker-pass copy is titled after its meeting"
  assert_grep "$home/anarlog/sessions/Trips/m-live/audio.wav" "$home/anarlog/imports.jsonl" "the meeting's own recording is the one imported"
  assert_equals speaker-pass "$(phase_of "$home" m-live)" "the meeting waits on the speaker pass"
  child=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["request_key"])' "$home/anarlog/imports.jsonl")
  child=$(printf '%s' "$child" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:8])')
  job="job-$child"
  meeting "$home" "{\"id\":\"imp-$child\",\"title\":\"Road trip (speaker pass)\",\"ended\":-60,\"source\":\"batch_transcription\",\"model\":\"soniqo-parakeet-batch\",\"recording_import\":{\"job_id\":\"$job\",\"meeting_id\":\"imp-$child\",\"processing_status\":\"transcribing\",\"summary_status\":\"pending\",\"error\":null},\"transcript\":\"Speaker 1: Firstmate, do it: plan the route along the river.\\n\\nSpeaker 2: Fine by me.\\n\\nSpeaker 1: We should compare the shed kits. Firstmate, do it.\\n\\nSpeaker 1: And plan the route back home. Firstmate, do it.\\n\\nSpeaker 2: Firstmate, do it, maybe.\"}"
  out=$(run "$home" 60 check)
  assert_equals "" "$out" "an unfinished speaker pass keeps waiting"
  printf '{"processing_status":"done","error":null}\n' > "$home/anarlog/jobs/$job.json"
  out=$(run "$home" 120 check)
  assert_contains "$out" "1 meeting(s) ready for intake" "the meeting is announced once its speaker pass is done"
  assert_contains "$out" "ready: Road trip" "under its own title"
  assert_not_contains "$out" "(speaker pass)" "the speaker-pass copy is never announced on its own"
  assert_equals 1 "$(grep -c . "$home/anarlog/imports.jsonl")" "the speaker pass is requested once"

  # Candidates: 1-2 from the live transcript (the captain's), 3-6 from the speaker pass.
  model_says "$home" '{"outcome":"The route goes along the river.","actions":[],"spoken_orders":[{"candidates":[1,3],"instruction":"Plan the road route along the river","evidence":"plan the route along the river","outward":false,"destructive":false,"other_person":false},{"candidates":[4],"instruction":"Compare the shed kits","evidence":"We should compare the shed kits","outward":false,"destructive":false,"other_person":false},{"candidates":[2,5],"instruction":"Plan the route back home","evidence":"plan the route back home","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 180 intake)
  assert_contains "$out" "Road trip: 2 clear follow-up(s) to start, 2 for the captain's decision" "orders heard in both transcripts count once, and the rest wait"
  assert_grep "Plan the route back home" "$home/inbox/meeting-m-live-start" "an order heard in both transcripts keeps the live attribution"
  assert_no_grep "Plan the route back home" "$home/inbox/meeting-m-live-review" "an order heard in both transcripts is filed once"
  assert_grep "Compare the shed kits (waits because could not tell who said it" "$home/inbox/meeting-m-live-review" "an order the live transcript misheard, just before a live-heard one, is kept and waits"
  assert_grep "A spoken order that could not be read clearly" "$home/inbox/meeting-m-live-review" "a candidate no entry covers still waits"
  assert_not_contains "$out" "live transcript only" "the speaker-pass transcript counts as final"
  assert_grep "Plan the road route along the river" "$home/inbox/meeting-m-live-start" "the spoken order goes to firstmate ready to start"
  assert_grep "Speaker 2: Fine by me." "$(ls "$home"/model/prompt.*)" "the model reads the speaker-pass transcript"
  pass "fm-meetings: a live-only meeting gets Anarlog's batch pass through its own import"
}

# speaker_pass_meeting <home> <id> <live transcript> <speaker-pass transcript>:
# a live-only meeting whose speaker pass has finished and is ready for intake.
speaker_pass_meeting() {
  local home=$1 id=$2 live=$3 heard=$4 child
  mkdir -p "$home/anarlog/sessions/$id"
  printf 'RIFF-fake-audio' > "$home/anarlog/sessions/$id/audio.wav"
  meeting "$home" "{\"id\":\"$id\",\"title\":\"Route chat\",\"ended\":-900,\"transcript\":\"$live\",\"attachments\":[{\"relative_path\":\"audio.wav\",\"filename\":\"audio.wav\",\"content_type\":\"audio/wav\"}]}"
  run "$home" 0 check >/dev/null
  child=$(python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:8])' "fm-meetings-speakers-$id")
  meeting "$home" "{\"id\":\"imp-$child\",\"title\":\"Route chat (speaker pass)\",\"ended\":-60,\"source\":\"batch_transcription\",\"model\":\"soniqo-parakeet-batch\",\"recording_import\":{\"job_id\":\"job-$child\",\"meeting_id\":\"imp-$child\",\"processing_status\":\"done\",\"summary_status\":\"done\",\"error\":null},\"transcript\":\"$heard\"}"
  printf '{"processing_status":"done","error":null}\n' > "$home/anarlog/jobs/job-$child.json"
  run "$home" 120 check >/dev/null
}

test_spoken_order_evidence_from_the_live_copy_credits_the_captain() {
  local home out live="Captain: Firstmate, do it: plan the root along the river." \
    heard="Speaker 1: Firstmate, do it: plan the route along the river."
  home=$(new_home quote-live)
  baseline "$home"
  speaker_pass_meeting "$home" m-quote "$live" "$heard"
  model_says "$home" '{"outcome":"The route goes along the river.","actions":[],"spoken_orders":[{"candidates":[1,2],"instruction":"Plan the road route along the river","evidence":"plan the root along the river","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 180 intake)
  assert_contains "$out" "Route chat: 1 clear follow-up(s) to start, 0 for the captain's decision" "an order quoted from the captain's live copy starts on its own"
  assert_grep "copied exactly from a covered candidate heard in the meeting transcript" "$(ls "$home"/model/prompt.*)" "the prompt asks for the quote from the live copy"

  home=$(new_home quote-pass)
  baseline "$home"
  speaker_pass_meeting "$home" m-quote "$live" "$heard"
  model_says "$home" '{"outcome":"The route goes along the river.","actions":[],"spoken_orders":[{"candidates":[1,2],"instruction":"Plan the road route along the river","evidence":"plan the route along the river","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 180 intake)
  assert_contains "$out" "Route chat: 0 clear follow-up(s) to start, 1 for the captain's decision" "an order quoted only from the speaker-pass wording waits"
  assert_grep "could not tell who said it" "$home/inbox/meeting-m-quote-review" "and says it could not tell who said it"
  pass "fm-meetings: a spoken order credits the captain only when quoted from the captain's live copy"
}

test_spoken_order_also_listed_as_an_action_is_filed_once() {
  local home out order
  order='{"candidates":[1,2],"instruction":"Plan the road route along the river","evidence":"plan the root along the river","outward":false,"destructive":false,"other_person":false}'
  home=$(new_home order-once)
  baseline "$home"
  speaker_pass_meeting "$home" m-once "Captain: Firstmate, do it: plan the root along the river." \
    "Speaker 1: Firstmate, do it: plan the route along the river."
  model_says "$home" "{\"outcome\":\"The route goes along the river.\",\"actions\":[{\"title\":\"Plan the road route\",\"instruction\":\"Plan the road route along the river\",\"evidence\":\"plan the route along the river\",\"clear\":true,\"why_review\":\"\",\"outward\":false,\"destructive\":false,\"other_person\":false}],\"spoken_orders\":[$order]}"
  out=$(run "$home" 180 intake)
  assert_contains "$out" "Route chat: 1 clear follow-up(s) to start, 0 for the captain's decision" "the captain's order is started once, not again as a meeting action"

  home=$(new_home order-unattributed)
  baseline "$home"
  meeting "$home" '{"id":"m-glass","title":"Labelled chat","ended":-900,"source":"batch_transcription","transcript":"Speaker 1: Firstmate, do it, plan the lunch menu.\n\nSpeaker 2: Sounds good."}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"Lunch is on Friday.","actions":[{"title":"Plan the lunch menu","instruction":"Plan the lunch menu","evidence":"plan the lunch menu","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[{"candidates":[1],"instruction":"Plan the lunch menu","evidence":"plan the lunch menu","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "Labelled chat: 0 clear follow-up(s) to start, 1 for the captain's decision" "an order no one can attribute waits and does not start as a meeting action"
  assert_grep "could not tell who said it" "$home/inbox/meeting-m-glass-review" "it waits because no one can tell who said it"
  pass "fm-meetings: a spoken order the model also lists as a meeting action is filed once, by the spoken-order rule"
}

# alongside_meeting <home> <id> <step said after the order> <model spoken_orders>:
# the captain gives a spoken order and, in the same turn, a separate step.
alongside_meeting() {
  local home=$1 id=$2 step=$3 orders=$4
  meeting "$home" "{\"id\":\"$id\",\"title\":\"Shed chat\",\"ended\":-900,\"source\":\"batch_transcription\",\"transcript\":\"Captain: We should compare the shed kits. Firstmate, do it. And I will $step myself later.\\n\\nRobin: Sounds good.\"}"
  run "$home" 0 check >/dev/null
  model_says "$home" "{\"outcome\":\"They will compare shed kits.\",\"actions\":[{\"title\":\"Act on what was said\",\"instruction\":\"Then $step\",\"evidence\":\"$step\",\"clear\":true,\"why_review\":\"\",\"outward\":false,\"destructive\":false,\"other_person\":false}],\"spoken_orders\":$orders}"
}

test_action_said_alongside_a_spoken_order_is_kept() {
  local home out step order
  order='[{"candidates":[1],"instruction":"Compare the shed kits","evidence":"We should compare the shed kits","outward":false,"destructive":false,"other_person":false}]'
  for step in "draft the packing list for Saturday" "email the builder about the price"; do
    home=$(new_home "alongside-${step%% *}")
    baseline "$home"
    alongside_meeting "$home" m-shed "$step" "$order"
    out=$(run "$home" 60 intake)
    assert_contains "$out" "Shed chat: 1 clear follow-up(s) to start, 1 for the captain's decision" "the order starts and the step said with it waits ($step)"
    assert_grep "Compare the shed kits" "$home/inbox/meeting-m-shed-start" "the captain's spoken order still starts on its own ($step)"
    assert_grep "Act on what was said (waits because it was said alongside a spoken order" "$home/inbox/meeting-m-shed-review" "the step is kept for the captain ($step)"
    assert_grep "Then $step" "$home/inbox/meeting-m-shed-review" "the step keeps its instruction ($step)"

    home=$(new_home "alongside-unread-${step%% *}")
    baseline "$home"
    alongside_meeting "$home" m-shed "$step" '[]'
    out=$(run "$home" 60 intake)
    assert_contains "$out" "Shed chat: 0 clear follow-up(s) to start, 2 for the captain's decision" "with no entry for the order, both wait ($step)"
    assert_grep "Then $step" "$home/inbox/meeting-m-shed-review" "the step's instruction is not lost ($step)"
    assert_grep "A spoken order that could not be read clearly" "$home/inbox/meeting-m-shed-review" "the unread order waits too ($step)"
  done
  assert_grep "it would act toward someone outside Starship" "$home/inbox/meeting-m-shed-review" "an outward step keeps its own reason as well"
  pass "fm-meetings: a step said in the same turn as a spoken order is kept and waits"
}

test_action_whose_quote_holds_a_spoken_order_is_kept() {
  local home out
  home=$(new_home alongside-whole-turn)
  baseline "$home"
  meeting "$home" '{"id":"m-turn","title":"Shed chat","ended":-900,"source":"batch_transcription","transcript":"Captain: We should compare the shed kits. Firstmate, do it. And I will email the builder myself.\n\nRobin: Sounds good."}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[{"title":"Email the builder","instruction":"Email the builder about the shed","evidence":"We should compare the shed kits. Firstmate, do it. And I will email the builder myself.","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[{"candidates":[1],"instruction":"Compare the shed kits","evidence":"compare the shed kits. Firstmate, do it","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "Shed chat: 1 clear follow-up(s) to start, 1 for the captain's decision" "the order starts and the step quoted around it waits"
  assert_grep "Email the builder (waits because it was said alongside a spoken order" "$home/inbox/meeting-m-turn-review" "a step whose quote holds the order's quote is kept for the captain"
  pass "fm-meetings: an action whose quote holds a spoken order's quote is kept, not dropped as that order"
}

test_ready_meeting_is_announced_again_until_taken_in() {
  local home out
  home=$(new_home reannounce)
  baseline "$home"
  meeting "$home" '{"id":"m-again","title":"Again","ended":-900,"source":"batch_transcription"}'
  out=$(run "$home" 0 check)
  assert_contains "$out" "ready: Again" "a ready meeting is announced"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "it is not announced again while that wake is fresh"
  printf 'not json' > "$home/model/output.json"
  run "$home" 360 intake >/dev/null 2>&1
  out=$(run "$home" 420 check)
  assert_contains "$out" "1 meeting(s) ready for intake" "a meeting whose intake failed is announced again at the next check"
  assert_contains "$out" "ready: Again" "by name"
  out=$(run "$home" 480 check)
  assert_equals "" "$out" "and then only once"
  out=$(run "$home" $((420 + 43200)) check)
  assert_contains "$out" "ready: Again" "a meeting still waiting is announced again after twelve hours"
  pass "fm-meetings: a ready meeting is announced again after a failed intake and while it still waits"
}

test_wake_line_keeps_the_command_and_problems_whatever_the_titles() {
  local home out n
  home=$(new_home long-titles)
  printf 'enabled = true\nsource = anarlog\nsource = call-recorder\n' > "$home/config/meetings"
  baseline "$home"
  for n in 1 2 3 4 5 6; do
    meeting "$home" "{\"id\":\"m-long-$n\",\"title\":\"Quarterly garden planning with the whole allotment committee, part $n\",\"ended\":-900,\"source\":\"batch_transcription\"}"
  done
  mkdir -p "$home/data/calls"
  printf 'not a folder' > "$home/data/calls/archive"
  out=$(run "$home" 0 check)
  assert_contains "$out" "meetings: 6 meeting(s) ready for intake - run $ROOT/bin/fm-meetings.sh intake" "the command to run comes first"
  assert_contains "$out" "call-recorder cannot be read: the call archive cannot be read" "a problem reported once is not cut off by long titles"

  home=$(new_home long-titles-shown)
  baseline "$home"
  for n in 1 2 3 4 5 6; do
    meeting "$home" "{\"id\":\"m-long-$n\",\"title\":\"Quarterly garden planning with the whole allotment committee, part $n\",\"ended\":-900,\"source\":\"batch_transcription\"}"
  done
  out=$(run "$home" 0 check)
  assert_contains "$out" "ready: Quarterly garden planning with the wh..." "each title is cut short"
  assert_not_contains "$out" "allotment committee" "a long title is never shown whole"
  assert_contains "$out" "; and 3 more" "only the first few are named"
  pass "fm-meetings: the wake line puts the command and problems before a bounded list of titles"
}

test_speaker_pass_falls_back_to_the_live_transcript() {
  local home out
  home=$(new_home fallback)
  baseline "$home"
  meeting "$home" '{"id":"m-noaudio","title":"Quick chat","ended":-900}'
  out=$(run "$home" 0 check)
  assert_contains "$out" "Quick chat" "a meeting without a recording is announced at once"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "live transcript only: Anarlog kept no recording" "the outcome says only the live transcript was used, and why"
  assert_grep "Only the live transcript was available." "$home/spoken.txt" "the spoken line says so too"

  home=$(new_home fallback-failed)
  baseline "$home"
  mkdir -p "$home/anarlog/sessions/m-fail"
  printf 'audio' > "$home/anarlog/sessions/m-fail/rec.m4a"
  meeting "$home" '{"id":"m-fail","title":"Failed pass","ended":-900,"attachments":[{"relative_path":"rec.m4a","filename":"rec.m4a","content_type":"audio/mp4"}]}'
  touch "$home/anarlog/import-fails"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a refused speaker pass is retried while there is time"
  out=$(run "$home" 11000 check)
  assert_contains "$out" "Failed pass" "after the wait the live transcript is used"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 11100 intake)
  assert_contains "$out" "Anarlog could not start the speaker pass (anarlog meetings import" "the reason the speaker pass is missing is reported"
  assert_contains "$out" "Open the updated Anarlog desktop app" "with Anarlog's own words for it"

  home=$(new_home fallback-doctor)
  baseline "$home"
  meeting "$home" '{"id":"m-doc","title":"Doctor down","ended":-900,"attachments":[{"relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav"}]}'
  touch "$home/anarlog/doctor-fails"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a recording that cannot be located yet is retried while there is time"
  assert_equals waiting "$(phase_of "$home" m-doc)" "the meeting waits for the speaker pass"
  out=$(run "$home" 11000 check)
  assert_contains "$out" "Doctor down" "after the wait the live transcript is used"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 11100 intake)
  assert_contains "$out" "Anarlog could not start the speaker pass (anarlog doctor failed" "the reason the speaker pass is missing is reported"

  home=$(new_home fallback-missing)
  baseline "$home"
  meeting "$home" '{"id":"m-gone","title":"Missing file","ended":-900,"attachments":[{"relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav"}]}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "the meeting's recording could not be found on this Mac" "a recording Anarlog lists but this Mac lacks is named as the reason"
  assert_absent "$home/anarlog/imports.jsonl" "nothing is imported without the recording"
  pass "fm-meetings: the live transcript is used only when the speaker pass cannot run, and the outcome says so"
}

test_excluded_meeting_is_never_processed() {
  local home out
  home=$(new_home excluded)
  baseline "$home"
  printf 'exclude_word = Acme\n' >> "$home/config/meetings"
  meeting "$home" '{"id":"m-work","title":"Team sync","ended":-900,"source":"batch_transcription","participants":[{"human_id":"p1","display_name":"Sam","email":"sam@acme.test"}]}'
  run "$home" 0 check >/dev/null
  out=$(run "$home" 60 intake)
  assert_equals "excluded meeting, not processed: Team sync" "$out" "an excluded meeting gets only the one-line note"
  assert_absent "$home/model/calls" "an excluded meeting never reaches the model"
  assert_equals "" "$(ls "$home/inbox")" "an excluded meeting files nothing"
  assert_absent "$home/spoken.txt" "an excluded meeting is not spoken"
  assert_absent "$home/data/meetings/m-work/intake.json" "an excluded meeting keeps no intake record"

  home=$(new_home exclude-words)
  baseline "$home"
  printf '# private words\nAcme\n' > "$home/config/meeting-exclude-words"
  printf 'Robin\n' > "$home/config/leak-words"
  meeting "$home" '{"id":"m-work2","title":"Planning","ended":-900,"source":"batch_transcription","summary":"Roadmap for ACME customers."}'
  meeting "$home" '{"id":"m-friend","title":"Walk with Robin","ended":-800,"source":"batch_transcription","participants":[{"human_id":"r","display_name":"Robin","email":""}]}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"Lunch is on Friday.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "excluded meeting, not processed: Planning" "a word from the home's exclude-words file marks an excluded meeting"
  assert_contains "$out" "Walk with Robin: 0 clear follow-up(s)" "a friend named in the leak-word list does not exclude a meeting"

  home=$(new_home exclude-imported)
  baseline "$home"
  printf 'exclude_word = Acme\n' >> "$home/config/meetings"
  meeting "$home" '{"id":"imp-work","title":"Imported voice memo","ended":-60,"unfinished":true,"no_summary":true,"note":"","participants":[],"source":"batch_transcription","transcript":"Speaker 1: The Acme launch slips a week.\n\nSpeaker 2: Noted.","recording_import":{"job_id":"job-w","meeting_id":"imp-work","processing_status":"done","summary_status":"pending","error":null}}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "an imported recording waits for Anarlog's summary"
  out=$(run "$home" 700 check)
  assert_contains "$out" "ready: Imported voice memo" "after ten minutes it goes ahead without one"
  out=$(run "$home" 760 intake)
  assert_equals "excluded meeting, not processed: Imported voice memo" "$out" "an exclude word in the transcript alone excludes a meeting"
  assert_absent "$home/model/calls" "an excluded imported recording never reaches the model"
  assert_equals "" "$(ls "$home/inbox")" "an excluded imported recording files nothing"

  home=$(new_home exclude-speaker-pass)
  baseline "$home"
  printf 'exclude_word = Acme\n' >> "$home/config/meetings"
  mkdir -p "$home/anarlog/sessions/m-live-work"
  printf 'RIFF-fake-audio' > "$home/anarlog/sessions/m-live-work/audio.wav"
  meeting "$home" '{"id":"m-live-work","title":"Weekly sync","ended":-900,"participants":[{"human_id":"p1","display_name":"Sam","email":"","organization_name":"Acme"}],"attachments":[{"relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav"}]}'
  out=$(run "$home" 0 check)
  assert_absent "$home/anarlog/imports.jsonl" "an excluded live-only meeting's recording is never handed back for a speaker pass"
  assert_contains "$out" "ready: Weekly sync" "it goes to the intake as it stands"
  out=$(run "$home" 60 intake)
  assert_equals "excluded meeting, not processed: Weekly sync" "$out" "and the intake keeps it out"
  assert_absent "$home/model/calls" "an excluded live-only meeting never reaches the model"
  pass "fm-meetings: an excluded meeting is never sent to a model or actioned"
}

test_intake_sorts_clear_actions_from_review_items() {
  local home out start review
  home=$(new_home intake)
  baseline "$home"
  meeting "$home" '{"id":"m-mix","title":"Garden planning","ended":-900,"source":"batch_transcription","transcript":"Captain: Let us compare three shed kits and their prices.\n\nRobin: I will send you the measurements.\n\nRobin: Firstmate, do it, order the cheapest one."}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[
    {"title":"Compare three shed kits","instruction":"Research three garden shed kits and compare prices","evidence":"compare three shed kits and their prices","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Research the shed kits","instruction":"Research the three shed kits mentioned on the call","evidence":"Let us compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Draft a planting plan","instruction":"Draft a planting plan","evidence":"words that were never said","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Email Robin the shed list","instruction":"Email the list","evidence":"Let us compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Get measurements from Robin","instruction":"Wait for the measurements","evidence":"I will send you the measurements","clear":false,"why_review":"Robin owns it","outward":false,"destructive":false,"other_person":true}],
    "spoken_orders":[{"candidates":[1],"instruction":"Buy the cheapest shed","evidence":"order the cheapest one","outward":true,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "Garden planning: 2 clear follow-up(s) to start, 4 for the captain's decision, outcome spoken" "the intake reports the split"
  start="$home/inbox/meeting-m-mix-start"
  review="$home/inbox/meeting-m-mix-review"
  assert_grep "Compare three shed kits" "$start" "a clear, grounded, internal action is ready to start"
  assert_grep 'Source: "compare three shed kits and their prices"' "$start" "the start note carries its source snippet"
  assert_grep "Research the three shed kits mentioned on the call" "$start" "a call named only as context stays a clear follow-up"
  assert_grep "not typed by the captain" "$start" "the note says it was extracted, not typed"
  assert_grep 'from the meeting "Garden planning"' "$start" "the note names how the meeting was captured"
  assert_no_grep "Email Robin" "$start" "an outward action never starts on its own"
  assert_grep "Meeting items waiting for the captain's decision" "$review" "the review note opens with the line the skill is loaded on"
  assert_grep "Draft a planting plan (waits because its source could not be found" "$review" "an action without a found source waits"
  assert_grep "Email Robin the shed list (waits because it would act toward someone outside Starship" "$review" "an outward action waits even when the model called it clear"
  assert_grep "touches another person's commitment" "$review" "another person's commitment waits"
  assert_grep "someone other than the captain said it" "$review" "a spoken order from someone else waits"
  assert_grep "Garden planning" "$home/spoken.txt" "one spoken line goes to the desk"
  assert_grep "2 clear follow-ups handed to Starship, 4 waiting for your decision." "$home/spoken.txt" "the spoken line gives the split"
  assert_present "$home/data/meetings/m-mix/intake.json" "the intake record is kept"
  assert_grep '"source": "anarlog"' "$home/data/meetings/m-mix/intake.json" "the record names the source"
  assert_equals taken "$(phase_of "$home" m-mix)" "the meeting is marked taken in"
  out=$(run "$home" 120 intake)
  assert_equals "no meetings are waiting for intake" "$out" "a taken meeting is not taken in again"
  out=$(run "$home" 120 intake m-mix)
  assert_contains "$out" "already handled" "naming a taken meeting does not repeat it"
  assert_equals 1 "$(grep -c . "$home/model/calls")" "the model ran once"
  pass "fm-meetings: intake starts only clear grounded internal work and holds the rest for the captain"
}

test_outward_instructions_wait_whatever_the_model_says() {
  local home out review action instruction actions=""
  home=$(new_home outward)
  baseline "$home"
  meeting "$home" '{"id":"m-out","title":"Shed follow-up","ended":-900,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  local waits=("Remember to email Robin the measurements" "Please send Robin the list" "We should invite Robin"
    "Make sure we pay the deposit" "Ask Robin to pay" "Post on the forum asking about shed kits"
    "Post in the family group chat that the trip is on" "Call to book the campsite" "Phone at nine to cancel"
    "Message on WhatsApp to confirm")
  local clears=("Summarise the call notes into a checklist" "Write up the call transcript"
    "Research the three shed kits mentioned on the call" "Research the shed kits mentioned on today’s call"
    "Summarise the captain's call with the builder")
  for instruction in "${waits[@]}" "${clears[@]}"; do
    action="{\"title\":\"Follow up\",\"instruction\":\"$instruction\",\"evidence\":\"compare three shed kits\",\"clear\":true,\"why_review\":\"\",\"outward\":false,\"destructive\":false,\"other_person\":false}"
    actions="${actions:+$actions,}$action"
  done
  model_says "$home" "{\"outcome\":\"They will follow up on the shed.\",\"actions\":[$actions],\"spoken_orders\":[]}"
  out=$(run "$home" 60 intake)
  assert_contains "$out" "Shed follow-up: 5 clear follow-up(s) to start, 10 for the captain's decision" "outward instructions wait even when the model called them internal"
  review="$home/inbox/meeting-m-out-review"
  for instruction in "${waits[@]}"; do
    assert_grep "$instruction" "$review" "an instruction to act outward waits: $instruction"
  done
  for instruction in "${clears[@]}"; do
    assert_grep "$instruction" "$home/inbox/meeting-m-out-start" "a call named only as a noun starts on its own: $instruction"
  done
  pass "fm-meetings: an instruction to act outward waits for the captain whatever the model said"
}

test_failed_intake_stays_ready() {
  local home out rc=0
  home=$(new_home intake-fail)
  baseline "$home"
  meeting "$home" '{"id":"m-retry","title":"Retry me","ended":-900,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  printf 'not json' > "$home/model/output.json"
  out=$(run "$home" 60 intake) || rc=$?
  expect_code 1 "$rc" "a failed intake exits 1"
  assert_contains "$out" "intake failed: Retry me" "the failure is named"
  assert_equals ready "$(phase_of "$home" m-retry)" "the meeting stays ready for the next intake"
  assert_equals "" "$(ls "$home/inbox")" "a failed intake files nothing"
  pass "fm-meetings: a failed intake leaves the meeting ready"
}

test_imported_recordings_flow_into_the_same_intake() {
  local home out spec
  home=$(new_home imported)
  baseline "$home"
  spec='{"id":"imp-memo","title":"Voice memo","ended":-60,"unfinished":true,"source":"batch_transcription","language":"nl","transcript":"Speaker 1: Firstmate, do it, plan the lunch menu.\n\nSpeaker 2: Sounds good.","recording_import":{"job_id":"job-memo","meeting_id":"imp-memo","processing_status":"done","summary_status":"@SUMMARY@","error":null}}'
  meeting "$home" "${spec//@SUMMARY@/pending}"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a transcribed imported recording waits for Anarlog's summary"
  meeting "$home" "${spec//@SUMMARY@/done}"
  out=$(run "$home" 60 check)
  assert_contains "$out" "ready: Voice memo" "the transcribed imported recording is announced"
  assert_absent "$home/anarlog/imports.jsonl" "a recording Anarlog already transcribed is not imported again"
  model_says "$home" '{"outcome":"Lunch is on Friday.","actions":[],"spoken_orders":[{"candidates":[1],"instruction":"Plan the lunch menu","evidence":"plan the lunch menu","outward":false,"destructive":false,"other_person":false}]}'
  touch "$home/spoken.txt.off"
  out=$(run "$home" 120 intake)
  assert_contains "$out" "Voice memo: 0 clear follow-up(s) to start, 1 for the captain's decision" "the imported recording runs through the same intake"
  assert_grep "could not tell who said it" "$home/inbox/meeting-imp-memo-review" "a spoken order under diarized labels waits because no one can tell who said it"
  assert_no_grep "someone other than the captain" "$home/inbox/meeting-imp-memo-review" "it is never blamed on someone else"
  assert_contains "$out" "desk voice is off" "a home without desk voice is told so rather than told it spoke"
  assert_absent "$home/spoken.txt" "nothing is handed to a desk voice that is off"
  assert_grep '"origin": "imported recording"' "$home/data/meetings/imp-memo/intake.json" "its record says it came from an imported recording"
  assert_grep '"language": "nl"' "$home/data/meetings/imp-memo/intake.json" "its record keeps the language Anarlog heard"
  pass "fm-meetings: recordings imported into Anarlog flow into the same intake"
}

test_unreadable_source_or_config_is_reported_once() {
  local home out
  home=$(new_home broken)
  baseline "$home"
  touch "$home/anarlog/list-fails"
  out=$(run "$home" 0 check)
  assert_contains "$out" "meetings: anarlog cannot be read: anarlog meetings list failed: database is locked" "a broken source is reported with its own error"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "the same problem is reported only once"
  rm -f "$home/anarlog/list-fails"
  run "$home" 600 check >/dev/null
  touch "$home/anarlog/list-fails"
  out=$(run "$home" 900 check)
  assert_contains "$out" "anarlog cannot be read" "it is reported again after it cleared and came back"

  home=$(new_home broken-config)
  baseline "$home"
  printf 'anarlog_speaker_pass_wait = 60\n' >> "$home/config/meetings"
  out=$(run "$home" 0 check)
  assert_contains "$out" "meetings: the poll failed: fm-meetings: config/meetings line 3: unknown key anarlog_speaker_pass_wait" "a broken config is reported"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "a broken config is reported only once"
  printf 'enabled = true\nsource = anarlog\n' > "$home/config/meetings"
  run "$home" 600 check >/dev/null
  printf 'anarlog_speaker_pass_wait = 60\n' >> "$home/config/meetings"
  out=$(run "$home" 900 check)
  assert_contains "$out" "unknown key anarlog_speaker_pass_wait" "a broken config is reported again after it cleared and came back"

  pass "fm-meetings: an unreadable source or config is reported once until it clears"
}

test_recall_answers_from_included_meetings_only() {
  local home out
  home=$(new_home recall)
  baseline "$home"
  printf 'exclude_word = Acme\n' >> "$home/config/meetings"
  meeting "$home" '{"id":"m-robin","title":"Garden planning","ended":-900,"source":"batch_transcription","participants":[{"human_id":"r","display_name":"Robin","email":"robin@gardenclub.test"}]}'
  meeting "$home" '{"id":"m-robin-work","title":"Robin at Acme","ended":-800,"source":"batch_transcription"}'
  meeting "$home" '{"id":"m-robin-org","title":"Robin sync","ended":-100000,"source":"batch_transcription","summary":"Robin walked through the launch plan.","participants":[{"human_id":"r","display_name":"Robin","email":"","organization_name":"Acme","job_title":"Engineer"}]}'
  meeting "$home" '{"id":"m-robin-old","title":"Robin catch-up","ended":-100000,"source":"batch_transcription","summary":"Robin shared launch dates.","transcript":"Robin: The Acme launch slips a week.\n\nCaptain: Noted."}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They agreed to compare shed kits.","actions":[{"title":"Compare shed kits","instruction":"Compare shed kits","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[]}'
  run "$home" 60 intake >/dev/null
  out=$(run "$home" 120 recall what did we agree with Robin)
  assert_contains "$out" "Garden planning (with Robin)" "recall finds the meeting by person"
  assert_contains "$out" "Outcome: They agreed to compare shed kits." "recall gives what was agreed"
  assert_contains "$out" "Follow-up started: Compare shed kits" "recall lists the follow-ups"
  assert_not_contains "$out" "Acme" "recall never answers from an excluded meeting"
  assert_not_contains "$out" "Robin catch-up" "recall never answers from a meeting that only its transcript excludes"
  assert_not_contains "$out" "Robin sync" "recall never answers from a meeting whose participant's organisation alone excludes it"
  assert_not_contains "$out" "launch plan" "nothing of that meeting reaches the asker"
  printf 'exclude_word = gardenclub\n' >> "$home/config/meetings"
  out=$(run "$home" 180 recall what did we agree with Robin)
  assert_equals "no meeting matches what did we agree with Robin" "$out" "a word added later keeps a meeting already taken in out of recall"
  pass "fm-meetings: recall answers from included meetings only"
}

test_archived_calls_feed_the_intake() {
  local home out stamp old
  home=$(new_home calls)
  printf 'enabled = true\n' > "$home/config/meetings"
  printf 'speaker_name = Sam\n' > "$home/config/call-companion"
  baseline "$home"
  stamp=$(stamp_at -900)
  old=$(stamp_at -100000)
  archived_call "$home" "$old" "[10:00:05] Sam: An old call."
  archived_call "$home" "$stamp" \
    "[10:00:05] Sam: Let us compare three shed kits." \
    "[10:00:09] Sam: Firstmate, do it: compare the shed kits." \
    "[10:00:20] others: Sounds good. Firstmate, do it, order the cheapest one." \
    "[10:00:30] unknown speaker: Maybe."
  out=$(run "$home" 0 check)
  assert_contains "$out" "meetings: 1 meeting(s) ready for intake" "an archived call with its notes is announced"
  assert_contains "$out" "ready: Call " "as a call"
  assert_equals baseline "$(phase_of "$home" "call-$old")" "a call archived before arming is left alone"
  assert_equals ready "$(phase_of "$home" "call-$stamp")" "the call is ready for intake"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "it is announced only once"
  assert_equals "" "$(cat "$home/anarlog/calls.log")" "the call-recorder source never calls Anarlog"
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[{"title":"Paint the fence","instruction":"Paint the fence","evidence":"Maybe","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[{"candidates":[1],"instruction":"Compare the shed kits","evidence":"Firstmate, do it: compare the shed kits","outward":false,"destructive":false,"other_person":false},{"candidates":[2],"instruction":"Order the cheapest shed","evidence":"order the cheapest one","outward":true,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 360 intake)
  assert_contains "$out" ": 2 clear follow-up(s) to start, 1 for the captain's decision" "the owner's own spoken order starts, the far side's waits"
  assert_grep "Compare the shed kits" "$home/inbox/meeting-call-$stamp-start" "an order under the home's speaker_name label is the owner's"
  assert_grep "Paint the fence" "$home/inbox/meeting-call-$stamp-start" "a clear grounded action from the call starts"
  assert_grep "Order the cheapest shed (waits because someone other than the captain said it" "$home/inbox/meeting-call-$stamp-review" "an order from the call audio is not the owner's"
  assert_grep 'from the call "Call ' "$home/inbox/meeting-call-$stamp-start" "the note says it came from a call"
  assert_grep "with its end-of-call notes" "$home/inbox/meeting-call-$stamp-start" "and that the notes were read"
  assert_grep "The call settled the shed plan." "$(ls "$home"/model/prompt.*)" "the model reads the end-of-call summary"
  assert_grep "- Compare the shed kits" "$(ls "$home"/model/prompt.*)" "and the notes' active next steps"
  assert_no_grep "Paint the fence" "$(ls "$home"/model/prompt.*)" "but not a withdrawn one"
  assert_grep "Sam: Let us compare three shed kits. Firstmate, do it: compare the shed kits." "$(ls "$home"/model/prompt.*)" "consecutive lines by one speaker read as one turn"
  assert_grep "recording started" "$home/data/calls/archive/$stamp-transcript.txt" "the archive is left as it was"
  assert_grep '"source": "call-recorder"' "$home/data/meetings/call-$stamp/intake.json" "the record names the source"
  assert_grep '"origin": "call"' "$home/data/meetings/call-$stamp/intake.json" "and how it was captured"
  out=$(run "$home" 400 recall shed kits)
  assert_contains "$out" "Call " "recall finds the call"
  assert_contains "$out" "Follow-up started: Spoken order: Compare the shed kits" "and what started from it"
  pass "fm-meetings: calls archived by the call recorder feed the same intake, with the owner's label as the owner"
}

test_call_without_notes_waits_ten_minutes_and_exclusion_applies() {
  local home out stamp
  home=$(new_home calls-no-notes)
  printf 'enabled = true\nexclude_word = Acme\n' > "$home/config/meetings"
  baseline "$home"
  stamp=$(stamp_at -60)
  NO_NOTES=1 archived_call "$home" "$stamp" "[10:00:05] me: Let us compare three shed kits."
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a call whose notes are not in yet waits"
  assert_equals waiting "$(phase_of "$home" "call-$stamp")" "and is tracked"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "it keeps waiting while the notes may still come"
  out=$(run "$home" 700 check)
  assert_contains "$out" "ready: Call " "after ten minutes it goes ahead without notes"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 760 intake)
  assert_contains "$out" "0 clear follow-up(s) to start, 0 for the captain's decision" "the call is taken in from its transcript alone"
  assert_grep "notes never came" "$home/data/meetings/call-$stamp/intake.json" "the record says the notes never came"

  home=$(new_home calls-excluded)
  printf 'enabled = true\nexclude_word = Acme\n' > "$home/config/meetings"
  baseline "$home"
  stamp=$(stamp_at -900)
  archived_call "$home" "$stamp" "[10:00:05] me: The Acme launch slips a week."
  run "$home" 0 check >/dev/null
  out=$(run "$home" 60 intake)
  assert_contains "$out" "excluded meeting, not processed: Call " "an exclude word in a call's transcript excludes it"
  assert_absent "$home/model/calls" "an excluded call never reaches the model"
  pass "fm-meetings: a call without notes waits ten minutes, and exclusion applies to calls"
}

test_both_sources_run_together() {
  local home out stamp
  home=$(new_home both)
  printf 'enabled = true\nsource = anarlog\nsource = call-recorder\n' > "$home/config/meetings"
  baseline "$home"
  touch "$home/anarlog/list-fails"
  stamp=$(stamp_at -900)
  archived_call "$home" "$stamp" "[10:00:05] me: Hello."
  out=$(run "$home" 0 check)
  assert_contains "$out" "1 meeting(s) ready for intake" "a broken source does not stop the other"
  assert_contains "$out" "ready: Call " "and the call is named"
  assert_contains "$out" "anarlog cannot be read" "and the broken source is named"
  out=$(run "$home" 0 status)
  assert_contains "$out" "intake: on; sources: anarlog, call-recorder" "status names every configured source"
  assert_contains "$out" "call-recorder" "and the call's source"
  pass "fm-meetings: configured sources run together, each reported on its own"
}

# real_inbox <home> <now-offset> <args...>: run the subject against the real inbox.
real_inbox() {
  local home=$1 offset=$2
  shift 2
  env FM_MEETINGS_INBOX="$ROOT/bin/fm-inbox.sh" FM_HOME="$home" FM_MEETINGS_NOW=$((NOW + offset)) \
    FM_MEETINGS_ANARLOG="$FAKES/anarlog" FAKE_ANARLOG_DIR="$home/anarlog" \
    FM_MEETINGS_CLAUDE="$FAKES/claude" FAKE_MODEL_DIR="$home/model" FAKE_MODEL_OUTPUT="$home/model/output.json" \
    FM_MEETINGS_SPEAK="$FAKES/speak" FAKE_SPOKEN="$home/spoken.txt" "$SUBJECT" "$@"
}

# call_notes <home> <stamp>: the inbox notes the intake filed for that call.
call_notes() {
  grep -rl "^request_id=meeting-call-$2-" "$1/state/inbox" 2>/dev/null
}

test_deleting_a_call_removes_what_the_intake_kept() {
  local home out stamp other start
  home=$(new_home consent)
  printf 'enabled = true\n' > "$home/config/meetings"
  baseline "$home"
  touch "$home/state/.afk"
  stamp=$(stamp_at -900)
  other=$(stamp_at -800)
  archived_call "$home" "$stamp" "[10:00:05] me: Let us compare three shed kits."
  archived_call "$home" "$other" "[10:00:05] me: Let us compare three shed kits again."
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[{"title":"Compare shed kits","instruction":"Compare three shed kits","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},{"title":"Email the builder","instruction":"Email the builder","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[]}'
  out=$(real_inbox "$home" 60 intake)
  assert_contains "$out" "1 clear follow-up(s) to start, 1 for the captain's decision" "both calls are taken in"
  assert_equals 2 "$(call_notes "$home" "$stamp" | grep -c .)" "the call has a start and a review note"
  start=$(basename "$(grep -rl "^request_id=meeting-call-$stamp-start" "$home/state/inbox")" .note)
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$start" >/dev/null
  out=$(FM_HOME="$home" CALL_COMPANION_OPEN_BIN=true "$ROOT/bin/fm-call-companion.sh" delete "$stamp" 2>&1) \
    || fail "deleting the call failed: $out"
  assert_contains "$out" "deleted archived call $stamp" "the call is deleted"
  assert_contains "$out" "removed the meeting intake's record and inbox notes of call-$stamp" "and the delete says the intake's copies went too"
  assert_absent "$home/data/meetings/call-$stamp" "the intake record of the deleted call is gone"
  assert_equals "" "$(call_notes "$home" "$stamp")" "its inbox notes are gone, acknowledged or not"
  assert_equals "" "$(phase_of "$home" "call-$stamp")" "the check no longer tracks it"
  assert_present "$home/data/meetings/call-$other/intake.json" "another call's intake record stays"
  assert_equals 2 "$(call_notes "$home" "$other" | grep -c .)" "and so do its notes"
  run "$home" 120 check >/dev/null
  assert_equals "" "$(phase_of "$home" "call-$stamp")" "the next check does not bring it back"
  out=$(FM_HOME="$home" CALL_COMPANION_OPEN_BIN=true "$ROOT/bin/fm-call-companion.sh" delete --all 2>&1) \
    || fail "deleting every call failed: $out"
  assert_absent "$home/data/meetings/call-$other" "deleting every call removes every call's intake record"
  assert_equals "" "$(call_notes "$home" "$other")" "and every call's notes"
  out=$(run "$home" 180 recall shed kits)
  assert_equals "no meeting matches shed kits" "$out" "recall no longer answers from a deleted call"
  pass "fm-meetings: deleting a call removes the intake's record and notes of it"
}

test_notes_land_in_the_real_inbox() {
  local home out
  home=$(new_home real-inbox)
  baseline "$home"
  # An away record keeps the real inbox from ringing a primary pane that a
  # scratch home does not have; the note and its wake are still written.
  touch "$home/state/.afk"
  meeting "$home" '{"id":"m-real","title":"Garden planning","ended":-900,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[{"title":"Compare shed kits","instruction":"Compare three shed kits","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[]}'
  out=$(real_inbox "$home" 60 intake)
  assert_contains "$out" "Garden planning: 1 clear follow-up(s) to start" "the intake ran against the real inbox"
  assert_grep "request_id=meeting-m-real-start" "$(ls "$home"/state/inbox/*.note)" "the start note is a durable inbox note keyed by meeting"
  assert_grep "Meeting follow-ups ready to start" "$(ls "$home"/state/inbox/*.note)" "the note opens with the line the skill is loaded on"
  assert_grep "inbox" "$home/state/.wake-queue" "the note wakes firstmate"
  pass "fm-meetings: follow-ups land in the real inbox as durable, waking notes"
}

test_example_config_is_accepted_and_typos_refused() {
  local home out rc=0
  home=$(new_home config)
  cp "$ROOT/docs/examples/meetings" "$home/config/meetings"
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 0 "$rc" "the shipped example config is accepted: $out"
  assert_contains "$out" "intake: off" "the shipped example leaves the intake off"
  printf 'speaker_pas = off\n' >> "$home/config/meetings"
  rc=0
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown key is refused"
  assert_contains "$out" "unknown key speaker_pas" "the refused key is named"
  pass "fm-meetings: the example config is accepted and a typo is refused"
}

test_layer_only_reads_anarlog_and_imports() {
  local home
  for home in "$TMP_ROOT"/*/anarlog; do
    [ -f "$home/calls.log" ] || continue
    if grep -v -E '^(--json )?(doctor|meetings --source local (list|get|export|import|import-status)( |$))' "$home/calls.log" >/dev/null; then
      fail "the layer called Anarlog outside its read and import commands: $(grep -v -E '^(--json )?(doctor|meetings --source local (list|get|export|import|import-status)( |$))' "$home/calls.log" | head -1)"
    fi
  done
  pass "fm-meetings: the layer only reads Anarlog and asks it to import recordings"
}

fm_test_run \
  test_help_and_usage \
  test_intake_is_off_until_config_enables_it \
  test_arm_binds_the_check_and_disarm_removes_it \
  test_meetings_before_arming_are_left_alone \
  test_native_batch_meeting_is_announced_once \
  test_meeting_whose_first_read_fails_is_retried \
  test_capture_pending_and_missing_summary_wait \
  test_live_only_meeting_gets_a_speaker_pass \
  test_spoken_order_evidence_from_the_live_copy_credits_the_captain \
  test_spoken_order_also_listed_as_an_action_is_filed_once \
  test_action_said_alongside_a_spoken_order_is_kept \
  test_action_whose_quote_holds_a_spoken_order_is_kept \
  test_ready_meeting_is_announced_again_until_taken_in \
  test_wake_line_keeps_the_command_and_problems_whatever_the_titles \
  test_speaker_pass_falls_back_to_the_live_transcript \
  test_excluded_meeting_is_never_processed \
  test_intake_sorts_clear_actions_from_review_items \
  test_outward_instructions_wait_whatever_the_model_says \
  test_failed_intake_stays_ready \
  test_imported_recordings_flow_into_the_same_intake \
  test_unreadable_source_or_config_is_reported_once \
  test_recall_answers_from_included_meetings_only \
  test_archived_calls_feed_the_intake \
  test_call_without_notes_waits_ten_minutes_and_exclusion_applies \
  test_both_sources_run_together \
  test_deleting_a_call_removes_what_the_intake_kept \
  test_notes_land_in_the_real_inbox \
  test_example_config_is_accepted_and_typos_refused \
  test_layer_only_reads_anarlog_and_imports

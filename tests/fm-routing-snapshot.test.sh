#!/usr/bin/env bash
# Behavior tests for bin/fm-routing-snapshot.sh: the roster labels and profiles
# from config/crew-dispatch.json, the newest dispatch decisions from
# state/dispatch-decisions.jsonl (malformed lines skipped), and per-record
# kind and model from state/<id>.meta - with no task description, brief text,
# or write leaving the read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-routing-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-routing-snapshot)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data/ship-a"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

snapshot() { FM_HOME="$HOME_DIR" "$TOOL" --json; }
fingerprint() { (cd "$HOME_DIR" && find . -type f -print | LC_ALL=C sort | xargs cksum); }

# --- empty home: valid model, empty sections -----------------------------------
out=$(snapshot) || fail "empty home exits non-zero"
assert_equals 'fm-routing.v1' "$(jq -r .schema <<<"$out")" "schema"
assert_equals '0 0 0 null' "$(jq -r '"\(.roster | length) \(.decisions | length) \(.workers | length) \(.roster_error)"' <<<"$out")" "empty home has empty sections and no error"
pass "an empty home yields an empty fm-routing.v1 model"

# --- roster labels and profiles ------------------------------------------------------
cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "rules": [
    { "when": "COURSE WRITING: drafts and assignments under data/course.", "use": { "harness": "claude", "model": "claude-fable-5-1", "effort": "medium" }, "why": "SECRET-WHY" },
    { "when": "Different-vendor HOSTILE read for HIGH-STAKES calls only (architecture, security).", "use": { "harness": "cursor", "model": "grok-4.7-xhigh" } },
    { "when": "Implementation, validation, difficult debugging, security-sensitive review, or integration work that needs the strongest model.",
      "use": [ { "harness": "claude", "model": "opus", "effort": "high" }, { "harness": "codex", "model": "gpt-5.6-sol", "provider": "codex" } ] },
    { "when": "A short rule.", "use": { "harness": "claude" } }
  ],
  "default": { "harness": "claude", "model": "opus", "effort": "high" }
}
JSON
out=$(snapshot)
assert_equals 'rule_1|COURSE WRITING' "$(jq -r '.roster[0] | "\(.rule)|\(.label)"' <<<"$out")" "a label stops at the first colon"
assert_equals 'Different-vendor HOSTILE read for HIGH-STAKES calls only' "$(jq -r '.roster[1].label' <<<"$out")" "a label stops at the first parenthesis"
assert_equals 'Implementation, validation, difficult debugging…' "$(jq -r '.roster[2].label' <<<"$out")" "a long label is cut at a word boundary with an ellipsis"
assert_equals 'A short rule' "$(jq -r '.roster[3].label' <<<"$out")" "a short label drops its full stop"
assert_equals '[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":null}]' "$(jq -c '.roster[2].profiles' <<<"$out")" "profile arrays keep harness, model, and effort only"
assert_equals 'default|default|opus' "$(jq -r '.roster[-1] | "\(.rule)|\(.label)|\(.profiles[0].model)"' <<<"$out")" "the default closes the roster"
assert_not_contains "$out" 'SECRET-WHY' "why text never reaches the snapshot"
printf '{not json' > "$HOME_DIR/config/crew-dispatch.json.bad"
FM_CONFIG_OVERRIDE="$TMP_ROOT/badcfg" snapshot >/dev/null || fail "an absent override config must not fail"
mkdir -p "$TMP_ROOT/badcfg"
cp "$HOME_DIR/config/crew-dispatch.json.bad" "$TMP_ROOT/badcfg/crew-dispatch.json"
bad=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/badcfg" snapshot) || fail "a malformed rules file must not fail the snapshot"
assert_equals '0|rules file is unreadable or malformed' "$(jq -r '"\(.roster | length)|\(.roster_error)"' <<<"$bad")" "a malformed rules file is reported, not hidden"
pass "the roster carries short labels and use profiles, and reports a malformed rules file"

# --- decisions: newest first, bounded, malformed lines skipped ------------------------
{
  printf '%s\n' '{"at":1000,"task":"old-a","status":"clear","rule":"rule_1","rule_when":"COURSE WRITING: drafts and assignments under data/course.","p":0.7,"profile":{"harness":"claude","model":"claude-fable-5-1","effort":"medium"}}'
  printf '%s\n' 'not json at all'
  printf '%s\n' '{"at":"bad","task":"x"}'
  printf '%s\n' '{"at":2000,"task":"mid-b","status":"ambiguous","rule":"rule_3","rule_when":"Implementation, validation, difficult debugging, security-sen","p":0.41,"profile":null}'
  printf '%s\n' '{"at":3000,"task":"new-c","status":"clear","rule":"default","rule_when":"No listed rule applies to this task.","p":1.7,"profile":{"harness":"claude","model":"opus","effort":"high"}}'
} > "$HOME_DIR/state/dispatch-decisions.jsonl"
out=$(snapshot)
assert_equals 'new-c,mid-b,old-a' "$(jq -r '[.decisions[].task] | join(",")' <<<"$out")" "decisions are newest first and malformed lines are skipped"
assert_equals 'default|null' "$(jq -r '.decisions[0] | "\(.label)|\(.p)"' <<<"$out")" "default reads as default and an out-of-range probability is dropped"
assert_equals 'Implementation, validation, difficult debugging…|0.41|null' "$(jq -r '.decisions[1] | "\(.label)|\(.p)|\(.profile)"' <<<"$out")" "a cut rule excerpt gains an ellipsis; a non-clear decision has no profile"
assert_equals 'COURSE WRITING|claude-fable-5-1' "$(jq -r '.decisions[2] | "\(.label)|\(.profile.model)"' <<<"$out")" "the chosen profile is kept"
for at in 4000 5000 6000; do
  printf '{"at":%s,"task":"later-%s","status":"clear","rule":"default","p":0.9,"profile":null}\n' "$at" "$at" >> "$HOME_DIR/state/dispatch-decisions.jsonl"
done
out=$(snapshot)
assert_equals 'later-6000,later-5000,later-4000,new-c,mid-b' "$(jq -r '[.decisions[].task] | join(",")' <<<"$out")" "the list holds the newest five decisions"
pass "recent decisions are newest first, bounded, and tolerant of malformed lines"

# --- workers: model_live wins, spawn time from spawn_gen, outcome never read ---------
fm_write_meta "$HOME_DIR/state/ship-a.meta" \
  "kind=ship" "harness=claude" "model=opus" "effort=high" "task_type=implementation" \
  "spawn_gen=s1790000000.123.456" "outcome=PRIVATE-OUTCOME-TEXT"
fm_write_meta "$HOME_DIR/state/scout-b.meta" \
  "kind=scout" "harness=cursor" "model=grok-4.7-xhigh" "model_live=grok-4.7-high" "effort=default"
printf '# Task\nPRIVATE-BRIEF-TEXT\n' > "$HOME_DIR/data/ship-a/brief.md"
before=$(fingerprint)
out=$(snapshot)
after=$(fingerprint)
assert_equals "$before" "$after" "the snapshot writes nothing"
assert_equals '["effort","id","kind","model","started"]' "$(jq -c '.workers[] | select(.id == "ship-a") | keys' <<<"$out")" "a worker carries only id, kind, model, effort, and spawn time"
assert_equals 'ship|opus|high|1790000000' "$(jq -r '.workers[] | select(.id == "ship-a") | "\(.kind)|\(.model)|\(.effort)|\(.started)"' <<<"$out")" "a ship record carries kind, model, effort, and spawn time"
assert_equals 'grok-4.7-high|null' "$(jq -r '.workers[] | select(.id == "scout-b") | "\(.model)|\(.started)"' <<<"$out")" "model_live wins and absent fields are null"
assert_not_contains "$out" 'PRIVATE-OUTCOME-TEXT' "a record's outcome never reaches the snapshot"
assert_not_contains "$out" 'PRIVATE-BRIEF-TEXT' "brief text never reaches the snapshot"
pass "workers come from task records without their outcome or brief"

# --- usage -----------------------------------------------------------------------------
FM_HOME="$HOME_DIR" "$TOOL" --bogus >/dev/null 2>&1
expect_code 2 "$?" "unknown argument exits 2"
help=$("$TOOL" --help) || fail "--help exits non-zero"
assert_contains "$help" 'fm-routing.v1' "--help documents the schema"
pass "usage errors exit 2 and --help prints the header"

printf '# all fm-routing-snapshot tests passed\n'

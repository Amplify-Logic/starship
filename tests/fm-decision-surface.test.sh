#!/usr/bin/env bash
# End-to-end tests for the private Lavish captain-decision surface.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SURFACE="$ROOT/bin/fm-decision-surface.sh"
DECISIONS="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-surface)
HOME_DIR="$TMP_ROOT/home"
PAGE="$HOME_DIR/.lavish/captain-decisions.html"
ANSWERS="$HOME_DIR/.lavish/captain-decisions.answers.json"
FAKEBIN="$HOME_DIR/fakebin"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

run_tasks() {
  (cd "$HOME_DIR" && tasks-axi "$@")
}

run_decisions() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$DECISIONS" "$@"
}

write_origin() {
  local id=$1 repo=$2
  run_tasks add "$id" "Inspect $id" --kind scout --repo "$repo" --start >/dev/null
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=sample:$id" \
    "worktree=$HOME_DIR/projects/$repo" \
    "project=$HOME_DIR/projects/$repo" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
}

write_origin sample-route-review sample
write_origin sample-access-review another-sample
route_hold=$(run_decisions hold sample-route-review route \
  --title "Choose the sample route" \
  --reason "Choose: route north; OR route south. Recommendation: route north." \
  --repo sample) || fail "could not create route decision"
access_hold=$(run_decisions hold sample-access-review access \
  --title "Choose open vs restricted sample access" \
  --reason "Choose open vs restricted access; restricted access is safer." \
  --repo another-sample) || fail "could not create access decision"
run_decisions complete sample-route-review route >/dev/null || fail "could not complete route inventory"
run_decisions complete sample-access-review access >/dev/null || fail "could not complete access inventory"
run_tasks add legacy-captain-call "Confirm a legacy captain call" --kind captain --repo legacy >/dev/null
run_tasks hold legacy-captain-call --reason "Legacy call pending" --kind captain >/dev/null

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > "$HOME_DIR/generate.out"
assert_grep "generated: 3 captain decisions (tasks-axi count: 3)" "$HOME_DIR/generate.out" \
  "generator count did not reconcile with tasks-axi"
assert_present "$PAGE" "generator did not write the private page"

node - "$PAGE" "$route_hold" "$access_hold" <<'NODE' || fail "generated manifest/page contract failed"
const fs = require("node:fs");
const [page, routeHold, accessHold] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const match = html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s);
if (!match) process.exit(1);
const manifest = JSON.parse(match[1]);
if (manifest.count !== 3 || manifest.decisions.length !== 3) process.exit(2);
const route = manifest.decisions.find((item) => item.id === routeHold);
const access = manifest.decisions.find((item) => item.id === accessHold);
if (!route || route.reason !== "Choose: route north; OR route south. Recommendation: route north.") process.exit(3);
if (JSON.stringify(route.options) !== JSON.stringify(["route north", "route south"])) process.exit(4);
if (route.recommendation !== "route north.") process.exit(5);
if (!access || access.group !== "another-sample") process.exit(6);
if (!html.includes("Firstmate recommendation - advisory, not decided")) process.exit(7);
if (!html.includes("No explicit recommendation is recorded in the backlog.")) process.exit(8);
if (/https?:\/\//.test(html) || /<link\b[^>]*href=/.test(html) || /<script\b[^>]*src=/.test(html)) process.exit(9);
NODE
pass "generator reconciles every captain hold and renders reason, options, recommendation, and groups"

# A long two-line card title must keep clear separation from the identity element under it.
assert_grep "h3 { margin:.5rem 0 .2rem; font-size:clamp(1.4rem,3vw,2rem); line-height:1.34; padding-bottom:4px; }" \
  "$PAGE" "generated stylesheet lost the card heading overlap remedy"

marker=$(node - "$PAGE" "$route_hold" <<'NODE'
const fs = require("node:fs");
const [page, holdId] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const manifest = JSON.parse(html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s)[1]);
const decision = manifest.decisions.find((item) => item.id === holdId);
const payload = {version:1, hold_id:decision.id, origin_id:decision.origin, decision_key:decision.key, answer:"route south", answer_type:"option"};
const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
process.stdout.write(`FM_DECISION_ANSWER_V1:${encoded}`);
NODE
) || fail "could not create synthetic Lavish mark"
cat > "$FAKEBIN/lavish-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = poll ]; then
  printf 'session:\n  status: feedback\nprompts[1]:\n  - prompt: "Captain decision answer: route south\\n$marker"\n'
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/lavish-axi"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  "$SURFACE" poll > "$HOME_DIR/poll.out"
assert_grep "captured: 1 unambiguous answer" "$HOME_DIR/poll.out" "poll did not capture the marked answer"
assert_grep "$route_hold: route south" "$HOME_DIR/poll.out" "poll discarded the chosen option text"
[ "$(jq -r '.accepted[0].chosen_option' "$ANSWERS")" = "route south" ] \
  || fail "answers file did not retain the exact option"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" route > "$HOME_DIR/dry-run.out"
jq -e '.applied == false and .results[0].status == "dry-run" and .results[0].would_create == true' \
  "$HOME_DIR/dry-run.out" >/dev/null || fail "route dry-run did not prove the planned dependent and resolve call"
show=$(run_tasks show "$route_hold" --full)
assert_contains "$show" "state: queued" "dry-run resolved the hold"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" route --apply > "$HOME_DIR/route.out"
route_id=$(jq -r '.results[0].routed_to[0]' "$HOME_DIR/route.out")
[ -n "$route_id" ] && [ "$route_id" != null ] || fail "route did not report dependent identity"
show=$(run_tasks show "$route_hold" --full)
assert_contains "$show" "state: done" "resolve contract did not close the answered hold"
assert_contains "$show" "Chosen option: route south" "resolve contract lost the selected option text"
show=$(run_tasks show "$route_id" --full)
assert_contains "$show" "blocked: no" "resolve contract did not clear the dependency edge"
assert_contains "$show" "Chosen option: route south" "dependent work did not retain the selected option text"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" route --apply > "$HOME_DIR/route-retry.out"
jq -e --arg route "$route_id" '
  .results[0].status == "resolved"
    and .results[0].would_create == false
    and .results[0].routed_to == [$route]
' "$HOME_DIR/route-retry.out" >/dev/null || fail "identical route retry was not idempotent"

run_tasks rm "$route_id" >/dev/null || fail "could not remove scratch routed work"
run_tasks rm "$route_hold" >/dev/null || fail "could not remove scratch resolved hold"
run_tasks rm sample-route-review >/dev/null || fail "could not remove scratch origin"
if run_tasks show "$route_hold" --full >/dev/null 2>&1; then fail "scratch hold remained after removal"; fi
pass "Lavish mark polls to exact text and routes through resolve before scratch cleanup"

# A forged choice that was not on the rendered page must stay unresolved.
forged=$(node - "$PAGE" "$access_hold" <<'NODE'
const fs = require("node:fs");
const [page, holdId] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const manifest = JSON.parse(html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s)[1]);
const decision = manifest.decisions.find((item) => item.id === holdId);
const payload = {version:1, hold_id:decision.id, origin_id:decision.origin, decision_key:decision.key, answer:"guessed route", answer_type:"option"};
process.stdout.write(`FM_DECISION_ANSWER_V1:${Buffer.from(JSON.stringify(payload)).toString("base64url")}`);
NODE
)
cat > "$FAKEBIN/lavish-axi" <<EOF
#!/usr/bin/env bash
printf 'prompt: "$forged"\n'
EOF
chmod +x "$FAKEBIN/lavish-axi"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  "$SURFACE" poll > "$HOME_DIR/ambiguous.out"
assert_grep "captured: 0 unambiguous answers" "$HOME_DIR/ambiguous.out" "forged option was accepted"
assert_grep "selected option is not present" "$HOME_DIR/ambiguous.out" "ambiguous mark was not explained"
show=$(run_tasks show "$access_hold" --full)
assert_contains "$show" "state: queued" "ambiguous mark resolved a hold"
pass "ambiguous or forged marks remain unresolved"

rm -rf "$TMP_ROOT"

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

# A captain-kind row held as `future` (with or without a date) is not a captain
# decision, and a captain call deferred with --until is still one; neither may
# stop the page from being rewritten.
run_tasks add later-undated "Revisit an undated follow-up" --kind captain --repo sample >/dev/null
run_tasks hold later-undated --reason "Own follow-up later" --kind future >/dev/null
run_tasks add later-dated "Revisit a dated follow-up" --kind captain --repo sample >/dev/null
run_tasks hold later-dated --reason "Own follow-up checkpoint" --kind future --until 2099-01-01 >/dev/null
run_tasks add deferred-call "Choose a deferred sample call" --kind captain --repo sample >/dev/null
run_tasks hold deferred-call --reason "Choose: keep vs drop" --kind captain --until 2099-01-01 >/dev/null
run_tasks add later-unrecorded "Revisit an unrecorded hold" --kind captain --repo sample >/dev/null
run_tasks hold later-unrecorded --reason "Held without a kind" >/dev/null
printf 'stale page\n' > "$PAGE"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > "$HOME_DIR/future.out" 2> "$HOME_DIR/future.err" \
  || fail "generate aborted on a future-kind hold: $(cat "$HOME_DIR/future.err")"
assert_grep "generated: 3 captain decisions (tasks-axi count: 6)" "$HOME_DIR/future.out" \
  "generator did not reconcile skipped rows with tasks-axi"
assert_grep "skipped: later-unrecorded is held as an unrecorded kind, not for a captain decision" "$HOME_DIR/future.out" \
  "a hold without a recorded kind was not labelled as unrecorded"
if grep -q "not shown:" "$HOME_DIR/future.out"; then fail "future-kind holds were reported as captain decisions that could not be shown"; fi
assert_grep "skipped: later-undated is held as future, not for a captain decision" "$HOME_DIR/future.out" \
  "undated future hold was not reported as skipped"
assert_grep "skipped: later-dated is held as future, not for a captain decision" "$HOME_DIR/future.out" \
  "dated future hold was not reported as skipped"
node - "$PAGE" "$access_hold" <<'NODE' || fail "page after future-kind holds did not list exactly the captain decisions"
const fs = require("node:fs");
const [page, accessHold] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const match = html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s);
if (!match) process.exit(1);
const manifest = JSON.parse(match[1]);
const ids = manifest.decisions.map((item) => item.id).sort();
if (JSON.stringify(ids) !== JSON.stringify([accessHold, "deferred-call", "legacy-captain-call"].sort())) process.exit(2);
if (manifest.count !== 3) process.exit(3);
if (manifest.unshown.length !== 0 || html.includes('class="unshown"')) process.exit(4);
NODE
pass "future-kind holds are skipped silently on the page and a deferred captain call still renders"

# One row that cannot be read is left off the cards but named on the page and in
# the generate output instead of aborting the page.
REAL_TASKS_AXI=$(command -v tasks-axi)
ODD_BIN="$TMP_ROOT/oddbin"
mkdir -p "$ODD_BIN"
cat > "$ODD_BIN/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = legacy-captain-call ]; then
  echo "error: unreadable row" >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "\$@"
EOF
chmod +x "$ODD_BIN/tasks-axi"
PATH="$ODD_BIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > "$HOME_DIR/odd.out" 2>&1 \
  || fail "generate aborted on one unreadable row: $(cat "$HOME_DIR/odd.out")"
assert_grep "generated: 2 captain decisions (tasks-axi count: 6)" "$HOME_DIR/odd.out" \
  "unreadable row was not excluded from the rendered decisions"
assert_grep "not shown: legacy-captain-call could not be read" "$HOME_DIR/odd.out" \
  "generate output did not name the decision that could not be shown"
node - "$PAGE" <<'NODE' || fail "page did not name the decision that could not be shown"
const fs = require("node:fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const manifest = JSON.parse(html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s)[1]);
if (manifest.decisions.some((item) => item.id === "legacy-captain-call")) process.exit(1);
if (JSON.stringify(manifest.unshown.map((item) => item.id)) !== JSON.stringify(["legacy-captain-call"])) process.exit(2);
const notice = html.match(/<section class="unshown" role="alert">(.*?)<\/section>/s);
if (!notice || !notice[1].includes("1 captain decision could not be shown") || !notice[1].includes("<code>legacy-captain-call</code>")) process.exit(3);
if (html.indexOf('class="unshown"') > html.indexOf('class="decision-card"')) process.exit(4);
NODE
pass "one unreadable row is named on the page and in the output while the page is still rewritten"

# `open` and `route --apply` refuse a page older than the newest generate attempt.
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > /dev/null || fail "could not regenerate the page"
access_marker=$(node - "$PAGE" "$access_hold" <<'NODE'
const fs = require("node:fs");
const [page, holdId] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const manifest = JSON.parse(html.match(/<script id="fm-decision-data" type="application\/json">(.*?)<\/script>/s)[1]);
const decision = manifest.decisions.find((item) => item.id === holdId);
const payload = {version:1, hold_id:decision.id, origin_id:decision.origin, decision_key:decision.key, answer:"restricted access", answer_type:"custom"};
process.stdout.write(`FM_DECISION_ANSWER_V1:${Buffer.from(JSON.stringify(payload)).toString("base64url")}`);
NODE
) || fail "could not create the access answer mark"
cat > "$FAKEBIN/lavish-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = poll ]; then
  printf 'prompt: "$access_marker"\n'
  exit 0
fi
printf '%s\n' "\$*" >> "$HOME_DIR/lavish-open.log"
EOF
chmod +x "$FAKEBIN/lavish-axi"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" "$SURFACE" open > /dev/null \
  || fail "open refused a freshly generated page"
assert_grep "$PAGE" "$HOME_DIR/lavish-open.log" "open did not hand the fresh page to Lavish"
FAIL_BIN="$TMP_ROOT/failbin"
mkdir -p "$FAIL_BIN"
printf '#!/usr/bin/env bash\necho "error: backlog unavailable" >&2\nexit 1\n' > "$FAIL_BIN/tasks-axi"
chmod +x "$FAIL_BIN/tasks-axi"
if PATH="$FAIL_BIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > /dev/null 2>&1; then
  fail "generate reported success while the backlog could not be read"
fi
: > "$HOME_DIR/lavish-open.log"
if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  "$SURFACE" open > /dev/null 2> "$HOME_DIR/open-stale.err"; then
  fail "open showed a page older than the failed generate attempt"
fi
assert_grep "older than the last generate attempt" "$HOME_DIR/open-stale.err" "open refusal did not explain the stale page"
[ ! -s "$HOME_DIR/lavish-open.log" ] || fail "open launched Lavish on a stale page"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  "$SURFACE" poll > "$HOME_DIR/poll-stale.out" 2> "$HOME_DIR/poll-stale.err" \
  || fail "poll stopped reading answers from a stale page: $(cat "$HOME_DIR/poll-stale.err")"
assert_grep "captured: 1 unambiguous answer" "$HOME_DIR/poll-stale.out" "poll did not read the answer from a stale page"
assert_grep "warning: this page is older than the last generate attempt" "$HOME_DIR/poll-stale.err" \
  "poll did not warn that the page is stale"
[ "$(grep -c . "$HOME_DIR/poll-stale.err")" = 1 ] || fail "poll stale warning was not one line"
if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" route --apply > /dev/null 2> "$HOME_DIR/route-stale.err"; then
  fail "route --apply resolved answers from a page older than the failed generate attempt"
fi
assert_grep "refusing route --apply: this decision page is older than the last generate attempt" "$HOME_DIR/route-stale.err" \
  "route --apply refusal did not explain the stale page"
show=$(run_tasks show "$access_hold" --full)
assert_contains "$show" "state: queued" "route --apply resolved a hold from a stale page"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$SURFACE" generate > /dev/null || fail "recovery generate failed"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" "$SURFACE" open > /dev/null \
  || fail "open still refused after a successful generate"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  "$SURFACE" poll > /dev/null 2> "$HOME_DIR/poll-fresh.err" || fail "poll failed on a fresh page"
[ ! -s "$HOME_DIR/poll-fresh.err" ] || fail "poll warned about a fresh page: $(cat "$HOME_DIR/poll-fresh.err")"
pass "open and route --apply refuse, and poll warns, while the last generate attempt is unfinished"

rm -rf "$TMP_ROOT"

#!/usr/bin/env bash
# End-to-end tests for the phone tap desk: card export, tap read-back routing,
# refusals, saved reasons, and the seven-day easy-to-undo default.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESK="$ROOT/bin/fm-tap-desk.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-tap-desk)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

HOME_DIR=''
FAKEBIN=''

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  FAKEBIN="$HOME_DIR/fakebin"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  # A gh that knows no pull request, unless a case installs its own.
  printf '#!/usr/bin/env bash\necho "no such pull request" >&2\nexit 1\n' > "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
}

home_env() {
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

desk() { home_env "$DESK" "$@"; }
hold() { home_env "$HOLD" "$@"; }
tasks() { home_env "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
identity_of() { hold open "$1" --identity; }
cards_json() { cat "$HOME_DIR/data/tap-desk/cards.json"; }

# Backdate a hold by rewriting its leading hold-set stamp, the way an old hold reads.
backdate_hold() {  # <task-id> <stamp>
  local body
  body=$(tasks show "$1" --full | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const m = s.match(/^  body: (.*)$/m); process.stdout.write(m ? JSON.parse(m[1]) : "");
    });')
  printf '%s\n' "$body" | sed "1s/^Captain hold set: .*/Captain hold set: $2/" > "$HOME_DIR/body.txt"
  tasks update "$1" --body-file "$HOME_DIR/body.txt" >/dev/null
}

write_tap() {  # <dir> <key> <kind> <id> <identity> <choice> [option] [reason] [pr]
  mkdir -p "$1"
  node -e '
    const [file, card, kind, id, identity, choice, option, reason, pr] = process.argv.slice(1);
    const tap = { card, kind, id, identity, choice, option, pr, reason, tapped_at: new Date().toISOString() };
    require("node:fs").writeFileSync(file, JSON.stringify({ id: card, version: 2, data: tap }));
  ' "$1/$2.json" "$2" "$3" "$4" "$5" "$6" "${7:-}" "${8:-}" "${9:-}"
}

field() {  # <task-id> <field>
  tasks show "$1" --full | sed -n "s/^  $2: //p" | head -1
}

test_export_lists_decisions_and_ready_merges() {
  new_home export
  hold hold pick-route --title "Choose the route" \
    --reason "Choose: route north; OR route south. Recommendation: route north." --repo sample >/dev/null \
    || fail "could not hold the question"
  tasks add work-a "Build the widget" --kind ship --repo sample >/dev/null
  hold hold work-a --reason "Waiting on the owner" >/dev/null || fail "could not hold the work item"
  tasks add work-later "Later idea" --kind ship --repo sample >/dev/null
  tasks hold work-later --reason "someday" --kind future >/dev/null
  # A call the owner deferred to a date is not one of his calls.
  hold hold revisit --title "Revisit the pricing" --reason "Choose: keep; OR raise." --repo sample --until 2999-01-01 >/dev/null \
    || fail "could not hold the deferred question"
  tasks add ship-pr "Ship the fix" --kind ship --repo sample >/dev/null
  tasks add ship-draft "Draft fix" --kind ship --repo sample >/dev/null
  tasks add ship-merged "Merged fix" --kind ship --repo sample >/dev/null
  tasks add ship-validating "Still validating" --kind ship --repo sample >/dev/null
  tasks add ship-red "Red checks" --kind ship --repo sample >/dev/null
  tasks add ship-rules "Rules change" --kind ship --repo sample >/dev/null
  # An unrelated project's own agent rules are not Starship's; this repository's are.
  git init -q "$HOME_DIR/unrelated"
  git -C "$HOME_DIR/unrelated" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  fm_write_meta "$HOME_DIR/state/ship-pr.meta" "kind=ship" "project=$HOME_DIR/unrelated" "pr=https://github.com/o/sample/pull/7"
  fm_write_meta "$HOME_DIR/state/ship-draft.meta" "kind=ship" "pr=https://github.com/o/sample/pull/8"
  fm_write_meta "$HOME_DIR/state/ship-merged.meta" "kind=ship" "pr=https://github.com/o/sample/pull/9"
  fm_write_meta "$HOME_DIR/state/ship-validating.meta" "kind=ship" "pr=https://github.com/o/sample/pull/10"
  fm_write_meta "$HOME_DIR/state/ship-red.meta" "kind=ship" "pr=https://github.com/o/sample/pull/11"
  fm_write_meta "$HOME_DIR/state/ship-rules.meta" "kind=ship" "project=$ROOT" "pr=https://github.com/o/sample/pull/12"
  fm_write_meta "$HOME_DIR/state/ship-nopr.meta" "kind=ship"
  # Every open PR reads as open and non-draft to gh; only the fleet reader
  # says which of them is ready.
  cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    case "$3" in
      */pull/7) echo '{"state":"OPEN","isDraft":false,"title":"Fix the widget","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","author":{"login":"Me"}}' ;;
      */pull/8) echo '{"state":"OPEN","isDraft":true,"title":"Draft","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","author":{"login":"me"}}' ;;
      */pull/9) echo '{"state":"MERGED","isDraft":false,"title":"Merged","headRefOid":"cccccccccccccccccccccccccccccccccccccccc","author":{"login":"me"}}' ;;
      */pull/10|*/pull/11) echo '{"state":"OPEN","isDraft":false,"title":"Not ready","headRefOid":"dddddddddddddddddddddddddddddddddddddddd","author":{"login":"me"}}' ;;
      */pull/12) echo '{"state":"OPEN","isDraft":false,"title":"Rules","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","author":{"login":"teammate"}}' ;;
      *) exit 1 ;;
    esac
    ;;
  "api --hostname")
    case "$*" in
      *" user "*) echo me ;;
      *pulls/7/files*) printf 'src/widget.js\nAGENTS.md\nCLAUDE.md\n' ;;
      *pulls/12/files*) printf 'src/x.js\n.agents/skills/demo/SKILL.md\nAGENTS.md\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$FAKEBIN/gh"
  cat > "$FAKEBIN/reader" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ship-validating) echo "state: working · source: run-step · ci · run: r10" ;;
  ship-red) echo "state: failed · source: run-step · ci failed · run: r11" ;;
  ship-merged) echo "state: done · source: run-step · passed · PR merged · run: r9" ;;
  *) echo "state: done · source: run-step · passed · run: r1" ;;
esac
EOF
  chmod +x "$FAKEBIN/reader"
  home_env FM_FLEET_STATE_READER="$FAKEBIN/reader" "$DESK" export > "$HOME_DIR/export.out" || fail "export failed"
  assert_grep "decisions: 2" "$HOME_DIR/export.out" "export did not count both captain calls"
  assert_grep "merges: 2" "$HOME_DIR/export.out" "export did not count only the ready merges"
  assert_grep "not shown: ship-draft:" "$HOME_DIR/export.out" "a draft PR was not named as not shown"
  assert_grep "not shown: ship-nopr: it is ready to land but records no pull request" "$HOME_DIR/export.out" \
    "ready work with no PR was not named as not shown"
  # Two decisions, two merge cards, and the draft and the PR-less ready work:
  # the same count the bridge strip and the Factory pane show.
  assert_grep "owner's calls: 6" "$HOME_DIR/export.out" "export did not report the owner's calls"
  local route_id work_id perms
  route_id=$(identity_of pick-route)
  work_id=$(identity_of work-a)
  cards_json | node -e '
    const [routeId, workId] = process.argv.slice(1);
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const doc = JSON.parse(s);
      const by = Object.fromEntries(doc.cards.map((c) => [c.key, c]));
      const check = (ok, code) => { if (!ok) { console.error(JSON.stringify(doc, null, 2)); process.exit(code); } };
      check(doc.schema === "fm-tap-cards.v1", 2);
      check(by["d.pick-route"] && by["d.pick-route"].identity === routeId, 3);
      check(JSON.stringify(by["d.pick-route"].options) === JSON.stringify(["route north", "route south"]), 4);
      check(by["d.pick-route"].closes_on_answer === true && by["d.pick-route"].easy_undo === false, 5);
      check(by["d.work-a"] && by["d.work-a"].identity === workId && by["d.work-a"].closes_on_answer === false, 6);
      check(!by["d.work-later"] && !by["d.revisit"], 7);
      check(doc.owner_calls === 6 && !("set_aside" in doc), 14);
      check(by["m.ship-pr"] && by["m.ship-pr"].identity === "a".repeat(40) && by["m.ship-pr"].pr_url === "https://github.com/o/sample/pull/7", 8);
      check(!by["m.ship-draft"] && !by["m.ship-merged"] && !by["m.ship-nopr"], 9);
      check(!by["m.ship-validating"] && !by["m.ship-red"], 10);
      check(by["m.ship-pr"].opened_by_other === false && by["m.ship-pr"].rules_files.length === 0, 11);
      const rules = by["m.ship-rules"];
      check(rules && rules.opened_by === "teammate" && rules.opened_by_other === true, 12);
      check(JSON.stringify(rules.rules_files) === JSON.stringify([".agents/skills/demo/SKILL.md", "AGENTS.md"]), 13);
    });' "$route_id" "$work_id" || fail "card file contract failed"
  assert_no_grep "__FM_TAP_CARDS__" "$HOME_DIR/data/tap-desk/page.html" "the page kept its card placeholder"
  assert_grep '"key":"d.pick-route"' "$HOME_DIR/data/tap-desk/page.html" "the page does not carry the cards"
  if [ "$(uname)" = Darwin ]; then perms=$(stat -f '%Lp' "$HOME_DIR/data/tap-desk/cards.json"); else perms=$(stat -c '%a' "$HOME_DIR/data/tap-desk/cards.json"); fi
  assert_equals "600" "$perms" "the card file is not private"
  pass "export lists every captain call, held work included, and only merges the fleet reader calls ready, naming who opened them and any rules they change"
}

test_mark_records_explicit_fields_and_refuses_unsafe_marks() {
  new_home mark
  hold hold pick-route --title "Choose the route" --reason "Choose: route north; OR route south." --repo sample >/dev/null
  hold hold pay-call --title "Pay the invoice now or later" --reason "Choose: now; OR later." --repo sample >/dev/null
  local out rc
  rc=0; out=$(desk mark pick-route --easy-undo 2>&1) || rc=$?
  expect_code 1 "$rc" "easy-undo without a recommendation"
  assert_contains "$out" "needs --recommend" "easy-undo without a recommendation was not explained"
  rc=0; out=$(desk mark pick-route --recommend "route east" 2>&1) || rc=$?
  expect_code 1 "$rc" "a recommendation that is not an option"
  rc=0; out=$(desk mark pay-call --recommend later --easy-undo 2>&1) || rc=$?
  expect_code 1 "$rc" "easy-undo on a money decision"
  assert_contains "$out" "money" "the money refusal did not name its class"
  assert_not_contains "$(field pay-call body)" "Tap marks for" "a refused mark still wrote the body"
  # The Factory pane keeps a question's shape until the owner's calls stamp
  # moves, whatever adapter keeps the backlog, so a mark must move the stamp.
  rm -f "$HOME_DIR/state/.owner-calls-changed"
  desk mark pick-route --recommend "route north" --easy-undo >/dev/null || fail "a valid mark was refused"
  [ -s "$HOME_DIR/state/.owner-calls-changed" ] || fail "a mark left the owner's calls stamp unmoved"
  assert_contains "$(field pick-route body)" "Tap easy to undo: yes" "the easy-to-undo field was not recorded"
  local before
  before=$(identity_of pick-route)
  desk export >/dev/null
  cards_json | grep -q '"easy_undo": true' || fail "export did not carry the mark"
  assert_equals "$before" "$(identity_of pick-route)" "marking changed the question's identity"
  # A reworded re-hold is a new question; the old marks must not carry over.
  hold hold pick-route --reason "Choose: route north; OR route west." >/dev/null
  desk export >/dev/null
  cards_json | grep -q '"easy_undo": true' && fail "marks carried over to a re-held question"
  pass "mark records explicit fields bound to the question and refuses unsafe or invalid marks"
}

# The Factory pane shows each held decision through `shapes`, so it carries the
# same options and recommendation as its card, and a question with none
# recorded comes back plain, with no options and no stand-in text.
test_shapes_reads_each_question_as_its_card_does() {
  new_home shapes
  hold hold pick-route --title "Choose the route" --reason "Choose: route north; OR route south." --repo sample >/dev/null
  desk mark pick-route --option "go north" --option "go south" --option "stay" --recommend "go south" >/dev/null \
    || fail "could not mark the route"
  hold hold open-ask --title "How should launch day go" --reason "The launch plan needs your view." --repo sample >/dev/null
  # A title that lists its calls is no list of options: only the reason names them.
  hold hold three-calls --title "Garden: owner's calls (plant now or later, tell the neighbours now / on return, ask about the hedge)" \
    --reason "Three calls from the garden walk: (a) plant the beans now or wait for rain;" --repo sample >/dev/null
  # A plain two-way title still gives its two options when the reason names none.
  hold hold two-way --title "Ship the beta now or after the holidays?" --reason "The beta is ready to go." --repo sample >/dev/null
  hold hold slash-way --title "Deploy now / tomorrow or next week?" --reason "The build is green." --repo sample >/dev/null
  hold hold branch-way --title "Merge fm/login-fix or wait for review?" --reason "The fix is ready." --repo sample >/dev/null
  hold hold vs-branch --title "Merge fm/vs-code-fix or wait for review?" --reason "The fix is ready." --repo sample >/dev/null
  hold hold vs-way --title "Run tests vs. skip or ship?" --reason "The build is green." --repo sample >/dev/null
  local out
  out=$(desk shapes pick-route open-ask three-calls two-way slash-way branch-way vs-branch vs-way) || fail "shapes failed"
  printf '%s' "$out" | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const doc = JSON.parse(s);
      const by = Object.fromEntries(doc.decisions.map((d) => [d.id, d]));
      const check = (ok, code) => { if (!ok) { console.error(s); process.exit(code); } };
      check(doc.schema === "fm-tap-shapes.v1", 2);
      check(JSON.stringify(by["pick-route"].options) === JSON.stringify(["go north", "go south", "stay"]), 3);
      check(by["pick-route"].recommended_option === "go south" && by["pick-route"].recommendation === "go south", 4);
      check(by["pick-route"].identity && by["pick-route"].title === "Choose the route", 5);
      check(by["open-ask"].question === "The launch plan needs your view." && by["open-ask"].options.length === 0, 6);
      check(by["open-ask"].recommendation === "" && !/None|null/.test(JSON.stringify(by["open-ask"])), 7);
      check(JSON.stringify(by["three-calls"].options) === "[]", 8);
      check(JSON.stringify(by["two-way"].options) === JSON.stringify(["Ship the beta now", "after the holidays"]), 9);
      check(JSON.stringify(by["slash-way"].options) === "[]", 10);
      check(JSON.stringify(by["branch-way"].options) === JSON.stringify(["Merge fm/login-fix", "wait for review"]), 11);
      check(JSON.stringify(by["vs-branch"].options) === JSON.stringify(["Merge fm/vs-code-fix", "wait for review"]), 12);
      check(JSON.stringify(by["vs-way"].options) === "[]", 13);
    });' || fail "shapes did not read the questions as their cards do"
  desk export >/dev/null || fail "export failed"
  cards_json | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const cards = JSON.parse(s).cards;
      const card = cards.find((c) => c.id === "pick-route");
      if (JSON.stringify(card.options) !== JSON.stringify(["go north", "go south", "stay"]) || card.recommended_option !== "go south") process.exit(2);
      if (JSON.stringify(cards.find((c) => c.id === "three-calls").options) !== "[]") { console.error(s); process.exit(3); }
      if (JSON.stringify(cards.find((c) => c.id === "two-way").options) !== JSON.stringify(["Ship the beta now", "after the holidays"])) { console.error(s); process.exit(4); }
    });' || fail "the card and shapes disagree, or a card misread its title as options"
  desk mark two-way --recommend "after the holidays" >/dev/null \
    || fail "mark without --option refused the options of a plain two-way title"
  desk mark three-calls --recommend "later, tell the neighbours now" >/dev/null 2>&1 \
    && fail "mark took an option split out of a title that lists several calls"
  desk mark slash-way --recommend "Deploy now / tomorrow" >/dev/null 2>&1 \
    && fail "mark took an option split out of a title that names three choices"
  desk mark branch-way --recommend "wait for review" >/dev/null \
    || fail "mark without --option refused the options of a two-way title naming a branch"
  pass "shapes reads each held question exactly as its tap card does, a plain question stays plain, and only a plain two-way title gives options"
}

# On 2026-11-14 the bridge strip, the Factory pane and the tap page showed 0 to
# 2, 17 to 36 and 112 calls for the owner at the same moment. All three now
# show the one count of his calls, and the pane shows each question with the
# options and recommendation its card carries.
test_the_strip_the_pane_and_the_page_show_one_count() {
  new_home onecount
  hold hold pick-route --title "Choose the route" --reason "Which way should the walk go?" --repo sample >/dev/null
  desk mark pick-route --option "north" --option "south" --recommend "south" >/dev/null || fail "could not mark"
  hold hold old-ask --title "Name the newsletter" --reason "Needs a name." --repo sample >/dev/null
  hold hold revisit --title "Revisit the pricing" --reason "Ask again later." --repo sample --until 2999-01-01 >/dev/null
  tasks add ship-pr "Ship the fix" --kind ship --repo sample >/dev/null
  tasks add asking "A worker's question" --kind ship --repo sample >/dev/null
  tasks add pausing "A worker's pause" --kind ship --repo sample >/dev/null
  fm_write_meta "$HOME_DIR/state/ship-pr.meta" "kind=ship" "pr=https://github.com/o/sample/pull/7"
  fm_write_meta "$HOME_DIR/state/asking.meta" "kind=ship"
  fm_write_meta "$HOME_DIR/state/pausing.meta" "kind=ship"
  cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"state":"OPEN","isDraft":false,"title":"Fix","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","author":{"login":"me"}}' ;;
  "api --hostname") case "$*" in *" user "*) echo me ;; *) printf 'src/x.js\n' ;; esac ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$FAKEBIN/gh"
  cat > "$FAKEBIN/reader" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ship-pr) echo "state: done · source: run-step · passed · run: r1" ;;
  asking) echo "state: parked · source: status-log · needs-decision: which index?" ;;
  pausing) echo "state: paused · source: status-log · waiting on the carrier" ;;
esac
EOF
  chmod +x "$FAKEBIN/reader"
  # A remote second mate has a PR ready for the owner's merge word, reported
  # through its mirrored parent channel; the page names it rather than cards it.
  fm_write_meta "$HOME_DIR/state/far.meta" kind=secondmate mode=secondmate window=remote:far remote_host=far-host
  printf 'done [key=child-outcome-far-fix-done-0a0b0c0d] [at=100]: child far-fix done: checks green pr=https://github.com/o/sample/pull/8 mode=no-mistakes yolo=off\n' \
    > "$HOME_DIR/state/far.status"
  printf '#!/usr/bin/env bash\necho open\n' > "$FAKEBIN/pr-reader"
  chmod +x "$FAKEBIN/pr-reader"
  local out calls strip record
  out=$(home_env FM_SECONDMATE_PR_READER="$FAKEBIN/pr-reader" FM_FLEET_STATE_READER="$FAKEBIN/reader" "$DESK" export) \
    || fail "export failed"
  calls=$(cards_json | node -e 'let s=""; process.stdin.on("data",(c)=>s+=c).on("end",()=>console.log(JSON.parse(s).owner_calls))')
  assert_equals "4" "$calls" "the page's count of the owner's calls"
  assert_contains "$(cards_json)" '"id": "far:far-fix"' "the page names the second mate's PR"
  strip=$(home_env FM_SECONDMATE_PR_READER="$FAKEBIN/pr-reader" FM_FLEET_STATE_READER="$FAKEBIN/reader" \
    FM_FLEET_STATE_NO_CACHE=1 FM_BRIDGE_STRIP_PMSET= \
    bash "$ROOT/bin/fm-bridge-strip.sh" render --width 110 | sed $'s/\033\\[[0-9;]*m//g')
  assert_contains "$strip" "■ 2 decisions for you   ■ 2 ready to merge" "the strip's count of the owner's calls"
  # The pane reads the same home: its snapshot is the home's own backlog plus
  # the canonical state of each task, and its questions come from the real
  # shapes reader rather than a stand-in.
  home_env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-fleet-snapshot.sh" --backlog > "$HOME_DIR/backlog.json" \
    || fail "the backlog snapshot failed"
  # shellcheck disable=SC2016 # the ${...} below are JavaScript template literals
  node -e '
    const fs = require("node:fs");
    const [home] = process.argv.slice(1);
    const line = { "ship-pr": ["done", "run-step", "passed · run: r1"], asking: ["parked", "status-log", "needs-decision: which index?"],
                   pausing: ["paused", "status-log", "waiting on the carrier"] };
    const tasks = Object.entries(line).map(([id, [state, source, detail]]) => ({
      id, kind: "ship", project: "/projects/sample",
      current_state: { state, source, detail, raw: `state: ${state} · source: ${source} · ${detail}` },
      paths: { meta: { path: `${home}/state/${id}.meta` }, status_log: { path: `${home}/state/${id}.status` } },
      hints: { open_decisions: [] }, pr: { url: id === "ship-pr" ? "https://github.com/o/sample/pull/7" : null } }));
    const backlog = JSON.parse(fs.readFileSync(`${home}/backlog.json`, "utf8"));
    fs.writeFileSync(`${home}/snapshot.json`, JSON.stringify({ schema: "fm-fleet-snapshot.v1", generated: "", tasks, backlog }));
  ' "$HOME_DIR"
  record=$(home_env FM_SECONDMATE_PR_READER="$FAKEBIN/pr-reader" FM_FACTORY_SNAPSHOT="$HOME_DIR/snapshot.json" \
    FM_FACTORY_PEEK= FM_FACTORY_INBOX=true FM_FLEET_STATE_READER="$FAKEBIN/reader" FM_FLEET_STATE_NO_CACHE=1 \
    python3 "$ROOT/bin/fm-factory.py" --data --fresh) || fail "the pane's record failed"
  printf '%s' "$record" | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const record = JSON.parse(s);
      const by = Object.fromEntries(record.needs_you.map((n) => [n.id, n]));
      const check = (ok, code) => { if (!ok) { console.error(JSON.stringify(record.needs_you, null, 2)); process.exit(code); } };
      check(record.counts.decisions === 2 && record.counts.ready_to_merge === 2 && record.needs_you.length === 4, 2);
      check(by["pick-route"] && JSON.stringify(by["pick-route"].options.map((o) => [o.label, o.suggested])) === JSON.stringify([["north", false], ["south", true]]), 3);
      check(by["old-ask"] && by["old-ask"].options.length === 0 && by["old-ask"].why === "Needs a name.", 4);
      check(by["ship-pr"] && by["ship-pr"].kind === "finished work", 5);
      check(!by["asking"] && !by["pausing"] && !by["revisit"], 6);
      check(by["far:far-fix"] && by["far:far-fix"].mate === "far" && by["far:far-fix"].pr === "https://github.com/o/sample/pull/8", 7);
    });' || fail "the pane did not show the owner's calls as the page does"
  pass "the bridge strip, the Factory pane and the tap page show one count of the owner's calls"
}

test_route_answers_keeps_and_saves_reasons() {
  new_home route
  hold hold pick-route --title "Choose the route" --reason "Choose: route north; OR route south. Recommendation: route north." --repo sample >/dev/null
  tasks add work-a "Build the widget" --kind ship --repo sample >/dev/null
  hold hold work-a --reason "Waiting on the owner" >/dev/null
  desk mark work-a --option "ship now" --option "wait" --recommend "wait" >/dev/null
  hold hold keep-me --title "Rename the tool" --reason "Choose: alpha; OR beta." --repo sample >/dev/null
  tasks add drop-me "Old experiment" --kind ship --repo sample >/dev/null
  hold hold drop-me --reason "Still wanted?" >/dev/null
  hold hold delegate --title "Pick a colour" --reason "Choose: red; OR blue." --repo sample >/dev/null
  desk mark delegate --recommend blue >/dev/null
  local taps="$HOME_DIR/taps/taps"
  write_tap "$taps" d.pick-route decision pick-route "$(identity_of pick-route)" option "route south" "North floods in winter"
  write_tap "$taps" d.work-a decision work-a "$(identity_of work-a)" option "ship now" ""
  write_tap "$taps" d.keep-me decision keep-me "$(identity_of keep-me)" keep "" "Ask again after the launch"
  write_tap "$taps" d.drop-me decision drop-me "$(identity_of drop-me)" drop "" ""
  write_tap "$taps" d.delegate decision delegate "$(identity_of delegate)" you-decide "" ""

  desk route --taps "$taps" > "$HOME_DIR/dry.out" || fail "dry run failed"
  assert_grep "would answer: pick-route" "$HOME_DIR/dry.out" "the dry run did not plan the answer"
  assert_equals "queued" "$(field pick-route state)" "the dry run changed a decision"

  desk route --taps "$taps" --apply > "$HOME_DIR/apply.out" || fail "route --apply failed: $(cat "$HOME_DIR/apply.out")"
  assert_equals "done" "$(field pick-route state)" "the answered question did not close"
  assert_contains "$(field pick-route body)" "Chosen option: route south" "the chosen option was not recorded"
  assert_contains "$(field pick-route body)" "Reason: North floods in winter" "the reason was not saved with the decision"
  assert_equals "queued" "$(field work-a state)" "the answered work item was closed instead of resumed"
  assert_equals "no" "$(field work-a held)" "the answered work item was not released"
  assert_equals "yes" "$(field keep-me held)" "keep released the hold"
  assert_contains "$(field keep-me body)" "kept for" "keep was not noted on the task"
  assert_contains "$(field keep-me body)" "Ask again after the launch" "the keep reason was not saved"
  assert_equals "done" "$(field drop-me state)" "drop did not close the work item"
  assert_contains "$(field drop-me body)" "Dropped" "drop was not recorded"
  assert_contains "$(field delegate body)" "Chosen option: blue" "you decide did not apply the recommendation"
  assert_grep "## Tap rule candidates" "$HOME_DIR/data/learnings.md" "learnings got no rule candidate section"
  assert_grep "(pick-route, chose \"route south\"): North floods in winter" "$HOME_DIR/data/learnings.md" "the reason was not offered as a rule candidate"
  assert_grep "(keep-me, keep): Ask again after the launch" "$HOME_DIR/data/learnings.md" "the keep reason was not offered as a rule candidate"
  assert_no_grep "(work-a" "$HOME_DIR/data/learnings.md" "a tap without a reason added a rule candidate"

  desk route --taps "$taps" --apply > "$HOME_DIR/replay.out" || fail "a replay failed"
  assert_grep "already handled: 5" "$HOME_DIR/replay.out" "reading the same taps again was not a no-op"
  [ "$(grep -c 'keep-me' "$HOME_DIR/data/learnings.md")" = 1 ] || fail "a replay appended the reason twice"

  desk export >/dev/null
  cards_json | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const card = JSON.parse(s).cards.find((c) => c.key === "d.keep-me");
      if (!card || !card.kept || card.kept.reason !== "Ask again after the launch") process.exit(1);
    });' || fail "the next export does not show the keep and its reason"
  pass "route answers, resumes, keeps, drops and delegates through the captain-hold path and saves every reason once"
}

test_route_refuses_stale_unknown_and_away_releases() {
  new_home refuse
  hold hold pick-route --title "Choose the route" --reason "Choose: route north; OR route south." --repo sample >/dev/null
  tasks add work-a "Build the widget" --kind ship --repo sample >/dev/null
  hold hold work-a --reason "Choose: go; OR stop." >/dev/null
  local old taps="$HOME_DIR/taps" out rc
  old=$(identity_of pick-route)
  hold hold pick-route --reason "Choose: route north; OR route east." >/dev/null
  write_tap "$taps" d.pick-route decision pick-route "$old" option "route south" ""
  rc=0; out=$(desk route --taps "$taps" --apply) || rc=$?
  expect_code 0 "$rc" "a stale tap"
  assert_contains "$out" "stale: pick-route: the question changed" "a tap on a changed question was not refused as stale"
  assert_equals "queued" "$(field pick-route state)" "a stale tap answered the new question"

  rm -rf "$taps"
  write_tap "$taps" d.pick-route decision pick-route "$(identity_of pick-route)" option "route south" ""
  out=$(desk route --taps "$taps" --apply)
  assert_contains "$out" "stale: pick-route: the chosen option is no longer offered" "an option that is not offered was accepted"
  assert_equals "queued" "$(field pick-route state)" "an unoffered option answered the question"

  rm -rf "$taps"
  mkdir -p "$taps"
  printf '{"card":"d.x","kind":"decision","id":"other","identity":"i","choice":"option","option":"a"}' > "$taps/forged.json"
  printf '{"card":"m.work-a","kind":"merge","id":"work-a","identity":"not-a-head","choice":"merge"}' > "$taps/badhead.json"
  printf 'not json' > "$taps/garbage.json"
  rc=0; out=$(desk route --taps "$taps" --apply) || rc=$?
  expect_code 1 "$rc" "unreadable taps"
  assert_contains "$out" "the card key does not match the task" "a forged card key was not refused"
  assert_contains "$out" "carries no head commit" "a merge tap without a head was not refused"
  assert_contains "$out" "not JSON" "a garbage file was not named"

  rm -rf "$taps"
  : > "$HOME_DIR/state/.afk"
  write_tap "$taps" d.work-a decision work-a "$(identity_of work-a)" option "go" "Ready now"
  rc=0; out=$(desk route --taps "$taps" --apply) || rc=$?
  expect_code 1 "$rc" "a release while away"
  assert_contains "$out" "refused: work-a" "releasing held work while away was not refused"
  assert_equals "yes" "$(field work-a held)" "held work was released while away"
  rm -f "$HOME_DIR/state/.afk"
  out=$(desk route --taps "$taps" --apply) || fail "the retried tap failed: $out"
  assert_contains "$out" "answered, work resumes" "a refused tap was not retried once attended"
  assert_equals "no" "$(field work-a held)" "the retried tap did not release the work"
  pass "route refuses stale, unoffered, forged and away-time releases and retries a refused tap"
}

test_route_merges_only_through_pr_merge() {
  new_home merge
  tasks add ship-pr "Ship the fix" --kind ship --repo sample >/dev/null
  fm_write_meta "$HOME_DIR/state/ship-pr.meta" "kind=ship" "pr=https://github.com/o/sample/pull/7"
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa pr=https://github.com/o/sample/pull/7 taps="$HOME_DIR/taps" out rc
  printf 'OPEN %s\n' "$head" > "$HOME_DIR/live.pr"
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2 \$3" = "pr view $pr" ] || exit 1
read -r state head < "$HOME_DIR/live.pr"
printf '{"state":"%s","headRefOid":"%s"}\n' "\$state" "\$head"
EOF
  chmod +x "$FAKEBIN/gh"
  cat > "$FAKEBIN/fake-merge" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOME_DIR/merge.calls"
[ -e "$HOME_DIR/merge.refuse" ] && { echo "error: required check build has not reported" >&2; exit 1; }
exit 0
EOF
  chmod +x "$FAKEBIN/fake-merge"
  write_tap "$taps" m.ship-pr merge ship-pr "$head" not-yet "" "Wait for the demo" "$pr"
  home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply > "$HOME_DIR/notyet.out" || fail "not yet failed"
  assert_absent "$HOME_DIR/merge.calls" "not yet called the merge command"
  assert_contains "$(field ship-pr body)" "not yet for head $head: Wait for the demo" "not yet was not noted with its reason"

  rm -rf "$taps"
  touch "$HOME_DIR/merge.refuse"
  write_tap "$taps" m.ship-pr merge ship-pr "$head" merge "" "" "$pr"
  rc=0; out=$(home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply) || rc=$?
  expect_code 1 "$rc" "a refused merge"
  assert_contains "$out" "refused: ship-pr: https://github.com/o/sample/pull/7: error: required check build has not reported" "the merge refusal was not reported"
  assert_grep "ship-pr $pr --captain-approved --expected-head $head" "$HOME_DIR/merge.calls" "the merge was not the captain's yes pinned to the card's head"
  rm -f "$HOME_DIR/merge.refuse"
  out=$(home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply) || fail "the retried merge failed"
  assert_contains "$out" "merged: ship-pr: https://github.com/o/sample/pull/7" "the retried merge was not reported"
  [ "$(wc -l < "$HOME_DIR/merge.calls" | tr -d ' ')" = 2 ] || fail "the merge was not retried exactly once"
  home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply >/dev/null
  [ "$(wc -l < "$HOME_DIR/merge.calls" | tr -d ' ')" = 2 ] || fail "a handled merge tap merged again"

  # A PR that changed after its card is stale once, never a retried refusal.
  local case_name
  for case_name in pushed closed moved; do
    rm -rf "$taps"
    printf 'OPEN %s\n' "$head" > "$HOME_DIR/live.pr"
    fm_write_meta "$HOME_DIR/state/ship-pr.meta" "kind=ship" "pr=$pr"
    case "$case_name" in
      pushed) printf 'OPEN %s\n' "$(printf 'f%.0s' $(seq 40))" > "$HOME_DIR/live.pr" ;;
      closed) printf 'CLOSED %s\n' "$head" > "$HOME_DIR/live.pr" ;;
      moved) fm_write_meta "$HOME_DIR/state/ship-pr.meta" "kind=ship" "pr=https://github.com/o/sample/pull/70" ;;
    esac
    write_tap "$taps" m.ship-pr merge ship-pr "$head" merge "" "$case_name" "$pr"
    rc=0; out=$(home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply) || rc=$?
    expect_code 0 "$rc" "a merge tap on a $case_name PR"
    assert_contains "$out" "stale: ship-pr" "a merge tap on a $case_name PR was not stale"
    out=$(home_env FM_TAP_DESK_MERGE_BIN="$FAKEBIN/fake-merge" "$DESK" route --taps "$taps" --apply) || fail "a replayed $case_name tap failed"
    assert_contains "$out" "already handled: 1" "a stale $case_name tap was not recorded once"
  done
  [ "$(wc -l < "$HOME_DIR/merge.calls" | tr -d ' ')" = 2 ] || fail "a stale merge tap reached the merge command"
  pass "a merge tap is the captain's yes for the card's PR and head only, stale once when that PR changed, and not yet never merges"
}

test_defaults_apply_only_marked_easy_old_safe_decisions() {
  new_home defaults
  hold hold due-one --title "Choose the label colour" --reason "Choose: red; OR blue." --repo sample >/dev/null
  hold hold young-one --title "Choose the font" --reason "Choose: serif; OR sans." --repo sample >/dev/null
  hold hold unmarked --title "Choose the icon" --reason "Choose: star; OR moon." --repo sample >/dev/null
  hold hold kept-one --title "Choose the banner" --reason "Choose: wide; OR narrow." --repo sample >/dev/null
  hold hold deferred --title "Choose the theme" --reason "Choose: dark; OR light." --repo sample --until 2999-01-01 >/dev/null
  hold hold wordy --title "Choose the layout" --reason "Choose: grid; OR list." --repo sample >/dev/null
  hold hold past-deferred --title "Choose the sidebar" --reason "Choose: left; OR right." --repo sample --until 2020-01-02 >/dev/null
  hold hold stale-one --title "Choose the footer" --reason "Choose: short; OR tall." --repo sample >/dev/null
  # A hold waiting on other work is no call of the owner's until that work lands.
  tasks add other-work "The other work" --kind ship --repo sample >/dev/null
  tasks add blocked-one "Choose the frame" --kind ship --repo sample --blocked-by other-work >/dev/null
  hold hold blocked-one --reason "Choose: oak; OR pine." >/dev/null || fail "could not hold the blocked question"
  local id ten_days_ago
  ten_days_ago=$(node -e 'process.stdout.write(new Date(Date.now() - 10 * 864e5).toISOString().replace(/\.\d+Z$/, "Z"))')
  for id in due-one unmarked kept-one wordy blocked-one; do backdate_hold "$id" "$ten_days_ago"; done
  for id in deferred past-deferred stale-one; do backdate_hold "$id" 2020-01-01T00:00:00Z; done
  desk mark due-one --recommend blue --easy-undo >/dev/null || fail "could not mark due-one"
  desk mark young-one --recommend sans --easy-undo >/dev/null || fail "could not mark young-one"
  desk mark kept-one --recommend wide --easy-undo >/dev/null || fail "could not mark kept-one"
  desk mark deferred --recommend dark --easy-undo >/dev/null || fail "could not mark deferred"
  desk mark wordy --recommend grid --easy-undo >/dev/null || fail "could not mark wordy"
  desk mark past-deferred --recommend left --easy-undo >/dev/null || fail "could not mark past-deferred"
  desk mark stale-one --recommend short --easy-undo >/dev/null || fail "could not mark stale-one"
  desk mark blocked-one --recommend oak --easy-undo >/dev/null || fail "could not mark blocked-one"
  # A body edit made after marking cannot smuggle a refused class past the default.
  tasks update wordy --title "Choose the layout and delete the old one" >/dev/null
  write_tap "$HOME_DIR/taps" d.kept-one decision kept-one "$(identity_of kept-one)" keep "" ""
  desk route --taps "$HOME_DIR/taps" --apply >/dev/null || fail "could not record the keep"

  desk export >/dev/null || fail "export failed"
  cards_json | node -e '
    let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
      const by = Object.fromEntries(JSON.parse(s).cards.map((c) => [c.id, c]));
      const check = (ok, code) => { if (!ok) { console.error(s); process.exit(code); } };
      check(by["due-one"].default_in_days === 0, 2);
      check(by["young-one"].default_in_days === 7, 3);
      // A call deferred to a date that has not come is not one of the owner'"'"'s
      // calls, so it has no card until that date.
      check(!by["deferred"], 4);
      check(by["kept-one"].default_in_days === null && by["wordy"].default_in_days === null && by["unmarked"].default_in_days === null, 5);
      // Once its date has passed it waits on the owner again and is carded,
      // but a deferred call is still never given the seven-day default.
      check(by["past-deferred"] && by["past-deferred"].default_in_days === null, 6);
      // An undated hold past the aging threshold no longer waits on the owner,
      // as the bearings Captain'"'"'s Call reads it, so it has no card either.
      check(!by["stale-one"], 7);
      check(!by["blocked-one"], 8);
    });' || fail "a card promises a default that defaults would never apply"
  desk defaults > "$HOME_DIR/dry.out" || fail "the defaults dry run failed"
  assert_grep "would default: due-one: blue" "$HOME_DIR/dry.out" "the due decision was not listed"
  assert_equals "queued" "$(field due-one state)" "the dry run applied a default"
  desk defaults --apply > "$HOME_DIR/apply.out" || fail "defaults --apply failed: $(cat "$HOME_DIR/apply.out")"
  assert_grep "defaulted: due-one: blue" "$HOME_DIR/apply.out" "the default was not reported for the owner"
  assert_equals "done" "$(field due-one state)" "the default did not answer the decision"
  assert_contains "$(field due-one body)" "Default applied" "the answer was not recorded as a default"
  assert_contains "$(field due-one body)" "not the owner's tap" "the default reads as the owner's own answer"
  assert_equals "queued" "$(field young-one state)" "a decision younger than seven days was defaulted"
  assert_equals "queued" "$(field unmarked state)" "an unmarked decision was defaulted"
  assert_equals "queued" "$(field kept-one state)" "a kept decision was defaulted"
  assert_grep "skipped: kept-one: the owner tapped keep" "$HOME_DIR/apply.out" "the keep skip was not explained"
  assert_equals "queued" "$(field deferred state)" "a deferred decision was defaulted"
  assert_equals "queued" "$(field past-deferred state)" "a decision whose deferral date passed was defaulted"
  # Its date has passed, so it is one of the owner's calls again and defaults
  # reads it, but only to say why it is never defaulted.
  assert_no_grep "defaulted: past-deferred" "$HOME_DIR/apply.out" "a decision whose deferral date passed was offered a default"
  assert_grep "skipped: past-deferred: the owner deferred it until 2020-01-02" "$HOME_DIR/apply.out" \
    "a decision whose deferral date passed was not named as never defaulted"
  assert_equals "queued" "$(field wordy state)" "a destructive-sounding decision was defaulted"
  assert_grep "skipped: wordy: it reads as destructive" "$HOME_DIR/apply.out" "the class refusal was not explained"
  # A marked, old hold the page does not card is never answered unseen.
  for id in stale-one blocked-one; do
    assert_no_grep "$id" "$HOME_DIR/dry.out" "the dry run offered a default for $id, which has no card"
    assert_no_grep "$id" "$HOME_DIR/apply.out" "defaults --apply reached $id, which has no card"
    assert_not_contains "$(field "$id" body)" "Default applied" "$id was defaulted without a card"
  done
  local rc=0
  desk defaults --days 3 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a default window under seven days"
  pass "defaults apply only to marked, easy-to-undo, seven-day-old, safe decisions and record them as defaults"
}

fm_test_run \
  test_export_lists_decisions_and_ready_merges \
  test_mark_records_explicit_fields_and_refuses_unsafe_marks \
  test_shapes_reads_each_question_as_its_card_does \
  test_the_strip_the_pane_and_the_page_show_one_count \
  test_route_answers_keeps_and_saves_reasons \
  test_route_refuses_stale_unknown_and_away_releases \
  test_route_merges_only_through_pr_merge \
  test_defaults_apply_only_marked_easy_old_safe_decisions

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
      check(!by["d.work-later"], 7);
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
  desk mark pick-route --recommend "route north" --easy-undo >/dev/null || fail "a valid mark was refused"
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
  local id
  for id in due-one unmarked kept-one deferred wordy past-deferred; do backdate_hold "$id" 2020-01-01T00:00:00Z; done
  desk mark due-one --recommend blue --easy-undo >/dev/null || fail "could not mark due-one"
  desk mark young-one --recommend sans --easy-undo >/dev/null || fail "could not mark young-one"
  desk mark kept-one --recommend wide --easy-undo >/dev/null || fail "could not mark kept-one"
  desk mark deferred --recommend dark --easy-undo >/dev/null || fail "could not mark deferred"
  desk mark wordy --recommend grid --easy-undo >/dev/null || fail "could not mark wordy"
  desk mark past-deferred --recommend left --easy-undo >/dev/null || fail "could not mark past-deferred"
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
      check(by["deferred"].easy_undo === true && by["deferred"].default_in_days === null, 4);
      check(by["kept-one"].default_in_days === null && by["wordy"].default_in_days === null && by["unmarked"].default_in_days === null, 5);
      // tasks-axi drops a hold whose --until date has passed from the held
      // listing, so neither the page nor the default ever reaches it.
      check(!by["past-deferred"], 6);
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
  assert_no_grep "past-deferred" "$HOME_DIR/apply.out" "a decision whose deferral date passed was offered a default"
  assert_equals "queued" "$(field wordy state)" "a destructive-sounding decision was defaulted"
  assert_grep "skipped: wordy: it reads as destructive" "$HOME_DIR/apply.out" "the class refusal was not explained"
  local rc=0
  desk defaults --days 3 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a default window under seven days"
  pass "defaults apply only to marked, easy-to-undo, seven-day-old, safe decisions and record them as defaults"
}

fm_test_run \
  test_export_lists_decisions_and_ready_merges \
  test_mark_records_explicit_fields_and_refuses_unsafe_marks \
  test_route_answers_keeps_and_saves_reasons \
  test_route_refuses_stale_unknown_and_away_releases \
  test_route_merges_only_through_pr_merge \
  test_defaults_apply_only_marked_easy_old_safe_decisions

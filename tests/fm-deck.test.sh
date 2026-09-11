#!/usr/bin/env bash
# Behavior tests for bin/fm-deck.sh, the captain's private Action Deck pane.
#
# The pane is a composition, so these tests drive the real bin/fm-tray.sh and
# bin/fm-order.sh over a fixture gateway log and fixture order files, and stub
# only tasks-axi (the backlog reader, which is an external tool). They cover the
# five sections, honest degradation when a source is missing, the read-only
# boundary, and the captain-facing wording contract: no internal vocabulary and
# no verbatim worker status notes reach the pane.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECK="$ROOT/bin/fm-deck.sh"
# bin/fm-deck.sh collects every source; bin/fm-deck-render.py presents them.
# The renderer is driven directly below so that seam is a tested contract and
# not just an implementation detail of the wrapper.
RENDER="$ROOT/bin/fm-deck-render.py"
MARK='__FM_DECK_SECTION__'
TMP=$(fm_test_tmproot fm-deck)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# Frozen gateway "now" so staged ages and expiry countdowns are deterministic.
NOW=1700003600

make_home() {  # <name> -> home dir
  local home="$TMP/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/data/action-gateway"
  printf '%s\n' "$home"
}

# tasks-axi is an external tool; stub its `list` with the exact shape the real
# one emits, including its "-"/none absent markers and its truncation pointer.
install_fake_tasks_axi() {  # <fakebin> [empty]
  local fb=$1 mode=${2:-full}
  mkdir -p "$fb"
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = list ] || exit 0
if [ "$mode" = empty ]; then
  printf 'count: 0\n'
  printf 'tasks[0]{id,state,kind,repo,title}:\n'
  exit 0
fi
printf 'count: 5\n'
printf 'tasks[5]{id,state,kind,repo,title,hold_kind,hold_reason,links,closed,blocked_by,held,priority}:\n'
printf '  ship-task,in_flight,ship,alpha,"Ship the alpha widget","-","-","pr:https://github.com/acme/alpha/pull/7","-",none,no,"-"\n'
printf '  parked-task,in_flight,ship,alpha,"Rework the beta importer","-","-",none,"-",none,no,"-"\n'
printf '  hold-one,queued,captain,alpha,"Authorise the Sweden field visit",captain,"needs the captain",none,"-",none,yes,"-"\n'
printf '  landed-ship,done,ship,alpha,"Land the gamma migration","-","-","pr:https://github.com/acme/alpha/pull/4",2026-09-02,none,no,"-"\n'
printf '  landed-scout,done,scout,alpha,"Investigate the delta timeouts and report what is actually slow\\\\n... (truncated, 210 chars total - use show landed-scout --full to see complete text)","-","-","report:data/landed-scout/report.md",2026-09-01,none,no,"-"\n'
SH
  chmod +x "$fb/tasks-axi"
}

# Two prepared staged actions under one armed order, plus one under a domain with
# no order file, plus one expired card.
write_gateway_log() {  # <home>
  cat > "$1/data/action-gateway/action-audit.log" <<'JSONL'
{"ts":1700000000,"event":"prepared","state":"prepared","request_id":"r-1","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expires_at":1800000000,"requester_id":"worker-1","request":{"task_id":"t-1","domain":"proactive-outbound","action_kind":"crm.update","target":"hubspot://note-1","parameters":{},"idempotency_key":"i-1","expires_at":1800000000,"nonce":"n-1","requester_id":"worker-1"}}
{"ts":1700003000,"event":"prepared","state":"prepared","request_id":"r-2","digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expires_at":1700000100,"requester_id":"worker-2","request":{"task_id":"t-2","domain":"proactive-outbound","action_kind":"crm.update","target":"hubspot://note-2","parameters":{},"idempotency_key":"i-2","expires_at":1700000100,"nonce":"n-2","requester_id":"worker-2"}}
{"ts":1700003500,"event":"prepared","state":"prepared","request_id":"r-3","digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","expires_at":1800000000,"requester_id":"worker-3","request":{"task_id":"t-3","domain":"unclaimed-domain","action_kind":"sheet.write","target":"sheet://q3","parameters":{},"idempotency_key":"i-3","expires_at":1800000000,"nonce":"n-3","requester_id":"worker-3"}}
JSONL
}

write_orders() {  # <home>
  mkdir -p "$1/data/orders"
  cat > "$1/data/orders/proactive-outbound.md" <<'EOF'
# Proactive outbound

Status: ARMED (captain 2026-09-01)

Watch: the every-two-days scan snapshot.
EOF
  cat > "$1/data/orders/spares.md" <<'EOF'
# Spares currency

Status: DRAFT

Watch: the Exact Online spares list.
EOF
}

write_workers() {  # <home>
  local home=$1
  fm_write_meta "$home/state/ship-task.meta" \
    "window=default:w1:p1" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Ship the alpha widget" \
    "pr=https://github.com/acme/alpha/pull/7"
  printf 'working: pushed the branch\n' > "$home/state/ship-task.status"

  fm_write_meta "$home/state/parked-task.meta" \
    "window=default:w1:p2" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Rework the beta importer"
  # A realistic worker note, full of pipeline vocabulary the captain must not see.
  printf 'working: started\n' > "$home/state/parked-task.status"
  printf 'needs-decision [key=beta-shape]: no-mistakes run 01ABC parked at the review gate with 4 ask-user findings; worktree HEAD 9f2a1b\n' \
    >> "$home/state/parked-task.status"

  fm_write_meta "$home/state/stuck-task.meta" \
    "window=default:w1:p3" "kind=scout" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Investigate the delta timeouts"
  printf 'blocked: teardown refused, no credential for the vendor portal\n' \
    > "$home/state/stuck-task.status"
}

# The deck pins its backlog read to this home's file, so the file has to exist
# even though the stub above is what answers the query. Keep it consistent with
# the stub's rows so the fixture does not describe a backlog it cannot produce.
write_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] ship-task - Ship the alpha widget (repo: alpha) (kind: ship)
- [ ] parked-task - Rework the beta importer (repo: alpha) (kind: ship)

## Queued
- [ ] hold-one - Authorise the Sweden field visit (repo: alpha) (kind: captain) (hold-kind: captain)

## Done
- [x] landed-ship - Land the gamma migration (repo: alpha) (kind: ship)
- [x] landed-scout - Investigate the delta timeouts (repo: alpha) (kind: scout)
EOF
}

write_loose_ends() {  # <home>
  mkdir -p "$1/data/loose-ends"
  cat > "$1/data/loose-ends/latest.md" <<'EOF'
# Loose Ends - Tuesday 2026-09-01 (first sweep)

Sources read: mail, chat, meetings.

## Corrections (captain)

- Something the captain already closed in person.

## URGENT - today

1. **Reply to Jordan** about the replaced unit and the warranty claim.
2. Confirm the firewall ports with the network developers.

## Waiting external

3. Vendor is still confirming what the board order actually covers.

## Commitments made / people waiting

4. Owe Northwind the customer's answer on the noise case.
5. Owe Alex the scale-up update after Thursday's review.
6. Owe Sam a direction on who owns the portal route.

## Admin / low

7. Expense receipts are missing.
EOF
}

run_deck() {  # <home> <fakebin> [args...]
  local home=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" \
  FM_ACTION_GATEWAY_TEST=1 \
  FM_ACTION_GATEWAY_NOW="$NOW" \
  FM_ACTION_GATEWAY_ROOT="$home/data/action-gateway" \
  FM_ACTION_AUDIT_LOG="$home/data/action-gateway/action-audit.log" \
  FM_HOME="$home" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_DECK_COLUMNS="${FM_DECK_COLUMNS:-120}" \
    "$DECK" "$@"
}

# Prints "<home> <fakebin>" on ONE line, so a caller can `read -r home fb`.
# Neither path can contain a space: both are built under fm_test_tmproot.
full_home() {  # <name> -> "<home> <fakebin>"
  local home fb
  home=$(make_home "full-$1")
  fb=$(fm_fakebin "$home")
  install_fake_tasks_axi "$fb"
  write_gateway_log "$home"
  write_orders "$home"
  write_workers "$home"
  write_backlog "$home"
  write_loose_ends "$home"
  printf '%s %s\n' "$home" "$fb"
}

# One worker per verb scenario, so the UNDER WAY ordering assertion has real
# neighbours to sort against.
write_verb_worker() {  # <home> <id> <outcome>
  fm_write_meta "$1/state/$2.meta" \
    "window=default:w1:$2" "kind=ship" "project=$1/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" "outcome=$3"
}

# The sentinel-delimited payload bin/fm-deck.sh emits, so bin/fm-deck-render.py
# can be driven on its own. The first argument is spliced into every
# worker-authored field the pane shows (tray target and action kind, backlog
# title, commissioned outcome, loose-ends item); the second is its JSON-escaped
# form, which is how bin/fm-tray.sh's json.dumps hands a control character over.
render_payload() {  # <inject> <tray-inject>
  local inject=$1 tray=$2
  printf '%s now\n%s\n' "$MARK" "$NOW"
  printf '%s width\n120\n' "$MARK"
  printf '%s home\nStarship\n' "$MARK"
  printf '%s interval\n\n' "$MARK"
  printf '%s limits\n5\t5\t8\n' "$MARK"
  printf '%s vocabulary\n' "$MARK"
  printf 'working\tWORKING\t%s\n' '🔵'
  printf 'parked\tNEEDS YOU\t%s\n' '🟣'
  printf '%s tray\n' "$MARK"
  printf '[{"domain":"proactive-outbound","action_kind":"crm.update%s","target":"hubspot://note-1%s","age_secs":3600,"age":"1h","expiry":"2h","expired":false}]\n' \
    "$tray" "$tray"
  printf '%s orders\n' "$MARK"
  printf '%s backlog\n' "$MARK"
  printf 'count: 1\n'
  printf 'tasks[1]{id,state,kind,repo,title,hold_kind,hold_reason,links,closed,blocked_by,held,priority}:\n'
  printf '  hold-one,queued,captain,alpha,"Authorise the Sweden field visit%s",captain,"needs the captain",none,"-",none,yes,"-"\n' "$inject"
  printf '%s tasks\n' "$MARK"
  printf 'ship-task\tship\tAlpha\tShip the alpha widget%s\tworking\t120\t\n' "$inject"
  printf '%s loose_ends\n' "$MARK"
  printf 'path\tdata/loose-ends/latest.md\n'
  printf 'age_secs\t120\n'
  printf 'body\n'
  printf '# Loose Ends - test sweep\n\n## URGENT - today\n\n1. Reply to Jordan%s about the warranty claim.\n' "$inject"
}

# The pane is drawn into a real terminal, where a state dot occupies TWO columns
# and not the one len() counts. These two helpers measure what the terminal
# draws, so the width assertions below can talk about rendered columns without
# restating the rule: east-asian 'W' and 'F' are two columns, and ambiguous
# characters (the rules' ─, the · and … separators) are one, which is how the
# terminals this pane is read in draw them.
#
# Emits "<chars><TAB><cols><TAB><line>" for each line of the frame on stdin.
frame_widths() {
  python3 -c '
import sys, unicodedata
for line in sys.stdin.read().split("\n"):
    cols = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in line)
    sys.stdout.write("%d\t%d\t%s\n" % (len(line), cols, line))
'
}

# The display column each UNDER WAY row's trailing "heard" text starts at. The
# section exists to be scanned straight down the state dot, so every row has to
# answer with the same number however wide the glyphs in front of it are.
under_way_offsets() {
  python3 -c '
import re, sys, unicodedata
tail = re.compile(r"(heard \S+ ago|not reported yet)$")
for line in sys.stdin.read().split("\n"):
    match = tail.search(line)
    if not match:
        continue
    head = line[: match.start()]
    sys.stdout.write("%d\n" % sum(
        2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in head))
'
}

# The display width of every line drawn as a bare rule. The rules are the only
# lines the frame fills edge to edge, so they pin the scale the width
# assertions measure against.
rule_widths() {
  python3 -c '
import sys, unicodedata
for line in sys.stdin.read().split("\n"):
    if line and set(line) == {"\u2500"}:
        sys.stdout.write("%d\n" % sum(
            2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in line))
'
}

# No C0 (including DEL) and no C1 anywhere in a rendered frame.
assert_no_control_characters() {  # <text> <msg>
  local count
  count=$(printf '%s' "$1" | tr -d '\n' | LC_ALL=C tr -dc '[:cntrl:]' | wc -c | tr -d ' ')
  [ "$count" = 0 ] || fail "$2 ($count C0 characters survived)"
  case "$1" in
    *"$(printf '\302\233')"*) fail "$2 (a C1 character survived)" ;;
  esac
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$DECK" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-deck.sh' "--help names the command"
  assert_contains "$out" 'Read-only' "--help states the read-only boundary"
  pass "fm-deck --help exits 0 and states the read-only boundary"
}

test_empty_home_renders_honest_empty_sections() {
  local home fb out rc
  home=$(make_home empty)
  fb=$(fm_fakebin "$home")
  install_fake_tasks_axi "$fb" empty
  set +e
  out=$(run_deck "$home" "$fb" --once 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "empty home exit"
  assert_contains "$out" 'nothing staged for you right now' "empty staged section"
  assert_contains "$out" 'nothing is waiting on you' "empty needs-you section"
  assert_contains "$out" 'no work under way' "empty under-way section"
  assert_contains "$out" 'nothing has landed recently' "empty just-in section"
  assert_not_contains "$out" 'LOOSE ENDS' "loose ends section is absent with no sweep"
  assert_not_contains "$out" 'No such file' "no error text leaked into the pane"
  assert_not_contains "$out" 'Traceback' "no traceback leaked into the pane"
  pass "an empty home renders honest empty sections, never an error wall"
}

test_no_sources_at_all_still_renders() {
  local home fb out rc
  home=$(make_home bare)
  fb=$(fm_fakebin "$home")
  # No tasks-axi on PATH at all, no state dir contents, no gateway log.
  rm -rf "$home/state" "$home/data/action-gateway"
  set +e
  out=$(PATH="$fb:/usr/bin:/bin" run_deck "$home" "$fb" --once 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "bare home exit"
  assert_contains "$out" 'ACTION DECK' "pane still renders its frame"
  assert_contains "$out" 'nothing staged for you right now' "staged degrades"
  assert_contains "$out" 'nothing is waiting on you' "needs-you degrades"
  pass "a home with no readable sources still renders the frame"
}

test_staged_actions_group_by_order_with_age_and_expiry() {
  local home fb out staged
  read -r home fb <<EOF
$(full_home staged)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  staged=$(printf '%s\n' "$out" | awk '/STAGED FOR YOUR CLICK/,/NEEDS YOU/')

  assert_contains "$staged" 'proactive-outbound' "staged actions are grouped under their standing order"
  assert_contains "$staged" 'ARMED' "the group header carries the order's arming state"
  assert_contains "$staged" '2 waiting, oldest 1h' "the group header carries the age headline"
  assert_contains "$staged" 'EXPIRED' "an expired card is marked"
  assert_contains "$staged" 'expires in' "a live card shows its expiry countdown"
  assert_contains "$staged" 'hubspot://note-1' "the card names its target"
  # A staged action whose domain has no order file must still be visible.
  assert_contains "$staged" 'unclaimed-domain' "a card with no standing order still shows"
  assert_contains "$staged" 'no standing order on file' "and says so plainly"
  # An armed-or-draft order with nothing staged is coverage context, not a card.
  assert_contains "$staged" 'watching, nothing staged' "quiet orders are summarized"
  assert_contains "$staged" 'spares DRAFT' "a quiet order names its state"

  # Oldest first: the 1h card outranks the 10m card.
  local first second
  first=$(printf '%s\n' "$staged" | awk '/hubspot:\/\/note-1/ {print NR; exit}')
  second=$(printf '%s\n' "$staged" | awk '/hubspot:\/\/note-2/ {print NR; exit}')
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] \
    || fail "staged cards are not oldest-first (lines $first, $second)"
  pass "staged actions group by standing order with the age headline and expiry countdown"
}

test_needs_you_carries_full_pr_urls_and_distinguishes_asks() {
  local home fb out needs
  read -r home fb <<EOF
$(full_home needs)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')

  assert_contains "$needs" 'answer' "a parked worker asks him to answer"
  assert_contains "$needs" 'Rework the beta importer' "the parked row names the outcome"
  assert_contains "$needs" 'unblock' "a blocked worker asks him to unblock"
  assert_contains "$needs" 'Investigate the delta timeouts' "the blocked row names the outcome"
  assert_contains "$needs" 'review' "a PR asks him to review"
  assert_contains "$needs" 'https://github.com/acme/alpha/pull/7' "a PR row carries its full URL"
  assert_contains "$needs" 'decide' "a durable captain decision asks him to decide"
  assert_contains "$needs" 'Authorise the Sweden field visit' "the decision row names the decision"
  # A landed PR is history, not something waiting on him.
  assert_not_contains "$needs" 'pull/4' "a merged PR is not still awaiting review"
  pass "needs-you distinguishes answer, unblock, review and decide, with full PR URLs"
}

# AGENTS.md section 9: worker status lines are evidence for firstmate, never
# captain-facing copy. The pane must lead with the commissioned outcome instead.
test_worker_status_notes_never_reach_the_pane() {
  local home fb out
  read -r home fb <<EOF
$(full_home notes)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  assert_not_contains "$out" 'no-mistakes' "a pipeline name leaked from a worker note"
  assert_not_contains "$out" 'ask-user' "a gate-finding label leaked from a worker note"
  assert_not_contains "$out" 'review gate' "a pipeline step leaked from a worker note"
  assert_not_contains "$out" '01ABC' "a run identifier leaked from a worker note"
  assert_not_contains "$out" '9f2a1b' "a commit hash leaked from a worker note"
  assert_not_contains "$out" 'teardown refused' "a cleanup refusal leaked from a worker note"
  assert_not_contains "$out" '[key=' "a decision key token leaked from a worker note"
  pass "worker status notes never reach the captain's pane"
}

# Deliverable: outcome language only. This is a wording gate, so it asserts on
# the whole rendered frame rather than one section.
test_pane_carries_no_internal_vocabulary() {
  local home fb out term
  read -r home fb <<EOF
$(full_home wording)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  for term in \
    'worktree' 'teardown' 'crewmate' 'stale' 'wedge' 'harness' 'backend' \
    'wake queue' 'heartbeat' 'needs-decision' 'captain-held' 'fail-closed' \
    'fails closed' 'fail-open' 'secondmate' 'promote' 'brief'; do
    assert_not_contains "$out" "$term" "internal vocabulary '$term' reached the pane"
  done
  pass "the pane carries no internal vocabulary"
}

test_under_way_gives_one_outcome_line_per_worker() {
  local home fb out under
  read -r home fb <<EOF
$(full_home underway)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  under=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/')
  assert_contains "$under" 'Ship the alpha widget' "a live worker shows its outcome"
  assert_contains "$under" 'Alpha' "a live worker shows its project"
  assert_contains "$under" 'WORKING' "a reporting worker shows a state"
  assert_contains "$under" 'NEEDS YOU' "a parked worker is called out"
  assert_contains "$under" 'BLOCKED' "a blocked worker is called out"
  printf '%s\n' "$under" | grep -Eq 'heard [0-9]+[smhd] ago' \
    || fail "under way does not say how long ago each worker was last heard"
  # Most urgent first: the parked worker outranks the merely working one.
  local parked working
  parked=$(printf '%s\n' "$under" | awk '/NEEDS YOU/ {print NR; exit}')
  working=$(printf '%s\n' "$under" | awk '/WORKING/ {print NR; exit}')
  [ -n "$parked" ] && [ -n "$working" ] && [ "$parked" -lt "$working" ] \
    || fail "under way is not most-urgent-first (lines $parked, $working)"
  pass "under way gives one outcome line per worker, most urgent first"
}

# The pane is always on in a real terminal, so a row wider than the width it was
# drawn for does not get clipped - it WRAPS, spilling its tail onto its own line
# and breaking the one thing this section is for: scanning straight down the
# state dot. Every state dot is an east-asian wide glyph and so is the title's
# anchor, which len() counts as one column and a terminal draws as two, so
# nothing that measured characters could see the overrun coming. This test
# measures what the terminal draws, over the whole frame, at two of the widths
# the wrap was first seen in.
test_every_rendered_line_fits_the_width_it_was_drawn_for() {
  local home fb cols out over rules bad wide plain header offsets rows distinct
  read -r home fb <<EOF
$(full_home width)
EOF
  # A worker that has not reported yet draws the widest row this section can:
  # "not reported yet" is longer than any "heard <age> ago", and it carries a
  # state dot in front of a project label and an outcome that both need cutting.
  # Its wide glyphs also put clip() on the spot, since a cell cut by character
  # count can stop half way through one.
  fm_write_meta "$home/state/quiet-task.meta" \
    "window=default:w1:p4" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Zeevaart 🚢 Noord" "harness=claude" \
    "outcome=Wait on the vendor 🚚 for the spare part list before the quarter closes"

  # 118 and 100 are the widths the wrap was first reproduced at, and both sit
  # inside the MIN_WIDTH..MAX_WIDTH range bin/fm-deck-render.py clamps to.
  for cols in 118 100; do
    out=$(FM_DECK_COLUMNS="$cols" run_deck "$home" "$fb" --once 2>&1)

    # 1. Nothing may overrun the frame. This is the assertion that fails when a
    #    change goes back to counting characters.
    over=$(printf '%s\n' "$out" | frame_widths \
      | awk -F'\t' -v w="$cols" '$2 > w { printf "  %s cols: %s\n", $2, $3 }')
    [ -z "$over" ] || fail "at width $cols the frame overruns and wraps:"$'\n'"$over"

    # 2. And the frame must still FILL its width, so the fix cannot be "measure
    #    everything as double and let every line fall short". The rules are the
    #    only lines drawn to the full width, so they pin the scale.
    rules=$(printf '%s\n' "$out" | rule_widths)
    [ -n "$rules" ] || fail "no rule was measured at width $cols, so the scale is unpinned"
    bad=$(printf '%s\n' "$rules" | awk -v w="$cols" '$1 != w { print; exit }')
    [ -z "$bad" ] || fail "at width $cols a rule measured $bad columns, expected $cols"

    # 3. A row that really carries a wide state dot, and a row that carries no
    #    wide glyph at all: both must have been measured above, or this test
    #    proves nothing about either.
    wide=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/' | frame_widths \
      | awk -F'\t' '$2 > $1' | wc -l | tr -d ' ')
    [ "$wide" -ge 1 ] \
      || fail "at width $cols no UNDER WAY row carried a wide state dot to measure"
    plain=$(printf '%s\n' "$out" | frame_widths \
      | awk -F'\t' '$1 == $2 && $1 > 30 && $3 ~ /^ +[A-Za-z]/' | wc -l | tr -d ' ')
    [ "$plain" -ge 1 ] \
      || fail "at width $cols no plain row without a wide glyph was measured"

    # 4. The header carries the clock at the right edge, so an under-measured
    #    title splits it across two lines. It has to land exactly on the width.
    header=$(printf '%s\n' "$out" | frame_widths | awk -F'\t' '$3 ~ /ACTION DECK/ { print $2 }')
    [ "$header" = "$cols" ] \
      || fail "the header measured $header columns at width $cols, so the clock wraps"
    printf '%s\n' "$out" | grep -Eq 'ACTION DECK.*[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$' \
      || fail "at width $cols the header clock is not whole at the right edge"

    # 5. The outcome column cannot shift from row to row, whatever the width of
    #    the dot in front of it: every row hands its "heard" text to the same
    #    display column.
    offsets=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/' | under_way_offsets)
    rows=$(printf '%s\n' "$offsets" | grep -c . || true)
    [ "$rows" -ge 4 ] || fail "only $rows UNDER WAY rows were measured at width $cols"
    distinct=$(printf '%s\n' "$offsets" | sort -u | grep -c . || true)
    [ "$distinct" -eq 1 ] \
      || fail "UNDER WAY rows start their last column at $distinct different columns"
  done
  pass "every rendered line fits the width it was drawn for, wide state dots and all"
}

# A trailing `resolved:` line is an event about a decision, not the crew's word
# about the work. Reading the state off it renders a finished or failed worker as
# still working, which is the wrong direction to be wrong on the captain's pane.
# Also pins that every verb the status vocabulary defines maps deliberately,
# rather than a common verb landing on the right label only by coincidence.
test_state_projection_reads_past_a_trailing_resolve() {
  local home fb out under
  read -r home fb <<EOF
$(full_home resolve)
EOF
  # Finished, then an unrelated decision was resolved afterwards.
  {
    printf 'working: started\n'
    printf 'needs-decision [key=q1]: which shape\n'
    printf 'done: ready in branch\n'
    printf 'resolved [key=q1]: chose two\n'
  } > "$home/state/ship-task.status"
  # Failed, then an unrelated decision was resolved afterwards.
  {
    printf 'needs-decision [key=q2]: which vendor\n'
    printf 'failed: the importer cannot parse the feed\n'
    printf 'resolved [key=q2]: chose the other vendor\n'
  } > "$home/state/parked-task.status"
  # A declared pause behind a trailing resolve that closed an ordinary decision.
  {
    printf 'needs-decision [key=q3]: which window\n'
    printf 'paused: waiting on the vendor release\n'
    printf 'resolved [key=q3]: chose next week\n'
  } > "$home/state/stuck-task.status"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  under=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/')
  printf '%s\n' "$under" | grep -q 'READY .*Ship the alpha widget' \
    || fail "a finished worker behind a trailing resolve is not shown as ready"
  printf '%s\n' "$under" | grep -q 'FAILED .*Rework the beta importer' \
    || fail "a failed worker behind a trailing resolve is not shown as failed"
  printf '%s\n' "$under" | grep -q 'WAITING .*Investigate the delta timeouts' \
    || fail "a paused worker behind a trailing resolve is not shown as waiting"
  assert_not_contains "$under" 'WORKING' "a trailing resolve was read as progress"
  pass "the state projection reads past a trailing resolve and maps every known verb"
}

# A worker whose decision has been resolved but which has not written its next
# line has said nothing about the work, so the pane says it is waiting. Every
# verb the status vocabulary defines maps deliberately: landing on the right
# label through the unrecognised-verb arm would rank the worker below every
# paused one and below a finished one in UNDER WAY.
test_resolved_decisions_project_the_waiting_state() {
  local home fb out under outcome waiting finished
  home=$(make_home verbs)
  fb=$(fm_fakebin "$home")
  install_fake_tasks_axi "$fb" empty

  write_verb_worker "$home" keyed-decision "Choose the alpha shape"
  {
    printf 'needs-decision [key=q1]: which shape\n'
    printf 'resolved [key=q1]: chose two\n'
  } > "$home/state/keyed-decision.status"

  write_verb_worker "$home" keyed-block "Restore the beta feed"
  {
    printf 'blocked [key=q2]: no credential for the vendor portal\n'
    printf 'resolved [key=q2]: the credential arrived\n'
  } > "$home/state/keyed-block.status"

  write_verb_worker "$home" only-resolves "Settle the gamma question"
  printf 'resolved: settled out of band\n' > "$home/state/only-resolves.status"

  # Legacy bare lines, with no key, fold onto the default key the same way.
  write_verb_worker "$home" legacy-decision "Pick the delta window"
  {
    printf 'needs-decision: which window\n'
    printf 'resolved: next week\n'
  } > "$home/state/legacy-decision.status"

  write_verb_worker "$home" finished "Land the epsilon migration"
  printf 'done: ready in branch\n' > "$home/state/finished.status"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  under=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/')
  for outcome in 'Choose the alpha shape' 'Restore the beta feed' \
    'Settle the gamma question' 'Pick the delta window'; do
    printf '%s\n' "$under" | grep -q "WAITING .*$outcome" \
      || fail "a resolved decision does not project the waiting state: $outcome"
  done
  printf '%s\n' "$under" | grep -q 'READY .*Land the epsilon migration' \
    || fail "a finished worker is not shown as ready"
  assert_not_contains "$under" 'WORKING' "a resolved decision was read as progress"

  # The waiting workers outrank the finished one; the unrecognised-verb arm
  # would sort them below it.
  waiting=$(printf '%s\n' "$under" | awk '/Pick the delta window/ {print NR; exit}')
  finished=$(printf '%s\n' "$under" | awk '/Land the epsilon migration/ {print NR; exit}')
  [ -n "$waiting" ] && [ -n "$finished" ] && [ "$waiting" -lt "$finished" ] \
    || fail "a resolved decision sorts below a finished worker (lines $waiting, $finished)"
  pass "a resolved decision projects the waiting state and sorts with the waiting workers"
}

# A worker that died is not a pull request ready to look at, and one task must
# ask him for one thing, not two.
test_needs_you_withholds_failed_reviews_and_dedupes_by_task() {
  local home fb out needs answers reviews
  read -r home fb <<EOF
$(full_home asks)
EOF
  # Opened a PR, then died. The backlog still carries the same PR link.
  printf 'failed: the importer cannot parse the feed\n' > "$home/state/ship-task.status"
  # Parked on a decision AND carrying a PR: one task, one ask.
  fm_write_meta "$home/state/parked-task.meta" \
    "window=default:w1:p2" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Rework the beta importer" \
    "pr=https://github.com/acme/alpha/pull/9"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')
  assert_not_contains "$needs" 'pull/7' "a dead worker's pull request was offered for review"
  assert_not_contains "$needs" 'Ship the alpha widget' "a dead worker was presented as a review"

  # The parked worker asks once, for the thing that actually blocks it: its own
  # pull request is not a second demand while its decision is still open.
  # grep -c exits 1 on a zero count, and errexit is on by this point in the file.
  answers=$(printf '%s\n' "$needs" | grep -c 'Rework the beta importer' || true)
  [ "$answers" -eq 1 ] \
    || fail "one parked task with a pull request produced $answers rows, expected 1"
  printf '%s\n' "$needs" | grep -q 'answer .*Rework the beta importer' \
    || fail "the surviving row does not ask him to answer"
  assert_not_contains "$needs" 'pull/9' "the parked worker was asked for twice"
  reviews=$(printf '%s\n' "$needs" | grep -c 'review ' || true)
  [ "$reviews" -eq 0 ] \
    || fail "needs you offered $reviews reviews when no work was ready for one"
  pass "needs you withholds a failed worker's pull request and asks once per task"
}

# A worker that reports done is finished, not reviewed. While its backlog row is
# still in flight - the normal window before the merge and cleanup flow closes
# that row - its pull request is genuinely ready to look at, and it reaches the
# pane through that backlog row exactly as it did before a dead worker's pull
# request was suppressed.
test_needs_you_keeps_a_finished_workers_ready_pull_request() {
  local home fb out needs reviews
  read -r home fb <<EOF
$(full_home ready)
EOF
  printf 'done: ready in branch\n' > "$home/state/ship-task.status"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')
  assert_contains "$needs" 'https://github.com/acme/alpha/pull/7' \
    "a finished worker's ready pull request left the pane"
  printf '%s\n' "$needs" | grep -q 'review .*Ship the alpha widget' \
    || fail "the review row does not name the work that is ready"
  reviews=$(printf '%s\n' "$needs" | grep -c 'review ' || true)
  [ "$reviews" -eq 1 ] \
    || fail "a finished worker's pull request produced $reviews review rows, expected 1"
  pass "a finished worker's ready pull request still reaches needs you once"
}

# One finished worker with a recorded pull request, and this home's backlog
# hidden the way <condition> hides it. Prints "<home> <fakebin> <path>" on ONE
# line, so a caller can `read -r home fb path`; no path built under
# fm_test_tmproot can contain a space.
backlogless_home() {  # <name> <condition> -> "<home> <fakebin> <path>"
  local home fb
  read -r home fb <<EOF
$(full_home "$1")
EOF
  printf 'done: ready in branch\n' > "$home/state/ship-task.status"
  case "$2" in
    no-tool) rm -f "$fb/tasks-axi" ;;
    no-file) rm -f "$home/data/backlog.md" ;;
    unreadable)
      printf '#!/usr/bin/env bash\nexit 3\n' > "$fb/tasks-axi"
      chmod +x "$fb/tasks-axi"
      ;;
    manual) printf 'manual\n' > "$home/config/backlog-backend" ;;
    *) fail "unknown masking condition $2" ;;
  esac
  # A pinned PATH, because the real backlog reader is installed on the machines
  # this suite runs on: without it the "not installed" condition silently tests
  # the real tool against the fixture backlog instead.
  printf '%s %s %s\n' "$home" "$fb" "$fb:/usr/bin:/bin"
}

# A finished worker's pull request reaches NEEDS YOU through its backlog row, so
# when the backlog cannot be read at all that row never arrives and the ready
# work drops off the one pane it was certain to be seen on. Each condition below
# hides the same backlog a different way; the pull request has to survive all
# four, and the pane has to say why it is falling back to its own record rather
# than presenting the work as reviewed and ready.
test_needs_you_keeps_a_recorded_pull_request_when_the_backlog_is_unreadable() {
  local cond home fb path out needs rows caveat row
  for cond in no-tool no-file unreadable manual; do
    read -r home fb path <<EOF
$(backlogless_home "gap-$cond" "$cond")
EOF
    out=$(PATH="$path" run_deck "$home" "$fb" --once 2>&1)
    needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')

    assert_contains "$needs" 'https://github.com/acme/alpha/pull/7' \
      "$cond: the recorded pull request left the pane"
    printf '%s\n' "$needs" | grep -q 'check .*Ship the alpha widget' \
      || fail "$cond: the fallback row does not name the work that is waiting"
    rows=$(printf '%s\n' "$needs" | grep -c 'https://github.com/acme/alpha/pull/7' || true)
    [ "$rows" -eq 1 ] \
      || fail "$cond: the pull request produced $rows rows, expected 1"
    assert_contains "$needs" 'rows it alone would raise are missing' \
      "$cond: the section does not say the backlog is unavailable"
    assert_contains "$needs" 'not confirmed here' \
      "$cond: the section does not say the fallback row is unconfirmed"
    # A caveat standing under the rows it describes is captioning whatever
    # section comes next, so it has to head them.
    caveat=$(printf '%s\n' "$needs" | awk '/not confirmed here/ {print NR; exit}')
    row=$(printf '%s\n' "$needs" | awk '/check .*Ship the alpha widget/ {print NR; exit}')
    [ -n "$caveat" ] && [ -n "$row" ] && [ "$caveat" -lt "$row" ] \
      || fail "$cond: the caveat does not head the rows it describes (lines $caveat, $row)"
    # A recorded URL and an old status line say the branch exists, never that
    # its checks passed or that it is fit to merge.
    assert_not_contains "$needs" 'green' "$cond: the pane asserted a check result"
    assert_not_contains "$needs" 'merge' "$cond: the pane asserted merge readiness"
    assert_not_contains "$needs" 'ready in branch' "$cond: a worker status note reached the pane"
    # The worker-fed rows the backlog never carried are untouched by all this.
    assert_contains "$needs" 'Rework the beta importer' "$cond: worker-fed rows stopped rendering"
  done
  pass "a recorded pull request survives every way this home's backlog can go unreadable"
}

# The fallback is a fallback: with the backlog readable the pane must look
# exactly as it did, one review row carried by the backlog and no commentary
# about a source it read without trouble.
test_needs_you_stays_quiet_when_the_backlog_reads_normally() {
  local home fb out needs rows
  read -r home fb <<EOF
$(full_home quiet-source)
EOF
  printf 'done: ready in branch\n' > "$home/state/ship-task.status"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')
  rows=$(printf '%s\n' "$needs" | grep -c 'https://github.com/acme/alpha/pull/7' || true)
  [ "$rows" -eq 1 ] \
    || fail "a readable backlog produced $rows rows for one pull request, expected 1"
  printf '%s\n' "$needs" | grep -q 'review .*Ship the alpha widget' \
    || fail "the backlog's own review row stopped carrying the finished work"
  assert_not_contains "$needs" 'check ' "the fallback row fired against a readable backlog"
  assert_not_contains "$needs" 'rows it alone would raise are missing' \
    "a readable backlog was reported as unavailable"
  pass "a readable backlog still carries the review row, with nothing added"
}

# The same masking condition must not invent an ask. With no pull request on
# record there is nothing to fall back to, so the section says only what it
# could not see and offers no row and no unconfirmed-record caveat.
test_needs_you_invents_no_pull_request_when_none_is_recorded() {
  local home fb path out needs
  read -r home fb path <<EOF
$(backlogless_home no-record no-tool)
EOF
  # The finished worker has no pull request at all - only a status line.
  fm_write_meta "$home/state/ship-task.meta" \
    "window=default:w1:p1" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Ship the alpha widget"

  out=$(PATH="$path" run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')
  assert_not_contains "$needs" 'https://github.com/acme/alpha/pull/7' \
    "a pull request was shown for a worker that never recorded one"
  assert_not_contains "$needs" 'check ' "an ask was invented with nothing behind it"
  assert_contains "$needs" 'rows it alone would raise are missing' \
    "the section does not say the backlog is unavailable"
  assert_not_contains "$needs" 'not confirmed here' \
    "the unconfirmed-record caveat was printed with no row under it"
  pass "an unreadable backlog with no recorded pull request invents no ask"
}

# Two records of the same pull request - the worker's own and the backlog's -
# are one thing to look at, not two. The worker here is still working, so its
# own row is the one that renders and the backlog's must not repeat it.
test_needs_you_shows_one_row_when_task_and_backlog_carry_the_same_pull_request() {
  local home fb out needs rows
  read -r home fb <<EOF
$(full_home duplicate)
EOF
  printf 'working: pushed the branch\n' > "$home/state/ship-task.status"
  # A second worker recording the identical URL: still one thing to look at.
  fm_write_meta "$home/state/twin-task.meta" \
    "window=default:w1:p9" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Ship the alpha widget again" \
    "pr=https://github.com/acme/alpha/pull/7"
  printf 'working: pushed the same branch\n' > "$home/state/twin-task.status"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')
  rows=$(printf '%s\n' "$needs" | grep -c 'https://github.com/acme/alpha/pull/7' || true)
  [ "$rows" -eq 1 ] \
    || fail "one pull request with three records produced $rows rows, expected 1"
  pass "one pull request asks for one look however many records carry it"
}

# The renderer driven on its own with only the sections NEEDS YOU reads, so the
# rules below can pin an order between task records without depending on the
# order this machine's state directory happens to glob in. Task lines arrive on
# stdin in the order collect_tasks would have emitted them; the optional fourth
# argument is the whole backlog listing, exactly as the reader prints it.
render_needs() {  # <backlog-status> <needs-limit> <width> [backlog-listing]
  local backlog_state=$1 limit=$2 cols=$3 listing=${4:-}
  {
    printf '%s now\n%s\n' "$MARK" "$NOW"
    printf '%s width\n%s\n' "$MARK" "$cols"
    printf '%s home\nStarship\n' "$MARK"
    printf '%s interval\n\n' "$MARK"
    printf '%s limits\n5\t5\t%s\n' "$MARK" "$limit"
    printf '%s vocabulary\n' "$MARK"
    printf '%s tray\n[]\n' "$MARK"
    printf '%s orders\n' "$MARK"
    printf '%s backlog\n' "$MARK"
    if [ -n "$listing" ]; then printf '%s\n' "$listing"; fi
    printf '%s backlog_status\n%s\n' "$MARK" "$backlog_state"
    printf '%s tasks\n' "$MARK"
    cat
    printf '%s loose_ends\n' "$MARK"
  } | python3 "$RENDER" "$MARK" | awk '/NEEDS YOU/,/UNDER WAY/'
}

# The one pull request the rules below share, and the backlog listing that
# carries it too, so "one look per pull request" is tested with a real second
# source standing behind the task records rather than an empty one.
SHARED_PR='https://github.com/acme/alpha/pull/7'
shared_pr_backlog() {
  printf 'count: 1\n'
  printf 'tasks[1]{id,state,kind,repo,title,hold_kind,hold_reason,links,closed,blocked_by,held,priority}:\n'
  printf '  ship-task,in_flight,ship,alpha,"Ship the alpha widget","-","-","pr:%s","-",none,no,"-"\n' \
    "$SHARED_PR"
}

# A record that died on a pull request still claims its URL, so the backlog
# cannot re-raise the review this pane withheld - but claiming it is not the
# same as speaking for it. A retry running on the same branch is a live ask, and
# whichever of the two the state directory happens to list first must not decide
# whether the captain hears about it.
test_needs_you_keeps_a_live_review_a_dead_record_shares_a_url_with() {
  local order tasks needs rows
  for order in dead-first live-first; do
    case "$order" in
      dead-first)
        tasks=$(
          printf 'a-ship-task\tship\tAlpha\tShip the alpha widget\tfailed\t120\t%s\n' "$SHARED_PR"
          printf 'b-ship-retry\tship\tAlpha\tShip the alpha widget again\tworking\t120\t%s\n' "$SHARED_PR"
        )
        ;;
      *)
        tasks=$(
          printf 'a-ship-retry\tship\tAlpha\tShip the alpha widget again\tworking\t120\t%s\n' "$SHARED_PR"
          printf 'b-ship-task\tship\tAlpha\tShip the alpha widget\tfailed\t120\t%s\n' "$SHARED_PR"
        )
        ;;
    esac
    needs=$(printf '%s\n' "$tasks" | render_needs ok 5 120 "$(shared_pr_backlog)")
    printf '%s\n' "$needs" | grep -q 'review .*Ship the alpha widget again' \
      || fail "$order: a dead record spoke over the live retry sharing its pull request"
    assert_not_contains "$needs" 'Ship the alpha widget ·' \
      "$order: the dead record was offered for review"
    rows=$(printf '%s\n' "$needs" | grep -c "$SHARED_PR" || true)
    [ "$rows" -eq 1 ] \
      || fail "$order: one pull request with three records produced $rows rows, expected 1"
  done
  pass "a dead record claims a pull request without silencing the live one"
}

# The same rule with the backlog hidden: the finished record's fallback is the
# weakest ask this pane makes, so a worker still running on that branch outranks
# it and the captain is asked to review rather than to check.
test_needs_you_prefers_the_strongest_ask_a_shared_pull_request_carries() {
  local needs rows
  needs=$(
    {
      printf 'a-ship-task\tship\tAlpha\tShip the alpha widget\tdone\t120\t%s\n' "$SHARED_PR"
      printf 'b-ship-retry\tship\tAlpha\tShip the alpha widget again\tworking\t120\t%s\n' "$SHARED_PR"
    } | render_needs no-tool 5 120
  )
  rows=$(printf '%s\n' "$needs" | grep -c "$SHARED_PR" || true)
  [ "$rows" -eq 1 ] \
    || fail "one pull request with two records produced $rows rows, expected 1"
  printf '%s\n' "$needs" | grep -q 'review .*Ship the alpha widget again' \
    || fail "a finished record's fallback outranked a worker still on the branch"
  assert_not_contains "$needs" 'check ' "the weaker ask survived alongside the stronger one"
  pass "several records of one pull request collapse into its strongest ask"
}

# The needs limit drops the lowest-ranked rows first, and the fallback "check"
# is the lowest rank there is. Once it has been cut, the caveat describing it is
# a caption over rows that came from somewhere else entirely.
test_needs_you_drops_the_caveat_with_the_row_it_describes() {
  local needs
  needs=$(
    {
      printf 'parked-task\tship\tAlpha\tRework the beta importer\tparked\t120\t\n'
      printf 'stuck-task\tship\tAlpha\tInvestigate the delta timeouts\tblocked\t120\t\n'
      printf 'ship-task\tship\tAlpha\tShip the alpha widget\tdone\t120\t%s\n' "$SHARED_PR"
    } | render_needs no-tool 2 120
  )
  assert_not_contains "$needs" "$SHARED_PR" "the fixture did not truncate its fallback row"
  assert_contains "$needs" 'rows it alone would raise are missing' \
    "the section stopped saying the backlog is unavailable"
  assert_not_contains "$needs" 'not confirmed here' \
    "the caveat outlived the fallback row it describes"
  pass "the unconfirmed-record caveat is cut with the row it describes"
}

# Narrow terminals are where this pane is actually read, and clip() takes the
# end of a line. The uncertainty is the half that must not be what gets taken.
test_needs_you_keeps_its_caveat_readable_at_the_minimum_width() {
  local needs
  needs=$(
    printf 'ship-task\tship\tAlpha\tShip the alpha widget\tdone\t120\t%s\n' "$SHARED_PR" \
      | render_needs unreadable 5 40
  )
  assert_contains "$needs" 'not confirmed here' \
    "the caveat lost its uncertainty to the clip at the minimum width"
  assert_contains "$needs" 'the backlog could not be read' \
    "the section lost what it could not read to the clip at the minimum width"
  assert_contains "$needs" "$SHARED_PR" "the fallback row left the pane at the minimum width"
  pass "both source-availability lines survive the clip at the minimum width"
}

# bin/fm-deck-render.py owns the frame: bin/fm-deck.sh hands it the payload and
# it decides the sections, the counts strip, and what may reach the terminal.
test_renderer_presents_the_payload_the_deck_collects() {
  local out
  out=$(render_payload '' '' | python3 "$RENDER" "$MARK")
  assert_contains "$out" 'ACTION DECK · Starship' "the renderer draws the title"
  assert_contains "$out" 'STAGED FOR YOUR CLICK' "the renderer draws the staged section"
  assert_contains "$out" 'hubspot://note-1' "the renderer draws the staged target"
  assert_contains "$out" 'NEEDS YOU' "the renderer draws the needs-you section"
  assert_contains "$out" 'Authorise the Sweden field visit' "the renderer draws a decision"
  assert_contains "$out" 'LOOSE ENDS' "the renderer draws the loose ends section"
  assert_contains "$out" 'Reply to Jordan' "the renderer draws a loose end"
  assert_contains "$out" 'UNDER WAY' "the renderer draws the under-way section"
  assert_contains "$out" 'Ship the alpha widget' "the renderer draws a worker outcome"
  assert_contains "$out" 'snapshot' "a payload with no interval renders as a snapshot"
  pass "bin/fm-deck-render.py turns the deck's payload into the pane"
}

# The pane is always on and captain-private, so an escape sequence written by a
# worker could move his cursor, clear regions, or forge a whole frame. One place
# on the way to the terminal refuses C0 and C1; nothing may route around it.
test_control_characters_never_reach_the_terminal() {
  local home fb out esc bel c1
  esc=$(printf '\033')
  bel=$(printf '\007')
  c1=$(printf '\302\233')

  out=$(render_payload "${esc}[2J${bel}${c1}" '\u001b[2J\u009b' | python3 "$RENDER" "$MARK")
  assert_no_control_characters "$out" "the renderer let a control character through"
  assert_contains "$out" 'hubspot://note-1' "scrubbing the target dropped the target"
  assert_contains "$out" 'Ship the alpha widget' "scrubbing the outcome dropped the outcome"
  assert_contains "$out" 'Authorise the Sweden field visit' "scrubbing a title dropped the title"
  assert_contains "$out" 'Reply to Jordan' "scrubbing a loose end dropped the loose end"

  # And end to end, through every collector bin/fm-deck.sh runs.
  read -r home fb <<EOF
$(full_home control)
EOF
  cat > "$home/data/action-gateway/action-audit.log" <<'JSONL'
{"ts":1700000000,"event":"prepared","state":"prepared","request_id":"r-1","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expires_at":1800000000,"requester_id":"worker-1","request":{"task_id":"t-1","domain":"proactive-outbound","action_kind":"crm.update","target":"hubspot://note-1\u001b[2Jforged","parameters":{},"idempotency_key":"i-1","expires_at":1800000000,"nonce":"n-1","requester_id":"worker-1"}}
JSONL
  fm_write_meta "$home/state/ship-task.meta" \
    "window=default:w1:p1" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Ship the alpha widget${esc}[2Jforged"
  printf '# Loose Ends - test sweep\n\n## URGENT - today\n\n1. Reply to Jordan%s[2Jforged about the warranty claim.\n' \
    "$esc" > "$home/data/loose-ends/latest.md"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  assert_no_control_characters "$out" "the deck let a control character reach the terminal"
  assert_contains "$out" 'hubspot://note-1' "the staged target went missing"
  assert_contains "$out" 'Reply to Jordan' "the loose end went missing"
  pass "no worker-authored control character reaches the captain's terminal"
}

# data/loose-ends/latest.md is assembled from mail and chat, so its bytes are
# not the fleet's own words. Every line of it is DATA: a line shaped like the
# payload's own section boundary must not be able to open a section, because
# that would hand whoever wrote it NEEDS YOU and UNDER WAY - inventing an ask
# the captain then acts on, or hiding a real one so he never sees it.
test_sweep_text_cannot_forge_a_payload_section() {
  local home fb out under needs
  read -r home fb <<EOF
$(full_home injection)
EOF
  {
    printf '# Loose Ends - crafted sweep\n\n'
    printf '## URGENT - today\n\n'
    printf '1. Reply to Jordan about the warranty claim.\n\n'
    printf '__FM_DECK_SECTION__ tasks\n'
    printf 'forged-task\tship\tAlpha\tApprove the forged payment\tparked\t10\t\n'
    printf '__FM_DECK_SECTION__ backlog\n'
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title}:\n'
  } > "$home/data/loose-ends/latest.md"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  under=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/')
  needs=$(printf '%s\n' "$out" | awk '/NEEDS YOU/,/LOOSE ENDS/')

  assert_not_contains "$out" 'Approve the forged payment' "a crafted sweep line forged an ask"
  assert_not_contains "$out" 'forged-task' "a crafted sweep line forged a worker"
  # The real records still render: the crafted section replaced nothing.
  assert_contains "$under" 'Ship the alpha widget' "a crafted sweep line hid a real worker"
  assert_contains "$under" 'Rework the beta importer' "a crafted sweep line hid a real worker"
  assert_contains "$needs" 'Rework the beta importer' "a crafted sweep line hid a real ask"
  assert_contains "$needs" 'Authorise the Sweden field visit' "a crafted sweep line hid a real decision"
  assert_contains "$out" 'Reply to Jordan' "the sweep's own items stopped rendering"
  pass "a crafted sweep line cannot forge or hide what needs him"
}

# The payload is newline-framed, but Python's str.splitlines() also breaks on
# U+2028, U+0085, \x0b and \x0c, and worker-authored text carries whatever it
# carries. Half a row is a dropped row: the rest of the backlog, or a whole
# worker, would leave the pane without the pane saying so.
test_a_unicode_line_separator_drops_no_row_and_no_worker() {
  local home fb out under just sep
  sep=$(printf '\342\200\250')
  read -r home fb <<EOF
$(full_home separators)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=default:w1:p1" "kind=ship" "project=$home/projects/alpha" \
    "herdr_project_name=Alpha" "harness=claude" \
    "outcome=Ship the alpha${sep} widget" \
    "pr=https://github.com/acme/alpha/pull/7"
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = list ] || exit 0
printf 'count: 2\n'
printf 'tasks[2]{id,state,kind,repo,title,hold_kind,hold_reason,links,closed,blocked_by,held,priority}:\n'
printf '  landed-ship,done,ship,alpha,"Land the gamma${sep} migration","-","-","pr:https://github.com/acme/alpha/pull/4",2026-09-02,none,no,"-"\n'
printf '  hold-one,queued,captain,alpha,"Authorise the Sweden field visit",captain,"needs the captain",none,"-",none,yes,"-"\n'
SH
  chmod +x "$fb/tasks-axi"

  out=$(run_deck "$home" "$fb" --once 2>&1)
  under=$(printf '%s\n' "$out" | awk '/UNDER WAY/,/JUST IN/')
  just=$(printf '%s\n' "$out" | awk '/JUST IN/,0')
  assert_contains "$under" 'Ship the alpha widget' "a separator inside an outcome dropped the worker"
  assert_contains "$under" 'Rework the beta importer' "a separator dropped a later worker"
  assert_contains "$just" 'Land the gamma migration' "a separator inside a title dropped the row"
  assert_contains "$out" 'Authorise the Sweden field visit' "a separator dropped every later backlog row"
  pass "a Unicode line separator drops neither a backlog row nor a worker"
}

test_just_in_shows_completions_with_their_artifact() {
  local home fb out just
  read -r home fb <<EOF
$(full_home justin)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  just=$(printf '%s\n' "$out" | awk '/JUST IN/,0')
  assert_contains "$just" 'merged' "a landed PR is labelled merged"
  assert_contains "$just" 'https://github.com/acme/alpha/pull/4' "the landed PR carries its full URL"
  assert_contains "$just" 'findings' "a completed investigation is labelled findings"
  assert_contains "$just" 'data/landed-scout/report.md' "the investigation points at its report"
  assert_contains "$just" 'Land the gamma migration' "the completion names the outcome"
  # tasks-axi truncates long titles and appends a pointer to `show --full`; that
  # machine chatter must not reach the pane.
  assert_not_contains "$just" 'truncated' "the backlog truncation pointer reached the pane"
  assert_not_contains "$just" '--full' "the backlog truncation pointer reached the pane"
  # Newest first.
  local newer older
  newer=$(printf '%s\n' "$just" | awk '/Land the gamma migration/ {print NR; exit}')
  older=$(printf '%s\n' "$just" | awk '/delta timeouts/ {print NR; exit}')
  [ -n "$newer" ] && [ -n "$older" ] && [ "$newer" -lt "$older" ] \
    || fail "just in is not newest-first (lines $newer, $older)"
  pass "just in shows recent completions and findings with their artifact"
}

test_loose_ends_headline_and_top_items() {
  local home fb out loose
  read -r home fb <<EOF
$(full_home loose)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  loose=$(printf '%s\n' "$out" | awk '/LOOSE ENDS/,/UNDER WAY/')

  # The sweep numbers its six real loose ends; its prose bullets are not items.
  assert_contains "$loose" '7 open' "the headline counts the sweep's own numbered items"
  printf '%s\n' "$loose" | grep -Eq 'swept [0-9]+[smhd] ago' \
    || fail "the headline does not say how fresh the sweep is"
  assert_contains "$loose" 'Reply to Jordan' "an urgent item is shown"
  assert_contains "$loose" 'firewall ports' "the second urgent item is shown"
  assert_contains "$loose" 'board order' "a waiting-external item is shown"
  assert_contains "$loose" 'urgent' "items are labelled by urgency"
  assert_contains "$loose" 'waiting' "items are labelled by urgency"
  assert_not_contains "$loose" 'already closed in person' "a prose correction is not an item"
  assert_not_contains "$loose" 'Expense receipts' "an admin item is not urgent or waiting"
  assert_not_contains "$loose" '**' "markdown emphasis reached the pane"

  # Urgent outranks waiting.
  local first_urgent first_waiting
  first_urgent=$(printf '%s\n' "$loose" | awk '/Reply to Jordan/ {print NR; exit}')
  first_waiting=$(printf '%s\n' "$loose" | awk '/board order/ {print NR; exit}')
  [ -n "$first_urgent" ] && [ -n "$first_waiting" ] && [ "$first_urgent" -lt "$first_waiting" ] \
    || fail "loose ends are not urgent-before-waiting (lines $first_urgent, $first_waiting)"

  # Six urgent-or-waiting items, five shown, so one spills into the more line.
  assert_contains "$loose" 'more urgent or waiting' "the overflow pointer is shown"
  pass "loose ends shows a headline count and the top urgent and waiting items"
}

test_loose_ends_present_but_quiet() {
  local home fb out loose
  read -r home fb <<EOF
$(full_home quiet-loose)
EOF
  cat > "$home/data/loose-ends/latest.md" <<'EOF'
# Loose Ends - clean sweep

## Admin / low

1. Expense receipts are missing.
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  loose=$(printf '%s\n' "$out" | awk '/LOOSE ENDS/,/UNDER WAY/')
  assert_contains "$loose" '1 open' "the headline still counts every item"
  assert_contains "$loose" 'nothing urgent or waiting' "a quiet sweep says so plainly"
  pass "a sweep with nothing urgent or waiting renders an honest line"
}

test_counts_strip_summarizes_every_section() {
  local home fb out strip
  read -r home fb <<EOF
$(full_home counts)
EOF
  out=$(run_deck "$home" "$fb" --once 2>&1)
  strip=$(printf '%s\n' "$out" | sed -n 3p)
  assert_contains "$strip" 'need you' "the counts strip covers what needs him"
  assert_contains "$strip" '3 staged' "the counts strip covers staged actions"
  assert_contains "$strip" 'oldest 1h' "the counts strip leads staged with age"
  assert_contains "$strip" '7 loose ends' "the counts strip covers loose ends"
  assert_contains "$strip" '3 under way' "the counts strip covers live work"
  pass "the counts strip summarizes every section above the fold"
}

test_manual_backlog_backend_degrades_honestly() {
  local home fb out rc
  read -r home fb <<EOF
$(full_home manual)
EOF
  printf 'manual\n' > "$home/config/backlog-backend"
  set +e
  out=$(run_deck "$home" "$fb" --once 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "manual backend exit"
  # The backlog-fed rows go quiet; the state-fed sections keep working.
  assert_contains "$out" 'nothing has landed recently' "just-in degrades honestly"
  assert_not_contains "$out" 'Authorise the Sweden field visit' "backlog rows are not read"
  assert_contains "$out" 'Rework the beta importer' "worker-fed rows still render"
  assert_contains "$out" 'proactive-outbound' "staged actions still render"
  pass "a hand-edited backlog degrades the backlog-fed rows without breaking the pane"
}

test_read_only_refuses_acting_verbs() {
  local home fb out rc verb before after
  read -r home fb <<EOF
$(full_home readonly)
EOF
  for verb in approve execute merge arm disarm graduate; do
    set +e
    out=$(run_deck "$home" "$fb" "$verb" 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "$verb exit"
    assert_contains "$out" 'read-only view' "the pane refuses $verb by name"
  done
  # And a full render must leave every durable record byte-identical.
  before=$(find "$home/data" "$home/state" -type f -exec cksum {} \; | LC_ALL=C sort)
  run_deck "$home" "$fb" --once >/dev/null 2>&1
  after=$(find "$home/data" "$home/state" -type f -exec cksum {} \; | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "rendering the pane changed a durable record"
  pass "the pane refuses acting verbs and writes nothing"
}

test_interval_validation() {
  local home fb out rc
  home=$(make_home interval)
  fb=$(fm_fakebin "$home")
  install_fake_tasks_axi "$fb" empty
  for bad in 0 -5 abc ''; do
    set +e
    out=$(run_deck "$home" "$fb" --interval "$bad" 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "--interval '$bad' exit"
    assert_contains "$out" 'positive whole number' "--interval '$bad' is refused by name"
  done
  set +e
  out=$(run_deck "$home" "$fb" --interval 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "--interval with no value exit"
  assert_contains "$out" 'requires seconds' "a bare --interval is refused"
  pass "--interval refuses anything but a positive whole number of seconds"
}

# The refresh loop is bounded here through FM_DECK_MAX_FRAMES rather than by
# killing a process: a killed wrapper leaves the real script running, and a pane
# that keeps drawing into a closed pipe is exactly the hang this suite must not
# have. Each frame must re-read the records, not replay the first frame.
test_refresh_loop_redraws_and_reflects_changes() {
  local home fb out rc frames
  read -r home fb <<EOF
$(full_home refresh)
EOF
  # Appears only after the first frame has been drawn.
  ( sleep 1
    fm_write_meta "$home/state/late-task.meta" \
      "window=default:w1:p9" "kind=ship" "project=$home/projects/alpha" \
      "herdr_project_name=Alpha" "outcome=Fix the epsilon report"
    printf 'working: started\n' > "$home/state/late-task.status"
  ) &
  set +e
  out=$(FM_DECK_MAX_FRAMES=3 run_deck "$home" "$fb" --interval 1 2>&1)
  rc=$?
  set -e
  wait
  expect_code 0 "$rc" "bounded refresh loop exit"
  frames=$(printf '%s\n' "$out" | grep -c 'ACTION DECK')
  [ "$frames" -eq 3 ] || fail "the refresh loop drew $frames frames, expected 3"
  assert_contains "$out" 'refreshing every 1s' "the frame states its refresh cadence"
  assert_contains "$out" 'Fix the epsilon report' "a later frame did not re-read the records"
  printf '%s' "$out" | grep -q "$(printf '\033')" \
    || fail "the refresh loop did not clear the screen between frames"
  pass "the refresh loop redraws on its interval and re-reads records each frame"
}

# --json is the seam a second renderer reads: the bridge's /deck page shows this
# model, so it has to carry every section the pane draws, apply the same
# selection rules (one row per pull request, no completed work outside JUST IN,
# a failed worker's pull request withheld), and reach a browser with the same
# control-character scrub the terminal gets. The web page is presentation over
# this model and never re-derives "what needs him" from the raw records.
test_json_mode_emits_the_pane_as_one_model() {
  local home fb out rc
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not found for the --json model test"; return 0; }
  read -r home fb <<EOF
$(full_home json)
EOF
  set +e
  out=$(run_deck "$home" "$fb" --json 2>/dev/null)
  rc=$?
  set -e
  expect_code 0 "$rc" "--json exit"
  printf '%s' "$out" | jq -e '.schema == "fm-deck.v1"' >/dev/null || fail "--json did not emit the fm-deck.v1 model: $out"

  # Staged cards, grouped by order with the order's status alongside.
  [ "$(printf '%s' "$out" | jq -r '.staged.groups | length')" = 2 ] || fail "expected two staged groups: $out"
  [ "$(printf '%s' "$out" | jq -r '.staged.groups[0].order')" = proactive-outbound ] || fail "oldest group first: $out"
  [ "$(printf '%s' "$out" | jq -r '.staged.groups[0].status')" = ARMED ] || fail "order status missing: $out"
  [ "$(printf '%s' "$out" | jq -r '.staged.groups[0].cards | length')" = 2 ] || fail "two cards under the armed order: $out"
  [ "$(printf '%s' "$out" | jq -r '.staged.groups[1].status')" = null ] || fail "a domain with no order file has null status: $out"
  [ "$(printf '%s' "$out" | jq -r '[.staged.groups[].cards[] | select(.expired)] | length')" = 1 ] || fail "one expired card: $out"
  [ "$(printf '%s' "$out" | jq -r '[.staged.groups[].cards[] | select(.expired)][0].expiry')" = EXPIRED ] || fail "expired card wording: $out"
  printf '%s' "$out" | jq -e '.staged.quiet_orders[] | select(.order == "spares" and .status == "DRAFT")' >/dev/null \
    || fail "a quiet order is listed as watching: $out"

  # Needs-you rows: the same asks, one row per pull request, no completed work.
  [ "$(printf '%s' "$out" | jq -r '[.needs_you.rows[] | select(.ask == "answer")] | length')" = 1 ] || fail "one answer row: $out"
  [ "$(printf '%s' "$out" | jq -r '[.needs_you.rows[] | select(.ask == "unblock")] | length')" = 1 ] || fail "one unblock row: $out"
  [ "$(printf '%s' "$out" | jq -r '[.needs_you.rows[] | select(.url == "https://github.com/acme/alpha/pull/7")] | length')" = 1 ] \
    || fail "the shared pull request appears exactly once: $out"
  [ "$(printf '%s' "$out" | jq -r '[.needs_you.rows[].url | select(. != "")] | length')" = \
    "$(printf '%s' "$out" | jq -r '[.needs_you.rows[].url | select(. != "")] | unique | length')" ] \
    || fail "duplicate pull request urls in needs_you: $out"
  printf '%s' "$out" | jq -e '.needs_you.rows[] | select(.ask == "decide" and .title == "Authorise the Sweden field visit")' >/dev/null \
    || fail "the captain hold is a decide row: $out"
  [ "$(printf '%s' "$out" | jq -r '.counts.needs_you')" = "$(printf '%s' "$out" | jq -r '.needs_you.rows | length')" ] \
    || fail "counts.needs_you disagrees with the rows: $out"
  [ "$(printf '%s' "$out" | jq -r '.needs_you.backlog_status')" = ok ] || fail "backlog read normally: $out"
  [ "$(printf '%s' "$out" | jq -r '.needs_you.backlog_reason')" = null ] || fail "no caveat when the backlog reads: $out"
  printf '%s' "$out" | jq -e '[.needs_you.rows[], .under_way[]] | map(.title? // .outcome?) | index("Land the gamma migration") == null' >/dev/null \
    || fail "completed work leaked out of just_in: $out"

  # Under way carries the captain-facing label, never the worker's own note.
  [ "$(printf '%s' "$out" | jq -r '.under_way | length')" = 3 ] || fail "one row per recorded worker: $out"
  [ "$(printf '%s' "$out" | jq -r '.under_way[0].state')" = parked ] || fail "most urgent worker first: $out"
  [ "$(printf '%s' "$out" | jq -r '.under_way[0].label')" = 'NEEDS YOU' ] || fail "visible label resolved: $out"
  assert_not_contains "$out" 'no-mistakes run' "worker status note reached the model"
  assert_not_contains "$out" 'worktree HEAD' "worker status note reached the model"

  # Completions with their artifact, and the sweep with its bucketed items.
  [ "$(printf '%s' "$out" | jq -r '.just_in | length')" = 2 ] || fail "two completions: $out"
  [ "$(printf '%s' "$out" | jq -r '.just_in[0].artifact')" = 'https://github.com/acme/alpha/pull/4' ] || fail "merged artifact: $out"
  [ "$(printf '%s' "$out" | jq -r '.just_in[1].what')" = findings ] || fail "a scout completion is findings: $out"
  [ "$(printf '%s' "$out" | jq -r '.loose_ends.total')" -gt 0 ] || fail "loose ends total: $out"
  printf '%s' "$out" | jq -e '.loose_ends.items[0].bucket == "urgent"' >/dev/null || fail "loose end bucket: $out"
  pass "--json emits the whole pane as one fm-deck.v1 model with the pane's own selection rules"
}

test_json_mode_degrades_honestly_and_scrubs() {
  local home fb out esc
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not found for the --json degradation test"; return 0; }
  home=$(make_home json-empty)
  fb=$(fm_fakebin "$home")
  install_fake_tasks_axi "$fb" empty
  out=$(run_deck "$home" "$fb" --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.staged.groups | length')" = 0 ] || fail "empty staged: $out"
  [ "$(printf '%s' "$out" | jq -r '.needs_you.rows | length')" = 0 ] || fail "empty needs_you: $out"
  [ "$(printf '%s' "$out" | jq -r '.under_way | length')" = 0 ] || fail "empty under_way: $out"
  [ "$(printf '%s' "$out" | jq -r '.just_in | length')" = 0 ] || fail "empty just_in: $out"
  [ "$(printf '%s' "$out" | jq -r '.loose_ends')" = null ] || fail "no sweep is null, not an empty box: $out"
  [ "$(printf '%s' "$out" | jq -r '.counts.staged')" = 0 ] || fail "zero staged count: $out"

  # An unreadable backlog is reported as such, never as empty.
  printf 'manual\n' > "$home/config/backlog-backend"
  out=$(run_deck "$home" "$fb" --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.needs_you.backlog_status')" = manual ] || fail "manual backlog status: $out"
  printf '%s' "$out" | jq -e '.needs_you.backlog_reason | test("kept by hand")' >/dev/null || fail "manual backlog reason: $out"

  # The same scrub the terminal gets, so a browser never receives a control
  # byte, raw or as JSON's  escape.
  esc=$(printf '\033')
  out=$(render_payload "${esc}[2J" '\u001b[2J' | python3 "$RENDER" --json "$MARK")
  assert_no_control_characters "$out" "--json let a control character through"
  assert_not_contains "$out" '\u001b' "--json re-encoded a control character instead of dropping it"
  assert_contains "$out" 'hubspot://note-1' "scrubbing dropped the target from the model"
  pass "--json degrades to honest empties, names an unreadable backlog, and scrubs control characters"
}


test_help_exits_zero
test_empty_home_renders_honest_empty_sections
test_no_sources_at_all_still_renders
test_staged_actions_group_by_order_with_age_and_expiry
test_needs_you_carries_full_pr_urls_and_distinguishes_asks
test_worker_status_notes_never_reach_the_pane
test_pane_carries_no_internal_vocabulary
test_under_way_gives_one_outcome_line_per_worker
test_every_rendered_line_fits_the_width_it_was_drawn_for
test_state_projection_reads_past_a_trailing_resolve
test_resolved_decisions_project_the_waiting_state
test_needs_you_withholds_failed_reviews_and_dedupes_by_task
test_needs_you_keeps_a_finished_workers_ready_pull_request
test_needs_you_keeps_a_recorded_pull_request_when_the_backlog_is_unreadable
test_needs_you_stays_quiet_when_the_backlog_reads_normally
test_needs_you_invents_no_pull_request_when_none_is_recorded
test_needs_you_shows_one_row_when_task_and_backlog_carry_the_same_pull_request
test_needs_you_keeps_a_live_review_a_dead_record_shares_a_url_with
test_needs_you_prefers_the_strongest_ask_a_shared_pull_request_carries
test_needs_you_drops_the_caveat_with_the_row_it_describes
test_needs_you_keeps_its_caveat_readable_at_the_minimum_width
test_renderer_presents_the_payload_the_deck_collects
test_control_characters_never_reach_the_terminal
test_sweep_text_cannot_forge_a_payload_section
test_a_unicode_line_separator_drops_no_row_and_no_worker
test_just_in_shows_completions_with_their_artifact
test_loose_ends_headline_and_top_items
test_loose_ends_present_but_quiet
test_counts_strip_summarizes_every_section
test_manual_backlog_backend_degrades_honestly
test_read_only_refuses_acting_verbs
test_json_mode_emits_the_pane_as_one_model
test_json_mode_degrades_honestly_and_scrubs
test_interval_validation
test_refresh_loop_redraws_and_reflects_changes

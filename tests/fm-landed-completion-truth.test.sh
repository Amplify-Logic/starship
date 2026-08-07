#!/usr/bin/env bash
# Regression tests for the completion-truth property of firstmate's captain-facing
# landed surface: a task whose completion was JUST recorded with its date must appear
# in the very next report.
#
# What these tests pin is a just-finished row being CUT from a capped, NON-EMPTY
# landed list, reproduced directly against this fork. Every landed view caps its list
# with no time window at all, so the newest-first ordering is what decides which rows
# survive the cap; when that ordering was wrong, the cap silently discarded the newest
# completion instead of the oldest. Completion dates are day-granularity, so same-day
# completions tied and the tie was broken on id: a just-finished task with an
# alphabetically-low id lost its place to same-day completions that had finished
# earlier. That is the DEFAULT tasks-axi path and the defect actually fixed here.
#
# SCOPE, stated plainly: the pure-upstream trial
# (data/fm-upstream-trial-verdict-v2/report.md) reported a literally EMPTY "No recent
# completions are in the current baseline" section. A mis-ordering cannot produce that
# state, because both caps are positive-bounded slices and the round-robin takes index
# 0 of every non-empty home group. That symptom is NOT explained or fixed by this
# change. Two separate causes were verified against this fork and both still return an
# empty list against the finished fix, so both stay open as follow-ups: a Done row that
# is not in the structured `- [x] <id> - <rest>` form is silently excluded from landed,
# so even a NON-empty Done section can render an empty list; and a completion never
# written into Done at all - for example when the completion or cleanup step fails -
# never appears while the task still sits in In flight. Neither belongs here: the first
# is the backlog parser's structured-row contract, which every section shares, and the
# second is the completion/cleanup recording path.
#
# bin/fm-landed-lib.sh owns the ordering rule these tests hold to, including the
# ruling that a dated completion always outranks an undated one.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-landed-truth)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=2026-08-03T18:00:00Z
TODAY=2026-08-03

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  : > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

# Stub only the local tools the snapshot may reach for, and record any network call
# so these tests also prove the landed baseline stays local-only.
make_fakebin() {  # <home>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

run_bearings() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW="$NOW" NET_LOG="$home/net.log" \
    "$BEARINGS" "$@"
}

# A registered secondmate home with its own valid structured backlog, which is what the
# cross-home roll-up requires before a home's Done reaches the captain at all.
make_mate_home() {  # <parent> <id>
  local parent=$1 id=$2 mate
  mate="$TMP_ROOT/$(basename "$parent")-$id-home"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  printf -- '- %s - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$id" "$mate" >> "$parent/data/secondmates.md"
  printf '%s\n' "$mate"
}

# Write a Done section the way `tasks-axi done` actually writes it: newest completion
# PREPENDED to the top. Verified against tasks-axi 0.2.3, whose `done` inserts each
# newly completed row above the previous ones.
# Args after the header are Done rows, newest FIRST.
write_backlog() {  # <home> <row...>
  local home=$1; shift
  {
    printf '## In flight\n\n## Queued\n\n## Done\n'
    printf '%s\n' "$@"
  } > "$home/data/backlog.md"
}

done_row() {  # <id> <title> <verb> <date-or-empty>
  if [ -n "$4" ]; then
    printf -- '- [x] %s - %s (repo: firstmate) (kind: ship) (%s %s)' "$1" "$2" "$3" "$4"
  else
    printf -- '- [x] %s - %s (repo: firstmate) (kind: ship)' "$1" "$2"
  fi
}

landed_ids() {  # <json>
  printf '%s' "$1" | jq -r '.landed[].id'
}

# The exact trial failure shape on the DEFAULT backlog backend: several tasks complete
# on the same day, and the one that just finished has an id that sorts early. It must
# lead the landed list, not be cut from it.
test_just_finished_same_day_completion_leads_landed() {
  local home fakebin json ids rows i
  home=$(make_home same-day)
  rows=("$(done_row aaa-just-now "The scout that just finished" "done" "$TODAY")")
  for i in 1 2 3 4 5 6; do
    rows+=("$(done_row "zzz-earlier-$i" "Earlier same-day landing $i" "merged" "$TODAY")")
  done
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'aaa-just-now' \
    || fail "a completion recorded today vanished from landed: $ids"
  [ "$(printf '%s\n' "$ids" | head -1)" = "aaa-just-now" ] \
    || fail "the newest same-day completion must lead landed, got: $ids"
  [ ! -s "$home/net.log" ] \
    || fail "the landed baseline must make no network call, got: $(cat "$home/net.log")"
  pass "a just-finished same-day completion leads the landed baseline"
}

# The hand-edited / manual-backend path: a completion is recorded but not yet dated.
#
# This expectation is deliberately INVERTED from the one this file first shipped with,
# which asserted that an undated row LEADS the landed list because the ordering dated
# it as of the snapshot's own generation time. That approach is superseded: it let a
# home full of undated rows displace genuinely dated completions out of a capped list,
# which is the same trust failure inverted. The ruled contract, pinned here, is that
# dated evidence wins - an undated row sorts BELOW every dated row - while undated
# rows keep recording-position order among themselves so the newest of them still
# leads its own group.
test_undated_completion_sorts_below_every_dated_row() {
  local home fakebin json ids expected
  home=$(make_home undated)
  write_backlog "$home" \
    "$(done_row undated-first "Recorded first, still undated" "done" "")" \
    "$(done_row undated-second "Recorded second, still undated" "done" "")" \
    "$(done_row dated-jul-09 "Dated landing 09" "merged" "2026-07-09")" \
    "$(done_row dated-jul-05 "Dated landing 05" "merged" "2026-07-05")" \
    "$(done_row dated-jul-01 "Dated landing 01" "merged" "2026-07-01")"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")
  expected='dated-jul-09
dated-jul-05
dated-jul-01
undated-first
undated-second'

  [ "$ids" = "$expected" ] || fail "undated rows must sort below every dated row, got: $ids"
  # The superseded behaviour ranked an undated row as "just now", so it led the list;
  # this assertion is what fails if that behaviour ever returns.
  [ "$(printf '%s\n' "$ids" | head -1)" = "dated-jul-09" ] \
    || fail "a dated completion must lead landed ahead of any undated row, got: $ids"
  pass "an undated completion sorts below every dated row and keeps recording order"
}

# The failure direction the ruling protects: an undated row must never push a dated
# completion out of a CAPPED list. Under the superseded "date it as now" behaviour the
# eight undated rows below would have filled the whole cap and cut the dated row.
test_undated_rows_cannot_displace_dated_completions_under_the_cap() {
  local home fakebin json ids count rows i
  home=$(make_home undated-displacement)
  rows=()
  for i in 1 2 3 4 5 6 7 8; do
    rows+=("$(done_row "undated-$i" "Undated landing $i" "done" "")")
  done
  rows+=("$(done_row dated-kept "Dated landing that must survive the cap" "merged" "2026-07-01")")
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")
  count=$(printf '%s\n' "$ids" | grep -c .)

  [ "$count" -lt 9 ] || fail "expected the landed list to be capped, got $count rows"
  printf '%s\n' "$ids" | grep -qx 'dated-kept' \
    || fail "undated rows displaced a dated completion out of the capped list: $ids"
  [ "$(printf '%s\n' "$ids" | head -1)" = "dated-kept" ] \
    || fail "the dated completion must lead a list of otherwise undated rows, got: $ids"
  pass "undated rows cannot displace a dated completion out of the capped list"
}

# The cap is the mechanism that turned a mis-ordering into a disappearance, so pin the
# invariant directly: whatever the cap drops, it is never the newest completion.
test_cap_drops_oldest_never_newest() {
  local home fakebin json ids count rows i
  home=$(make_home cap-drops-oldest)
  rows=("$(done_row newest-today "The task that just finished" "done" "$TODAY")")
  for i in $(seq 1 20); do
    rows+=("$(done_row "history-$i" "Historical landing $i" "merged" "$(printf '2026-07-%02d' "$i")")")
  done
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")
  count=$(printf '%s\n' "$ids" | grep -c .)

  [ "$count" -lt 21 ] || fail "expected the landed list to be capped, got $count rows"
  [ "$(printf '%s\n' "$ids" | head -1)" = "newest-today" ] \
    || fail "the cap must never drop the newest completion, got: $ids"
  printf '%s\n' "$ids" | grep -qx 'history-1' \
    && fail "the cap must drop the OLDEST completions, but the oldest survived: $ids"
  printf '%s' "$json" | jq -e '
    [.omitted[]?.surface] | any(test("landed"))
  ' >/dev/null || fail "a capped landed list must disclose that it was capped: $json"
  pass "the landed cap drops the oldest completions and discloses the cap"
}

# A completion recorded AFTER an earlier report was generated must show up in the next
# one: the surface reads current backlog state each run and holds no prior baseline.
test_completion_recorded_after_an_earlier_report_appears_next_run() {
  local home fakebin first second rows
  home=$(make_home after-earlier-report)
  rows=("$(done_row settled "Landed a while ago" "merged" "2026-07-01")")
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")

  first=$(run_bearings "$home" "$fakebin" --json)
  landed_ids "$first" | grep -qx 'fresh-completion' \
    && fail "the first report should not yet show the later completion"

  # The task completes now, prepended exactly as tasks-axi records it.
  write_backlog "$home" \
    "$(done_row fresh-completion "Finished after the first report" "done" "$TODAY")" \
    "${rows[@]}"

  second=$(run_bearings "$home" "$fakebin" --json)
  landed_ids "$second" | grep -qx 'fresh-completion' \
    || fail "a completion recorded after an earlier report is missing: $(landed_ids "$second")"
  [ "$(landed_ids "$second" | head -1)" = "fresh-completion" ] \
    || fail "the newly recorded completion must lead landed: $(landed_ids "$second")"
  pass "a completion recorded after an earlier report appears in the next one"
}

# The same ordering must hold for work a secondmate completed in its own home, which
# reaches the captain only through the bounded cross-home roll-up. The roll-up is also
# where the recording position could leak: `order` is an internal backlog parse index,
# so the canonical machine contract must keep publishing rows without it, carrying the
# documented recency_rank ordinal - 1 is that home's newest - in its place so each
# home's newest-first evidence still survives every later re-sort.
test_secondmate_just_finished_completion_survives_rollup() {
  local home mate fakebin json canonical ids rows i
  home=$(make_home mate-rollup)
  mate=$(make_mate_home "$home" mate)
  write_backlog "$home" "$(done_row main-old "Main home older landing" "merged" "2026-07-02")"

  rows=("$(done_row mate-just-now "Secondmate work that just finished" "done" "$TODAY")")
  for i in $(seq 1 15); do
    rows+=("$(done_row "mate-history-$i" "Secondmate history $i" "merged" "$(printf '2026-07-%02d' "$i")")")
  done
  write_backlog "$mate" "${rows[@]}"

  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'mate-just-now' \
    || fail "a secondmate's just-finished completion vanished from landed: $ids"
  [ ! -s "$home/net.log" ] \
    || fail "the cross-home roll-up must make no network call, got: $(cat "$home/net.log")"

  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    ([.secondmate_current.records[].landed[]?] + [.secondmate_landed.records[]?]) as $published
    | ($published | length) > 0
      and ($published | all(has("order") | not))
      and ($published | all(.recency_rank >= 1))
      and (.secondmate_current.records[0].landed[0].id == "mate-just-now")
      and (.secondmate_current.records[0].landed[0].recency_rank == 1)
      and (.secondmate_landed.records[0].id == "mate-just-now")
  ' >/dev/null \
    || fail "the published landed contract must stay order-free and carry newest-first recency_rank: $canonical"
  pass "a secondmate's just-finished completion survives the cross-home roll-up"
}

# The overall cap is a GLOBAL bound, so balancing across homes alone breaks the same
# promise from the other end: the merge takes index 0 of every home in deterministic id
# order, and once the fleet has more homes than the cap has slots, the homes that sort
# last fall off the end - taking the newest completion in the fleet with them if it
# happens to live in one of them. The merge therefore reserves a leading slot for every
# home whose newest dated completion carries the fleet's newest completion date, and
# balances the rest.
test_just_finished_completion_survives_when_homes_exceed_the_cap() {
  local home fakebin json ids mate i id
  home=$(make_home homes-exceed-cap)
  # The main home sorts first under "(main)" and holds only an OLD completion, so every
  # slot ahead of the last home is already claimed by a home that sorts earlier.
  write_backlog "$home" "$(done_row main-old "Main home older landing" "merged" "2026-07-01")"
  for i in 1 2 3 4 5 6 7; do
    id=$(printf 'mate-%02d' "$i")
    mate=$(make_mate_home "$home" "$id")
    if [ "$i" -eq 7 ]; then
      write_backlog "$mate" "$(done_row "$id-just-now" "Secondmate work that just finished" "done" "$TODAY")"
    else
      write_backlog "$mate" "$(done_row "$id-old" "Older landing $i" "merged" "$(printf '2026-06-%02d' "$i")")"
    fi
  done
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'mate-07-just-now' \
    || fail "the overall cap cut the newest completion in the fleet: $ids"
  [ "$(printf '%s\n' "$ids" | head -1)" = "mate-07-just-now" ] \
    || fail "the newest completion in the fleet must lead landed across homes, got: $ids"
  # The reservation costs exactly one slot: the rest of the list stays balanced across
  # homes in deterministic id order, and the cap is still disclosed.
  printf '%s' "$json" | jq -e '
    (.landed | length) == 6
      and ([.landed[].id] | unique | length) == 6
      and ([.omitted[].surface] | any(test("landed showing 6 of 8")))
  ' >/dev/null || fail "the reservation broke the balanced merge or the cap disclosure: $json"
  pass "the newest completion in the fleet survives a cap smaller than the home count"
}

# Two homes land on the SAME newest date while the fleet has more homes than the cap
# has slots. Day-granularity dates provide no finer evidence anywhere in the system,
# so the reservation must hold a leading slot for EVERY home whose newest dated
# completion carries the fleet's newest date - otherwise the tie breaks on home-id
# order and a later-sorting home's just-finished completion is cut from the list.
test_same_day_cross_home_tie_keeps_later_sorting_homes_completion() {
  local home fakebin json ids mate i id
  home=$(make_home same-day-cross-home)
  write_backlog "$home" "$(done_row main-old "Main home older landing" "merged" "2026-07-01")"
  for i in 1 2 3 4 5 6 7; do
    id=$(printf 'mate-%02d' "$i")
    mate=$(make_mate_home "$home" "$id")
    if [ "$i" -eq 2 ]; then
      write_backlog "$mate" "$(done_row "$id-same-day" "Earlier-sorting home same-day landing" "merged" "$TODAY")"
    elif [ "$i" -eq 7 ]; then
      write_backlog "$mate" "$(done_row "$id-just-now" "Later-sorting home work that just finished" "done" "$TODAY")"
    else
      write_backlog "$mate" "$(done_row "$id-old" "Older landing $i" "merged" "$(printf '2026-06-%02d' "$i")")"
    fi
  done
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'mate-07-just-now' \
    || fail "a same-day tie broke on home order and cut the later-sorting home's just-finished completion: $ids"
  printf '%s\n' "$ids" | grep -qx 'mate-02-same-day' \
    || fail "reserving the later-sorting home must not drop the earlier-sorting home's same-day completion: $ids"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 6
      and ([.landed[].id] | unique | length) == 6
      and ([.omitted[].surface] | any(test("landed showing 6 of 8")))
  ' >/dev/null || fail "the same-day reservation broke the balanced merge or the cap disclosure: $json"
  pass "a same-day cross-home tie keeps every tied home's newest completion under the cap"
}

test_just_finished_same_day_completion_leads_landed
test_undated_completion_sorts_below_every_dated_row
test_undated_rows_cannot_displace_dated_completions_under_the_cap
test_cap_drops_oldest_never_newest
test_completion_recorded_after_an_earlier_report_appears_next_run
test_secondmate_just_finished_completion_survives_rollup
test_just_finished_completion_survives_when_homes_exceed_the_cap
test_same_day_cross_home_tie_keeps_later_sorting_homes_completion

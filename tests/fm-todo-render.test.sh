#!/usr/bin/env bash
# Behavior tests for the deterministic daily to-do page renderer.
#
# Contracts under test:
#   - Urgency wins the order: an outage sits above an urgent item, which sits
#     above a routine one, whatever order the ledger recorded them in.
#   - One calm "Needs you now" list: live problems first, then a partner
#     awaiting the captain, then hard deadlines, an urgent ask that only waited
#     long never above them, no summary strip, Now box, sweep banner or held
#     count, and no item rendered twice.
#   - Waiting on others, other channel activity and closed today render as
#     collapsed folds below the list, in that order.
#   - Recency breaks the tie inside a class, so a severe item arriving at 15:00
#     leads the class over one recorded at 09:00 and the page re-ranks itself
#     without anyone re-ordering it by hand.
#   - Waiting and closed work never mix into the live section: a handed-over
#     item renders under "Waiting on others" with its hand-over note, and an
#     item archived on the rendered day renders under "Closed today"
#     with its recorded resolution.
#   - An item archived on an earlier day is history, not something that closed
#     since this morning, and never reappears.
#   - Every live line carries its own read time, taken from the ledger's
#     `updated` stamp in the configured local zone, and the page's own render
#     stamp is a separate, differently labelled time.
#   - Legacy morning prose remains a labelled historical reference; structured
#     morning actions join the queue and ledger resolutions supersede them.
#   - Nothing is invented and nothing is carried forward: a resolved item does
#     not survive into the next render of the same page.
#   - The page renders with no visual tool installed, from the tracked house
#     style templates, and a missing template is refused rather than producing
#     an unstyled page.
#   - An intake read refreshes an existing page and never manufactures one:
#     a completed channel read re-ranks a page that exists, reports a page that
#     does not, and a renderer that fails never fails the read.
#   - An add-on's `todo-page` hooks put their own sections on the page on every
#     render, in name order, after the morning detail and before the intake
#     coverage; a hook that fails or runs out of time adds nothing and never
#     fails the render, and a home with no add-on gets no such section.
#   - A morning copy of a section an add-on renders is never shown, and
#     dropping it leaves no empty panel behind: a wrapper the drop emptied goes
#     with it, and a morning file that held nothing else produces no
#     morning-detail wrapper and no empty legacy reference fold.
#   - Team announcements render in their own collapsed "Updates" fold, newest
#     post first with its post time and link, and never in "Needs you now".
#   - In a real Chrome at desktop width, no row of a closed fold sits over the
#     sections below it, and such a row can still be found on the page.
#   - A click anywhere on a card opens and closes its note box, as the note
#     button still does; a click on its link, its button or inside the open
#     box, or one that ends a text selection, does not toggle it.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER="$ROOT/bin/fm-todo-render.sh"
INTAKE="$ROOT/bin/fm-channel-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-render-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600
T_1100=1789030800
T_1500=1789045200
T_1530=1789047000
T_YESTERDAY_1500=1788958800  # 2026-09-09 15:00 local

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/data/channel-intake" "$h/.lavish"
  cat >"$h/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
EOF
  printf 'C_BRIEF\tslack-channel\tdaily brief channel, top-level messages\n' \
    >"$h/data/channel-intake/sources.tsv"
  printf 'M_ACTION\tgmail\tmail carrying the action label only\n' \
    >>"$h/data/channel-intake/sources.tsv"
}

# Every invocation pins the clock instead of sleeping or suspending anything.
observe_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"
}

render_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" "$RENDER" "$@"
}

page_of() {
  printf '%s/.lavish/today-2026-09-10.html\n' "$1"
}

# The rendered order of a set of titles, one per line, as the page presents
# them. Read from the written page rather than from any internal call, so the
# assertion is about what the captain actually sees.
title_order() {
  local page=$1
  shift
  grep -o 'class="what">[^<]*' "$page" | sed 's/^class="what">//'
}

# The 1-based position of a fixed string in the rendered page.
line_of() {
  grep -n -F "$2" "$1" | head -n 1 | cut -d: -f1
}

test_outage_then_oldest_ask_orders_the_live_section() {
  local h page order

  h="$TMP_ROOT/ordering"
  new_home "$h"

  # Deliberately recorded in the WRONG order: the routine item is oldest and
  # first, the outage is newest and last, so nothing but the ranking can
  # produce the expected page.
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref r-routine \
    --digest a --class routine --title 'routine housekeeping' >/dev/null
  observe_at "$h" "$T_0900" observe --source M_ACTION --ref r-urgent-old \
    --digest b --class urgent --title 'older urgent ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref r-urgent-new \
    --digest c --class urgent --title 'newer urgent ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref r-outage \
    --digest d --class outage --title 'tap down at the customer' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  order=$(title_order "$page")

  [ "$order" = 'tap down at the customer
older urgent ask
newer urgent ask
routine housekeeping' ] || fail "the live section is not ranked as expected:
$order"

  pass 'the live section ranks a live outage first, then the oldest ask first, never the newest read'
}

test_waiting_and_closed_never_mix_into_the_live_section() {
  local h page key_wait key_done key_old out

  h="$TMP_ROOT/placement"
  new_home "$h"

  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref w1 \
    --digest a --class urgent --title 'quote for the dealer')
  key_wait=$(printf '%s' "$out" | awk '{ print $2 }')
  out=$(observe_at "$h" "$T_0900" observe --source M_ACTION --ref d1 \
    --digest b --class urgent --title 'invoice dispute')
  key_done=$(printf '%s' "$out" | awk '{ print $2 }')
  out=$(observe_at "$h" "$T_YESTERDAY_1500" observe --source M_ACTION --ref d0 \
    --digest c --class urgent --title 'yesterdays closed ask')
  key_old=$(printf '%s' "$out" | awk '{ print $2 }')

  observe_at "$h" "$T_1100" resolve --item "$key_wait" \
    --reason 'handed to Nora, she answers the dealer' --waiting >/dev/null
  observe_at "$h" "$T_1100" resolve --item "$key_done" \
    --reason 'credit note sent, customer confirmed' >/dev/null
  observe_at "$h" "$T_YESTERDAY_1500" resolve --item "$key_old" \
    --reason 'closed yesterday' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # Placement, not mere presence: the waiting item must sit after the waiting
  # heading, and the closed one after the closed heading.
  assert_contains "$(cat "$page")" 'handed to Nora, she answers the dealer' \
    'the hand-over note is missing from the page'
  [ "$(line_of "$page" 'quote for the dealer')" -gt "$(line_of "$page" '<summary>Waiting on others')" ] \
    || fail 'a handed-over item did not render under Waiting on others'
  [ "$(line_of "$page" 'invoice dispute')" -gt "$(line_of "$page" '<summary>Closed today')" ] \
    || fail 'an item archived today did not render under Closed today'
  assert_contains "$(cat "$page")" 'credit note sent, customer confirmed' \
    'the recorded resolution is missing from the closed table'

  # An earlier day's archive is history, not something that closed this
  # morning, so it must appear nowhere on today's page.
  assert_not_contains "$(cat "$page")" 'yesterdays closed ask' \
    'an item archived on an earlier day reappeared on todays page'

  # And the waiting item stays inside its own block rather than leaking into
  # the live table above it or the closed table below it.
  [ "$(line_of "$page" 'quote for the dealer')" -lt "$(line_of "$page" '<summary>Closed today')" ] \
    || fail 'the waiting item did not stay inside the Waiting on others block'

  pass 'waiting, closed-today and closed-earlier items each render in exactly one place'
}

test_every_line_carries_its_own_read_time() {
  local h page

  h="$TMP_ROOT/provenance"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref p1 \
    --digest a --class urgent --title 'morning ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref p2 \
    --digest b --class urgent --title 'afternoon ask' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # The provenance stamp is the ledger's read time for THAT item, in the
  # configured zone - not the render time and not one shared stamp.
  assert_contains "$(cat "$page")" 'morning ask<span class="prov obs">read 09:00 CEST</span>' \
    'the morning line does not carry its own read time'
  assert_contains "$(cat "$page")" 'afternoon ask<span class="prov obs">read 15:00 CEST</span>' \
    'the afternoon line does not carry its own read time'
  # The page's own build time is separate and separately labelled.
  assert_contains "$(cat "$page")" 'rebuilt from the to-do records at <span class="mono">15:30 CEST</span>' \
    'the page does not stamp its own render time'
  # The channel stays on the row for audit, off the visible text.
  assert_contains "$(cat "$page")" 'data-source="slack-channel (C_BRIEF)"' \
    'the row does not keep the channel it was read on for audit'
  assert_not_contains "$(cat "$page")" '<span class="org">' 'the row still shows its source label'
  assert_not_contains "$(cat "$page")" '<span class="ctx how">' 'the row still shows how it was read'

  pass 'each live line carries the time that item was read, separately from the render stamp, with its channel kept for audit'
}

test_legacy_morning_is_a_historical_reference() {
  local h page fragment

  h="$TMP_ROOT/morning-fragment"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref m1 \
    --digest a --class urgent --title 'live item' >/dev/null

  # Deliberately awkward content: an unclosed-looking construct, an entity, an
  # ampersand and an ordering the renderer would change if it parsed it.
  fragment="$h/.lavish/today-2026-09-10.morning.html"
  cat >"$fragment" <<'FRAG'
<div class="wrap"><header><h1>Old Today heading</h1></header>
<h2>Verified this morning<small>read by hand at 06:00</small></h2>
<div class="note"><b>Fourth Coffee Site.</b> Stage read live &amp; unchanged.</div>
<ul><li>routine last</li><li>outage first</li></ul>
<h2>Calendar through Friday</h2><p>Calendar snapshot</p>
</div>
FRAG

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  assert_contains "$(cat "$page")" '<summary>Earlier morning reference - not re-verified by this update</summary>' 'legacy content must be collapsed and labelled'
  assert_contains "$(cat "$page")" 'Stage read live &amp; unchanged.' 'legacy evidence must survive'
  [ "$(grep -c '<h1>' "$page")" = 1 ] || fail 'page must have one title'
  [ "$(line_of "$page" 'Calendar snapshot')" -gt "$(line_of "$page" '<summary>Earlier morning reference')" ] || fail 'legacy prose must stay inside the reference'
  pass 'legacy morning content stays in a labelled historical disclosure'

}

test_structured_morning_merges_and_ledger_supersedes() {
  local h page key out
  h="$TMP_ROOT/structured"
  new_home "$h"
  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref shared --digest a --class urgent --title 'ledger action')
  key=$(printf '%s' "$out" | awk '{ print $2 }')
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<h2>Tickets and calendar</h2><p>Detail without duplicate actions</p>
HTML
  cat >"$h/.lavish/today-2026-09-10.morning.json" <<JSON
{"version":1,"date":"2026-09-10","actions":[
{"key":"morning-only","source":"C_BRIEF","ref":"decision","class":"urgent","title":"new morning decision","updated":$T_1100},
{"key":"$key","source":"C_BRIEF","ref":"shared","class":"urgent","title":"duplicate morning action","updated":$T_0900}]}
JSON
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  # Morning and ledger lines sort together by when the ask was made: the ledger
  # ask seen at 09:00 is older than a morning line first seen on this render.
  [ "$(line_of "$page" 'ledger action')" -lt "$(line_of "$page" 'new morning decision')" ] || fail 'morning and ledger priorities must sort together, oldest ask first'
  assert_not_contains "$(cat "$page")" 'duplicate morning action' 'ledger identity must win'
  observe_at "$h" "$T_1500" resolve --item "$key" --reason 'no longer needed' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  assert_not_contains "$(cat "$page")" 'duplicate morning action' 'resolved ledger item must not reappear from morning'
  [ "$(line_of "$page" 'no longer needed')" -gt "$(line_of "$page" '<summary>Closed today')" ] || fail 'cleared reason must be in closed footer'
  cp "$page" "$h/previous.html"
  printf '{invalid' >"$h/.lavish/today-2026-09-10.morning.json"
  if render_at "$h" "$T_1530" render >/dev/null 2>&1; then fail 'invalid metadata must refuse'; fi
  cmp -s "$page" "$h/previous.html" || fail 'failed composition must preserve page'
  pass 'morning actions merge, resolutions win, and invalid metadata preserves the page'
}

test_nothing_is_carried_forward_between_renders() {
  local h page out key

  h="$TMP_ROOT/no-carry-forward"
  new_home "$h"
  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c1 \
    --digest a --class urgent --title 'ask that gets answered')
  key=$(printf '%s' "$out" | awk '{ print $2 }')
  render_at "$h" "$T_1100" render >/dev/null
  page=$(page_of "$h")
  assert_contains "$(cat "$page")" 'ask that gets answered' \
    'the open item never rendered in the first place'

  observe_at "$h" "$T_1500" resolve --item "$key" --reason 'answered in the thread' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null

  # It may appear in the closed table, but never again as open work.
  [ "$(line_of "$page" 'ask that gets answered')" -gt "$(line_of "$page" '<summary>Closed today')" ] \
    || fail 'a resolved item survived into the live section of the next render'

  # The page is rebuilt from the durable records, never read back: deleting
  # it and rendering again gives the same bytes.
  cp "$page" "$h/previous.html"
  rm -f "$page"
  render_at "$h" "$T_1530" render >/dev/null
  cmp -s "$page" "$h/previous.html" || fail 'a re-render from the same records produced a different page'

  # With no records at all, the page is honestly empty.
  rm -rf "$h/data/todo" "$h/data/channel-intake/archive" "$h/data/channel-intake/items"
  render_at "$h" "$T_1530" render >/dev/null
  assert_not_contains "$(cat "$page")" 'ask that gets answered' \
    'the renderer read content back from the page it had already written'
  assert_contains "$(cat "$page")" 'Nothing open.' \
    'an empty record set did not render as an empty page'

  pass 'the page is rebuilt from the records every time, so nothing is invented or carried forward'
}

test_calm_layout_ranks_live_problems_first_and_folds_the_rest() {
  local h page body key_wait key_done ids dupes

  h="$TMP_ROOT/calm"
  new_home "$h"
  # Recorded worst-first-last: a long-waiting urgent ask is the newest read,
  # so only the tiers can put the outage and the deadline above it.
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c-obl \
    --digest a --class obligation --title 'answer the training question' >/dev/null
  observe_at "$h" "$T_0900" observe --source M_ACTION --ref c-dl \
    --digest b --class deadline --title 'feedback due before leave' >/dev/null
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c-out \
    --digest c --class outage --title 'partner machine down now' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref c-urg \
    --digest d --class urgent --title 'partner waiting 26 days' >/dev/null
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c-rt \
    --digest e --class routine --title 'weekly newsletter' >/dev/null
  key_wait=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c-w \
    --digest f --class urgent --title 'dealer quote handed over' | awk '{ print $2 }')
  key_done=$(observe_at "$h" "$T_0900" observe --source M_ACTION --ref c-d \
    --digest g --class urgent --title 'invoice settled' | awk '{ print $2 }')
  observe_at "$h" "$T_1100" resolve --item "$key_wait" --reason 'Nora will answer it' --waiting >/dev/null
  observe_at "$h" "$T_1100" resolve --item "$key_done" --reason 'credit note sent' >/dev/null

  # A partner-facing ask awaiting the captain, flagged by the morning sweep.
  printf '{"version":2,"date":"2026-09-10","actions":[{"key":"k-p","source":"helpdesk","ref":"t-9","class":"obligation","kind":"reply","title":"partner awaiting your answer","partner_awaiting":true,"awaiting_since":%s,"updated":%s}]}\n' \
    "$T_YESTERDAY_1500" "$T_1100" >"$h/.lavish/today-2026-09-10.morning.json"

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  body=$(sed -n '/<h2>Needs you now/,/<\/table>/p' "$page")

  # Tier 0 is a live outage, tier 1 a partner awaiting the captain, tier 3 a hard
  # deadline; age alone never lifts the urgent ask above them, and everything
  # else follows oldest ask first. The stored title loses its rotting "26 days".
  [ "$(grep -o 'class="what">[^<]*' <<<"$body" | sed 's/^class="what">//')" = 'partner machine down now
partner awaiting your answer
feedback due before leave
answer the training question
partner waiting' ] || fail "the Needs you list is not in action order:
$body"

  # One list: no summary strip, no Now box, no sweep banner, no held count.
  assert_not_contains "$(cat "$page")" 'class="tiles"' 'the summary-count strip is still on the page'
  assert_not_contains "$(cat "$page")" 'class="strip now"' 'the separate Now box is still on the page'
  assert_not_contains "$(cat "$page")" 'No verification sweep recorded' 'the sweep banner is still on the page'
  assert_not_contains "$(cat "$page")" 'held, not re-checked' 'the held count is still on the page'
  [ "$(grep -o '<h2>[^<]*' "$page" | sed 's/^<h2>//')" = 'Needs you now' ] \
    || fail 'the page has headed sections beyond the Needs you list'

  # No item appears twice anywhere on the page.
  ids=$(grep -o 'id="item-[^"]*"' "$page" | sort)
  dupes=$(uniq -d <<<"$ids")
  [ -z "$dupes" ] || fail "items appear twice on the page: $dupes"
  [ "$(grep -c -F 'class="what">partner machine down now' "$page")" = 1 ] || fail 'the outage is rendered more than once'

  # Waiting, routine activity and closed work sit in collapsed folds, below
  # the list and in that order, never expanded.
  assert_not_contains "$(cat "$page")" '<details open' 'a fold renders expanded'
  [ "$(line_of "$page" '<summary>Waiting on others (1)</summary>')" -lt "$(line_of "$page" '<summary>Other channel activity</summary>')" ] \
    && [ "$(line_of "$page" '<summary>Other channel activity</summary>')" -lt "$(line_of "$page" '<summary>Closed today (1)</summary>')" ] \
    || fail 'waiting, activity and closed are not folded in order'
  [ "$(line_of "$page" 'dealer quote handed over')" -gt "$(line_of "$page" '<summary>Waiting on others')" ] \
    || fail 'the handed-over item is not inside the waiting fold'
  [ "$(line_of "$page" 'weekly newsletter')" -gt "$(line_of "$page" '<summary>Other channel activity')" ] \
    || fail 'routine activity is not inside its fold'
  [ "$(line_of "$page" 'invoice settled')" -gt "$(line_of "$page" '<summary>Closed today')" ] \
    || fail 'the closed item is not inside the closed fold'

  pass 'the calm layout ranks live problems first, then partners, then deadlines in one list, never repeats an item, and folds the rest'
}

test_house_style_comes_from_the_tracked_templates() {
  local h page out code

  h="$TMP_ROOT/house-style"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref s1 \
    --digest a --class outage --title 'tap down' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # A complete, self-contained page: the house variables, the severity pills
  # and the provenance legend, with nothing fetched and no tool running.
  assert_contains "$(cat "$page")" '<!doctype html>' 'the page has no document type'
  assert_contains "$(cat "$page")" '--accent:#0b4f8a' 'the house palette is missing'
  assert_contains "$(cat "$page")" '<span class="pill bad">outage</span>' \
    'the severity pill is missing from the outage row'
  assert_contains "$(cat "$page")" 'could not be confirmed from any source available here' \
    'the provenance legend is missing'
  assert_contains "$(cat "$page")" '<title>Today - Thursday 10 September 2026</title>' \
    'the page title was not filled in'

  # A missing template is refused, never silently rendered unstyled.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$T_1530" \
    FM_TODO_TEMPLATE_DIR="$TMP_ROOT/no-such-templates" "$RENDER" render 2>&1) \
    && code=0 || code=$?
  expect_code 2 "$code" 'a missing house-style template still rendered a page'
  assert_contains "$out" 'house-style head template is missing' \
    'the refusal did not name the missing template'

  pass 'the page renders from the tracked house-style templates with no visual tool installed'
}

test_completed_read_refreshes_an_existing_page_only() {
  local h page out order code

  h="$TMP_ROOT/refresh-wiring"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref f1 \
    --digest a --class routine --title 'routine item' >/dev/null

  # No page written yet: a completed read says so and manufactures nothing.
  out=$(observe_at "$h" "$T_0900" complete --source C_BRIEF --checkpoint cp1)
  assert_contains "$out" 'nothing refreshed' 'a read with no page did not report it'
  assert_absent "$(page_of "$h")" 'a background read manufactured a page nobody wrote'

  # With the morning page on disk, the 15:00 outage reaches the top on the
  # read that recorded it, with no second command and no model call.
  render_at "$h" "$T_1100" render >/dev/null
  page=$(page_of "$h")
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref f2 \
    --digest b --class outage --title 'tap down at the customer' >/dev/null
  out=$(observe_at "$h" "$T_1530" complete --source C_BRIEF --checkpoint cp2)
  assert_contains "$out" 'rendered at 15:30 CEST' 'the completed read did not refresh the page'
  order=$(title_order "$page")
  [ "$order" = 'tap down at the customer
routine item' ] || fail "the refresh did not re-rank the page:
$order"

  # A renderer that fails is reported and never fails the read itself. The
  # failure is a real one - the house-style templates are pointed somewhere
  # they are not - rather than a stubbed exit code.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_1530" \
    FM_TODO_TEMPLATE_DIR="$TMP_ROOT/no-such-templates" \
    "$INTAKE" complete --source C_BRIEF --checkpoint cp3) && code=0 || code=$?
  expect_code 0 "$code" 'a failing renderer failed the completed read'
  assert_contains "$out" 'read complete, checkpoint cp3' \
    'the read itself was not reported after a failing renderer'
  assert_contains "$out" 'the day page was not refreshed' \
    'a failing renderer was not reported'
  [ "$(grep -c 'checkpoint=cp3' "$h/data/channel-intake/sources/C_BRIEF/state")" -ge 1 ] \
    || fail 'the checkpoint the read advanced was lost when the render failed'

  pass 'a completed read refreshes an existing page, never manufactures one, and never fails on the render'
}

# A home's add-on whose todo-page hooks print sections of their own, here the
# live table a ticket system would give it.
addon_section() {  # <home>
  local h=$1
  mkdir -p "$h/addon/hooks/todo-page"
  printf 'path = %s\n' "$h/addon" >"$h/config/addon"
  cat >"$h/addon/hooks/todo-page/10-open-tickets" <<'HOOK'
#!/usr/bin/env bash
printf '<h2>Your open tickets<small>read live</small></h2>\n<p class="sub">Read live at 15:00 CEST.</p>\n'
HOOK
  chmod +x "$h/addon/hooks/todo-page/10-open-tickets"
}


test_a_morning_copy_of_an_addon_section_is_never_shown() {
  local h page
  h="$TMP_ROOT/tickets-morning"
  new_home "$h"
  addon_section "$h"
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<section class="morning-details">
  <h2>Your open tickets<small>read at 06:20 CEST</small></h2>
  <p class="sub">Eight tickets carry you as owner.</p>
  <div class="tablewrap"><table><tr><td>Morning-only closed ticket</td></tr></table></div>
  <div class="card"><h2>Calendar<small>read by hand at 06:00</small></h2><p>Calendar snapshot</p></div>
</section>
HTML
  printf '{"version":1,"date":"2026-09-10","actions":[]}' >"$h/.lavish/today-2026-09-10.morning.json"
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only closed ticket' 'the morning ticket table is still shown'
  assert_not_contains "$page" '06:20 CEST' 'the morning read time is still shown'
  assert_contains "$page" 'Calendar snapshot' 'the rest of the morning detail was lost'
  [ "$(grep -o '<h2>Your open tickets' "$(page_of "$h")" | wc -l | tr -d ' ')" = 1 ] \
    || fail 'the page carries more than one tickets section'

  # The same holds for a legacy morning file with no action metadata.
  rm "$h/.lavish/today-2026-09-10.morning.json"
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only closed ticket' 'a legacy morning ticket table is still shown'
  assert_contains "$page" 'Read live at 15:00 CEST.' 'the live section is missing beside a legacy morning file'
  pass 'a morning copy of an add-on section is replaced by the live section'
}

test_dropping_a_morning_copy_leaves_no_empty_panel_behind() {
  local h page
  h="$TMP_ROOT/tickets-empty-panel"
  new_home "$h"
  addon_section "$h"
  printf '{"version":1,"date":"2026-09-10","actions":[]}' >"$h/.lavish/today-2026-09-10.morning.json"

  # The morning copy sits inside a .card panel, which the house style gives a
  # border and padding, so an emptied wrapper would render as a blank panel.
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<section class="morning-details">
  <div class="card"><h2>Your open tickets<small>read at 06:20 CEST</small></h2>
    <div class="tablewrap"><table><tr><td>Morning-only closed ticket</td></tr></table></div></div>
  <div class="card"><h2>Calendar<small>read by hand at 06:00</small></h2><p>Calendar snapshot</p></div>
</section>
HTML
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only closed ticket' 'the morning ticket table survived inside its panel'
  assert_contains "$page" 'Calendar snapshot' 'the sibling panel was lost with the dropped one'
  assert_not_contains "$page" '<div class="card"></div>' 'the drop left an empty panel on the page'

  # A morning file that held nothing but the tickets section leaves no wrapper,
  # not even around the stray whitespace the drop leaves behind.
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'

<section class="morning-details">
  <h2>Your open tickets<small>read at 06:20 CEST</small></h2>
  <div class="tablewrap"><table><tr><td>Morning-only closed ticket</td></tr></table></div>
</section>
HTML
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only closed ticket' 'the only morning section survived the drop'
  assert_not_contains "$page" 'aria-label="Morning detail"' 'an empty morning-detail wrapper was printed'
  assert_contains "$page" 'Read live at 15:00 CEST.' 'the live section is missing'
  pass 'dropping the morning copy leaves no empty panel or wrapper behind'
}

test_a_legacy_morning_copy_leaves_no_empty_reference_fold() {
  local h page
  h="$TMP_ROOT/tickets-legacy-fold"
  new_home "$h"
  addon_section "$h"

  # A legacy morning file (no action metadata) whose only content is the
  # tickets section the page now renders live.
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<h2>Your open tickets</h2><p>Eight tickets carry you as owner.</p>
<div class="tablewrap"><table><tr><td>Morning-only row</td></tr></table></div>
HTML
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only row' 'the legacy morning ticket table is still shown'
  assert_not_contains "$page" 'Earlier morning reference' 'an empty legacy reference fold was printed'
  assert_contains "$page" 'Read live at 15:00 CEST.' 'the live section is missing'

  # A legacy file that still carries other prose keeps its reference fold.
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<h2>Your open tickets</h2><p>Eight tickets carry you as owner.</p>
<div class="tablewrap"><table><tr><td>Morning-only row</td></tr></table></div>
<h2>Pilot notes</h2><p>Tap pressure checked by hand at 06:00.</p>
HTML
  render_at "$h" "$T_1530" render >/dev/null
  page=$(cat "$(page_of "$h")")
  assert_not_contains "$page" 'Morning-only row' 'the legacy morning ticket table survived beside other prose'
  assert_contains "$page" 'Earlier morning reference' 'the reference fold was dropped although prose remained'
  assert_contains "$page" 'Tap pressure checked by hand at 06:00.' 'the remaining morning prose was lost'
  pass 'a legacy morning file holding only the tickets copy leaves no empty reference fold'
}

test_addon_sections_render_on_every_build() {
  local h page out code
  h="$TMP_ROOT/addon-sections"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref s1 --digest a --class urgent --title 'live item' >/dev/null
  observe_at "$h" "$T_0900" complete --source C_BRIEF --checkpoint c-1 >/dev/null
  printf '{"version":1,"date":"2026-09-10","actions":[]}' >"$h/.lavish/today-2026-09-10.morning.json"
  printf '<h2>Worth knowing</h2><p>Morning context</p>\n' >"$h/.lavish/today-2026-09-10.morning.html"

  # No add-on: the page carries no section beyond its own.
  render_at "$h" "$T_1530" render >/dev/null || fail 'a render with no add-on failed'
  assert_not_contains "$(cat "$(page_of "$h")")" 'Add-on' 'a home with no add-on grew a section'

  # Two hooks in name order, each told the page's date and render time, and a
  # failing hook, whose partial output never reaches the page.
  mkdir -p "$h/addon/hooks/todo-page"
  printf 'path = %s\n' "$h/addon" >"$h/config/addon"
  cat >"$h/addon/hooks/todo-page/20-second" <<'HOOK'
#!/usr/bin/env bash
printf '<h2>Add-on second</h2><p>for %s at %s</p>\n' "$FM_TODO_PAGE_DATE" "$FM_TODO_PAGE_NOW"
HOOK
  cat >"$h/addon/hooks/todo-page/10-first" <<'HOOK'
#!/usr/bin/env bash
printf '<h2>Add-on first</h2><p>store %s</p>\n' "${FM_TODO_STORE##*/}"
HOOK
  cat >"$h/addon/hooks/todo-page/30-broken" <<'HOOK'
#!/usr/bin/env bash
printf '<h2>Add-on broken</h2>\n'
exit 3
HOOK
  chmod +x "$h/addon/hooks/todo-page"/*
  out=$(render_at "$h" "$T_1530" render 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "a failing add-on section failed the render: $out"
  assert_contains "$out" 'todo-page hook' 'the failing hook was not named'
  page=$(page_of "$h")
  assert_contains "$(cat "$page")" "<p>for 2026-09-10 at $T_1530</p>" 'the hook was not told the page date and render time'
  assert_contains "$(cat "$page")" '<p>store todo</p>' 'the hook was not told the item store'
  assert_not_contains "$(cat "$page")" 'Add-on broken' 'a failing hook still put its output on the page'
  [ "$(line_of "$page" 'Morning context')" -lt "$(line_of "$page" '<h2>Add-on first')" ] \
    && [ "$(line_of "$page" '<h2>Add-on first')" -lt "$(line_of "$page" '<h2>Add-on second')" ] \
    && [ "$(line_of "$page" '<h2>Add-on second')" -lt "$(line_of "$page" '<summary>Intake coverage')" ] \
    || fail 'add-on sections are not after the morning detail, in name order, ahead of the intake coverage'

  # A hook that runs out of time adds nothing and the page is still written.
  cat >"$h/addon/hooks/todo-page/40-slow" <<'HOOK'
#!/usr/bin/env bash
printf '<h2>Add-on slow</h2>\n'
sleep 5
HOOK
  chmod +x "$h/addon/hooks/todo-page/40-slow"
  FM_ADDON_HOOK_TIMEOUT=1 render_at "$h" "$T_1530" render >/dev/null 2>&1 || fail 'a slow add-on section failed the render'
  assert_not_contains "$(cat "$page")" 'Add-on slow' 'a hook that ran out of time still put its output on the page'
  assert_contains "$(cat "$page")" 'Add-on first' 'a slow hook cost the other sections'
  pass 'add-on sections render on every build in name order, and a failing or slow one never costs the page'
}

test_team_updates_fold_newest_post_first() {
  local h page
  h="$TMP_ROOT/updates"
  new_home "$h"
  printf 'C_TEAM\tslack-announcements\tteam announcement channels\n' >>"$h/data/channel-intake/sources.tsv"
  # Recorded newest-read first but oldest-posted first, so only the post time orders them.
  observe_at "$h" "$T_1500" observe --source C_TEAM --ref u-old --digest a --class update \
    --source-epoch "$T_YESTERDAY_1500" --title 'price list changes 1 Nov' >/dev/null
  observe_at "$h" "$T_0900" observe --source C_TEAM --ref u-new --digest b --class update \
    --source-epoch "$T_0900" --title 'Furniture limited release - live on the partner webshop' \
    --link 'https://example.slack.com/archives/C_TEAM/p1' >/dev/null
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref ask --digest c --class obligation \
    --title 'approve the RMA' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  assert_contains "$(cat "$page")" '<summary>Updates (2)</summary>' 'the updates fold is missing'
  [ "$(line_of "$page" 'Furniture limited release')" -lt "$(line_of "$page" 'price list changes')" ] \
    || fail 'updates are not newest post first'
  [ "$(line_of "$page" 'Furniture limited release')" -gt "$(line_of "$page" '<summary>Updates')" ] \
    || fail 'an update leaked into needs-you'
  [ "$(line_of "$page" 'approve the RMA')" -lt "$(line_of "$page" '<summary>Updates')" ] \
    || fail 'the ask is not above the updates'
  assert_contains "$(cat "$page")" 'posted 09:00 CEST' 'the post time is missing'
  assert_contains "$(cat "$page")" 'https://example.slack.com/archives/C_TEAM/p1' 'the permalink is missing'
  pass 'team announcements fold under Updates, newest post first, below every ask'
}

test_closed_folds_cover_nothing_and_stay_findable() {
  local h page probed chrome dom report i

  if ! chrome=$(find_chrome); then
    echo 'skip: Chrome not found for the closed-fold layout test'
    return 0
  fi
  h="$TMP_ROOT/closed-folds"
  new_home "$h"
  for i in 1 2 3 4 5 6; do
    observe_at "$h" "$T_1100" resolve --waiting --reason "handed to Nora for answer $i" --item "$(
      observe_at "$h" "$T_0900" observe --source C_BRIEF --ref "w$i" --digest "a$i" --class urgent \
        --title "waiting item $i handed on with a title long enough to wrap" | awk '{ print $2 }')" >/dev/null
  done
  addon_section "$h"
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # Probe the rendered page the way the layout checker does: hit-test the
  # middle of every text line of every row in a closed fold, and count a row
  # as covered when that point lands on another section of the page. Then
  # search for one of those rows as find-in-page would, which is what opens
  # the fold for a find or a link.
  probed="$h/probed.html"
  sed 's#</body>#<script>setTimeout(() => {\
  let covered = 0;\
  for (const fold of document.querySelectorAll("details:not([open])")) {\
    for (const row of fold.querySelectorAll("[id^=item-]")) {\
      const text = document.createRange(); text.selectNodeContents(row);\
      if ([...text.getClientRects()].some(r => r.width * r.height >= 16 \&\& (hit => hit \&\& !hit.contains(fold) \&\& !fold.contains(hit))(document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)))) covered++;\
    }\
  }\
  const out = document.createElement("pre"); out.id = "probe";\
  out.textContent = "covered=" + covered + " found=" + window.find("waiting item 3 handed on");\
  document.body.appendChild(out);\
}, 300);</script></body>#' "$page" >"$probed"

  # The 1110px desktop width the layout checker reported from.
  report=$(fm_chrome_dump_dom "$chrome" "$probed" "$h/probed.dom" "page=$probed" --window-size=1110,3000) \
    || fail "Chrome produced no DOM for the closed-fold probe: $report"
  dom=$(cat "$h/probed.dom")
  assert_contains "$dom" '<pre id="probe">' 'the closed-fold probe never ran in Chrome'
  assert_contains "$dom" 'covered=0 ' 'a row in a closed fold sits over another section at desktop width'
  assert_contains "$dom" ' found=true' 'a row in a closed fold can no longer be found on the page'

  pass 'closed folds lay no row over the sections below and their rows stay findable'
}

test_card_click_toggles_its_note_box() {
  local h page probed chrome dom report

  if ! chrome=$(find_chrome); then
    echo 'skip: Chrome not found for the card-click test'
    return 0
  fi
  h="$TMP_ROOT/card-click"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref r-card --digest a --class urgent \
    --title 'card to click through' --link 'https://example.slack.com/archives/C_BRIEF/p9' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # Click the card's parts in turn and record whether its note box is open
  # after each click: the ask text, again, the link, the note button, inside
  # the open box, the button again, and the ask text with some of it selected.
  probed="$h/probed.html"
  sed 's#</body>#<script>setTimeout(() => {\
  const card = document.querySelector("tr.item"), box = card.nextElementSibling;\
  const link = card.querySelector("a"); link.addEventListener("click", e => e.preventDefault());\
  const what = card.querySelector("td.what"), states = [];\
  const click = el => { el.click(); states.push(box.classList.contains("open") ? "open" : "shut"); };\
  click(what); click(what); click(link); click(card.querySelector("button.notetoggle"));\
  click(box.querySelector("input")); click(card.querySelector("button.notetoggle"));\
  const sel = document.createRange(); sel.selectNodeContents(what);\
  getSelection().removeAllRanges(); getSelection().addRange(sel); click(what);\
  const out = document.createElement("pre"); out.id = "probe";\
  out.textContent = "states=" + states.join(",") + ";";\
  document.body.appendChild(out);\
}, 300);</script></body>#' "$page" >"$probed"

  report=$(fm_chrome_dump_dom "$chrome" "$probed" "$h/probed.dom" "page=$probed" --window-size=1110,3000) \
    || fail "Chrome produced no DOM for the card-click probe: $report"
  dom=$(cat "$h/probed.dom")
  assert_contains "$dom" '<pre id="probe">' 'the card-click probe never ran in Chrome'
  assert_contains "$dom" 'states=open,shut,shut,open,open,shut,shut;' \
    'a click on the card does not toggle its note box as expected'

  pass 'a click anywhere on a card toggles its note box, except on its controls or a selection'
}

test_outage_then_oldest_ask_orders_the_live_section
test_waiting_and_closed_never_mix_into_the_live_section
test_every_line_carries_its_own_read_time
test_legacy_morning_is_a_historical_reference
test_structured_morning_merges_and_ledger_supersedes
test_nothing_is_carried_forward_between_renders
test_house_style_comes_from_the_tracked_templates
test_completed_read_refreshes_an_existing_page_only
test_a_morning_copy_of_an_addon_section_is_never_shown
test_dropping_a_morning_copy_leaves_no_empty_panel_behind
test_a_legacy_morning_copy_leaves_no_empty_reference_fold
test_calm_layout_ranks_live_problems_first_and_folds_the_rest
test_addon_sections_render_on_every_build
test_team_updates_fold_newest_post_first
test_closed_folds_cover_nothing_and_stay_findable
test_card_click_toggles_its_note_box

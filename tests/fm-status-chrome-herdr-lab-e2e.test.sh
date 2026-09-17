#!/usr/bin/env bash
# tests/fm-status-chrome-herdr-lab-e2e.test.sh - real-herdr evidence for the
# status companion's chrome mode (docs/status-bar.md "Herdr chrome mode").
#
# Chrome mode reclaims the companion pane's empty rows by publishing the
# canonical row onto the PRIMARY pane's own border title and then hiding the
# companion with `pane zoom --on`. Three Herdr surfaces carry that: the border
# title store, `pane zoom --on/--off`, and `pane layout`. `pane zoom` and
# `pane layout` are first uses of those verbs in this repo, and Herdr draws
# borders in its TUI CLIENT rather than its server, so `pane read` cannot see
# any of it. This test therefore measures the real binary through the isolated
# lab and its rendered screen, rather than assuming the shape.
#
# What it establishes:
#
# - `pane zoom --on` hides the companion and reclaims its rows, while the
#   primary's border title still renders.
# - `pane layout` reports the tab's pane count and its `zoomed` flag correctly
#   while zoomed, and again after a third pane appears.
# - `pane zoom --off` releases the zoom, and is idempotent when Herdr has
#   already released it itself.
# - A deliberate unzoom is PRESERVED: the live renderer keeps publishing the
#   border row and never re-applies the zoom.
#
# Safety: every Herdr call goes through bin/fm-herdr-lab.sh, which owns the
# isolation contract - a generated named non-default `fm-lab-` session, the
# refuse-default hard guard before each destructive call, and the fleet-state
# tripwire that teardown verifies byte-identical afterward. The default session
# is never touched. The live renderer this test drives is isolated separately,
# against a scratch home and fixture metrics sources rather than the captain's
# private state/ directory and real vendor account; see SCRATCH below.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Host-capability gates: this test needs the real runtimes named here, and
# self-skips rather than failing where they are absent.
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the lab viewer)"; exit 0; }
python3 -c 'import pyte' >/dev/null 2>&1 \
  || { echo "skip: python3 module 'pyte' not found (required to render the lab screen)"; exit 0; }

# shellcheck source=bin/fm-herdr-lab.sh
. "$ROOT/bin/fm-herdr-lab.sh"

SESSION=$(fm_herdr_lab_name statuschrome)
RENDERER_PID=

# The lab contract isolates the SESSION. The renderer this test drives is the
# real one, so its HOME and its vendor account have to be isolated separately or
# a run from a firstmate checkout would read the captain's private state/
# directory, fold the canonical reader over every real task, write cache and
# claim files into it, and spawn a real provider read against the live account.
#
# SCRATCH_STATE is an empty state directory: no *.meta, so the fleet supply has
# a zero-record fleet to read and never reaches bin/fm-crew-state.sh at all, and
# every cache or claim file it writes lands here. SCRATCH_ROLLOUT pins the Codex
# context source to a fixture, so the metrics supply never resolves a pane to a
# process or asks lsof which rollout any real session holds open. And the
# provider source is disabled outright, so no quota-axi subprocess can start.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-chrome-e2e.XXXXXX") \
  || fail "could not create the scratch home for the isolated renderer"
SCRATCH_STATE="$SCRATCH/state"
SCRATCH_ROLLOUT="$SCRATCH/sessions/lab/rollout-fixture.jsonl"
mkdir -p "$SCRATCH_STATE" "$(dirname "$SCRATCH_ROLLOUT")"
printf '%s\n' \
  '{"payload":{"type":"token_count","info":{"model_context_window":272000,"last_token_usage":{"input_tokens":54400,"cached_input_tokens":0,"output_tokens":0}}}}' \
  > "$SCRATCH_ROLLOUT"

# The renderer traps TERM to restore the terminal and then RESUMES its loop, so
# a plain TERM never ends it. It is meant to exit when the pane it follows dies,
# which is not how this test drives it, so stop it outright.
stop_renderer() {
  local waited=0
  [ -n "$RENDERER_PID" ] || return 0
  kill -TERM "$RENDERER_PID" 2>/dev/null || true
  while kill -0 "$RENDERER_PID" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  kill -KILL "$RENDERER_PID" 2>/dev/null || true
  wait "$RENDERER_PID" 2>/dev/null || true
  RENDERER_PID=
}

cleanup_all() {
  stop_renderer
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 \
    || printf 'not ok - lab teardown or its fleet-state tripwire failed for %s\n' "$SESSION" >&2
  [ -z "${SCRATCH:-}" ] || rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

fm_herdr_lab_provision "$SESSION" || fail "could not provision the isolated Herdr lab session"

CHROME_SOURCE=firstmate-primary-status-v1
BORDER_MARKER='FM │ CHROME-BORDER-EVIDENCE codex·high'

layout_field() { # <pane> <jq filter>
  fm_herdr_lab_cli "$SESSION" pane layout --pane "$1" 2>/dev/null | jq -r "$2" 2>/dev/null
}

# Rendered box tops are the direct measure of the reclaim: one per visible pane
# in the tab, so two while the companion shows and one once it is hidden.
count_box_tops() { # <rendered screen>
  printf '%s\n' "$1" | grep -c '┌' || true
}

# --- the primary and its companion, exactly the shape the launcher builds ----

CREATE_OUT=$(fm_herdr_lab_cli "$SESSION" workspace create --cwd "$ROOT" --label chrome --no-focus) \
  || fail "could not create the lab workspace"
PRIMARY=$(printf '%s' "$CREATE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PRIMARY" ] || fail "could not parse the primary pane id: $CREATE_OUT"

SPLIT_OUT=$(fm_herdr_lab_cli "$SESSION" pane split "$PRIMARY" --direction down \
  --ratio 0.93 --no-focus --cwd "$ROOT") || fail "could not split the companion pane"
COMPANION=$(printf '%s' "$SPLIT_OUT" | jq -r '.result.pane.pane_id // empty')
[ -n "$COMPANION" ] || fail "could not parse the companion pane id: $SPLIT_OUT"

fm_herdr_lab_cli "$SESSION" pane report-metadata "$PRIMARY" \
  --source "$CHROME_SOURCE" --title "$BORDER_MARKER" --ttl-ms 120000 >/dev/null \
  || fail "report-metadata --ttl-ms was refused by the real herdr binary"

# The launcher's capability probe reads its own row back through `pane get`, so
# prove that readback actually resolves the published title.
STORED=$(fm_herdr_lab_cli "$SESSION" pane get "$PRIMARY" 2>/dev/null \
  | jq -r '.result.pane.title // empty' 2>/dev/null)
[ "$STORED" = "$BORDER_MARKER" ] \
  || fail "pane get did not read back the published border title: '$STORED'"

[ "$(layout_field "$PRIMARY" '.result.layout.panes | length')" = 2 ] \
  || fail "pane layout did not report the primary and its companion as two panes"
[ "$(layout_field "$PRIMARY" '.result.layout.zoomed')" = false ] \
  || fail "a freshly split tab already reported itself zoomed"

UNZOOMED_SCREEN=$(fm_herdr_lab_view "$SESSION" --cols 120 --rows 24 --seconds 3) \
  || fail "could not render the unzoomed lab screen"
case "$UNZOOMED_SCREEN" in
  *"$BORDER_MARKER"*) ;;
  *) fail "the border title did not render on the split primary's border" ;;
esac
[ "$(count_box_tops "$UNZOOMED_SCREEN")" -eq 2 ] \
  || fail "the unzoomed tab did not render both the primary and the companion"

pass "herdr chrome: report-metadata --ttl-ms stores a border row, pane get reads it back, and it renders on the split border"

# --- the reclaim: zoom hides the companion, the border row survives ---------

ZOOM_ON=$(fm_herdr_lab_cli "$SESSION" pane zoom "$PRIMARY" --on) \
  || fail "pane zoom --on was refused by the real herdr binary"
[ "$(printf '%s' "$ZOOM_ON" | jq -r '.result.zoom.zoomed')" = true ] \
  || fail "pane zoom --on did not report the tab zoomed: $ZOOM_ON"

# The pane count is unchanged by zoom - the companion still EXISTS, which is
# what keeps the border (and therefore the title) alive - and the flag flips.
[ "$(layout_field "$PRIMARY" '.result.layout.panes | length')" = 2 ] \
  || fail "pane layout lost a pane while the tab was zoomed"
[ "$(layout_field "$PRIMARY" '.result.layout.zoomed')" = true ] \
  || fail "pane layout did not report a zoomed tab as zoomed"

ZOOMED_SCREEN=$(fm_herdr_lab_view "$SESSION" --cols 120 --rows 24 --seconds 3) \
  || fail "could not render the zoomed lab screen"
case "$ZOOMED_SCREEN" in
  *"$BORDER_MARKER"*) ;;
  *) fail "zooming the primary dropped its border title, which is the whole status surface" ;;
esac
[ "$(count_box_tops "$ZOOMED_SCREEN")" -eq 1 ] \
  || fail "the companion pane was still rendered while the primary was zoomed, so no rows were reclaimed"

pass "herdr chrome: zooming the primary hides the companion and reclaims its rows while the border title still renders"

# --- a third pane must never be hidden -------------------------------------

THIRD_OUT=$(fm_herdr_lab_cli "$SESSION" pane split "$PRIMARY" --direction right \
  --ratio 0.6 --no-focus --cwd "$ROOT") || fail "could not add a third pane to the tab"
THIRD=$(printf '%s' "$THIRD_OUT" | jq -r '.result.pane.pane_id // empty')
[ -n "$THIRD" ] || fail "could not parse the third pane id: $THIRD_OUT"

[ "$(layout_field "$PRIMARY" '.result.layout.panes | length')" = 3 ] \
  || fail "pane layout did not report the third pane, which is the count the release path reads"
# Measured on herdr 0.7.4: splitting a zoomed tab releases the zoom itself, so
# the co-tenant is visible immediately and the renderer's release is a
# confirmation rather than the thing that saves the pane.
[ "$(layout_field "$PRIMARY" '.result.layout.zoomed')" = false ] \
  || fail "herdr kept the tab zoomed after a third pane appeared, so a co-tenant pane is hidden"

ZOOM_OFF=$(fm_herdr_lab_cli "$SESSION" pane zoom "$PRIMARY" --off) \
  || fail "pane zoom --off was refused by the real herdr binary"
[ "$(printf '%s' "$ZOOM_OFF" | jq -r '.result.zoom.zoomed')" = false ] \
  || fail "pane zoom --off left the tab zoomed: $ZOOM_OFF"
[ "$(layout_field "$PRIMARY" '.result.layout.zoomed')" = false ] \
  || fail "the tab still reported itself zoomed after the release"

pass "herdr chrome: a third pane is reported by pane layout and never left hidden, and pane zoom --off is idempotent"

# --- a deliberate unzoom is preserved --------------------------------------
#
# The tab is unzoomed. The real renderer runs against it in chrome mode, with
# the launcher's ownership signal deliberately ARMED, which is the only state
# in which it may touch the zoom at all. It must keep publishing the border row
# and must never re-apply the zoom.

FM_STATUS_HERDR_SESSION="$SESSION" HERDR_SESSION="$SESSION" \
  FM_STATUS_BAR_INTERVAL=1 FM_STATUS_CHROME_ZOOM_EVERY=1 \
  FM_HOME="$SCRATCH" FM_STATE_OVERRIDE="$SCRATCH_STATE" \
  FM_CODEX_METRICS_ROLLOUT="$SCRATCH_ROLLOUT" FM_CODEX_QUOTA_DISABLE=1 \
  FM_PRIMARY_HARNESS=codex \
  "$ROOT/bin/fm-status-bar.sh" \
    --adapter codex --model gpt-6-astra --effort high \
    --follow-pane "$COMPANION" --follow-backend herdr \
    --chrome-pane "$PRIMARY" --chrome-role FM --chrome-zoomed >/dev/null 2>&1 &
RENDERER_PID=$!
sleep 4
stop_renderer

[ "$(layout_field "$PRIMARY" '.result.layout.zoomed')" = false ] \
  || fail "the renderer re-applied the zoom and fought a deliberate unzoom"

LIVE_TITLE=$(fm_herdr_lab_cli "$SESSION" pane get "$PRIMARY" 2>/dev/null \
  | jq -r '.result.pane.title // empty' 2>/dev/null)
case "$LIVE_TITLE" in
  'FM │ '*) ;;
  *) fail "the renderer did not publish a role-marked border row: '$LIVE_TITLE'" ;;
esac
[ "$LIVE_TITLE" != "$BORDER_MARKER" ] \
  || fail "the renderer never replaced the seeded row, so it was not actually publishing"

pass "herdr chrome: the live renderer keeps publishing the border row and never re-applies a released zoom"

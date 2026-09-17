#!/usr/bin/env bash
# Add the fork's bridge fields to a finished bearings model.
#
# Usage: fm-bridge-fields.sh <fleet-snapshot-json-file> < model.json > enriched.json
#
# The phone bridge renders fields upstream's projection does not emit: the hold
# kind and reason behind a decision or a gate. In-flight rows are no longer
# enriched here at all - upstream's own projection emits their captain-facing
# `name` and `repo`, and a second copy written from this side would be the
# duplicate that drifts. The hold fields used to be edits scattered through
# upstream's jq program, which is the shape that conflicts on every upstream
# change to it. They live here instead, and bin/fm-bearings-snapshot.sh calls
# this in one guarded step.
#
# This reads the same fleet snapshot the projection read, so every value is
# derived from the same source rather than recovered from the rendered model.
# Rows are matched by id, including the "<home>/<id>" form a secondmate row
# carries. A row this cannot match keeps whatever the projection gave it.
#
# Adds fields only. With this script absent the model is upstream's exact
# projection, which is what the bridge must degrade against.
#
# A secondmate home's decisions_open and queued are looked up in separate maps,
# never merged: an actionable captain hold appears in both under one id, and
# the decision row must read its reason from decisions_open while the gate row
# reads hold_reason from queued, exactly as the projection did in its own loop
# over each collection.
#
# Key order is deliberately not part of the guarantee. The fork fields are
# appended after upstream's keys, and equivalence with the pre-extraction
# projection is proven on sorted keys.
set -eu

usage() {
  echo "usage: fm-bridge-fields.sh <fleet-snapshot-json-file> < model.json" >&2
}

main() {
  local snap=${1:-}
  [ -n "$snap" ] || { usage; return 1; }
  [ -r "$snap" ] || { echo "fm-bridge-fields: snapshot not readable: $snap" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "fm-bridge-fields: jq not found" >&2; return 1; }

  jq --slurpfile snap "$snap" '
    # Copied verbatim from the projection this enrichment came out of. The
    # tostring, the whitespace collapse and the ellipsis on a cut all change
    # rendered output, so a paraphrase here would silently alter every field
    # longer than its limit.
    def trunc($n): if . == null then null else
      (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "\u2026") else . end) end;
    ($snap[0]) as $s
    # An unstructured main row carries id null, which from_entries rejects as a
    # key; it can never be matched, so it is dropped rather than aborting. A
    # PROJECTED row may carry a null id too - an action-free posture row is one -
    # and indexing a map with null is a hard jq error, so every lookup below
    # tests the id before it indexes. Losing every bridge field to one such row
    # is exactly the silent degradation this script exists to prevent.
    | ([ $s.backlog.records[]? | select(.id != null) | {key: .id, value: .} ] | from_entries) as $main_rows
    | ([ ($s.secondmate_current.records // [])[] as $m
         | ($m.decisions_open // [])[] | {key: ($m.id + "/" + .id), value: .} ] | from_entries) as $sm_decisions
    | ([ ($s.secondmate_current.records // [])[] as $m
         | ($m.queued // [])[] | {key: ($m.id + "/" + .id), value: .} ] | from_entries) as $sm_queued
    | .decisions_open = [ .decisions_open[]
        | . as $row
        | if $row.owner == "(main)" and $row.id != null and ($main_rows[$row.id] != null) then
            ($main_rows[$row.id]) as $r
            | $row + {hold_kind: $r.hold_kind,
                      hold_reason: (($r.hold_reason // null) | trunc(160)),
                      repo: (($r.repo // null) | trunc(120))}
          elif $row.id != null and ($sm_decisions[$row.id] != null) then
            ($sm_decisions[$row.id]) as $r
            | $row + {hold_kind: ($r.hold_kind // null),
                      hold_reason: (($r.reason // null) | trunc(160)),
                      repo: (($r.repo // null) | trunc(120))}
          else $row end ]
    | .gates = [ .gates[]
        | . as $row
        | if $row.id == "(main-inventory)" then $row + {hold_kind: null, repo: null}
          elif $row.owner == "(main)" and $row.id != null and ($main_rows[$row.id] != null) then
            ($main_rows[$row.id]) as $r
            | $row + {hold_kind: $r.hold_kind, repo: (($r.repo // null) | trunc(120))}
          elif ($sm_queued[($row.owner // "") + "/" + ($row.id // "")] != null) then
            ($sm_queued[($row.owner // "") + "/" + ($row.id // "")]) as $r
            | $row + {hold_kind: ($r.hold_kind // null), repo: (($r.repo // null) | trunc(120))}
          else $row end ]
  '
}

main "$@"

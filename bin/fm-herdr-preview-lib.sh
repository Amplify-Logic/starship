#!/usr/bin/env bash
# PREVIEW ONLY - label builders for the unapproved Herdr layout convergence.
#
# Source this library; it defines functions and runs nothing.
# Nothing in the live fleet path sources it: bin/fm-visible-status.sh remains
# the only writer of real workspace, tab, and pane labels, and it is unchanged
# by this file. The only caller is
# tests/fm-herdr-layout-preview-e2e.test.sh, the opt-in lab stager that
# produces the captures in docs/herdr-layout-preview.md.
# Delete this file, its test, and the doc if the captain declines the preview.
#
#   fm_preview_project_row <project> <stats>       today's project row
#   fm_preview_worker_tab <outcome> <icon> <state> today's worker tab row
#   fm_preview_worker_detail <runtime> <branch>    today's detail row
#   fm_preview_grouped_child <outcome> <icon> <state>
#   fm_preview_prefixed_row <project> <outcome> <icon> <state>
#
# The first three build the layout we ship today (model BEFORE).
# fm_preview_grouped_child builds a header-plus-children candidate that reuses
# fm_preview_project_row for the header (model AFTER-A).
# fm_preview_prefixed_row carries the project name on the worker row itself
# (model AFTER-B).
# Every builder takes an already-resolved state and icon so this file never
# becomes a second owner of the state vocabulary; the caller resolves them
# through bin/fm-visible-format-lib.sh.
# The three today-formats are deliberately restated here rather than shared,
# so the live label writers in bin/fm-visible-status.sh stay untouched before
# the captain's decision; consolidate them into bin/fm-visible-format-lib.sh
# once the layout decision lands.

# shellcheck source=bin/fm-visible-format-lib.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/fm-visible-format-lib.sh"

# fm_preview_project_row: the project container row we ship today, and the
# header row AFTER-A keeps. <stats> is the six-count string
# fm_visible_aggregate consumes.
fm_preview_project_row() {  # <project-name> <stats>
  printf '%s · %s' "$1" "$(fm_visible_aggregate "$2")"
}

# fm_preview_worker_tab: the worker tab title we ship today. AFTER-A and
# AFTER-B both keep it, so the view inside a worker is unchanged either way.
fm_preview_worker_tab() {  # <outcome> <icon> <visible-state>
  printf 'WORKER · %s · %s %s' "$1" "$2" "$3"
}

# fm_preview_worker_detail: the grouped Agents detail row we ship today.
# Unchanged in both candidates.
fm_preview_worker_detail() {  # <runtime> <branch>
  printf '%s · %s' "$1" "$2"
}

# fm_preview_grouped_child: AFTER-A worker row. One workspace per worker,
# labelled as a child of the project header above it. The leading character is
# literal U+2514 BOX DRAWINGS LIGHT UP AND RIGHT, matching upstream's own
# projection label so the two shapes are comparable.
# This row depends on sidebar adjacency to say which project it belongs to.
fm_preview_grouped_child() {  # <outcome> <icon> <visible-state>
  printf '└ %s · %s %s' "$1" "$2" "$3"
}

# fm_preview_prefixed_row: AFTER-B worker row. One workspace per worker,
# carrying its own project name, so the row stays readable wherever Herdr
# places it.
fm_preview_prefixed_row() {  # <project-name> <outcome> <icon> <visible-state>
  printf '%s · %s · %s %s' "$1" "$2" "$3" "$4"
}

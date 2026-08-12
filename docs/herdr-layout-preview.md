# Herdr layout preview: what the fleet list looks like after convergence

**Status: preview only, nothing is live.**
Nothing in this document is switched on.
The live fleet still uses the layout shown under BEFORE, and it stays that way until the captain approves a change.

The decision this preview serves was already made: converge on upstream's Herdr backend and adopt its one-worker-per-container execution unit, because isolating and inspecting a single worker is genuinely better that way, but do not adopt upstream's raw visual hierarchy.
Upstream's list is flat, labelled by task slug, carries no project context, and degrades past about five workers (the private firstmate-home report `data/fm-upstream-trial-verdict-v2/report.md`, sections "One-worker-per-container: real opinion after using it" and "What ours does better").
This preview shows what upstream's worker unit looks like once our human-readable project labels are put back on top of it.

## The two-minute version

**What changes.** Today one row in the fleet list is one project, and you open it to see its workers.
After convergence one row is one worker, so a fleet of eight workers is eight rows instead of three.
Each row carries its own project name, so `Atelier · Retry the nightly artwork export · 🔴 FAILED` reads completely on its own line.

**What stays.** The words stay.
Human outcomes instead of task slugs, `NEEDS YOU` / `FAILED` / `BLOCKED` in plain capitals with their colour, and the runtime and branch on the detail row are all unchanged.
Opening a worker looks exactly like it does today.
No 22-character token is ever shown, and nothing about how work is identified or controlled changes.

**What is lost.** One thing: the per-project count line, `City Guide · 🟣 1 NEEDS YOU · 🔵 2 WORKING`, is not part of the recommended layout, so out of the box you read the fleet by scanning eight rows instead of three summaries.
Counts are partly recoverable in the fork, on a single summary row rather than one row per project, though at fleet scale that row most likely carries fleet totals rather than a per-project breakdown, for width reasons the end of this document sets out.
At eight workers scanning is a fair trade; at thirty it would not be, and that is when the summary row becomes worth building and testing.

**Recommendation.** Go ahead with AFTER-B below.
It is the only one of the two candidates that survives real use: I tried the version that keeps a project heading with its workers indented underneath, and it breaks the first time a worker starts out of order, which happens constantly on a real fleet.
The evidence is in this document.

## How these were produced

Every layout below was staged in a real, throwaway Herdr workspace of its own, using the guarded lab helper for every single operation including cleanup.
The live fleet was never touched, and the check that proves the live fleet was unchanged passed after each of the three runs.

The synthetic fleet is eight workers across three projects, covering five of the six states the fleet list can show: `NEEDS YOU`, `FAILED`, `BLOCKED`, `WORKING` and `READY`.
The sixth state, the paused `🟡 WAITING`, is not exercised by these captures, so the yellow slot of the count line and the AFTER-B row format are unverified for that one state.
Seven start in project order; the eighth, `Fix the crash on the last booking step`, deliberately starts last, for a project whose other workers started first.
That eighth worker is the whole experiment: it is what a normal day looks like.

The rows are Herdr's own reported labels, read back after staging, not mock-ups.
They are printed here as text rather than photographed because taking a picture would mean attaching to the throwaway workspace, and the safety helper correctly refuses that.
Regenerate them with:

```bash
FM_HERDR_LAYOUT_PREVIEW_E2E=1 \
  FM_HERDR_LAYOUT_PREVIEW_OUT=docs/evidence/herdr-layout-preview \
  HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh \
  tests/fm-herdr-layout-preview-e2e.test.sh
```

Verified 2026-08-03 against Herdr 0.7.4 on macOS 25.5.0.
Raw captures: [`docs/evidence/herdr-layout-preview/`](evidence/herdr-layout-preview/).

## BEFORE: what you see today

Three rows, one per project, each with a running count of what its workers need.

```text
WORKSPACE  City Guide · 🟣 1 NEEDS YOU · 🔵 2 WORKING
  TAB      WORKER · Validate GPS triggers across all seven city stops · 🔵 WORKING
  DETAIL   pi/gpt-5.6 · detached
  TAB      WORKER · Decide the harbour-loop audio cut · 🟣 NEEDS YOU
  DETAIL   claude/opus-5 · fm/journey-route-audio-q2
  TAB      WORKER · Speed up the offline map tiles · 🔵 WORKING
  DETAIL   codex/gpt-5.6 · fm/journey-tile-cache-r3
WORKSPACE  Atelier · 🟣 1 NEEDS YOU · 🔴 1 FAILED
  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS YOU
  DETAIL   claude/opus-5 · fm/atelier-onboarding-copy-k4
  TAB      WORKER · Retry the nightly artwork export · 🔴 FAILED
  DETAIL   pi/gpt-5.6 · fm/atelier-export-retry-m1
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
  TAB      WORKER · Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
  DETAIL   claude/opus-5 · fm/api-platform-rate-limit-c7
  TAB      WORKER · Audit the public schema for breaking changes · 🟢 READY
  DETAIL   codex/gpt-5.6 · detached
```

`WORKSPACE` is a row in the fleet list, `TAB` is a worker inside it, `DETAIL` is that worker's runtime and branch.
Full capture: [`01-before.txt`](evidence/herdr-layout-preview/01-before.txt).

When the eighth worker starts, the list does not grow.
It joins its own project and the count on that project's row goes up:

```text
WORKSPACE  City Guide · 🟣 1 NEEDS YOU · 🔴 1 FAILED · 🔵 2 WORKING
  ...
  TAB      WORKER · Fix the crash on the last booking step · 🔴 FAILED
  DETAIL   claude/opus-5 · fm/journey-checkout-crash-t9
```

Full capture: [`02-before-late-worker.txt`](evidence/herdr-layout-preview/02-before-late-worker.txt).
This order-independence is what today's layout buys, and it is exactly what the convergence has to pay for.

## AFTER-A: a project heading with workers indented under it

The obvious way to keep project grouping on upstream's unit is to give each project a heading row and put its workers, now one row each, directly beneath it.
Staged in project order it looks almost like today:

```text
WORKSPACE  City Guide · 🟣 1 NEEDS YOU · 🔵 2 WORKING
WORKSPACE  └ Validate GPS triggers across all seven city stops · 🔵 WORKING
WORKSPACE  └ Decide the harbour-loop audio cut · 🟣 NEEDS YOU
WORKSPACE  └ Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Atelier · 🟣 1 NEEDS YOU · 🔴 1 FAILED
WORKSPACE  └ Decide the onboarding welcome copy · 🟣 NEEDS YOU
WORKSPACE  └ Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
WORKSPACE  └ Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  └ Audit the public schema for breaking changes · 🟢 READY
```

Full capture, with every worker's tab and detail row: [`03-after-a-grouped.txt`](evidence/herdr-layout-preview/03-after-a-grouped.txt).

**This is the shape that fails.**
Herdr puts a new row at the bottom of the list and offers no way to move it.
So when the eighth worker starts, for City Guide, whose heading is at the very top, it lands here instead:

```text
WORKSPACE  City Guide · 🟣 1 NEEDS YOU · 🔴 1 FAILED · 🔵 2 WORKING
WORKSPACE  └ Validate GPS triggers across all seven city stops · 🔵 WORKING
WORKSPACE  └ Decide the harbour-loop audio cut · 🟣 NEEDS YOU
WORKSPACE  └ Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Atelier · 🟣 1 NEEDS YOU · 🔴 1 FAILED
WORKSPACE  └ Decide the onboarding welcome copy · 🟣 NEEDS YOU
WORKSPACE  └ Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
WORKSPACE  └ Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  └ Audit the public schema for breaking changes · 🟢 READY
WORKSPACE  └ Fix the crash on the last booking step · 🔴 FAILED
```

Full capture: [`04-after-a-late-worker.txt`](evidence/herdr-layout-preview/04-after-a-late-worker.txt).

The last row is a City Guide worker, but it is sitting under the API Platform heading, and the indent makes it look like it belongs there.
The Journey heading four rows above correctly counts it, so the counts and the layout now disagree.
That is worse than no grouping at all: a wrong project label is a trap, and this one appears every time a worker starts out of order, which on a real fleet is most of the time.

There is no way to fix this from our side.
Ordering is fixed at creation and there is no reorder or nesting command, so any layout that relies on a row's position to say which project it belongs to is unreliable by construction.

## AFTER-B: the project name on every row (recommended)

Put the project name on the worker row itself and the layout stops depending on position:

```text
WORKSPACE  City Guide · Validate GPS triggers across all seven city stops · 🔵 WORKING
WORKSPACE  City Guide · Decide the harbour-loop audio cut · 🟣 NEEDS YOU
WORKSPACE  City Guide · Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Atelier · Decide the onboarding welcome copy · 🟣 NEEDS YOU
WORKSPACE  Atelier · Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  API Platform · Audit the public schema for breaking changes · 🟢 READY
```

Full capture, with every worker's tab and detail row: [`05-after-b-prefixed.txt`](evidence/herdr-layout-preview/05-after-b-prefixed.txt).

The eighth worker still lands at the bottom, and it still reads correctly:

```text
WORKSPACE  City Guide · Fix the crash on the last booking step · 🔴 FAILED
```

Full capture: [`06-after-b-late-worker.txt`](evidence/herdr-layout-preview/06-after-b-late-worker.txt).

Same eight workers, same three projects, nothing misleading, and no row that means something different depending on where it sits.

Opening any of these workers gives exactly what you get today:

```text
  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS YOU
  DETAIL   claude/opus-5 · fm/atelier-onboarding-copy-k4
```

## Side by side

| | Today (BEFORE) | AFTER-A heading + indent | AFTER-B project on each row |
|---|---|---|---|
| Rows at 8 workers, 3 projects | 3 | 11 | 8 |
| Project shown for every worker | yes | only while ordering holds | yes |
| Survives a worker starting out of order | yes | **no** | yes |
| Per-project count line | yes | yes, but can contradict the layout | not as staged, partly recoverable as one pinned summary row |
| `NEEDS YOU` / `FAILED` / `BLOCKED` prominent | yes | yes | yes |
| Human outcome instead of a task slug | yes | yes | yes |
| Runtime and branch visible | yes | yes | yes |
| Inside a worker | unchanged | unchanged | unchanged |
| Upstream's one-worker unit | no | yes | yes |

## What is honestly given up, and what it would take to get back

Two things go with AFTER-B as staged, and they are not equally hard to get back.

**The per-project count line is not in the recommended layout, and only partly recoverable in the fork.**
At eight workers, scanning eight labelled rows for a purple dot is fine.
At twenty-five it would be worse than three summary rows, so at that scale it is worth building the row described here first.

The recovery works by the same mechanism that makes AFTER-B work.
Herdr's workspace order is creation order, and a later workspace always appends, so a holder workspace created before any worker keeps position 1 permanently and never has to be moved.
AFTER-A already proves the two halves of this are possible: a non-worker holder workspace is stageable, and its row is renamed on each state change exactly the way `update_project` renames project rows today.
Capture 03 stages three such holder rows, the first of which reads `City Guide · 🟣 1 NEEDS YOU · 🔵 2 WORKING`.
Capture 04 is the stronger evidence for the claim, because it shows that same holder row recounted after the late worker arrived, as `City Guide · 🟣 1 NEEDS YOU · 🔴 1 FAILED · 🔵 2 WORKING`.
That recounted row is a holder row being re-rendered on a state change, which is exactly what a summary row would have to do.
What broke AFTER-A was adjacency, and a single fleet-summary row pinned at the top does not depend on adjacency at all.
So one first-created row could carry counts that no longer depend on where anything sits, at the cost of one extra row rather than one per project.

Two things are not yet verified, and both need testing before anyone commits to the summary row.
First, whether a first-created workspace still holds position 1 across a Herdr session restart.
Second, whether a single summary row stays legible at realistic width, which is the more likely of the two to bite.
[`docs/herdr-backend.md`](herdr-backend.md) records a real Herdr pane measuring 54 columns in the environment it was verified in, and the widest of the three staged project rows is already 51 characters, so concatenating every project's counts onto one row runs to several hundred characters in a sidebar that truncates.
At the twenty-five-worker scale that motivates the summary row, per-project counts on one row are very likely too wide to read, so the realistic version of that row carries fleet totals rather than a per-project breakdown.
That is still worth having, but it is less than what the three project rows give you today, and it is the honest size of what this recovery buys.

**Same-project workers no longer sit together, and that one really is upstream's to fix.**
They appear in the order they started.
Because every row names its project this is a scanning cost rather than a correctness problem, and sorting by urgency is not available either, for the same reason: the list order cannot be controlled.

**The upstream ask is worth raising for real grouping and sorting.**
Herdr would need to let a row declare a parent, or let the list be sorted, so grouping does not depend on creation order.
That is a small, well-defined ask and it benefits upstream's own supervisor tree, which has exactly the same weakness: their `└ ` child rows drift away from their parent the same way AFTER-A's did.
Worth raising with Kun Chen; worth doing regardless of whether he takes it.
It is no longer the only way to get counts back, though, because the pinned summary row above does not need it, and it stays the only way to get a per-project breakdown back at a scale where one row cannot hold one.

## What is in this branch

Nothing here changes the live fleet.
The only change to a file the running fleet uses is a mechanical one that moved three label-formatting helpers into a library so the preview reuses the exact same state words and colours instead of copying them.
`bin/fm-visible-status.sh` behaves identically, verified by its existing tests.

- `bin/fm-visible-format-lib.sh` - the state vocabulary (`NEEDS YOU`, `FAILED`, colours, ordering), now owned in one place.
- `bin/fm-herdr-preview-lib.sh` - preview-only row builders for BEFORE, AFTER-A and AFTER-B, sourced by nothing the live fleet runs.
- `tests/fm-herdr-layout-preview-e2e.test.sh` - the opt-in lab stager that produced every capture above, and asserts the failure in AFTER-A so it cannot quietly stop being true.
- `docs/evidence/herdr-layout-preview/` - the raw captures.

If the captain approves AFTER-B, the follow-up work is adopting upstream's backend and pointing the live label writer at `fm_preview_prefixed_row`'s format.
If the captain declines, delete the two preview files, this document, and the captures; the vocabulary library stays because it is an improvement either way.

# The chart room

The chart room is a private read-only view of where every project stands, served on IPv4 loopback and rendered fresh on every request.
`bin/fm-chart-room.sh` and `bin/fm-chart-room.mjs` own its commands and mechanics; read the script header before first use.
This document owns the goal charter format, which is the one new thing the chart room asks anyone to record.

## What it is, and what it deliberately is not

Start it with `bin/fm-chart-room.sh serve` and open `http://127.0.0.1:4390`.

Every page is derived when it is requested, from the records that already exist: the backlog through `tasks-axi`, `data/projects.md`, `state/<id>.meta`, `data/<id>/report.md`, and `data/done-archive.md`.
Nothing is cached, pre-generated, or refreshed on a timer, so a link followed hours after it was printed shows the records as they are then rather than as they were when the link was made.
That is the whole reason this is a server rather than a generated page: a surface that outlives its premises is the failure this design exists to prevent.

The server is read-only.
It never writes to the backlog, task metadata, decisions, reports, or any project, and it makes no outbound network calls.
The bind address is a constant in the engine with no flag or environment variable that widens it, so the chart room cannot be published to a network by configuration.

It does not grow a second way to answer a decision.
Answers keep their existing single owner in `bin/fm-decision-surface.sh`; the chart room only makes sure a waiting decision is visible and explains itself.

## Views

| Address | What it shows |
| --- | --- |
| `/` | The fleet home: the answers the captain owes, then one row per project |
| `/p/<project>` | That project's goal map, or a flat list when it has no charter |
| `/p/<project>/node/<id>` | The story behind one piece of work, decision, or goal |
| `/report/<task-id>` | A finished report, rendered through the same Markdown owner `fm-read.sh` uses |

Every row, chip, heading, and tab on those pages opens something.
A folded bucket holds its rows rather than dropping them, so the "show more" row expands in place instead of naming work it will not show.

## The goal charter

A charter is optional.
A project without one renders flat and functional; a project with one gets the goal map.
It lives in the private home at `data/goals/<project>.md`, where `<project>` is the name in `data/projects.md`.

Firstmate drafts a charter from the recorded history and the captain approves it.
A charter whose status line says DRAFT still renders, clearly marked as a proposal awaiting his word, so he can judge the real thing rather than a description of it.

```markdown
# Alpha
Status: DRAFT - awaiting captain approval
Aliases: alpha-legacy-name

## Port of arrival
One paragraph naming the end state this project is sailing toward.

## Goals

### g1 - The weekly run finishes without a nudge
Covers: alpha-run-*
Planned:
- A quiet week proves itself

### g2 - Open to other crews
On ice: your order of 2 August - nothing outward until the run is boring.
Covers: alpha-outward-*
```

- `# <title>` names the project on its own pages. Optional; the registry name is used otherwise.
- `Status:` marks the charter a proposal when it contains the word DRAFT.
- `Aliases:` lists further names work may have been filed under, for projects whose recorded name has drifted. A project's own registered name always wins over another project's alias.
- `## Port of arrival` is the end state, rendered at the foot of the map.
- `### <id> - <title>` opens a goal. The id is stable and short (`g1`, `g2`); the title is a plain outcome sentence.
- `On ice: <reason>` marks a goal paused, with the captain's own words for why. Its work keeps its place rather than disappearing.
- `Planned:` introduces bullets that are intent only - work that is not filed anywhere yet. They render greyed and are never counted as progress.
- `Covers:` maps work that predates the chart, as exact identities or `prefix-*` families. Naming one piece of work outright beats a family that happens to include it.

## How work reaches a goal

In order:

1. The task's own note carries a `goal: <id>` line. This is the forward habit: one line at intake, no schema change.
2. Otherwise the charter's `Covers:` entries claim it, which is how work filed before the chart existed reaches its goal without anyone editing the backlog after the fact.
3. Otherwise it lands in the trailing "Other work" lane.

That last lane is deliberate.
Work can be untagged, but it cannot be invisible, and a chart that disagrees with the records shows the disagreement instead of hiding it.
The same applies at fleet level: work whose project matches nothing on the register is listed on the home page rather than dropped.

The same rule covers a record that cannot be read at all.
Identity is enumerated first, then each record is read on its own; when that read fails or its output does not parse, the piece of work is still shown, by name, marked as one whose record could not be read.
It is never dropped, and one bad record never blanks the page around it.
A record like that names no project, so the fleet home is where it surfaces rather than any one project's map.
A record that is read only as far as its identity keeps that identity as its name, because a row the captain cannot name is a row he cannot act on.

## Language

The chart room's own words are the captain's: shipped, under way, charted next, your call, on ice.
Text quoted from the records - a park reason, a task note - is shown as it was recorded, because rewriting a stored reason at render time would put words in the record's mouth.
Keeping those reasons in plain language is therefore a property of how they are written, not something this renderer can add afterwards.

## Putting a view on his screen

`bin/fm-overlay.sh <report-or-path>` opens a Markdown file as an overlay pane inside the captain's terminal, through Herdr's `plugin pane open --placement overlay`.
Nothing calls it by default.

It never installs anything.
The viewer is third-party code that runs inside the captain's own session, so installing one is his call.
When no viewer is installed, when the terminal is not Herdr, or when the pane refuses to open, the helper prints where to read the same content and exits successfully - a missing overlay never fails the caller that only wanted to show something.
What it prints is the chart room's `/report/<task-id>` address when the file is a task report, and the file's own path for any other Markdown, because a derived link for a goal charter or a note beside a report would lead nowhere.

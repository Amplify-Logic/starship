# Factory pane

A factory is one segment of the owner's work: a crew with its own work list, rules, memory and workers.
The Factory pane is the glance across all of them, as a Herdr pane beside your work, and `enter` opens one factory's own tab with its live workers beside it.
`bin/fm-factory.py` owns the record, the screen, the keys and the factory tabs, and `bin/fm-factory-pane.sh` owns installing, showing and removing the pane; read their headers before first use.
`herdr-plugins/starship-factory/` is the Herdr plugin that carries it.
The [factory registry](configuration.md#factory-registry-datafactoriesmd) names a home's factories; without one, every registered project is its own factory.

## The overview

```text
 S T A R S H I P  │  2 jobs running  ·  3 need you  ·  1 idle                    Sat 15:47

 NEEDS YOU

 ▸ ● Harvest chart: a question for you                        Garden Journal · waiting 3 h
       The harvest chart can open on this week or this season.
       1  this week  · the crew suggests this
       2  this season
       3  both side by side
       t  Talk it through

   ● Share a garden page as a picture is ready for you to look at

 RIGHT NOW

   Sample Shop                                                             Starship steers
     ● Search that forgives typos                                                   47 min
       ✓ planning ••••• ▸ building •••••   checking ·····   ready for you
       running the search tests: 41 of 58 passed
       next  Gift wrap at checkout · then 3 more

   Recipe Box   idle since 06:46 · nothing in line                         Starship steers

 SINCE YOU LAST LOOKED   since 03:46

   12:36    Garden Journal  asked you  Harvest chart has a question for you.
   13:57    Garden Journal  finished   Share a garden page as a picture is finished.

 ↑↓ move · 1/2/3 answer · enter open · t talk · s who steers · q quit
```

- The count line is the bridge strip's look: running jobs, what needs you, idle factories, and the time.
- NEEDS YOU comes first, across all factories, questions before finished work.
  A question shows its why in one or two lines, its options when the question wrote them as `Options: 1 ..., 2 ...` or `A ..., B ...`, who suggests one, and what it holds up.
  The first two and the highlighted one open in full; the rest stay one line each so a long list still leaves room for the floor.
- RIGHT NOW lists each factory with who steers it.
  A running job shows its title, how long it has run, the four steps (planning, building, checking, ready for you), and what it is doing this minute.
  A job with no sign of life for 15 minutes says `quiet for N min, no sign of life` instead, and its light stops moving.
  An idle factory is one faint row.
- SINCE YOU LAST LOOKED is one rolling list since the pane was last closed: the time, who acted (a factory, Starship, or you), one word, and a sentence.

Colour only repeats what the words already say: cyan is where you are, amber is work under way, green is done, red is waiting for you.

## A factory's own tab

`enter` on a factory, or on something that needs you, opens that factory's tab, or focuses it when it is already open.
Its page is on the left: the count line, so other factories' questions stay in view, then this factory's NEEDS YOU, its work in order, the rules the crew follows, what it has learned lately, its own feed, and the talk history.
Its live workers are stacked on the right, at most four, each a read-only copy of that worker's own pane that refreshes every two seconds.
Typing never reaches a worker from there; talking goes through the talk box.
`esc` goes back to the tab the factory was opened from, and `q` closes the tab with its worker copies.
Outside Herdr, `enter` opens the same page in place instead.

## Keys

| Key | What it does |
| --- | --- |
| `↑` `↓` | Move the highlight; it starts on the first thing that needs you. |
| `enter` | Open the highlighted factory's tab. |
| an option key | Answer the highlighted question with that option, after `enter` confirms it. |
| `k` | Keep the highlighted finished work and ask Starship to land it, after `enter` confirms it. |
| `c` | Ask for changes to the highlighted finished work, in the talk box. |
| `t` | Talk to the highlighted factory's crew, or talk the highlighted question through. |
| `s` | Switch who steers the highlighted factory, both ways. |
| `esc` | Back, or cancel a confirmation or the talk box. |
| `q` | Quit. |

Every writing key acts on the highlighted row only; the highlight stays on the same question or factory when the record refreshes, a pending confirmation closes when what it is about leaves the record, and an open talk box keeps its text but says it was settled elsewhere, sends nothing, and closes with `esc`.
An answer, a keep, a change request and anything said in the talk box become a captain inbox note (`bin/fm-inbox.sh note`), the existing path for the owner to tell Starship something, saved once under a request id that names the factory and the item; an answer's id also names the question's key and when it was asked, and a keep's id the time the work became ready, so a repeated press is one note but a new or re-asked question or returned work is a new one.
Starship then acts on it under its own rules: it records the answer on the held decision, merges only under its merge rules, and passes words on to the crew.
The pane itself merges nothing, answers no held decision itself, and types into no worker, which is why the talk box says `Starship hears this too`.

Talking never changes who steers; only `s` does.
`s` records the change in `state/factory/steer.log`, tells Starship through the same inbox, and shows it in the feed.
Who steers is the owner's stated choice of whether he is working with that crew himself or Starship is; it grants Starship no new authority and takes none away.

## One record behind the screen

`bin/fm-factory.py --data` prints the record the screen is drawn from, and `--plain` prints the screen as text, so an agent reading the pane loses nothing.
`--plain --factory <id>` prints one factory's page.
Both use the cached record while it is younger than 20 seconds and build a fresh one otherwise.

The record's schema is `fm-factory.v1`:

| Field | What it holds |
| --- | --- |
| `as_of`, `since` | When the record was built and the start of SINCE YOU LAST LOOKED, as UTC times and epochs. |
| `counts`, `count_line` | Running jobs, items that need you, and idle factories. |
| `needs_you[]` | Each question or finished work: its `id`, `factory`, `kind`, `title`, `ask`, `why`, `options[]` (`key`, `label`, `suggested`), `suggested_by`, `holds_up[]`, `since`, `pr`, `for`, the person it waits on, and a worker question's decision `key`. |
| `factories[]` | Each factory: `id`, `name`, `about`, `projects`, `steered_by`, `state`, `idle_since`, `crew`, `needs` (the ids of its items in `needs_you`), `jobs[]`, `next`, `rules`, `learned`, and `talk`. |
| `factories[].jobs[]` | Each job: `id`, `title`, `kind`, `state`, `step`, `started`, `doing` and where it came from, `last_sign_of_life` and where it came from, `quiet`, `until`, and `pr`. |
| `feed[]` | Each event: `at` (or a `date` when only the day is known), `actor`, `factory`, `word`, and `text`. |

Every state is a word: a job is `running`, `waiting on you`, `ready for you`, `stuck`, `waiting`, `stopped`, `no worker`, `no reading`, `with Starship`, `finished`, `next`, `later`, `on hold`, `on hold until <date>`, or `waits on other work`; a factory is `needs you`, `at work`, or `idle`.

## Where each part comes from

| Part | Source |
| --- | --- |
| Jobs, decisions, finished work, the work list | `bin/fm-fleet-snapshot.sh --json`, the canonical fleet reading |
| Each job's state word | `fm_fleet_status_bucket` in `bin/fm-fleet-status-lib.sh`, the same fold the status bar and bridge strip count with |
| Which factory a job belongs to | Its work item's project, through the factory registry |
| How long a job has run | Its spawn time in the task's metadata |
| What a job is doing this minute | The worker's stated step, else the checks' own state, else `at work, no step reported yet` |
| The last sign of life | The newest of the worker's turn times (`state/<id>.busy-state`), its last finished turn, its last status line, its stated step, and the last time its pane text was seen to change |
| The feed | The `[at=]` times on status lines, completed work items, the who-steers log, and the owner's own notes and Starship's replies from the inbox |
| Rules and what it has learned | The factory registry |

The pane text check reads each running worker's pane through `bin/fm-peek.sh` once per record and remembers when it last changed in `state/factory/activity.json`.

### Stating the current step

A worker may say what it is doing this minute by writing one line of plain words to `state/<task-id>.step` in its home, beside its status file, for example `running the app's tests: 213 of 340 passed`.
Only the first line is read, up to 140 characters, and it counts only when written after the job started.
It is optional: without it the pane falls back to the sources above.

## Not in this first draft

- The night-shift `Tonight` row is left out, because no night-shift work list exists in the shared code for it to read.
- There is no key to add work.

## Install, show, and remove

Run each from a pane inside the Herdr workspace:

```sh
bin/fm-factory-pane.sh install   # link the plugin and show the Factory pane beside this pane
bin/fm-factory-pane.sh remove    # close every Factory pane and factory page, and unlink the plugin
```

Set `FM_HOME` when installing for a home other than this code root; the pane remembers it.
To show the pane beside another pane later, bind the plugin's `starship.factory.open` action to a key.

## Verification

`tests/fm-factory.test.sh` builds a fixture home of sample factories and a fixture fleet reading, and checks the record and the plain screen word for word, the quiet job, the registry fallback, the writing keys pressed in the real live view, and the Herdr calls behind the factory tab and the plugin against a stand-in Herdr.

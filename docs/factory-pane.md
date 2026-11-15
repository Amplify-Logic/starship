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

 ▸ ● Harvest chart                                            Garden Journal · waiting 3 h
       The harvest chart can open on this week or this season.
       1  this week  · Starship suggests this
       2  this season
       3  both side by side
       t  Talk it through
       x  Already settled?

   ● Share a garden page as a picture is ready for you to look at

 RIGHT NOW

   Sample Shop                                                             Starship steers
     ● Search that forgives typos                                                   47 min
       ✓ planning ••••• ▸ building •••••   checking ·····   ready for you
       running the search tests: 41 of 58 passed
       next  Gift wrap at checkout · then 3 more

   Recipe Box   idle since 06:46 · nothing in line                         Starship steers

 SINCE YOU LAST LOOKED, 03:46

   12:36    Garden Journal  asked you  Harvest chart needs your call.
   13:57    Garden Journal  PR ready   Share a garden page as a picture has its PR ready.

 ↑↓ move · 1/2/3 answer · x settled? · enter open · t talk · s who steers · q quit
```

- The count line is the bridge strip's look: running jobs, what needs you, idle factories, and the time.
- NEEDS YOU comes first, across all factories, questions before finished work.
  It lists exactly the owner's calls, the one count the bridge strip and the tap page also show: each decision held for the owner that waits on him now (not aged, deferred to a date, or waiting on other work), and each PR or ready branch waiting for the merge word whose task carries no open captain hold.
  `fm_owner_calls` in `bin/fm-fleet-status-lib.sh` owns that count.
  A worker's question and an ask-user review finding go to Starship, which answers them or holds them for the owner, so they never appear here; their jobs read `with Starship` or are still in the checks.
  A question shows its why, the options and suggestion its tap card carries (`bin/fm-tap-desk.sh shapes`, including any recorded with `fm-tap-desk.sh mark`), and what it holds up.
  Those options come from the hold's recorded marks or its reason; its title gives them only when it is a plain two-way call (`X or Y`, perhaps ending in `?`), never when it holds a comma, a parenthesis, a spaced ` / ` or ` vs `, or more than two choices.
  A question with no options recorded shows only its plain words and `Talk it through`.
  The first two and the highlighted one open in full, every word of the title and each option wrapped to the pane's width; the rest stay one line each, shortened on a whole word with an ellipsis, so a long list still leaves room for the floor.
- RIGHT NOW lists each factory with who steers it.
  A running job shows its title, how long it has run, the four steps (planning, building, checking, ready for you), and what it is doing this minute.
  A job with no sign of life for 15 minutes says `quiet for N min, no sign of life` instead, and its light stops moving.
  An idle factory is one faint row.
- SINCE YOU LAST LOOKED is one rolling list since the owner last looked at the pane: the time, who acted (a factory, Starship, or you), one word, and a sentence.
  A look is a key pressed in the pane, or the pane focused in Herdr for a few seconds; focus alone keeps a look going for at most 15 minutes after the focus began or the last key press, so a pane left focused all day does not hold the list back. Only Herdr saying the pane is not focused ends a focus; a failed or unreadable answer from Herdr changes nothing. A look ends 15 minutes after its last key press or counted focus, and while one is under way the list keeps starting where the look before it ended.
  Its heading names that time; with no look recorded yet it reads LAST 12 HOURS, and it never reaches back more than two days, reading LAST 48 HOURS when the last look is older.
  A factory's own tab records no look, since it shows one factory only.
  It holds outcomes (`finished`, `PR ready`, `landed`, `failed`), the owner's own calls as they were held (`asked you`), and what the owner and Starship said; a worker's pause, a blocker, and a question a worker put to Starship never appear.
  A ship's `done` is an outcome only when it is the ready report, so a build handed into the checks is not listed as finished.

When the screen is taller than the pane, the count line stays on top and the keys at the bottom while everything between them scrolls.
The highlight keeps itself in sight as it moves, `pgup`, `pgdn` and the mouse wheel scroll the view, and the row under the count line and the row above the keys say how many lines are out of sight above or below.
The pane asks the terminal for mouse reports to see the wheel, so Herdr's own text selection does not work inside it.

Colour only repeats what the words already say: cyan is where you are, amber is work under way, green is done, red is waiting for you.

## A factory's own tab

`enter` on a factory, or on something that needs you, opens that factory's tab, or focuses it when it is already open.
Its page is on the left: the count line, so other factories' questions stay in view, then this factory's NEEDS YOU, its work in order, the rules the crew follows, what it has learned lately, its own feed, and the talk history.
Its live workers are stacked on the right, at most four, each a read-only copy of that worker's own pane that refreshes every two seconds.
Only a worker at work gets a copy: one that is `running`, `with Starship`, `stuck`, or `waiting on you`.
A parked, held, queued, or finished job gets none, and a copy closes its own pane only once its job really ends: when the job is gone from the record or `finished`, landed, `ready for you`, `stopped`, `no worker`, parked (`waiting`), or held (`on hold`, `on hold until <date>`, `waits on other work`); it stays open through `no reading`.
Typing never reaches a worker from there; talking goes through the talk box.
`esc` goes back to the tab the factory was opened from, and `q` closes the tab with its worker copies.
Outside Herdr, `enter` opens the same page in place instead.

## Keys

| Key | What it does |
| --- | --- |
| `↑` `↓` | Move the highlight; it starts on the first thing that needs you, and past the first or last row the view scrolls instead. |
| `pgup` `pgdn`, mouse wheel | Scroll the view, without moving the highlight or closing a confirmation or the talk box. |
| `enter` | Open the highlighted factory's tab. |
| an option key | Answer the highlighted question with that option, after `enter` confirms it. |
| `x` | Tell Starship the highlighted question looks already settled, so it re-checks it. |
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
`x` files a reconcile request for the question through `bin/fm-captain-hold.sh reconcile-requests` under the pane's own source, which installing the pane binds, and wakes Starship with an inbox note naming the call, and it never closes anything itself.
Only `install` binds that source and only `remove` unbinds it, so a pane installed before the key existed needs `install` once more.
While the card reads `checking`, the footer leaves `x settled?` out and a press only says `Starship is already checking this`, filing nothing and sending no note, once the inbox holds the note that press would send; if that note never got saved, the press files and sends as usual.
Starship re-reads the conversation and records it in that turn: it closes the call with the evidence (`reconcile close`), or rewrites it by retitling it with `bin/fm-tasks-axi.sh update <id> --title '<new title>'` and holding it again with `bin/fm-captain-hold.sh hold <id> --reason '<new reason>'`, and a rewritten call still retires its pending request with `reconcile note`.
The card reads `checking` while that request is pending and either it or the pane's settled note for the call is from since the call was last held; a press that finds a request from before the call was last held names its note after that time, so it always wakes Starship.

Talking never changes who steers; only `s` does.
`s` records the change in `state/factory/steer.log`, tells Starship through the same inbox, and shows it in the feed.
Who steers is the owner's stated choice of whether he is working with that crew himself or Starship is; it grants Starship no new authority and takes none away.

## One record behind the screen

`bin/fm-factory.py --data` prints the record the screen is drawn from, and `--plain` prints the screen as text, so an agent reading the pane loses nothing.
`--plain --factory <id>` prints one factory's page, and `--plain --height <rows>` prints only what a pane that tall shows when it opens.
Both use the cached record while it is younger than 20 seconds and build a fresh one otherwise.
The owner's calls do not wait for that: when their change signal (`bin/fm-owner-calls-signal-lib.sh`) has moved past the one the record was built under, the record is rebuilt with a fresh read of the backlog and the inbox on the workers as the last full refresh read them, which takes a second or two rather than a full refresh.
The live pane checks that signal once a second, so an answered, parked, released, closed or added decision, or a note to Starship, changes NEEDS YOU within about two seconds.
The record is always built by the code on disk, so a running pane or worker copy checks before every frame whether `bin/fm-factory.py` changed, and re-runs itself in place, in the same pane, once the new file is non-empty and compiles.
The live pane holds that reload while the talk box, a confirmation or a notice is showing, so a draft or a sent or not-sent line is never lost, and reloads on the first frame after.

The record's schema is `fm-factory.v1`:

| Field | What it holds |
| --- | --- |
| `as_of`, `since` | When the record was built and the start of SINCE YOU LAST LOOKED, as UTC times and epochs. |
| `snapshot_epoch`, `calls_signal` | When the workers in it were read, and the owner's calls signal its calls were read under. |
| `read_at` | When the refresh began reading, in fractional epoch seconds; a pane keeps a card it just asked about checking until a record read after the press arrives. |
| `since_from` | What that start is: `last look`, or `12 hours` with no look recorded yet, or `48 hours` when the last look is older than that. |
| `counts`, `count_line` | Running jobs, items that need you, and idle factories. |
| `needs_you[]` | Each of the owner's calls: its `id`, `factory`, `kind` (`question` or `finished work`), `title`, `ask`, `why`, `options[]` (`key`, `label`, `suggested`), `suggested_by`, a `recommendation` that is not one of the options, `holds_up[]`, `since`, `pr`, `for`, the person it waits on, and `checking`, true while Starship re-checks a question the owner marked already settled. |
| `factories[]` | Each factory: `id`, `name`, `about`, `projects`, `steered_by`, `state`, `idle_since`, `crew`, `needs` (the ids of its items in `needs_you`), `jobs[]`, `next`, `rules`, `learned`, and `talk`. |
| `factories[].jobs[]` | Each job: `id`, `title`, `kind`, `state`, `step`, `started`, `doing` and where it came from, `last_sign_of_life` and where it came from, `quiet`, `until`, and `pr`. |
| `feed[]` | Each event: `at` (or a `date` when only the day is known), `actor`, `factory`, `word`, and `text`. |

Every state is a word: a job is `running`, `waiting on you`, `ready for you`, `stuck`, `waiting`, `stopped`, `no worker`, `no reading`, `with Starship`, `finished`, `next`, `later`, `on hold`, `on hold until <date>`, or `waits on other work`; a factory is `needs you`, `at work`, or `idle`.

## Where each part comes from

| Part | Source |
| --- | --- |
| Jobs, finished work, the work list | `bin/fm-fleet-snapshot.sh --json`, the canonical fleet reading, plus each captain hold the tasks-axi adapter reads that the snapshot's markdown backlog lacks |
| Each job's state word | `fm_fleet_status_bucket` in `bin/fm-fleet-status-lib.sh`, the same fold the status bar and bridge strip count with |
| What needs you | `fm_owner_calls` in `bin/fm-fleet-status-lib.sh`, over the backlog as the home's tasks-axi adapter reads it (`bin/fm-fleet-snapshot.sh --axi-backlog`) and those state words |
| A question's options and suggestion | `bin/fm-tap-desk.sh shapes`, the reading its tap card shows |
| Whether a question is being re-checked | A request in `bin/fm-captain-hold.sh reconcile list`, made, or followed by the pane's settled inbox note, since the call was last held |
| Which factory a job belongs to | Its work item's project, through the factory registry |
| How long a job has run | Its spawn time in the task's metadata |
| What a job is doing this minute | The worker's stated step, else the checks' own state, else `at work, no step reported yet` |
| The last sign of life | The newest of the worker's turn times (`state/<id>.busy-state`), its last finished turn, its last status line, its stated step, and the last time its pane text was seen to change |
| The feed | The `[at=]` times on `done` and `failed` status lines, when each of the owner's calls was held, completed work items, the who-steers log, and the owner's own notes and Starship's replies from the inbox |
| Rules and what it has learned | The factory registry |

The pane text check reads each running worker's pane through `bin/fm-peek.sh` once per record and remembers when it last changed in `state/factory/activity.json`.
Each full refresh also keeps the fleet reading it was built from in `state/factory/basis.json`, which a rebuild of the owner's calls starts from.

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
`bin/fm-factory-pane.sh open --item <id>` opens the pane with its highlight on that item of NEEDS YOU, which is how a click on the [bridge strip](bridge-strip.md#the-most-urgent-call)'s most urgent call opens it.
When a Factory pane is already showing in the same tab, its highlight moves to the item instead of a second pane opening, and the view scrolls to bring it into sight even after a hand scroll.
An item the record does not hold yet keeps its place for up to a minute while a fresh record is built.

## Verification

`tests/fm-factory.test.sh` builds a fixture home of sample factories and a fixture fleet reading, and checks the record and the plain screen word for word, the quiet job, the registry fallback, the writing keys pressed in the real live view, how soon a parked decision leaves the live view, the Herdr calls behind the factory tab and the plugin against a stand-in Herdr, a worker copy closing when its job ends, and a running pane reloading its changed code in place.
`tests/fm-tap-desk.test.sh` checks on one real backlog that the bridge strip, this pane, and the tap page show the same count of the owner's calls, and that the pane shows a question's recorded options.

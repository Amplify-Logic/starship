# Factory pane

A factory is one segment of the owner's work: a crew with its own work list, rules, memory and workers.
The Factory pane is the glance across all of them, as a Herdr pane beside your work, and `enter` opens one factory's own tab with its live workers beside it.
`bin/fm-factory.py` owns the record, the screen, the keys and the factory tabs, and `bin/fm-factory-pane.sh` owns installing, showing and removing the pane; read their headers before first use.
`herdr-plugins/starship-factory/` is the Herdr plugin that carries it.
The [factory registry](fork-configuration.md#factory-registry-datafactoriesmd) names a home's factories; without one, every registered project is its own factory.

## The overview

```text
 STARSHIP  │  2 busy  ·  2 decisions for you  ·  1 ready to merge  ·  1 idle   Sat 15:47
 9 queued  ·  1 starts on its own  ·  4 in line  ·  1 on hold
           ·  3 wait on you, 1 of them deferred to a date

 NEEDS YOU

 ▸ ● Harvest chart                                            Garden Journal · waiting 3 h
       The harvest chart can open on this week or this season.
       1  this week  · Starship suggests this
       2  this season
       3  both side by side
       t  Talk it through · by voice
       x  Already settled?

   ● Which payment provider for the shop                         Sample Shop · waiting 9 h
   ● Share a garden page as a picture is ready to merge  Garden Journal · ready 1 h 49 min

 RIGHT NOW

   Sample Shop   8 queued · 4 in line                                      Starship steers
     ● Search that forgives typos                                                   47 min
       ✓ planning ••••• ▸ building •••••   checking ·····   ready to merge
       running the search tests: 41 of 58 passed
       next  Gift wrap at checkout · then 3 more

   Recipe Box   idle since 06:46 · nothing queued                          Starship steers

 SINCE YOU LAST LOOKED, 03:46

   today    Sample Shop     closed     Stamp card at checkout was closed; no change or report on record.
   12:36    Garden Journal  asked you  Harvest chart needs your call.
   13:57    Garden Journal  PR ready   Share a garden page as a picture has its PR ready.

 ↑↓ move · 1/2/3 answer · x settled? · enter open · t talk (voice) · s who steers · q quit
```

- The count line is the overview the bridge strip and the status bar show, the same figures from the same reading in the same words ([status-bar.md](status-bar.md#fleet-words) owns them), plus the idle factories and the time.
  On a narrow pane it shortens to `decisions` and `to merge`, as the strip does; before the first reading it says `reading the crew`, and a reading that is no longer current carries its age, such as `(10m ago)`.
- The queue line under it counts every job nobody has started, and it stays in sight with the count line while the rest scrolls.
  After the total it says what will start each of them: `start on their own` is work that waits on other work or on a date still ahead and needs no word from you, `parked until <date>` is work parked until a date still ahead, which is looked at again on that date and never starts by itself, counted once: `parked until <date>` when every parked job shares one date, else `parked, soonest <date>`, with each job's own date only in the opened list, `in line` is queued with nothing set to start it, `on hold` is held with no date ahead, `wait on other work` is a decision for you that other open work still blocks, so it cannot be decided yet, and `wait on you` is every other decision held for you, with the ones deferred to a date counted apart.
  A count of zero is left out, and in a narrow pane the line wraps between counts.
  Work listed as in flight that has no worker is not queued; it reads `no worker` on its factory's page.
- NEEDS YOU comes first, across all factories, questions before finished work.
  It lists exactly the owner's calls behind the count line's `decisions for you` and `ready to merge`, the calls the tap page also shows: each decision held for the owner that waits on him now (not aged, deferred to a date, or waiting on other work), and each PR or ready branch waiting for the merge word whose task carries no open captain hold.
  `fm_owner_calls` in `bin/fm-fleet-status-lib.sh` owns that count, and the merges are the work the overview reading read as ready, so the list is the count.
  It also counts each PR a second mate has ready for the merge word, read from what the mate reports to this home: a PR is listed once its child's done outcome reaches this home, not at its registration, never when that mate has `yolo` on and merges it itself, and only while that child's newest outcome is done; it is dropped for good once the PR is merged or closed, unless a closed PR's child reports done on it again. Such a PR is listed in the factory of its repository and names its mate (`from <mate>`).
  A worker's question and an ask-user review finding go to Starship, which answers them or holds them for the owner, so they never appear here; their jobs read `needs a look`, as the status bar counts them.
  A question shows its why, the options and suggestion its tap card carries (`bin/fm-tap-desk.sh shapes`, including any recorded with `fm-tap-desk.sh mark`), and what it holds up.
  Those options come from the hold's recorded marks or its reason; its title gives them only when it is a plain two-way call (`X or Y`, perhaps ending in `?`), never when it holds a comma, a parenthesis, a spaced ` / ` or ` vs `, or more than two choices.
  A question with no options recorded shows only its plain words and `Talk it through`.
  A call with something to read shows an `r  Read the report` line; see [Reading the work](#reading-the-work).
  Only the highlighted one opens as a card, every word of its title and each option wrapped to the pane's width, and the highlight starts on the first; every other one stays one line with its factory and how long it has waited, its title shortened on a whole word with an ellipsis, so a long list still leaves room for the floor.
  A call you already answered, or finished work you asked to keep, says so in place of its wait (`answered 14:02, waiting for Starship`) and marks the option you picked, also after a restart, until the call is settled and leaves the list.
- RIGHT NOW lists each factory with who steers it and its own queue: how many of its jobs have not started, and how many of those are in line.
  A busy job shows its title, how long it has run, the four steps (planning, building, checking, ready to merge), and what it is doing this minute.
  A job with no sign of life for 15 minutes says `quiet for N min, no sign of life` instead, and its light stops moving.
  A job with something to read shows the same `r  Read the report` line.
  An idle factory is one faint row.
  A factory with [routine work](#routine-work) adds one `↻` line per routine kind under it, idle or not.
- SINCE YOU LAST LOOKED is one rolling list since the owner last looked at the pane: the time, who acted (a factory, Starship, or you), one word, and a sentence.
  A look is a key pressed in the pane, or the pane focused in Herdr for a few seconds; focus alone keeps a look going for at most 15 minutes after the focus began or the last key press, so a pane left focused all day does not hold the list back. Only Herdr saying the pane is not focused ends a focus; a failed or unreadable answer from Herdr changes nothing. A look ends 15 minutes after its last key press or counted focus, and while one is under way the list keeps starting where the look before it ended.
  Its heading names that time; with no look recorded yet it reads LAST 12 HOURS, and it never reaches back more than two days, reading LAST 48 HOURS when the last look is older.
  A factory's own tab records no look, since it shows one factory only.
  It holds outcomes (`finished`, `PR ready`, `landed`, `closed`, `failed`), the owner's own calls as they were held (`asked you`), and what the owner and Starship said; a worker's pause, a blocker, and a question a worker put to Starship never appear.
  A ship's `done` is an outcome only when it is the ready report, so a build handed into the checks is not listed as finished.
  A [routine](#routine-work) job's `finished`, `PR ready`, `landed` and `closed` are left out; its `failed` and `asked you` are listed as usual.
  A closed work item reads `landed` only with its merged change or local landing on record and `finished` only with its report; one closed with neither, such as dropped or superseded work or a call that was answered, reads `closed`.
  `landed_delivery` in `bin/fm-landed-lib.sh` owns that reading.

When the screen is taller than the pane, the count line stays on top and the keys at the bottom while everything between them scrolls.
The highlight keeps itself in sight as it moves, `pgup`, `pgdn` and the mouse wheel scroll the view, and the row under the count line and the row above the keys say how many lines are out of sight above or below.
The pane asks the terminal for mouse reports to see the wheel, so Herdr's own text selection does not work inside it.

The pane asks for mouse button reports too, so a click on a `Read the report` line reads that item; a click anywhere else does nothing.

Colour only repeats what the words already say: cyan is where you are, amber is work under way, green is done or ready to merge, red is a decision for you.

## Reading the work

A call or job has something to read when its task has a report or a page of its own in the home (`data/<id>/report.md` or `data/<id>/page.html`), or when its hold reason names a report under the home's `data/`; only then does it show `r  Read the report`.
`r` reads the highlighted call, or on a highlighted factory the first job the screen shows with that line, and a click reads the line it lands on.
The pane hands those to `bin/fm-read.sh`, which opens the task's own `page.html` when there is one and otherwise renders the reports into one calm reading page under `.lavish/`, then opens it in Lavish, or in the browser when Lavish is not installed.
The reader runs in the background, so the pane never waits on it, and when it cannot open the page the pane says why.
A scout writes that `page.html` beside its report, in whatever form best presents its work.

## Routine work

Some work repeats all day, such as a to-do pass every hour, and each pass is a job of its own that ends with a report.
A factory's `routine:` line in the [factory registry](fork-configuration.md#factory-registry-datafactoriesmd) marks such work as routine, so its passes do not crowd the overview:

```markdown
## Garden Journal
projects: garden-journal
routine: Reminder pass, Weekly harvest summary
```

- `routine: yes` marks every job of the factory as routine.
- Otherwise the line lists kinds of jobs, separated by commas: a job is of a kind when its title starts with that kind as a whole word, ignoring case (`Reminder pass 07:50`); a job with no title is matched by its id.
- Without the line, or with `routine: no`, nothing is routine and the pane shows every job as it always has.

Under its factory in RIGHT NOW, each routine kind that ran today, or has a pass under way, is one line:

```text
     ↻ Reminder pass  4 runs today · last started 07:50                             busy
```

- `runs today` counts each pass that started, finished, failed or was closed today, by the machine's local day.
- `last` names the newest of those, as `started`, `finished` or `failed`, with its time.
- The right side says `busy` while a pass runs, or `waiting` while one is paused on a wait it declared.
- A pass that runs as expected, or waits, folds into that line instead of drawing its own card.
- A pass that needs a look or failed, is quiet with no sign of life, stopped, without a worker, or a decision for you or ready to merge keeps its own row as usual.
- SINCE YOU LAST LOOKED leaves out a routine pass that finished, landed, had its PR ready or was closed, while a failed one and a call it put to you are listed as usual.
- A pass folded into that line is left out of the factory's busy crew and of whether the factory is at work, so a factory whose only busy work is a folded pass counts as idle, since its last pass or outcome; the count line still counts it busy, since it shows the overview's figures, as the strip and the status bar do.
- Such a factory reads idle on the overview too, sorted with the idle factories, while any other card it would show, such as a pass that needs a look, still shows under its head with its routine line; only with nothing busy at all does it drop those cards, keeping its idle row and its routine lines.
- A factory's own tab still lists every routine pass with the rest of its work.

## A factory's own tab

`enter` on a factory, or on something that needs you, opens that factory's tab, or focuses it when it is already open.
Its page is on the left: the count line and the queue line, so other factories' questions stay in view, then this factory's NEEDS YOU, its work in order, the rules the crew follows with their size against the cap a brief takes them under, what it has learned lately, its own feed, and the talk history.
Its work opens with the factory's own queue line; everything moving or waiting on your answer is listed, then the first eight in line, and the rest of its queue folds into one count per queue word: a held decision that other open work blocks waits on other work, one that has waited undated past the aging threshold is an older call, and any other is one more that waits on you.
That folded count line can be highlighted like any other row: `enter` on it lists every job it stands for under it, each with its title and queue word, grouped by count, and `esc` hides the list again; while it is open, the keys line names `esc` only for hiding it.
Its live workers are stacked on the right, at most four, each a read-only copy of that worker's own pane that refreshes every two seconds.
Only a worker at work gets a copy: one that is `busy`, `with Starship`, `needs a look`, `failed`, or `decision for you`.
A parked, held, queued, or finished job gets none, and a copy closes its own pane only once its job really ends: when the job is gone from the record or `finished`, landed, `ready to merge`, `stopped`, `no worker`, back in line (`next`, `later`), parked (`waiting`), or held (`on hold`, `on hold until <date>`, `waits on other work`); it stays open through `no reading`.
Typing never reaches a worker from there; talking goes through the talk box.
`esc` goes back to the tab the factory was opened from, and `q` closes the tab with its worker copies.
Outside Herdr, `enter` opens the same page in place instead.

## Keys

| Key | What it does |
| --- | --- |
| `↑` `↓` | Move the highlight; it starts on the first thing that needs you, and past the first or last row the view scrolls instead. |
| `pgup` `pgdn`, mouse wheel | Scroll the view, without moving the highlight or closing a confirmation or the talk box. |
| `enter` | Open the highlighted factory's tab, or on a factory's folded count line, list every job it stands for. |
| an option key | Answer the highlighted question with that option, after `enter` confirms it. |
| `x` | Tell Starship the highlighted question looks already settled, so it re-checks it. |
| `k` | Keep the highlighted finished work and ask Starship to land it, after `enter` confirms it. |
| `c` | Ask for changes to the highlighted finished work, in the talk box, typed. |
| `r` | Read the highlighted call's report, or on a factory the first shown job's; a click on a `Read the report` line reads that one. |
| `t` | Talk to the highlighted factory's crew, or talk the highlighted question through: by voice where the desk voice is set up, typed otherwise. |
| `s` | Switch who steers the highlighted factory, both ways. |
| `esc` | Back, hide an opened folded count line, or cancel a confirmation or the talk box. |
| `q` | Quit. |

### Answering, and the talk box

A key that writes something opens one box that floats over the pane, just under the row it is about, while the rest of the pane dims behind it.
The box has an outline and no fill, so it reads as a field laid over the pane; its top edge names what it is about and, in its corner, that nothing is sent yet or how it takes your words.
The keys line at the bottom turns into the same instruction in the highlight colour: which key sends, which cancels.

```text
 ▸ ● Harvest chart                                            Garden Journal · waiting 3 h
       1  this week  · Starship suggests this
     ▸ 2  this season
       3  both side by side
       t  Talk it through · by voice
       x  Already settled?
   ╭─ Your answer · Harvest chart ───────────────────────────────── not sent yet ─╮
   │                                                                              │
   │  2 this season                                                               │
   │                                                                              │
   │  enter sends it to Starship · esc cancels                                    │
   ╰──────────────────────────────────────────────────────────────────────────────╯
 ...
 ENTER  send answer 2 to Starship      ESC  cancel
```

While a confirmation is open only `enter` and `esc` do anything; any other key is answered with which key to press, so an answer is never dropped by a stray key.
What happened is then said on the line under the queue line: `✓ SENT to Starship: ...` in green, `Not sent: answer 2 was cancelled.`, or `✗ NOT SENT: ...` in red with the reason, which stays until the next key or for a minute.

`t` opens the same box as a talk box.
Where this machine has a microphone recorder and the home has the desk voice's speech key (see the [desk floater](desk-floater.md#enablement)), it listens at once: its corner reads `● listening`, your words appear in the box while you speak, and the note is sent when you stop speaking for two seconds or press `enter`.
It waits a minute for your first words; when none counted as speech by then but it picked up some sound, it stops listening and keeps that recording, its corner reads `recorded`, and `enter` writes it down and sends it.
The words shown while you speak come from the newest eight seconds of sound, written down at most every two seconds by the same command that writes the note down, so they arrive in small bursts and an ellipsis leads them once the note is longer than that.
What is sent is one writing down of the whole note when you finish, so a note costs the speech service about its own length plus those short pieces, and a short piece that failed is tried again only after a growing wait.
From your first words on the microphone's sound goes to that speech service, as the desk voice's does.
The first key you type drops the recording and turns the box into a typed field; `esc` cancels and sends nothing, and a dropped recording is not written down afterwards and leaves no file.
A recording with no words in it is not sent, a microphone that gives no sound at all is named as such, and one whose words could not be written down is saved with the desk voice's [unsent recordings](desk-floater.md#recordings-are-never-lost); in each case the box stays open as a typed field.
Without a recorder or the key, `t` opens the typed field at once and its corner reads `typed · no desk voice`; the card and the keys line say `typed` or `by voice` before you press it.
A typed field shows every character with the cursor at its end, on up to three lines.
The recorder is ffmpeg reading the Mac's default input; `FM_FACTORY_MIC` names another one, or turns voice off when empty (`bin/fm-factory.py`'s header owns the recorder's contract).

Every writing key acts on the highlighted row only; the highlight stays on the same question or factory when the record refreshes, a pending confirmation closes and says nothing was sent when what it is about leaves the record, and an open talk box keeps its text but says it was settled elsewhere, sends nothing, and closes with `esc`.
An answer, a keep, a change request and anything said in the talk box become a captain inbox note (`bin/fm-inbox.sh note`), the existing path for the owner to tell Starship something, saved once under a request id that names the factory and the item; an answer's id also names the question's key and when it was asked, and a keep's id the time the work became ready, so a repeated press is one note but a new or re-asked question or returned work is a new one.
Starship then acts on it under its own rules: it records the answer on the held decision, merges only under its merge rules, and passes words on to the crew.
A note that was spoken says so, since its words may have been heard wrong.
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
`--plain --factory <id>` prints one factory's page, `--plain --item <id>` puts the highlight on that item of NEEDS YOU so its card is the open one, and `--plain --height <rows>` prints only what a pane that tall shows when it opens.
Both use the cached record while it is younger than 20 seconds, or older with no status, record or backlog file written since its last full refresh, and build a fresh one otherwise.
Once the record is five minutes old a full refresh comes due even with no such file written, unless the machine is busy: a worker's pane activity, a job gone quiet and a change merged elsewhere are recorded in no file, so without that safety refresh the pane would go stale.
A full refresh reads the fleet, the backlog and its held questions' options, the inbox and the workers' panes side by side, and keeps each held question's options from the last full refresh while the owner's calls signal (below) has not moved since they were read, for at most five minutes (`FM_FACTORY_MAX_AGE`); a question held again since is always read afresh.
The owner's calls do not wait for that: when their change signal (`bin/fm-owner-calls-signal-lib.sh`) has moved past the one the record was built under, the record is rebuilt with a fresh read of the backlog and the inbox on the workers as the last full refresh read them, which takes a second or two rather than a full refresh.
The live pane checks that signal once a second, so an answered, parked, released, closed or added decision, or a note to Starship, changes NEEDS YOU within about two seconds.
All panes and live copies of one home share one rebuild at a time, full or of the owner's calls only.
Panes that open together on a home with no record build one first record between them: each waits its turn and builds only if the record is still missing.
After a full refresh the next full refresh waits at least as long as that one took, so a refresh that overran leaves the machine that much rest; on a busy machine, a one-minute load average of twice the cores or more, that wait is at least a minute.
A rebuild of the owner's calls waits for neither, only for a rebuild already under way, so the calls stay within about two seconds however long the last full refresh took.
A pane that asks for a rebuild meanwhile starts none and queues none; it asks again at its next check.
It also reads the overview once a second, off the drawing thread, so its count line follows the strip and the status bar, and NEEDS YOU is rebuilt the same way when the overview's ready work changes.
The record is always built by the code on disk, so a running pane or worker copy checks before every frame whether `bin/fm-factory.py` changed, and re-runs itself in place, in the same pane, once the new file is non-empty and compiles.
The live pane holds that reload while the talk box, a confirmation or a notice is showing, so a draft or a sent or not-sent line is never lost, and reloads on the first frame after.

The record's schema is `fm-factory.v1`:

| Field | What it holds |
| --- | --- |
| `as_of`, `since` | When the record was built and the start of SINCE YOU LAST LOOKED, as UTC times and epochs. |
| `snapshot_epoch`, `calls_signal` | When the workers in it were read, and the owner's calls signal its calls were read under. |
| `read_at` | When the refresh began reading, in fractional epoch seconds; a pane keeps a card it just asked about checking until a record read after the press arrives. |
| `since_from` | What that start is: `last look`, or `12 hours` with no look recorded yet, or `48 hours` when the last look is older than that. |
| `counts`, `count_line` | The overview reading's `busy`, `decisions` and `ready_to_merge` (each null before the first reading), whether that reading is `current`, `past` or `unknown` and its `age`, and the `idle` factories. |
| `ready_list` | The overview reading's ready work that NEEDS YOU was built on. |
| `queue`, `queue_line` | Every job nobody has started: `total`, `starts_on_its_own`, `parked` and `parked_until[]` (one `until` date and `count` per date, soonest first), `in_line`, `on_hold`, `waits_on_other_work`, `waits_on_you` (which includes the older calls and the deferred) and `deferred`, and the same as one line of words. |
| `needs_you[]` | Each of the owner's calls: its `id`, `factory`, `kind` (`question` or `finished work`), `title`, `ask`, `why`, `options[]` (`key`, `label`, `suggested`), `suggested_by`, a `recommendation` that is not one of the options, `holds_up[]`, `since`, `pr`, `for`, the person it waits on, `mate`, the second mate whose PR it is (absent for this home's own work), `answered`, when the owner answered it since it was asked and with which option (`at` and the option `key`, null for a keep), or null, `checking`, true while Starship re-checks a question the owner marked already settled, and `read`, the sources `bin/fm-read.sh` is given (empty when there is nothing to read). |
| `factories[]` | Each factory: `id`, `name`, `about`, `projects`, `steered_by`, `state`, `idle_since`, `crew`, `needs` (the ids of its items in `needs_you`), `jobs[]`, `next`, `queue` (its own counts, as above), `rules`, `rules_size` (the characters its rules take in a brief, measured against the top-level `rules_cap`, as [the registry](fork-configuration.md#factory-registry-datafactoriesmd) describes), `learned`, and `talk`, plus `routine` (the [routine](#routine-work) kinds its registry entry names, or `Routine work` for `routine: yes`) and `routine_runs[]`, one per routine kind that ran today or has a pass under way: `kind`, `today`, `last` and `last_word`, `running`, and `folded` (the ids of the jobs the line stands for on the overview). |
| `factories[].jobs[]` | Each job: `id`, `title`, `kind`, `state`, `step`, `started`, `doing` and where it came from, `last_sign_of_life` and where it came from, `quiet`, `until`, `pr`, `queue`, `parked_until` (the date a `parked` job is parked until, else null), `routine` (its routine kind, or null), and `read`. |
| `feed[]` | Each event: `at` (or a `date` when only the day is known), `actor`, `factory`, `word`, and `text`. |

Every state is a word: a job is `busy`, `decision for you`, `ready to merge`, `needs a look`, `failed`, `waiting`, `stopped`, `no worker`, `no reading`, `with Starship`, `finished`, `next`, `later`, `on hold`, `on hold until <date>`, or `waits on other work`; a factory is `needs you`, `at work`, or `idle`.
A job reads `ready to merge` only once the shared overview reading lists it as ready, so it is counted in the count line's `ready to merge`; until then it stays `busy` at `checking`.
The words the overview also uses mean what [status-bar.md](status-bar.md#fleet-words) says; `with Starship` is finished work that is Starship's turn, such as a scout report it reads first, and `no reading` a job whose state could not be read.
A job nobody has started also says where it stands in the queue: its `queue` is `starts on its own`, `parked`, `in line`, `on hold`, `waits on other work`, `waits on you`, `older call`, or `deferred`, and null for a job with a worker.

## Where each part comes from

| Part | Source |
| --- | --- |
| Jobs, finished work, the work list | `bin/fm-fleet-snapshot.sh --light`, the canonical fleet reading without the parts the pane does not show, plus each captain hold the tasks-axi adapter reads that the snapshot's markdown backlog lacks |
| What is held, and what still waits on other work | The backlog as the home's tasks-axi adapter reads it, for every open work item it has: a markdown backlog file cannot tell a blocker that was finished and archived from one still open |
| The queue | Every open work item with no worker, counted in that same pass by what will start it |
| Whether closed work was finished or only closed | `landed_delivery` in `bin/fm-landed-lib.sh`, the reading Recently Landed is selected with |
| Whether you already answered a call | The owner's own answer and keep notes in the inbox (`bin/fm-inbox.sh receipts`), matched by the request id each key writes |
| The count line | `fm_fleet_status_counts` `overview` in `bin/fm-fleet-status-lib.sh`, the reading the bridge strip and the status bar show, followed once a second by the live pane |
| Each job's state word | `fm_fleet_status_bucket` in `bin/fm-fleet-status-lib.sh`, the same fold the status bar and bridge strip count with |
| What needs you | `fm_owner_calls` in `bin/fm-fleet-status-lib.sh`, over the backlog as the home's tasks-axi adapter reads it (`bin/fm-fleet-snapshot.sh --axi-backlog`) and the overview reading's ready work, or this pane's own state words before the first overview reading |
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
When that reading is missing or empty, the pane asks for a full refresh instead of a rebuild of the owner's calls, under the same rest as any other, so it starts nothing while that rest lasts; the pane only checks that the file is there and not empty, and a rebuild that finds it unreadable refreshes whole under the same rest.

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

`tests/fm-factory.test.sh` builds a fixture home of sample factories and a fixture fleet reading, and checks the record and the plain screen word for word, the queue's counts, parked work counted by its date, a folded count line opened on every job it stands for, closed work against finished work, the quiet job, routine passes folded into one line and kept out of the feed except a failed one, and every pass shown as before without a routine mark, the registry fallback, the writing keys pressed in the real live view, the Read line and what `r` and a click hand the reader, the talk box listening to a stand-in microphone that writes real samples, what a spoken note hands the speech service and that a cancelled one hands it nothing more, how soon a parked decision leaves the live view, the Herdr calls behind the factory tab and the plugin against a stand-in Herdr, a worker copy closing when its job ends, and a running pane reloading its changed code in place.
`tests/fm-tap-desk.test.sh` checks on one real backlog that the bridge strip, this pane, and the tap page show the same count of the owner's calls, and that the pane shows a question's recorded options.

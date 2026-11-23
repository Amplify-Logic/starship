# Factory pane

A factory is one segment of the owner's work: a crew with its own work list, rules, memory and workers.
The Factory pane is the glance across all of them, as a Herdr pane beside your work, and `enter` opens one factory's own tab with its live workers beside it.
`bin/fm-factory.py` owns the record, the screen, the keys and the factory tabs, and `bin/fm-factory-pane.sh` owns installing, showing and removing the pane; read their headers before first use.
`herdr-plugins/starship-factory/` is the Herdr plugin that carries it.
The [factory registry](fork-configuration.md#factory-registry-datafactoriesmd) names a home's factories; without one, every registered project is its own factory.

## The overview

```text
 STARSHIP  │  3 things need you. 1 older question is still open, and 1 more is    Sat 15:47
              put off to a date.
              2 jobs are running. 1 hit a problem, and Starship is on it.
              1 change went live since you looked at 03:46.

 NEEDS YOU  most pressing first

 ▸ ● Harvest chart                                  first up · Garden Journal · waiting 9 h
       The harvest chart can open on this week or this season.
       1  this week  · Starship suggests this
       2  this season
       3  both side by side
       t  Talk it through · by voice
       x  Already settled?

   ● Which payment provider for the shop                          Sample Shop · waiting 3 h
   ● Share a garden page as a picture is ready to merge   Garden Journal · ready 1 h 49 min

     · 1 older question is still open. It left Needs you after waiting with no date set,
       waiting since 1 Oct.

   ↺ Nothing comes back this week. 1 is put off to a later date.
     The next is on 1 Dec.

 YOUR FACTORIES  new since you looked at 03:46

   Sample Shop                                                                  1 needs you
     now   ● Search that forgives typos                                              47 min
             ✓ planning ••••• ▸ building •••••   checking ·····   ready to merge
             running the search tests: 41 of 58 passed
           ● Gift cards at checkout
             stopped: its checks raised a question, Starship is on it
     new   14:12  Report ready: Why the cart is slow
                  r  Read the report
           11:41  Went live: Faster cart
                  o  See what changed
           today  Settled: Free shipping over fifty? You answered: Yes, from fifty.
     next  Gift wrap at checkout, then 3 more lined up

   Garden Journal                                                                2 need you
     now   Nothing is running.
     new   13:57  PR ready: Share a garden page as a picture

 QUIET FOR NOW

   Recipe Box   Idle since 06:46, nothing lined up.

 ↑↓ move · 1/2/3 answer · x settled? · enter open · t talk (voice) · s who steers · q quit
```

- The top says what stands in three plain sentences beside the time, and it stays in sight while the rest scrolls.
  The first counts the calls in NEEDS YOU, then the older questions and the calls put off to a date, so every call that waits on you is counted once; the second counts the jobs running and any that stopped or hit a problem, and says Starship is on them; the third counts what went live and the reports that came in since you last looked.
  Its figures come from the overview the bridge strip and the status bar show ([status-bar.md](status-bar.md#fleet-words) owns them); before the first reading the second sentence says `reading the crew`, and a reading that is no longer current carries its age, such as `(10m ago)`.
  On a narrow pane the wordmark shortens, and below 72 columns it takes a row of its own above the sentences.
- A factory's page opens its work with that factory's queue line, which counts every job nobody has started.
  After the total it says what will start each of them: `start on their own` is work that waits on other work or on a date still ahead and needs no word from you, `parked until <date>` is work parked until a date still ahead, which is looked at again on that date and never starts by itself, counted once: `parked until <date>` when every parked job shares one date, else `parked, soonest <date>`, with each job's own date only in the opened list, `in line` is queued with nothing set to start it, `on hold` is held with no date ahead, `wait on other work` is a decision for you that other open work still blocks, so it cannot be decided yet, and `wait on you` is every other decision held for you, with the ones deferred to a date counted apart.
  A count of zero is left out, and in a narrow pane the line wraps between counts.
  Work listed as in flight that has no worker is not queued; it reads `no worker` on its factory's page.
- On a first run, with nothing waiting on you and no work in the backlog, open or finished, YOUR FACTORIES says to ask Starship for a first report, and with no factory at all the keys line offers only `q quit`, the one key that does something there.
- NEEDS YOU comes first, across all factories, most pressing first: the decisions that have waited longest, then finished work, then a second mate's ready PRs.
  That is the one order `fm_owner_calls` gives, so the first card, marked `first up`, is always the call the bridge strip names as most urgent.
  It lists exactly the owner's calls behind the strip's `decisions for you` and `ready to merge`, the calls the tap page also shows: each decision held for the owner that waits on him now (not aged, deferred to a date, or waiting on other work), and each PR or ready branch waiting for the merge word whose task carries no open captain hold.
  `fm_owner_calls` in `bin/fm-fleet-status-lib.sh` owns that count, and the merges are the work the overview reading read as ready, so the list is the count.
  It also counts each PR a second mate has ready for the merge word, read from what the mate reports to this home: a PR is listed once its child's done outcome reaches this home, not at its registration, never when that mate has `yolo` on and merges it itself, and only while that child's newest outcome is done; it is dropped for good once the PR is merged or closed, unless a closed PR's child reports done on it again. Such a PR is listed in the factory of its repository and names its mate (`from <mate>`).
  A worker's question and an ask-user review finding go to Starship, which answers them or holds them for the owner, so they never appear here; their jobs are in the `needs a look` state the status bar counts, which a job's row spells as stopped with Starship on it (below).
  A question shows its why, the options and suggestion its tap card carries (`bin/fm-tap-desk.sh shapes`, including any recorded with `fm-tap-desk.sh mark`), and what it holds up.
  The open card shows the whole why and the whole suggestion, wrapped to the pane's width and never cut short.
  In a call's title, why and suggestion, a file path is left out, and so is a work item's id or a revision mark such as `(r2)` alone in brackets; any other bracketed words stay, and `Read the report` still opens the file. Options, the feed and the talk keep their words as written.
  Those options come only from the hold's recorded marks or an `Options:` list in its reason, never from a title or a sentence cut into pieces.
  A question with no options recorded shows only its plain words and `Talk it through`.
  Finished work with a pull request shows that PR's In short, See it, You need to and Risk lines from its description above `k  keep it`, the short section every pipeline PR opens with ([PR text](fork-configuration.md#pr-text)), so the merge word can be given here in a minute; a PR opened without those sections, or one that cannot be read, shows none, and each PR is read once every half hour.
  Merges are answered here and on the web mirror rather than on the phone tap page, unless the home turned [phone merging](fork-configuration.md#phone-tap-desk-configtap-desk) back on.
  A call with something to read shows an `r  Read the report` line; see [Reading the work](#reading-the-work).
  Only the highlighted one opens as a card, every word of its title and each option wrapped to the pane's width, and the highlight starts on the first; every other one stays one line with its factory and how long it has waited, its title shortened on a whole word with an ellipsis, so a long list still leaves room for the floor.
  A call you already answered, or finished work you asked to keep, says so in place of its wait (`answered 14:02, waiting for Starship`) and marks the option you picked, also after a restart, until the call is settled and leaves the list.
- Under the calls, NEEDS YOU keeps two shelves for the calls that wait on you but are not listed.
  The older questions shelf is one line counting the decisions that left the list after waiting 14 days with no date set, and since when the oldest has waited; `enter` on it lists them, each with its factory and since when, and `esc` hides the list.
  On a listed question `b` asks Starship to bring it back into NEEDS YOU and `n` says it is no longer needed; each opens a confirmation first, as an answer does, and goes to Starship as a note, after which the question says what you asked until Starship acts on it.
  The coming back shelf, marked `↺`, lists the calls put off to a date that come back within a week, each with its date from the record, and says how many more are put off and the date the next of them comes back.
  A factory's page keeps the same two shelves for that factory's own calls.
- YOUR FACTORIES tells each factory as Now, New and Next, in one block, as `View.told` in `bin/fm-factory.py` composes it for both screens.
  The head names the factory and, on the right, how many things there need you (`2 need you`); a factory the owner steers also says `you steer`, and one Starship steers says nothing, since the switch is the `s` key.
  Now is what runs or stopped there: a busy job shows its title, how long it has run, the four steps (planning, building, checking, ready to merge), and what it is doing this minute; one that has named no step yet reads `just started` for its first five minutes and `at work` after that.
  A job with no sign of life for 15 minutes says `quiet for N min, no sign of life` instead, and its light stops moving.
  A job that is not busy but waits, stopped, failed or is a call of yours that has started is one row with its state in words, and with nothing busy Now opens with `Nothing is running.`
  A job with something to read shows the same `r  Read the report` line.
  A factory with [routine work](#routine-work) adds one `↻` line per routine kind under Now.
  New is what came out of the factory since the owner last looked: `Went live:`, `Report ready:`, `Settled:`, `PR ready:`, `Finished:`, `Failed:` or `Closed:` in front of the work's title, newest first, each with its time, at most four, then how many more there are, with `, on its own page` only when that page's Lately, which lists eight, holds them all.
  A settled call says what the owner answered, from its resolution record's `Captain decision:` words, a report shows its `r  Read the report` line, a change that went live through a PR shows an `o  See what changed` line, and work that went live is told once, so its earlier finished or PR ready is left out.
  Next is the first job in line and how many more are lined up after it, or `, once you answer` when the next job waits on a call of yours.
  A factory with nothing that needs you, nothing in Now and nothing new is quiet: it folds into one line under QUIET FOR NOW, saying since when it is idle, or that nothing is running, how many jobs are lined up, and how many of its calls are put off with the date the next comes back.
  The heading says since when New tells what moved, in the third sentence's words: since the owner last looked, or the last 12 or 48 hours.
- New starts where the owner last looked at the pane.
  A look is a key pressed in the pane, or the pane focused in Herdr for a few seconds; focus alone keeps a look going for at most 15 minutes after the focus began or the last key press, so a pane left focused all day does not hold New back. Only Herdr saying the pane is not focused ends a focus; a failed or unreadable answer from Herdr changes nothing. A look ends 15 minutes after its last key press or counted focus, and while one is under way New keeps starting where the look before it ended.
  With no look recorded yet it covers the last 12 hours, and it never reaches back more than two days.
  A factory's own tab records no look, since it shows one factory only, and lists the same outcomes under Lately.
- A factory's feed is one rolling list since that start: the time, one word, and a sentence.
  It holds outcomes (`finished`, `report ready`, `PR ready`, `went live`, `closed`, `settled`, `failed`), the owner's own calls as they were held (`asked you`), and what the owner and Starship said; a worker's pause, a blocker, and a question a worker put to Starship never appear, and the overview's New holds the outcomes alone.
  A `report ready`, `went live` or `settled` row leads with that word and then names the work by its title alone, such as `went live  Faster cart`, and a settled call adds what the owner answered.
  A change that went live through a pull request takes its time from the PR's merge, read once with `gh` and kept in `state/factory/merged-at.json`, and a report from when its file was written; work closed with only its day on record shows `today` or the day.
  A ship's `done` is an outcome only when it is the ready report, so a build handed into the checks is not listed as finished; a scout's `done` reads `report ready`.
  A [routine](#routine-work) job's `finished`, `report ready`, `PR ready`, `went live`, `closed` and `settled` are left out; its `failed` and `asked you` are listed as usual.
  A closed work item reads `went live` only with its merged change or local landing on record and `report ready` only with its report; one closed with neither reads `settled` when it was a call of the owner's, and `closed` otherwise, such as dropped or superseded work.
  `landed_delivery` in `bin/fm-landed-lib.sh` owns that reading.

When the screen is taller than the pane, the sentences stay on top and the keys at the bottom while everything between them scrolls.
The highlight keeps itself in sight as it moves, `pgup`, `pgdn` and the mouse wheel scroll the view, and the row under the sentences and the row above the keys say how many lines are out of sight above or below.
The pane asks the terminal for mouse reports to see the wheel, so Herdr's own text selection does not work inside it.

The pane asks for mouse button reports too, so a click on a `Read the report` line reads that item and a click on a `See what changed` line opens that PR in the browser; a click anywhere else does nothing.

Colour only repeats what the words already say: cyan is where you are, amber is work under way, green is done or ready to merge, red is a decision for you.
The pane and the worker copies in a factory's tab select light or dark colours, including the highlighted rows: the remembered [workspace theme](fork-configuration.md#workspace-theme-configworkspace-theme) when one is set, repainting in place when it is switched, else the terminal background at startup; plain-text output is unchanged.
[Terminal theme](fork-configuration.md#terminal-theme-fm_terminal_theme) owns detection, fallback and the override.

## Reading the work

A call or job has something to read when its task has a report or a page of its own in the home (`data/<id>/report.md` or `data/<id>/page.html`), or when its hold reason names a report under the home's `data/`; only then does it show `r  Read the report`.
`r` reads the highlighted call, or on a highlighted factory the first job or report in New the screen shows with that line, and a click reads the line it lands on.
A closed report in New has something to read the same way, by its work item's id or the report it names.
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

Under its factory's Now in YOUR FACTORIES, each routine kind that ran today, or has a pass under way, is one line:

```text
     ↻ Reminder pass  4 runs today · last started 07:50                             busy
```

- `runs today` counts each pass that started, finished, failed or was closed today, by the machine's local day.
- `last` names the newest of those, as `started`, `finished` or `failed`, with its time.
- The right side says `busy` while a pass runs, or `waiting` while one is paused on a wait it declared.
- A pass that runs as expected, or waits, folds into that line instead of drawing its own card.
- A pass that needs a look or failed, is quiet with no sign of life, stopped, without a worker, or a decision for you or ready to merge keeps its own row as usual.
- New and the feed leave out a routine pass that finished, had its report or its PR ready, went live, or was closed or settled, while a failed one and a call it put to you are listed as usual.
- A pass folded into that line is left out of the factory's busy crew and of whether the factory is at work, so a factory whose only busy work is a folded pass counts as idle, since its last pass or outcome; the top's running count still counts it, since it shows the overview's figures, as the strip and the status bar do.
- Such a factory reads idle on the overview too, sorted with the idle factories, while any other card it would show, such as a pass that needs a look, still shows in its Now with its routine line, and a factory with a routine line is never folded as quiet.
- A factory's own tab tells its routine work the same way, under HAPPENING NOW.

## A factory's own tab

`enter` on a factory, or on something that needs you, opens that factory's tab, or focuses it when it is already open.
Its page is on the left, under the three sentences so other factories' questions stay in view, and reads top to bottom:
- The factory's name with who steers it on the right, what it is for, and one sentence of state: how many things there need you, how many jobs run there and whether one stopped or hit a problem, and, when something moved, how many changes went live and reports are ready, in the third sentence's words (`View.page_state`).
- NEEDS YOU, this factory's cards, with its older questions shelf under them.
- HAPPENING NOW, the factory's Now as the overview tells it, with `Nothing is running.` when nothing runs, its routine lines, and any other job under way that the queue does not hold.
- LATELY, its New: the same outcomes in the same words, the eight newest, or `Nothing new.`
- UP NEXT, how many jobs are lined up in its heading, then the first three in line; the rest folds into one count line, `N more lined up` first, then one count per queue word for the rest of its queue: a held decision that other open work blocks waits on other work, and any other is one more that waits on you.
- COMING BACK, every call of this factory put off to a date, soonest first, each with its day and date, with how many in its heading; it is left out when there are none.
- HOW THIS CREW WORKS, the rules the crew follows and what it has learned lately; the rules' size against the cap a brief takes them under is said only from nine tenths of that cap on, and over it.
- CONVERSATION, what the owner and Starship said there.

There is no line of queue counters, and a call with a card under this page's NEEDS YOU, or on its older questions shelf, is shown there only, never listed again under HAPPENING NOW or UP NEXT nor counted in a fold.
`View.page_parts` owns that composition, and the screen's `page` carries it, so the web page tells the same facts.
That folded count line can be highlighted like any other row: `enter` on it lists every job it stands for under it, each with its title and queue word, grouped by count, and `esc` hides the list again; while it is open, the keys line names `esc` only for hiding it.
`r` reads the first thing with something to read under HAPPENING NOW, UP NEXT or LATELY, and `o` opens the first change in LATELY that went live.
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
| `enter` | Open the highlighted factory's tab, or on a factory's folded count line or the older questions shelf, list every job it stands for. |
| an option key | Answer the highlighted question with that option, after `enter` confirms it. |
| `x` | Tell Starship the highlighted question looks already settled, so it re-checks it. |
| `k` | Keep the highlighted finished work and ask Starship to land it, after `enter` confirms it. |
| `c` | Ask for changes to the highlighted finished work, in the talk box, typed. |
| `r` | Read the highlighted call's report, or on a factory the first shown job's; a click on a `Read the report` line reads that one. |
| `o` | On a factory on the overview, open the PR of the first change in its New that went live, in the browser (`FM_FACTORY_OPEN` stands in for the opener); a click on a `See what changed` line opens that one. |
| `t` | Talk to the highlighted factory's crew, or talk the highlighted question through: by voice where the desk voice is set up, typed otherwise. |
| `s` | Switch who steers the highlighted factory, both ways. |
| `b` `n` | On a listed older question, ask Starship to bring it back into NEEDS YOU, or say it is no longer needed, after `enter` confirms it. |
| `esc` | Back, hide an opened folded count line or older questions shelf, or cancel a confirmation or the talk box. |
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
What happened is then said on the line under the sentences: `✓ SENT to Starship: ...` in green, `Not sent: answer 2 was cancelled.`, or `✗ NOT SENT: ...` in red with the reason, which stays until the next key or for a minute.

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
Both use the cached record while it is younger than a minute, or older with no status, record or backlog file written since its last full refresh, and build a fresh one otherwise.
A minute, because a busy fleet writes those files every few seconds and every full refresh reads every worker's state, which costs seconds of processor time; the owner's calls never wait on it (below).
Once the record is five minutes old a full refresh comes due even with no such file written, unless the machine is busy: a worker's pane activity, a job gone quiet and a change merged elsewhere are recorded in no file, so without that safety refresh the pane would go stale.
A full refresh reads the fleet, the backlog and its held questions' options, the inbox and the workers' panes side by side, and keeps each held question's options from the last full refresh while the owner's calls signal (below) has not moved since they were read, for at most five minutes (`FM_FACTORY_MAX_AGE`); a question held again since is always read afresh.
The owner's calls do not wait for that: when their change signal (`bin/fm-owner-calls-signal-lib.sh`) has moved past the one the record was built under, the record is rebuilt with a fresh read of the backlog and the inbox on the workers as the last full refresh read them, which takes a second or two rather than a full refresh.
The live pane checks that signal once a second, so an answered, parked, released, closed or added decision, or a note to Starship, changes NEEDS YOU within about two seconds.
All panes and live copies of one home share one rebuild at a time, full or of the owner's calls only.
Panes that open together on a home with no record build one first record between them: each waits its turn and builds only if the record is still missing.
After a full refresh the next full refresh waits at least as long as that one took, so a refresh that overran leaves the machine that much rest; on a busy machine, a one-minute load average of twice the cores or more, that wait is at least a minute.
A rebuild of the owner's calls waits for neither, only for a rebuild already under way, so the calls stay within about two seconds however long the last full refresh took.
A pane that asks for a rebuild meanwhile starts none and queues none; it asks again at its next check.
It also reads the overview once a second, off the drawing thread, so its sentences follow the strip and the status bar, and NEEDS YOU is rebuilt the same way when the overview's ready work changes.
The record is always built by the code on disk, so a running pane or worker copy checks before every frame whether `bin/fm-factory.py` changed, and re-runs itself in place, in the same pane, once the new file is non-empty and compiles.
The live pane holds that reload while the talk box, a confirmation or a notice is showing, so a draft or a sent or not-sent line is never lost, and reloads on the first frame after.

`bin/fm-factory.py --screen` prints what the screen shows as data, schema `fm-factory-screen.v1`, for a second screen that lays the pane out its own way, such as the web page ([web.md](web.md)).
It is the overview and every factory's page as the pane selects and words them: the three sentences and the part each leads to, the first card, the two shelves, the stopped jobs, each call with its answers and how long it has waited, each factory told as Now, New and Next (its badge, its jobs with the step a busy one is on and what it is doing, its routine lines, its New with times, links and what can be read, its Next, or its one quiet line) and the heading over them, and for a factory's page its parts top to bottom (its sentence of state, what HAPPENING NOW lists, its LATELY, its UP NEXT with how many are lined up and the folded rest, its COMING BACK with dates), its rules, lessons, talk and the jobs whose workers its tab shows.
It answers from the cached record at once and keeps that record current the way a live pane does, starting a due refresh or a rebuild of the owner's calls in the background.
`bin/fm-factory.py act` is the writing keys for such a screen: it reads one action as JSON on stdin, sends the note that key sends under the same request id, and prints whether it went and the words the pane would say.
An action that names the asking its screen showed sends nothing once the record's differs.
The script's header and `screen()` and `act()` own the fields and the actions.

The record's schema is `fm-factory.v1`:

| Field | What it holds |
| --- | --- |
| `as_of`, `since` | When the record was built and the start of New and the feed, as UTC times and epochs. |
| `snapshot_epoch`, `calls_signal` | When the workers in it were read, and the owner's calls signal its calls were read under. |
| `read_at` | When the refresh began reading, in fractional epoch seconds; a pane keeps a card it just asked about checking until a record read after the press arrives. |
| `since_from` | What that start is: `last look`, or `12 hours` with no look recorded yet, or `48 hours` when the last look is older than that. |
| `counts`, `count_line` | The overview reading's `busy`, `decisions`, `ready_to_merge`, `failed` and `lost` (each null before the first reading) and `lost_list`, the ids of the stopped jobs, whether that reading is `current`, `past` or `unknown` and its `age`, and the `idle` factories. |
| `ready_list` | The overview reading's ready work that NEEDS YOU was built on. |
| `queue`, `queue_line` | Every job nobody has started: `total`, `starts_on_its_own`, `parked` and `parked_until[]` (one `until` date and `count` per date, soonest first), `in_line`, `on_hold`, `waits_on_other_work`, `waits_on_you` (which includes the older calls and the deferred), `older` and `deferred`, and the same as one line of words. |
| `older[]`, `coming_back[]` | The two shelves: each older question's `id`, `factory`, `title`, `since` (the day it was last held), `asking` and `asked` (what the owner asked of it since, or null), oldest first; and each call put off to a date with its `until`, soonest first. |
| `news` | How many changes went live and reports came in since the feed's start, before the feed is cut short. |
| `needs_you[]` | Each of the owner's calls, most pressing first: its `id`, `factory`, `kind` (`question` or `finished work`), `title`, `ask`, `why`, `options[]` (`key`, `label`, `suggested`), `suggested_by`, a `recommendation` that is not one of the options, `holds_up[]`, `since`, `pr`, `for`, the person it waits on, `mate`, the second mate whose PR it is (absent for this home's own work), `answered`, when the owner answered it since it was asked and with which option (`at` and the option `key`, null for a keep), or null, `checking`, true while Starship re-checks a question the owner marked already settled, `summary[]`, the short section a finished-work PR opens with as `label` and `text` pairs in the order In short, See it, You need to, Risk (empty for a question, or for a PR without that section), and `read`, the sources `bin/fm-read.sh` is given (empty when there is nothing to read). |
| `factories[]` | Each factory: `id`, `name`, `about`, `projects`, `steered_by`, `state`, `idle_since`, `crew`, `needs` (the ids of its items in `needs_you`), `jobs[]`, `next`, `queue` (its own counts, as above), `rules`, `rules_size` (the characters its rules take in a brief, measured against the top-level `rules_cap`, as [the registry](fork-configuration.md#factory-registry-datafactoriesmd) describes), `learned`, and `talk`, plus `routine` (the [routine](#routine-work) kinds its registry entry names, or `Routine work` for `routine: yes`) and `routine_runs[]`, one per routine kind that ran today or has a pass under way: `kind`, `today`, `last` and `last_word`, `running`, and `folded` (the ids of the jobs the line stands for on the overview). |
| `factories[].jobs[]` | Each job: `id`, `title`, `kind`, `state`, `step`, `started`, `doing` and where it came from (null when no step is known), `last_sign_of_life` and where it came from, `quiet`, `until`, `pr`, `queue`, `parked_until` (the date a `parked` job is parked until, else null), `look` (for a `needs a look` job, what it waits on Starship for: `checks`, `question` or `stuck`, else null), `routine` (its routine kind, or null), and `read`. |
| `feed[]` | Each event: `at` (or a `date` when only the day is known), `actor`, `factory`, `job`, `word`, and `text`; an outcome also has the work's `title`, a change that went live its `pr`, a report its `read`, and a settled call the owner's `answer`. |

Every state is a word: a job is `busy`, `decision for you`, `ready to merge`, `needs a look`, `failed`, `waiting`, `stopped` (its worker is gone, which the overview counts, and Starship recovers it), `no worker`, `no reading`, `with Starship`, `finished`, `next`, `later`, `on hold`, `on hold until <date>`, or `waits on other work`; a factory is `needs you`, `at work`, or `idle`.
A job reads `ready to merge` only once the shared overview reading lists it as ready, so it is counted in the strip's `ready to merge`; until then it stays `busy` at `checking`.
A pipeline (`run-step`) reading that comes back `unknown` on a worker the overview's liveness check reads alive also stays `busy` at `checking`, as the overview counts it busy, so the row does not drop out of Now between readings; on a worker not read alive it reads `no reading`.
The words the overview also uses mean what [status-bar.md](status-bar.md#fleet-words) says; `with Starship` is finished work that is Starship's turn, such as a scout report it reads first, and `no reading` a job whose state could not be read.
A job's row says three of those states in fuller words, so it is plain whose turn it is, while the record keeps the state word: `needs a look` reads by its `look`, `stopped: its checks raised a question, Starship is on it` (`checks`), `stopped: it asked Starship a question, Starship is on it` (`question`), `stopped: it is stuck, Starship is on it` (`stuck`, a blocked worker), else `waiting on Starship`; `stopped` reads `stopped, Starship is on it` for a job the overview counts stopped (the one the top sentence counts) and plain `stopped` otherwise; and `with Starship` reads `finished, now with Starship`, or `finished, Starship is reading the report` for a scout.
A job nobody has started also says where it stands in the queue: its `queue` is `starts on its own`, `parked`, `in line`, `on hold`, `waits on other work`, `waits on you`, `older call`, or `deferred`, and null for a job with a worker.

## Where each part comes from

| Part | Source |
| --- | --- |
| Jobs, finished work, the work list | `bin/fm-fleet-snapshot.sh --light`, the canonical fleet reading without the parts the pane does not show, plus each captain hold the tasks-axi adapter reads that the snapshot's markdown backlog lacks |
| What is held, and what still waits on other work | The backlog as the home's tasks-axi adapter reads it, for every open work item it has: a markdown backlog file cannot tell a blocker that was finished and archived from one still open |
| The queue | Every open work item with no worker, counted in that same pass by what will start it |
| Whether closed work was finished or only closed | `landed_delivery` in `bin/fm-landed-lib.sh`, the reading Recently Landed is selected with |
| Whether you already answered a call | The owner's own answer and keep notes in the inbox (`bin/fm-inbox.sh receipts`), matched by the request id each key writes |
| The sentences' figures | `fm_fleet_status_counts` `overview` in `bin/fm-fleet-status-lib.sh`, the reading the bridge strip and the status bar show, followed once a second by the live pane |
| Each job's state word | `fm_fleet_status_bucket` in `bin/fm-fleet-status-lib.sh`, the same fold the status bar and bridge strip count with |
| What needs you | `fm_owner_calls` in `bin/fm-fleet-status-lib.sh`, over the backlog as the home's tasks-axi adapter reads it (`bin/fm-fleet-snapshot.sh --axi-backlog`) and the overview reading's ready work, or this pane's own state words before the first overview reading |
| A question's options and suggestion | `bin/fm-tap-desk.sh shapes`, the reading its tap card shows |
| Whether a question is being re-checked | A request in `bin/fm-captain-hold.sh reconcile list`, made, or followed by the pane's settled inbox note, since the call was last held |
| Which factory a job belongs to | Its work item's project, through the factory registry |
| How long a job has run | Its spawn time in the task's metadata |
| What a job is doing this minute | The worker's stated step, else the checks' own state, else nothing, which a row reads as `just started` or `at work` |
| The last sign of life | The newest of the worker's turn times (`state/<id>.busy-state`), its last finished turn, its last status line, its stated step, and the last time its pane text was seen to change |
| The feed and New | The `[at=]` times on `done` and `failed` status lines, when each of the owner's calls was held, completed work items, the who-steers log, and the owner's own notes and Starship's replies from the inbox; a merged change's time from its PR (`gh pr view`), a report's from its file, and a settled call's answer from its resolution record |
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

`tests/fm-factory.test.sh` builds a fixture home of sample factories and a fixture fleet reading, and checks the record and the plain screen word for word, the three sentences counting every call once, the two shelves and the keys that bring an older question back or let it go, NEEDS YOU's order against the strip's most urgent call, a stopped job's words, the queue's counts, parked work counted by its date, a factory's page read top to bottom with no line of queue counters and its calls put off to a date under COMING BACK, a folded count line opened on every job it stands for, closed work against finished work with a change's merge time, a report's time and a settled call's answer, each factory told as Now, New and Next and a quiet factory folded into one line, the quiet job, routine passes folded into one line and kept out of the feed except a failed one, and every pass shown as before without a routine mark, the registry fallback, the writing keys pressed in the real live view, the screen as data against the plain screen, an action from a second screen against the note the pressed key sends, the Read line and what `r` and a click hand the reader, the See what changed line and what `o` and a click hand the opener, the talk box listening to a stand-in microphone that writes real samples, what a spoken note hands the speech service and that a cancelled one hands it nothing more, how soon a parked decision leaves the live view, the Herdr calls behind the factory tab and the plugin against a stand-in Herdr, a worker copy closing when its job ends, and a running pane reloading its changed code in place.
`tests/fm-tap-desk.test.sh` checks on one real backlog that the bridge strip, this pane, and the tap page show the same count of the owner's calls, and that the pane shows a question's recorded options.

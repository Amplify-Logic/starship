# Continuous channel intake

Operator procedure for the opt-in continuous intake gate, which works as one system with the morning intake (`bin/fm-morning-intake.sh`) and the daily to-do page (`bin/fm-todo-render.sh`).
`bin/fm-channel-intake.sh --help` owns the configuration schema (every `config/channel-intake` key and its default) and the exact commands, flags and mechanics; `bin/fm-channel-intake-schedule.sh --help` owns how the schedule is installed.
This document owns the install and rollback procedure, the private inventory format, the division of work between the gate and its orchestrator, and the detection limits that must be disclosed rather than glossed.

## What is implemented and what is active

Implemented means the tracked code exists and its behavior suite passes.
Active means a device has opted in, installed the schedule and armed the live check.
They are separate on purpose, and a report about this feature must state both.
Nothing in this repository activates itself: the gate is inert on every home without an `enabled = true` line, and the schedule refuses to install on a home that has not opted in.
[`configuration.md`](configuration.md#daily-intake-and-to-do-page-configmorning-intake-configchannel-intake) says how a home turns the three parts on.

## The division of work

The gate is local only.
It never reads a source system, never opens a network connection, never sends a message, never spawns an agent, and never takes the per-home session lock or the watcher lock.
It decides when a source is worth reading, remembers what has already been seen, and renders what the captain still owes.

An orchestrator does the authenticated connector read on its own path and reports back.
That split is what keeps a poll cheap: the incremental checkpoint read is the gate's decision, and no reasoning agent is paid for merely to discover there is no work.
If connector access itself needs an agent, that agent's cadence, work and quota are bounded and disclosed by whoever configures it; nothing here invents a webhook or a subscription, because the connectors in use expose none.

A tick therefore looks like this.

1. launchd runs `tick`. It reads no source and finds the due set from each source's own checkpoint and backoff.
2. If anything is due it records one armed cycle and appends exactly one wake.
3. The orchestrator runs `claim`, which hands back each due source's checkpoint, its coverage sentence, the bounded revision window, the tracked thread parents with their reply markers, any extra read the source's kind owes, and one `recheck:` line per open or waiting to-do item that names a source; `bin/fm-todo.sh --help` owns which items are listed.
   It then records the pass with `bin/fm-todo.sh sweep-start --pass`, so every listed item the pass does not re-read shows as not re-checked.
4. The orchestrator reads those sources through its own authenticated connector path.
   It re-reads every `recheck:` item at its source in the same pass, applying the closing rules in `daily-todo-freshness`, and records each outcome with `bin/fm-todo.sh verify` or, with the evidence, `bin/fm-todo.sh close`.
5. Each observed message becomes one `observe` call carrying a stable source id and a content digest.
   Before classifying anything as `obligation`, `urgent` or `deadline`, the orchestrator reads the rest of the thread for a reply the captain already sent, and reads the source-side item's own completion state.
   A message the captain has already answered with content that discharges it, or whose source-side task is already completed, is reported as `routine` rather than opened as a new owed item.
   The gate deliberately does not enforce this: it opens an item for whatever class it is handed, because only the connector read can see the thread and the source-side state.
   Silence is not completion. A message nobody replied to and a source-side item nobody closed both stay owed, and an acknowledgement or a promise to act is not a reply that discharges anything.
   A partner- or customer-facing ask - a colleague relaying a partner question, a customer's own message - is observed with `--partner`, which ranks it ahead of other asks on the day page.
6. A source that reads what the captain sent - their sent mail and their chat replies - closes each open item that a sent message discharges, with `bin/fm-todo.sh close --actor` naming the captain and the sent message as evidence; an acknowledgement or a promise to act closes nothing.
7. `complete --source ID --checkpoint VALUE` advances that source's checkpoint and says how many listed `recheck:` items are still not re-read, or `fail --source ID --reason TEXT` records the failure and backs off.

Three kinds carry their own read, so asks that never carry an @mention or a fresh modification date still reach the page between morning sweeps.
A `slack-dms` source reads each DM its coverage sentence names directly by conversation id, never through search.
A `calendar` source reads the window through the next two working days for unanswered invites and events that ask for preparation.
An `asana` source hands out, once per local day, a full re-list of every incomplete task assigned to the captain, completed with `--relisted`.
The day page's coverage fold names every channel family no enrolled kind reads between morning sweeps.
Any other kind is read by its checkpoint alone; a home that needs a system read differently, such as a ticket system, carries that in its private add-on (`bin/fm-addon.sh`).

## Team announcement channels

A `slack-announcements` source enrols a set of team channels for what they announce rather than for asks addressed to the page's owner.
Its coverage sentence lists the channel ids; the source kind is what makes the gate accept the `update` class from it.

Each pass reads, in every enrolled channel, the new top-level posts since the checkpoint and the poster's own replies under them.
It keeps only a post that announces something relevant to support:

- a product or feature launch or change;
- a date or deadline;
- a price, availability or ordering change;
- a process or policy change.

Chit-chat, social posts, lunch and celebrations, and questions between colleagues are not observed at all.

A kept post is one `observe --class update` call.
Its `--ref` is the message timestamp, its `--source-epoch` the post time, its `--link` the Slack permalink, and its `--title` a one-line summary that carries the post's dates, for example "Example product limited release, 50 units - live on the partner webshop 15 Oct".
A post that asks the page's owner to act, or sets a deadline that is theirs, is observed with an owed class instead (`obligation` or `deadline`), so it reaches "Needs you now" like any other ask.
An edit inside the revision window is re-observed like any other message, so a moved date updates the same item.

An update is never notified and never on the to-do list.
The brief lists it under what changed, and the day page shows it in the collapsed "Updates" fold, newest post first with its post time and link.
It leaves the polled set two weeks after it was posted or last edited, the same way routine traffic leaves after a day; `bin/fm-channel-intake.sh --help` owns the horizon.

### The durable updates log

Each kept post also appends one dated entry to `data/product-updates/log.md` in the home, newest last, so drafting and investigations work from the latest facts rather than from what an earlier session remembered.
The orchestrator writes it on the same pass as the `observe`; tracked code never does.
An entry is a level-two heading of the post date and the one-line summary, then the dates it announces, the facts a reply would need (names, quantities, prices, dimensions, ordering channel), and the permalink.
An edit that changes a fact appends a new entry naming the change rather than rewriting the old one, so the newest entry for a topic is the current one.

Drafts and investigations read the newest entries before relying on product, date, price or process facts, as they already read the reply bank before drafting.
That standing instruction lives in the home's private brief include, which [`configuration.md`](configuration.md#home-brief-include-configbrief-includemd) owns.

## Install

Every step is local to one device and one home.

1. Write the private, gitignored `config/channel-intake`.
   Start from the key list in `bin/fm-channel-intake.sh --help`.
   `enabled = true` is the opt-in. `notify_recipient` and `notify_recipient_verified` are covered under "Recipient verification" below.
2. Write the private, gitignored source inventory, by default `data/channel-intake/sources.tsv`.
   Its format is under "The source inventory" below.
3. Confirm the resolved configuration with `bin/fm-channel-intake.sh status`.
   It prints declared knobs only, and never the recipient identity itself.
4. Install the schedule with `bin/fm-channel-intake-schedule.sh install`.
   That writes `~/Library/LaunchAgents/<label>.plist`, loads it, and arms the live watcher check.
   Inspect the definition first with `render` if you want to read it before it is loaded.
5. Confirm with `bin/fm-channel-intake-schedule.sh status`.

Firstmate owns installing the schedule and enabling live notifications.
A worker prepares the configuration; it does not activate it.

## Rollback

1. `bin/fm-channel-intake-schedule.sh remove` unloads the LaunchAgent and disarms the live check.
2. Setting `enabled = false` in `config/channel-intake` makes every command inert again, including the read-only session-start surface.
3. Deleting `config/channel-intake` returns the home to the shipped state.

Removing the schedule deliberately leaves the ledger under `data/channel-intake/` in place.
An open obligation must survive an uninstall, and removing a schedule is not the same as discarding what the captain still owes.
Discarding the ledger is a separate, explicit deletion.

## The source inventory

Tab-separated, hand-maintained, gitignored, and the only place a channel id, mailbox or board id lives.
Tracked code reads it; tracked code never contains it.

```
<id><TAB><kind><TAB><coverage sentence>
```

`id` and `kind` must be leading-dot-free slugs of `[A-Za-z0-9._-]`, because both reach paths under `data/channel-intake/`.
The coverage sentence is free text and is rendered verbatim on the brief.

The file is also the explicit coverage statement, and that is its more important job.
A row is one enrolled source.
Enrolling the channels the daily brief and improvements intake already use does not enrol every channel in the workspace, and the brief says so in its own words on every render.
Coverage is stated, never implied.

## Recipient verification

Notifications are refused outright until `notify_recipient_verified = true`.
Set it only after the configured `notify_recipient` has been checked against the known captain account, not because the value looks right.
Standing scope covers concise private intake alerts to the captain and nobody else.
It does not authorize a public or channel reply, a message to a customer, or notifying any other user, and no command here can send one.

## Delivery surfaces

Three destinations, and they are not interchangeable.

| Class | Destination | Constraint |
|---|---|---|
| `urgent`, `outage`, `deadline` | one grouped private direct message, plus the daily to-do list | rate-limited, capped per local day, deferred by quiet hours except `outage` |
| `routine` | the brief only | never a ping |
| `obligation` | the daily to-do list | not the Action Deck |
| `automation-candidate` | a proposal in the brief | never an executable card |
| `update` | the brief and the day page's "Updates" fold | never a ping, never owed; only a `slack-announcements` source records one |

Quiet hours defer, they do not drop: a deferred alert renders as soon as the window ends.
`outage` is the single class that still goes out inside quiet hours, because silencing a live service outage until morning would not preserve real severity.

The Action Deck is for automations the captain fires directly, with preview, exact target, the existing per-action approval, and post-execution evidence.
It is not a task inbox.
This gate has no path that writes anything the deck renders, and the behavior suite asserts that.
Detecting that a device or account needs an action grants no permission to perform it; that stays with the action gateway.

`notify-due` renders and does not send.
The orchestrator sends the payload and then calls `notify-sent --keys "..."`, which is what stamps the items.
An interrupted send therefore re-renders on the next pass rather than being silently swallowed.
An item the captain resolves between the render and the confirmation is skipped and named on stdout; the rest are stamped and the payload still counts against the daily cap, so a delivered alert never re-renders.

A payload that cannot go out says why.
`status` prints `notifications_state`, and `pending` and the live check name the condition in words: `blocked` when the recipient is unset or unverified, `held` when the daily cap is spent or the minimum gap has not elapsed.
Nothing is lost in either case - the items stay notifiable and re-render once the condition clears - but neither is ever reported as nothing to send, because "no alert went out" and "nothing needed an alert" are not the same fact.

`brief` and `todo` render from the same ledger every time.
A correction, a resolution and a completed obligation reconcile across both by construction rather than needing a second pass over two stores.
The day's Lavish page is the third surface, and it re-ranks itself during the day rather than being a snapshot of 06:00.
A completed read calls [`bin/fm-todo-render.sh`](../bin/fm-todo-render.sh), which first folds this ledger, the morning action metadata and the captain-held backlog into one durable item per ask through [`bin/fm-todo.sh`](../bin/fm-todo.sh), then rebuilds `.lavish/today-<YYYY-MM-DD>.html` from those items with no model call.
An `automation-candidate` is excluded there exactly as it is from `todo`, because a proposal is not a human obligation.
Each line says when it was last verified against its source, and a line not re-read in the current verification sweep says "not re-checked since" rather than passing as current; the page carries its own render time separately.
Closures, including the captain's page commands, are durable on the item and show in the collapsed closed fold ("Closed today", or "Closed since" the previous sweep) with their evidence; a closed item returns only when its source meaningfully changes, with the reason shown.
A home's add-on can extend the page through two hook points of `bin/fm-addon.sh`: `todo-verbs` hooks take more one-line verbs on a row, such as changes to a ticket the row names, and show their own state on the row with `bin/fm-todo.sh mark`; `todo-page` hooks add sections of their own, such as a live table from a system only that home reads.
`bin/fm-todo.sh --help` owns the item record, identity, verification, page commands, add-on verbs and marks; `bin/fm-todo-render.sh --help` owns the page shape, add-on sections and the morning composition format; verification procedure remains owned by `daily-todo-freshness`.
The refresh is fail-soft and never manufactures a page: a home with no page for the day is told so, a renderer that fails is reported, and neither costs the read whose checkpoint has already advanced.
Both accept `--out FILE` inside the configured `report_dir` and overwrite the same path, so a background render updates the existing page instead of leaving a trail of dated files; a path with a `..` component is refused before the directory check.

Opening a rendered page is opt-in and never automatic.
A report the captain asked for is rendered with `--open`, which opens the written page as soon as it is ready; that flag is the only thing in this gate that opens anything.
A scheduled or background render omits it, writes the same path, and never takes focus - the launchd job only ever runs `tick`, so the flag cannot reach it.
`--open` without `--out` is refused, because there is no page to open.

The opener is `open_command`, defaulting to `open` on macOS and `xdg-open` elsewhere; `status` prints the one that would be used.
It fails soft on purpose: an opener that is not installed, or one that exits non-zero, is reported as `could not open <path>` and the command still succeeds with the page written.
The render is the deliverable and the open is a convenience, so a missing viewer must never turn a written report into a failed command.

## Resolution

An obligation is discharged by content, not by the fact that somebody replied.
An acknowledgement or a promise to act is not a completion.

- `resolve --item KEY --reason TEXT` archives the item. The active list loses it; the archive keeps its source, ref, link, provenance, revision count and the reason it was closed.
- `resolve --item KEY --waiting --reason TEXT` is the honest middle state for work handed to someone else. The item stays on the ledger under waiting-on-others.
  A reason that names neither a date nor a hand-over to someone other than the captain is refused, because that wait is a park with no end; `bin/fm-channel-intake.sh --help` owns the accepted forms.

A resolved ask is never reopened by a poll.
A reaction or an unchanged re-read reports `archived-unchanged` and does nothing.
Even a genuine later edit only reports `archived-changed` and annotates the archived record; reopening is a captain decision.
The brief then says the item was edited after it was closed and that it stays closed, bounded like every other row there.
The annotation is carried alongside the archived evidence rather than rewritten into it, so the source, ref, link, provenance, revision count and reason it was closed stay verbatim.

A post-resolution edit is news exactly once.
The poll that first sees it reports `archived-changed` and writes one log line; every later poll of that same unchanged edited message reports `archived-unchanged` and writes nothing at all.
The archived record keeps its pre-resolution digest as evidence, so "has this edit already been reported" is answered by the annotation rather than by that digest - without which a single edited archived message would re-announce itself to the orchestrator on every tick for as long as the record lives, and grow the log behind it.
A genuinely later, different edit supersedes the annotation and is news once more, and neither case ever reopens the item.

## Disclosed detection limits

Both limits are real, bounded by design, and rendered on the brief itself so a reader is never left to assume completeness.

**The edit horizon.**
An in-place edit keeps the original source id, so a forward cursor never returns it again.
Re-detection depends entirely on the orchestrator re-reading the bounded recent window that `claim` hands over as `revision_window_from`, and re-observing what it finds; the digest comparison in the gate then updates the same item.
An edit to a message older than that window is not detected.
Widening `revision_window_seconds` costs a proportional re-read on every tick.

**Thread replies on older parents.**
A cursor read of a channel returns messages whose own id is newer than the cursor.
A reply added to a thread whose parent predates the cursor can therefore appear in no such read at all.
`observe --thread PARENT --reply-marker VALUE` records a per-parent reply marker, and `claim` prints the tracked parents back so the orchestrator re-reads only the threads whose marker advanced.

The tracked set is bounded, and that bound is part of the limit rather than a footnote to it.
A parent whose reply marker has not advanced within `revision_window_seconds` leaves the set, so neither the `claim` output nor the per-tick connector work behind it grows with all thread history.
`claim` states the bound as `thread_tracking_window_seconds` and the brief states it in words, because a tracked set that silently meant "every parent ever seen" would be both unbounded and a coverage claim nobody could honour.
Coverage is therefore parents still inside that bounded set and nothing older, and no completeness is claimed for new replies on old threads.
Retiring a marker retires a re-read hint and nothing else: every captured item, its evidence and its checkpoint are untouched, and a reply that does arrive later on a retired parent still resolves to the same item key - which for a closed obligation is the archived record, never a reopening.

To reproduce the gap before relying on any coverage claim: note a parent message older than the current checkpoint, locate a reply on it, then run the same cursor read and confirm the reply does not appear.

**Latency is a target, not a bound.**
The poll interval is a target detection latency.
Real latency also absorbs sleep and offline stretches, rate limiting and backoff, quota exhaustion, agent queue delay, and the tick's own completion time.
`status` reports measured detection latency from real samples rather than projecting it from the interval, and the brief states the same caveat in place.

## Cost and quota discipline

`interval_seconds` has a hard 300-second floor, because an awake laptop multiplies the cadence by every enrolled source.
`active_start` and `active_end` bound the scanning day: set together as `HH:MM`, they make every source not-due outside the window, so the tick enqueues no wake, the watcher check stays silent, and a claim hands back an empty set.
The window wraps midnight when the end is at or before the start, exactly as quiet hours do, and leaving both unset keeps the historical all-day behavior.
It bounds reads, not alerts: quiet hours still own whether a rendered payload goes out.
A laptop opened partway into the window reads on that first tick rather than waiting for the next interval boundary, because the cadence is measured from each source's last attempt.
A source whose read failed backs off geometrically to `backoff_max_seconds`, so a permanently broken source settles into a cheap heartbeat instead of a retry loop.
One armed cycle produces one wake, no matter how many ticks fire inside it.

A throttle reported by a connector is a reason to call `fail` and back off.
It is never a reason to retry harder, and the request-rate ceiling is deliberately not measured by hitting it: that would spend the account's quota for every other lane and teach little.
Honour whatever `retry-after` or error backoff the connector reports.

Per-tick cost is a function of the enrolled source count and thread activity.
Measure it on the real inventory rather than projecting it from one channel.

## Ledger horizons

Per-poll work is bounded by the horizons that already exist, not by a new retention policy, and nothing is ever deleted.

Every surface that walks the ledger reads a whole record directory in one process rather than one per field per record, so the registered watcher check finishes well inside its timeout however long the home has been running.

Routine traffic is rendered in exactly one place: the brief's "what changed", bounded by the same 24-hour window as every other row there.
Past that horizon it leaves the polled set by *moving* into `data/channel-intake/inactive/` with its record byte for byte intact.
It is not deleted, not resolved and not closed on the captain's behalf: `items --state inactive` lists it, a bare `items` lists it, `status` counts it as `items_inactive`, and re-observing the same message restores it to the active set rather than opening a second item.
`tick` does that pass, capped per run so a first sweep over a long-running ledger is itself bounded, with the remainder draining on later ticks.
A team update leaves the same way on its own longer horizon, edited or not (see "Team announcement channels").

Nothing else owed, waiting, corrected or already notified ever leaves the polled set, whatever its age.
An open obligation is a durable record with no expiry, and the only thing that takes one off the active list is an explicit `resolve`.

## Session-start surface

When `bin/fm-bootstrap.sh` runs, the built-in bootstrap hook `hooks/bootstrap/20-channel-intake` calls `pending`, which is read-only and silent on a home that has not opted in or has nothing owed.
It reports due sources, items ready to send or blocked or held, sources reading `unknown`, and a live check that has gone absent or unregistered, naming `arm-check` as the repair.
The `intake-digest-lines` skill owns the response to each of those lines.

A home whose add-on carries same-named tools, hooks and skills runs the add-on's: its `hooks/bootstrap/20-channel-intake` replaces the built-in one, its skills replace the opt-in ones, and a schedule or live check it armed keeps naming its own scripts.
A source reading `unknown` did not complete its last read.
That is not the same as nothing new, and it must not be reported to the captain as quiet.

## Maintaining this file

Keep current operating procedure here and exact mechanics in the script's own header and `--help`.
State each contract once and cross-reference it everywhere else.
Do not copy the configuration schema or the command list from the script into this file.

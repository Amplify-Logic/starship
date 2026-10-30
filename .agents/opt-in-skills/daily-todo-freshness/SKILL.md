---
name: daily-todo-freshness
description: >-
  Agent-only verification procedure for any captain-facing "waiting on you" surface.
  Load before producing or updating a daily to-do, needs-you, waiting-on-you, or morning-brief page, before re-checking the `recheck:` items a channel-intake claim lists, and before claiming in chat that a person or thread is waiting on the captain.
  Owns the clock rule, re-reading each item at its source, the other-party acknowledgement check, the closing rules, the pre-publish re-read, and labelling discipline.
user-invocable: false
metadata:
  internal: true
---

# daily-todo-freshness

Load this before producing or updating any captain-facing to-do, needs-you, or waiting-on-you surface, and before claiming in chat that anything is waiting on the captain.
This skill is the single owner of the verification procedure for those surfaces.
It exists because a page built from what an earlier read said, rather than from a fresh read, shows asks that were already answered and hides ones that moved.
A home whose add-on (`bin/fm-addon.sh`) carries a skill of this name gets that one instead, with stages for the systems only that home reads.

Run the stages below in order for every item that will appear on the surface.
Do not publish an item whose stage was not run; label it "cannot verify" and name the channel instead.
A surface built partly from memory or from a previous page is not verified.

## Why the obvious sweep fails

A search, a sent folder and a status field are exactly the surfaces that miss the actions that matter.

- A reply sent from a shared mailbox or a help-desk tool never reaches the captain's own sent folder, whoever wrote it.
- An internal note or comment rarely moves a status and rarely appears in a search index.
- Chat search lags on direct and group messages, and returns nothing for conversations it has not indexed.
- Colleagues close items, and states move between the read and the publish.

Every stage below exists to close one of those gaps.

## Stage 0 - establish the clock

1. Record the sweep start time in the home's local zone (`timezone` in `config/channel-intake`) and in UTC.
2. Read every timestamp a source returns with its zone; a value with a trailing `Z` or an offset is not local time.
3. Convert to the local zone before writing any time on the surface; never print a raw UTC value as local.
4. For the daily page, record the sweep start with `bin/fm-todo.sh sweep-start`, or `sweep-start --pass` on a channel-intake pass, so a line not re-read in this sweep or pass renders as not re-checked.

## An intake pass re-checks what is open

A pass is not only an intake of new messages.
Every `recheck:` line its claim prints is an open or waiting item to re-read at its source in that same pass, through the stage below that owns the source.
Record each outcome on the item: `bin/fm-todo.sh verify` when it is still open, `bin/fm-todo.sh close` with the evidence when it is discharged.
`complete` reports the listed items left unread; that count is a miss to fix in the next pass, not a result.

## Stage 1 - the system of record, per item

For every item that comes from a system with its own record of the ask (a ticket, an issue, a task, a request):

1. Fetch the record itself and read its current state, owner, last change time, and the time of its last inbound and last outbound message where it keeps them.
2. Print a state by its label exactly as the system names it; never print an internal id and never paraphrase it.
3. Read the newest inbound message and the newest outbound message on the record; never infer a message's content from the state.
4. An outbound from a shared mailbox or a help-desk reply is a real reply from the team, whoever wrote it.
5. Read the record's internal notes, newest first; a note that asks the captain directly by name (`captain_names` in the home's private `config/channel-intake`) makes the item the captain's even when the owner says otherwise.
   With no `captain_names` set, only a record the captain owns or a message the captain wrote is theirs; never decide ownership by any other person's name.
6. When a surface states how many items a person holds, recount them live rather than reusing a number, and check whether the system's own "open" filter hides a state where the other party can still be waiting.

The system's own tool help owns its object types, filters and fields.

## Stage 2 - chat, read directly, never via search

1. For each named counterparty, read the direct message or channel history directly with the channel-read tool.
2. The home's `slack-dms` intake source reads its named conversations directly on every pass; their conversation ids live only in its coverage sentence in the home's private source inventory (`data/channel-intake/sources.tsv`, or the `sources_file` that `config/channel-intake` names).
3. For any item whose thread is named, read the thread to its last reply and check whether the captain appears after the question.
4. Use search only to discover an unknown thread, never to conclude that something is absent.
5. A zero-result search is not evidence of absence; record it as "not located".
6. Team announcement channels are read for what they announce, not for asks; `docs/channel-intake.md` owns which posts are kept, and a kept post that asks the page's reader to act is verified here like any other line.

## Stage 3 - mail, and know its limits

1. Search the sent folder for the captain's own sends within the sweep window.
2. Search per counterparty domain for inbound mail.
3. Never conclude "no reply was sent" from the captain's mailbox alone; it is authoritative only for mail sent from the captain's own address, and a shared-mailbox reply must come from Stage 1.

## Stage 4 - task trackers

1. Fetch named tasks by their id and read completion, due date, last change, assignee and where they sit in the project.
2. Enumerate a project's open tasks through its task list rather than through text search, which a tracker may ignore or index late; never use search to conclude a task's state.
3. Keep the task ids in the durable record instead of re-finding tasks by name.

## Stage 5 - calendar

1. List the window's events ordered by start time in the home's local zone.
2. Read the captain's own response on each event and write "declined" where it is declined; an event on the calendar is not an event the captain is attending.
3. Read event descriptions, because commitments and references to other records hide there, and follow any such reference back into Stage 1.
4. Put every meeting the captain attends or hosts today in the morning actions, never in the details fragment, and give every calendar-sourced action an `ends_at`: the event's end, as an ISO timestamp with its zone. A "due today" deadline gets the end of that local day. The to-do page closes the item on its own once that time passes. The details fragment carries only context that is not time-bound.

## Stage 6 - the other-party acknowledgement check

For anything still looking open after the stages above:

1. Before writing "no reply", look for the counterparty's next message in every visible channel.
2. If they thank the captain, confirm, or move on, the captain acted somewhere invisible; the item is not open.
3. Where a relationship is known to run on a channel no source reads, such as phone or a messaging app, write "cannot verify, likely handled off-channel" rather than "no reply".

## Closing rules

An item closes on evidence that its ask was discharged, never on silence.

1. A reply the captain posted in the parent channel after the mention, not inside the thread, counts as a reply; a thread read that finds no replies is not evidence that the captain did not answer.
2. An internal hand-over - routing the ask to a colleague, another record or another team - never closes a partner- or customer-facing ask while the other party is still waiting on the team; it stays open or waiting until they have an answer.
3. A read of what the captain sent closes each open item a sent message discharges, with that message as the evidence and the captain as the actor; an acknowledgement or a promise to act closes nothing.

## Stage 7 - the pre-publish re-read, non-negotiable

1. Immediately before writing the surface, re-fetch the state and last change of every record on it, and re-run any live recount from Stage 1.
2. Re-read the last message in any thread quoted on the surface.
3. If a re-fetch shows a change, fix the line; if a line cannot be re-read, drop it to "cannot verify".
4. Stamp the surface with the re-read time, not the sweep start time.
5. For the daily page, record each successful re-read on its item with `bin/fm-todo.sh verify`, and each proven closure with `bin/fm-todo.sh close` and its evidence; that script's `--help` owns the commands, and a line with no recorded re-read is never shown as current.

A few minutes between reading and publishing is enough for a line to go wrong; the re-read is what closes that gap.

## Stage 8 - labelling discipline

1. Every line carries the channel it was verified on and the timestamp of that read.
2. "Cannot verify" names the specific blind spot, such as phone, in person, a messaging app, or a system not reachable from this account.
3. A shared mailbox whose replies are readable on the system of record is not a blind spot; never list it in a legend of unreachable channels.
4. Never publish an item as closed without evidence of the close, to the same standard as publishing it as open.
5. A durable record may carry an item between updates, but its freshness never carries with it: a line counts as current only when this sweep re-read it, and an unread line names the time of its last read instead.

## Chat claims

The same procedure applies to a single sentence in chat.
Before telling the captain that a person or thread is waiting on them, run Stages 1, 2, 6 and 7 for that item.
If they were not run, say "cannot verify" and name the channel, rather than alleging that something is owed or missed.

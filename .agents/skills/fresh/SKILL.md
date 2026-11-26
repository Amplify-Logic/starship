---
name: fresh
description: >-
  Start a fresh first-mate session on the captain's word: save what this session learned, then hand every piece of work in progress to a new, empty session of the same kind.
  Use when the captain invokes /fresh or asks for a fresh or clean first-mate session, and on a captain inbox note that begins `Fresh session asked for from`.
user-invocable: true
metadata:
  internal: true
---

# fresh

A fresh session replaces this first-mate session with a new, empty one of the same kind, in the same place, without losing work.
Work in progress needs no handover of its own: workers keep running, and the new session picks everything up from durable records at its session start.
What only this session knows is the one thing that would be lost, so this skill saves it first and starts the handover last.
`bin/fm-primary-handoff.sh fresh` owns the commands and refusals; [`docs/primary-handoff.md`](../../../docs/primary-handoff.md#fresh-session) owns the flow.

## Steps

1. Run `bin/fm-primary-handoff.sh fresh check`.
   On `refused: <words>`, tell the captain those words in plain chat and stop; for an inbox note, also acknowledge it and publish the same words with `bin/fm-inbox.sh reply <id>`.
2. Confirm with the captain when the ask came from chat: one plain question, such as "Start a fresh session now? I save what I learned first, and everything under way carries over."
   Go on only on a clear yes.
   An inbox note from the web page or the desk is already the captain's confirmed press, so it needs no second confirmation.
3. Save what this session learned: run the `stow` skill's full pass now, in this turn.
4. Finish the turn's bookkeeping, because `go` ends this session:
   acknowledge a handled inbox note with `bin/fm-inbox.sh drain --ack <id>` and publish `Saved what I learned; a fresh session is starting.` with `bin/fm-inbox.sh reply <id>`, and run any `WAKE_ACK_REQUIRED` command this turn printed.
5. Run `bin/fm-primary-handoff.sh fresh go` as the turn's last command.
   It waits a few seconds before it starts, so the reply below still reaches the captain.
6. On `started:`, end the turn with one line: the fresh session is starting, and everything under way carries over.
   This session closes once the new one confirms it is running.
   On `refused: <words>`, tell the captain those words instead.

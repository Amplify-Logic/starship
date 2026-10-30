---
name: intake-digest-lines
description: >-
  Load whenever the session-start digest, a bootstrap run, or a wake prints a `MORNING_INTAKE:` or `CHANNEL_INTAKE:` line, the morning intake and continuous channel intake that feed the daily to-do page.
  Owns what each of those lines asks for: claiming, completing, failing and acknowledging an intake, reading claimed sources, sending the grouped private alert, and repairing a lost live check.
user-invocable: false
metadata:
  internal: true
---

# intake-digest-lines

The morning intake (`bin/fm-morning-intake.sh`) and the continuous channel intake (`bin/fm-channel-intake.sh`) print these lines through their bootstrap hooks into the session-start digest, and through their live checks into wakes.
Each line prints the absolute command to run, which is the add-on's own copy when the home's add-on carries these tools (`bin/fm-addon.sh`); run that one rather than the same-named script beside this skill.

- `MORNING_INTAKE: <label> due for <date> ...` - the opt-in morning intake is owed and nothing has taken it.
  Take it with `bin/fm-morning-intake.sh claim`, perform the intake, and finish it with `complete --report <path>`; the day is not done until that call verifies the report.
  If the intake cannot be completed, record `fail --reason <text>` rather than leaving it silently unclaimed, so the failure stays visible and the retry budget is honest.
- `MORNING_INTAKE: <label> failed for <date> ...` - a previous attempt failed and the day is still owed while attempts remain.
  Read the recorded reason before retrying, and treat an exhausted budget (`after N attempts`) as a captain-facing blocker rather than a line to retry past; `bin/fm-morning-intake.sh reset` clears the budget only for a deliberate fresh attempt.
  A same-date failure never closes the day, so a corrected source message published after it must still be ingested.
- `MORNING_INTAKE: <label> claim ... stalled ...` - an intake was taken but never completed within its window.
  Reconcile what the previous attempt actually wrote before re-claiming, so a partial report is not silently treated as the day's deliverable.
- `MORNING_INTAKE: new <label> report at <path>` - a completed intake is waiting to be read.
  Read it, relay its findings rather than only that it finished, then run `bin/fm-morning-intake.sh acknowledge <path>` so the same report does not surface at later session starts.
- `CHANNEL_INTAKE: <N> source(s) due for <label> - take them with <path> claim` - the opt-in continuous channel intake has enrolled sources whose poll interval has elapsed.
  Run `bin/fm-channel-intake.sh claim`, read only the sources it hands back through the authenticated connector path, report each message with `observe`, re-read every `recheck:` item it lists under `daily-todo-freshness`, and close each source with `complete --source ID --checkpoint VALUE`.
  A source whose kind is `slack-announcements` follows `docs/channel-intake.md` "Team announcement channels" for which posts it keeps, the `update` class, and the durable updates log entry.
  Before classifying a message as `obligation`, `urgent` or `deadline`, read the rest of its thread for a reply the captain already sent and read the source-side item's own completion state; something already answered with content that discharges it, or already completed at the source, is reported as `routine` rather than opened as a new owed item.
  The gate cannot check either of those - only the connector read sees the thread and the source-side state - so this is the orchestrator's precondition, not a validation it will be stopped by.
  Silence is never completion: an unanswered message and an unclosed source-side item both stay owed, and an acknowledgement or a promise to act is not a reply that discharges anything.
  A read that could not be finished is recorded with `fail --source ID --reason TEXT`, never left unclaimed: the checkpoint advances only behind captured output, so a silent abandon re-reads the same window forever while reporting nothing.
  The gate itself reads no source and sends no message; it decides only when a read is worth doing.
- `CHANNEL_INTAKE: <N> item(s) ready to send|blocked, ...|held, ... for <label>` - notifiable items are waiting on the private direct-message path.
  `ready to send` means render the payload with `bin/fm-channel-intake.sh notify-due`, send that one grouped private message to the configured recipient and nobody else, then stamp it with `notify-sent --keys "..."`; the items are not discharged until that call lands, so an interrupted send re-renders rather than vanishing.
  `blocked, ...` is a configuration refusal and needs the captain: nothing is sent until `notify_recipient` is set and `notify_recipient_verified = true`, which is set only after the recipient has been checked against the known captain account.
  `held, ...` is the rate limit or the daily cap doing its job; report it as deferred delivery rather than retrying past it, and never route around it with a public or channel reply.
- `CHANNEL_INTAKE: source(s) reading unknown for <label>: <ids>` - those sources did not complete their last read.
  That is not the same as nothing new, and it must never be relayed to the captain as a quiet channel; say which sources are dark and since when, using `bin/fm-channel-intake.sh sources` for the per-source freshness and failure detail.
- `CHANNEL_INTAKE: <label> live check is absent|unregistered - re-arm it with <path> arm-check` - the live watcher shim is gone or no longer bound, so the running fleet is only woken at the next session start.
  Run `bin/fm-channel-intake.sh arm-check` to repair it; arming is all-or-nothing, so a failure leaves nothing behind and is a captain-facing blocker rather than a line to retry past.

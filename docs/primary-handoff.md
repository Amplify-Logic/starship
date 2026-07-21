# Primary orchestrator handoff

Quota- and context-aware automated rotation of the Firstmate primary orchestrator.
Opt-in only: absent or disabled `config/primary-handoff` leaves every existing primary launch path unchanged.

`bin/fm-primary-handoff.sh` and its header own the exact commands, flags, state fields, and test seams.
This document owns the atomic-lock protocol, the never-two-holders invariant, the dual trigger axes, and the failure-mode catalog.

## Why

A long-running primary can exhaust a provider's short-window quota, or fill its model context window until every request re-bills a huge resident prompt.
Restart is already a non-event: backlog, task meta, wake queue, and PR polls live on disk under `FM_HOME`.
Handoff reuses that property: flush durable intent, release the session lock only after the outgoing harness is dead, then launch a primary profile through `bin/fm-primary.sh`.

Measured context cost (fleet learning, 2026-07-19): most primary-session spend is re-billing resident context on every request.
Keeping sessions short and rotating before context balloons past roughly half used is the top cost lever this feature automates.

## Configuration

Local, gitignored `config/primary-handoff` is a JSON object.
See [`docs/examples/primary-handoff.json`](examples/primary-handoff.json) and the "Primary orchestrator handoff" section of [`configuration.md`](configuration.md).

Two independent trigger axes share one rotation protocol:

| Axis | Config field | Signal | Default when `enabled: true` | Rotation target |
| --- | --- | --- | --- | --- |
| Quota | `threshold_percent_remaining` | `quota-axi` min general-window remaining | `15` | Next distinct profile in `chain` |
| Context | `threshold_context_percent_used` | `state/.primary-context` used percent | absent = axis disabled | Same profile (fresh session) |

Captain target for the context axis: rotate near ~50% context used (`"threshold_context_percent_used": 50`).
Absent or null `threshold_context_percent_used` leaves quota-only behavior exactly as before the context axis existed.

## Context signal plumbing

Claude Code already feeds `context_window.remaining_percentage` into the status-line command.
`bin/fm-status-bar.sh` parses that field for display and, without changing captain-facing display semantics, also writes a durable sample to `state/.primary-context`:

```text
schema=fm-primary-context.v1
remaining_percent=<0-100>
used_percent=<100 - remaining>
updated_at=<epoch>
```

The handoff supervisor reads `used_percent` out-of-band.
Test seam: `FM_HANDOFF_CONTEXT_USED` overrides the durable sample.

## Same-runtime vs cross-runtime

- **Context trigger** chooses `from == to`: the outgoing primary exits and the same runtime profile respawns with an empty context window.
  Worker panes are independent backend endpoints; they keep running and report through durable `state/<id>.status` and `.meta`.
  The incoming primary picks them up through ordinary session-start reconciliation (restart is a non-event).
- **Quota trigger** still walks `chain` to the next distinct usable profile (cross-runtime).
- When both axes fire on the same check, **quota wins**: a same-runtime refresh cannot restore provider quota.

## Atomic-lock handoff protocol

Hard invariant: two orchestrators must never both hold the per-home session lock (`state/.lock`) as live harness holders.
The session lock file records one PID; the invariant is that at most one live harness process may be that holder at any time, and the handoff must never launch an incoming primary while a live outgoing holder still exists.

Phases recorded in `state/.primary-handoff`:

1. **planning** - Acquire the handoff coordination lock (`state/.primary-handoff.lock`).
   Read `state/.primary-active` and the live session-lock holder.
   Choose the target profile (same-runtime for context, next chain profile for quota, or explicit `--to`).
   Persist the durable intent (`from`, `to`, `trigger`, `token`, `outgoing_pid`) before touching the outgoing process.
2. **flushing** - Hold the wake-queue lock briefly so no mid-append wake record is lost, then release it.
   Durable fleet records are already on disk; this step only serializes the last queue write and stamps the handoff record.
   The session lock remains held by the outgoing harness.
3. **releasing** - Signal the outgoing harness PID, wait until it is not a live harness, then run `fm-lock.sh release-stale`.
   `release-stale` removes `state/.lock` only when the recorded holder is dead or not a harness.
   It refuses while a live harness still holds the lock.
4. **launching** - Re-check the never-two-holders invariant.
   Refuse to launch if the session lock is still held by a live harness.
   Launch the incoming profile through `bin/fm-primary.sh` (or the test launch seam).
5. **complete** - Observe a new live session-lock holder distinct from the outgoing PID, or accept a successful launch seam result in tests.
   Record cooldown metadata so the supervisor does not thrash.
   The incoming primary's ordinary session-start path re-arms the watcher / supervision cycle; a rotation that left the fleet unwatched would be a regression.

The coordination lock serializes concurrent supervisors.
The session lock transfer is strictly ordered: outgoing death, then stale release, then incoming acquire via ordinary `fm-session-start.sh` / `fm-lock.sh` acquire inside the new primary session.

```
outgoing holds lock
        |
   write durable intent (planning)
        |
   flush wake-queue critical section (flushing)
        |
   signal outgoing; wait until dead (releasing)
        |
   release-stale session lock
        |
   assert: no live session-lock holder
        |
   launch incoming primary (launching)
        |
   incoming session-start acquires lock + re-arms supervision
        |
   complete + cooldown
```

## Safety refusals

Unless `execute --force`:

- **Away mode** (`state/.afk`): refuse.
  The away daemon owns supervision then; rotating the primary would fight that ownership.
- **In-progress rotation**: refuse when `state/.primary-handoff` phase is `planning`, `flushing`, `releasing`, or `launching`.
- **Cooldown**: skip after a completed handoff until `cooldown_until`.
  Prevents a primary that starts already above threshold from busy-loop rotating.

## In-flight captain decisions (conversation-only state)

Rotation destroys conversation-only state in the outgoing primary pane.
Anything the orchestrator has not yet written to a durable record (backlog hold, task status, captain preference file, wake queue) is lost.

Chosen tradeoff:

1. Prefer **flushing and deferring** over rotating through an unsafe moment (afk, in-progress, cooldown).
2. The flush gate serializes the durable wake queue so wakes arriving during rotation are not lost.
3. Do **not** invent a heuristic for "mid-chat undecided thought": that state is undetectable and must stay the operator's responsibility.
4. After rotation, the incoming primary reconciles from disk only.
   Escalate or re-ask any captain decision that never landed in a durable record.

## Failure modes

| Failure | Detection | Response | Lock invariant |
| --- | --- | --- | --- |
| Feature disabled / config absent | Config read | No-op exit 0 | Untouched |
| Quota probe missing or unparseable | `quota-axi` / fixture | No quota handoff; context axis may still fire | Untouched |
| Context sample missing | No `state/.primary-context` / override | No context handoff | Untouched |
| Current profile not over either threshold | Metric compare | No handoff | Untouched |
| Away mode active | `state/.afk` | Refuse (unless `--force`) | Untouched |
| Cooldown active | `cooldown_until` | Skip | Untouched |
| Rotation already in progress | Non-terminal phase | Refuse overlapping execute | Untouched |
| No next profile in chain / CLI missing | Chain walk | Abort planning; keep outgoing | Untouched |
| Crash during planning before intent publish | Missing or partial record | Next check starts clean | Outgoing still holds |
| Crash during flushing | Phase `flushing` | Resume refuses launch until release completes; may retry flush | Outgoing still holds |
| Outgoing ignores signal / stays alive | Wait timeout | Phase `aborted`; never launch incoming | Outgoing still holds |
| `release-stale` while live holder | `fm-lock.sh` refusal | Abort; never launch | Outgoing still holds |
| Crash after release, before launch | Phase `releasing`/`launching`, lock free | Retry launch only; never recreate outgoing ownership | Zero live holders until incoming acquires |
| Incoming launch fails | Launch non-zero | Phase `failed`; lock left free/stale for manual recovery | Still at most one holder (zero) |
| Second supervisor races | Coordination lock | Loser exits without mutating session lock | Preserved by serialization |
| Attempted launch while live holder exists | Pre-launch assert | Hard refuse | Preserved |
| Failure injection at any phase | `FM_HANDOFF_INJECT_FAIL` test seam | Abort that phase without advancing past the safety gate | Asserted by tests |

Manual recovery after `failed` or `aborted`: inspect `state/.primary-handoff`, confirm `fm-lock.sh status`, then relaunch a primary with `bin/fm-primary.sh <profile>` once the lock is free or stale.

## Interaction with existing primary launch

`bin/fm-primary.sh` still refuses to start when another live Firstmate session holds the lock.
Handoff depends on that refusal: it never steals a live lock.
When handoff is disabled or `config/primary-handoff` is absent, `fm-primary.sh` behavior is completely unchanged: it does not write the marker.
Only when the config exists with `enabled: true` does `fm-primary.sh` write the lightweight `state/.primary-active` marker on real launches so the supervisor can see which profile is live.
That marker is not a lock and never authorizes mutation.

## Quota-monitored providers only (quota axis)

Auto-rotation via `check`/`run` only triggers the **quota** axis for quota-monitored providers: claude, codex, and grok.
When the active primary is pi, kimi-k3, or opencode, no quota source exists, `min_remaining` reports `na`, and the quota axis never auto-hands-off.
The **context** axis can still fire for any profile that has a durable context sample.
Operators must run `fm-primary-handoff.sh execute --force` (or wait until a monitored provider is active again) to force a quota-style chain walk off an unmonitored provider.
This is an accepted limitation, not a bug.

## Testing

`tests/fm-primary-handoff.test.sh` exercises the happy path, disabled no-op, context-threshold detection, same-runtime rotation, afk refusal, cooldown, workers-survive, watcher re-arm, wake durability across flush, and failure-injection cases that prove the never-two-holders invariant across flush, signal, wait, release, and launch failures.

# Primary orchestrator handoff

Quota-aware automated rotation of the Firstmate primary orchestrator.
Opt-in only: absent or disabled `config/primary-handoff` leaves every existing primary launch path unchanged.

`bin/fm-primary-handoff.sh` and its header own the exact commands, flags, state fields, and test seams.
This document owns the atomic-lock protocol, the never-two-holders invariant, and the failure-mode catalog.

## Why

A long-running primary can exhaust a provider's short-window quota while the fleet's durable state remains healthy.
Restart is already a non-event: backlog, task meta, wake queue, and PR polls live on disk under `FM_HOME`.
Handoff reuses that property: flush durable intent, release the session lock only after the outgoing harness is dead, then launch the next verified primary profile through `bin/fm-primary.sh`.

## Configuration

Local, gitignored `config/primary-handoff` is a JSON object.
See [`docs/examples/primary-handoff.json`](examples/primary-handoff.json) and the "Primary orchestrator handoff" section of [`configuration.md`](configuration.md).

## Atomic-lock handoff protocol

Hard invariant: two orchestrators must never both hold the per-home session lock (`state/.lock`) as live harness holders.
The session lock file records one PID; the invariant is that at most one live harness process may be that holder at any time, and the handoff must never launch an incoming primary while a live outgoing holder still exists.

Phases recorded in `state/.primary-handoff`:

1. **planning** - Acquire the handoff coordination lock (`state/.primary-handoff.lock`).
   Read `state/.primary-active` and the live session-lock holder.
   Choose the next profile in the configured chain.
   Persist the durable intent (`from`, `to`, `token`, `outgoing_pid`) before touching the outgoing process.
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
   incoming session-start acquires lock
        |
   complete + cooldown
```

## Failure modes

| Failure | Detection | Response | Lock invariant |
| --- | --- | --- | --- |
| Feature disabled / config absent | Config read | No-op exit 0 | Untouched |
| Quota probe missing or unparseable | `quota-axi` / fixture | No handoff; log and keep outgoing | Untouched |
| Current profile not over threshold | Metric compare | No handoff | Untouched |
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

## Quota-monitored providers only

Auto-rotation via `check`/`run` only triggers for quota-monitored providers: claude, codex, and grok.
When the active primary is pi, kimi-k3, or opencode, no quota source exists, `min_remaining` reports `na`, and `check` never auto-hands-off.
Operators must run `fm-primary-handoff.sh execute --force` (or wait until a monitored provider is active again) to rotate off an unmonitored provider.
This is an accepted limitation, not a bug.

## Testing

`tests/fm-primary-handoff.test.sh` exercises the happy path, disabled no-op, and failure-injection cases that prove the never-two-holders invariant across flush, signal, wait, release, and launch failures.

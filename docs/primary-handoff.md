# Primary orchestrator handoff

Quota- and context-aware automated rotation of the Firstmate primary orchestrator, and a [fresh session](#fresh-session) on the owner's word.
The automatic rotation is opt-in only: absent or disabled `config/primary-handoff` leaves every existing primary launch path unchanged.
A fresh session needs no config, because the owner's press is the ask.

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
See [`docs/examples/primary-handoff.json`](examples/primary-handoff.json) and the "Primary orchestrator handoff" section of [`fork-configuration.md`](fork-configuration.md).
The quota-rotation example uses `"chain": ["claude-fable", "claude-opus"]` so a Fable primary can hand off directly to Opus.
Both Claude profiles read the shared general windows (`five_hour`, `seven_day`) of the single `claude` provider, and `claude-fable` also reads its own `model:fable` window, so this chain rotates when either the shared windows or the Fable window crosses the threshold.
After rotating to `claude-opus` only the shared windows bound it, so no further quota rotation is expected once they are low: `check` reports `handoff: chain exhausted` and stays put quietly instead of failing on every poll, while the context axis can still refresh the same profile.
The `astra` profile draws on the same single `codex` provider allowance as the `codex` profile, so a `"chain": ["codex", "astra"]` behaves the same way: one model switch, then `check` reports `handoff: chain exhausted` and stays put.

Two independent trigger axes share one rotation protocol:

| Axis | Config field | Signal | Default when `enabled: true` | Rotation target |
| --- | --- | --- | --- | --- |
| Quota | `threshold_percent_remaining` | `quota-axi` min remaining over the provider's general windows and the profile's own model window | `15` | Next distinct profile in `chain` |
| Context | `threshold_context_percent_used` | `state/.primary-context` used percent | absent = axis disabled | Same profile (fresh session) |

Captain target for the context axis: rotate near ~50% context used (`"threshold_context_percent_used": 50`).
Absent or null `threshold_context_percent_used` leaves quota-only behavior exactly as before the context axis existed.

## Context signal plumbing

Claude Code feeds context-window percentages into the status-line command.
`bin/fm-status-bar.sh` displays context used (preferring `used_percentage`, else deriving used from `remaining_percentage`) and also writes a durable sample to `state/.primary-context`:

```text
schema=fm-primary-context.v1
remaining_percent=<100 - used>
used_percent=<0-100>
owner=<lock holder PID>|<process identity>|<optional conversation id>
updated_at=<epoch>
```

The handoff supervisor reads `used_percent` out-of-band only for the current session and a fresh sample; `bin/fm-primary-handoff-lib.sh` owns the binding and freshness checks.
An incoming launch clears the outgoing sample, and legacy samples without an owner are ignored.
Test seam: `FM_HANDOFF_CONTEXT_USED` overrides the durable sample.

## Same-runtime vs cross-runtime

- **Context trigger** chooses `from == to`: the outgoing primary exits and the same runtime profile respawns with an empty context window.
  Worker panes are independent backend endpoints; they keep running and report through durable `state/<id>.status` and `.meta`.
  The incoming primary picks them up through ordinary session-start reconciliation (restart is a non-event).
- **Quota trigger** still walks `chain` to the next distinct usable profile (cross-runtime).
  When no distinct usable successor exists (for example `claude-opus` at the end of the shared-provider Claude chain), `check` prints `handoff: chain exhausted ...` and does not enter a quota rotation or record a failure; it then evaluates the context axis as usual, so a same-profile refresh can still happen.
- When both axes fire on the same check and a quota rotation is possible, **quota wins**: a same-runtime refresh cannot restore provider quota.

## Launch routes

The incoming primary starts where the outgoing one runs, so the owner finds it in the same place.
The route is chosen at planning from the outgoing process and kept in the handoff record, so recovery after the outgoing has exited still knows the way:

- **Herdr:** the outgoing process's own environment names a Herdr pane, and Herdr confirms that pane's shell is its ancestor.
  The incoming starts in that same pane once it is back at an idle shell prompt, else in a new tab of the same workspace, else in a new workspace when that workspace closed with its only pane.
  Every Herdr call names the session the outgoing recorded.
  An environment that names a Herdr pane Herdr cannot confirm refuses before anything is signalled.
- **tmux:** anything else starts a new tmux window from the controller's own tmux, as before the Herdr route existed.
- **Custom:** `FM_HANDOFF_LAUNCH_CMD`, the test and operator seam.

`bin/fm-primary-handoff-lib.sh` "launch routes" owns the exact rules.

## Atomic-lock handoff protocol

Hard invariant: two orchestrators must never both hold the per-home session lock (`state/.lock`) as live harness holders.
The session lock file records one PID; the invariant is that at most one live harness process may be that holder at any time, and the handoff must never launch an incoming primary while a live outgoing holder still exists.

Phases recorded in `state/.primary-handoff`:

1. **planning** - Acquire the handoff coordination lock (`state/.primary-handoff.lock`).
   Read `state/.primary-active` and the live session-lock holder.
   Choose the target profile (same-runtime for context, next chain profile for quota, or explicit `--to`).
   Preflight the launch route and the target profile through the primary launcher's CLI, integration, configuration, and account checks while the outgoing owner remains intact.
   Persist the durable intent and outgoing process identity before touching the outgoing process.
2. **flushing** - Hold the wake-queue lock briefly so no mid-append wake record is lost, then release it.
   Durable fleet records are already on disk; this step only serializes the last queue write and stamps the handoff record.
   The session lock remains held by the outgoing harness.
3. **releasing** - Signal the outgoing harness PID, wait until it is not a live harness, then run `fm-lock.sh release-stale`.
   `release-stale` holds the same acquisition mutex as ordinary session acquisition while checking liveness, removing the stale lock, and cleaning its session identity and handoff acknowledgement.
   It refuses while a live harness still holds the lock.
   The release decision lives in `bin/fm-primary-handoff-lib.sh`, which `fm-lock.sh` executes for that subcommand and without which it refuses the release rather than removing the lock.
4. **launching** - Re-check the never-two-holders invariant.
   Refuse to launch if the session lock is still held by a live harness.
   Dispatch the generation-bound launch entry, which serializes incoming launchers across controller restarts and retains its lifetime lock through the primary launcher's exec.
5. **complete** - Wait under a bounded startup deadline for the actual session-lock acquisition acknowledgement.
   Its token, target profile, holder PID, and process identity must match this attempt and the current live lock owner; command success alone never completes handoff.
   Record cooldown metadata so the supervisor does not thrash.
   The incoming primary's ordinary session-start path re-arms the watcher / supervision cycle; a rotation that left the fleet unwatched would be a regression.

The coordination lock serializes concurrent supervisors, and obtaining it is required before reconciling an interrupted nonterminal record.
If the original owner is still live before release, reconciliation aborts that attempt safely so the next check can start afresh.
A releasing attempt may resume only against the recorded outgoing process identity.
The record persists `shutdown_requested=yes` before the outgoing is signalled and never clears it.
A failed target preflight aborts a live-outgoing attempt only when the record proves no shutdown was requested; otherwise the attempt stays pending, so the replacement launches once the outgoing exits.
With no live owner, recovery resumes the recorded target; an already running launcher is reused, and an already acknowledged replacement is finalized.
An unrelated live owner aborts recovery without receiving a signal.
The same generation gate prevents a delayed duplicate runtime dispatch from starting another incoming primary.
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

- **Away mode**: refuse when the canonical away-contract predicate is true or the legacy daemon/quiet flag exists.
  This includes Pi and supervision-host homes that have no away daemon.
  [`../bin/fm-afk-contract.sh`](../bin/fm-afk-contract.sh) owns the canonical posture predicate.
- **Cooldown**: skip after a completed handoff until `cooldown_until`.
  Prevents a primary that starts already above threshold from busy-loop rotating.

Coordination, generation, and live-owner checks apply even with `--force`.

## Fresh session

A fresh session replaces the first-mate session with a new, empty one of the same profile, in the same place, on the owner's word.
The owner asks for it three ways, and every way asks to confirm first:

- `/fresh` typed in chat, which loads the `fresh` skill; the first mate asks once in chat.
- The **Fresh session** button on the Starship web page ([web.md](web.md#fresh-session)), which asks on the page.
- The `↻ Fresh session` mark on the bridge strip, which takes a second click ([bridge-strip.md](bridge-strip.md#a-fresh-session)), or `starship fresh` in a terminal, which asks y/N ([desk.md](desk.md#a-fresh-session)).

One press runs one flow:

1. `fresh check` says whether a fresh session can start now, or refuses in one plain sentence.
2. From the web page or the desk, `fresh ask` leaves the first mate one captain inbox note asking it to load the `fresh` skill; the press stops nothing itself.
3. The first mate saves what the session learned by running the `stow` skill's full pass, then runs `fresh go` as its turn's last command.
4. `fresh go` starts `execute --fresh` in its own process session after a short grace, so the first mate's reply still lands and stopping the first mate never stops the handover.
5. `execute --fresh` is the same atomic-lock protocol as a context rotation, from the live profile to itself: the old session closes, and the new one starts in the same place and acquires the lock.
   The old session stops before the new one starts, but on tmux its window stays open until the new one holds the lock, so a first mate that is its tmux session's only window keeps that session.
   Work in progress needs no handover of its own: workers keep running, and the new session picks everything up from durable records at session start.

The memory save runs in the outgoing session rather than as a note for the new one, because only the outgoing session holds what was learned in conversation; a new session running `/stow` could only re-read what is already on disk.
The cost is that a press waits for the first mate to reach its inbox, which it does at its next wake.

The live profile is the live lock holder's own launch line, read back against the launch lines `bin/fm-primary.sh` owns, else `state/.primary-active`, which only an enabled handoff config writes and which can go stale once it is disabled.
A manual fresh session ignores the cooldown, because it is an explicit ask, and it never takes `--force`.

Each step refuses, in plain words, while:

- the first mate is in away or quiet mode;
- a merge is under way: `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` each hold a mark for as long as they run (`bin/fm-merge-running-lib.sh`), because stopping the session that started a merge part way through can strand it;
- a handover is already running, or an earlier press from the web page or the desk is still waiting for the first mate (presses from those two only);
- no first mate is running, its profile cannot be read, or there is no launch route.

The first mate's own `check` and `go` never wait behind a press, so a press from the web page or the desk can finish, and `/fresh` still works while an earlier press waits.
When the first mate's own step is refused, it clears the waiting press, so the refusal the owner saw is the only result.

`bin/fm-primary-handoff.sh`'s header owns the exact commands, words, and test seams.

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
| Feature disabled / config absent | Config read | Reconcile any nonterminal attempt, then no-op exit 0 | Untouched unless reconciling |
| Quota probe missing or unparseable | `quota-axi` / fixture | No quota handoff; context axis may still fire | Untouched |
| Quota over threshold, no distinct successor in `chain` | `check` / `run` | `handoff: chain exhausted`, no quota rotation, no failure phase; context axis still evaluated | Untouched unless context axis fires |
| Context sample missing | No `state/.primary-context` / override | No context handoff | Untouched |
| Current profile not over either threshold | Metric compare | No handoff | Untouched |
| Away mode active | Canonical contract or legacy daemon/quiet flag | Refuse (unless `--force`) | Untouched |
| Cooldown active | `cooldown_until` | Skip | Untouched |
| Controller still running | Coordination lock | Refuse overlapping execute | Untouched |
| No next profile / unavailable launch route, CLI, configuration, or account | Chain walk and launcher preflight | Refuse before signalling outgoing | Untouched |
| Crash during planning before intent publish | Missing or partial record | Next check starts clean | Outgoing still holds |
| Crash during planning or flushing after intent publish | Nonterminal record and original owner still live | Abort attempt; a later check may start afresh | Outgoing still holds |
| Outgoing ignores signal / stays alive | Wait timeout | Retain `releasing` for reconciliation; never launch over a live owner | Outgoing still holds |
| `release-stale` while live holder | `fm-lock.sh` refusal | Retain attempt for reconciliation; never launch | Live owner preserved |
| `release-stale` with `bin/fm-primary-handoff-lib.sh` missing | `fm-lock.sh` refusal naming the file | Refuse; never launch; lock left in place | No ownership transfer |
| Crash after release, before launch | Phase `releasing`/`launching`, lock free | Retry launch only; never recreate outgoing ownership | Zero live holders until incoming acquires |
| Incoming launch fails or acknowledgement is delayed | Launch non-zero or startup deadline | Retain `launching`; subsequent checks retry or finalize the same target | No launch over a live owner |
| Controller dies after incoming startup | Matching live acquisition acknowledgement | Finalize the recorded attempt once | Incoming remains owner |
| Unrelated or reused PID owns the home | Lock and process identity differ from record | Abort recovery without signalling it | Unrelated owner preserved |
| Outgoing names a Herdr pane Herdr cannot confirm | Launch route detection | Refuse before signalling | Untouched |
| Fresh session while away, while a merge is under way, or while a handover runs | `fresh` refusals and `execute --fresh` | Refuse in plain words, exit 3 | Untouched |
| Second supervisor races | Coordination lock | Loser exits without mutating session lock | Preserved by serialization |
| Attempted launch while live holder exists | Pre-launch assert | Hard refuse | Preserved |
| Failure injection at any phase | `FM_HANDOFF_INJECT_FAIL` test seam | Abort that phase without advancing past the safety gate | Asserted by tests |

For manual recovery, inspect `state/.primary-handoff` and confirm `fm-lock.sh status`.
Nonterminal attempts are reconciled by `check`, `execute`, and `run`; older terminal `failed` records still require a manual primary launch once the lock is free or stale.

## Interaction with existing primary launch

`bin/fm-primary.sh` still refuses to start when another live Firstmate session holds the lock.
Handoff depends on that refusal: it never steals a live lock.
When handoff is disabled or `config/primary-handoff` is absent, `fm-primary.sh` behavior is completely unchanged: it does not write the marker.
Only when the config exists with `enabled: true` does `fm-primary.sh` write the lightweight `state/.primary-active` marker on real launches so the supervisor can see which profile is live.
That marker is not a lock and never authorizes mutation.

## Quota-monitored providers only (quota axis)

Auto-rotation via `check`/`run` only triggers the **quota** axis for quota-monitored providers: claude, codex, grok, and cursor.
A cursor-grok primary is read from its cursor plan windows (`included_usage` and `auto_usage`), not from the model- or bot-scoped windows quota-axi also reports for that account.
When the active primary is pi or opencode, no quota source exists, `min_remaining` reports `na`, and the quota axis never auto-hands-off.
The **context** axis can still fire for any profile that has a durable context sample.
Operators must run `fm-primary-handoff.sh execute --force` (or wait until a monitored provider is active again) to force a quota-style chain walk off an unmonitored provider.
This is an accepted limitation, not a bug.

## Testing

`tests/fm-primary-handoff.test.sh` also covers the fresh session (no config, the profile read back from every launch line, each refusal, the single inbox ask, and `go` in its own process session) and the Herdr route against a stand-in Herdr: the same pane, a new tab or workspace when the pane closed, and a refusal when Herdr cannot confirm the pane.

`tests/fm-primary-handoff.test.sh` uses synthetic holders and runtime stubs to exercise stale-release/acquisition races, preflight refusals, delayed and unrelated ownership acknowledgements, controller death at durable phase boundaries, recovery without duplicate launches, the happy path, disabled no-op, context-threshold detection, the cursor-grok quota mapping and its general-window selection, the `claude-fable` model-window rotation to `claude-opus`, same-runtime rotation, afk refusal, cooldown, workers-survive, watcher re-arm, wake durability across flush, and failure-injection cases that prove the never-two-holders invariant across flush, signal, wait, release, and launch failures.

# Watcher continuity

This document explains how Firstmate keeps the watcher re-armed after a wake, how wakes are ordered and acknowledged, and which tests and live evidence cover that contract.
Read it when debugging a supervision gap or changing a harness's re-arm path.

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.
In this document, an arm is one run of `bin/fm-watch-arm.sh`, which starts a watcher cycle or attaches to one and returns the cycle's reason.

| Topic | Section |
| --- | --- |
| Which component re-arms the watcher on each harness | [Ownership](#ownership) |
| What happens between an actionable close and the wake reaching the model | [Actionable wake ordering](#actionable-wake-ordering) |
| How a watcher-downtime episode is announced and retired | [Recovery episode acknowledgement](#recovery-episode-acknowledgement) |
| How each actor consumes the wake queue | [Per-actor acknowledgement](#per-actor-acknowledgement) |
| What `bin/fm-watch-arm.sh` guarantees about each cycle | [Arm-layer cycle contract](#arm-layer-cycle-contract) |
| Which test suites pin these contracts | [Regression coverage](#regression-coverage) |
| What is not guaranteed, and where live evidence lives | [Active limits and verification](#active-limits-and-verification) |

## Ownership

On Pi, omp, OpenCode, Cursor, and Claude primaries, one component owns re-arming the watcher.
Codex and Grok keep their own protocols; see [Manual recovery and other harnesses](#manual-recovery-and-other-harnesses).

| Harness | Re-arm owner |
| --- | --- |
| Pi | `.pi/extensions/fm-primary-pi-watch.ts` |
| omp | `.omp/extensions/fm-primary-omp-watch.ts` |
| OpenCode | `.opencode/plugins/fm-primary-watch-arm.js` |
| Cursor | `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) |
| Claude | `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) |

On a non-Pi primary, a home opted into the supervision host also changes what the owner runs; see [Supervision host](#supervision-host).

### Pi, omp, and OpenCode adapters

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter:

- Starts the next arm before delivering the wake prompt.
- Checks current session-lock ownership at launch.
- Preserves one child or scheduled retry at a time.
- Applies bounded exponential retry after an unexpected or failed close.

A failed follow-up never cancels continuity restoration.

### Pi session replacement

Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`:

1. `session_shutdown` changes the current generation's durable extension marker from `active` to `handoff`, but keeps its established arm child alive.
2. The owning `session_start` publishes a distinct active generation.
3. That `session_start` commits its tracked replacement arm.
4. Only after that commit does the replacement arm retire the predecessor.

A state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including:

- A main follow-up Pi accepted but had not yet consumed.
- Branch handling.
- A retiring child that reports after the successor claim.

A handoff marker never satisfies the extension-ownership tolerance.
So a running Pi process whose replacement did not load this extension is reported as missing, rather than borrowing stale load evidence from its predecessor.

A main follow-up counts as delivered once Pi accepts it, never once the model reads it.
The reason is that a follow-up queued while main is streaming joins the running run without a `before_agent_start`.
The extension header owns how consumption is observed and why it only decides what a replacement replays.

### omp session replacement

omp's replacement follows its own generation-owner contract in `.omp/extensions/fm-primary-omp-watch.ts`, whose header owns its differences from Pi:

- It retires the predecessor arm at replacement shutdown instead of retaining it across the handoff.
- It reports no shutdown reason, so every shutdown with a pending actionable close persists the handoff for the next owning `session_start` to replay.

### Cursor stop hook

Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary.
It re-arms by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up.
[`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.

### Claude Stop hook

Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop.
On each Stop, an eligible primary with supervision need admits one home-scoped owner, which foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

### Claude session-lock ownership

The hook handles the session lock as follows:

- A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes.
- A live owner the session does not own, an absent lock, or a malformed lock keeps the competing hook inert.

Whether the session owns that lock is the shared `fm_session_lock_owned_by_self` verdict in `bin/fm-session-lock-lib.sh`.
That verdict accepts either of two cases:

- A recorded pid inside the current harness ancestry.
- A live lock recorded under this same trusted Claude session id.

With that verdict, a background session keeps arming after its transient helper chain is recycled.
[`turnend-guard.md`](turnend-guard.md#guard-predicates) owns the Claude guard's behavior when that live owner is genuinely another session.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.

### Claude arm failures

After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
The beacon is `state/.last-watcher-beat`, which only the watcher process touches.

- A cycle-end failure is benign when that live-watcher predicate is true.
  In that case the hook suppresses the arm output and continues silently.
- Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode.
- A refused notice commit stays silent for a later retry.
- After a successful notice, later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.

The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).

### Supervision host

On a non-Pi primary, a home opted into the supervision host runs `bin/fm-supervision-host.sh` in place of the arm its re-arm owner would start.
The host owns successive watcher cycles through the same arm.
It starts and confirms each successor before its engine handles an away wake, and it stops its cycle before handing a wake back.
So the recovery and acknowledgement contracts below apply unchanged ([supervision-host.md](supervision-host.md)).

## Actionable wake ordering

This section covers what each re-arm owner does between an actionable close and the wake reaching the model.

### Pi, omp, and OpenCode successor start

After an actionable Pi, omp, or OpenCode child close, the adapter:

1. Waits for the predecessor process to close.
2. Starts and verifies one singleton successor.
3. Confirms the handling handoff against that successor before scheduling the follow-up.
4. Delivers the original wake.

A complete Pi reason line can be observed while the predecessor is still finishing durable cleanup.
That line is retained for replacement handoff, but the adapter never treats that already-ready predecessor as its own successor.

If the handoff confirmation fails, the adapter retries it once against the current generation and successor.
A failed confirmation is a restoration failure: the adapter classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.

### Readiness timeout and retry

The adapter waits at most one readiness timeout per attempt.
If the successor is not ready in that time, the adapter sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.

If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, the adapter delivers the original wake with a typed continuity-restoration failure, even if every successor arm hung without reporting readiness.

This is deliberate Option B ordering.
Whenever restoration succeeds, the fleet is protected before the model handles the wake.
When restoration does not succeed, the model is never left blind.

### Claude handling successor

Claude's Stop hook also starts one handling successor before notification.
After an actionable foreground close, including an attached peer cycle that ended, the hook:

1. Launches `bin/fm-watch-arm.sh` with the closed arm's pid as `FM_WATCH_PREDECESSOR_ARM_PID`.
2. Waits for that arm's one status line.
3. Only then exits 2 with the wake.

A child of the hook cannot outlive its exit-2 rewake.
So that successor is the one deliberate detached launch in the continuity path:

- It runs under nohup.
- Its stdio is away from the hook's pipes.
- It has its own process group.

This is the shape `bin/fm-startup-network.sh` uses, and [`verification/supervision.md`](verification/supervision.md#detached-session-open-workers-survive-the-hook) verified that it survives the hook.

The next Stop's foreground arm attaches to that live cycle.
A successor that confirms no live watcher adds one line to the rewake banner and never withholds the wake.
The next Stop then re-arms as before.

### Durable queue and turn-end backstop

The durable wake queue preserves actionable events between a watcher close and the next drain.
The bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding.
So a finished, hung, or identity-mismatched claim cannot suppress that recovery ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).

The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce.
It enters its poll loop immediately and keeps scanning signals, stale panes, and checks.

### Manual recovery and other harnesses

- The model no longer re-arms after ordinary wakes.
- No PreToolUse hook denies fleet commands based on watcher status.
- A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
- Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
- Codex retains its bounded foreground checkpoint protocol.
- Grok retains its tracked background-task notification protocol.

No adapter starts a replacement with a fire-and-forget shell `&` from a model command.
The Claude hook's detached handling successor is launched by the hook itself, which waits for the successor's status line before it exits.

The turn-end guard remains the final backstop rather than the normal continuity mechanism.
In its `--claude` mode it cooperates with the auto-arm.

## Recovery episode acknowledgement

A recovery episode is one generation of the `state/.watcher-down` marker.
It is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.

### Announcement

An unacknowledged downtime generation is announced at most once.
The first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch.
It mints a fresh generation so buried decisions still resurface once.

### Generation reuse

Every watcher close and every durable queue append publishes downtime.
So a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and from trapping later arms in repeated recovery presentation.

### What an acknowledgement retires

An acknowledgement carries two separable facts:

- Queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below).
- Only retiring the episode is bound to `--recovery-generation`.

A generation mismatch therefore does not block consumption of rows through that sequence.
It is a non-fatal result that names its own remedy: re-drain, then acknowledge the newer episode.

The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff.
It uses the `fm_lease_actor` identity owned by `bin/fm-lease-lib.sh`.
The Pi branch extension injects its branch actor into its own bash tool calls.

### Claiming rows

Every presented row is claimed to exactly one actor under the durable queue lock.

- Main records its presented set in `state/.main-eligible-rows`.
- A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`.
  The grant is bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`.
  Publication is refused if main already claimed any requested row.
- A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
- A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.

### Lock deadlines during presentation

An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.

| Lock with a live holder | Drain result |
| --- | --- |
| Initial queue lock | One PID-naming advisory, and the whole drain is skipped before any claim or mutation. |
| Status-presentation lock | One such advisory after raw wake presentation, and status annotations, sections, and cursors are left retriable on the next drain. |

Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics, so acknowledgement atomicity is unchanged.

### Guard counts for branch-held rows

Because the main drain's exclusion makes branch-granted rows invisible to main, `bin/fm-guard.sh`'s queued-wake warning counts only the rows the calling actor can itself present or retire.
So an actor is never sent to a drain that provably has nothing for it.
`bin/fm-wake-lib.sh` owns that per-actor count (`fm_wake_actor_pending_count`) alongside the grant row-list and owner-record reads that the drain and `bin/fm-wake-grant.sh` share.

A row a live grant reserves is therefore never counted as drainable for main.
Rather than going silent about a visibly non-empty queue, the guard prints a distinct advisory.
That advisory names the live supervision branch as the holder and says not to drain those rows from here.

The branch actor's queued-wake output stays suppressed in every case.
A main drain with nothing of its own left, and a live grant still holding the queue, says so in one bounded line instead of exiting silently.

### Structurally unusable rows

A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff.
A main drain retires such a row under the queue lock.
It reports how many it removed, together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record.
A branch drain never retires them, because a grant can only name sequences that were structurally valid when it was published.

A retirement that cannot be read or written is reported and never fails the drain.
The rows that remain usable are still presented with their acknowledgement command, and the unusable ones stay queued for a later drain to retire.
Failing the whole drain would strand the usable rows too.

### Acknowledgement cutoffs

| Acknowledgement | What it deletes |
| --- | --- |
| Main `--ack-through <SEQ>` | Only claimed main rows at or below the cutoff. |
| Branch | Only claimed branch rows at or below its cutoff. |

A main acknowledgement first claims every unreserved row at or below its cutoff, so none is stranded.
It leaves a row above the cutoff that arrived after presentation unowned, so an away-session grant can still take it rather than handing every later wake back to main.

Every settled branch prompt releases any residual grant.
So an omitted or failed acknowledgement leaves the durable row available to a later main drain.
A successful acknowledgement has already removed it.

An acknowledgement can remove none of the actor's rows while a presented row above the cutoff still waits.
Such an acknowledgement is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row.
The presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.

If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.

### Branch eligibility and check rows

[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.

A check-kind row is main-owned in every mode, including a heartbeat review.
So it is never part of a branch claim and never defers one.
Main is woken for it on that check's own triggering close.

`fm-wake-drain.sh` never reclassifies a row itself.
It filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.

### Per-actor regression tests

`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts and check that:

- Branch acknowledgement cannot swallow a main row.
- A concurrent main turn cannot present or acknowledge an active branch grant.
- A no-op stale acknowledgement names the current presented wake's exact command.
- Live-holder presentation contention stays bounded and retriable.
- Acknowledgement locking remains blocking.

The same suite pins the counted-equals-presentable invariant against `bin/fm-guard.sh` and `bin/fm-wake-drain.sh` together:

- A branch-held row raises the held advisory rather than the ordinary queued-wake warning for main.
- That row is presented with its acknowledgement command - with the ordinary warning restored - as soon as the grant clears.
- Structurally unusable rows are retired by main alone while every remaining row stays presentable and acknowledgeable.

`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.

### How an arm resolves a close

| Child return | What the arm does |
| --- | --- |
| Actionable output | Returns that reason normally. |
| Zero/empty | Rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger. |

An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one.
It does this because it holds no handle on the watcher's stdout and cannot read the reason line itself.

### Terminal-delivery ledger

Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero, even after its durable wake was handled and acknowledged.
An unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

### Cycle exit log

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes:

- Arm and watcher PIDs.
- Start and end timestamps.
- Exit code and signal.
- Classified reason.
- Beacon age.
- Lock identity before and after close.
- Successor disposition.

The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

### Grace, beacon, and stop signals

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`.
No helper process can make a wedged watcher appear healthy.
An arm whose own script path sits under a disposable no-mistakes validation checkout (`.no-mistakes/worktrees/`) refuses with the typed failure line before touching any state, because a watcher started there outlives the validation step and keeps writing the real home's state from a checkout about to be deleted.
Once per poll the watcher checks that its home, its state directory, and its own code root still exist, and exits with a logged reason when one is gone, scoped to itself alone, so a torn-down temporary home or a discarded checkout never leaves an orphan watcher behind.
The watcher uses bash's native fatal handling for HUP and TERM, including during a blocked poll, so both run its EXIT cleanup.
`watcher_stop_signals` in `bin/fm-watch.sh` owns the signal-handling rationale.

## Session-start first-run scoping

The session-start allowance is scoped to a genuinely first invocation, closing the previously documented mid-session re-run gap.
`bin/fm-lock.sh` treats a recorded holder PID equal to the current harness PID as a successful re-acquire, so before this scoping a mid-session re-run of `bin/fm-session-start.sh` also passed this gate, re-acquired the lock, and ran bootstrap's five mutating sweeps - including the secondmate liveness sweep's `fm_backend_kill` plus respawn recovery action, which `bin/fm-bootstrap.sh` scopes to "session start (reboot/restart) only".
The gate now passes the shared session-lock relation (`fm_session_lock_relation()` in `bin/fm-primary-scope-lib.sh`, the same harness-identity and contiguous-ancestry predicate `bin/fm-sessionstart-nudge.sh` consumes through `fm_session_lock_in_ancestry()`) into `bin/fm-continuity-command-policy.mjs`.
A lock-free home - no lock file, an unreadable or non-numeric holder, or a dead holder - keeps `bin/fm-session-start.sh` a recovery command, exactly the genuine first run including crash recovery over a stale lock.
A live holder matching the current process or its contiguous verified-harness ancestry means this session already ran session start, and a live harness holder outside it means another session owns the home; either way the attempt is denied with the canonical outage summary, and the deny guidance for other fleet commands stops naming the once-per-session entry point.
The wake-drain, watcher-arm, ordinary literal teardown, and exact sentinel-enable allowances are independent of session-lock ownership and unchanged.

The scoping is a gate over one harness's Bash tool calls, not the mutation authority itself: the session lock remains what actually gates bootstrap's mutating sweeps, and "run session-start exactly once per session" remains a behavioral contract owned by AGENTS.md section 3.
The relation inherits the ancestry walk's own bounds - at most eight parents, matching `bin/fm-lock.sh` - and recognizes harness identity through the evidence tiers `bin/fm-primary-scope-lib.sh` owns and documents, while refusing to cross a non-harness gap into an unrelated ancestor session.

## Claude background-shell pressure reap

Claude Code 2.1.193 and later can terminate a main-session background shell when the runtime reports memory pressure.
By default that reap also waits until 30 minutes have passed since the last user interaction, with no turn or subagent running.
A freshly armed watcher therefore gets no 30-minute grace once the captain has already been away that long.
The watcher arm, the watcher, caffeinate, and the event-wait helper share one process group, so that signal takes the whole supervision cycle down together.
`bin/fm-primary.sh` exports `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` for both `claude-fable` and `claude-opus` so the tracked arm remains the live wait.
tmux crewmates do not inherit the primary's `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP` export (verified 2026-09-09).
`bin/backends/tmux.sh` creates the worker with `tmux new-window` and then send-keys, so the pane environment comes from the tmux server, not from the primary process.
This home runs herdr, not tmux, and the herdr spawn path was not live-tested for this variable.
From spawn code, `bin/fm-spawn.sh` does not put this variable on the herdr launch line and does not unset it.
The Claude worker launch prefix sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000` and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` (see `docs/configuration.md` "Context window").
A herdr worker pane otherwise inherits the launching environment for `FM_HERDR_PROJECT_*`, which is why spawn pins or clears those two variables, but that is not evidence for this pressure-reap export.
Whether a herdr crewmate receives the export is therefore untested.
A Claude secondmate runs its own supervision cycle, so its watcher arm is a tracked background shell of an interactive Claude session and is reapable exactly as the primary's was.
`bin/fm-spawn.sh` therefore carries `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` on the Claude launch line for `kind=secondmate`, on every backend, because the pane environment comes from the backend rather than from the launching primary.
Ordinary crewmates and scouts arm no watcher, so they stay on Claude's default and the disable is deliberately not applied to them.
The launch-line placement is what carries it on the verified tmux path; whether a herdr pane would also have inherited it remains untested, as above, so the herdr secondmate case rests on the explicit launch-line export rather than on inheritance.
The launcher header owns the exact primary export, and `bin/fm-spawn.sh`'s `launch_template()` owns the secondmate one.
A Claude primary started outside that launcher must export the same variable by hand before launch.

Host status is two separate claims, and only the first rests on this fleet's own evidence.
Verified on macOS, Claude Code 2.1.193 and later: the dated evidence is the 2026-09-03 herdr-killsweep-scout report and the 2026-09-04 `state/.watch-cycle-exits.log` cluster of 44 `arm-interrupted` TERM exits.
Unverified on Linux: Linux is a real firstmate target and the launcher export is unconditional, so a Linux primary gets it, but this fleet has never reproduced the watcher-arm reap on a Linux host.
Unverified is not the same as ignored or harmless there: Claude Code 2.1.266 still registers `process.on("memoryPressure")` for a tracked background shell in any interactive session unless `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP` is set, with no Darwin-only branch, and [claude-code#78674](https://github.com/anthropics/claude-code/issues/78674) reports the same reaper on Linux.
On Linux the export is therefore a precaution against a mechanism that is demonstrably present, not a mitigation whose effect on this fleet's watcher arm has been observed.
The host-level sentinel below still assumes the watcher can disappear for other reasons.

## Host-level outage sentinel

This mitigation still bounds detection outside the harness process tree.
The Claude pressure-reap disable above does not cover every way a watcher or away daemon can disappear.

Both supervision entries idempotently register `bin/fm-supervision-sentinel.sh` as a per-home macOS launchd agent, and both register only after observing an identity-matched live watcher with a fresh beacon.
`bin/fm-watch-arm.sh` registers at most once per arm, once it has observed and reported a healthy watcher.
Away mode is not exempt: `bin/fm-afk-start.sh` `exec`s the daemon, so the registration belongs to `bin/fm-supervise-daemon.sh`, which registers only once it has observed the watcher it started as healthy.
That daemon runs for days, so only a verified registration latches: a failure schedules another attempt on the housekeeping cadence, doubling to a `AFK_SENTINEL_RETRY_MAX_DEFAULT` cap (300 seconds, overridable with `FM_AFK_SENTINEL_RETRY_MAX_SECS`), so no transient launchd failure can leave the unattended window without host outage detection.
The one exception is a capability the host does not have - a non-Darwin host, a missing `launchctl`, a missing `/usr/bin/shasum` - which `arm` reports with its own exit status so it is never inferred from an ambiguous error: the daemon then stops attempting for that session, records one `unsupported` row saying the away session ran with in-session guards only, and deliberately does not mark itself armed, because an unsupported host is unprotected.
A deliberate no-op - a home disarmed mid-away, sentinel mode off, a non-primary scope - is reported with its own distinct exit status too: the daemon neither latches it as armed nor treats it as a failure, appends no ledger row, leaves an already-open gap open for the return catch-up to surface, and keeps its base-cadence retry so a mid-away `enable` is observed and verified normally.
Both the retry and its `fm_watcher_healthy` probe are gated to that same cadence, so a home whose watcher never becomes healthy cannot make the daemon pay a multi-fork predicate on its one-second loop tick.
Whether a host alarm covered a given away stretch is not re-derivable once the daemon is gone, so every transition is appended to `state/.supervision-sentinel.away-gap` and folded into the return catch-up as `host-alarm` evidence by `bin/fm-afk-return.sh`, which is also the only owner allowed to clear it.
An unprotected stretch is therefore visible after the captain returns even when it was already repaired, and a stretch that never closed is visible as an open record.
The generated job sets `RunAtLoad`, so a bootstrap or kickstart runs a scheduled check immediately; registering before the watcher is confirmed would deliver a real `SUPERVISION DOWN` alert for the very outage that entry is ending - on every reboot, since the `gui/<uid>` agent is gone while task metadata survives.
The alarm's premise is that supervision was healthy and then stopped, so a home never observed healthy has no outage to report and stays unregistered until one is.
launchd invokes its one-shot `scheduled-check` mode every 60 seconds outside the harness process tree.
Only that entry point updates `state/.supervision-sentinel-last-check`; the marker-only `note-outage` and `check` modes cannot certify that launchd is alive, and neither of them ever fires an external channel.
It writes that proof as soon as it has resolved this home and read its supervision state - the whole claim the proof makes - and deliberately not after alert delivery: registration waits a bounded `FM_SENTINEL_CHECK_WAIT_SECS` for the proof, while delivery is bounded only per channel, so a slow notifier would otherwise make a healthy launchd service read as a registration failure.
When launchd retains the service but no scheduled check ever lands, the arm path records `state/.supervision-sentinel.arm-failure` and skips further launchd mutation for an exponentially growing per-home cooldown instead of paying a bootout, a bootstrap, and a bounded liveness wait on every watcher and away-mode entry.
That cooldown has its own bounds (`FM_SENTINEL_ARM_RETRY_SECS`, 60 seconds, doubling to `FM_SENTINEL_ARM_RETRY_MAX_SECS`, one hour), separate from the repeat-alert schedule.
It still fails the arm and still warns that the host alarm is unavailable, and because it suppresses retries it leaves the home unmonitored - so every later session start prints a `HOST SUPERVISION SENTINEL - REGISTRATION FAILED` banner naming the remaining suppression window and the `bin/fm-supervision-sentinel.sh enable` recovery command, exactly as a deliberate disarm is surfaced.
An explicit `enable` bypasses the cooldown for one real attempt; only a verified registration clears the record, so a failed `enable` preserves the evidence and its escalating count rather than resetting to a first failure.
The arm path and the session-start banner both read that record through one shared helper (`fm_supervision_arm_failure_status` in `bin/fm-supervision-lib.sh`), which treats a deadline beyond its own recorded window as stale evidence suppressing nothing, so a clock rollback or a restored state volume neither blocks retries forever nor advertises a suppression window that is not enforced.
The in-harness turn-end and continuity guards keep blocking a blind turn end throughout, so a suppressed host registration degrades the backstop rather than removing it.
The check reuses `fm_supervision_status` plus `fm_watcher_healthy`, so it requires the existing home-scoped watcher lock, PID identity, watcher path, and fresh beacon rather than trusting a leftover file or live PID alone.
Lock home and watcher path are compared by physical target, so a checkout reached through a symlinked path component cannot make a live watcher look foreign to a host check that resolved its own root differently; two genuinely different homes still never match.
Future-dated beacon timestamps are rejected rather than remaining fresh indefinitely after wall-clock rollback or restore.
With the default 300-second grace, a stale-beacon outage becomes an active alert within at most roughly 360 seconds instead of remaining silent for hours.
A missing or dead identity-matched lock is detected on the next host check even while the beacon is still fresh.

The sentinel writes `state/.supervision-outage-alarm`, posts through the channels owned by [`wedge-alarm.md`](wedge-alarm.md), and deduplicates one continuous outage.
The first repeat waits five minutes by default, then repeats back off exponentially to a one-hour cap instead of firing at one unchanging cadence forever.
That backoff belongs to one episode, keyed on the watcher lock pid and beacon evidence.
When the key changes - the watcher was re-armed and reaped again between two host checks - the outage is genuinely new, so the repeat schedule resets and the alert fires on the next check instead of inheriting a delay of up to an hour.
Only an unchanged, continuous outage keeps backing off.
The marker distinguishes pending delivery from a successful alert, so a failed channel retries on the next host check after a short claim lease without consuming the repeat schedule.
That short lease applies to a new episode too, which keeps a delivery still in flight from being duplicated while deferring the new alert by at most the lease.
The launchd label is derived from `FM_HOME`, so sibling firstmate homes never share a service identity.
Its plist runs only `fm-supervision-sentinel.sh scheduled-check`.
It contains no watcher arm, daemon launch, signal, process sweep, or restart command.

`bin/fm-supervision-sentinel.sh disarm` is the only supported uninstall path.
It boots out only the exact home-scoped launchd service and writes `state/.supervision-sentinel.disarmed`; ordinary harness closure, session end, task cleanup, and watcher shutdown never invoke it.
While that record exists, automatic watcher and away-mode entry does not silently re-enable the service, and every session-start digest prints a loud disabled-state notice.
The session owner must deliberately run `bin/fm-supervision-sentinel.sh enable` to restore and verify the service before the durable record is removed.

No automatic recovery is attempted.
A launchd process cannot recreate the harness completion notification that wakes firstmate after an ordinary watcher reason, and it cannot safely infer the away-mode daemon's supervisor target.
Starting either owner from launchd could race the existing singleton or create a second supervision cycle while `state/.afk` assigns ownership to the daemon.
The sentinel therefore makes the outage bounded and loud while leaving recovery to the existing home-scoped, identity-checked paths.
Linux and other hosts retain the hook alarms but do not yet have a verified host scheduler; watcher entry reports that limitation in a genuine primary home, and stays silent in a child task worktree or non-primary home exactly as macOS does.
On such a host the marker-only guard modes are the only writers of `state/.supervision-outage-alarm`, so they refresh unclaimed evidence whenever the outage episode or in-flight count moves rather than freezing on the first outage ever observed; a claim or committed delivery owned by a scheduled host check is never overwritten.
The launchd transport itself is covered by an opt-in real-`launchctl` smoke rather than the default suite; see [`wedge-alarm.md`](wedge-alarm.md) for how to run it and what remains transport-unverified until it is.

## Filesystem-event continuity

Glasses mailbox and bridge-inbox wakes survive the intentional one-shot watcher boundary through `state/.last-check`.
On startup and at the top of every later watcher loop, including the loop after a bounded wait timeout, `bin/fm-watch.sh` asks `bin/fm-file-event-lib.sh` whether any current default watch path is newer than the last completed authenticated-check sweep.
A newer path removes the marker before the cadence test, so authenticated checks run in that same loop instead of waiting for another filesystem event or the 300-second backstop.
The live waiter still compares signatures around each bounded wait, which covers a write racing catch-up with waiter setup.
Each watcher loop captures a private marker before filesystem catch-up and publishes that boundary only when an authenticated check sweep completes, so unchanged paths do not fire twice while a later write remains newer for the next loop or successor.
This catch-up is part of the existing singleton watcher cycle and does not add another watcher, change lock ownership, or alter the one-actionable-reason exit contract.
Both the catch-up and the forked terminal wait are reached through guarded calls, so a checkout without `bin/fm-file-event-lib.sh` runs the watcher's own `event_wait_or_sleep` and its ordinary check cadence instead.
`bin/fm-file-event-lib.sh` also checks that shape once each time it loads, which for the watcher is once per start and never per cycle: `fm_fork_assert_watcher_hook_shape` walks the watcher beside it, and if any fork call has escaped its guard or the terminal wait has lost its else branch it names the line on stderr and disables the override by replacing the fork's terminal wait with a direct call to the watcher's own `event_wait_or_sleep` and making the catch-up a no-op, so the watcher always still has a wait even when its call site is the thing that broke.
`fm_fork_assert_watcher_hook_shape` is the single owner of that check, and `tests/fm-file-eventwait.test.sh` proves it by running the function against the real watcher and against deliberately broken copies that have lost a guard or the else branch.
`docs/bridge-view.md` owns the separate glasses existence-only watcher-check guidance.

## Regression coverage

### Pi and OpenCode watch extension

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops.
It then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, and:

- Blocks prompt delivery to prove the successor launches first.
- Verifies single-flight behavior.
- Changes the session lock before close to prove ownership is rechecked.
- Hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.

The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, plus:

- Same-instance shutdown-plus-start.
- The predecessor remaining live under a handoff generation until its replacement commits.
- Bounded retry after that replacement kills the predecessor but fails before readiness.
- Automatic re-arm before any model turn.
- A fresh extension-module rebind carrying all in-flight actionable closes exactly once.
- Stale prior-generation callbacks.
- Repeated transitions with exactly one live cycle.
- Disappearance of the shutting-down refusal after a valid replacement activates.
- Terminal quit still refusing late rearm.

The guard and session-start suites prove that active generation evidence tolerates a fresh-beacon handoff.
They also prove that a legacy or handoff-phase watcher marker from an absent replacement extension still raises the outage diagnostic.

### Arm, recovery, triage, and lock suites

`tests/fm-watch-arm.test.sh` covers:

- Durable queue replay.
- Real remote parent-replies ingestion into the authoritative status log.
- Decision-only OPEN DECISIONS recovery.
- Interrupted handling replay.
- Generation-bound acknowledgement.
- A persistent live successor after recovery.
- A watcher close inside the handling window that must leave the printed acknowledgement valid.
- A re-arm whose recovery cycle is slowed after confirmation and must still surface rather than read as a watcher that stayed live.
- The self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
- The disposable-checkout arm refusal.
- The home-gone and state-gone watcher exits.
- The test reaper that stops a watcher armed for a temporary home.

`tests/fm-watch-recovery-loop.test.sh` covers:

- The once-per-generation announcement bound with the real Pi extension against a refused handling handshake.
- A handling successor that must surface a real crew event instead of going blind.

`tests/fm-watch-triage.test.sh` proves TERM stops a watcher blocked inside a poll's pane capture and still releases its lock and records an acknowledgeable stop.
It also checks that a newly appended keyed decision is classified without rereading earlier status bytes, so signal handling can return to the watcher's beacon refresh even when the status history is long.

`tests/fm-watcher-lock.test.sh` covers:

- Verified-successor attach.
- Recovery publication before stale-lock removal.
- The typed self-eviction failure.
- Bounded and successor-linked lifecycle rows.
- A SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.

### Claude auto-arm and turn-end guard

`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.

`tests/fm-claude-stop-autoarm.test.sh` covers:

- The auto-arm's scope.
- Stale and live session owners.
- Unchanged AFK and need boundaries.
- Single-flight.
- Bounded failure retries.
- Benign live-watcher cycle ends.
- One-notice failure episodes.
- Exit-2 translation.
- The handling successor an ended attached cycle starts with the closed arm as its predecessor and that outlives the rewake.
- An unconfirmed successor reported in the banner without withholding the wake.
- Host-timeout HUP/TERM/INT translation into the same durable failure handoff.

It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim.
[`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.

`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh`:

1. Starts with the reproduced stale-lock state.
2. Receives session start through the tracked SessionStart hook.
3. Completes two tokenless cycles.
4. Checks the competing-live-owner negative control.

`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including:

- Monotonic failed-epoch progression.
- The integrated bounded fail-open.
- Post-alarm continuation suppression.
- Positive recovery reset.

[`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed, because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.

The other harnesses rely on these mechanisms:

- Claude depends on the Stop `asyncRewake` rewake.
- Cursor depends on its awaited stop-hook park.
- Grok retains native background-completion notifications.
- Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current cross-harness live evidence, the dated Stop-owned Claude auto-arm results, and exact opt-in commands.

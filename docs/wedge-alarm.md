# Supervision active alert channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS` (the pane is genuinely busy or wedged, or its Enter is swallowed), `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash, guarded by `if [ "$backend" = tmux ]`.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend it was skipped entirely.
On 2026-07-10 a `claude`-on-`herdr` primary wedged past max-defer overnight: the tmux flash was skipped, and only the passive `state/.subsuper-inject-wedged` marker was written.
Nothing surfaces that marker until the next fleet action, so 20 escalations sat buffered for roughly 8.5 hours with no active alert.
The classifier-side half of that incident shipped separately (PR #429); this is the alarm-channel half.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

The same channel owner now carries host-level watcher-outage alarms from `bin/fm-supervision-sentinel.sh`.
That sentinel is registered with macOS launchd by the always-on watcher arm and by the away-mode daemon, each only after it has observed a healthy watcher; it then runs outside the harness process tree once a minute and alerts when tasks are in flight without an identity-matched watcher lock and a fresh `state/.last-watcher-beat`.
Every report says `SUPERVISION DOWN` and carries the beacon age, the grace window, and the in-flight task count.
The outage marker is `state/.supervision-outage-alarm`.
The turn-end guard and Claude continuity gate write that marker through `note-outage`, a marker-only mode, and never fire a channel: an in-harness hook must return its blocking result immediately, so only the scheduled host check crosses this boundary.
The operator-facing `check` mode is marker-only for the same reason, so `scheduled-check` really is the single owner of external delivery, and every mode returns early on a deliberately disarmed home.
Being marker-only does not make `check` silent: it prints its verdict on stdout - an unambiguous `OK - ...` line when the home is idle or healthily watched, or the `SUPERVISION DOWN` summary plus a note that external delivery is still pending and host-owned - and exits non-zero only on a detected outage, so an operator or agent gets an answer without reading the marker file.
It also reports a suppressed launchd registration, and `note-outage` stays completely silent so a blocking hook banner is never delayed.
A continuous outage repeats after five minutes by default, then backs off exponentially to a one-hour cap so a persistent failure remains visible without training the captain to ignore a fixed-cadence alarm.
The backoff is scoped to one episode: when the watcher lock or beacon evidence changes because the watcher recovered and was reaped again, the schedule resets and the new outage alerts at once rather than inheriting an hour-long delay.
A failed channel leaves delivery pending and retries on the next host check after a short claim lease; only a successful channel advances the backoff.

## Channels

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive (used by the tests).

- `off` - position-independent kill switch that disables every active alert; the marker and tmux flash remain.
- `auto` / `default` - platform default. macOS resolves to `osascript`; other platforms have no built-in OS channel, so `auto` there fires nothing and logs that the durable marker is the only signal (configure a `command:` directive instead).
- `osascript` - a macOS Notification Center banner via `osascript`.
  OS-level delivery reaches the captain even when every pane and its status-line is unreadable.
  The title identifies either `firstmate: away-mode escalations WEDGED` or `firstmate: SUPERVISION DOWN`.
- `herdr` - a herdr UI notification via `herdr notification show`. herdr's own surface, separate from the pane and its status-line.
- `command:<cmd>` - run `<cmd>` via `sh -c`, with the alarm summary passed as `$1` and on stdin. Lets the alert reach a phone or pager (ntfy, Slack, SMS) even when the captain is away from the machine entirely.

An absent `config/wedge-alarm` behaves as `auto`, i.e. default-on on macOS.
Default-on is deliberate: an away-mode injection wedge or a dead watcher must not stay silent, so the reachable OS channel fires unless the captain explicitly disables it.
The injection alarm is rate-limited to at most once per max-defer window.
The host sentinel emits once per outage episode, then repeats on an exponential five-minute-to-one-hour backoff while that same outage persists.

Each channel is best-effort: a missing binary or a non-zero exit logs a warning and the alarm falls through to the next channel, never crashing the daemon loop.
Every invocation is also process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS` (10 seconds by default), including `command:`, `osascript`, `herdr`, and an `FM_WEDGE_ALARM_EXEC` override.
On timeout or daemon shutdown, its watchdog terminates the notifier group, logs the timeout when applicable, and continues to the next configured channel.
The AppleScript passes the summary as an `argv` item rather than interpolating it into the script source, so summary text can never break the notification.
See `docs/examples/wedge-alarm` for a copyable starting config.

## Host fallback and recovery boundary

The launchd sentinel is intentionally an alarm, not a second supervision cycle.
It never calls `bin/fm-watch-arm.sh`, starts `bin/fm-supervise-daemon.sh`, or signals a recorded process.
A generic launchd job cannot recreate the harness-native completion notification that makes an ordinary watcher wake firstmate, and it cannot safely reconstruct the away-mode daemon's supervisor-pane target.
Starting either process from the fallback could race the existing singleton lock or violate the daemon's ownership of the watcher while `state/.afk` exists.
The fallback therefore detects and reports an outage within the 300-second grace plus the 60-second launchd interval, while the existing home-scoped recovery path remains authoritative.
There is no broad process kill anywhere in this path.

launchd registration is idempotent and home-scoped through a SHA-256 label derived from canonical `FM_HOME` and state paths.
The arm path compares the loaded manifest digest and reloads only that exact service when its script path, interval, or environment changes.
Service identity is therefore a function of durable configuration alone: the manifest pins the durable 300-second default beacon grace rather than the ambient `FM_GUARD_GRACE` of whoever ran the arm, so a one-off `FM_GUARD_GRACE=30 bin/fm-watch-arm.sh` can neither reconfigure the host check's outage threshold for every later scheduled run nor move the digest and force a bootout/bootstrap on the next ordinary arm.
`FM_GUARD_GRACE` therefore governs the in-session guards and arm health checks only, never the scheduled host check; `docs/configuration.md` states that divergence where the variable is defined.
It also requires a recent `state/.supervision-sentinel-last-check`, kickstarting the exact service and refusing registration if no scheduled one-shot check completes within `FM_SENTINEL_CHECK_WAIT_SECS` (15 seconds by default).
A host that retains the service but never completes a check cannot converge - a job that cannot resolve its own home under the pinned minimal PATH looks exactly like this - so each failure is recorded in `state/.supervision-sentinel.arm-failure` and the next arm skips all launchd mutation until an exponential per-home cooldown expires.
That cooldown has its own bounds, `FM_SENTINEL_ARM_RETRY_SECS` (60 seconds) doubling to `FM_SENTINEL_ARM_RETRY_MAX_SECS` (one hour), deliberately separate from the repeat-alert schedule: changing how often a continuous outage re-alerts must not change how long a broken registration goes unretried.
The record stores both the computed `retry_at` deadline and the `retry_after_secs` window it came from, and `fm_supervision_arm_failure_status` in `bin/fm-supervision-lib.sh` is the single reader both the enforcing arm path and the reporting session-start banner use, so the displayed window can never drift from the enforced one.
A `retry_at` that is unreadable, or further out than the `retry_after_secs` recorded atomically beside it, is stale evidence that suppresses nothing - that is how a wall-clock rollback or a state volume restored from a machine whose clock ran ahead is prevented from either blocking retries indefinitely or advertising an enormous suppression window nothing honors.
That cooldown never reports success and never claims host monitoring is healthy: the arm still fails, watcher entry still warns that the host alarm is unavailable, and **every later session start prints a `HOST SUPERVISION SENTINEL - REGISTRATION FAILED` banner** with the remaining suppression window and the recovery command.
A suppressed registration disables host monitoring exactly as effectively as a deliberate disarm, so it is surfaced exactly as loudly.
An explicit `enable` bypasses the cooldown for one real attempt, but only a verified registration clears the record: a failed `enable` keeps the evidence and its escalating count.

When another arm for the same home already holds the registration lock, this arm waits out that holder's own convergence bound instead of declaring the alarm unavailable while registration is still succeeding.
If that wait expires it makes one short attempt to take the lock over, because the holder is itself a harness-tracked process and a holder reaped mid-registration leaves the lock behind with no failure record at all; `fm_lock_try_acquire` reclaims only a lock whose owner pid is provably gone, so this can never evict a holder that is still converging.
Failing that, it never reports success it did not earn: it names the concrete missing evidence - launchd is not holding the exact service, or the service is loaded but no scheduled check has completed recently enough to prove it can observe this home - so the caller's warning says what to repair rather than that something generic failed.
In-harness guard checks use the marker-only `note-outage` entry point, never write that launchd-health proof, and never wait on an external notifier.
The job receives a fixed minimal system PATH rather than persisting the harness process PATH.
The job runs only `bin/fm-supervision-sentinel.sh scheduled-check`; its plist contains no restart command.
Registration lives in the current logged-in macOS GUI domain, which is the lifetime that also owns the interactive harness sessions; the next watcher arm re-registers after a new login.

Explicit `bin/fm-supervision-sentinel.sh disarm` removes only this home's exact service and leaves `state/.supervision-sentinel.disarmed` for every later session-start digest to surface.
No ordinary harness closure, session end, task cleanup, or watcher stop calls disarm, and automatic arm attempts respect the durable record.
Every check mode respects it too, including the marker-only ones, so a disarmed home accumulates no new outage evidence and fires no channel.
The launchd-spawned scheduled check still records its local `state/.supervision-sentinel-last-check` liveness proof before honoring the disarm record, because that marker is what `enable`'s bounded registration wait observes; it is a local file, never an alert, so the disarmed home stays silent on every external channel.
Only deliberate `bin/fm-supervision-sentinel.sh enable` restores the service and clears that record after launchd health is verified.
It does not claim outage coverage across logout, reboot, system sleep, a missing state volume, or launchd failure.
Other operating systems keep the existing turn-end and continuity alarms but currently have no verified host scheduler, and every surface says so instead of claiming an external fallback.
A positively proven missing host capability - a non-Darwin host, a missing `launchctl`, or a missing `/usr/bin/shasum` - is reported by `arm` with its own exit status (`FM_SUP_SENTINEL_UNSUPPORTED_EXIT`), so a long-lived caller can stop attempting what can never succeed while every ambiguous failure keeps exit 1 and stays retryable.
The away daemon stops retrying on that status but never marks itself armed, and records one `unsupported` row stating the away session had in-session guards only; `check` prints the same limitation beside its verdict, so an unsupported host is never rendered as protected.
A deliberate no-op - a durably disarmed home, `FM_SUPERVISION_SENTINEL_MODE=off`, or a non-primary scope - likewise gets its own exit status (`FM_SUP_SENTINEL_NOOP_EXIT`), so exit 0 always means a verified registration: a caller never latches a deliberately unprotected home as protected, never closes an away host-alarm gap on it, and never spends failure records or retry backoff on a refusal that was on purpose.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `FM_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/fm-supervise-daemon.sh`).
This keeps tests from posting a real desktop notification:

- Whenever the daemon is sourced, its library-mode guard defaults `FM_WEDGE_ALARM_EXEC` to `discard`.
- `tests/wake-helpers.sh` upgrades that default to an on-disk recorder that logs `<channel>\t<summary>` to `$FM_WEDGE_ALARM_LOG`.
- The host-sentinel suite executes one-shot alert mode through the same recorder.
- Its title-argv test unsets the seam only after shadowing `osascript` with a file-writing fake.
- Its opt-in real-launchd smoke does not use this seam at all, because a launchd job's environment is fixed at plist-write time and `fm_sentinel_write_plist` deliberately has **no** notifier-override knob.
  Instead it launches a *copy* of the sentinel inside the scratch home, next to a stub `fm-supervise-daemon.sh` that only appends its argv to a file.
  The sentinel resolves its alert owner beside itself, so the launched process has no path to the real daemon - and therefore none to any real notifier - regardless of what any config lookup does.
- Production plist generation carries no notifier override, and `test_arm_registers_one_home_scoped_read_only_launchd_job` asserts the generated manifest contains no `FM_WEDGE_ALARM_EXEC`.
  This is deliberate: `FM_WEDGE_ALARM_EXEC` replaces *every* channel before any real notifier, so a manifest carrying one would redirect that home's whole external-alert path for as long as the service stayed loaded, and an override that exited non-zero would leave `delivery=pending` and retry silently forever - the exact silent-outage class this sentinel exists to remove.
- Production leaves `FM_WEDGE_ALARM_EXEC` unset, so the real channels fire.

The automated tests verify channel selection, summary propagation, and the title/body argv shape without posting a notification.
The real `osascript`/`herdr` delivery mechanism was verified once by the bounded manual run below.

## Verifying the launchd transport (opt-in, not yet run)

Every default test in `tests/fm-supervision-sentinel.test.sh` drives registration through a fake `launchctl`, so the fake proves the arm/reconcile/disarm logic but not that a real `gui/<uid>` agent runs and delivers.
`test_real_launchd_scheduled_check_delivers_end_to_end` closes that gap end to end over the real transport: it builds a scratch primary home under `TMPDIR`, derives the exact SHA-256 service identity before registering anything, runs a real `launchctl bootstrap`, waits for a launchd-spawned `scheduled-check` to record host liveness, and asserts the outage summary reached the alert owner and the marker committed `delivery=sent`.
Its no-real-notification safety is structural rather than configured: launchd runs a *copy* of the sentinel from the scratch home's own `bin/` (alongside copies of only the three libraries it sources), and the sentinel resolves its alert owner as `fm-supervise-daemon.sh` next to itself - which in that copy is a stub that only appends to a file.
The real daemon is not reachable from the launched process, so no config-lookup failure and no `auto` → `osascript` fallback can turn the smoke into a real banner, and no notifier-override knob has to exist in production for it to work.
That safety is also the limit of the claim: the smoke proves the job reaches an alert owner at the expected path, not that the real daemon's notifier body works under launchd (see the split lists below).
It is gated on `FM_SENTINEL_REAL_LAUNCHD_SMOKE=1` plus macOS plus `/bin/launchctl`, and it skips with an explicit reason otherwise.
The gate is deliberate: the smoke mutates the caller's own `gui/<uid>` launchd domain, so it must be an attended choice rather than something CI or a parallel shard does implicitly.
An `EXIT`-registered teardown boots out that one derived label and fails loudly with the exact `launchctl bootout` command if the service somehow survives; it never sweeps other labels.

```
FM_SENTINEL_REAL_LAUNCHD_SMOKE=1 tests/fm-supervision-sentinel.test.sh
```

**This smoke has not been run yet, and no evidence for it is recorded below.**
It was authored but not executed here, because bootstrapping even a scratch agent writes into the user's `gui/<uid>` launchd domain, which is outside the boundary this change was allowed to touch.

A successful run would establish, against real launchd rather than a fake:

- that `launchctl bootstrap` in `gui/<uid>` accepts the generated plist and honors `RunAtLoad` plus `StartInterval`,
- that `fm_primary_scope_matches` resolves `git` on the pinned `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` job PATH,
- and that a launchd-spawned check can write `state/` and invoke an alert owner at the expected path with `--active-alert` and the outage summary.

The structural stub that makes the smoke safe also bounds what it can prove, so these stay unverified even after a successful run:

- the real `bin/fm-supervise-daemon.sh --active-alert` body under launchd - its `FM_WEDGE_ALARM_LOG_FILE` setup, `wedge_alarm_notify` channel resolution, the `set -m` process-group watchdog in `wedge_alarm_run_bounded`, and `trim_log` - because the smoke launches a stub at that path instead,
- and that `osascript display notification` is delivered and TCC-attributed the same way from a launchd agent as from the interactive shell recorded in the manual run below, since no real notifier runs in the smoke at all.

Verifying those two would require a run that lets the real daemon post a real banner from a launchd agent, which is deliberately not what this test does.
Until then, treat the launchd half of this backstop as logic-verified but transport-unverified, and treat the notifier body under launchd as unverified regardless of whether the smoke has been run.
The in-harness turn-end and continuity banners do not depend on any of it: they are covered by hermetic tests and remain authoritative on their own.

## Verification (macOS, darwin)

Recorded 2026-07-10T12:41-0700 on macOS 26.5.2 (build 25F84), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.3.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "FIRSTMATE TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (manual verification of the argv-safe mechanism)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
    -e 'end run' "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "FIRSTMATE TEST - IGNORE" was posted with the label as its body.
Production now passes both body and title as argv items to the same AppleScript mechanism.
The away-mode title is `firstmate: away-mode escalations WEDGED`, while the host sentinel uses `firstmate: SUPERVISION DOWN`.
`tests/fm-supervision-sentinel.test.sh` verifies the two-item argv shape against a fake `osascript` and never posts a real banner.

### herdr channel

```
$ herdr notification show "FIRSTMATE TEST - IGNORE" \
    --body "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr reported `"shown":true`.
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" fm-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.

# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows session start, wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing `bin/fm-session-start.sh` stops the gate self-blocking the one command AGENTS.md section 3 mandates as a session's first, since a fresh session has tasks in flight and no live watcher by definition.
The deny guidance keeps the two entry points distinct rather than pointing every denial at a once-per-session command: `bin/fm-wake-drain.sh` is the action that is always safe mid-session, and `bin/fm-session-start.sh` is named only when the hook process's own ancestry does not already hold the home session lock.
That is a two-branch guidance text, not two decisions: a session that already holds the lock is told to drain, tear down, and re-arm without being pointed back at an out-of-contract mid-session re-run, while a genuine pre-lock session still gets the session-start clause.
The ancestry test is `fm_session_lock_in_ancestry()` in `bin/fm-primary-scope-lib.sh`, one owner shared with `bin/fm-sessionstart-nudge.sh` so the nudge and this gate cannot drift on what "already ran session start" means.
The recovery set is keyed on the executed command word, so a direct `bin/fm-bootstrap.sh` stays denied while the `bin/fm-bootstrap.sh` that `bin/fm-session-start.sh` runs inside its own process is allowed with it; session start acquires the per-home session lock first, and holding that lock is what gates bootstrap's mutating sweeps.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard adapters are unchanged, while the shared guard alarm now uses the canonical outage summary from `bin/fm-supervision-lib.sh`.
The Claude continuity denial uses that same summary, so both surfaces name every in-flight task and report elapsed time from `state/.last-watcher-beat`, or explicitly report an unknown duration and unknown start when the beacon evidence is missing, unreadable, unsupported, or future-dated.
The turn-end guard remains the final backstop rather than the normal continuity mechanism.

## Known limitation

The session-start allowance is not restricted to a genuinely first invocation, and this gate's allow/deny decision does not try to detect one.
`bin/fm-lock.sh` treats a recorded holder PID equal to the current harness PID as a successful re-acquire, so a mid-session re-run of `bin/fm-session-start.sh` — not only the fresh case where no lock exists yet — also passes this gate, acquires the lock, and runs bootstrap's five mutating sweeps.
The gate's own trigger condition is watcher liveness, which is independent of session-lock ownership, so the classification does not distinguish the two cases from where it sits.
The deny guidance does distinguish them with `fm_session_lock_in_ancestry()`, so a session that already holds the lock is no longer told about session start at all.
Applying that same ancestry test to the allow/deny classification is beyond this fix's risk budget: it is a deliberate scope deferral rather than a technical limitation, and remains a deferred follow-up.

That is accepted rather than patched now, for two reasons.
The session lock, not watcher liveness, is the actual mutation authority for those sweeps.
And "run session-start exactly once per session" is a behavioral contract owned and enforced by AGENTS.md and agent discipline, not by a PreToolUse gate; a half-enforced first-invocation check here would be less trustworthy than this stated limitation.

A re-run does exceed the documented contract, so the blast radius is stated plainly rather than minimized.
AGENTS.md section 3 scopes session start to once per session, and `bin/fm-bootstrap.sh`'s secondmate liveness sweep scopes itself to "session start (reboot/restart) only" with a mid-session secondmate death explicitly out of scope.
The practical consequence is that this gate transitively permits mutations it denies when invoked directly.
The most destructive of them is that sweep's own recovery action: for any secondmate whose liveness probe reads confidently dead, it runs `fm_backend_kill` and then respawns through `bin/fm-spawn.sh <id> --secondmate` (`bin/fm-bootstrap.sh:447-448`).
It also includes the `bin/fm-visible-status.sh --all` Herdr presentation projection, whose cursor-worker `model_live=` meta write is owned by [`cursor-harness.md`](cursor-harness.md), and the secondmate reread nudges that bootstrap performs inside its own process.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
It also asserts both guidance branches verbatim, and that a session holding the home lock still gets the identical allow/deny decisions, so the ancestry test can only ever change guidance text.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
That run's captured system message named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
The recovery guidance has since gained the conditional session-start clause described above, so the string this gate emits today for a pre-lock session is longer than the one that dated run recorded.
`tests/fm-claude-continuity-live-e2e.test.sh` asserts both current strings verbatim and is the place to read them: the credentialed turn covers the pre-lock branch, and a direct lab invocation with a recorded lock holder covers the lock-held branch.
Refreshing this dated capture would take a fresh credentialed run of that opt-in test.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.

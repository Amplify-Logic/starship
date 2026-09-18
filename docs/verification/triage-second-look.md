# Status second look verification

Repeatable evidence for the opt-in second look over the status lines the deterministic wake classifier drops.
Current behavior and the operator-facing contract are owned by [`../configuration.md`](../configuration.md) ("Status second look"), the invocation and exit codes by [`../../bin/fm-triage-second-look.sh`](../../bin/fm-triage-second-look.sh)'s header, and the request shape, questions, thresholds and tier rule by its engine; this page records evidence only.

Date: 2026-09-17.
Shell: GNU bash 3.2.57 (macOS 25.5.0, Darwin arm64).
Model: `jev-1.13.0`, pinned rather than an alias.

This host has neither `timeout` nor `gtimeout`, so every run recorded below took
`fm_run_timed`'s perl mechanism. A host that has either one takes the external
mechanism instead, which bounds the engine differently; that path is not covered
by the console output on this page and is asserted by the portable suite instead
(see the external-timeout case below), because it is the mechanism every Linux
home and this repository's own CI runner select.

## Portable suite, network stubbed

`tests/fm-triage-second-look.test.sh` (34 assertions) drives the real classifier, the real request build and the real thresholds, stubbing only the HTTP response.
It covers the span reader (dropped lines emitted, already-escalating lines never handed over, `paused:`/`captain-held:`/`resolved:` declarations never eligible, the 0/1/2 returns matching the actionable sibling, and the read completing with every endpoint pointed at a closed port); the gate (absent, malformed value, unknown key, read from `FM_CONFIG_OVERRIDE` when one is set rather than from the home, the home resolved through `FM_ROOT_OVERRIDE`, and `--dry-run` previewing the request on an unarmed home while the live path still refuses); the request (pinned model, the dropped line and no other task state - the brief's intent, the worker kind and earlier status lines all stay on the machine - one batch for the whole scan, the batch bound, no already-escalating line reachable, and the key absent from both streams); the rule applied to the recorded 2026-09-17 probe response (8 promotions and 0 false promotions, `g05` promoted by `adverse_event` alone at 0.76 while `needs_captain` sat under threshold at 0.38, zero confidence demoting `alert` to `digest` rather than silencing, and every promotion carrying a tier and a reason - the scores are the recording's, so these cases hold the rule fixed, not the model's answers); every fail-open path (no key, malformed body, answerless body, unreachable endpoint, one unusable answer inside an otherwise good batch, an unusable condition or urgency answer never vetoing the conditions that did fire, unreadable answers reported on stderr rather than passing for a quiet verdict, and the call-site bound); the batch reaching the engine with `timeout` on PATH, so the bounding mechanism a host happens to select cannot leave the capability silently inert; and the away-mode daemon call site (armed escalation with its reason, unarmed home adding nothing, empty scan making no call, an unusable answer reaching the daemon log rather than /dev/null, a promoted heartbeat dispatched as the heartbeat it is rather than as an unknown wake, the away scan re-promoting lines the watcher already marked surfaced because it keeps its own offset marker, and one scan building one digest however many alert-tier lines it promotes).

The same file also covers the always-on watcher call site, driving a real `bin/fm-watch.sh` subprocess: an unarmed home absorbs the heartbeat and advances its backoff exactly as before, and an armed home turns the same absorb into a heartbeat wake whose payload names the promoted line and `adverse_event`, leaves the line the second look silenced out of the wake, and still records the log surfaced through its end so the next heartbeat does not re-fire it; a backstop heartbeat carrying no promotion keeps the ordinary heartbeat key, so nothing can collapse onto a promotion queued earlier.
These three cases sit here rather than in `tests/fm-watch-triage.test.sh` because `fail()` ends a test file, and a timing-sensitive case elsewhere in that file could end the run before this capability was ever exercised.
`tests/fm-wake-queue.test.sh` holds the other half of that property at the queue itself, where wake-row collapse lives: a promotion keeps its payload past a later bare heartbeat, and two distinct promotions queued before one drain both survive it because each is keyed by its own payload, while bare heartbeats still collapse to one.

```console
$ bash tests/fm-triage-second-look.test.sh | tail -3
ok - an unarmed home adds nothing to the away-mode escalation buffer
ok - an unusable answer reaches the daemon log rather than /dev/null
ok - a scan with no dropped lines makes no call and escalates nothing
```

## Live guard against the real API

The stubbed suite catches a change on this side.
It cannot catch one on the vendor's - a pinned model that stops answering, an answer shape that moves, a question read differently after an upgrade - so `tests/fm-triage-second-look-live-e2e.test.sh` makes one real batched call.
It is opt-in because it spends money, and it fails rather than passing vacuously when no key is available.
Its assertions are about the contract, not about exact probabilities, because a model answers a shade differently run to run and a pinned number would make the guard flap.

```console
$ FM_TRIAGE_SECOND_LOOK_LIVE_E2E=1 FM_TRIAGE_SECOND_LOOK_ENV_FILE=~/starship/.env \
    bash tests/fm-triage-second-look-live-e2e.test.sh
ok - the pinned model answers live and still separates the two ends of the fixture set
```

The same four lines through `bin/fm-triage-second-look.sh` directly, 2026-09-17T21:26:54Z:

```console
$ printf '...four dropped lines...' | FM_HOME=<armed home> bin/fm-triage-second-look.sh
live	alert	needs_captain+adverse_event	working: the backfill migration truncated public.users on staging before I caught it; 4100 rows gone
live	digest	needs_captain	working: the only queue tier that handles our burst is the $400/month plan, signing up needs a card
```

Destroyed data promoted at the interrupt tier, a spend the captain owns promoted to the next batch, and both `working: rebased onto main and reran the suite, all green` and `working: the nightly job costs about $12/month on this tier, well inside the existing plan` left silent.
That last one is the narrowest case in the set and the one the `needs_captain` false criterion ("merely mentions costs or external systems as findings") was written to hold down.

Refresh this page by rerunning the two commands above after a model upgrade or a question change.
Re-measuring the carried-over probe numbers below needs the live probe re-run against the shipped line-only request, which has not been done.

## Measurements carried over from the probe

These are the 2026-09-17 scout measurements the thresholds were set from, not re-measured here.

They were taken against the request as it stood that day, which carried the task's goal from its brief, its worker kind and up to three preceding status lines alongside the dropped line, and against the two question texts that referred to that goal.
The shipped request carries the dropped line alone, so every number below describes the richer request rather than the one this home now sends.
Nothing re-measures them: the regression suite replays a recording keyed by synthetic tag, so it cannot observe the request and a question or payload change leaves its verdicts unchanged.
What still holds under test is the promote rule itself - the three ORed conditions and the tier thresholds applied to those recorded scores.
Over 16 realistic status lines the shipped classifier drops: 8/8 captain-worthy lines caught, 0/8 false promotions, stable across 5 repeats, 8,257 input plus 1,380 output tokens, 1.03s wall, $0.000347 at $42/Btok.
Batched against per-line on the same set: 8,257 versus 12,217 input tokens, 1.03s versus 11.47s, $0.000347 versus $0.000513.
An adversarial line instructing the supervisor to treat it as a critical blocker scored `needs_captain` 0.51-0.60 and was wrongly promoted 5/5 times when sent alone, and 0.23-0.27 and correctly silent 5/5 times when sent beside its 15 peers, which is why one request per scan is a safety property and not only the cheaper shape. That contrast was measured on the richer request too; batching is kept for it, but the margin has not been re-measured on the line-only request.
Under the escalate-only design the worst that isolated failure could achieve is one extra line in a digest.

# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The serial table, the `serial-hint` rows, was refreshed on 2026-11-28 from five green main CI runs: [46119657668](https://github.com/Amplify-Logic/starship/actions/runs/46119657668), [46117758204](https://github.com/Amplify-Logic/starship/actions/runs/46117758204), [46101040413](https://github.com/Amplify-Logic/starship/actions/runs/46101040413), [46049978933](https://github.com/Amplify-Logic/starship/actions/runs/46049978933), and [46040399536](https://github.com/Amplify-Logic/starship/actions/runs/46040399536).
Each row is that script's median successful `duration_ms` across the five runs' uploaded portable serial timing artifacts; every one of the 415 serial members had five successful samples.
A median is a typical duration, not a worst case: a slow run can take a shard a few minutes past its modeled sum, which stays well inside the 30-minute job cap.
Serial hints used to be the slowest sample per script, but that stopped fitting the packing target: `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` alone measured 1025772-1270927 ms across those runs, above the 1200000 ms target, and the slowest samples together needed more than eighteen shards, so no shard count could pass the coverage guard.
Before this refresh, provisional and stale serial hints had packed serial shards 6 and 13 at about 24 and 26 minutes of median work while the typical shard held about 17 to 18.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` is the one exception: it retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
A script that joins the lane later carries a provisional hint until the next refresh replaces it with a CI median.

The parallel table, the `parallel-hint` rows, keeps the slowest successful `duration_ms` per script.
It was refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457), using their uploaded portable timing artifacts and completed `FM_TEST_END` log markers.
It was refreshed again on 2026-11-08, when each row kept the larger of its previous value and the slowest successful `duration_ms` across green main run [42504916826](https://github.com/Amplify-Logic/starship/actions/runs/42504916826) and PR runs [42519113644](https://github.com/Amplify-Logic/starship/actions/runs/42519113644), 42527277677 (both attempts) and 42531129942; the parallel set then summed to about 3377 seconds, so it moved to three lanes.
Observed maxima provide conservative packing weights, not an upper bound on future durations.
A failed script's duration is excluded even when its lane uploaded an artifact, and a cancelled job's wall time is only a lower bound whose unfinished scripts have no completed sample.
`tests/fm-park.test.sh` is a portable parallel member; its 70085 ms parallel hint is its completed passing Ubuntu `FM_TEST_END` sample from CI run [42730709201](https://github.com/kunchenguid/firstmate/actions/runs/42730709201), and `tests/fm-arm-pretool-check.test.sh` moved to parallel lane 2 to keep the lanes within 5%.
The T3 Code backend suites `tests/fm-backend-t3code.test.sh` (239245 ms) and `tests/fm-t3-mcp.test.sh` (57613 ms) carry the slowest successful Ubuntu samples from CI runs [39463576576](https://github.com/kunchenguid/firstmate/actions/runs/39463576576), [39814995718](https://github.com/kunchenguid/firstmate/actions/runs/39814995718), and [39883948163](https://github.com/kunchenguid/firstmate/actions/runs/39883948163).
Those two run in the portable parallel lanes: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

The supervision-host suite outgrew any one shard as a single file: this fork's run 37147855677 of the earlier repository measured 1672244 ms, and the creator's run [39642852135](https://github.com/kunchenguid/firstmate/actions/runs/39642852135) measured 1192918 ms while sitting alone in a serial shard, and its run 39765114423 cancelled that script at the 30-minute job cap.
The suite is therefore four serial members so no one file occupies a whole CI shard, sharing the stub-engine fixtures in `tests/supervision-host-helpers.sh`.
`tests/fm-supervision-host-drain.test.sh` covers the report surface, dispatch, and BRANCH OUTCOMES.
`tests/fm-supervision-host-hook.test.sh` covers the Claude Stop-hook re-arm and hand-back.
`tests/fm-supervision-host.test.sh` covers the host loop's wakes, closes, mirror, and return.
`tests/fm-supervision-host-park.test.sh` covers the latch, park boundary, compaction, and lock ownership.
Hints are not a formality: a script packed on the 45000 ms default can land beside a shard already holding most of the target and take that shard toward its job cap while the coverage guard still passes.
`test_portable_serial_packing_budget_boundary` pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
Do not discount a local speedup from CI packing weights; wait for CI to measure it.

## Parallel lanes

The three parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
This fork's duration values (`parallel-hint` rows) and ordered lane memberships (`parallel-lane` rows) live in [`tests/fork-test-timing.conf`](../tests/fork-test-timing.conf), which [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) reads as an overlay on its own `portable_parallel_weight_hints` and `list_portable_parallel_<k>` tables; [`bin/fm-fork-test-registry-lib.sh`](../bin/fm-fork-test-registry-lib.sh) owns the row grammar and overlay rules, and the lane's own test header owns any lane-specific prerequisite.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the largest and smallest lane sums to differ by no more than five percent of the largest.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh the `parallel-hint` rows with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n`, which this fork sets with the `serial-shards` row in `tests/fork-test-timing.conf`, and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints, this fork's being the `serial-hint` rows in `tests/fork-test-timing.conf`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The watch-triage suite is three serial members so no one file occupies a whole CI shard: `tests/fm-watch-triage.test.sh` (classifier, signal/turn-end absorb, wedge ladder, gone endpoints, TERM, busy-pane age, timer repair, procevent, heartbeat/afk hand-off, exit picker), `tests/fm-watch-triage-pause.test.sh` (declared waits, captain-call holds, pause transitions, away/quiet holds, paused-until and background-job waits), and `tests/fm-watch-triage-wedge-defer.test.sh` (wedge-threshold deferrals).
The split replaced a 1074843 ms single file that sat in a serial shard with about 27.8 minutes of tests against the 30-minute job cap, measured on run [40280579086](https://github.com/kunchenguid/firstmate/actions/runs/40280579086).
The packing estimates are per-script medians from a few runs, not measured rebalanced jobs, a P95, or a guarantee of future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `serial-hint` rows in `tests/fork-test-timing.conf` with the median successful `duration_ms` per `path`, keeping the native-Windows exception in [Verification inputs](#verification-inputs):

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R Amplify-Logic/starship --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | LC_ALL=C sort -t$'\t' -k1,1 -k2,2n \
  | awk -F'\t' '{ v[$1, ++n[$1]] = $2 } END { for (p in n) { c = n[p]; m = (c % 2) ? v[p, (c + 1) / 2] : int((v[p, c / 2] + v[p, c / 2 + 1]) / 2); print "serial-hint", p, m } }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Use green runs only: a timed-out shard may upload no artifact, so its slowest scripts would go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that the parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, the Herdr lane, and the hc lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
Each lane records its own CI tripwire as its `--max-wall-ms` limit, and the aggregate step lists every lane's duration against that limit in its log and as a table on the run's summary page, flagging any lane within 15 percent of it with a warning on the pull request, so a lane drifting toward its tripwire is visible on every PR before it fails one.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
`.github/workflows/ci.yml` owns the partition count; the script balances them by each root's direct byte size.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the three watch-triage members still sum to about 26 minutes of CI test time.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses twenty-six long-lived Linux jobs (eighteen serial, three parallel, Herdr, four lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession and keeps only the newest of close main pushes' runs, without changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate, Full suite verdict | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.

# Firstmate portable test shards (Phase 4 parallel, serial re-shard)

This document records how the portable parallel CI shards and the later serial re-shard were balanced from measured evidence.
Composition and execution are owned by `bin/fm-test-run.sh` (`--lane portable-parallel-1` / `portable-parallel-2` / `portable-serial-1` / `portable-serial-2`; `portable-serial` remains the local remainder union).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (30 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Phase 1 serial durations | CI timing artifacts `fm-test-timing` from main after #825 / #832 / #834 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

Phase 1 averages used for balance (mean of available serial `duration_ms` across those artifacts):

| duration_ms (avg) | script |
|---:|---|
| 29639 | `tests/fm-arm-pretool-check.test.sh` |
| 25402 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19428 | `tests/fm-x-mode.test.sh` |
| 14979 | `tests/fm-cd-pretool-check.test.sh` |
| 9339 | `tests/fm-backend-herdr.test.sh` |
| 6885 | `tests/fm-herdr-lab.test.sh` |
| 5127 | `tests/fm-crew-state.test.sh` |
| 4044 | `tests/fm-pr-merge.test.sh` |
| 3922 | `tests/fm-grok-harness.test.sh` |
| 2492 | `tests/fm-test-run.test.sh` |
| 1901 | `tests/fm-send-popup-settle.test.sh` |
| 1234 | `tests/fm-spawn-batch.test.sh` |
| 851 | `tests/fm-send-strict.test.sh` |
| 791 | `tests/fm-review-diff.test.sh` |
| 627 | `tests/fm-tmux-submit-busy.test.sh` |
| 525 | `tests/fm-brief.test.sh` |
| 321 | `tests/fm-composer-ghost.test.sh` |
| 283 | `tests/fm-dispatch-select.test.sh` |
| 276 | `tests/fm-send-settle.test.sh` |
| 189 | `tests/fm-ensure-agents-md.test.sh` |
| 175 | `tests/fm-supervision-instructions.test.sh` |
| 138 | `tests/fm-instruction-owners.test.sh` |
| 133 | `tests/fm-lint.test.sh` |
| 108 | `tests/fm-pi-primary-types.test.sh` |
| 106 | `tests/fm-nm-test-contract.test.sh` |
| 67 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-captain-translation-contract.test.sh` |
| 48 | `tests/fm-composer-lib.test.sh` |
| 36 | `tests/fm-stow-contract.test.sh` |
| 28 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing method

Longest-processing-time (LPT) assignment onto two workers using the Phase 1 averages above.
Do not rebalance alphabetically or by family intuition.
Shard execution order is longest-first so wall-clock tracks the balanced sum.

| Lane | Script count | Sum of Phase 1 averages |
|---|---:|---:|
| `portable-parallel-1` | 15 | 64579 ms (~64.6 s) |
| `portable-parallel-2` | 15 | 64579 ms (~64.6 s) |
| imbalance | | 0 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial shards

`portable-serial` is the local remainder alias: every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in (default skip), GUI backends, and other stateful or unproven work serial.
CI does not run that alias as one job.
It runs two LPT-balanced serial shards of the same remainder.

Five successful main `fm-test-timing-portable-serial` artifacts from 2026-08-13/14 were used (workflow runs 31660022545, 31663580449, 31679450074, 31744799083, 31744805387).
Unsharded remainder walls on those runs were 19m09s, 19m26s, 19m53s, 19m35s, and 20m07s against the original 20m cap.

Mean per-script `duration_ms` across those artifacts, longest-processing-time onto two workers:

| Lane | Script count | Sum of means |
|---|---:|---:|
| `portable-serial-1` | 48 | 591542 ms (~9.86 min) |
| `portable-serial-2` | 48 | 591522 ms (~9.86 min) |
| imbalance | | 19 ms |

Slowest remainder scripts by that mean (these stay serial; none moved to the proven-isolated parallel set):

| duration_ms (avg) | script |
|---:|---|
| 173794 | `tests/fm-pr-check-security.test.sh` |
| 129943 | `tests/fm-secondmate-harness.test.sh` |
| 101133 | `tests/fm-watch-triage.test.sh` |
| 99974 | `tests/fm-watcher-lock.test.sh` |
| 61257 | `tests/fm-bearings-snapshot.test.sh` |

No suite moved into the parallel set.
The Phase 2 isolation-proof candidate list is unchanged, and these remainder scripts still carry shared lock, watcher, AFK, tmux, daemon, or other serial-family contracts.
Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_serial_1` / `list_portable_serial_2`).
A new `tests/*.test.sh` that is not proven-isolated must be added to one of those lists or the coverage guard fails.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. The two portable serial shards are a partition of the serial remainder.
4. Union of portable parallel shards + portable serial shards + real-Herdr family equals the complete `tests/*.test.sh` inventory.
5. Those five partitions are pairwise disjoint (no missing scripts, no duplicates).

CI runs that guard as a required job (`test-coverage`).

## Timing artifacts

Every portable parallel shard, both portable serial shards, and the Herdr lane upload their runner-generated timing JSON even when the behavior run reports failures.
The dependent aggregate job runs after all five lanes, combines every available lane JSON through `bin/fm-test-run.sh --aggregate-json`, and uploads one summary artifact for critical-path review.
The workflow in `.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | Measured shard sum ~1 min; hang tripwire with margin |
| portable serial 1/2 | 20 | Hang tripwire above the measured ~9.86 min LPT shard wall, restoring the original 20m cap with headroom |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
Do not raise them as a substitute for green results, retries, or weaker assertions.

## What this phase does not do

- Does not expand the proven-isolated set without a new concurrent isolation proof.
- Does not parallelize watcher, AFK, real Herdr, real tmux, or other stateful families.
- Does not delete or skip tests to buy wall-clock.

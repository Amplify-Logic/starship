# Test failure cause verification

Repeatable evidence for the advisory failure-cause labels `bin/fm-test-run.sh` prints after a run with failures.
Current behavior and the operator-facing contract are owned by [`../configuration.md`](../configuration.md) ("Test failure cause"), when it runs and its marker by [`../../bin/fm-test-run.sh`](../../bin/fm-test-run.sh)'s header, and the request shape, questions, size bounds and floor by its engine, [`../../bin/fm-test-failure-cause.py`](../../bin/fm-test-failure-cause.py); this page records evidence only.

Date: 2026-09-29.
Host: macOS, Darwin arm64; Python 3.12.5, git 2.50.1, GNU bash 3.2.57.
Model: `jev-1.13.0`, pinned rather than an alias.
The key was read from the home's `.env` through `FM_HOME` and never printed.

Every run below went through the engine on the shared-budget request shape, where every failure's question and output tail share one budget and each tail shrinks as the failure count grows.
The fix that later reserved room for the questions inside the window check changes nothing here: these requests are far below any trimming.

## Portable suite, network stubbed

`tests/fm-test-run.test.sh` drives the real runner and the real request build with recorded answers in place of the network: the labels, the 0.6 floor, an answer that cannot be read, no key, a green run, the key reaching only the Authorization header against a local endpoint, a hung endpoint ending silently inside the bound, the diff fitted and the captain-private paths excluded, and a run past what the size budget can describe marking its remaining failures `not-labelled`.

## Live probe set

Six failing-test cases shaped like Firstmate's, in one scratch git repository with a base commit and a branch diff, sent as one batched request: six choice questions, serialized state 4,462 characters with a 2,944-character diff, 2,889 input and 263 output tokens, 0.46-0.48 s per request.

| Case | Script | Expected | What failed |
| --- | --- | --- | --- |
| 1 | `tests/fm-count.test.sh` | code bug | The branch changed `count_lines` to `tail -n +3`, off by one where the header skip should be `+2`; the test, updated to expect 3, got 2. |
| 2 | `tests/fm-classify.test.sh` | code bug | The branch dropped `paused*` from the classifier's case; the test says a paused line was classified as unknown. |
| 3 | `tests/fm-summary.test.sh` | test out of date | The branch deliberately renamed the summary field `total=` to `scripts=`, with a comment saying so; the test still greps `total=`. |
| 4 | `tests/fm-resolve.test.sh` | test out of date | The branch deliberately changed `dispatch-resolve: off` to `dispatch-resolve: disabled (no TYPESAFE_API_KEY)`; the test asserts the old text. |
| 5 | `tests/fm-sync.test.sh` | environment | `Could not resolve host: github.com`. |
| 6 | `tests/fm-meta.test.sh` | environment | `jq: command not found`. |

Three serial runs through the CLI, label and confidence per run:

| Case | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| 1 | unclear 0.58 | unclear 0.52 | unclear 0.49 |
| 2 | code-bug 0.98 | code-bug 0.98 | code-bug 0.98 |
| 3 | test-out-of-date 0.89 | test-out-of-date 0.87 | test-out-of-date 0.88 |
| 4 | test-out-of-date 0.94 | test-out-of-date 0.93 | test-out-of-date 0.93 |
| 5 | environment 1.00 | environment 0.99 | environment 1.00 |
| 6 | environment 0.98 | environment 0.98 | environment 0.97 |

Case 1's top pick was `code_bug` every time; a separate call through the engine's own `build_request` answered `code_bug` at 0.54, with probabilities `code_bug` 0.69, `test_out_of_date` 0.29 and `environment` 0.02.

Result: 15 of 18 labels printed, all 15 correct, and no wrong label printed.
The three `unclear` answers were all case 1, whose top pick was right but under the floor.

## Real failing run

`tests/fm-timeout-lib.test.sh` fails on this Mac on `origin/main` code too, because the stock `/bin/bash` 3.2 has no `BASHPID` (`line 100: BASHPID: unbound variable`, then `not ok - the bounded probe failed under PATH=...`).
Its real output tail and this branch's real diff against its base `88c1c709` (7 files; request state 42,347 characters, the diff trimmed to 38,774) were labelled `environment` 0.82, 0.83 and 0.78 over three serial runs, 0.55-0.60 s each, which is correct.

An earlier real-run check, on the request shape before the shared budget, planted a one-line off-by-one in `bin/fm-trace-context-lib.sh` and then reverted it; it came back `unclear` 0.45, with a top pick of `code_bug` at about 0.7.

## The dry-run preview and key order

The `--dry-run` preview used to serialize with sorted keys, so its key order differed from the request actually sent, and sending that sorted body measurably moved the answers: case 1 `code_bug` 0.83 and case 2 `code_bug` 0.73.
The preview now prints the body in the order the engine sends it, so it is the exact request.

## The floor

The evidence supports keeping 0.6: no wrong label was printed at or above it, and the only answers below it were right but uncertain.
Six probes and one real failing run are a small sample, so 0.6 is a conservative choice rather than a tuned one.

Refresh this page by rerunning the probe set and a real failing run after a model upgrade or a question change.

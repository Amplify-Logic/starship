# Native worker-runtime re-verification exam

`bin/fm-harness-exam.sh` is the behavior half of worker-runtime certification.

The existing adapter tests prove that recorded facts are wired into firstmate, while this exam proves those facts against a real interactive runtime.

## Scope

The score contains eight probes: autonomy, composer classification, busy signature, interrupt, turn-end hook, liveness marker, exit, and resume.

The 2026-08-01 evaluation counted trust among its original core eight and liveness as an extra property.

The approved implementation scope replaced trust with liveness, so startup and trust dialogs remain captured evidence but do not affect the eight-point score.

Every scored observation comes from outside the runtime pane.

The runtime cannot mark its own probe as passing.

## Running an exam

Run the exam only when spending real model calls and exercising unattended tool execution is intended.

```sh
bin/fm-harness-exam.sh kimi --model kimi-code/k3
```

Use `--list` to print supported adapters and `--plan <adapter>` to inspect the recorded expectations without launching anything.

The supported adapters are Claude, Codex, OpenCode, Pi, Grok, Cursor, and Kimi.

The default artifact directory is `data/harness-exam/<adapter>-<UTC timestamp>` under the active firstmate home.

Pass `--output <dir>` to place artifacts elsewhere.

A successful run exits zero only when all eight probes pass.

A failed or missing observation exits nonzero and remains visible in the scorecard.

Exit code 3 is separate: it means the lab home was not authenticated, so nothing was scored at all.

## Isolation and credentials

Each run creates a fresh git repository and a private Unix home beneath a temporary lab directory.

Each run also creates a private tmux socket in its own short temporary directory, so the socket path stays under the platform Unix-socket path limit for every adapter name even with the stock macOS per-user `TMPDIR`.

The ambient tmux server is never used.

The runtime receives its real unattended flag, but its tool access starts in the throwaway repository.

The lab copies only the selected adapter's known authentication and configuration files from `--source-home`.

The exam writes no configuration, session, or artifact state into the source home.

The isolated copies are read-only and never write token refreshes back to the source home.

Claude receives a read-only copy of the home-root `.claude.json` account and onboarding state, so the lab home does not boot as a first-run install, plus `.claude/.credentials.json` when that file-based token exists.

The macOS login keychain is resolved from `HOME`, not from the user session.

Verified 2026-08-13 on macOS 25.5.0: under a fresh `HOME`, `security default-keychain` reports "A default keychain could not be found" and `security list-keychains` falls back to `/Library/Keychains/System.keychain` alone.

So an adapter whose credential lives only in the login keychain boots LOGGED OUT inside the lab, and no file copy can bridge it.

That applies to cursor, whose token is the keychain item `cursor-access-token` (`~/.cursor/auth.json` does not exist on current builds, and `cli-config.json` carries identity without a token), and to claude on a macOS install with no `.claude/.credentials.json`.

`--share-login-keychain` links the source home's `~/Library/Keychains` into the lab home for those adapters.

It is off by default and is the one bridge that is not a read-only copy: the lab runtime reaches the real login keychain through that link and can rewrite the items it owns, so it stays a deliberate operator choice rather than a silent default.

An unauthenticated lab is refused rather than scored.

The run stops with exit code 3 and writes `evidence/00-auth-blocked.txt`, because an unauthenticated runtime parks on its login screen and every probe would time out into eight recorded failures - a false negative from a tool whose whole job is deciding whether a build still behaves.

Kimi receives a dedicated `KIMI_CODE_HOME`, and source hook blocks are removed before the exam hook is installed.

Codex receives a dedicated `CODEX_HOME`.

Pi receives a dedicated session directory and an explicit turn-end extension.

Grok receives a dedicated `GROK_HOME` containing only the copied configuration and exam hook.

Use `--keep-lab` only when the temporary runtime home itself is needed for diagnosis.

## Probe contract

| Probe | Outside-the-pane assertion |
|---|---|
| Autonomy | The adapter's unattended mode lets a real shell tool create a nonce proof without an approval response. |
| Composer | A settled composer reads `empty`, literal unsubmitted input reads `pending`, and the composer clears back to `empty`. |
| Busy | A deterministic long shell tool call shows the adapter's recorded busy regex, while settled idle chrome does not. |
| Interrupt | The recorded key ends the active turn, leaves the same runtime process alive, and either prints the recorded interrupt text or ends the turn before the deterministic tool call could have finished on its own. |
| Turn-end | A native adapter hook writes both an external marker and captured payload after a completed turn. |
| Liveness | The backend verdict plus raw process command and argv match the adapter record. |
| Exit | The recorded command returns the pane to its shell. |
| Resume | A new pane launched through the recorded resume path restores a nonce from the prior conversation. |

Pi intentionally expects the current backend liveness verdict `unknown` while also requiring its raw `node` and `pi-coding-agent` process markers.

This records the known classifier limitation instead of pretending Pi has an `alive` verdict.

The busy probe includes the negative idle assertion that prevents Kimi's `thinking` footer from being mistaken for `thinking...` activity.

The interrupt probe refuses to count a turn that simply ran to completion, so `FM_HARNESS_EXAM_BUSY_SECONDS` must stay long enough for an interrupted turn to end measurably early.

It also fails closed when the busy signature was never observed, because an unobserved turn has no boundary for the recorded key to end.

The startup wait accepts an empty composer only after real composer chrome is rendered on the classified row, so a blank mid-boot frame cannot start the probes before the runtime is ready for input.

## Artifacts

`results.json` is the machine-readable result.

`scorecard.md` is the human-readable summary.

`evidence/` contains plain and ANSI pane captures, runtime version output, launch and resume commands, process listings, the autonomy proof, and the raw turn-end payload.

A hook payload that arrives only after the scored autonomy-turn window is retained as `evidence/05-turn-end-late-payload.txt`, so a failed turn-end probe never reuses the passing evidence filename.

`bin/fm-harness-exam-adapters.tsv` is the checked-in expectation record that drives all seven adapters.

A runtime version can be called re-verified only when its `results.json` reports eight passes and the captured evidence is retained with the certification update.

The exam does not update `docs/toolchain-manifest.tsv`, move a version pin, or edit an adapter fact automatically.

Those remain deliberate reviewable changes made from the evidence.

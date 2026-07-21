# Kimi Code harness verification

Empirical verification record for Kimi Code as a Firstmate harness.
Primary support is certified separately through `bin/fm-primary.sh kimi-k3`.
This document owns the **partial WORKER** lab record from 2026-07-21.

The distilled operating facts live in the `harness-adapters` skill.
Exact primary launch flags live in `bin/fm-primary.sh`.
Worker dispatch through `bin/fm-spawn.sh` remains **refused** on this partial evidence.

**Partial worker lab: 2026-07-21** on:

| Component | Version / note |
|---|---|
| Kimi Code CLI (`kimi`) | `0.27.0` |
| Model | `kimi-code/k3` (TUI shows `Model: K3`) |
| Isolation | Named non-`default` Herdr lab via `bin/fm-herdr-lab.sh` |
| Lab session | `fm-lab-firstmate-kimi-w-73720-15206` |

## Scope: primary certified; worker partial and refused

Kimi primary support (session-start, PreToolUse seatbelt, Stop turn-end guard, watcher protocol) stays as certified on 2026-07-19.
See `docs/architecture.md` and the four lifecycle guard docs for that evidence.

Worker (crewmate/scout) certification is **incomplete**.
Surfaces verified live on 2026-07-21 are recorded below.
Busy-pane signature, interrupt of a running turn, and crewmate turn-end hook firing were **not** captured because every model call returned a billing-cycle usage limit:

```text
403 You've reached your usage limit for this billing cycle.
Your quota will be refreshed in the next cycle.
```

Do not infer those missing surfaces from the primary record, from another harness, from Herdr agent-detection manifests, or from strings inside the Kimi binary.
`fm-spawn` must not accept `kimi` until busy signature, interrupt, and turn-end are captured live and recorded here.

## Worker surfaces verified live, 2026-07-21, Kimi Code 0.27.0

### Launch and autonomy

Interactive launch shape exercised in the lab:

```sh
kimi --yolo --model kimi-code/k3
```

Observed TUI chrome: `Version: 0.27.0`, `Model: K3`, footer token `yolo`.
On a later `--continue` resume the TUI also printed `YOLO mode: ON` / `All actions will be approved automatically.`

The CLI rejects combining `--prompt` with `--yolo` (`Cannot combine --prompt with --yolo`).
`-p` / `--prompt` is non-interactive only.
There is no positional interactive prompt for a brief.
Any future worker spawn design must deliver the brief after the TUI is up (for example via the backend send path), not by inventing a positional or `-p --yolo` launch.

### Trust dialog

A brand-new git worktree under `/private/tmp/kimi-worker-trust-*` showed **no** trust dialog.
The idle composer appeared immediately after launch.

### Composer classification

Idle composer (verbatim shape):

```text
 ╭──────────────────────────────────────────────────╮
 │ >                                                │
 ╰──────────────────────────────────────────────────╯
 yolo  K3 thinking: max  /private/tmp/...
```

Against the shared owner `bin/fm-composer-lib.sh`:

| Row | `bordered` | Verdict |
|---|---|---|
| `> ` (empty agent box) | 1 | `empty` |
| `> PENDING_TEST_TEXT` | 1 | `pending` |
| bare `>` (no box) | 0 | `unknown` (dead shell) |

No `FM_COMPOSER_IDLE_RE` override is required for this idle shape: the empty composer is the bordered `>` glyph alone, with no placeholder sentence.

### Exit

`/exit` opens slash autocomplete (`→ exit  Exit the application`).
One Enter selects and executes.
The Herdr pane closed and the Kimi process was gone.

### Resume

From the same worktree cwd:

```sh
kimi --yolo --model kimi-code/k3 --continue
```

Restored the prior durable session id and transcript under a new process id.

### Observed process name (not wired)

`pane process-info` reported `name: kimi` and `argv0: kimi-code`.
That observation is recorded for a future liveness wiring pass.
It is **not** sufficient to enable worker dispatch, and `bin/backends/tmux.sh` was deliberately left unchanged on this partial certification.

## Worker surfaces explicitly UNVERIFIED, 2026-07-21, Kimi Code 0.27.0

Blocked by the same `403` usage-limit response on every model turn attempt (interactive submit and `kimi -p`):

| Surface | Status | Reason |
|---|---|---|
| Busy-pane signature for `fm-watch.sh` / `fm-tmux-lib.sh` defaults | UNVERIFIED | No mid-turn pane capture; do not copy another harness's busy regex |
| Interrupt of a running turn | UNVERIFIED | No live running turn; do not copy primary `ctrl+c` facts into the worker record |
| Crewmate turn-end hook path | UNVERIFIED | Stop hook never fired in this lab; do not install or claim a worker turn-end mechanism yet |
| Unattended `--yolo` tool execution proof | UNVERIFIED | Same quota block |

Until those rows are replaced with dated live evidence, worker dispatch stays refused: do not add `kimi` to `fm-spawn`'s verified worker set, do not extend `FM_BUSY_REGEX` / `FM_TMUX_BUSY_REGEX_DEFAULT` for Kimi, and do not treat partial launch/composer/exit/resume facts as a complete worker adapter.

## Primary pointer

Primary-only certification and e2e evidence remain in `docs/architecture.md` (2026-07-19) plus `docs/turnend-guard.md`, `docs/arm-pretool-check.md`, `docs/sessionstart-nudge.md`, and `docs/cd-guard.md`.
That primary record does not authorize worker dispatch.

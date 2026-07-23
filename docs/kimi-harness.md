# Kimi Code harness verification

Empirical verification record for Kimi Code as a Firstmate harness.
Primary support is certified separately through `bin/fm-primary.sh kimi-k3`.
This document owns the WORKER certification record.

The distilled operating facts live in the `harness-adapters` skill.
Exact primary launch flags live in `bin/fm-primary.sh`.
Worker dispatch through `bin/fm-spawn.sh` accepts `kimi` after the 2026-07-23 lab.

**Worker lab: 2026-07-23** on:

| Component | Version / note |
|---|---|
| Kimi Code CLI (`kimi`) | `0.27.0` (isolated install under `/tmp/kimi-code-0.27.0-lab`; captain PATH had auto-upgraded to 0.29.0 mid-session and was not used for the cert captures) |
| Model | `kimi-code/k3` (TUI shows `Model: K3`) |
| Isolation | Named non-`default` Herdr lab via `bin/fm-herdr-lab.sh` |
| Lab session | `fm-lab-firstmate-kimi-w-38519-28030` |

A prior partial lab on 2026-07-21 verified launch/autonomy, trust, composer, exit, and resume, but could not capture busy/interrupt/turn-end because every model call returned billing-cycle `403`.
That quota blocker is gone (Allegretto plan; probe `kimi --prompt 'Reply with exactly OK.' --model kimi-code/k3` succeeded 2026-07-23).

## Scope: primary certified; worker certified 2026-07-23

Kimi primary support (session-start, PreToolUse seatbelt, Stop turn-end guard, watcher protocol) stays as certified on 2026-07-19.
See `docs/architecture.md` and the four lifecycle guard docs for that evidence.

Worker (crewmate/scout) certification is complete for the surfaces below on Kimi Code 0.27.0.

## Worker surfaces verified live

### Launch and autonomy (2026-07-21, reconfirmed 2026-07-23)

Interactive launch shape:

```sh
kimi --yolo --model kimi-code/k3
```

Observed TUI chrome: `Version: 0.27.0`, `Model: K3`, footer token `yolo`.
The CLI rejects combining `--prompt` with `--yolo` (`Cannot combine --prompt with --yolo`).
There is no positional interactive prompt for a brief.
`fm-spawn` therefore launches the TUI first, then delivers `brief.md` via the backend send path after a short settle (`FM_KIMI_BRIEF_SETTLE_SECS`, default 2).

### Trust dialog (2026-07-21)

A brand-new git worktree showed no trust dialog.
The idle composer appeared immediately after launch.

### Composer classification (2026-07-21, reconfirmed 2026-07-23)

Idle composer shape is the bordered `> ` glyph.
Against `bin/fm-composer-lib.sh`: bordered `> ` is `empty`, bordered `> PENDING...` is `pending`, bare `>` is `unknown`.
No `FM_COMPOSER_IDLE_RE` override is required.

### Exit (2026-07-21)

`/exit` plus one Enter closes the pane.

### Resume (2026-07-21)

`kimi --yolo --model kimi-code/k3 --continue` restores the durable session for that cwd.

### Busy-pane signature (2026-07-23) - VERIFIED

While `agent_status=working` on a real K3 turn, the pane showed two ASCII-stable busy phases distinct from idle:

1. Reasoning: a braille spinner prefix plus the literal ASCII `thinking...` (example capture: `⠙ thinking...`).
2. Tool execution: the literal ASCII `Running a command` (example: `● Running a command` / `$ sleep 15; echo X`).

Idle footer remains `yolo  K3 thinking: max` (or `high`).
That idle string contains `thinking` but not `thinking...`, so the busy regex must match the ellipsis form only.

Wired into `FM_BUSY_REGEX` / `FM_TMUX_BUSY_REGEX_DEFAULT` as:

```text
thinking\.\.\.|Running a command
```

Moon-phase emoji spinners (`🌕`/`🌔`/...) also appear mid-turn but are not used in the regex (not ASCII-stable).
`Press Ctrl+B to run in background` appeared during a long shell tool call and is tool-specific, not the general busy signature.

### Interrupt (2026-07-23) - VERIFIED

Keystroke: `Ctrl+C` (`pane send-keys ... C-c`).
Evidence: mid-turn pane printed `Interrupted by user`, `agent_status` returned to `idle`, and `pane process-info` still showed a live `kimi` / `kimi-code` process in the same pane.
Matches the primary interrupt fact; now verified on the worker path as well.

### Crewmate turn-end hook (2026-07-23) - VERIFIED

Mechanism: `[[hooks]]` `event = "Stop"` in `KIMI_CODE_HOME/config.toml`.
Live marker log from an isolated worker home after a completed short turn:

```text
UserPromptSubmit 2026-07-23T21:58:44Z
Stop 2026-07-23T21:58:48Z
```

Stop stdin payload (verbatim):

```json
{"hook_event_name":"Stop","session_id":"session_d3399d49-b83b-4b0a-bf5f-fd90abe04be0","cwd":"/private/tmp/kimi-worker-cert-fezvWk","stop_hook_active":false}
```

An interrupted turn fired `Interrupt` instead of `Stop` (expected).
Project-local worktree config/plugin hooks did **not** fire (marker stayed empty when launched without the isolated `KIMI_CODE_HOME`).
Consequence for `fm-spawn`: install a per-task isolated `state/<id>.kimi-home` with auth symlinks from the source Kimi home and a Stop hook that `touch`es `state/<id>.turn-ended`.
Never edit the captain's `~/.kimi-code/config.toml` for worker turn-end.

### Process name / liveness (2026-07-23)

`pane process-info` reported `name: kimi` and `argv0: kimi-code`.
`bin/backends/tmux.sh` treats `*kimi*` as `alive`.

## Primary pointer

Primary-only certification and e2e evidence remain in `docs/architecture.md` (2026-07-19) plus `docs/turnend-guard.md`, `docs/arm-pretool-check.md`, `docs/sessionstart-nudge.md`, and `docs/cd-guard.md`.
Primary facts are unchanged by this worker certification.

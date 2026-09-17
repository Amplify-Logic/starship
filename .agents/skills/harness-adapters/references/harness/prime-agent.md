# Prime Agent

WORKER ONLY, verified 2026-08-07 on v0.7.0 (source tag be9e2fa).
This adapter is carried by this fork and is not part of the upstream harness set.
Cross-harness provider and credential identity is owned by `../common/model-and-effort.md`.

## Operating facts

Prime Agent (Prime Intellect), a hard fork of pi whose TUI is a thin client over a per-session daemon worker.
`../../../../docs/prime-agent-harness.md` owns the dated evidence, exact commands, and raw output; the facts below are the operating summary.
Pin the version: the project releases daily and ships no npm package (install is the release installer or a source build).

| Fact | Value |
|---|---|
| Busy-pane signature | `(Waiting\|Thinking\|Executing) · [0-9]+s` - a braille-spinner row in the MESSAGES area (`⠴ Waiting · 0s`, `⠏ Thinking · 3s · ↓ 52 tokens`, `⠹ Executing · 19s · ↑ 111 tokens`). Never match the bare state word (model prose can contain `Thinking`) and never the footer. `Operation aborted · Ns` (post-interrupt) is deliberately not matched. In the shared `FM_BUSY_REGEX_DEFAULT`. |
| Exit command | `/quit` - cleanly DETACHES the client and prints `Resume this session with: prime-agent --resume <session-id>`. The agent KEEPS RUNNING in the daemon. |
| Interrupt | single `Ctrl+C` (verified: `Operation aborted · 2s`, pane and process survive, composer idle) |
| Autonomy | `--autonomous` (+ `--autonomous-max-turns/-max-continuations/-max-tokens/-timeout-ms`, repeatable `--autonomous-gate`); budget exhaustion exits 1 with a clear stderr reason, natural stop exits 0 |
| Env marker | `PRIME_AGENT_INTERNAL_DAEMON_WORKER`, `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_KERNEL_VENV`, `PRIME_AGENT_LAUNCHER_PATH`, `PRIME_AGENT_BUILD_ID`. It ALSO sets `PI_CODING_AGENT=true` (inherited from pi), so `../../../../bin/fm-harness.sh` tests the PRIME_AGENT_* markers FIRST - same shape as CURSOR_AGENT before CLAUDECODE. |
| Resume | `prime-agent -c` or `-r <session-id>` (id printed on /quit, shown in `list`); restores the daemon-backed session with full context |
| Trust | None - pi's trust mechanism was removed upstream; no dialog on first launch in a fresh directory |
| Turn-end | pi-fork extension API: `pi.on("turn_end")` via `-e <path>` (verified live: marker touched at every turn boundary). No hooks.json - "hooks have been renamed to extensions". `fm-spawn` writes `state/<id>.prime-ext.ts` outside the worktree. |
| Liveness | pane COMM is `node` but the CLI sets `process.title = "prime-agent"`, so the foreground node's argv/comm reads `prime-agent` (verified on macOS). tmux liveness resolves node+argv exactly like cursor. The real agent lives in a daemon worker OUTSIDE the pane. |
| Launch | `PRIME_AGENT_CODING_AGENT_DIR=<task state> PRIME_AGENT_KERNEL_VENV=<task state>/kernel-venv prime-agent --daemon-socket <task state>/daemon.sock -e <turn-end ext> --model <validated route> [--thinking <effort>] "$(cat <brief>)"` (a positional brief starts the session, like pi). |

**Daemon persistence changes supervision semantics.** The agent survives `/quit`, pane kill, and terminal loss (verified: `prime-agent list` showed the detached session with 0 clients after the TUI exited).
A dead pane is NOT a stopped worker.
`fm-spawn` gives every task its own daemon socket because the default socket is per-USER shared (`$TMPDIR/prime-agent-<uid>/daemon.sock`): without it, one task's `list`/`stop` sees and hits every task's agents, and a bare `prime-agent shutdown --force` sweeps ALL discovered daemons (it rejects socket flags).
Management commands take the socket flag AFTER the subcommand (`prime-agent list --daemon-socket <path>`, `prime-agent stop <id> --daemon-socket <path>`); a flag before the subcommand is misparsed as a positional prompt (verified: it launched a run on the PAID default model and 401'd).
Teardown order is load-bearing (all verified 2026-08-07): the TUI client auto-relaunches its daemon supervisor on reconnect, so `fm-teardown` runs the daemon stop only AFTER the endpoint is dead; a live session worker watches its supervisor and launches a REPLACEMENT when it dies, so workers are killed before the supervisor (worker sockets are namespaced by the task's supervisor hash, `$TMPDIR/prime-agent-<uid>/worker-<hash>-*.sock`, the hash recovered from the task's `.supervisor-launch-<hash>.lock`); the supervisor itself lingers after its last session stops and is TERM'd by the socket it listens on (its argv is title-rewritten to bare `prime-agent`, so the socket is the only ownership handle).

**Containment needs BOTH env vars** (fm-spawn's template sets them): `PRIME_AGENT_CODING_AGENT_DIR` relocates sessions/auth/logs/daemon state; the kernel venv is hardcoded to `~/.prime/agent/kernel-venv` unless `PRIME_AGENT_KERNEL_VENV` is set (verified: an ipykernel ran from the task-contained venv and no `~/.prime` existed after the lab).
Auth is `<agentDir>/auth.json`; fm-spawn symlinks the operator's `~/.prime/agent/auth.json` (override `FM_PRIME_AGENT_SOURCE_HOME`) so token refreshes propagate, the same posture as the kimi worker-home links.

**Model routes are quota-guarded at spawn.** Subscription-quota routes only: `opencode/big-pickle`, `opencode/*-free` (OpenCode Zen free models), and `openai-codex/*` (ChatGPT Plus/Pro Codex subscription OAuth).
`anthropic/*` is REFUSED: it bills per-token extra usage even on a Claude Pro/Max OAuth login (verified $0.1845 for a one-line probe, trial leg 2).
Every other `opencode/*` id needs paid Zen billing (verified: 401 CreditsError on `opencode/gpt-5.6-sol`).
An absent `--model` folds to `opencode/deepseek-v4-flash-free` because the CLI's own default is a paid route.
The guard is `prime_agent_model_route_ok` in `../../../../bin/fm-spawn.sh`, regression-covered by `tests/fm-prime-agent-adapter.test.sh`.

**Composer.** Idle composer is a BARE ` > ` row with a rotating dark-truecolor ghost placeholder (` >   Try "add tests for @<filepath>"`; fg 38;2;113;113;122, under the ghost-luminance ceiling, so the shared stripper already drops it; the `Try "..."` pattern is also in the shared idle regex as the plain-row backstop).
The stripped row reduces to the lone `>` glyph, which the shared dead-shell rule would read `unknown` - so the tmux composer reader promotes the row to a structurally-identified agent prompt row ONLY on panes positively identified as prime-agent (node COMM + prime-agent argv), the same scoping class as cursor's structural fix.

Backend applicability: tmux only. herdr, zellij, orca, and cmux were not exercised with prime-agent.

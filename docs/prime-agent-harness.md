# Prime Agent worker-harness verification

Empirical evidence for the `prime-agent` worker adapter (Prime Intellect, a hard fork of pi).
The concise operating facts live in `.agents/skills/harness-adapters/SKILL.md`; this doc is the dated verification record, in the same shape as `docs/cursor-harness.md` and `docs/kimi-harness.md`.
The preceding trial report and the captain's adoption decision live in `data/fm-prime-agent-trial-t1/` (untracked, home-local).

- **Date:** 2026-08-07 (wire task `fm-prime-agent-adapter-wire-p2`); trial 2026-08-06 (`fm-prime-agent-trial-t1`)
- **Version:** v0.7.0 (source tag `be9e2fa` "chore(release): prepare v0.7.0"; the trial ran main commit `c5991bc` of the same release)
- **Install:** source clone + `npm ci` + `npm run build`, run via `./prime-agent.sh --dist` (no public npm package exists)
- **Route:** OpenCode Zen free model `opencode/deepseek-v4-flash-free`; the Zen key was read at runtime from the operator's existing auth and never printed or logged
- **Environment:** macOS, tmux on an isolated server (`tmux -L fm-pa-lab`), never the default server; every run under `PRIME_AGENT_CODING_AGENT_DIR`/`PRIME_AGENT_KERNEL_VENV` pointed into the lab

## CLI surface (v0.7.0 `--help`)

- Positional `[message...]` starts an interactive session with that brief (verified live below).
- `-e, --extension <source>` is repeatable; `--thinking <level>` accepts `off, minimal, low, medium, high, xhigh, max`.
- Daemon management commands: `agents`, `list`, `attach`, `stop`, `status`, `doctor`, `shutdown`.
- `--daemon-socket <path>` is a run option; `--autonomous` with budget flags exists.

## Verified facts

### Containment (both env vars required)

`PRIME_AGENT_CODING_AGENT_DIR` relocates the agent dir (default `~/.prime/agent`, from `packages/coding-agent/src/config.ts` `getAgentDir`).
`PRIME_AGENT_KERNEL_VENV` relocates the IPython kernel venv, which is otherwise hardcoded to `~/.prime/agent/kernel-venv` (`packages/coding-agent/src/core/kernel/bootstrap.ts:342`).

```
$ PRIME_AGENT_CODING_AGENT_DIR=$LAB/agent PRIME_AGENT_KERNEL_VENV=$LAB/agent/kernel-venv \
    prime-agent -p --model opencode/deepseek-v4-flash-free "Reply with exactly: LAB OK"
LAB OK
$ ls agent/
auth.json  daemon-workers  kernel-venv  logs  session-artifacts  session-leases  sessions
$ ls ~/.prime
ls: ...: No such file or directory   # containment holds
```

A later turn that used the Python tool spawned `.../lab/agent/kernel-venv/bin/python -m ipykernel_launcher ...` - the kernel venv lived inside the contained dir.

### Liveness: node COMM, prime-agent argv

The CLI sets `process.title = "prime-agent"` (`packages/coding-agent/src/cli-main.ts:18`).
In a live pane: `#{pane_current_command}` = `node`, the pane pid is the shell, and the foreground child reports `ps -o comm=` = `prime-agent` and `ps -o args=` = `prime-agent`.
This is the same node+argv resolution class as cursor; `bin/fm-tmux-lib.sh`'s `fm_tmux_pane_is_prime_agent` walks the pane's descendant tree, bounded at five levels, for a `prime-agent` argv.

### Busy signature

Mid-turn capture (plain):

```
 ⠴ Waiting · 0s
```

Trial-observed variants: `⠏ Thinking · 3s · ↓ 52 tokens`, `⠹ Executing · 19s · ↑ 111 tokens`.
The shared regex is `(Waiting|Thinking|Executing) · [0-9]+s`; the bare word `Thinking` in prose does not match, and the transient `Operation aborted · 2s` post-interrupt row is deliberately not matched (the turn is over).

### Idle composer placeholder

Verbatim styled capture of the idle composer row (`capture-pane -e`, `cat -v`):

```
^[[48;2;26;26;31m >  ^[[7m ^[[0m^[[38;2;113;113;122m^[[48;2;26;26;31mTry "add tests for @<filepath>"^[[39m
```

The placeholder foreground is truecolor 113,113,122 (luminance ~114, under the 128 ghost ceiling), so the shared `fm_composer_strip_ghost` already drops it; the SGR-7 reverse-video cell is the terminal cursor over a space and trims to nothing.
What remains is the lone `>` glyph, which the shared dead-shell rule reads as `unknown` on an unbordered row - so the tmux composer reader promotes the row to a structurally-identified agent prompt row (`bordered=1`) only on panes positively identified as prime-agent.
The `^(> *)?Try ".*"$` alternation in `FM_COMPOSER_IDLE_RE_DEFAULT` is the plain-row backstop for styling surprises and the plain-read backends.
Observed placeholder variants: `Try "add tests for @<filepath>"`, `Try "refactor @<filepath>"`, `Try "explain how @<filepath> works"`, trial: `Try "improve performance in @<filepath>"`.

### Interrupt

One `Ctrl+C` mid-turn: the turn stopped with `Operation aborted · 2s`, the pane and process survived, and the composer returned to the idle placeholder.

### Turn-end extension

`state/<id>.prime-ext.ts` (the pi-fork extension API) loaded with `-e`:

```ts
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["<turn-end path>"]));
}
```

Verified: the marker file appeared ~10s after a one-line prompt completed.

### Positional brief

`prime-agent --daemon-socket ... --model opencode/deepseek-v4-flash-free "Reply with exactly: POSITIONAL OK"` in a fresh pane ran the turn unattended; the reply contained `POSITIONAL OK`.

### Effort flag

`prime-agent -p --model opencode/deepseek-v4-flash-free --thinking xhigh "Reply with exactly: THINK OK"` printed `THINK OK`, exit 0.

### Daemon persistence and scoped teardown

After `/quit` the pane returned to the shell and printed `Resume this session with: prime-agent --resume 019fdb1c-...`, while:

```
$ prime-agent list                       # contained agent dir, default socket
name  id            status  age  model                            messages  clients
      bb9c4f2f8830  idle    13s  opencode/deepseek-v4-flash-free  2         0
```

The agent kept running detached - a dead pane is not a stopped worker.

The default daemon socket is per-USER shared: `$TMPDIR/prime-agent-<uid>/daemon.sock` (`packages/coding-agent/src/modes/daemon/daemon-socket.ts` `defaultDaemonSocketDir`).
`list` against the shared socket showed sessions from a DIFFERENT agent dir, so per-task scoping requires `--daemon-socket <task socket>` at launch (verified: the task's supervisor then listens on that path, from `agent-b/logs/daemon.sock.*.log`).

Scoped management, verified live:

```
$ prime-agent list --daemon-socket $TASK_SOCK             # flag AFTER the subcommand
$ prime-agent stop b85742c10586 --daemon-socket $TASK_SOCK
ok
$ prime-agent list --daemon-socket $TASK_SOCK
No active agents.            # the other task's daemon (default socket) was untouched
```

Two command-shape traps, both verified:

- `prime-agent --daemon-socket <path> list` (flag BEFORE the subcommand) misparses `list` as a positional prompt and launches a run on the CLI's PAID default model, which 401'd on the free Zen key. This also proves the CLI default is a billed route, which is why `fm-spawn` always emits an explicit validated `--model`.
- Public `prime-agent shutdown [--force]` rejects socket flags (`Error: Unknown option for shutdown: --daemon-socket`) and sweeps EVERY discovered daemon (`runShutdownAll` -> `discoverDaemons`), so teardown never uses it; the socket-aware internal `daemon` command family is not publicly routed in v0.7.0 (`Unknown command: daemon shutdown`).

The supervisor keeps listening after its last session stops (verified: `lsof -U` still showed the socket bound).
Its argv is title-rewritten to bare `prime-agent`, so the socket path is the only reliable ownership handle.
Two teardown-ordering facts were verified the hard way in the end-to-end lab:

- The TUI client auto-relaunches its daemon supervisor on reconnect, so `fm-teardown` runs the daemon stop only AFTER the endpoint (window) is dead; a stop issued first left a relaunched supervisor and a resurrected state dir.
- A live session worker WATCHES its supervisor and launches a replacement when it dies (`failed to launch replacement supervisor` in the worker log), so workers must exit first. Worker sockets are namespaced by the task's supervisor hash - `$TMPDIR/prime-agent-<uid>/worker-<hash>-*.sock`, with the hash recoverable from the task's `.supervisor-launch-<hash>.lock` dir - so `prime_agent_daemon_stop` TERMing stays scoped to the task even on a shared tmpdir. Note `stop <id>` unbinds the worker socket before the worker process fully exits, so the socket alone is not a liveness test during shutdown.

Socket-path matching is deliberately asymmetric in `prime_agent_daemon_stop`, because `lsof -U` prints a unix socket's `sun_path` exactly as the binding process passed to `bind()`:

- Supervisor socket: matched via the PHYSICAL task path (`pwd -P`), because `fm-spawn` substitutes the physically resolved state path (`STATE_REAL`) into `--daemon-socket`, so that is the form the supervisor binds.
- Worker sockets: matched via the LOGICAL `${TMPDIR%/}` (trailing slash stripped, never physically resolved), because prime-agent composes them from Node's `os.tmpdir()` - `$TMPDIR` verbatim. Lab evidence 2026-08-07: `lsof` showed `/var/folders/1g/.../prime-agent-501/worker-*.sock` with no `/private` prefix, so a physically resolved dir would silently no-op the worker kill on macOS and reopen the watchdog-relaunch hazard.

With real treehouse in the loop (its `return` reaps worktree-cwd processes), the verified end state of a full spawn/teardown cycle was: no prime-agent processes, no socket listeners, the containment home removed, no `~/.prime`.

### Env markers (harness detection)

Children of a prime-agent worker see `PI_CODING_AGENT=true` (inherited from pi) plus the prime-specific `PRIME_AGENT_INTERNAL_DAEMON_WORKER`, `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_KERNEL_VENV`, `PRIME_AGENT_LAUNCHER_PATH`, `PRIME_AGENT_BUILD_ID` (the launcher sets the last two; firstmate's launch wrapper sets the containment pair).
`bin/fm-harness.sh` tests the `PRIME_AGENT_*` markers before `PI_CODING_AGENT`, the same shape as `CURSOR_AGENT` before `CLAUDECODE`.

## Model-route guard (captain's hard constraint: subscription quota only, never per-token billing)

`bin/fm-spawn.sh`'s `prime_agent_model_route_ok` refuses any prime-agent spawn whose `--model` is not a subscription-quota route, before any endpoint is created:

- Allowed: `opencode/big-pickle`, `opencode/*-free` (OpenCode Zen zero-cost ids), `openai-codex/*` (ChatGPT Plus/Pro Codex subscription OAuth).
- Refused: `anthropic/*` - trial leg 2 measured **$0.1845** for a one-line probe on `anthropic/claude-opus-5` via a Claude Pro OAuth login; third-party harness usage draws from extra usage, billed per token, never against plan limits.
- Refused: every other `opencode/*` id - verified `Provider authentication failed (CreditsError, 401): No payment method` for `opencode/gpt-5.6-sol` on the free Zen key.
- An absent `--model` folds to `opencode/deepseek-v4-flash-free` (verified free), never the CLI's paid default.

## End-to-end acceptance (2026-08-07)

A full `fm-spawn`/`fm-teardown` cycle ran against the real scripts in a scratch lab (isolated tmux server, real treehouse, real prime-agent v0.7.0 on the free Zen route):

```
$ bin/fm-spawn.sh e2e-pa1 <lab project> --harness prime-agent --scout --backend tmux
spawned e2e-pa1 harness=prime-agent kind=scout ... window=firstmate:fm-e2e-pa1 worktree=<pool worktree>
# pane: brief processed unattended, reply contained "E2E SPAWN OK"
# state/: e2e-pa1.meta (model=opencode/deepseek-v4-flash-free folded), e2e-pa1.prime-ext.ts,
#         e2e-pa1.prime-agent-home/ (auth.json symlink, sessions, daemon.sock, kernel-venv), e2e-pa1.turn-ended
# fm_tmux_composer_state -> empty (idle placeholder), fm_backend_tmux_agent_alive -> alive,
# fm_pane_is_busy matched a steered mid-turn pane at poll 2.
$ bin/fm-teardown.sh e2e-pa1
teardown e2e-pa1 complete (...)
# after: zero prime-agent processes, no socket listeners, containment home removed, no ~/.prime
```

One spawn-time guard this surfaced: the per-task daemon socket lives under the state dir, and AF_UNIX caps `sun_path` at 104 bytes, so `fm-spawn` refuses a prime-agent spawn whose socket path risks exceeding the limit (hit live with a macOS TMPDIR-anchored state home) rather than letting the daemon fail to bind at worker runtime.

## Not verified / out of scope

- herdr, zellij, orca, and cmux backends with prime-agent (tmux only).
- Secondmate-on-prime-agent (the pi secondmate primary extensions have no prime-agent equivalent).
- no-mistakes skill invocation syntax on prime-agent (slash commands exist; use natural language).
- The `openai-codex/*` subscription route end to end (config acceptance only; the trial's leg 3 was quota-deferred).
- `--autonomous` budget flags beyond the trial's checks; firstmate's launch template does not use them.

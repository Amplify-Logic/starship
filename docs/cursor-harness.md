# Cursor CLI harness verification

Empirical verification record for the `cursor` WORKER adapter (the Cursor CLI
`agent` binary), covering the launch, supervision, recovery, and monitoring facts
firstmate depends on.

The distilled operating facts live in the `harness-adapters` skill, which is their
one owner; the exact launch flags live in `bin/fm-spawn.sh`. This document is the
EVIDENCE: dated commands, verbatim output, and the limitations behind each
decision. Regression coverage is `tests/fm-cursor-adapter.test.sh`.

**Verified 2026-07-19** on:

| Component | Version |
|---|---|
| Cursor CLI (`agent`) | `2026.07.16-899851b` |
| Model | Cursor Grok 4.5 (`cursor-grok-4.5-{low,medium,high}`) |
| tmux | 3.6a |
| Account | Cursor Pro, `captain@example.com` |

`agent` resolves to `~/.local/bin/agent`, a bash wrapper that `exec -a`s a bundled
Node app at `~/.local/share/cursor-agent/versions/<version>/index.js`. That detail
is load-bearing for the liveness probe below.

## Scope: worker only

Cursor is verified as a WORKER (crewmate/scout) adapter only. Primary-orchestrator
support was NOT verified: no session-start nudge, turn-end guard, PreToolUse
seatbelt, or watcher supervision protocol was validated for a firstmate running ON
cursor. Do not treat worker verification as primary support.

## 1. Identity, authentication, and models

```
$ agent --version
2026.07.16-899851b

$ agent status
✓ Logged in as captain@example.com
```

All six Grok 4.5 ids are live:

```
$ agent --list-models | grep -i grok
cursor-grok-4.5-high - Cursor Grok 4.5
cursor-grok-4.5-high-fast - Cursor Grok 4.5 Fast
cursor-grok-4.5-low - Cursor Grok 4.5 Low
cursor-grok-4.5-low-fast - Cursor Grok 4.5 Low Fast
cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
cursor-grok-4.5-medium-fast - Cursor Grok 4.5 Medium Fast
```

`--list-models` also advertises a parameterized override form
(`--model 'claude-opus-4-8[context=1m,effort=high,fast=false]'`). The explicit
suffixed ids above are what firstmate uses: they are simpler and directly verified.

## 2. Launch, autonomy, and worktree containment

The verified launch shape is the interactive one, with the brief as a positional
prompt (it auto-submits):

```
agent --yolo --workspace <worktree> --model cursor-grok-4.5-low "$(cat <brief>)"
```

- `--yolo` (alias of `--force`, "Run Everything") auto-approves every tool call.
  Verified unattended: the agent ran `sleep 45 && echo SLEPT` with no approval
  prompt, and the footer showed `Run Everything`.
- `--workspace <path>` pins the workspace root (it otherwise defaults to cwd).
- **No `-w`/`--worktree` is passed, deliberately.** Cursor worktree allocation is
  strictly opt-in on this CLI, so firstmate's own isolated copy stays the only
  one. Verified: `~/.cursor/worktrees/` gained no entry across every launch in
  this lab, retaining only two directories pre-dating the work (Dec 2025).

The footer confirms the resolved profile and the working directory, e.g.:

```
  Cursor Grok 4.5 Low · 7%                                   Run Everything
  /private/tmp/.../scratchpad/lab1 · main
```

### Global config side effects (limitation)

Launching with `--model` persists that model as the account default in
`~/.cursor/cli-config.json` (`model.modelId`, `hasChangedDefaultModel: true`), and
the Run Everything state persists there too. A later launch with no `--model`
inherits it. **Always pass `--model` explicitly** rather than relying on the
default, which is shared mutable state outside firstmate's control.

That same file carries `attribution.attributeCommitsToAgent: true` and
`attributePRsToAgent: true`. Firstmate's repo rule is that no agent is ever added
as a commit co-author, so a cursor worker committing in a firstmate-governed repo
must not rely on Cursor's own attribution defaults.

## 3. Busy and idle pane signatures

Busy (verbatim, mid tool call):

```
  $ sleep 45 && echo SLEPT 15s
    ctrl+b twice to send to background
 ⠠⠛ Running  67 tokens

  → Add a follow-up                                          ctrl+c to stop
  1 task
```

Idle (same pane, after the turn):

```
  READY1

  → Add a follow-up

  Cursor Grok 4.5 Low · 7%                                   Run Everything
```

The busy marker is the footer hint **`ctrl+c to stop`**, present only while a turn
runs. It is ASCII, so it avoids the locale fragility of matching the braille
spinner, exactly like grok's `Ctrl+c:cancel`.

**The spinner VERB is not a safe signal.** It changes within a single turn -
`⠰⠳ Working` while reasoning, `⠠⠛ Running` during a tool call. Sampling a
tool-executing pane found `Working` absent while `ctrl+c to stop` was present in
every sample, so matching the verb would read a busy pane as idle and trip
premature stale detection.

### Empty-composer classification (two defects found and fixed)

Cursor's composer is a background-filled block (no box-drawing border) whose row
always begins with `→ `. It has two idle placeholders: `Add a follow-up` after a
turn, and `Plan, search, build anything` in a fresh session.

**Defect 1 - reverse-video cursor cell.** The captured idle row is:

```
ESC[48;2;21;21;21m ESC[2m→ ESC[0;7mESC[48;2;21;21;21mAESC[0;2mESC[48;2;21;21;21mdd a follow-upESC[0m
```

The placeholder is SGR-2 dim EXCEPT its first character `A`, drawn `ESC[0;7m` -
reverse video, the terminal cursor cell. Reverse video is neither dim/faint nor a
dark foreground, so `fm_composer_strip_ghost` keeps it and the idle composer
reduces to a lone `A`:

```
stripped=[A] plain=[→ Add a follow-up]
verdict=pending          # before the fix
```

An idle cursor pane therefore read as holding unsubmitted input, which would defer
every away-mode escalation indefinitely - the wedge class `bin/fm-composer-lib.sh`
exists to prevent. Note a plain `FM_COMPOSER_IDLE_RE` does **not** fix this on its
own: the idle regex was only matched against the ghost-stripped content (`A`),
never the plain row. The fix matches the placeholder against the PLAIN row too,
which is styling-independent.

**Defect 2 - `#{cursor_y}` does not point at the composer.** Cursor parks the
terminal cursor in its bottom status area. A pane with real unsubmitted text on
row 15 reported:

```
$ tmux display-message -p '#{cursor_y}'
20                                    # the cwd/status row, 5 rows below
```

Reading the cursor_y row found an empty status line, so a composer holding
`some real unsubmitted text` classified as `empty` - a **false-empty**, the
dangerous direction, because `bin/fm-supervise-daemon.sh` picks injection targets
by emptiness and would type an escalation over pending input. This is the same
class as the grok `cursor_y` residual gap recorded in the `harness-adapters`
skill, but several rows off rather than one.

The fix locates the composer structurally (the last `→ ` row), mirroring the herdr
adapter's structural scan - which is why herdr was never affected. The scan is
scoped to panes positively identified as cursor (`fm_tmux_pane_is_cursor`: `node`
COMM plus the versioned `cursor-agent` bundle path in argv, the same marker the
liveness probe uses), because other harnesses' output can legitimately contain
`→ `-prefixed lines and an unscoped scan would misread their empty composer as
pending; every non-cursor pane keeps the plain `#{cursor_y}` behaviour. Verified
live after the fix:

```
composer_row=15
state(idle,after turn)=empty
state(typed)=pending
```

## 4. First-run trust

An untrusted directory shows a blocking dialog before the agent starts:

```
  ⚠ Workspace Trust Required
  Cursor Agent can execute code and access files in this directory.
  Do you trust the contents of this directory?
    /private/tmp/.../scratchpad/lab1
  ▶ [a] Trust this workspace
    [q] Quit
  Use arrow keys to navigate, Enter to select, or press the key shown
```

Accept with a single `Enter` (or the `a` key). Trust then persists per directory -
a relaunch in the same directory showed no dialog.

Two operational consequences:

- **It appears on every spawn.** Firstmate gives each task a fresh worktree path,
  which is by definition untrusted, so the dialog fires each time.
- **It is slow.** The dialog took roughly 15-27 seconds to render in this lab,
  noticeably longer than other harnesses, so a post-spawn peek must allow for that
  before concluding the launch failed.

`--trust` exists but is documented and verified as `--print`/headless only, so it
cannot clear the interactive dialog. Trust is stored as
`~/.cursor/projects/<slugified-path>/.workspace-trusted`:

```json
{ "trustedAt": "2026-07-19T12:08:34.966Z", "workspacePath": "/private/tmp/.../lab1" }
```

Pre-seeding that file would avoid the keystroke, but the slug is truncated and
hashed for long paths (observed:
`private-tmp-claude-501-Users-you-treehouse-s-5009b96`), so reproducing it
means reimplementing an unspecified internal hash inside the captain's `~/.cursor`.
The keystroke path is the least invasive mechanism and matches how claude, codex,
and pi trust dialogs are already handled, so firstmate accepts the dialog rather
than writing to Cursor's own state.

## 5. Interrupt, exit, session identity, and resume

| Fact | Value |
|---|---|
| Interrupt | single `Ctrl+C` - cancels the running turn, pane survives |
| Exit | `/quit` or `/exit` (both listed as "Exit"), clean status 0 |
| Session id | a chat UUID, printed on exit |
| Resume | `agent --resume=<chatId>`, **from the original working directory** |

Interrupting mid-tool-call left `$ sleep 45 && echo SLEPT Cancelled • 28s` and
returned the pane to idle with the busy footer gone.

Exit prints the resume line and the pane goes dead with status 0:

```
To resume this session: agent --resume=a06b82e5-bfdb-4003-b545-4248b7539e98
Pane is dead (status 0, Sun Jul 19 14:14:36 2026)
```

**Resume is workspace-scoped, and fails silently.** Chats are stored under
`~/.cursor/chats/<workspace-hash>/<chatId>/`, so resuming the same id from a
different directory does NOT restore the conversation and does NOT error - it
opens a FRESH session (empty composer placeholder `Plan, search, build anything`,
no prior turns) in the launch directory. Recovery must relaunch resume with the
task worktree as cwd; `--resume` alone will not return the agent to where it was.

From the correct directory, resume restored the full conversation with no trust
prompt and preserved the model. The chat's `meta.json` records `cwd` but not the
model, so the model comes from the global default unless `--model` is passed -
another reason to always pass it explicitly.

### Slash-command submit behaviour

Typing `/` opens an autocomplete popup. Unlike grok and codex, the FIRST `Enter`
both completes and executes the highlighted entry: with only `/ex` typed, one
`Enter` ran `/exit`. There is no two-Enter hazard, but there is the inverse risk -
a partially typed slash command runs whichever entry is highlighted, which may not
be the one intended.

## 6. Turn-end notification

Cursor has a **native hook system**, so no polling workaround is needed. Hooks are
read from, in precedence order, an enterprise path, a managed team path,
`~/.cursor/hooks.json` (user), and `<workspace>/.cursor/hooks.json` (project).

Verified live with a project hook:

```json
{ "version": 1, "hooks": { "stop": [ { "type": "command", "command": "date +%s >> /tmp/fm_cursor_stop_hook.log" } ] } }
```

Two turns produced exactly two invocations, confirming it fires per turn and not
only at agent exit:

```
1784463401
1784463434
```

Firstmate installs the per-task hook at `<worktree>/.cursor/hooks.json` and keeps
it out of git via `info/exclude`, the same pattern as the claude and opencode
worktree hooks. Unlike grok, project hooks need NO separate hook-trust grant
beyond the workspace trust the spawn already clears, so no global file and no
write into the captain's `~/.cursor` is required - this is the least invasive
accurate mechanism.

The hook runtime sets `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`,
`CURSOR_TRANSCRIPT_PATH`, and `CLAUDE_PROJECT_DIR`, and `stop`/`subagentStop`
carry a `loop_count` checked against a `loop_limit`, the same loop-guard shape
claude and codex Stop hooks use.

### Claude-compatible hook ingestion (cross-harness hazard)

Cursor also ingests claude-format hooks from `~/.claude/settings.json`,
`<project>/.claude/settings.json`, and `<project>/.claude/settings.local.json`,
mapping claude's event names onto its own (`Stop` -> `stop`,
`UserPromptSubmit` -> `beforeSubmitPrompt`, `PreToolUse` -> `preToolUse`).

Firstmate writes both of those file shapes: `.claude/settings.local.json` per
claude task worktree, and the PRIMARY's own `.claude/settings.json` carrying the
turn-end guard. A disposable worktree only ever gets one harness's hook, so tasks
do not collide - but **never launch a cursor worker from the firstmate primary
checkout**, whose `.claude/settings.json` Stop hook would then run firstmate's own
turn-end guard inside a worker session. The same ingestion is why Cursor's slash
menu surfaces claude-ecosystem skills (`/executing-plans` was listed in this lab).

## 7. Agent-process liveness

Cursor's wrapper `exec`s node, so tmux reports a generic COMM:

```
$ tmux display-message -p '#{pane_current_command}'
node
```

Before this work that landed in `fm_backend_tmux_agent_alive`'s `unknown` bucket,
the same gap pi has. Cursor is recoverable where pi is not: `exec -a` rewrites
argv[0], but the versioned bundle path survives as an argument, giving an
unambiguous marker:

```
$ ps -o args= -p <pane_pid>
/Users/.../.local/bin/agent --use-system-ca /Users/.../cursor-agent/versions/2026.07.16-899851b/index.js --yolo
```

So the tmux probe resolves a `node` COMM through argv and returns `alive` on a
`cursor-agent` match. Verified live, with the dead-shell control unchanged:

```
comm=node
agent_alive=alive
shell_verdict=dead
```

Any other bare `node` still returns `unknown` and is never inferred dead, so the
secondmate-liveness sweep (which respawns only on `dead`) cannot act on an
ambiguous reading.

### Other runtime backends

| Backend | Applicability | Basis |
|---|---|---|
| tmux | verified | reference backend; probe extended and tested live above |
| herdr | composer-safe, liveness unverified | herdr uses a STRUCTURAL composer scan, so the `cursor_y` defect cannot occur, and it shares `fm_composer_strip_ghost` + the shared idle default, so the placeholder fix applies. Its own agent-liveness path was not exercised against cursor. |
| zellij / orca / cmux | not verified for cursor | orca and cmux read a PLAIN (unstyled) screen, so they never see the reverse-video cell and rely on the shared idle-placeholder match, which now covers cursor's two placeholders. No cursor session was run on any of the three. |

These are marked on inspection of each integration surface, not assumption. Only
tmux is claimed as verified for cursor.

## 8. Extension / status-line surface

For the separately queued cross-orchestrator status-bar task: **Cursor CLI exposes
no supported status-line, footer, or terminal-UI API.**

- `statusLine`, `statusLineNode`, and `statusLinePadding` appear in the shipped
  bundle only as internal TUI rendering identifiers. There is no configuration or
  extension key for them.
- There is no claude-style `"statusLine"` settings key (searched; absent).
- `~/.cursor/cli-config.json` has a `display` block
  (`showStatusIndicators`, `showStatusLineRunningTime`) but these are fixed
  boolean toggles for Cursor's own footer, not a content API.
- The extension surface that DOES exist is plugins: `--plugin-dir <path>`,
  `agent plugin marketplace`, and plugin manifests contributing `hooks`,
  `commands`, `agents`, skills, and MCP servers. None of these contribute footer
  or status-line content.

Status-bar parity on cursor therefore cannot use a native API and would need a different mechanism.
The canonical decision is now owned by [`status-bar.md`](status-bar.md): Cursor remains worker-only, so a captain-facing renderer is not applicable and no guarded primary launcher exists on which to install an outer line.

## 9. Model and effort mapping

Cursor is the one verified adapter with **no effort flag**: reasoning effort is a
SUFFIX on the model id. All three tiers were exercised end to end and each
returned a correct answer, with the footer confirming the resolved model:

| Requested effort | Model id | Footer |
|---|---|---|
| low | `cursor-grok-4.5-low` | `Cursor Grok 4.5 Low` |
| medium | `cursor-grok-4.5-medium` | `Cursor Grok 4.5 Medium` |
| high | `cursor-grok-4.5-high` | `Cursor Grok 4.5` |

`xhigh` and `max` have no cursor tier and cap at `high`, per the effort-fallback
rule in the `harness-adapters` skill, rather than being dropped silently. An
explicit model id that already carries a tier (or a `[...]` parameterized form)
wins and is never retiered.

**Fast variants are a separate cost/speed choice and are never selected
implicitly.** `cursor-grok-4.5-*-fast` is only ever used when named explicitly.

## 10. Proven dispatch profile values

`config/crew-dispatch.json` is captain-private and is deliberately NOT edited from
a task worktree. The proven values for firstmate to apply after merge:

| Axis | Value |
|---|---|
| harness | `cursor` |
| model | `cursor-grok-4.5` (the effort axis appends the tier) |
| effort | `low` \| `medium` \| `high` (`xhigh`/`max` cap at `high`) |

## Known limitations

1. **Primary support is unverified.** Worker only; see "Scope" above.
2. **A live `fm-spawn` end-to-end run was not performed from this task.** Spawning
   allocates a real pooled treehouse worktree and writes live fleet state outside
   the task worktree, which a crewmate must not do. Every underlying behaviour was
   verified by raw launches instead, and the launch template, hook install,
   liveness, composer, and effort mapping are covered by
   `tests/fm-cursor-adapter.test.sh`. The first supervised `fm-spawn --harness
   cursor` dispatch remains firstmate's gate before routing volume to it.
3. **Trust costs a keystroke and up to ~30s on every spawn** (section 4).
4. **`--model` mutates the account-global default** (section 2).
5. **Resume fails open into a fresh session from the wrong cwd** (section 5).
6. **Cursor executes claude-format hooks**, so cursor must never be launched from
   the firstmate primary checkout (section 6).
7. **Liveness is verified on tmux only** (section 7).
8. Herdr in this lab was 0.7.4, not the 0.7.3 assumed when the task was written;
   no Herdr lifecycle operation was needed, so the guarded lab was never
   provisioned and the captain's `default` session was never touched.

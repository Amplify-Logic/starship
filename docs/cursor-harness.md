# Cursor CLI harness verification

Empirical verification record for the `cursor` WORKER adapter (the Cursor CLI
`agent` binary), covering the launch, supervision, recovery, and monitoring facts
firstmate depends on.

The distilled operating facts live in the `harness-adapters` skill, which is their
one owner; the exact launch flags live in `bin/fm-spawn.sh`. This document is the
EVIDENCE: dated commands, verbatim output, and the limitations behind each
decision. Regression coverage is `tests/fm-cursor-adapter.test.sh`.

**PRIMARY certified and WORKER partially re-verified 2026-08-13** on:

| Component | Version |
|---|---|
| Cursor CLI (`agent`) | `2026.08.11-e8db854` |
| Model | Cursor Grok 4.6 (`cursor-grok-4.6-{low,medium,high,xhigh}`, each with a `-fast` variant) |
| tmux | 3.6a |
| macOS | 25.5.0 |

The original certification was **2026-07-19** on Cursor CLI `2026.07.16-899851b` with Grok 4.5, and the first primary certification was 2026-07-22 on `2026.07.20-8cc9c0b`.

Sections below carry the date of the evidence they rest on; anything marked 2026-08-13 supersedes the earlier reading.

The 2026-08-13 re-certification changed four operating facts and found three defects in firstmate's own tooling; "What the re-certification changed" at the end of this document is the summary.

`agent` resolves to `~/.local/bin/agent`, a bash wrapper that `exec -a`s a bundled
Node app at `~/.local/share/cursor-agent/versions/<version>/index.js`. That detail
is load-bearing for the liveness probe below.

## Scope: worker and primary

Cursor is verified as a WORKER (crewmate/scout) adapter and, separately, as a PRIMARY orchestrator through `bin/fm-primary.sh cursor-grok`.
As of the 2026-08-13 re-certification the primary role is fully certified on the current build, while the worker role stands at six of the exam's eight probes with exit and resume carried by direct evidence instead.
Worker facts below remain authoritative for `fm-spawn`.
Primary certification evidence is in "Primary orchestrator certification" later in this document.
Never treat worker verification alone as primary support, and never launch a cursor WORKER from the firstmate primary checkout (that checkout's `.claude/settings.json` is the primary's hook surface).

## 1. Identity, authentication, and models

```
$ agent --version
2026.08.11-e8db854

$ agent status
✓ Logged in as your.email@example.com
```

Grok 4.6 shipped 2026-08-12 and exposes **eight** ids, including a tier Grok 4.5 never had (verified 2026-08-13):

```
$ agent --list-models | grep -i grok-4.6
cursor-grok-4.6-low - Cursor Grok 4.6 Low
cursor-grok-4.6-low-fast - Cursor Grok 4.6 Low Fast
cursor-grok-4.6-medium - Cursor Grok 4.6 Medium
cursor-grok-4.6-medium-fast - Cursor Grok 4.6 Medium Fast
cursor-grok-4.6-high - Cursor Grok 4.6
cursor-grok-4.6-high-fast - Cursor Grok 4.6 Fast
cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High
cursor-grok-4.6-xhigh-fast - Cursor Grok 4.6 Extra High Fast
```

The six Grok 4.5 ids recorded on 2026-07-19 are still live alongside them.

### Where the credential actually lives (verified 2026-08-13)

There is no `~/.cursor/auth.json` on this build.

`~/.cursor/cli-config.json` carries identity only - its `authInfo` holds `authId`, `displayName`, `email`, and `userId`, and no token.

The credential is the macOS **login keychain** item `cursor-access-token` (with `cursor-refresh-token` and `cursor-user`).

The login keychain is resolved from `HOME`, not from the user session, so any isolated-`HOME` lab starts logged out:

```
$ HOME=$(mktemp -d) security default-keychain
security: SecKeychainCopyDefault: A default keychain could not be found.

$ HOME=$(mktemp -d) agent status
Not logged in

$ agent status                      # same binary, real HOME
✓ Logged in as your.email@example.com
```

Linking `~/Library/Keychains` into the isolated home restores authentication, which is what `bin/fm-harness-exam.sh --share-login-keychain` does; `docs/harness-exam.md` owns that contract.

`cli-config.json` also changed shape: the selected model is now `{"modelId": "grok-4.6", ...}` plus a `selectedModel.parameters` list carrying `effort` and `fast`, rather than a single suffixed id.
Firstmate does not read that file, so this is recorded as context for the account-default hazard below, not as a dependency.

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

### Model identity vs label truth (verified 2026-07-21)

Incident shape (sample-local-services-run-d1, 2026-07-20): herdr presentation
showed `cursor/gpt-5.6-sol-xh...` from `state/<id>.meta` `model=` while the pane
footer showed `Cursor Grok 4.5 Medium Fast`.

Re-checked on Cursor CLI `2026.07.17-3e2a980`:

| Probe | Result |
|---|---|
| `agent --print --mode ask --model definitely-not-a-real-model-xyz ...` | exit 1; stderr lists available models. **Not** a silent fallback. |
| `agent --print --mode ask --model gpt-5.6-sol-xhigh ...` | exit 0; answer returned; `~/.cursor/cli-config.json` updated to sol. |
| `agent about` / idle footer | show the account-default display name when no effective `--model` applies. |

So an unrecognized id does **not** quietly become the account default on this CLI.
The lying label is still possible when the worker ends up on a different live model
than meta recorded (missing `--model`, account-default inheritance, or a later
runtime substitution such as a third-party pool exhaustion while meta still
carries the requested id). Firstmate's defenses:

1. `fm-spawn` folds cursor effort into the launch model id, records that launch id
   as `model=` (with `model_requested=` when it differs), and refuses unknown ids
   when `agent --list-models` / `FM_CURSOR_MODEL_CATALOG` is available
   (`bin/fm-cursor-model-lib.sh`).
2. `fm-visible-status.sh` prefers the idle pane footer model over meta for cursor
   workers, and writes `model_live=` when they disagree.

Regression coverage: `tests/fm-cursor-adapter.test.sh`,
`tests/fm-visible-status.test.sh`, `tests/fm-spawn-dispatch-profile.test.sh`.

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
- **OPEN (observed once, 2026-08-13, herdr backend): accepting trust can leave the launch prompt sitting unsubmitted in the composer.**
  One spawn started the agent normally but its positional prompt stayed pending in the composer until a manual Enter was sent, which is not how a positional prompt behaves on a launch with no trust gate.
  The likely reading is that the dialog defers the auto-submit and the keystroke that accepts trust only closes the dialog.
  Not reproduced since, and not fixed in code: after accepting a cursor trust dialog, confirm the prompt actually submitted rather than assuming it did, and send one Enter if it did not.

`--trust` exists but is documented and verified as `--print`/headless only, so it
cannot clear the interactive dialog. Trust is stored as
`~/.cursor/projects/<slugified-path>/.workspace-trusted`:

```json
{ "trustedAt": "2026-07-19T12:08:34.966Z", "workspacePath": "/private/tmp/.../lab1" }
```

Pre-seeding that file would avoid the keystroke, but the slug is truncated and
hashed for long paths (observed:
`private-tmp-claude-501-Users-<you>-treehouse-s-5009b96`), so reproducing it
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

On 2026-07-19 exit printed the resume line and the pane went dead with status 0:

```
To resume this session: agent --resume=a06b82e5-bfdb-4003-b545-4248b7539e98
Pane is dead (status 0, Sun Jul 19 14:14:36 2026)
```

### The resume line is gone (verified 2026-08-13)

On `2026.08.11-e8db854`, `/quit` still exits cleanly and returns the pane to its shell, but prints no resume line.

A full scrollback capture after exit (`tmux capture-pane -p -S -120`) contained no `agent --resume=` text at all, while the chat itself was still written to disk:

```
$ ls ~/.cursor/chats/12bb2dd5e49e2b5a6a3b674257ae65f4/
c2bb28b1-351f-4aef-8a5d-5afb18ce6541
```

Resuming with that id from the original working directory restored the prior conversation, so the capability is intact and only its DISCOVERY changed.

Recovery must therefore read the chat id from `~/.cursor/chats/<workspace-hash>/<chatId>/` rather than scraping exit output.

The resume also showed the workspace trust dialog again, so a recovery relaunch must expect it rather than treating it as a failed resume.

Anything that scrapes the printed line - including this repo's own exam resume probe - now finds nothing.

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

### The argv lookup used the wrong process (found and fixed 2026-08-13)

That 2026-07-19 reading came from a lab where `agent` was the pane's own command.

Firstmate never spawns that shape: `fm_backend_tmux_create_task` opens a bare window on the login shell and `spawn_send_literal` types the launch line into it, so the runtime is a CHILD of the pane shell.

`#{pane_current_command}` reports the foreground process, but `#{pane_pid}` reports the pane's own process, and the identity check read argv from `#{pane_pid}` alone.

Measured on a task-shaped pane (Cursor CLI `2026.08.11-e8db854`):

```
pane_current_command = node
pane_pid             = 39955
ps -o args= $pane_pid = bash --noprofile --norc         # no cursor-agent match
first descendant argv = /Users/.../.local/bin/agent --use-system-ca .../cursor-agent/versions/2026.08.11-e8db854/index.js --yolo ...
```

So `fm_tmux_pane_is_cursor` returned false for every real cursor task pane on tmux, with two consequences.

Liveness fell back to `unknown` instead of `alive`, and - the dangerous one - the structural composer scan from section 3 never engaged, so classification fell back to the very `#{cursor_y}` path that scan exists to replace:

```
# same pane, real unsubmitted text in the composer
cursor_y             = 23
row at cursor_y      = []                               # empty status row -> FALSE-EMPTY
structural row       = 18
composer at row 18   = [  → some real unsubmitted text]
```

A false-empty is what `bin/fm-supervise-daemon.sh` reads when picking an injection target, so an away-mode escalation could have been typed on top of pending input - exactly the wedge class the section 3 work was meant to close.

`fm_tmux_pane_argv_matches` (`bin/fm-tmux-lib.sh`) now walks the pane process and its descendants, bounded at five levels, and both cursor and prime-agent identify through it.

`fm_tmux_pane_is_prime_agent` already walked descendants for this same reason (2026-08-07); that walk is now the one shared owner rather than a second copy.

After the fix, on the same task-shaped pane: `pane_is_cursor=yes`, `agent_alive=alive`, `composer_state=empty` when idle and `pending` with text typed.

This is why limitation 2 below (no live `fm-spawn` end-to-end run) mattered: every underlying behaviour was verified in a shape firstmate does not actually produce.

Any other bare `node` still returns `unknown` and is never inferred dead, so the
secondmate-liveness sweep (which respawns only on `dead`) cannot act on an
ambiguous reading.

### Other runtime backends

| Backend | Applicability | Basis |
|---|---|---|
| tmux | verified | reference backend; probe extended and tested live above |
| herdr | composer-safe; busy/blocked corroborated | herdr uses a STRUCTURAL composer scan, so the `cursor_y` defect cannot occur, and it shares `fm_composer_strip_ghost` + the shared idle default, so the placeholder fix applies. Native `blocked` / idle readings are corroborated against the rendered busy footer (`ctrl+c to stop`) before immediate waiting-on-human escalation or poll-path idle (regression: 2026-07-19 `default:wP:p4`; `tests/fm-backend-herdr.test.sh`, `tests/fm-supervision-events.test.sh`). Process-level agent-alive still follows herdr's registered `agent get` path, not tmux argv introspection. |
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
The canonical decision is now owned by [`status-bar.md`](status-bar.md): Cursor primary is certified, but with no third-party status-line API the guarded launcher installs no companion bar.

## 9. Model and effort mapping

Cursor is the one verified adapter with **no effort flag**: reasoning effort is a
SUFFIX on the model id. All three tiers were exercised end to end on 2026-07-19 and each
returned a correct answer, with the footer confirming the resolved model:

| Requested effort | Model id | Footer |
|---|---|---|
| low | `cursor-grok-4.5-low` | `Cursor Grok 4.5 Low` |
| medium | `cursor-grok-4.5-medium` | `Cursor Grok 4.5 Medium` |
| high | `cursor-grok-4.5-high` | `Cursor Grok 4.5` |

An explicit model id that already carries a tier (or a `[...]` parameterized form)
wins and is never retiered.

### The tier ladder is per-model, not fixed (corrected 2026-08-13)

"`xhigh` and `max` have no cursor tier" was true of Grok 4.5 and is false of Grok 4.6, which ships `cursor-grok-4.6-xhigh` and `cursor-grok-4.6-xhigh-fast`.

Capping at `high` unconditionally produced two wrong launches, both reproduced against `cursor_model_with_effort` before the fix:

| Input | Was | Now |
|---|---|---|
| `cursor-grok-4.6` + effort `xhigh` | `cursor-grok-4.6-high` (silently under-tiered) | `cursor-grok-4.6-xhigh` |
| `cursor-grok-4.6-xhigh` + effort `high` | `cursor-grok-4.6-xhigh-high` (no such id) | `cursor-grok-4.6-xhigh` |

The second was the worse one: `-xhigh` does not end in `-high`, so it missed the already-tiered passthrough, and the fabricated id then failed the catalog preflight and refused the spawn outright.

A captain naming the exact `-xhigh` id could not dispatch at all.

`xhigh` and `max` now resolve against `agent --list-models`: the real `-xhigh` tier when that model has one, `-high` otherwise, and `-high` when the catalog cannot be read, since `-high` is the tier every verified cursor model has.

Fast variants remain a separate cost choice that the effort axis never selects.

Regression coverage pins both ladders from catalog fixtures rather than from whichever build the test machine has installed (`tests/fm-cursor-adapter.test.sh`).

**Fast variants are a separate cost/speed choice and are never selected
implicitly.** `cursor-grok-4.5-*-fast` is only ever used when named explicitly.

## 10. Proven dispatch profile values

`config/crew-dispatch.json` is captain-private and is deliberately NOT edited from
a task worktree. The proven values for firstmate to apply after merge:

| Axis | Value |
|---|---|
| harness | `cursor` |
| model | `cursor-grok-4.6` (the effort axis appends the tier) |
| effort | `low` \| `medium` \| `high` \| `xhigh` (`max` folds to `xhigh` on 4.6) |

One live rule needs correcting rather than extending: the standing crew default records that
`cursor-grok-4.6-high-fast` is "the ONLY 4.6 id offered - the `-fast` suffix is therefore not an implicit
cost upgrade but the only route to the model the captain named".

That was true when the rule was written and is false as of 2026-08-13: all eight Grok 4.6 ids are live,
including the non-fast `cursor-grok-4.6-high`.

The `-fast` choice may still be the right one, but it is now a deliberate cost/speed decision that needs
the captain's word rather than a workaround justified by an absent alternative.

## Known limitations

1. ~~**Primary Stop hooks failed on Cursor CLI `2026.07.20-8cc9c0b`.**~~ RESOLVED 2026-08-13: on `2026.08.11-e8db854` a single completed TUI turn fired Claude-format `Stop`, native `stop`, native `beforeSubmitPrompt`, and `PreToolUse` together. See "Primary orchestrator certification".
2. **A live `fm-spawn` end-to-end run has still not been performed.** Spawning
   allocates a real pooled treehouse worktree and writes live fleet state outside
   the task worktree, which a crewmate must not do. This gap is what hid the
   pane-identity defect in section 7 for three weeks: every 2026-07-19 probe ran
   against a raw launch where `agent` was the pane's own process, a shape
   `fm-spawn` never produces. The 2026-08-13 re-certification closed that
   specific hole by measuring a task-shaped pane directly, but the first
   supervised `fm-spawn --harness cursor` dispatch remains firstmate's gate
   before routing volume to it.
3. **Trust costs a keystroke and up to ~30s on every spawn** (section 4).
4. **`--model` mutates the account-global default** (section 2).
5. **Resume fails open into a fresh session from the wrong cwd** (section 5).
6. **Cursor executes claude-format hooks**, so cursor WORKERS must never be launched from
   the firstmate primary checkout (section 6). Launching cursor as the PRIMARY from that checkout is intentional.
7. **Liveness is verified on tmux only** (section 7).
8. Herdr in the 2026-07-19 worker lab was 0.7.4, not the 0.7.3 assumed when that task was written;
   the 2026-07-22 primary lab also used Herdr 0.7.4 with `bin/fm-herdr-lab.sh`.
   The 2026-08-13 re-certification used tmux only, so the herdr readings above are not re-confirmed on this build.
9. **The exam cannot drive cursor's exit and resume probes on this build** (see "What the re-certification changed").
   `/quit` and `--resume` both work when driven directly, but under `docs/harness-exam.md`'s own rule a version
   counts as re-verified only at eight passes, so the worker role stands at six with two probes carried by
   direct evidence instead.

## Primary orchestrator certification

**Re-certified 2026-08-13** on Cursor CLI (`agent`) `2026.08.11-e8db854`, in an isolated tmux lab with a private HOME and a throwaway workspace (never the primary checkout).

Guarded launcher profile: `bin/fm-primary.sh cursor-grok` → `agent --yolo --model cursor-grok-4.6-high`.
`FM_PRIMARY_HARNESS=cursor` is exported for stable detection.
Worker adapter behavior is intentionally unchanged.

Grok 4.6 also offers `-xhigh`, so `-high` is now a deliberate cost choice rather than the ceiling it was on Grok 4.5.

| Mechanism | Result | Evidence |
|---|---|---|
| session-start | PASS | Claude-format `SessionStart` from `.claude/settings.json` fired on interactive launch. |
| turn-end / Stop | **PASS (was FAIL)** | One completed TUI turn appended to all four hook logs: Claude-format `Stop` AND native `.cursor/hooks.json` `stop`, plus native `beforeSubmitPrompt`. This is the mechanism that did not fire on `2026.07.20-8cc9c0b`. |
| PreToolUse seatbelt | PASS | Claude-format `PreToolUse` fired on the shell tool call in the same turn. |
| supervision protocol | PASS | `docs/supervision-protocols/cursor.md` rendered by `bin/fm-supervision-instructions.sh --harness cursor`. |
| session lock | PASS | Shared `bin/fm-lock.sh` + `fm-primary` active-session refusal (profile-agnostic; `tests/fm-primary.test.sh`). |
| status-bar | DOCUMENTED-GAP | No third-party status-line API (section 8); launcher installs no companion pane. |

The 2026-07-22 reading is superseded: the primary turn-end guard can now be claimed as wired rather than best-effort.

### The version gate no longer blocks

The old launcher refused any build but `2026.07.20-8cc9c0b`, and that exact-match block existed only because Stop was unverified there.

On the installed build the launcher therefore refused to start at all:

```
$ FM_PRIMARY_DRY_RUN=1 bin/fm-primary.sh cursor-grok
fm-primary: Cursor primary support is verified only for 2026.07.20-8cc9c0b; found 2026.08.11-e8db854
```

Cursor self-updates, so an equality gate in front of it turns every publisher release into an unscheduled outage of the certified primary rather than a merely uncertified one - the reasoning `bin/fm-toolchain-lib.sh` already applies fleet-wide, and the same change Kimi received.

An unrecognized build now warns and launches.
The check that can still refuse is an explicitly logged-out CLI, because that would boot the primary to a login screen instead of a session; an unreadable `agent status` is not treated as evidence of being logged out.

`--print` / `--mode ask` is still not a valid primary hook lab.
Keep primary hook probes on an interactive Cursor TUI in an isolated lab.

## What the re-certification changed (2026-08-13)

Scope: Cursor CLI `2026.08.11-e8db854` with Grok 4.6, both roles, requested by the captain on 2026-08-13.

### Roles

**PRIMARY: certified.**
Every mechanism was verified directly, including the `Stop` turn-end hook that failed on the previously certified build.
The launcher also stopped refusing to start: it had hard-blocked every build but `2026.07.20-8cc9c0b`, so Cursor's own auto-update had already made `bin/fm-primary.sh cursor-grok` unlaunchable before this work began.

**WORKER: six of eight exam probes pass.**
Autonomy, composer, busy, interrupt, turn-end, and liveness pass on `bin/fm-harness-exam.sh`.
Exit and resume do not, and `docs/harness-exam.md` requires eight for a version to be called re-verified, so the worker role is deliberately NOT claimed as a full eight-point re-verification.
Both underlying capabilities were confirmed by hand: `/quit` returned the pane to its shell, and `agent --resume=<chatId>` restored a prior conversation.
The resume probe cannot pass as written because this build no longer prints the resume id it scrapes.
The exit probe's failure is not explained: `/quit` executed reliably when typed by hand at the same idle state, and neither waiting for the turn to end nor lengthening the settle before Enter made the probe drive it.

### Runtime behaviour that changed

1. **Grok 4.6 added an `-xhigh` tier**, so cursor's effort ladder is per-model rather than capped at `-high` for every model.
2. **Exit no longer prints the resume id**, so recovery must read it from `~/.cursor/chats/<workspace-hash>/`.
3. **Credentials moved out of reach of an isolated `HOME`**: the token is a login-keychain item, and the login keychain is `HOME`-relative.
4. **`cli-config.json` records the model as a base id plus parameters** rather than one suffixed id.

### Defects found in firstmate's own tooling

These were pre-existing and are the reason a routine re-certification took three labs.

1. **Cursor panes were never identified on tmux.** The argv check read `#{pane_pid}`, which is the login shell in every pane `fm-spawn` creates, so liveness degraded to `unknown` and - the dangerous one - the structural composer scan never engaged, leaving real unsubmitted text classifiable as `empty` for the away-mode injector. Section 7 carries the measurement.
2. **The exam scored an unauthenticated lab as eight runtime failures.** A setup gap read as a total runtime regression; it now stops with its own exit code and no scorecard.
3. **The exam's own hook path silently disabled the hook it was testing.** `LAB_ROOT` inherited the trailing slash from macOS `TMPDIR`, and Cursor does not execute a hook command whose path contains `//`, so the turn-end probe failed while the mechanism worked. Normalizing the path turned that probe green.

Defect 1 is the one that mattered beyond this task: it affected live cursor workers on the tmux backend, not just the lab.

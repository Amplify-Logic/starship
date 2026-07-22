# Native session-start nudge

AGENTS.md section 3 remains the single authoritative behavioral contract for session start.
The tracked native adapters are an enforcement layer that injects one instruction and never runs the digest, lock acquisition, bootstrap sweeps, wake drain, or supervision arm itself.
The injected line is exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the two hooks cannot drift on primary detection.
The Shared Predicate section of `docs/turnend-guard.md` remains authoritative for marker validation, plain-checkout detection, and the required firstmate-shaped paths.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid, matching `bin/fm-lock.sh` and Pi's `lockOwnership()` ancestry depth.
If the lock names a live pid in that ancestry, session-start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Observed posture |
|---|---|---|
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is verified, and the tracked wiring is smoke-checked by `tests/fm-sessionstart-nudge.test.sh`. |
| Codex | `.codex/hooks.json` reads the payload, anchors to hook process `pwd -P`, verifies a firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is verified on Codex 0.144.4. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs the wrapper once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Verified in the interactive TUI on OpenCode 1.17.18 and intentionally fail-open in headless `opencode run`. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message enters model context without racing an initial positional prompt, and the changed extension passes strict TypeScript checking on Pi 0.80.10. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project event fires on Grok 0.2.103, but hook stdout does not reach model context, so this path is documented fail-open. |
| Kimi | `bin/fm-primary.sh` installs an isolated managed plugin whose native `sessionStart.skill` contains the nudge. | Kimi 0.27.0 discards ordinary SessionStart hook stdout; the native plugin skill is injected into model context on startup, resume, and `/new`. |
| Cursor | Tracked `.claude/settings.json` `SessionStart` (Cursor maps it onto native `sessionStart`). | Verified 2026-07-22 on Cursor CLI `2026.07.20-8cc9c0b` in an isolated Herdr lab: Claude-format SessionStart fired on interactive primary launch. Native `.cursor/hooks.json` `sessionStart` did not fire in the same run. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end guard plugins run later on `session.idle`, and the turn-end guard continues to let the watcher coordinator act first, so the three plugins do not race for one lifecycle event.

## Empirical validation on 2026-07-17

All scratch runs used isolated git repositories under `.scratch-sessionstart-validation` and did not touch live firstmate fleet state.

### Codex 0.144.4

Command run from the scratch repository:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --output-last-message last.txt 'Follow any SessionStart hook context before this prompt. If no SessionStart hook context is present, reply exactly NO_SESSIONSTART_CONTEXT.'
```

The hook payload was:

```json
{"session_id":"019f729b-dd85-7d81-a94c-5696da142f37","transcript_path":null,"cwd":"$HOME/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/codex","hook_event_name":"SessionStart","model":"gpt-5.6-sol","permission_mode":"bypassPermissions","source":"startup"}
```

Codex logged `hook: SessionStart Completed`, and `last.txt` contained exactly `CODEX_SESSIONSTART_CONTEXT`.
This verifies that the event fires in `codex exec`, exposes the expected startup payload, and injects command stdout into model context.

### Grok 0.2.103

Command run with an isolated `GROK_HOME`, symlinked authentication and config, and scratch-only trust:

```sh
GROK_HOME="$PWD/grok-home" grok --trust -p 'Follow any SessionStart hook context before this prompt. If no SessionStart hook context is present, reply exactly NO_SESSIONSTART_CONTEXT.' --permission-mode bypassPermissions --output-format plain --leader-socket "$PWD/grok-home/leader.sock"
```

The hook payload was:

```json
{"hookEventName":"session_start","sessionId":"019f729c-279d-7920-9d1f-66ae112dcf78","cwd":"$HOME/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/grok","workspaceRoot":"$HOME/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/grok/","timestamp":"2026-07-18T00:24:24.878540+00:00","source":"new"}
```

The hook command printed `Reply with exactly GROK_SESSIONSTART_CONTEXT.`.
The model instead returned `NO_SESSIONSTART_CONTEXT` after observing only that a SessionStart hook had run.
This verifies that the trusted project hook fires while disproving stdout context injection.

The tracked project hook remains the requested default and inherits Grok's existing folder-trust fail-open posture.
Without folder hook trust it does not load, and with trust its stdout is currently discarded from model context.
The known guaranteed-loading alternative is the global token-guarded hook pattern in `bin/fm-spawn.sh`, but installing files under `~/.grok/hooks/` expands trust and writes outside the repository.
Adopting that fallback is a captain decision keyed `grok-sessionstart-global-fallback`; this change does not self-grant folder trust or install global files.

### OpenCode 1.17.18

Headless command run:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO 'Reply exactly OPENCODE_INITIAL.'
```

The plugin observed a `session.created` event whose `properties.sessionID` and `properties.info.id` were both `ses_08d630a04ffehetb0dr0bJUrYS`.
`client.session.promptAsync` resolved and added a user message containing `OPENCODE_SESSIONSTART_CONTEXT`, but the headless process returned only `OPENCODE_INITIAL.` and exited before another model turn.

Interactive command run:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Reply exactly OPENCODE_INITIAL_TUI.' --print-logs --log-level INFO --mini
```

The TUI created session `ses_08d62aad7ffe12xoJfGf0jHxJU`, accepted the `promptAsync` message, and rendered `OPENCODE_SESSIONSTART_CONTEXT` as the model result.
This verifies `session.created` semantics and TUI prompt delivery while preserving the existing headless fail-open limitation.

### Claude and Pi wiring smoke checks

`jq empty .claude/settings.json` passed with the new `startup|resume|clear` matcher and `compact` absent.
`tests/fm-sessionstart-nudge.test.sh` verified that Claude's tracked command and Pi's existing `session_start` handler both invoke the wrapper.
`tests/fm-pi-primary-types.test.sh` passed strict no-emit TypeScript checking against Pi 0.80.10.
An initial Pi live smoke using `sendUserMessage` showed that starting a second turn from `session_start` races Pi's positional prompt and exits with `Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.`.
The integration therefore uses `pi.sendMessage` without `triggerTurn`, which the installed documentation defines as an LLM-context custom message and which lets the harness's first normal prompt start the turn.
The corrected live smoke command was `pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session 'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'` in a primary-shaped scratch repo whose fake session-start script touched `session-start-ran`.
Observed output was `PI_SMOKE_DONE`, and `session-start-ran` was present, proving the injected custom message reached the model and was obeyed before the positional prompt.
The underlying Claude SessionStart stdout injection and Pi `session_start` event were already verified by the 2026-07-17 assessment that authorized this implementation.

### Kimi Code 0.27.0

The Kimi run used a plain scratch Firstmate clone, isolated `FM_HOME` and `KIMI_CODE_HOME` directories, and a named non-default Herdr session on 2026-07-19.
Every Herdr operator call went through `fm-herdr-lab.sh`, and the guarded teardown left the running `default` session byte-identical to its pre-provision tripwire.

The exact launch shape was:

```sh
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start LAB-FIRSTMATE-PLAIN \
  --cwd "$SCRATCH_ROOT" --no-focus \
  --env "FM_HOME=$SCRATCH_HOME" \
  --env "FM_KIMI_SOURCE_HOME=$ISOLATED_KIMI_SOURCE" \
  --env 'FM_KIMI_BIN=$HOME/.kimi-code/bin/kimi' \
  --env 'FM_PRIMARY_VISIBLE_PREFIX=LAB' \
  -- "$SCRATCH_ROOT/bin/fm-primary.sh" kimi-k3
```

The startup TUI printed these exact safe fields:

```text
Model:     K3
Version:   0.27.0
yolo  K3 thinking: max
```

On the first prompt, Kimi ran `bin/fm-session-start.sh` before replying and printed:

```text
• Primary harness: kimi
• Lock: acquired — held by this session (pid 13478)
```

`/new` created `session_f03d64aa-8cda-46c1-a9e3-f45bc7ecef48`, reset displayed context to `0% (0/256k)`, and the next turn ran the nudge command before returning `NEW_SESSION_NUDGE_OK`.
`/sessions`, followed by selecting the earlier session, printed `Resumed session (session_04558657-d3b3-48f0-9f6f-c9a97985f8d0).`, and the resumed turn ran the nudge command before returning `RESUME_NUDGE_OK`.
After `/exit` closed the Kimi process, a fresh launcher invocation accepted the stale lock, `/sessions` resumed that same durable session, and the first turn returned `REOPEN_RESUME_OK` after running session start under the new pid.

The two non-empty session wires contained exactly one native plugin reminder and one exact nudge apiece:

```text
session_04558657-d3b3-48f0-9f6f-c9a97985f8d0 plugin_session_start_records=1 exact_nudge_records=1
session_f03d64aa-8cda-46c1-a9e3-f45bc7ecef48 plugin_session_start_records=1 exact_nudge_records=1
```

Resume replays the existing reminder into model context instead of appending a duplicate record.
This is why the managed plugin uses native `sessionStart.skill`; Kimi's ordinary `SessionStart` command hook executes, but its stdout is not a model-context transport.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact one-line output for a plain primary and a marked linked secondmate primary.
It also verifies tracked wrapper registration for Claude, Codex, OpenCode, Pi, and Grok.
`tests/fm-primary.test.sh` verifies the isolated managed Kimi plugin's native session-start skill and primary-only registration path.
`tests/fm-turnend-guard.test.sh` continues to cover the same shared primary scope through the turn-end path.

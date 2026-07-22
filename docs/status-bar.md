# Firstmate status bar

This file is the single owner of the Firstmate primary status-bar contract.
`bin/fm-status-bar.sh` owns rendering mechanics, and each primary adapter supplies only the metrics its tool exposes.

## Canonical line

After ANSI styling is removed, every renderer uses this field order:

```text
⚓ <model>·<effort> │ 🧠<context-remaining> ⚡<provider-quota-used> │ 🚢<active> ⏸<paused> ⚠<attention> │ 👁 <supervision> │ $<session-cost> │ 💤<afk>
```

The separator is one space, a dim `│`, and one space.
Renderers keep the order and meanings fixed instead of substituting tool-specific footer fields.
Width-constrained surfaces clip or truncate the canonical line without wrapping or changing native interaction controls.

| Field | Meaning | Placeholder |
| --- | --- | --- |
| `⚓ model·effort` | The active model and reasoning or thinking effort reported by the orchestrator. | `--` for either unavailable value. |
| `🧠 context` | The integer percentage of the model context window remaining. | `--` when the orchestrator does not expose current context use. |
| `⚡ quota` | The integer percentage of the provider's short-window quota already used. | `--` when the provider or orchestrator does not expose quota. |
| `🚢 active` | Ordinary task records currently owned by this Firstmate home, excluding persistent second mates. | `0` when no ordinary tasks exist. |
| `⏸ paused` | Active tasks whose latest non-empty event declares a bounded external wait. | `0` when none are paused. |
| `⚠ attention` | Active tasks whose latest non-empty event requires action because it is a decision, blocker, or failure. | `0` when none need attention. |
| `👁 supervision` | Age in seconds of `state/.last-watcher-beat`. | Bright-red `NO-WATCH --` when the beacon is missing or unreadable. |
| `$ cost` | Cumulative cost in US dollars for the current orchestrator session, rounded to two decimals. | `$--` when the orchestrator does not expose cost. |
| `💤 AFK` | Whether the Firstmate home is in away mode. | Dim `💤--` when away mode is off. |

Counts are cheap local projections, not full worker reconciliation.
An ordinary task remains active while its metadata exists, including the interval between completion and cleanup.
A persistent second mate never contributes to the three task counts.

## Thresholds and colors

ANSI renderers use bright colors for state and alerts.
Green is ANSI 92, yellow is ANSI 93, red is ANSI 91, cyan is ANSI 96, dim is ANSI 2, and reset is ANSI 0.
`NO-WATCH` is always bold bright red with ANSI `91;1`.

| Metric | Green | Yellow | Red |
| --- | --- | --- | --- |
| Context remaining | 30 through 100 percent. | 15 through 29 percent. | 0 through 14 percent. |
| Provider quota used | 0 through 69 percent. | 70 through 89 percent. | 90 through 100 percent. |
| Supervision freshness | Beacon age below 180 seconds. | Not used. | Beacon age of 180 seconds or more, or a missing or unreadable beacon. |

The active count is bright green.
The paused count is bright yellow only when nonzero and dim otherwise.
The attention count is bright red only when nonzero and dim otherwise.
The active AFK flag is bright cyan.
Unavailable provider metrics are dim and never silently converted to zero.

## Adapter surfaces

### Claude Code

Tracked `.claude/settings.json` registers `bin/fm-status-bar.sh --adapter claude` through Claude's native `statusLine` command API.
The command consumes Claude's model, effort, context-remaining, five-hour quota, and cumulative-cost JSON fields.
When context-remaining is numeric, the renderer also persists a durable sample to `state/.primary-context` for the optional primary-handoff context axis (see [`docs/primary-handoff.md`](primary-handoff.md)); captain-facing display semantics are unchanged.
The renderer emits nothing unless `bin/fm-primary.sh` supplied `FM_PRIMARY_HARNESS=claude`.
This keeps the tracked project setting inert for an unguarded manual Claude launch.

### Pi

Tracked `.pi/extensions/fm-primary-status-bar.ts` uses Pi's native `ctx.ui.setFooter()` API.
It gets model, thinking level, context use, and session-entry cost from Pi, then delegates canonical rendering and fleet sampling to `bin/fm-status-bar.sh`.
Pi 0.80.10 exposes no provider-quota value to this footer, so quota is `--`.
The extension uses Pi TUI's `truncateToWidth()` and a one-second cached refresh, and it does not replace the editor or keyboard controls.
The extension is inert unless `bin/fm-primary.sh` supplied `FM_PRIMARY_HARNESS=pi`.

### Kimi Code/K3

Kimi Code 0.27.0 has a native status bar but no supported plugin or configuration API for third-party status content.
Its plugin surface provides skills, MCP servers, and lifecycle hooks, while the native footer remains internal.
`bin/fm-primary.sh kimi-k3` therefore adds a one-row tmux companion pane only when the guarded primary runs inside tmux.
The companion delegates to `bin/fm-status-bar.sh`, disables terminal autowrap, leaves Kimi's own footer and controls unchanged, and exits when the Kimi pane exits.
Kimi's model is known from the guarded K3 profile, while effort, context, quota, and session cost use `--` because Kimi does not expose them to the plugin or launcher.
Outside tmux there is no non-invasive persistent Kimi surface, so the launcher leaves the native TUI untouched rather than claiming false parity.

### Cursor CLI

Cursor CLI is worker-only in the status-bar owner: there is no captain-facing Cursor status renderer, and a Cursor primary profile must not gain one as part of status-bar work.
A captain-facing Cursor renderer is therefore not applicable.
Cursor CLI exposes no supported third-party status-line, footer, or terminal-UI API, as recorded in [`cursor-harness.md`](cursor-harness.md#8-extension--status-line-surface).
`bin/fm-primary.sh cursor-grok` certifies primary supervision separately and deliberately installs no companion status bar.
Adding a wrapper-owned line solely for display would falsely imply a status-line API exists, so the closest safe implementation remains no installation.

## Local activation after merge

Claude's earlier prototype is local to the primary home's `.claude/settings.local.json`.
After this change lands, remove only that local `statusLine` entry so it no longer overrides tracked `.claude/settings.json`.
Do not copy a renderer into `state/` and do not edit `~/.claude`, `~/.kimi-code`, `~/.pi`, or `~/.cursor`.
The next guarded Claude, Pi, or Kimi primary launch loads the tracked integration automatically.

## Verification record

The adapter contract was checked on 2026-07-19 with Claude Code's project status-line payload shape, Kimi Code 0.27.0, Pi 0.80.10, Cursor CLI 2026.07.16-899851b, and tmux 3.6a.
The installed Pi documentation and example at `examples/extensions/custom-footer.ts` show `ctx.ui.setFooter()`, `render(width)`, and `truncateToWidth()`.
The installed Kimi help and public 0.27.0 plugin documentation expose lifecycle hooks but no footer renderer.
The installed Cursor help exposes plugin directories but no status-line configuration or footer renderer.

```sh
pi --version
kimi --version
agent --version
bash tests/fm-status-bar.test.sh
bash tests/fm-primary.test.sh
bash tests/fm-pi-primary-types.test.sh
bin/fm-lint.sh
```

Observed version output:

```text
0.80.10
0.27.0
2026.07.16-899851b
```

Claude's adapter was exercised directly with the same JSON shape supplied to the native status-line command:

```sh
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-claude-live.XXXXXX")
mkdir -p "$tmp_root/state"
: > "$tmp_root/state/.last-watcher-beat"
printf '%s' '{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":64.8},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":2.345}}' |
  env FM_PRIMARY_HARNESS=claude FM_HOME="$tmp_root" bin/fm-status-bar.sh --adapter claude |
  perl -pe 's/\e\[[0-9;]*m//g'
rm -rf "$tmp_root"
```

Observed output:

```text
⚓ Claude Fable·high │ 🧠64% ⚡12% │ 🚢0 ⏸0 ⚠0 │ 👁 1s │ $2.35 │ 💤--
```

Pi's installed extension was loaded in a real 140-column Pi TUI with an isolated configuration and no model login:

```sh
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-pi-live.XXXXXX")
session="fm-status-pi-live-$$"
mkdir -p "$tmp_root/home/state" "$tmp_root/pi"
: > "$tmp_root/home/state/.last-watcher-beat"
tmux new-session -d -s "$session" -x 140 -y 30 \
  "env FM_PRIMARY_HARNESS=pi FM_HOME='$tmp_root/home' PI_CODING_AGENT_DIR='$tmp_root/pi' pi --offline --approve --no-session --no-extensions -e '$PWD/.pi/extensions/fm-primary-status-bar.ts' --no-skills --no-context-files --name STATUS-TEST"
sleep 4
tmux capture-pane -p -t "$session":0.0 -S -30
tmux send-keys -t "$session":0.0 '/quit' Enter
sleep 1
tmux kill-session -t "$session" 2>/dev/null || true
rm -rf "$tmp_root"
```

The TUI listed `fm-primary-status-bar.ts` under loaded extensions and rendered:

```text
⚓ unknown·off │ 🧠-- ⚡-- │ 🚢0 ⏸0 ⚠0 │ 👁 3s │ $0.00 │ 💤--
```

A 48-column rerun stayed on one row and ended at `👁 NO-WA`, confirming that Pi truncates the ANSI line to the supplied render width instead of wrapping it.

Kimi's non-native fallback was exercised in a real 140-column one-row tmux companion:

```sh
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-kimi-live.XXXXXX")
session="fm-status-kimi-live-$$"
mkdir -p "$tmp_root/home/state"
tmux new-session -d -s "$session" -x 140 -y 12 'sleep 8'
main_pane=$(tmux display-message -p -t "$session":0.0 '#{pane_id}')
status_pane=$(tmux split-window -d -P -F '#{pane_id}' -v -l 1 -t "$main_pane" \
  "env FM_PRIMARY_HARNESS=kimi FM_HOME='$tmp_root/home' FM_STATUS_BAR_INTERVAL=1 '$PWD/bin/fm-status-bar.sh' --adapter kimi --model kimi-code/k3 --effort -- --follow-pane '$main_pane'")
sleep 2
tmux capture-pane -p -t "$status_pane" -S -1
tmux kill-session -t "$session" 2>/dev/null || true
rm -rf "$tmp_root"
```

Observed output:

```text
⚓ kimi-code/k3·-- │ 🧠-- ⚡-- │ 🚢0 ⏸0 ⚠0 │ 👁 NO-WATCH -- │ $-- │ 💤--
```

`tests/fm-status-bar.test.sh` passed canonical order, threshold, placeholder, supervision-alert, Claude-payload, control-byte sanitization, exact-pane cleanup, guarded-installation, and Cursor-boundary cases.
`tests/fm-primary.test.sh` passed the guarded Kimi companion case alongside all existing launcher cases.
`tests/fm-pi-primary-types.test.sh` reported an honest skip because the host TypeScript 4.9.5 cannot parse Pi 0.80.10's declarations, while the real Pi TUI loaded and ran the TypeScript extension.
`bin/fm-lint.sh` passed with the repository-pinned ShellCheck 0.11.0.

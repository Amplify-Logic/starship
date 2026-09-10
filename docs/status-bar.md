# Firstmate status bar

This file is the single owner of the Firstmate primary status-bar contract.
`bin/fm-status-bar.sh` owns rendering mechanics, and each primary adapter supplies only the metrics its tool exposes.

## Canonical line

After ANSI styling is removed, every renderer uses this field order:

```text
⚓ <model>·<effort> [<account-role>] │ 🧠<context-used> ⚡<provider-quota-used> │ 🚢<active> ⏸<paused> ⚠<attention> │ 👁 <supervision> │ $<session-cost> │ 💤<afk>
```

The separator is one space, a dim `│`, and one space.
Renderers keep the order and meanings fixed instead of substituting tool-specific footer fields.
Width-constrained surfaces clip or truncate the canonical line without wrapping or changing native interaction controls.

| Field | Meaning | Placeholder |
| --- | --- | --- |
| `⚓ model·effort` | The active model and reasoning or thinking effort reported by the orchestrator. | `--` for either unavailable value. |
| `[account-role]` | A compact role word for the vendor account this primary is running on, attached to the model identity rather than forming its own group. | Omitted entirely when the account is unknown. |
| `🧠 context` | The integer percentage of the model context window already used. | `--` when the orchestrator does not expose current context use. |
| `⚡ quota` | The integer percentage of the provider's short-window quota already used. | `--` when the provider or orchestrator does not expose quota. |
| `🚢 active` | Ordinary task records currently owned by this Firstmate home, excluding persistent second mates. | `0` when no ordinary tasks exist. |
| `⏸ paused` | Active tasks whose latest non-empty event declares a bounded external wait. | `0` when none are paused. |
| `⚠ attention` | Active tasks whose latest non-empty event requires action because it is a decision, blocker, or failure. | `0` when none need attention. |
| `👁 supervision` | Age in seconds of `state/.last-watcher-beat`. | Bright-red `NO-WATCH --` when the beacon is missing or unreadable. |
| `$ cost` | Cumulative cost in US dollars for the current orchestrator session, rounded to two decimals. | `$--` when the orchestrator does not expose cost. |
| `💤 AFK` | Whether the Firstmate home is in away mode. | Dim `💤--` when away mode is off. |

The account role is dim and is a ROLE word such as `Team`, `Max`, or `Plus`.
It is rendered only from a verified account name: an explicit `--role`, else `FM_PRIMARY_ACCOUNT_ROLE`
(which `bin/fm-primary.sh` sets on its companion panes), else the account owner's own `FM_ACCOUNT_NAME`,
which is how the label reaches the native Claude, Pi, and Cursor surfaces as well as the companions.
An unknown ambient account renders no label at all instead of a guess.
Acceptance is a positive rule, not a denylist: the value must be entirely alphabetic and at most twelve
characters. Anything else - a bare numeric account id, a UUID or any prefix of one, or a value carrying
punctuation or spaces - is dropped whole rather than shortened, so neither an account ID or email address
nor a truncated fragment of one can ever reach the status row.
This field consumes whatever account identity the account owner resolves; it never defines its own.

Counts are cheap local projections, not full worker reconciliation.
An ordinary task remains active while its metadata exists, including the interval between completion and cleanup.
A persistent second mate never contributes to the three task counts.

## Thresholds and colors

ANSI renderers use bright colors for state and alerts.
Green is ANSI 92, yellow is ANSI 93, red is ANSI 91, cyan is ANSI 96, dim is ANSI 2, and reset is ANSI 0.
`NO-WATCH` is always bold bright red with ANSI `91;1`.

| Metric | Green | Yellow | Red |
| --- | --- | --- | --- |
| Context used | 0 through 70 percent. | 71 through 85 percent. | 86 through 100 percent. |
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
The command consumes Claude's model, effort, context-used (`context_window.used_percentage`, falling back to deriving used from `remaining_percentage` when used is absent), five-hour quota, and cumulative-cost JSON fields.
When context used is numeric, the renderer also persists a durable sample to `state/.primary-context` for the optional primary-handoff context axis (see [`docs/primary-handoff.md`](primary-handoff.md)), deriving remaining as `100 - used` for the sample API.
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
`bin/fm-primary.sh kimi-k3` therefore attaches the shared companion pane described under "Shared companion surface" below, which leaves Kimi's own footer and controls unchanged.
Kimi's model is known from the guarded K3 profile, while effort, context, quota, and session cost use `--` because Kimi does not expose them to the plugin or launcher.
Outside a verified companion provider there is no non-invasive persistent Kimi surface, so the launcher leaves the native TUI untouched rather than claiming false parity.

### Cursor CLI

Cursor CLI 2026.09.08 exposes a native custom status line: a single `statusLine` object of
`{type: "command", command, padding?, updateIntervalMs?, timeoutMs?}` in its user configuration.
The command receives a JSON payload on stdin and its stdout is rendered as the status row.
This supersedes the earlier record that Cursor had no third-party status surface.
`bin/fm-status-bar.sh --adapter cursor` consumes `model.display_name` (falling back to `model.id`),
`model.param_summary` as effort, and `context_window.used_percentage` with the same
`remaining_percentage` fallback the Claude adapter uses.
The payload carries no provider quota and no session cost, so `⚡` and `$` stay `--` rather than being
derived from anything else.

Scope matters here: Cursor validates `statusLine` only in the user-level `cli-config.json`.
A tracked per-project `.cursor/cli.json` is rejected with `Unrecognized key(s) in object: 'statusLine'`,
so Cursor has no tracked in-repo integration equivalent to `.claude/settings.json`.
Activation is therefore an explicit opt-in through [`bin/fm-cursor-statusline.sh`](../bin/fm-cursor-statusline.sh),
which writes only that one key into the configuration the captain already uses, after taking a timestamped
backup, and whose `uninstall` restores the previous state.
It preserves every other setting, refuses a foreign status line in both directions, refuses an unparseable
config rather than rewriting it, and never reads, copies, or links credentials.
A `statusLine` that is a non-object, or an object with no `command`, counts as foreign on presence alone.
Its own key is recognised by the renderer invocation the command ends with rather than by the absolute path
of the checkout that wrote it, so `uninstall` still works when it is run from a worktree instead of the
checkout that installed the key.
Cursor stores authentication outside the config directory, so the existing login is unaffected either way.
The installed command is inert unless `bin/fm-primary.sh` supplied `FM_PRIMARY_HARNESS=cursor`, so an
unguarded manual `cursor-agent` run renders nothing.

Cursor remains worker-first in dispatch; this section governs display only, and installing the row neither
creates a Cursor primary profile nor changes worker routing.

### Codex and Astra

Codex 0.153.4 has a native status line, but it is a fixed-item selector configured by `/statusline` and
persisted as exactly two keys, `status_line` and `status_line_use_colors`.
There is no command, script, or plugin variant, and its items cannot express Firstmate's fleet counts,
supervision freshness, or away state.
The two surfaces are therefore complementary rather than alternatives.

Codex's own items do expose model, effort, context, and both usage windows, so the recommended native
selection - set through `/statusline`, or in `$CODEX_HOME/config.toml` - is:

```toml
[tui]
status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit"]
status_line_use_colors = true
```

`model-with-reasoning` renders model and reasoning effort together; `context-used`, `five-hour-limit`, and
`weekly-limit` are Codex's own context and usage-window items.
Codex silently ignores an unrecognized item id, so a mistyped entry disappears rather than erroring.

Alongside that, `bin/fm-primary.sh` attaches the shared Firstmate companion row for the `codex` and `astra`
profiles, carrying the fields Codex cannot show.
The companion reports the model from the guarded profile - `gpt-6-astra` for `astra`, with the effort
`config/astra-effort` resolved - while context, quota, and cost stay `--` because Codex exposes none of them
to a companion process.
Codex reports a single `all_models` availability scope, so Astra draws on the ordinary Codex windows: there is
no separate Astra allowance, and none is displayed.

### opencode and grok - unverified

`bin/fm-primary.sh` lists `opencode` and `grok` as verified primary profiles, so they are carried here
rather than left out, but neither binary is installed on this machine and neither was probed.
No native status-line, footer, or plugin surface has been examined for either one, and no integration for
either has been exercised, so nothing is claimed about what they do or do not expose.
Their prospective surface is the shared companion below, which is provider-driven rather than
harness-driven and would therefore attach the same way it does for Kimi, Codex, and Astra - but that has
not been demonstrated for either profile, and `companion_status_profile` deliberately does not yet list
them, so today a guarded `opencode` or `grok` primary leaves its native TUI untouched.
These two rows stay unverified until the binaries are present and probed; they are not waived.

### Shared companion surface

Kimi, Codex, and Astra share one companion implementation rather than three.
`bin/fm-status-bar.sh --follow-pane <pane> --follow-backend <tmux|herdr>` runs a one-row loop that disables
autowrap, clips the canonical line instead of wrapping it, and exits as soon as its exact primary pane is gone.
It clears the whole pane once at startup, because `herdr pane run` echoes the launch command into the pane's
shell before `exec` replaces it and that line would otherwise stay visible below the status row.
Each refresh collects the whole row before any of it reaches the pane, then writes the single-row erase and
the finished row together, so the row is never left blank while the next one is being collected.
Every refresh publishes its row, so a resized or repainted companion recovers on the next tick.
Only `tmux` and `herdr` are accepted; any other value renders nothing rather than guessing.

`bin/fm-primary.sh` picks the provider that actually owns the terminal: `TMUX_PANE` selects tmux, and
`HERDR_PANE_ID` selects Herdr. Herdr calls are always `--session`-scoped so an unscoped call can never
resolve against another session's pane.

Two Herdr details are load-bearing and were measured rather than assumed.
`herdr pane split --ratio` is the share the ORIGINAL pane keeps, so the companion is created with a HIGH
ratio and takes the remainder.
Herdr clamps that share to 0.9, so the companion can never be smaller than a tenth of the tab.
That floor is proportional rather than a fixed row count: it is two rows on a 23-row terminal and six rows on
a 63-row one, where tmux pins its companion to exactly one row.
Measured on herdr 0.7.4 (2026-09-10) in a disposable 64-row session: `pane split --ratio` at 0.9, 0.93, 0.95,
0.98, 0.99 and 1.0 all recorded a 0.9 split and a 6-row companion, `pane resize --direction down` never went
below that floor while `--direction up` grew the companion freely, and the internal `layout.set_split_ratio`
RPC clamped to 0.9 as well.
Herdr 0.7.4 therefore has no supported route to a one-row companion.

If the session provider refuses the split, the guarded launch continues with the native TUI untouched rather
than failing the primary.
A split that SUCCEEDS but does not name its new pane is a different outcome and is reported as one: the
primary has already been shrunk by then, so the launcher says the tab is now sharing an empty pane instead
of claiming the TUI is untouched.
The split response is the only authority for which pane that call created, and it governs both where the
renderer runs and which pane may be closed.
A pane is never identified positionally from the tab's layout, nor by diffing the tab before and after the
split: either can resolve to a co-tenant created by something else - an AFK split, the Action Deck - and
closing one of those would destroy live work.
So when the response names no pane, nothing is closed at all; an unused pane is strictly better than a
destroyed one.

## Local activation after merge

Claude's earlier prototype is local to the primary home's `.claude/settings.local.json`.
After this change lands, remove only that local `statusLine` entry so it no longer overrides tracked `.claude/settings.json`.
Do not copy a renderer into `state/` and do not edit `~/.claude`, `~/.kimi-code`, or `~/.pi`.
The next guarded Claude, Pi, or Kimi primary launch loads the tracked integration automatically.

`~/.cursor` is the one carve-out, and only through `bin/fm-cursor-statusline.sh`.
Cursor validates `statusLine` only in the user config, so there is no tracked in-repo integration to load;
the installer is the activation route, it is opt-in, it writes exactly the one `statusLine` key after a
timestamped backup, and `uninstall` restores the prior state.
Editing `~/.cursor` by hand is still out of scope, and no other file under it is ever touched.

## Verification record

The adapter contract was checked on 2026-07-21 with Claude Code's project status-line payload shape, Kimi Code 0.27.0, Pi 0.80.10, Cursor CLI 2026.07.17-3e2a980, and tmux 3.6a.
The installed Pi documentation and example at `examples/extensions/custom-footer.ts` show `ctx.ui.setFooter()`, `render(width)`, and `truncateToWidth()`.
The installed Kimi help and public 0.27.0 plugin documentation expose lifecycle hooks but no footer renderer.
On that date the installed Cursor CLI 2026.07.17-3e2a980 exposed plugin directories but no status-line
configuration or footer renderer, which is why the contract originally excluded Cursor from display.

That Cursor record is superseded, not deleted.
Re-probed on 2026-09-08 against the installed Cursor CLI 2026.09.08-6caf4ff, which does expose a native
custom status line: a `statusLine` command object accepted in the user-level `cli-config.json` and rejected
in a per-project `.cursor/cli.json`.
The row was verified live - the renderer's output appeared in a real Cursor TUI - by an offline probe that
sent no model request and incurred no spend.
Codex 0.153.4 was probed the same way: its `status_line` selector and the exact `model-with-reasoning` item
id were read from the shipped binary's schema enum, again with no model request.
`opencode` and `grok` were not probed at all; neither binary is installed here, so both stay unverified.
Nothing was run on the project's Linux workstation, so no Linux behavior is claimed anywhere in this file.

```sh
pi --version
kimi --version
agent --version
bash tests/fm-status-bar.test.sh
bash tests/fm-primary.test.sh
bash tests/fm-pi-primary-types.test.sh
bin/fm-lint.sh
```

Observed version output on 2026-07-21:

```text
0.80.10
0.27.0
2026.07.17-3e2a980
```

Observed on the 2026-09-08 re-probe, on a machine where `pi`, `kimi`, `opencode`, and `grok` are not
installed:

```text
agent --version   -> 2026.09.08-6caf4ff
codex --version   -> codex-cli 0.153.4
```

Claude's adapter was exercised directly with the same JSON shape supplied to the native status-line command:

```sh
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-claude-live.XXXXXX")
mkdir -p "$tmp_root/state"
: > "$tmp_root/state/.last-watcher-beat"
printf '%s' '{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":35.2,"remaining_percentage":64.8},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":2.345}}' |
  env FM_PRIMARY_HARNESS=claude FM_HOME="$tmp_root" bin/fm-status-bar.sh --adapter claude |
  perl -pe 's/\e\[[0-9;]*m//g'
rm -rf "$tmp_root"
```

Observed output:

```text
⚓ Claude Fable·high │ 🧠35% ⚡12% │ 🚢0 ⏸0 ⚠0 │ 👁 0s │ $2.35 │ 💤--
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
⚓ unknown·off │ 🧠-- ⚡-- │ 🚢0 ⏸0 ⚠0 │ 👁 4s │ $0.00 │ 💤--
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

`tests/fm-status-bar.test.sh` passed canonical order, threshold, placeholder, supervision-alert, Claude-payload, Cursor-payload, account-role, control-byte sanitization, exact-pane cleanup on both companion providers, unverified-provider refusal, one-time pane clear, blank-free refresh, per-refresh row publication, and guarded-installation cases.
`tests/fm-primary.test.sh` passed the guarded tmux and herdr companion cases - including the separated refused-split and split-named-no-pane outcomes, and cleanup of only the exact pane the split returned - alongside all existing launcher cases.
`tests/fm-cursor-statusline.test.sh` passed the installer's single-key install, exact uninstall restore, foreign-status-line refusal in both directions, cross-checkout removal, invalid-config refusal, and credentials-untouched cases.
`tests/fm-pi-primary-types.test.sh` reported an honest skip because the host TypeScript 4.9.5 cannot parse Pi 0.80.10's declarations, while the real Pi TUI loaded and ran the TypeScript extension.
`bin/fm-lint.sh` passed with the repository-pinned ShellCheck 0.11.0.

# Firstmate status bar

This file is the single owner of the Firstmate primary status-bar contract.
`bin/fm-status-bar.sh` owns rendering mechanics, and each primary adapter supplies only the metrics its tool exposes.

## Canonical line

After ANSI styling is removed, every renderer uses this field order:

```text
⚓ <model>·<effort> [<account-role>] │ 🧠<context-used> ⚡<provider-quota-used> │ 🚢<working> 🧪<validating> ⏸<paused> ⚠<attention> 📋<records> │ 👁 <supervision> │ $<session-cost> │ 💤<afk>
```

The separator is one space, a dim `│`, and one space.
Renderers keep the order and meanings fixed instead of substituting tool-specific footer fields.
Width-constrained surfaces clip or truncate the canonical line without wrapping or changing native interaction controls.

| Field | Meaning | Placeholder |
| --- | --- | --- |
| `⚓ model·effort` | The active model and reasoning or thinking effort reported by the orchestrator. | `--` for either unavailable value. |
| `[account-role]` | A compact role word for the vendor account this primary is running on, attached to the model identity rather than forming its own group. | Omitted entirely when the account is unknown. |
| `🧠 context` | The integer percentage of the model context window already used. | `--` when the orchestrator does not expose current context use. |
| `⚡ quota` | The integer percentage of the provider's binding quota window already used, immediately followed by a dim token naming the window or windows that bind it when the adapter knows them. | `--` when the provider or orchestrator does not expose quota, or exposes a figure whose windows cannot all be named. |
| `🚢 working` | Tasks a live worker is busy on right now. | `--` while the fleet reading is unknown. |
| `🧪 validating` | Tasks the validation pipeline is carrying. They are progressing, but no worker is typing at them. | `--` while the fleet reading is unknown. |
| `⏸ paused` | Tasks in a declared bounded external wait. | `--` while the fleet reading is unknown. |
| `⚠ attention` | Tasks that need Firstmate to act: a decision, a blocker, or a failure. | `--` while the fleet reading is unknown. |
| `📋 records` | Ordinary task records in this home, excluding persistent second mates. Always exact, and deliberately not a claim about running workers. | `0` when no ordinary tasks exist. |
| `👁 supervision` | Age in seconds of `state/.last-watcher-beat`. | Bright-red `NO-WATCH --` when the beacon is missing or unreadable. |
| `$ cost` | Cumulative cost in US dollars for the current orchestrator session, rounded to two decimals. | `$--` when the orchestrator does not expose cost. |
| `💤 AFK` | Whether the Firstmate home is in away mode. | Dim `💤--` when away mode is off. |

## Fleet fields

A task record outlives its worker, and `AGENTS.md` section 8 defines a status line as a wake EVENT rather than current state.
Counting `state/*.meta` files as running workers, and folding each status log's last line into paused and attention, therefore reported records as live work in both directions at once: it overstated how much was running and understated how much needed attention.

The four live fields come from `bin/fm-crew-state.sh`, the canonical current-state reader, folded by `bin/fm-fleet-status-lib.sh`.
That library selects no run and re-implements no attribution; run selection stays with the canonical reader.
The distinction between `🚢` and `🧪` is the reader's SOURCE, not its state word: `working · run-step` is the pipeline carrying a task, and `working · pane` is a worker busy on one.
`⚠` covers `parked`, `blocked`, and `failed`, which are the states that need Firstmate rather than time.

The four live fields are a single reading and share a single fate.
A reading that is missing, incomplete, past its maximum age, malformed, or taken for a different set of tasks renders `--` in all four rather than a number in any.
They are never reported as zero to stand in for "not read yet", because an idle fleet is a real state the captain has to be able to act on.
`📋` is independent of all that: it counts records directly, so it stays exact even while the live fields are unknown.

A canonical read consults the validation pipeline and costs about a second per task, which is three orders of magnitude more than the renderer's one-second frame.
So the fold runs out of band: a frame reads the cache and starts at most one detached refresh, under a claim that a second frame cannot take and that a refresher which died without writing releases on its own.
A frame never calls the canonical reader itself.
`bin/fm-fleet-status-lib.sh`'s header owns the exact cache lifetimes and their environment seams, and `bin/fm-status-cache-lib.sh` owns the cache and freshness mechanics it shares with the Codex metrics supply.

### The context sample and the handoff axis are separate decisions

`state/.primary-context` is the primary-handoff supervisor's CONTEXT axis: a home with that axis enabled rotates its live primary once the sample crosses its threshold.
The native Claude adapter has always fed it.
The Codex companion deliberately does NOT, even though it now reads real context.
Displaying a figure and using it to rotate a live primary are separate decisions, and only the first one is in this renderer's scope; a home that wants Codex-driven rotation needs a task that owns the handoff reader and its freshness semantics.

The window token is dim and is a short length word such as `5h`, `wk`, or `24h`.
It is part of the metric rather than decoration: the same percentage means something different
against a five-hour allowance than against a weekly one, so an adapter that knows its window always
names it, and a figure whose window cannot be named is withheld rather than shown bare.
A provider can report more than one window binding at the same percentage, and then the token names
them shortest-first, joined by `/` - `5h/wk`.
A tie too wide for the token's eight-character bound collapses to its shortest binding window; the
percentage stays the tied one, and the windows the token no longer spells out remain just as binding,
so the shortest window's reset does not restore the whole allowance.
Adapters whose payload carries no window - Claude, Pi, and Cursor - render the bare percentage their
own contracts already specify, unchanged.

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
Each of Codex's own limit items is REMAINING-oriented and omits itself when the provider has not supplied
that window, which is the opposite orientation from this row's USED percentages.

Alongside that, `bin/fm-primary.sh` attaches the shared Firstmate companion row for the `codex` and `astra`
profiles, carrying the fields Codex cannot show.
The companion reports the model from the guarded profile - `gpt-6-astra` for `astra`, with the effort
`config/astra-effort` resolved - and supplies real context and quota figures of its own through
[`bin/fm-codex-session-metrics-lib.sh`](../bin/fm-codex-session-metrics-lib.sh), which owns the mechanics.
Session cost stays `--`: Codex's `estimated-thread-cost` item is Enterprise-workspace only and is not
exposed to a companion process.

Three different quantities are involved here, and the integration's correctness rests on not confusing
them.

**Context is per-session, so it is read from that exact session.** The followed pane resolves to its
foreground Codex process, that process is asked which rollout file it currently holds OPEN, and only that
file is read. Codex holds exactly one rollout open per thread, so the open descriptor is the process's own
statement of which thread it is running. Nothing picks the newest file in the sessions tree, so a sibling
Codex session - another primary, a worker, the desktop app - owns a different descriptor and can never be
borrowed. No Codex process behind the pane, no rollout, or more than one rollout is a refusal.
The figure is the last turn's prompt size against the context window that session itself reported, which
are the same two numbers Codex's own `context-used` item is built from. The window is read from the session
rather than from a model catalog, so no capacity is ever assumed. Compaction needs no special handling: a
compacted thread's next event reports the smaller post-compaction prompt.

**Provider quota is per-account, so it comes from the account owner.** `quota-axi` already resolves
provider and account identity, and it is read strictly read-only with `--no-credential-refresh`, which
keeps the read from delegating an expired session's renewal to the vendor CLI and surfacing a login prompt
behind a status bar. The row consumes that owner's `all_models` effective availability and the window it
reports as binding, converting its REMAINING percentage into this row's USED one. `quota-axi` names every
window tied at the minimum remaining, so a tie is an ordinary state - an untouched account ties at 100%
remaining, an exhausted one at 0% - and the tied figure is reported with every tied window named. All the
tied window ids are retained in the reading and its cache even when the row's token has to be compact.
Codex reports a single account-wide availability scope, so an Astra primary draws on the ordinary Codex
windows rather than an allowance of its own, and none is displayed as though it had one.

**The rollout's own `rate_limits` block is a third thing, and it is the trap this integration exists to
avoid.** It is stamped with a limit identity - `limit_id` and `limit_name` - which is frequently not the
running model's. A live `gpt-6-astra` primary was measured reporting `limit_id=codex_bengalfox`
(GPT-5.3-Codex-Spark) at 0% used while the account's actual binding weekly window sat at 54% used.
Reporting that 0% would tell the captain there is full headroom when there is not. The block is therefore
not a quota source here at all, under any name. Filtering it by identity was tried and does not work: the
block never states which account or which model allowance it describes, so nothing in it can establish the
scope the row would be claiming, and a name-shaped rule mismatches exactly where it matters - the plain
`codex` profile's own model string is a substring of `codex_bengalfox`, so it matches that very block.
Quota comes from the account owner or it is unavailable. The rollout supplies context, and nothing else.

Freshness and cost are bounded on every path. The session read is a local file read cached for 15 seconds,
and it reads a bounded tail of the rollout that escalates from 256 KB while nothing is found and stops at
32 MB or the file's own size, because a live rollout reaches hundreds of megabytes and the newest
token-count event can sit far behind the end of it. A reading that cannot be refreshed inside that bound
keeps its last known value for up to 15 minutes and then goes back to `--`, because a live session's
occupancy does not become unknown the moment its newest event scrolls past the window - and never becomes
zero. Candidate lines are selected on `payload.type` exactly, so conversation content that merely mentions
the event name cannot stand in for a reading.

The provider read is a subprocess, so a refresh never waits on it. On a cache miss the refresh starts one
detached read, renders the `--` placeholder for that frame, and a later frame picks the answer up once it
lands; its own 120-second cache and a 30-second in-flight lock bound how often that happens. A one-second
companion refresh therefore performs no blocking subprocess work on any tick, and no credential is read, no
credential refresh is delegated, and no token value is ever printed. Only metric metadata is parsed - token
totals and the context window - and never conversation content.

Every reading must be positively known or it is unavailable. A missing, malformed, expired, stale, or
unattributable figure renders as the dim `--` placeholder and is never converted to `0`, because a
confident zero on either metric is exactly the reading that would mislead. A genuine zero still renders as
`0%`.

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

### Herdr chrome mode: reclaiming the companion's empty rows

On a large tab the Herdr companion's proportional floor leaves the one-row status strip sitting in a
six-row pane: a border, the status row, three empty rows, and a border.
Chrome mode reclaims those rows without giving up any canonical field.

The canonical row is published to the PRIMARY pane's own border title, where it costs no rows at all,
and the companion pane is then hidden by zooming the primary.

The shape is defined by measurement, not inference. Every fact below was captured on herdr 0.7.4
through [`bin/fm-herdr-lab.sh`](../bin/fm-herdr-lab.sh) in a disposable `fm-lab-*` session, and
[`tests/fm-status-chrome-herdr-lab-e2e.test.sh`](../tests/fm-status-chrome-herdr-lab-e2e.test.sh)
re-runs the zoom, layout, and readback ones against the real binary:

- **A pane with no split has no border whatsoever.** Neither `pane report-metadata --title` nor
  `pane rename` renders anything on an unsplit pane. So the companion pane must keep EXISTING for a
  border to exist; the reclaim is hiding it, never closing it. An earlier record that the companion
  could be closed outright was measured with the split still present and is superseded here.
- **With the split present, the primary's top border renders the row in full**, every canonical field
  included, and it keeps refreshing while the primary is unfocused.
- **Zooming the primary hides the companion and keeps that border title.** The primary occupies every
  row through its own bottom border, the companion's box stops being rendered entirely, and the status
  row still reads from the top border. This is the reclaim.
- **Herdr truncates the border title itself, visibly**, appending its own ellipsis - verified at both
  60 and 40 columns. Width is therefore Herdr's concern and this renderer does not second-guess it.
- **`pane get` reads the published row back exactly.** `.result.pane.title` returns the string that
  was published, and the last source to publish is the one it resolves. That readback is what makes
  the capability gate below evidence rather than a guess.
- **`pane layout` reports the pane count and the zoom flag independently.** A zoomed two-pane tab
  still reports two panes with `zoomed: true`: zoom hides the companion without removing it, which is
  exactly why the border survives.
- **Herdr releases the zoom itself when a third pane appears.** Splitting a co-tenant into a zoomed
  tab returns three panes and `zoomed: false` with no request from us, and `pane zoom --off` on an
  already-unzoomed tab is accepted as a no-op (`reason: "already_unzoomed"`). So the renderer's
  release is a cheap confirmation, not the thing keeping a co-tenant visible.

The row is prefixed with a compact visible role marker, `FM` for an ordinary primary and `LAB` for a
lab primary, so the guarded primary identity is not displaced by the status fields.
The marker leads the row, which is also the one position a clip can never reach.

Two guarantees are load-bearing:

- **The border title is published under its own source**, `firstmate-primary-status-v1`, never the
  launcher's `firstmate-primary-visible-v1`. Herdr REPLACES a source's entire metadata record on every
  `report-metadata` call, so publishing under the launcher's source would wipe the primary's own
  display-agent and supervision state labels on the first refresh. A separate source contributes only
  this title and leaves the launcher's record resolving untouched.
- **Herdr stores a border title clipped to 80 codepoints, silently.** The renderer therefore drops
  whole fields from the right until the row fits and appends a visible marker, so the rightmost fields
  can never disappear without a sign. Fields are dropped on the separator rather than by offset,
  because the row is full of multibyte glyphs and an offset slice could split one; the last-resort
  trim removes whole codepoints for the same reason.
  That measurement does not depend on the ambient locale. `${#var}` counts codepoints under a UTF-8
  `LC_CTYPE` and BYTES under `C`/`POSIX`, and neither the herdr server nor the shell it spawns the
  companion in is guaranteed to carry a UTF-8 locale - the canonical row is 72 codepoints but 105
  bytes, so a byte count would throw away three fields from a row that fits. The renderer forces `C`
  for the measurement and counts codepoints directly, as every UTF-8 byte that is not a continuation
  byte, which is the same answer on every host.

The row is published with a `--ttl-ms` of two and a half refresh intervals, so a renderer that dies
lets the border row expire instead of freezing a stale fleet count on the captain's screen.

### The capability gate is positive evidence

Nothing is hidden on the strength of a protocol number. The presentation protocol floor is only a
cheap PRE-FILTER: protocol 16 attests the managed presentation surfaces the adapter uses, and none of
the three chrome mode actually depends on - `report-metadata --ttl-ms`, `pane get`'s resolved title,
and `pane layout` - and the same number also matches older herdr builds.

So after the split exists, and before anything is hidden, `bin/fm-primary.sh` proves the surfaces
against the real pane: it publishes the role marker to the border under chrome mode's own source with
a short expiry, reads it back with `pane get` and requires an exact match, and requires `pane layout`
to answer with a parseable pane count. Only when all three succeed does it pass `--chrome-pane` to the
companion and consider hiding it. Any failure - a client that answers the pre-filter but does not
store the row, or one whose layout cannot be read - leaves the companion visible with its in-pane row
as the only surface, which is exactly the behavior that shipped before chrome mode. The probe row
carries a short `--ttl-ms`, so a probe that no renderer ever follows expires instead of sitting on the
border.

This check is local to the launcher's Herdr arm on purpose. It is not a backend capability layer and
not a general probe framework; it is the one thing that must be true before the captain's only
pre-existing status surface is hidden.

### The zoom is owned, and releasing it is one-way

Zoom is applied exactly once, by `bin/fm-primary.sh`, and only when the tab holds nothing but the
primary and the companion just created.
When it applies that zoom it says so, by passing `--chrome-zoomed` to the companion, and that signal
is the ONLY thing that arms the renderer's release watch. The launcher still passes `--chrome-pane` on
a crowded tab - the border row is worth having either way - so without the signal the renderer would
otherwise be releasing a zoom that belongs to someone else. If `pane run` then fails, the launcher
releases its own zoom before closing the pane it was taken for.
The renderer never re-applies the zoom: it only RELEASES, on a slow cadence, if a third pane later
appears in that tab, and it stops checking once released.
That keeps two properties at the same time - a co-tenant pane's live work is never hidden, and a
captain who deliberately unzooms is not fought once a second.

The fallback chain has no gap.
The companion keeps drawing its own in-pane row exactly as before, so an unzoomed primary, a Herdr
below the verified presentation protocol, a client that fails the capability probe, a refused zoom,
and a failing metadata call all degrade to the surface that shipped before chrome mode - the only
consequence is that the empty rows are not reclaimed.
Chrome mode is also off entirely for tmux, and refuses a chrome pane that is the companion itself.

## Local activation after merge

Claude's earlier prototype is local to the primary home's `.claude/settings.local.json`.
After this change lands, remove only that local `statusLine` entry so it no longer overrides tracked `.claude/settings.json`.
Do not copy a renderer into `state/` and do not edit `~/.claude`, `~/.kimi-code`, or `~/.pi`.
The next guarded Claude, Pi, or Kimi primary launch loads the tracked integration automatically.

Codex's native half needs no repeat edit once the `[tui]` block above is in `$CODEX_HOME/config.toml`,
but a session must have LOADED it: `/statusline` inside a running TUI applies the selection to that
session, while a session started before the block was written may not be showing it.
Whether Codex reloads that file without a restart has not been established here, so neither behavior
should be assumed; `/statusline` is the route that applies it either way, and it needs no relaunch.
The companion's own fields need no activation at all - they follow the guarded launch.

`~/.cursor` is the one carve-out, and only through `bin/fm-cursor-statusline.sh`.
Cursor validates `statusLine` only in the user config, so there is no tracked in-repo integration to load;
the installer is the activation route, it is opt-in, it writes exactly the one `statusLine` key after a
timestamped backup, and `uninstall` restores the prior state.
Editing `~/.cursor` by hand is still out of scope, and no other file under it is ever touched.

## Verification record

Rows captured before 2026-09-12 show the fleet group as `🚢<active> ⏸<paused> ⚠<attention>`.
That was the field shape on the day each of those runs was observed; the current shape is the one in the canonical line above, and those older captures are kept as the evidence they were rather than rewritten.

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

The Codex metric supply was added on 2026-09-10 against codex-cli 0.153.4, quota-axi 0.1.41, and herdr's
`pane process-info`.
The full `[tui].status_line` item enum was read from the shipped `codex-darwin-arm64` binary's string
table, with no model request and no network call, confirming `model-with-reasoning`, `context-used`,
`five-hour-limit`, and `weekly-limit` as real ids alongside `context-remaining`, `used-tokens`,
`total-input-tokens`, `total-output-tokens`, `thread-credits`, `estimated-thread-cost`,
`context-window-size`, `usage-limit`, `secondary-usage-limit`, `daily-limit`, `monthly-limit`, and
`annual-limit`.

The session binding and the misattribution were both measured on the live `gpt-6-astra` primary by
read-only inspection: `herdr pane process-info` resolved the followed pane to the Codex process, `lsof`
showed that process holding exactly one rollout open, and that rollout's newest token-count event reported
`model_context_window=258400` with `rate_limits.limit_id=codex_bengalfox`
(`limit_name=GPT-5.3-Codex-Spark`) at `primary.used_percent=0`.
The independently read account state at the same time was 46% remaining on the binding weekly window, so
the rollout's 0% was another model's allowance and not this primary's.
The corrected reading for that primary was context 58% used and quota 55% used on the `wk` window, which
agrees with the account owner rather than with the mismatched block.
The reported context window also agrees with the cached `gpt-6-astra` catalog entry - `context_window`
272000 at `effective_context_window_percent` 95 - so the figure rests on the session's own report and no
larger capacity is claimed anywhere.

`tests/fm-status-bar.test.sh` covers this supply with fixture rollouts and fixture provider reports only.
It spawns no renderer against a live pane and signals no process, because the suite's isolation rule is
that teardown matches exact child pids and never command-name patterns: a name pattern matching
`fm-status-bar.sh` would also match a live captain's companion, whose command line is byte-identical to a
fixture's.
The registered cases are the measured misattribution and every other shape of rollout rate-limit block
being refused as a quota source, current-session context across compaction, a token event buried beyond the
first tail step still being found while a line that merely mentions the event name is not, an unrefreshable
reading being kept only while it is young enough and then going back to unavailable rather than zero,
malformed and absent and stale readings staying unavailable rather than zero, a genuine zero surviving
those guards, a weekly-only provider limit, tied windows reported with every tied window named including a
genuine tied 0% and a tied exhausted account, a wide tie collapsing to its shortest binding window, an
unnameable window withheld on its own and inside a tie, single-versus-multiple open rollout resolution, a
process-info answer about another pane resolving to nothing, a tmux pane resolving its Codex primary
through a launcher shim and nothing else, a provider cache miss rendering a complete row instead of
waiting on the read, and the window token reaching the Codex row without leaking into the Claude, Pi, or
Cursor contracts.

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

### Truthful fleet fields, 2026-09-12

Measured against the captain's own fleet on herdr 0.7.4, reading copies of `state/*.meta` and `state/*.status` so the live home was never written to.
Thirteen ordinary task records; `bin/fm-crew-state.sh` read individually for each one.

The old rule and the new one, folded over the identical data:

```text
old:  🚢13 ⏸3 ⚠0
new:  🚢2 🧪1 ⏸2 ⚠5 📋13
```

Two workers were genuinely busy, one task was in the pipeline, two were in a declared wait, four runs had failed and one was parked at a review gate awaiting a decision.
The old rule was wrong in both directions at once: it reported thirteen running workers where there were two, and reported that nothing needed attention while five tasks did.

The complete row, rendered by `bin/fm-status-bar.sh` from that live data with the Codex supply bound to the captain's actual primary pane:

```text
⚓ gpt-6-astra·high │ 🧠82% ⚡9%wk │ 🚢2 🧪1 ⏸2 ⚠5 📋13 │ 👁 NO-WATCH 355s │ $-- │ 💤--
```

The `NO-WATCH` reading is an artifact of the copied beacon file, which does not advance; the live beacon was current throughout.

Pointed at the companion pane instead of the primary, the Codex supply returned `--` for context rather than a number from another session, which is the no-borrowed-sibling rule doing its job on live data.

`bin/fm-status-bar.sh` traps `TERM` with a handler that restores the terminal and does not exit, so its refresh loop survives a `timeout(1)` bound and every scoped signal short of `KILL`.
Cleaning up a probe renderer therefore means enumerating the probe's own process tree by pid and asserting the live companion's pid is not in it.
It must never mean matching on the command line: the captain's live companion runs a byte-identical one, which is how an earlier probe killed the captain's own status row.

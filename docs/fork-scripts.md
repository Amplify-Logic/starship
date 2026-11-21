# Fork scripts

These are the `bin/` scripts this fork, Starship, carries beyond upstream Firstmate.
[scripts.md](scripts.md) lists every other script and stays as upstream wrote it, so a catch-up from upstream does not conflict over this fork's rows.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-linux-setup.sh`      | Take a fresh Ubuntu 24.04, inside WSL 2 or on a server, to the point where a first mate can start |
| `fm-herdr-setup.sh`      | Make a fresh home start in Herdr: install Herdr and its Claude Code integration, select it as the runtime, and add the `starship` and `onboard-starship` commands |
| `fm-release.sh`          | Maintainer-only cut of the next named Starship release from a green default branch, with its CHANGELOG.md section as notes |
| `fm-claude-reply-speak.sh` | Claude Stop `async` hook speaking the primary's final reply through desk voice-out when the turn spoke nothing (docs/fork-configuration.md "Desk voice-out"), and warning the first mate at its next turn, without blocking, when that reply used internal terms `AGENTS.md` section 9 says to translate |
| `fm-captain-ledger.sh` | Claude UserPromptSubmit hook recording each captain prompt to the captain ledger in a home opted in through config/captain-ledger, plus the `pending` listing the session-start digest prints until `mark` records them reconciled |
| `fm-opt-in-skills.sh` | Link into `.agents/skills/` only the opt-in skills from `.agents/opt-in-skills/` that this home switched on with `config/` presence flags, so no other home lists them, plus every skill of this home's private add-on (docs/fork-configuration.md "Opt-in skills") |
| `fm-addon.sh` | This home's private add-on named by `config/addon`: resolve its checkout, list and run the `bootstrap`, `session-start`, `sentinel`, `watcher`, `deck-staging`, `todo-admit`, `todo-verbs` and `todo-page` hooks of this repository's `hooks/` and the add-on's, clone a missing checkout, create a new owner's private add-on, confirm the publishing guards, and hold back a home's first project until it has an add-on (docs/fork-configuration.md "Private add-on") |
| `fm-morning-intake.sh` | Opt-in once-a-day morning intake gate: arms, retries and closes the day's morning read and its to-do page, so a missed morning shows instead of being skipped (docs/fork-configuration.md "Daily intake and to-do page") |
| `fm-morning-intake-schedule.sh` | Install, render, report or remove the morning intake's macOS launchd schedule |
| `fm-channel-intake.sh` | Opt-in continuous channel intake: per-source poll gate, obligation ledger, grouped private alert, brief and to-do list, and the re-check of open items on every pass (docs/channel-intake.md) |
| `fm-channel-intake-schedule.sh` | Install, render, report or remove the channel intake's macOS launchd schedule |
| `fm-todo.sh` | The daily to-do page's durable item store: one record per ask, its verification, the captain's page commands, the rolling re-check, matching a new ask to the open line about the same thing, and the add-on `todo-verbs`, `hand-over` and `mark` extension point |
| `fm-todo-items.py` | The engine behind `fm-todo.sh` |
| `fm-todo-render.sh` | Rebuild the day's Lavish to-do page from the item store with no model call, including add-on `todo-page` sections |
| `fm-todo-compose.py` | The page composer behind `fm-todo-render.sh`, styled by `bin/templates/today-page.*.html` |
| `fm-procevent-mothership.sh` | Opt-in, per room: wake Firstmate when something new for this Starship arrives in a Mothership room, relay it to the owner, hold each request to the ship as an owner call whose answer it carries out in the room, tell the card of work taken on when it starts, has a PR, is blocked or fails and lands or finishes with a report, and show other work of a project shared with a room on its Ships view (see [fork-configuration.md](fork-configuration.md#mothership-monitoring-configmothership-monitor)) |
| `fm-mothership-report-lib.sh` | The one call each lifecycle step makes to tell a Mothership room how a task goes, doing nothing in a home with no room link |
| `fm-release-lib.sh`      | Release names and order, and the home's `config/update-channel` parser, shared by the update and the release cut |
| `fm-routine-creator-watch.sh` | The creator-repo watch a scheduled Claude cloud routine runs: public git reads into one capped digest pushed to the dedicated reports repository, never to firstmate ([cloud-routines.md](cloud-routines.md)) |
| `fm-primary.sh`          | Launch a verified primary profile from the tracked root, owning profile aliases and bypass flags |
| `fm-primary-handoff.sh`  | Optional quota- and context-aware primary orchestrator handoff (docs/primary-handoff.md) |
| `fm-primary-handoff-lib.sh` | Shared handoff state-machine and never-two-holders helpers, also executed by `fm-lock.sh release-stale` for the stale-lock release decision |
| `fm-account.sh`          | List and create the isolated vendor account homes named by `config/accounts.json`, printing the login command it never runs |
| `fm-account-lib.sh`      | Shared named-account resolution, derived `data/accounts/<vendor>/<name>` homes, and the missing/logged-out/wrong-seat launch gate |
| `fm-status-bar.sh`       | Render the canonical guarded primary status bar on native surfaces and on tmux or herdr companion panes (docs/status-bar.md) |
| `fm-cursor-statusline.sh` | Opt-in install, status, and exact-restore uninstall of Firstmate's status line in Cursor CLI's own user config (docs/status-bar.md) |
| `fm-fleet-status-lib.sh`  | Fold `fm-crew-state.sh` and the endpoint classifier into the status row's working/validating/paused/attention/ready/stopped counts, and on request the decisions inside ready, out of band and cached; `fm_owner_calls` is the one list of the owner's calls behind the status row, the bridge strip, the Factory pane, and the tap page (docs/status-bar.md) |
| `fm-owner-calls-signal-lib.sh` | The one cheap signal that the owner's calls may have changed, read once a second by the bridge strip and the Factory pane and moved by every command that changes a call (docs/bridge-strip.md) |
| `fm-bridge-strip.sh`     | Install, show, run, and remove the read-only Starship bridge strip across the top of a Herdr workspace: wordmark, crew lamps, the most urgent call, a red alert, the night shift, and battery, and print one reading of them for another screen (`fields`; docs/bridge-strip.md) |
| `fm_terminal_theme.py`  | Shared terminal background detection and light/dark palettes for the Factory pane and bridge strip with the remembered workspace theme (docs/fork-configuration.md) |
| `fm-theme.sh`            | Switch the whole workspace between cream light and dark in one go: Terminal, Herdr, the bridge strip and the Factory pane, remembered for new panes (docs/fork-configuration.md "Workspace theme") |
| `fm-factory-pane.sh`     | Install, show, run, and remove the Factory pane, every factory at a glance in a Herdr pane (docs/factory-pane.md) |
| `fm-desk.py`             | The `starship` desk command: open the owner's whole Herdr workspace and its Terminal or Ghostty views from `config/desk-layout`, read a running desk back as a layout, and, as `onboard-starship`, set a new desk up one step at a time (docs/desk.md) |
| `fm-factory.py`          | Build the factory record (`--data`, `--plain`), print the screen as data and take a writing key for another screen (`--screen`, `act`), draw the live Factory pane, open a factory's own tab with live copies of its workers (docs/factory-pane.md), and print the factory profile `fm-brief.sh` adds to a brief (`profile`; docs/fork-configuration.md) |
| `fm-codex-session-metrics-lib.sh` | Supply the Codex companion's real context and provider-quota figures from the exact followed session and the account owner (docs/status-bar.md) |
| `fm-status-cache-lib.sh` | Shared status-row cache freshness, staleness bounds, and single-refresh claim ownership |
| `fm-landed-lib.sh`       | Shared newest-first completion-recency ordering for every capped landed surface       |
| `fm-task-reap-lib.sh` | Stop the processes a task left running inside its own copies, including its finished validation copies, for cleanup and relaunch |
| `fm-startup-memory-budget.sh` | Validate and report the bounded startup-memory allowance and current usage |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-decision-surface.sh` | Render, poll, and route the private loopback Lavish surface over captain decisions   |
| `fm-tap-desk.sh`         | Export the owner's calls as phone tap cards, read each held decision's options and recommendation (`shapes`), route the taps through the captain-hold and PR-merge paths, and apply the seven-day easy-to-undo default |
| `fm-read.sh`             | Open a task's own page, or render Markdown reports as one private loopback Lavish reading page |
| `fm-chart-room.sh`       | Serve the private read-only chart room: fleet home, per-project goal maps, rendered fresh on every request (docs/chart-room.md) |
| `fm-bridge-view.sh`      | Serve the captain's phone-first fleet glance, the `/deck` Action Deck page, the `/machines` page, photo drop, and hold-to-speak on loopback behind Tailscale Serve (docs/bridge-view.md) |
| `fm-bridge-fields.sh`    | Add the bridge's title, repo, hold kind and hold reason to a finished bearings model, so the projection itself carries none of them |
| `fm-machines.py`         | Read-only JSON snapshot of the tailnet machines, this Mac's numbers and background services, configured machines over ssh, and configured HTTPS probes; feeds the bridge's Machines page (docs/bridge-view.md) |
| `fm-routing-snapshot.sh` | Read-only JSON snapshot of the dispatch roster, recent dispatch decisions, and each task record's kind and model, from local files only; feeds the bridge page's Routing section (docs/bridge-view.md) |
| `fm-overlay.sh`          | Open a Markdown view as an in-terminal Herdr overlay pane, degrading to a printed pointer to the same content; installs nothing and is called nowhere by default (docs/chart-room.md) |
| `fm-present.sh`          | Present a captain-action artifact once per unchanged milestone through its existing local owner |
| `fm-speak.sh` | Speak one captain-facing outcome line out of this machine's speaker, shaped by the spoken-register owner `config/speak` names with `shaper`; a named `voice` selects macOS say, otherwise Deepgram Aura leads when DEEPGRAM_API_KEY is set, each the other's fallback (the script header owns the mechanic); inert unless config/speak opts the home in, which `--enabled` reports; `--stop`, `--repeat`, `--history`/`--replay` and `--mute`/`--unmute` back the desk floater's voice controls (docs/fork-configuration.md "Desk voice-out", docs/desk-floater.md) |
| `fm-deepgram-tts.sh` | Synthesize one line with Deepgram Aura and play it (or --to a file); reads DEEPGRAM_API_KEY from env or gitignored .env; never logs the key; every request opts out of Deepgram's Model Improvement Program (`mip_opt_out=true`) |
| `fm-deepgram-stt.sh` | Transcribe one audio file with Deepgram for the desk floater push-to-talk path, or as timed segments (`--segments`) for the call recorder's Deepgram engine, or check that Deepgram accepts the key (`--check-key`); never logs the key; every request opts out of Deepgram's Model Improvement Program (`mip_opt_out=true`) |
| `fm-desk-voice.sh` | Desk-voice delivery: send types a captain-input transcript (or dictation, only when the primary chat is the text box in front) into the primary chat pane, falling back to the durable mailbox (deliver / pending / drain transcripts and screenshot paths under state/desk-voice/, with a wake and a retried doorbell ring), plus `ring` to type a doorbell line only into an empty primary composer, with no mailbox fallback, `shot` to capture a display (or store a PNG handed over on standard input) into state/desk-voice/shots/, and `keep` / `recordings` / `retry` to save, list and transcribe again a floater recording whose words did not arrive (docs/desk-floater.md) |
| `fm-desk-floater.sh` | Build and launch the Mac always-on-top push-to-talk, dictation and screenshot floater for this home (docs/desk-floater.md) |
| `fm-screen-steps.sh` | Open a page in Arc full size with an always-on-top card of the steps and values the captain fills in by hand, each value with a Copy button; Done and Stuck reply into the primary chat through `fm-desk-voice.sh send` (the script header owns the steps format) |
| `fm-call-companion.sh` | Start (only with `--everyone-agreed`), stop, archive, list and delete call recordings, show the live call desk, and say which transcription engine suits this Mac (`engine`) (docs/call-companion.md) |
| `fm-call-watch.sh` | Notice calls, remind to ask before recording, and stop a running recording once the call ends; installs its LaunchAgent (docs/call-companion.md) |
| `fm-call-mic.sh` | Record the microphone and call audio in overlapping chunks and transcribe them with whisper.cpp on this Mac or with Deepgram (`transcription_engine`) |
| `fm-call-captions.sh` | Append a Google Meet tab's visible captions to the call transcript |
| `fm-call-digest.sh` | Keep the live call desk: a cited digest of the last hour of transcript |
| `fm-call-final-notes.py` | Write paraphrased end-of-call notes that account for every item the live desk showed |
| `fm-call-speaker-split.py` | Label transcribed speech by the recorded track that carried it |
| `fm-call-lib.sh` | Shared call-recorder paths and `config/call-companion` settings |
| `fm-meetings.sh` | Opt-in meeting intake: arm its standing check, take finished meetings and calls in as a summary, follow-ups to start and items held for the captain, and recall what was agreed (docs/meetings.md) |
| `fm-meetings.py` | The meeting intake behind `fm-meetings.sh`: the poll, the model pass, the sorting rules and the records |
| `fm_meeting_sources.py` | The meeting sources the intake reads, Anarlog and the call recorder, and the seam a new source plugs into |
| `fm-desk-floater-windows.sh` | From inside WSL 2, build, install, update, start, stop and remove the Windows floater with Windows' own C# compiler, and serve its `bridge` calls through the shared desk-voice, speech-to-text and speak scripts (docs/desk-floater-windows.md) |
| `fm-desk-play-windows.sh` | afplay stand-in `fm-speak.sh` uses inside WSL 2 once the Windows floater is installed: plays one reply through the Windows speakers and stops on a stop (docs/desk-floater-windows.md) |
| `fm-web.sh` | Serve the localhost page that mirrors the terminal workspace in plain words: the first mate's conversation with a message box that sends through `fm-desk-voice.sh send`, the Starship band, and the projects with buttons and keys that send the Factory pane's own notes; `open` opens it as its own app window (docs/web.md) |
| `fm-direct-line.sh` | The captain's direct line to an opted-in second mate: enable and disable from the parent, list, send once per client id, delivery and talking reads, the mate's conversation, and the mate's own `waiting` and `answered`, all as versioned JSON (docs/direct-line.md) |
| `fm-direct-line-lib.sh` | A second mate's direct-line opt-in and its "talking with the captain" state (docs/direct-line.md) |
| `fm-pane-writer-lib.sh` | The per-home pane-writer lock every typist into a primary's pane holds across check, type and Enter (docs/direct-line.md) |
| `fm-secondmate-pin.sh` | Show, set or clear one second mate's `config/secondmate-harness` line as JSON, refusing an edit that would not resolve (docs/configuration.md) |
| `fm-voice-relay.sh`      | Durable freshness, evidence, and presentation ledger for the spoken desktop companion: topic revisions, the pre-action and pre-speech gates, and immutable receipts (docs/desktop-companion.md) |
| `fm-voice-relay-appserver.sh` | Dry-run-unless-`--live` app-server adapter for that relay: schema probe, steerable-status check, `turn/steer`, `turn/interrupt` (docs/desktop-companion.md) |
| `fm-adhd.sh`             | Bounded ADHD divergent-ideation wrapper; writes distilled CLI output and refuses when `adhd` is absent (docs/adhd.md) |
| `fm-second-opinion.sh`   | Bounded rival-model second-opinion wrapper; hostile review or `--ship-verdict` ship-or-fix read by Fable (default) or Grok via Cursor, neutral cwd, per-reviewer quota floor (docs/second-opinion.md) |
| `fm-browse-session.sh`   | Isolated per-task chrome-devtools-axi sessions with per-task profiles; never attaches to the captain's Chrome (docs/worker-browsing.md) |
| `fm-action-gateway.sh`   | Privilege-separated confirm-first action broker: digest-bound captain approval, locked state machine, hard spend/messaging ceilings, execution stubbed (docs/action-gateway.md) |
| `fm-order.sh`            | Standing Order list/show/run/log-fire/arm/disarm/graduate over `data/orders/<slug>.md`; arming requires `--by-captain` (docs/ops-command-center.md) |
| `fm-tray.sh`             | Read-only pending-action renderer over the action-gateway audit log; age is the headline; never approves (docs/ops-command-center.md) |
| `fm-deck.sh`             | Refreshing captain-private Action Deck pane: what is waiting on the captain above the fold, then what is moving; composes records this home already keeps and mutates none of them; `--json` emits the same model for the bridge's `/deck` page (docs/ops-command-center.md, docs/bridge-view.md) |
| `fm-action-gateway-v2.py` | Gateway v2 broker: strict parsing, immutable closed plans, SQLite-authoritative state, peer-authenticated channels, approval signatures verified against an enrolled signer, and lease-bounded execution settled from the executor's own store (docs/action-gateway-v2.md) |
| `fm-action-safe-sink-v2.py` | Gateway v2 deterministic safe sink: the only executor the broker claims for; one local append-only record per approved plan, exactly once, read back before it reports (docs/action-gateway-v2.md) |
| `fm-action-runner-v2.py` | Gateway v2 execution entry point: the execution socket's executor peer; claims one lease, verifies the bound executor's bytes before running it, and reports back with no approval authority and no say in the outcome (docs/action-gateway-v2.md) |
| `fm-action-artifact-import-v2.py` | Gateway v2 quarantine artifact importer: validates every archive member before writing any, imports whole or not at all; the `--artifact-adapter` for the boundary pack (docs/action-gateway-v2.md) |
| `fm-gateway-install-v2.sh` | Gateway v2 installation lifecycle: activation preview, honest install check, and inert install/uninstall artifacts; `apply` always refuses, and uninstall quarantines by moving rather than deleting (docs/action-gateway-v2.md) |
| `fm-worker-boundary-regression.sh` | Run the synthetic unprivileged adversarial isolation pack for ambient, restricted-account, and nested-container targets (docs/worker-boundary-regression.md) |
| `fm-harness-exam.sh`     | Re-verify one worker adapter's eight runtime properties against a real runtime in an isolated lab home and score them from outside the pane (docs/harness-exam.md) |
| `fm-fork-test-registry-lib.sh` | Parse `tests/fork-test-registry.conf` so fork-only test families and changed-path owners are declared there rather than in the runner, and overlay the fork's measured CI timing hints and lane packing from `tests/fork-test-timing.conf`; its header owns the row grammar and the missing-registry behavior |
| `fm-continuity-pretool-check.sh` | Narrow Claude recovery gate when in-flight work has a genuine supervision outage by the Claude model's verdict (docs/arm-pretool-check.md) |
| `fm-continuity-command-policy.mjs` | Semantic owner of Claude continuity-gate fleet-command classification (docs/arm-pretool-check.md) |
| `fm-dispatch-select.sh`  | Resolve a matched crew-dispatch rule to one concrete profile, owning `capability-recent` selection plus capability evidence surfacing and never ranking by quota |
| `fm-capability-lib.sh`   | Append-only capability outcome log (green means first-try validation pass), 7-day reader, ranking, and advisory scout-tax helpers |
| `fm-home-port.sh`        | Export, import, push, pull, or bootstrap captain-private portable home material (docs/porting.md) |
| `fm-home-manifest.sh`    | Print the environment-fidelity manifest of backend and tool versions that `fm-bootstrap.sh manifest` dispatches to (docs/porting.md) |
| `fm-project-display-name.sh` | Resolve a project slug to its human display name with explicit brand overrides and a synthesized fallback |
| `fm-supervision-sentinel.sh` | Home-scoped macOS launchd outage sentinel that alarms outside the harness process tree and never restarts supervision (docs/watcher-continuity.md) |
| `fm-dropped-threads.sh`  | Opt-in twice-daily dropped-threads digest from local records: one spoken sentence plus a short list, recorded for a later Starship Voice phone card and spoken at the desk (docs/fork-configuration.md "Dropped-threads digest") |
| `fm-dropped-threads-schedule.sh` | Render, install, inspect, and remove that digest's opt-in macOS launchd schedule (docs/fork-configuration.md "Dropped-threads digest") |
| `fm-weekly-changes.py`   | Opt-in weekly plain "what changed" page: each registered project's merged pull requests by their In short line, plus changelog highlights, as a local page (docs/fork-configuration.md "Weekly changes page") |
| `fm-weekly-changes-schedule.sh` | Render, install, inspect, and remove that page's opt-in macOS launchd schedule (docs/fork-configuration.md "Weekly changes page") |
| `fm-launchd-schedule-lib.sh` | Shared per-home LaunchAgent render, lint, load, and remove for this fork's scheduled owners |
| `fm-task-outcome.sh`     | Resolve a worker outcome from an explicit value, structured backlog title, or safe fallback |
| `fm-visible-title.sh`    | Build the human WORKER tab title from a resolved outcome and state label, the single owner of that format |
| `fm-visible-status.sh`   | Project authoritative worker details onto Herdr presentation metadata                |
| `fm-upstream-lib.sh`     | Read-only fork upstream-drift detection, ledger-subtracted so the count falls as batches land (`UPSTREAM:`) |
| `fm-stack-versions.sh`   | Report-only check of each stack tool's installed version (Herdr, treehouse, no-mistakes, the AXI tools) against its latest release and Starship's pins, flagging Herdr and treehouse upgrades for a quiet window; its `notice` line tells every home at session start which tools are behind, from a once-a-day release cache |
| `fm-toolchain-lib.sh`    | Read-only runtime version-drift detection against `docs/toolchain-manifest.tsv`, fail-open (`TOOLCHAIN_DRIFT:`) |
| `fm-secondmate-registry-lib.sh` | Shared `data/secondmates.md` record parser and strict/scoped binding validator |
| `fm-durable-path-lib.sh` | Shared normalization of relative durable directory inputs to absolute paths          |
| `fm-startup-memory-budget-lib.sh` | Safe startup-memory budget parsing, publication, and estimation primitives    |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |

## Fork changes to upstream rows

This fork changes what these upstream scripts do, so each row below replaces the row of the same script in scripts.md.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-update.sh`           | Guarded self-update of firstmate and local or remote secondmate homes to origin's default branch or, on the release channel, its newest release, reconciling redundant divergence and classifying every live mate left on the target commit for restart or fallback nudge; `--step-back` moves a release-channel home back one release |
| `fm-install-herdr.sh`    | Install the exact-version Herdr pin CI and setup use, with official asset URL, SHA-256, and protocol checks |
| `fm-claude-stop-autoarm.sh` | Claude Stop/StopFailure `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake; see [watcher continuity](watcher-continuity.md#claude-stop-hook) |
| `fm-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub, GitLab, or Forgejo URL, refuse a Gerrit change because firstmate never submits one, refuse a GitHub pull request this home did not open or one that changes Starship's own rules unless `--captain-approved`, merge a GitHub pull request no task owns through the same guards with `--no-task`, then refuse an outcome it cannot prove landed or queued |
| `fm-inbox.sh`            | The captain's out-of-band capture surface: queue a note (optionally idempotent by request id), announce or repair its wake, ring a busy primary, record progress lines and a durable primary reply, forget a note by request id, and emit bounded receipts and primary-readiness JSON |

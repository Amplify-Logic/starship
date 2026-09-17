# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent session-open hook use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-sessionstart-run.sh` | Route a native session-open hook to the full digest, a context re-emit, or the nudge |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-startup-network.sh`  | Run session start's network checks and inactive-outcome scan off its blocking path, retaining reports and durable findings |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print structured fleet snapshot JSON and refresh only its parent-side remote-ledger cache (schema `fm-fleet-snapshot.v1`) |
| `fm-home-summary-refresh.sh` | Atomically publish this home's structured summary ledger                         |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the bounded remote-ledger fleet snapshot to compact TOON; `--include-prs` adds live GitHub enrichment |
| `fm-bearings-board.sh`   | Build and arm the stable interactive `/bearings lavish` fleet board                  |
| `fm-secondmate-reconcile.sh` | Queue Bearings reconcile requests for later supervision delivery and ask each mismatched home through its durable inbox with a per-home cooldown |
| `fm-update.sh`           | Guarded self-update of firstmate and local or remote secondmate homes, reconciling redundant divergence and classifying every live mate left on the target commit for restart or fallback nudge |
| `fm-secondmate-restart.sh` | Persist open conversational work, then restart eligible second mates or report the fallback outcome |
| `fm-secondmate-restart-lib.sh` | Shared second-mate restart capability and persistence-request contract |
| `fm-on.sh`               | Execute one tracked Firstmate command in a configured remote secondmate home, using its job worker except for the doctor bootstrap |
| `fm-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `fm-remote-job-worker.sh` | Long-lived remote queue worker for tracked `fm-*.sh` commands in the account runtime |
| `fm-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `fm-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's second-mate readiness (remote job worker, Herdr, Aqua launch agents, PATH, and required tools) |
| [`fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) | Move queued backlog items into a secondmate home; its header owns route-specific wake outcomes and retries |
| `fm-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `fm-captain-hold.sh`     | Hold tasks for the captain, record the captain's answers, gate investigation completion, and report record divergence between the status log and the backlog |
| `fm-decision-hold.sh`    | One-release compatibility shim mapping the retired decision commands onto fm-captain-hold.sh |
| `fm-brief.sh`            | Scaffold ship (explicit `--mode`), scout, secondmate-charter, and Herdr-lab briefs, with Captain's intent and Firstmate spec subsections on ship/scout |
| [`fm-dod-lib.sh`](../bin/fm-dod-lib.sh) | Own ship/scout worker role scope, ship definitions of done, and the no-mistakes `--intent` contract |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-herdr-lab-viewer.py` | The pty engine behind `fm-herdr-lab.sh viewer`: one real foreground Herdr client on a non-zero window grid |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, bounded concurrency, budgets, coverage guard, timing/JSON; refuses to execute in the repository primary checkout when `FM_TASK_ID` marks a task worker |
| `fm-test-isolation-proof.sh` | Concurrent isolation harness and portable candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` `@AGENTS.md` pointer, and self-governance guidance (explicit project mark documented in the helper's header and help) |
| `fm-guard.sh`            | Warn on primary-checkout tangles, main-session pending wakes, and unhealthy supervision |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for fm-lock.sh and the Claude Stop auto-arm |
| `fm-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a local secondmate home and maintain `data/secondmates.md` |
| `fm-remote-home-seed.sh` | Register and provision a whole secondmate home on an SSH-reachable host              |
| `fm-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `fm-remote-doctor.sh` |
| [`fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer shapes, capability-aware screen classification, and verdicts |
| `fm-agent-process-lib.sh` | Backend-neutral harness-process name classifier shared by the tmux and herdr adapters |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Herdr session-provider adapter with its own required CI lane                         |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live local or remote secondmates and send the placement-specific config reread when changed |
| `fm-project-mode.sh`     | Resolve a project's registered delivery posture from `data/projects.md` for fleet sync and home seeding |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-task-inbox-lib.sh`   | Single owner of durable steering-inbox records, acknowledgement, doorbells, and the delivery-attempt ladder |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and keyed escalation lifecycle |
| `fm-secondmate-report.sh` | Optional helper that resolves the parent channel itself and appends a correlated status or document-pointer report |
| `fm-extension.mjs`       | Bind, inspect, verify, and strictly invoke trusted external process-event adapter packages |
| `fm-extension-launch-barrier.mjs` | Publish one exact static core-owned invocation group before package code runs |
| `fm-extension.sh`        | Expose extension binding commands through the tracked shell and remote-home command boundary |
| `fm-procevent.sh`        | Register, supervise, capture, classify, acknowledge, and safely retire built-in or explicitly bound process-event sources |
| `fm-procevent-remote-reply.sh` | Relay the remote-secondmate status stream through non-destructive process-event deltas |
| `fm-procevent-quota.sh`  | Wake Firstmate when tracked quota drops below a threshold, is exhausted, or cannot be polled |
| `fm-procevent-when.sh`   | Fire a trust-bound deterministic action at most once when its registered condition holds, then wake with the outcome |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe watcher: absorb benign wakes, detect stalled local-secondmate wake queues, and exit on actionable ones |
| `fm-inactive-reconcile.sh` | Reconcile long-inactive direct crewmate terminal outcomes without forge access |
| `fm-afk-contract.sh`     | Own the away-posture record: schema, mandate-clause fields and never-set scan, refusal naming the missing part, read-back, entry announcement, archive, and cross-subsystem authority lock |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry (read-back, confirm, record), exit, rollback, and any backend terminal lifecycle |
| `fm-afk-return.sh`       | Own deterministic return shutdown, the return brief, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-nm-run-lib.sh`       | Single owner of shared no-mistakes run-attribution primitives and rules             |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `fm-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward/reconcile helper for origin pulls and secondmate syncs, with durable divergence markers |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi.sh`        | Run `tasks-axi` against this home's backlog from any working directory               |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-backlog-transition-lib.sh` | Pair task-record changes with their backlog transitions and replay interrupted closes |
| `fm-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and quota snapshot schema validation           |
| `fm-quota-choose.sh`     | Choose the first candidate with known positive quota from an ordered harness:model list |
| `fm-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `fm-wake-drain.sh`       | Present and acknowledge the current actor's claimed wake rows alongside status, outcome-backstop, decision, divergence, recovery, and supervision checks |
| `fm-wake-grant.sh`       | Serialize Pi supervision-branch wake-row claim activation, publication, release, and deactivation |
| `fm-wake-lib.sh`         | Shared durable wake queue, recovery generations, portable locks, and watcher identity/health helpers |
| `fm-classify-lib.sh`     | Shared wake classification, durable keyed-decision folds and scans, unread status selection, and bounded latest-event snapshots |
| `fm-send.sh`             | Steer a task via a durable inbox record plus doorbell, or send a supported key or typed harness invocation through the recorded backend |
| `fm-branch-prompt.sh`    | Emit the Pi supervision branch's byte-stable system prompt ([pi-supervision-branch.md](pi-supervision-branch.md)) |
| `fm-branch-outcome.sh`   | Own the supervision branch's append-only outcome store, cursors, bounded status-coverage indexes, and session-start replay |
| `fm-lease.sh`            | Claim, release, inspect, and sweep per-task supervision leases                       |
| `fm-lease-lib.sh`        | One owner of the supervision lease contract and the main-only role-partition guards  |
| `fm-control.sh`          | Agent lifecycle control plane: allowlisted `interrupt`, `exit`, and transactional `relaunch` verbs for an exact task id ([agent-control.md](agent-control.md)) |
| `fm-control-lib.sh`      | One executable owner of the control-plane verb allowlist, per-harness interrupt/exit mechanics, and per-backend capability |
| `fm-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `fm-busy-event.sh`       | The only writer of a task's semantic busy-state record and native-harness progress marker; arms an incarnation and applies lifecycle events |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication, merge-notification identity, and retirement |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub or GitLab URL, then refuse an outcome it cannot prove landed or queued |
| `fm-merge-outcome-lib.sh` | Publish a confirmed merge's durable, role-routed supervision outcome                 |
| `fm-merge-authority-lib.sh` | Resolve merge authority at the gate, persist it against the accepted canonical PR, and identity-check its later poll consumption |
| `fm-parent-channel-lib.sh` | Resolve a secondmate home's parent channel and append a captain-facing outcome line to it at most once |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task with an explicit delivery mode, write the ship instructions carrying that mode's definition of done, and supersede the task's brief so a later relaunch cannot revive stale scout delivery text |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness, resolve crew or secondmate harness, model, and effort, and validate the native-only `ultra` effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `fm-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions and emit their once-only wake   |
| `fm-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `fm-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `fm-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `fm-public-followup-lib.sh` | Shared Relay gate, open-loop registry state, expiry classification, locking, and private transport paths |
| `fm-public-followup.sh`  | Reconcile and deliver typed public commitments, then rechain or explicitly retire their retained loops |
| `fm-public-followup-emit.sh` | Report one typed terminal work result into the home that owes the public reply, or stage it when that home is on another machine |
| `fm-public-followup-collect.sh` | Read and retire the typed terminal results a remote work home staged for the home that owes the public reply |
| `fm-inbox.sh`            | The captain's out-of-band capture surface: queue a note, dictate one, read status, ask a side question |
| `fm-mail.sh`             | General-purpose mail plane: read unseen IMAP mail, send one SMTP message, or surface new mail as a `check` wake via `poll` (configuration in the home's gitignored `.env`) |
| `fm-mail.py`             | The IMAP/SMTP engine behind `fm-mail.sh` |
| `fm-mail-check.sh`       | Standing received-mail poll: `arm` registers a watcher check that runs `fm-mail.sh poll` on the watcher cadence (new mail still wakes via the poll; the check's own line also wakes unless the poll is a proven no-op), `disarm` removes it |
| `fm-voice-relay.py`      | Hold the spoken conversation on this host, answer from the records, and hand real work to `fm-inbox.sh` ([voice-relay.md](voice-relay.md)) |
| `fm-voice-client.py`     | The laptop end of the spoken interface: capture, playback, and turn timing over SSH; audio devices unverified |
| `fm_voice_frame.py`      | The wire format both machines share, copied to the laptop beside the client          |
| `fm_voice_records.py`    | What a spoken answer may read, and the handover that queues real work                |
| `fm-primary.sh`          | Launch a verified primary profile from the tracked root, owning profile aliases and bypass flags |
| `fm-primary-handoff.sh`  | Optional quota- and context-aware primary orchestrator handoff (docs/primary-handoff.md) |
| `fm-primary-handoff-lib.sh` | Shared handoff state-machine and never-two-holders helpers, also executed by `fm-lock.sh release-stale` for the stale-lock release decision |
| `fm-account.sh`          | List and create the isolated vendor account homes named by `config/accounts.json`, printing the login command it never runs |
| `fm-account-lib.sh`      | Shared named-account resolution, derived `data/accounts/<vendor>/<name>` homes, and the missing/logged-out/wrong-seat launch gate |
| `fm-status-bar.sh`       | Render the canonical guarded primary status bar on native surfaces and on tmux or herdr companion panes (docs/status-bar.md) |
| `fm-cursor-statusline.sh` | Opt-in install, status, and exact-restore uninstall of Firstmate's status line in Cursor CLI's own user config (docs/status-bar.md) |
| `fm-fleet-status-lib.sh`  | Fold `fm-crew-state.sh` into the status row's working/validating/paused/attention counts, out of band and cached (docs/status-bar.md) |
| `fm-codex-session-metrics-lib.sh` | Supply the Codex companion's real context and provider-quota figures from the exact followed session and the account owner (docs/status-bar.md) |
| `fm-status-cache-lib.sh` | Shared status-row cache freshness, staleness bounds, and single-refresh claim ownership |
| `fm-landed-lib.sh`       | Shared newest-first completion-recency ordering for every capped landed surface       |
| `fm-startup-memory-budget.sh` | Validate and report the bounded startup-memory allowance and current usage |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-decision-surface.sh` | Render, poll, and route the private loopback Lavish surface over captain decisions   |
| `fm-read.sh`             | Render a Markdown path or task report as a private loopback Lavish reading page      |
| `fm-chart-room.sh`       | Serve the private read-only chart room: fleet home, per-project goal maps, rendered fresh on every request (docs/chart-room.md) |
| `fm-bridge-view.sh`      | Serve the captain's phone-first fleet glance, the `/deck` Action Deck page, photo drop, and hold-to-speak on loopback behind Tailscale Serve (docs/bridge-view.md) |
| `fm-bridge-fields.sh`    | Add the bridge's title, repo, hold kind and hold reason to a finished bearings model, so the projection itself carries none of them |
| `fm-overlay.sh`          | Open a Markdown view as an in-terminal Herdr overlay pane, degrading to a printed pointer to the same content; installs nothing and is called nowhere by default (docs/chart-room.md) |
| `fm-present.sh`          | Present a captain-action artifact once per unchanged milestone through its existing local owner |
| `fm-speak.sh` | Speak one captain-facing outcome line out of this machine's speaker, shaped by the glasses spoken-register owner; a named `voice` selects macOS say, otherwise Deepgram Aura leads when DEEPGRAM_API_KEY is set, each the other's fallback (the script header owns the mechanic); inert unless config/speak opts the home in (docs/configuration.md "Desk voice-out", docs/desk-floater.md) |
| `fm-deepgram-tts.sh` | Synthesize one line with Deepgram Aura and play it (or --to a file); reads DEEPGRAM_API_KEY from env or gitignored .env; never logs the key |
| `fm-deepgram-stt.sh` | Transcribe one audio file with Deepgram for the desk floater push-to-talk path; never logs the key |
| `fm-desk-voice.sh` | Durable desk-voice mailbox: deliver / pending / drain captain-input transcripts under state/desk-voice/ and wake the primary (docs/desk-floater.md) |
| `fm-desk-floater.sh` | Build and launch the Mac always-on-top push-to-talk floater for this home (docs/desk-floater.md) |
| `fm-voice-relay.sh`      | Durable freshness, evidence, and presentation ledger for the spoken desktop companion: topic revisions, the pre-action and pre-speech gates, and immutable receipts (docs/desktop-companion.md) |
| `fm-voice-relay-appserver.sh` | Dry-run-unless-`--live` app-server adapter for that relay: schema probe, steerable-status check, `turn/steer`, `turn/interrupt` (docs/desktop-companion.md) |
| `fm-adhd.sh`             | Bounded ADHD divergent-ideation wrapper; writes distilled CLI output and refuses when `adhd` is absent (docs/adhd.md) |
| `fm-second-opinion.sh`   | Bounded rival-model second-opinion wrapper; hostile review via Pi, neutral cwd, Codex quota floor (docs/second-opinion.md) |
| `fm-browse-session.sh`   | Isolated per-task chrome-devtools-axi sessions with per-task profiles; never attaches to the captain's Chrome (docs/worker-browsing.md) |
| `fm-action-gateway.sh`   | Privilege-separated confirm-first action broker: digest-bound captain approval, locked state machine, hard spend/messaging ceilings, execution stubbed (docs/action-gateway.md) |
| `fm-order.sh`            | Standing Order list/show/run/log-fire/arm/disarm/graduate over `data/orders/<slug>.md`; arming requires `--by-captain` (docs/ops-command-center.md) |
| `fm-tray.sh`             | Read-only pending-action renderer over the action-gateway audit log; age is the headline; never approves (docs/ops-command-center.md) |
| `fm-deck.sh`             | Refreshing captain-private Action Deck pane: what is waiting on the captain above the fold, then what is moving; composes records this home already keeps and mutates none of them; `--json` emits the same model for the bridge's `/deck` page (docs/ops-command-center.md, docs/bridge-view.md) |
| `fm-action-gateway-v2.py` | Exercise gateway v2 strict parsing, immutable plans, SQLite state, and narrow peer-authenticated protocols in unprivileged test mode with all execution disabled (docs/action-gateway-v2.md) |
| `fm-worker-boundary-regression.sh` | Run the synthetic unprivileged adversarial isolation pack for ambient, restricted-account, and nested-container targets (docs/worker-boundary-regression.md) |
| `fm-harness-exam.sh`     | Re-verify one worker adapter's eight runtime properties against a real runtime in an isolated lab home and score them from outside the pane (docs/harness-exam.md) |
| `fm-install-baby-menu-quota.sh` | Install the tracked Baby Menu quota widget into a Baby Menu home, preserving other extensions and machine-local settings (docs/baby-menu-quota-widget.md) |
| `fm-fork-test-registry-lib.sh` | Parse `tests/fork-test-registry.conf` so fork-only test families and changed-path owners are declared there rather than in the runner; its header owns the row grammar and the missing-registry behavior |
| `fm-continuity-pretool-check.sh` | Narrow Claude recovery gate when in-flight work has no live watcher lock (docs/arm-pretool-check.md) |
| `fm-continuity-command-policy.mjs` | Semantic owner of Claude continuity-gate fleet-command classification (docs/arm-pretool-check.md) |
| `fm-dispatch-select.sh`  | Resolve a matched crew-dispatch rule to one concrete profile, owning `quota-balanced` and `capability-recent` selection plus capability evidence surfacing |
| `fm-capability-lib.sh`   | Append-only capability outcome log (green means first-try validation pass), 7-day reader, ranking, and advisory scout-tax helpers |
| `fm-home-port.sh`        | Export, import, push, pull, or bootstrap captain-private portable home material (docs/porting.md) |
| `fm-home-manifest.sh`    | Print the environment-fidelity manifest of backend and tool versions that `fm-bootstrap.sh manifest` dispatches to (docs/porting.md) |
| `fm-project-display-name.sh` | Resolve a project slug to its human display name with explicit brand overrides and a synthesized fallback |
| `fm-file-event-lib.sh`   | Default glasses mailbox/inbox watch paths, the bounded file-event wait, and the watcher's forked terminal wait (hook W1) |
| `fm-file-eventwait.py`   | Portable kqueue, inotify, or stat-backed implementation of the bounded file-event wait |
| `fm-shift.sh`            | Arm, stand down, and report the captain's glasses voice loop for one delivery shift; refuses rather than half-arming (docs/shift-loop.md) |
| `fm-supervision-sentinel.sh` | Home-scoped macOS launchd outage sentinel that alarms outside the harness process tree and never restarts supervision (docs/watcher-continuity.md) |
| `fm-morning-intake.sh`   | Opt-in once-per-local-day intake gate owning the local day, bounded retries, visible failure, and the completion watermark (docs/configuration.md "Morning intake") |
| `fm-morning-intake-schedule.sh` | Render, install, inspect, and remove that intake's opt-in macOS launchd schedule and its live watcher check (docs/configuration.md "Morning intake") |
| `fm-channel-intake.sh`   | Opt-in continuous channel intake: the per-source repeat-poll gate and obligation ledger, local only, owning cadence, checkpoints, dedup, backoff, and the notification budget (docs/channel-intake.md) |
| `fm-channel-intake-schedule.sh` | Render, install, inspect, and remove that intake's opt-in macOS launchd schedule and its live watcher check (docs/channel-intake.md) |
| `fm-launchd-schedule-lib.sh` | Shared per-home LaunchAgent render, lint, load, and remove for this fork's scheduled owners |
| `fm-task-outcome.sh`     | Resolve a worker outcome from an explicit value, structured backlog title, or safe fallback |
| `fm-visible-title.sh`    | Build the human WORKER tab title from a resolved outcome and state label, the single owner of that format |
| `fm-visible-status.sh`   | Project authoritative worker details onto Herdr presentation metadata                |
| `fm-upstream-lib.sh`     | Read-only fork upstream-drift detection, ledger-subtracted so the count falls as batches land (`UPSTREAM:`) |
| `fm-toolchain-lib.sh`    | Read-only runtime version-drift detection against `docs/toolchain-manifest.tsv`, fail-open (`TOOLCHAIN_DRIFT:`) |
| `fm-secondmate-registry-lib.sh` | Shared `data/secondmates.md` record parser and strict/scoped binding validator |
| `fm-path-lib.sh`         | Shared normalization of relative durable directory inputs to absolute paths          |
| `fm-startup-memory-budget-lib.sh` | Safe startup-memory budget parsing, publication, and estimation primitives    |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |

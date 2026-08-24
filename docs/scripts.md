# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-primary.sh`          | Launch a verified primary profile from the tracked root, owning profile aliases and bypass flags |
| `fm-primary-handoff.sh`  | Optional quota- and context-aware primary orchestrator handoff (docs/primary-handoff.md) |
| `fm-primary-handoff-lib.sh` | Shared handoff state-machine and never-two-holders helpers                        |
| `fm-status-bar.sh`       | Render the canonical guarded primary status bar and Kimi tmux companion              |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-landed-lib.sh`       | Shared newest-first completion-recency ordering for every capped landed surface       |
| `fm-startup-memory-budget.sh` | Validate and report the bounded startup-memory allowance and current usage |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-decision-hold.sh`    | Create, verify, complete, and resolve durable captain-held decisions                 |
| `fm-decision-surface.sh` | Render, poll, and route the private loopback Lavish surface over captain decisions   |
| `fm-read.sh`             | Render a Markdown path or task report as a private loopback Lavish reading page      |
| `fm-chart-room.sh`       | Serve the private read-only chart room: fleet home, per-project goal maps, rendered fresh on every request (docs/chart-room.md) |
| `fm-bridge-view.sh`      | Serve the captain's phone-first fleet glance, photo drop, and hold-to-speak on loopback behind Tailscale Serve (docs/bridge-view.md) |
| `fm-overlay.sh`          | Open a Markdown view as an in-terminal Herdr overlay pane, degrading to a printed pointer to the same content; installs nothing and is called nowhere by default (docs/chart-room.md) |
| `fm-present.sh`          | Present a captain-action artifact once per unchanged milestone through its existing local owner |
| `fm-adhd.sh`             | Bounded ADHD divergent-ideation wrapper; writes distilled CLI output and refuses when `adhd` is absent (docs/adhd.md) |
| `fm-second-opinion.sh`   | Bounded rival-model second-opinion wrapper; hostile review via Pi, neutral cwd, Codex quota floor (docs/second-opinion.md) |
| `fm-browse-session.sh`   | Isolated per-task chrome-devtools-axi sessions with per-task profiles; never attaches to the captain's Chrome (docs/worker-browsing.md) |
| `fm-action-gateway.sh`   | Privilege-separated confirm-first action broker: digest-bound captain approval, locked state machine, hard spend/messaging ceilings, execution stubbed (docs/action-gateway.md) |
| `fm-action-gateway-v2.py` | Exercise gateway v2 strict parsing, immutable plans, SQLite state, and narrow peer-authenticated protocols in unprivileged test mode with all execution disabled (docs/action-gateway-v2.md) |
| `fm-worker-boundary-regression.sh` | Run the synthetic unprivileged adversarial isolation pack for ambient, restricted-account, and nested-container targets (docs/worker-boundary-regression.md) |
| `fm-harness-exam.sh`     | Re-verify one worker adapter's eight runtime properties against a real runtime in an isolated lab home and score them from outside the pane (docs/harness-exam.md) |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Phase 2 concurrent isolation proof and proven-isolated candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and unhealthy supervision    |
| `fm-primary-scope-lib.sh` | Shared primary-home and session-lock-ancestry predicates for tracked hooks           |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-continuity-pretool-check.sh` | Narrow Claude recovery gate when in-flight work has no live watcher lock (docs/arm-pretool-check.md) |
| `fm-continuity-command-policy.mjs` | Semantic owner of Claude continuity-gate fleet-command classification (docs/arm-pretool-check.md) |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-dispatch-select.sh`  | Resolve a matched crew-dispatch rule to one concrete profile, owning `quota-balanced` and `capability-recent` selection plus capability evidence surfacing |
| `fm-capability-lib.sh`   | Append-only capability outcome log (green means first-try validation pass), 7-day reader, ranking, and advisory scout-tax helpers |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push inherited local material to live secondmates and point changed config at its private exact-content reread |
| `fm-home-port.sh`        | Export, import, push, pull, or bootstrap captain-private portable home material (docs/porting.md) |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `fm-project-display-name.sh` | Resolve a project slug to its human display name with explicit brand overrides and a synthesized fallback |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and one-shot escalation |
| `fm-secondmate-report.sh` | Append a correlated parent status or document-pointer report                         |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-file-event-lib.sh`   | Default glasses mailbox/inbox watch paths and bounded file-event wait for the watcher |
| `fm-file-eventwait.py`   | Portable kqueue, inotify, or stat-backed implementation of the bounded file-event wait |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-supervision-sentinel.sh` | Home-scoped macOS launchd outage sentinel that alarms outside the harness process tree and never restarts supervision (docs/watcher-continuity.md) |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-task-outcome.sh`     | Resolve a worker outcome from an explicit value, structured backlog title, or safe fallback |
| `fm-visible-status.sh`   | Project authoritative worker details onto Herdr presentation metadata                |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-upstream-lib.sh`     | Read-only fork upstream-drift detection, ledger-subtracted so the count falls as batches land (`UPSTREAM:`) |
| `fm-toolchain-lib.sh`    | Read-only runtime version-drift detection against `docs/toolchain-manifest.tsv`, fail-open (`TOOLCHAIN_DRIFT:`) |
| `fm-timeout-lib.sh`      | Shared portable wall-clock timeout for bounded read-only probes                      |
| `fm-supervision-lib.sh`  | Shared in-flight supervision status and canonical outage-summary helpers             |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-secondmate-registry-lib.sh` | Shared `data/secondmates.md` record parser and strict/scoped binding validator |
| `fm-path-lib.sh`         | Shared normalization of relative durable directory inputs to absolute paths          |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-startup-memory-budget-lib.sh` | Safe startup-memory budget parsing, publication, and estimation primitives    |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, emit bounded best-effort status-event annotations, then assert supervision health |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-wait wake classification vocabulary, plus the declared-pause recheck cadence and shared-blocker grouping fold |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll and provenance publication |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-merge.sh`         | Record PR metadata, then merge a task's canonical full GitHub URL                    |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash newly offered mentions and emit their once-only wake |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, clear, and cap completion follow-ups for an X-mode-linked task         |
| `fm-public-followup-lib.sh` | Gate and locate private promised-public-reply transport                           |
| `fm-public-followup.sh`  | Reconcile typed terminal results and deliver a promised public reply once            |
| `fm-public-followup-emit.sh` | Report a typed terminal result to the home that owns the public reply             |

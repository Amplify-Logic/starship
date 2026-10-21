---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, PRESENTATION_UNAVAILABLE, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, CONFIG_REREAD, ACCOUNTS invalid, PR_CHECK_MIGRATION, TOOLCHAIN_DRIFT, HOST_ENV, UPSTREAM, UPSTREAM_REPORT, UPSTREAM_CATCHUP, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The session-start rules in `session-start-recovery` still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.59.2, because older builds do not scope `axi status` to the current branch, so a worker can read another lane's gate or outcome as its own.
  For essential axi-family tools - `gh-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `peekaboo`, reported only in a home opted in with `config/computer-use`, run `bin/fm-computer-use.sh check` to name the problem (absent, another version, or fails to start) for the captain; it gates only computer use, so do not hold unrelated dispatch for it.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `PRESENTATION_UNAVAILABLE: lavish-axi ...` - explain that visual presentation is unavailable and continue nonvisual work with plain-text decisions and reports; do not hold unrelated dispatch for installation consent.
  Do not use Lavish until it satisfies the floor owned by `bin/fm-bootstrap.sh`; when visual work needs it, request consent for the printed install or upgrade command, then rerun bootstrap to confirm compatibility before using it.
  Scout briefs check the same floor when scaffolded and ask for a text report instead of a Lavish loop, so scaffold a visual scout only after that rerun confirms compatibility.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote secondmate host - and the stage stopped rather than letting it wedge; a `recorded fleet lock holder changed` line means lock line 1 no longer names the pid that requested the sweeps, because another session took the lock or this session re-anchored it, so they were skipped and belong to whichever session holds the lock now.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
  `skipped: registry entry does not resolve to a delivery posture` is the one skip that is not one-off: the clone is left alone on every bootstrap until `data/projects.md` is corrected, so run the printed `bin/fm-project-mode.sh <repo>` to read the refusal and fix the entry.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/fm-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `FM_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `BOOTSTRAP_INFO: closed the backlog item for <id> after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay closed the item, but the durable transition says physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure, then reconcile any surviving resource.
- `BOOTSTRAP_INFO: kept the captain call for <id> open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay retained the captain-held item, but physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure without closing or lifting the captain's call, then reconcile any surviving resource.
- `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed: <reason>` - this session start found a pending-close record carrying a close or retention transition but could not land it.
  A valid teardown record proves the transition was authorized and recorded, but physical cleanup may be partial: verify process reaping, the local-copy return, and endpoint closure before assuming those resources are gone.
  A validation error means the record cannot be trusted, so do not assume cleanup completed or follow any path or argument stored in it.
  Read the named reason, inspect the marker as inert data when validation failed, fix the record or backlog-file problem, and rerun session start so the valid recorded transition replays.
  Never delete `state/<id>.backlog-close` by hand - that can discard a completion link or captain-call retention the cleanup captured, and the surviving marker prevents the record sweep from starting the item meanwhile.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be read: <reason>` - this home could not determine whether the item matches its worker record.
  Resolve the named backlog read problem and rerun session start; never guess by starting or closing an unreadable item.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be moved to In flight: <reason>` - this home owns a worker whose backlog item is still queued, and the reconciliation could not correct it.
  Until it is corrected, the fleet view reads that worker as work no backlog item owns; resolve the named backlog problem and rerun session start.
- `BACKLOG_RECONCILE: code-root <file> is not this home's <file>; ...` - a tasks-axi write addressed the code root instead of this home, so the queue has already forked and either copy may hold rows the other lacks; [`docs/configuration.md`](../../../docs/configuration.md) ("Backlog backend") owns why.
  Neither copy is a safe winner: union-merge them into this home's file by task id, resolve each conflicting id to its most recent real transition, check this home's archive before treating a missing Done row as lost, and verify the merged id set equals the union of both inputs before installing it.
  Then move the code-root file aside rather than deleting it, tell the captain which rows were recovered, and run every later backlog command through `bin/fm-tasks-axi.sh`; re-linking the code-root copy is never the fix, because the next cwd-relative tasks-axi write replaces the link again.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox because backlog receipt or local outbox cleanup has not completed; [`bin/fm-backlog-handoff.sh`](../../../bin/fm-backlog-handoff.sh) owns the release contract.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after the route, receipt, or cleanup problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `ACCOUNTS: invalid config/accounts.json - <reason>` - the optional vendor account registry exists but failed low-cost bootstrap validation; launches that pin no account keep working on the ambient account, an explicit `--account` refuses while the file stays broken, so fix the malformed schema, unknown vendor, unsafe account name, undefined default, or unverifiable `expect` when convenient (`docs/configuration.md` "Vendor account pinning" owns the schema).
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `CONFIG_REREAD: secondmate <id>: send failed: <reason>` - inherited config changed for a live secondmate home, but its distinct self-describing exact-content reread imperative was not delivered, so that secondmate is still running on its previous inherited config.
  The generation stays pending on disk for the next bootstrap or `bin/fm-config-push.sh` retry; leave it in place, fix the named cause (an unavailable endpoint, a full retry queue, or a per-home inheritance lock still held by a running spawn or push), and treat that home's inherited settings as stale until a later run reports no failure.
  `secondmate-provisioning` owns the reread delivery contract itself.
- `TOOLCHAIN_DRIFT: <runtime> installed <version>, certified <version> (<evidence>) - <why>` - an agent runtime on PATH is not the build this repo carries certification evidence for.
  It is a report, not a gate: nothing is blocked, no launch was refused, and work continues on the drifted build.
  Do not install, downgrade, or pin anything in response; the line exists so a human decides between re-certifying against the new build and pinning the old one.
  Batch it into the next natural reply unless the drifted runtime is the one a task is about to depend on, or the line names a runtime whose certified pin is enforced elsewhere (`bin/fm-primary.sh` refuses a Cursor primary that is not its exact certified version, because Cursor's Stop turn-end hook is unverified rather than merely drifted, so Cursor drift means that certified path is down right now).
  Report it to the captain as the concrete consequence - which runtime is running past the evidence, and what that evidence covered - never as a version-number dump.
  Absence of this line means every listed runtime matched, was not installed, or printed no readable version; it is never a claim that a runtime was verified.
- `HOST_ENV: WSL: ...` - the WSL home this first mate runs in needs a change the line names; nothing is blocked, and [`ONBOARDING-windows.md`](../../../ONBOARDING-windows.md) owns the setup it points at.
  A path on the Windows drive is the captain's to move into the Linux home; never move a home or clone yourself, because that strands live workers and unlanded work.
  Localhost forwarding off means review boards and dev servers will not open in the Windows browser until the captain edits the named `.wslconfig` and restarts WSL, which also ends this session.
  Networking mode none means this Ubuntu has no network at all, so every network check and install fails, until the captain removes the mirrored line from `.wslconfig` and restarts WSL, which also ends this session.
- `UPSTREAM: <N> commits behind <remote>/<branch> (<url>) - <subjects>` - this home is a fork whose configured upstream has commits the local checkout lacks.
  `<N>` is what is genuinely still outstanding: the raw upstream delta minus the commits this fork has already delivered.
  When the line carries an `<R> upstream commits, <D> already delivered here` clause, the ledger accounted for `<D>` of them, and the listed subjects are only the outstanding ones.
  Tell the captain the outstanding count, the upstream URL, and the listed subjects so they can judge urgency; the raw figure is bookkeeping and rarely worth relaying.
  A commit the fork has delivered without leaving any machine-readable reference belongs in `docs/upstream-ported-ledger.txt` as one reviewable record, which is also how a wrong match is retired; never replace the derivation with a stored total.
  Do not merge, rebase, or fast-forward from upstream yourself; `/updatefirstmate` and `bin/fm-update.sh` only advance from origin and cannot deliver upstream work on a fork.
  Wait for an explicit captain decision on whether and how to take the upstream commits; taking them is a catch-up through the `catchup` skill.
  Absence of this line is normal for a non-fork home, an offline probe, or a current tip - never invent drift.
- `UPSTREAM_REPORT: new private report at <path>` - the standing weekly upstream watch produced a new private report.
  Read the report, relay its new gains and named fork collisions, and make no porting change without a separate captain decision.
  Also relay its tool-version `Behind:` line in plain words and install nothing, following the `catchup` skill's Tool versions rules.
  After reading, run `bin/fm-upstream-watch.sh acknowledge <path>` so the same report does not surface at later session starts.
  A quiet report's upstream part is one "nothing to do" line, followed by the tool versions; relay that one-line outcome and the tool versions, never padding from older reports.
- `UPSTREAM_CATCHUP: catch-up ready to prepare, private report at <path>` - a scheduled run on a home opted in to the weekly catch-up, or an earlier on-demand `bin/fm-upstream-watch.sh catchup` run, found new upstream work and wrote a catch-up plan that is still waiting to be prepared.
  Load the `catchup` skill, which owns preparing, landing, and acknowledging it.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.

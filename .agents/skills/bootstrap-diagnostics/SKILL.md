---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, NUDGE_SECONDMATES, CONFIG_REREAD, TOOLCHAIN_DRIFT, UPSTREAM, UPSTREAM_REPORT, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`docs/configuration.md` "Backlog backend" owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because crew-dispatch `quota-balanced` may call it; `bin/fm-dispatch-select.sh` still degrades at runtime when quota data is unavailable.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the startup-memory allowance is not a safe one-line positive decimal file; do not infer or propagate a default.
  Correct the primary file, then rerun session start so normal convergence can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
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
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - the local-HEAD secondmate sync left a live secondmate home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing the primary target commit, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed: <reason>` - the session-start liveness sweep could not guarantee that a live secondmate's recorded endpoint is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - the secondmate sweep fast-forwarded a running secondmate home and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send.
- `CONFIG_REREAD: secondmate <id>: send failed: <reason>` - inherited config changed for a live secondmate home, but its distinct self-describing exact-content reread imperative was not delivered, so that secondmate is still running on its previous inherited config.
  The generation stays pending on disk for the next bootstrap or `bin/fm-config-push.sh` retry; leave it in place, fix the named cause (an unavailable endpoint, a full retry queue, or a per-home inheritance lock still held by a running spawn or push), and treat that home's inherited settings as stale until a later run reports no failure.
  `secondmate-provisioning` owns the reread delivery contract itself.
- `TOOLCHAIN_DRIFT: <runtime> installed <version>, certified <version> (<evidence>) - <why>` - an agent runtime on PATH is not the build this repo carries certification evidence for.
  It is a report, not a gate: nothing is blocked, no launch was refused, and work continues on the drifted build.
  Do not install, downgrade, or pin anything in response; the line exists so a human decides between re-certifying against the new build and pinning the old one.
  Batch it into the next natural reply unless the drifted runtime is the one a task is about to depend on, or the line names a runtime whose certified pin is enforced elsewhere (`bin/fm-primary.sh` refuses a Cursor primary that is not its exact certified version, because Cursor's Stop turn-end hook is unverified rather than merely drifted, so Cursor drift means that certified path is down right now).
  A `kimi` line is not one of those: `bin/fm-primary.sh` never refuses a Kimi primary over its version, and it is quiet on the re-verified 0.31.1 as well as on the certified build, so the line means the running build is uncertified rather than down, and it batches like any other drift line.
  Report it to the captain as the concrete consequence - which runtime is running past the evidence, and what that evidence covered - never as a version-number dump.
  Absence of this line means every listed runtime matched, was not installed, or printed no readable version; it is never a claim that a runtime was verified.
- `UPSTREAM: <N> commits behind <remote>/<branch> (<url>) - <subjects>` - this home is a fork whose configured upstream has commits the local checkout lacks.
  `<N>` is what is genuinely still outstanding: the raw upstream delta minus the commits this fork has already delivered.
  When the line carries an `<R> upstream commits, <D> already delivered here` clause, the ledger accounted for `<D>` of them, and the listed subjects are only the outstanding ones.
  Tell the captain the outstanding count, the upstream URL, and the listed subjects so they can judge urgency; the raw figure is bookkeeping and rarely worth relaying.
  A commit the fork has delivered without leaving any machine-readable reference belongs in `docs/upstream-ported-ledger.txt` as one reviewable record, which is also how a wrong match is retired; never replace the derivation with a stored total.
  Do not merge, rebase, or fast-forward from upstream yourself; `/updatefirstmate` and `bin/fm-update.sh` only advance from origin and cannot deliver upstream work on a fork.
  Wait for an explicit captain decision on whether and how to take the upstream commits.
  Absence of this line is normal for a non-fork home, an offline probe, or a current tip - never invent drift.
- `UPSTREAM_REPORT: new private report at <path>` - the standing weekly upstream watch produced a new private report.
  Read the report, relay only its new gains and named fork collisions, and make no porting change without a separate captain decision.
  After reading, run `bin/fm-upstream-watch.sh acknowledge <path>` so the same report does not surface at later session starts.
  A one-line "nothing to do" report needs only that one-line outcome, never padding from older reports.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.

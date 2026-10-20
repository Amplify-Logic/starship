# Herdr runtime backend

This page covers running Firstmate workers on the Herdr runtime backend: setup, where tasks appear, how they are cleaned up, how input reaches them, and how their liveness is read.
Operators who choose Herdr, or who verify Firstmate against it, need it.
Below the operator sections it also keeps this fork's dated adapter findings for `bin/backends/herdr.sh`; [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) remains the owner of the shared, version-scoped Herdr CLI, projection, event, and lifecycle evidence.
A 2026-07-02 cleanup bug proved that `HERDR_SESSION` alone is not a safe way to target destructive session cleanup; see "Session targeting: the `--session` flag, not `HERDR_SESSION` alone" below.

Herdr is an agent-native terminal backend with native per-pane agent state and push events.
Starship's setup makes it the runtime of a fresh home on a Mac and inside WSL 2 on Windows, while a server and any home that already chose tmux keep tmux (see [Setup](#setup)).
Firstmate requires Herdr protocol 14 or newer.
Broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, 0.8.0, and 0.9.5, the version the required real-Herdr CI lane pins.
Protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Find a topic

| What you want to know | Start here |
| --- | --- |
| Install Herdr and select it | [Setup](#setup) |
| Why a command ran on a different `herdr` client | [Client selection](#client-selection) |
| Where task tabs appear and how to watch them | [Watching and task containers](#watching-and-task-containers) |
| The one-task workspaces, their setting, and their cleanup | [Presentation spaces](#presentation-spaces) |
| Grouping tasks by project with status tags and a sorted agents list | [Project groups](#project-groups) |
| Why a seeded default tab is or is not closed | [Default-tab prune](#default-tab-prune) |
| What task metadata records for a Herdr endpoint | [Endpoint metadata](#target-string-and-meta-fields) |
| How text and keys reach a worker and how delivery is confirmed | [Current transport behavior](#current-transport-behavior) and [Composer and injection safety](#composer-and-injection-safety) |
| What happens after a Herdr server restart and how liveness is judged | [Restart and liveness behavior](#restart-and-liveness-behavior) |
| How blocked transitions arrive and what happens without protocol 16 | [Push events and polling fallback](#push-events-and-polling-fallback) |
| Where the away daemon runs and how it stops | [Away-mode supervisor support](#away-mode-supervisor-support) |
| Stopping or deleting Herdr sessions during verification | [Destructive lab safety](#destructive-lab-safety) |
| Known limits and the test suite | [Active limits](#active-limits) and [Regression entry points](#regression-entry-points) |

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the [active limits](#active-limits) below.

On a Mac or inside WSL 2, `bin/fm-herdr-setup.sh` does the whole setup: it keeps a Herdr that passes the version gate or installs the pinned release through `bin/fm-install-herdr.sh`, installs Herdr's Claude Code integration, and writes `herdr` to `config/backend` only for a fresh home.
[ONBOARDING.md](../ONBOARDING.md) step 3 runs it on a Mac, and `bin/fm-linux-setup.sh` runs it inside WSL 2; the script header owns the exact rules.

Prerequisites:

- Herdr protocol 14 or newer, installed by `bin/fm-herdr-setup.sh` or from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering, native event subscription, and opt-in [project groups](#project-groups) agent-view transport.
- `perl`, present on stock macOS and Linux, to start a detached server (see [Server ownership](#server-ownership)).

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

### Selecting Herdr

Select Herdr in any of these ways:

- Local `config/backend` containing `herdr`.
- `FM_BACKEND=herdr` for one launch.
- An explicit request to Firstmate.

A remote second-mate agent is the one case with no choice: it always runs on Herdr, and [`remote-secondmates.md`](remote-secondmates.md) owns that requirement and the readiness its host must meet.

Herdr is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn stays silent, matching the verified tmux default path.

### Spawn preflight and CI

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

### CI lane cleanup

CI cleanup stays inside the guarded, non-default Herdr lab contract and preserves the default-session tripwire; `bin/fm-herdr-ci-cleanup.sh` owns the exact snapshot and teardown rules.
The first required lane targets Linux x86_64; if a genuine unsupported platform invariant appears (focus, cleanup, or default-session tripwire), keep the failure evidence and move the job to macOS rather than skip or weaken the assertion.

### Human worker presentation verification - 2026-07-19

Verified with Herdr 0.7.4, protocol 16, and Pi 0.80.10 in a generated non-`default` session.
Every operation used the hardened `bin/fm-herdr-lab.sh` helper, and guarded teardown confirmed the default-session fleet tripwire was unchanged.
The reproducible command is `FM_HERDR_WORKER_PRESENTATION_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh tests/fm-herdr-worker-presentation-e2e.test.sh`.
The real `workspace list`, `tab list`, `pane list`, `agent list`, and `api snapshot` outputs reported these grouped Agents inputs:

```text
workspace_label=City Guide · 🔵 1 WORKING
tab_label=WORKER · Validate GPS triggers across all seven city stops · 🔵 WORKING
display_agent=pi/gpt-5.6 · detached
native_agent=pi
fm_task_id=journey-gps-seven-stop-v8
```

This verifies an actual registered Pi agent rather than only fake API logs.
Herdr's default grouped row configuration consumes workspace and tab on its first row and agent presentation on its second row, so these are the captain-visible values on that surface.

The exact validation commands and results for this implementation were:

```text
bin/fm-lint.sh
PASS - ShellCheck 0.11.0, no findings

tests/fm-project-presentation.test.sh && tests/fm-visible-status.test.sh && tests/fm-spawn-herdr-presentation.test.sh && tests/fm-watch-presentation.test.sh
PASS

tests/fm-backend-herdr.test.sh
PASS

tests/fm-spawn-batch.test.sh && tests/fm-primary.test.sh && tests/fm-session-start.test.sh
PASS

tests/fm-teardown.test.sh && tests/fm-crew-state.test.sh
PASS

HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
PASS

FM_HERDR_WORKER_PRESENTATION_E2E=1 HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh tests/fm-herdr-worker-presentation-e2e.test.sh
PASS

set -o pipefail; for test_file in tests/*.test.sh; do printf '\\n===== %s =====\\n' "$test_file"; "$test_file"; done 2>&1 | tee /tmp/firstmate-herdr-naming-full-suite.log
PASS - 84/84 test scripts completed, 0 not-ok results, 6 documented opt-in skips
```

### Workspace ordering is creation order and cannot be changed - 2026-08-03

Verified with Herdr 0.7.4 on macOS 25.5.0 in generated non-`default` lab sessions, through `bin/fm-herdr-lab.sh` only.
`herdr workspace --help` exposes `list`, `create`, `get`, `focus`, `rename`, `report-metadata` and `close`, and no reorder, move, sort, or parent operation.
`workspace list` returns workspaces in creation order, and each carries the creation ordinal as `number`.
Creating `Alpha`, then `Beta`, then `Alpha-late` reported:

```text
w1	Alpha
w2	Beta
w3	Alpha-late
```

A workspace created later therefore always appears last, never beside an earlier workspace it is related to.
Any presentation that encodes a relationship in adjacency - upstream's `└ ` child rows included - separates from its parent as soon as one arrives out of order.
`bin/fm-visible-status.sh`'s project workspaces are unaffected, because a task joins an existing project workspace as a tab instead of creating a row.
The staged consequence at fleet scale is captured in [`docs/herdr-layout-preview.md`](herdr-layout-preview.md), reproducible with `FM_HERDR_LAYOUT_PREVIEW_E2E=1 HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh tests/fm-herdr-layout-preview-e2e.test.sh`.

## Client selection

Each operation routed through the adapter's session-scoped CLI helper starts with the first `herdr` on `PATH`, unless that session has already selected another client.

A host can carry more than one client, such as a self-updated copy in `~/.local/bin` beside a package-managed one.
A client older than the running server can receive error code `protocol_mismatch` on operational commands.

### Recovering from a protocol mismatch

On a `protocol_mismatch` refusal, the adapter:

1. Reads `status --json --session <name>` from each distinct `herdr` on `PATH`, in order.
2. Adopts the first one the running server reports compatible.
3. Retries the command on it once.

The choice is reused only for later calls to the same session in that process.
Another session starts with the `PATH` default.
A later mismatch forces selection again, so a changed server can return to that default.

Selection also follows these rules:

- Ordinary adapter operations make no selection read on the happy path.
- Status that supplies neither `.server.compatible` nor both client and server protocols leaves compatibility unknown.
- No other failure triggers a reselection.

`fm-remote-doctor.sh` reports the client selected for the remote session.
Removing or upgrading the shadowing client is the durable fix.
`bin/backends/herdr.sh` "client selection" owns the mechanics.

## Watching and task containers

The ordinary topology puts one task tab per endpoint in the exact workspace of the Firstmate or secondmate that launches it.
When the launcher has no Herdr workspace to inherit, the adapter maintains one durable home-labeled workspace instead.

| Home | Workspace label |
| --- | --- |
| Primary | `firstmate` |
| Secondmate | `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker |

A secondmate launched by the primary receives a narrowly scoped home override during container creation.

### Watching tasks

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.
For cursor workers, the grouped runtime/model row prefers the live idle-footer model from the pane over `meta model=` when readable (`bin/fm-visible-status.sh`, `bin/fm-cursor-model-lib.sh`).

### Focus

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused, because no prior target exists.
Later task creation does not intentionally steal focus.

### Placement beside the launcher

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.

Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for.
A Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.

With presentation spaces disabled, a crewmate or scout is created in the exact workspace that identity currently resolves to.
That workspace is read live from Herdr rather than from the injected snapshot, so the worker always appears beside the agent that launched it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch is the deliberate exception: it stands up that secondmate home's own workspace instead of joining the launcher's.

### Unresolvable launcher identity

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers:

- A missing or unusable socket identity.
- A closed or unreadable launcher pane.
- A pane and tab that disagree about their workspace.
- A workspace missing from the session.
- A pane belonging to another named session or Herdr server.

### Firstmate running outside Herdr

Firstmate running outside Herdr entirely has no launcher workspace to inherit, so its workers use this home's own labeled workspace, created on first use.
That path needs the home label to identify exactly one workspace.
Two workspaces sharing it are an unresolvable placement and refuse rather than adopting either.

Avoid naming a personal workspace `firstmate` or `2ndmate-<id>` for that reason.
Also avoid it because the adapter cannot distinguish that label collision from its own container.

An older secondmate workspace using `firstmate-<id>` is not migrated automatically.
Rename it manually before expecting new tasks or recovery to use it.

### Recovery and existing tasks

Recovery and list-live still scan the first workspace matching the home label, because they address panes they already recorded rather than choosing where new work goes.
The one recovery that does place new work is the control plane's reclaim of a destroyed endpoint.
It mints a replacement tab through this section's ordinary placement rules while pinning the herdr session the task's record names ([`agent-control.md`](agent-control.md) "Reclaiming a task whose endpoint is gone").

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
This section calls that one-task workspace the projection.
Without the projection, tasks use the ordinary flat layout described under [Watching and task containers](#watching-and-task-containers).

### Setting values

The local gitignored `config/herdr-presentation-spaces` file controls the projection.

| File state | Result |
| --- | --- |
| Absent | Leaves the choice to the version floor below (the unconfigured default). |
| `off` | Opts the home out. |
| `on` | Forces the projection on, as a deliberate opt-in. |
| Empty | A deliberate opt-in, the same as `on`. |
| Any other value | Warns and follows the unconfigured default rather than failing a spawn over a purely visual setting. |

Values are compared with whitespace stripped and case ignored.

The empty file is the historical presence-based opt-in form.
So every home that had already enabled the projection stays enabled with no migration step.
No previously enabled home can be turned off by the default or by the floor.

A home that never created the file gains the projection at its next Herdr spawn on a supported release.
That flip is deliberate.
It reaches only the Herdr backend, because no other runtime backend has a projection path.

### Why the default needs Herdr 0.8.0

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal.
That is the only removal shape Herdr's pre-0.8.0 focus defect touches.
The focus-safe removal plan below can only avoid the defect while the closing pane's shell can be proved lone, childless, and idle.

A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close.
On those releases, that close moves the active workspace for roughly a seventh of a second before the restore backstop pulls it back, once per task cleanup.

An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor.
On those releases every workspace-removal primitive preserves focus, and that proof stops being load-bearing.

Below the floor, an unconfigured home uses the ordinary flat per-home layout instead.
It warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker.
Deleting it only makes the same warning appear again.
An upgrade or downgrade re-announces itself because the release is part of the key.

### How the floor is checked

The floor reads two sources:

- The installed client's protocol and version.
- The selected named session's server signals, while that server is running.

Both applicable releases must pass.
When status positively reports no running server, the floor uses only the client, because that client will start it.

The unconfigured default is rechecked after the server is started or adopted, and before any presentation journal or workspace is created.
An unreadable server state or release is treated as unsupported rather than guessed at.

An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded.
That home accepts the documented focus move, and the exact prior-tab restore stays its backstop.

The floor has a single owner, the spawn-time gate.
So cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.

Upgrading Herdr to 0.8.0 or newer is the fix.
Writing `off` is the immediate mitigation for a home that cannot upgrade yet.

### Secondmate homes

The setting is inherited into secondmate homes through the normal configuration-convergence owner.
The default needs no special convergence.
The primary's absent file and the secondmate's absent file both mean the same unconfigured default.
So leaving the file absent converges a secondmate to that same default rather than turning it off.
Only an explicit primary `off` propagates the opt-out.

A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

### Presentation journal

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
A presentation journal is the per-task record in this home's `state/` that binds a task to its projected workspace.

Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Creation proceeds in this order:

1. Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token, before asking Herdr to create anything.
2. After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding.
   That binding records the physical home, named session, endpoint, parent, and immutable expected labels.

Another parent with the same presentation label does not prevent publication or participate in restart reclaim.

The token is visible in the workspace title, because Herdr exposes no verified hidden persistent field.
Neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

### Owning parent and tabs

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses.
It falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent.
The parent is the placement and ordering reference the projection is bound under.

The normal `fm-<id>` task tab is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

### Ordering

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.

Projected children are placed in one contiguous block immediately after their owning home when all of these are verifiable:

- The session layout.
- The protocol.
- The socket.
- `python3`.
- The account-private per-session lock.

Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

### Cleanup and focus safety

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.

Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace.
Its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last.
Both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.

Projected cleanup therefore:

- Runs under the same session lock.
- Refuses to delete the tab a live foreground client is viewing.
- Treats a workspace-emptying close as a focus-safe removal.

A focus-safe removal takes these steps:

1. Verify the close would empty the workspace.
2. When needed, reposition the doomed workspace behind the focused one through the verified `workspace.move` transport.
3. Prove the pane holds one lone idle shell.
4. End that shell, so Herdr removes the emptied workspace through its focus-preserving pane-death path.

The persisted `.focused` pointer is not a live viewer.
When `herdr terminal title clear` reports `no_foreground_client`, cleanup proceeds on that tab because no human is attached, and skips restoration of the tab it destroys.

Herdr currently has no atomic client-aware mutation.
So a fresh target-focus and foreground-client checkpoint runs immediately before each move, signal, or explicit close.
When a live viewer has switched to another tab, that fresh tab becomes the restore target.
A client can still attach or switch focus in the residual checkpoint-to-mutation window.
A durable atomic close is deferred until Herdr exposes that primitive.

The repositioning move-to-last preserves every surviving workspace's relative order.
Removal is confirmed against the exact moved workspace rather than inferred from pane disappearance.
An unconfirmed removal then makes one verified attempt, under the same session lock, to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.

The pane-death signals are pid-exact.
The escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.

A move-plan ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close.
Exact tab restoration remains the backstop whenever a surviving tab must be preserved.
So degraded behavior is never worse than the pre-mitigation sub-second restore.

### Ordinary removal and cleanup locking

Ordinary non-projected task removal:

- Serializes through the same session lock.
- Applies the same focus-safe plan when its close would empty a non-focused workspace.
- Keeps the legitimate plain close when the target is the active tab.
- Refuses an unlocked close if the lock cannot be acquired.

Task cleanup acquires that session lock before the task's isolated copy is returned.
So a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.

Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child.
It then retains each child's durable identity unless that exact pane returns structured not-found after its close.

### When task records are erased

Durable task records are erased only once the exact pane is confirmed gone through its structured presence.
After every close path, only a structured not-found response counts as gone.
A present or unknown result retains every record with a visible, retryable error.
Missing or malformed endpoint identity and missing confirmation machinery are ambiguity, never proof of a gone pane, and refuse record removal the same way.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.
Once the exact pane is confirmed gone, teardown retires the task's own journal when it binds that same pane, or when it is a version 1 attempt whose token-bearing projected workspace is itself confirmed gone, because nothing then remains for the session-start sweep to correlate; a journal bound to any other pane, or a version 1 attempt whose workspace is still present or unreadable, stays for that sweep.

### Restart recovery

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.
That presentation lock lives in a namespace private to the OS account, so another account on the same host running its own Firstmate on Herdr cannot block this account's spawn, recovery, or teardown.
A namespace at this account's name that another account owns, or that is not mode 700, is still refused and is never adopted, chowned, or removed.

A same-identity version 2 binding may replace one exact agent-free restart husk in place.
A husk is a restored same-labeled tab with a missing pane or no registered agent, as [Restart and liveness behavior](#restart-and-liveness-behavior) describes.
The replacement is allowed only when all of these agree:

- The physical home.
- The session.
- The metadata endpoint.
- The unique token match.
- The workspace shape and labels.
- The parent identity and placement.
- The non-target focus snapshot.

The replacement tab and pane are created and verified before the old pane is rechecked and closed.
Then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.

These cases fall back flat without mutating the old projection when duplicate-agent risk is positively absent:

- Version 1 journals.
- Dead or missing panes.
- Duplicate or absent tokens.
- Renamed or detached spaces.
- Cross-home mismatches.
- Inconsistent endpoint bindings.
- Active target tabs.
- Ambiguous identity or focus.

A live or unknown recorded or token-matched endpoint refuses duplicate launch.

### Startup cleanup of restored projections

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal, and it considers only that home.
A primary never recursively sweeps a secondmate home.

Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
A candidate must meet all of these conditions:

- The title must contain exactly one token occurrence across the named-session snapshot.
- The title must equal the title derived from exactly one valid presentation journal in this home's own `state/`.
- A version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
- The task's ordinary metadata must be absent.
- The candidate must have exactly one tab and exactly one pane.

Firstmate then cleans up the candidate in this order:

1. Acquire the existing task-id spawn lock, and then the shared named-session presentation lock.
2. Inside both locks, take one exact snapshot.
3. Require one unambiguous non-target focus and the exact title, token, tab, and pane shape.
4. Positively confirm no registered agent.
5. Read Herdr's process information for the exact named-session pane and apply the process proof below.
6. Immediately revalidate the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus.
7. Call the existing exact-pane focus-preserving close helper.
   It closes only that pane, never a workspace.
8. Retire the matching journal only after the exact pane is positively confirmed gone.

The process proof requires all of these:

- One recognized idle shell as both the shell process and the sole foreground process-group member.
- An operating-system process-table row for that shell.
- No child process.
- A sleeping or idle shell state.

The proof retries strict single samples for a bounded settle window, because an idle interactive shell transiently hosts short-lived prompt helpers.
A genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.

An unconfirmed close retains the journal.
A confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.

Any of these preserves the candidate and lets session startup continue with at most a concise warning:

- A malformed or missing title or token.
- A duplicate token.
- Zero or multiple journal matches.
- A cross-home version 2 binding.
- Current metadata.
- A registered or unknown agent.
- An extra tab or pane.
- An active target.
- A busy lock.
- A changed revalidation.
- An unreadable check.
- Any error.

### Operational compromises

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back flat.
  So a Herdr create failure surfaces as a spawn failure in every Herdr home, rather than only in homes that opted in.
  Every earlier degradation on the fresh projected-create path (no session server, contended presentation lock, absent or ambiguous parent) still warns and continues flat.
- Recovery of an existing presentation journal waits a bounded time, about two minutes, for a live holder of the shared presentation lock to finish, and refuses the spawn only if the lock stays held past that bound, rather than falling back flat.
  Default-on makes that refusal reachable in any Herdr home.
  Pass `fm-spawn.sh --herdr-resume-lock-wait` to opt that recovery into waiting for the lock without a bound instead, so concurrent recoveries always serialize.
  The flag applies to a fresh ship or scout spawn that recovers a journal.
  The multi-task path forwards the flag to each per-pair spawn.
  `fm-spawn.sh --relaunch` and `--secondmate` take no exact-resume presentation-order lock, so the flag has no effect there.
  Dead-owner reclaim still stops the wait when a holder crashed.
  Unbounded blocking on the session lock is never the default.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces.
  Session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

### Presentation tests

| Test | What it covers |
| --- | --- |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | Multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path. |
| `tests/fm-herdr-session-cleanup.test.sh` | Every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary. |
| `tests/fm-herdr-session-cleanup-e2e.test.sh` | The restored-shell cleanup in a guarded non-default named lab. |
| `tests/fm-backend-herdr-focus-flash-e2e.test.sh` | Reproduces the raw explicit-close focus steal on the installed release, and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval. |
| `tests/fm-backend-herdr-stale-active-tab-e2e.test.sh` | Proves a persisted-focused tab still closes when no foreground client is attached. |
| `tests/fm-herdr-attached-viewer-live-e2e.test.sh` | Proves the other half against a real attached viewer, which `bin/fm-herdr-lab.sh viewer start` supplies over a pty sized before the fork. |

[`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence for the focus-flash test.
[`verification/runtime-backends.md`](verification/runtime-backends.md#attached-foreground-viewer) owns the active versioned evidence and the re-run trigger for the attached-viewer test.

## Project groups

Project groups are an opt-in display layer that shows each task's project group and status in Herdr's sidebar and sorts Herdr's agents list by group and then by status.
They are off by default, and without the setting nothing in this page's other sections changes.
They are display-only: no tag or view is task, endpoint, ownership, or cleanup authority.

### Turning project groups on

The local gitignored `config/herdr-project-groups` file controls them.
It is inherited into secondmate homes, because the agents view is one per Herdr server and every home's tasks share it.

| File content | Result |
| --- | --- |
| Absent | Off. No producer runs and no Herdr call is made. |
| `off` | Off, the same as absent. |
| `on`, or empty | On, with one group per project, named after the task's project directory. |
| Rule lines | On, with the groups and group order the rules define. |

Blank lines and lines starting with `#` are ignored.

### Group rules

Each rule line is a group name followed by selectors, separated by whitespace.
The order in which a group name first appears is that group's display order, and a group may span several lines.
Group names use letters, digits, `.`, `_`, `+`, and `-`, at most 32 characters.

| Selector | Matches |
| --- | --- |
| `task:<prefix>` | A task id equal to `<prefix>` or starting with `<prefix>-`. |
| `repo:<name>` | A task whose project directory is named `<name>`. |
| `*` | Every task. |

Task-id selectors win over repository selectors, which win over `*`, across all lines; within one selector kind the first matching line wins.
A task that no rule matches is grouped by its project directory and listed after every rule group.
An invalid group name or an unknown selector is ignored with a warning.

Example, grouping by area of work and keeping a catch-all last:

```text
# config/herdr-project-groups
Web       task:web task:shop repo:storefront
Backend   task:api repo:api-server
Ops       task:deploy task:infra
Other     *
```

### Tags and status order

For each ship and scout task recorded in the home with Herdr endpoint metadata, Firstmate reports display-only metadata tokens under the source `firstmate`:

| Token | On | Value |
| --- | --- | --- |
| `fm_group` | pane and projected workspace | The group name. |
| `fm_state` | pane and projected workspace | The display status. |
| `fm_task` | pane | The task id. |
| `fm_sort` | pane | `<group order>.<group>.<status rank>.<task>`, at most 80 characters. |
| `fm_group_order` | projected workspace | `<group order>.<group>`, the key that [placement](#placement-inside-the-group) compares. |

Workspace tokens go only to the task's own projected workspace: an exact version 2 [presentation journal](#presentation-journal) binding the task's recorded session, workspace, and pane, whose live workspace holds that single pane.
A flat-layout task tab shares its workspace with other tasks, so it gets pane tokens only.

The display status comes from the task's status log through the shared classifier that `bin/fm-classify-lib.sh` owns, in this rank order:

| Rank | `fm_state` | Status log |
| --- | --- | --- |
| 1 | `needs-captain` | An open decision, or a captain-held transfer. |
| 2 | `problem` | `blocked` or `failed`. |
| 3 | `running` | Anything else, including `working`, `paused`, and no status yet. |
| 4 | `done` | `done`. |

It is the worker's latest declaration, not the reconciled current state that `bin/fm-crew-state.sh` owns, and it can lag one watcher poll behind the log.
Herdr's own agent status dot stays live beside it.

The watcher reconciles every task once per poll cycle, and a spawn tags its new task at once.
A reconcile reads each session's workspace and pane lists once and reports only tokens whose live value differs.
Whenever it reports a pane token, it also sets the agents view: `agent.view.set` with source `firstmate`, label `projects`, and sort by the `fm_sort` token, then workspace order.
Herdr keeps neither tokens nor the agents view across a server restart, so the next reconcile after a restart reports them again.
Agents without an `fm_sort` token, such as Firstmate itself or another tool's agents, sort after the tagged ones.
Herdr exposes no CLI for the agents view, so `bin/backends/herdr-agent-view.py` sends only those two whitelisted requests over the named session socket.

Tags and the agents view need Herdr protocol 22, verified with Herdr 0.9.5; the wire schema comes from Herdr 0.9.3, which speaks the same protocol.
An older client warns once per protocol and the feature stays inactive.

`bin/fm-herdr-groups.sh` owns the commands, including `plan` to preview groups and statuses without touching Herdr and `clear` to remove this home's tags and the agents view after turning the feature off.

### Sidebar rows

Herdr shows custom tokens only where its own configuration names them.
Firstmate never edits Herdr's configuration on its own.
`bin/fm-herdr-groups.sh sidebar-config` prints these suggested rows, and `sidebar-config --apply <path>` appends them to that Herdr configuration file after copying it to `<path>.bak-<epoch>`, refusing when the file already defines sidebar rows:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  [{ token = "$fm_group", bold = true }, "$fm_state"],
]

[ui.sidebar.agents]
rows = [
  ["state_icon", { token = "$fm_group", bold = true }, "$fm_state", "$fm_task"],
]
```

Run `herdr server reload-config` afterwards to apply them.
Colors can be added with Herdr's inline token styles.

### Placement inside the group

With project groups on, a new projected task is placed inside its owning parent's child block right after the last child whose `fm_group_order` token sorts at or before its own, instead of at the block end.
A child without that token counts as sorting before it, so untagged children never move behind a new task.
Everything else is [Ordering](#ordering) unchanged: one verified move of the new workspace only, never an existing child, a parent, or a foreign workspace, and every ambiguity leaves the new task where Herdr created it.
A task whose group changes later keeps its position until it ends.

### Verification status

The tags, the agents view, and the placement are covered by offline tests against a scripted Herdr CLI and socket helper (`tests/fm-herdr-groups.test.sh` and the ordering cases in `tests/fm-backend-herdr.test.sh`).
They were also exercised against a real Herdr 0.9.5 server (protocol 22) in a guarded lab session: after one watcher poll `herdr pane list` showed the `fm_*` tokens on each task pane, the agents list header read `projects` with tasks ordered by group and then status, a newly spawned projected task landed after the other tasks of its group with only that workspace moving and no focus change, and `fm-herdr-groups.sh clear` removed the tokens and the view.
To repeat the check on a live session, turn the feature on, wait one watcher poll, and confirm the same four results.

## Status: supported

Herdr is supported, with its own required CI lane, and is Starship's default for a fresh home on a Mac and inside WSL 2 on Windows.
Select it by putting `herdr` in a local `config/backend` file, by exporting `FM_BACKEND=herdr`, or by telling the first mate in chat to use herdr.
It can also be selected by runtime auto-detection when firstmate itself is running inside herdr and no explicit backend setting exists.
Absent those three explicit settings, firstmate falls through to runtime auto-detection.
When nothing is explicitly configured, `bin/fm-backend.sh`'s `fm_backend_detect` checks the runtime firstmate itself is executing inside: `$TMUX` (set inside every tmux pane, including a tmux pane nested inside a herdr pane) selects tmux and wins when present, `HERDR_ENV=1` (injected into every process herdr manages a pane for) selects herdr when `$TMUX` is absent, and cmux runtime signals select cmux only after those multiplexer markers are absent.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for cmux's primary `CMUX_WORKSPACE_ID` marker and macOS-only fallback signals.
An auto-detected herdr spawn stays silent, like an auto-detected tmux one; set `config/backend` or pass `--backend tmux` to opt out.
Only when none of that resolves anything does firstmate fall back to the hard default, tmux.
Absent `backend=` in a task's meta always means `tmux`; a herdr task carries an explicit `backend=herdr` line, while the experimental zellij, orca, cmux, and paseo adapters carry their own backend values.
A herdr spawn refuses loudly if `herdr` or `jq` is missing, or if the installed herdr's protocol is older than the verified minimum (`fm_backend_herdr_version_check`).
The managed human-presentation flow is additionally capability-gated (`fm_backend_herdr_presentation_capable`, protocol 16); below that it falls back to the prior label-based spawn flow instead of refusing - see "Presentation capability gate" below.

## Worktree provider stays treehouse

Herdr is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux.
Herdr's own `worktree.*` operations (branch-based, pooling/lease-free) are never used by this adapter.

## Home-workspace fallback and identity tokens

This section details the fallback the ordinary launcher-bound placement above falls through to, and the identity tokens that make a home workspace unambiguous.

With no Herdr ancestry to inherit, managed ship and scout tasks use one Herdr workspace per `(physical FM_HOME, physical project)` and one tab per task.
The adapter binds a newly created workspace once with hidden `fm_owner` and `fm_project` tokens.
A launcher workspace a spawn adopts gains only the hidden `fm_owner` token, so its workers stay visible to recovery without it ever becoming a project workspace; one that another home already owns, by token or by legacy home label, is left untouched.
Each token is a versioned Git object hash of the complete physical path, keeping the immutable identity below Herdr's metadata value limit without storing a truncatable raw path.
Workspace lookup exact-matches both tokens and never identifies or adopts managed work by its visible label.
The human project label is mutable presentation and may include prioritized aggregate state without weakening ownership.
A managed workspace holding tasks from several projects is labeled neutrally over all of them rather than after any one project; `bin/fm-visible-status.sh`'s header owns the exact label.

This container shape is what [`docs/herdr-layout-preview.md`](herdr-layout-preview.md) proposes replacing with upstream's one-workspace-per-worker unit.
That preview is unapproved and changes nothing here until the captain accepts it.

The project display name comes from `bin/fm-project-display-name.sh`, the single resolver owner.
It has explicit brand and acronym casing overrides and labels its generic title-cased result as a synthesized fallback rather than claiming a repository basename is authoritative human naming.
`sample-product` resolves to `Sample Product`, and `api-platform` resolves to `API Platform` via its explicit override.

A task's visible tab title is separate from its durable identity.
New panes carry hidden `fm_task_id`, while the recorded workspace, tab, and pane ids remain the operational targets.
The tab reads `WORKER · <human outcome> · <authoritative state>`.
`bin/fm-visible-title.sh` is the single owner of that title format; both the spawn path and the `bin/fm-visible-status.sh` tab rename build the title through it, so the title a worker is spawned with and the title a later refresh renames it to cannot drift apart.
`bin/fm-task-outcome.sh` owns outcome precedence: explicit `fm-spawn.sh --outcome`, structured backlog title, then a safe humanized task-id fallback.
The spawn path calls the outcome resolver, the title owner, and the project display-name resolver only through guarded best-effort hooks: with those fork scripts absent a herdr spawn still succeeds and degrades to upstream's behavior, the opaque window name as the tab title, the plain directory basename as the project label, and an empty `outcome=` value in the task's meta (pinned by `tests/fm-spawn-herdr-presentation.test.sh`).
`bin/fm-visible-status.sh` reads runtime/model from task metadata (and, for cursor, from the live pane footer when present), branch or detached state from the recorded isolated copy, and lifecycle state from `bin/fm-crew-state.sh`.
It never derives lifecycle state from the append-only status tail or Herdr's native activity alone.

### Legacy home labels

The former workspace labels remain the compatibility vocabulary: `firstmate` for a primary home and `2ndmate-<id>` for a marked secondmate home.
A secondmate primary pane still uses that home workspace because it has no physical project of its own.
Its tab keeps the legacy `fm-<id>` title too: `bin/fm-visible-status.sh` skips every `kind=secondmate` task, so the WORKER convention never applies to a secondmate primary.
New project workers spawned from either a primary or secondmate home use the token-owned project workspace contract instead.

Recovery scans token-owned workspaces whose `fm_owner` equals the active physical home, including adopted launcher workspaces, and reads hidden `fm_task_id` from each pane.
It also scans that home's un-tokened legacy workspace for visible `fm-<id>` tabs.
It never claims a tokened workspace owned by another home, even when the visible project label collides.

### Focus behavior: never steals the captain's attention

Verified empirically against the real binary, in an isolated session:

- `herdr workspace create` and `herdr tab create` do NOT focus by default once at least one workspace already exists in the session - matching (and no worse than) the pre-P3 adapter's already-flagless calls.
- The ONE exception: the very first workspace ever created in a brand-new, empty herdr session focuses regardless, because herdr always needs something focused to attach a client to - there is nothing to "not steal focus from" at that point.
- `--focus` reliably DOES focus (both the workspace and, for a tab, the pane within it) - confirming the flag has real effect and isn't a no-op, so its absence is meaningful.

Both `fm_backend_herdr_workspace_ensure`'s workspace create and `fm_backend_herdr_create_task`'s tab create now pass `--no-focus` unconditionally.
This is defense in depth rather than a behavior change in the already-safe steady state: it guards workspace and tab creation after the session already has a focused workspace, but it cannot prevent herdr's unavoidable first-workspace focus in a brand-new empty session.
Once a workspace exists, spawning - primary or secondmate, workspace or tab - should not switch whatever space the captain is actively watching.

### Label collisions do not identify managed work

Herdr enforces no workspace or tab label uniqueness.
Managed workspace adoption therefore ignores labels and exact-matches hidden physical owner/project tokens.
Managed task duplication and recovery read hidden `fm_task_id`; visible `fm-<id>` matching remains only as the legacy fallback.
Two projects or homes may safely share the same human display name without being adopted as each other.

### No forced migration

Existing live tasks keep their recorded pane targets and remain operational in legacy `firstmate` or `2ndmate-*` workspaces.
A bounded presentation refresh may rename a legacy task's recorded tab and update that recorded pane's metadata, but it never renames the shared legacy workspace to one task's project and never moves panes implicitly.
When teardown retires a refreshed legacy task, `fm-visible-status.sh --clear` restores `fm-<id>` so the legacy recovery fallback remains available.
That clear runs only once teardown has passed every gate that can still retain a live task, so a teardown that refuses and exits leaves the pane labeled exactly as it found it rather than stripping a still-running worker's label.
Other backends keep their existing selector and title contracts.

### Presentation capability gate

The managed presentation surfaces - `workspace report-metadata`, `pane report-metadata --token`, hidden `.tokens` in workspace/pane list output, and `workspace`/`tab rename` - are verified at protocol 16 (herdr 0.7.4).
`FM_BACKEND_HERDR_MIN_PROTOCOL` stays 14: the adapter's core spawn/capture/send primitives still work there, so the presentation dependency is capability-gated instead of raising the floor, mirroring the protocol-16 events gate.
Below `FM_BACKEND_HERDR_MIN_IDENTITY_PROTOCOL` (16), `fm_backend_herdr_presentation_capable` fails closed: a non-secondmate spawn uses the prior label-based flow (an `fm-<id>` tab in the legacy per-home workspace, no identity tokens, and no `herdr_workspace_managed=1` meta), and `bin/fm-visible-status.sh` exits without touching any tab or workspace, so legacy `fm-<id>` recovery labels survive.
`FM_BACKEND_HERDR_PRESENTATION_FORCE` (1 = capable, 0 = incapable) overrides the probe for tests, exactly like `FM_BACKEND_HERDR_EVENTS_FORCE`.
Default-on projection has its own higher floor, `FM_BACKEND_HERDR_MIN_PRESENTATION_PROTOCOL` (19, herdr 0.8.0): a home that configured nothing is projected only at or above it, while an explicit "on" is still honored between the identity floor and that release floor.

### Bounded presentation refresh and primary boundary

`bin/fm-visible-status.sh` refreshes at bounded authoritative-state points, never on a timer:

- `bin/fm-spawn.sh` projects the single task after its record is published, and after both the fresh-spawn and the relaunch publish paths, so a relaunch projects its own replacement record rather than the record it replaced.
- `bin/fm-session-start.sh` refreshes `--all --republish` during session recovery, but only for the session owner: a lock-refused read-only session must not mutate presentation.
  Recovery republishes rather than trusting the cached labels below, because whatever restarted the session may also have restarted the surface showing them.
- `bin/fm-push-transition-lib.sh` refreshes the single task on a push transition, before that transition is absorbed or escalated, so an absorbed transition still updates the label.
- `bin/fm-watch.sh` starts `--all` on each coalesced signal batch, where status writes and turn-end markers have already been gathered, and never waits for it.
  The poll loop owns the liveness beacon the whole supervision chain reads, and a large fleet against a slow Herdr made an inline refresh the one thing on that path that could outlast the guard's grace, so the pass is detached exactly like the published-summary refresh beside it.
  A pass still running when the next batch arrives keeps running instead of being raced.
- `bin/fm-teardown.sh` clears the retired task with `--clear <id>` once it has committed to retiring it, then refreshes `--all` after the record is removed, because the removal changes every remaining task's project aggregate.

An `--all` pass is bounded and single-flight, so a large fleet or a slow Herdr costs a stale label rather than a stalled caller: every backend round trip runs under a per-call deadline, each task under a per-task deadline, and the pass under a pass deadline, after which the tasks it did not reach keep their previous label until the next pass.
A task whose computed label matches the one last published for it costs only the primary-role clear described below and the `fm_state` token it restores, and each managed workspace is renamed once per pass rather than once per task or project in it; the authoritative state of a task is read once per pass, so a pass costs O(tasks) reads instead of O(tasks x tasks).
The published labels live in `state/<id>.visible-label` and `state/.visible-workspace-<id>`, which are caches - deleting one costs a redundant republish and nothing else - and `--republish` ignores them.
Only one pass per home runs at a time (`state/.visible-status-all.lock`), and a pass started from inside a running one is a no-op.
`bin/fm-visible-status.sh`'s header owns the exact deadlines and their environment overrides.

Every Herdr presentation call is best-effort because recorded ids, landed-work checks, and endpoint cleanup remain authoritative.
The helper updates only recorded, non-secondmate task panes and never emits `FIRSTMATE` or `LAB`.
Before it publishes a worker label, it clears any role the primary launcher left on that pane, because Herdr keeps a source's fields until that source clears them.
That clear runs on every pass, even for a task whose label is unchanged, because the label cache cannot see a primary marker that lands after the label was published.
Herdr tokens are keyed by name rather than source, so that clear also drops the worker's own `fm_state`; an unchanged task republishes just that token.
`bin/fm-primary.sh` is the structural owner of primary projection: only an invocation through the primary launcher may emit `FIRSTMATE`, and its guarded non-default lab mode emits `LAB · PRIMARY` instead.
An ordinary worker merely carrying `HERDR_ENV=1` can therefore never become the captain-facing primary.

## Workspace lifecycle: one persistent workspace per project pair

A token-owned project workspace is reused by subsequent tasks from the same physical home and physical project.
Teardown closes only the task's recorded pane/tab, never a workspace by label.
Closing the final tab may let Herdr remove the now-empty workspace as its normal side effect.

Reserved-keyword guard: never name a `jq --arg`/`--argjson` after a `jq` keyword (`label`, `and`, `or`, `not`, `if`, `then`, `else`, `end`, `reduce`, `foreach`, `import`, `def`, `as`, `__loc__`).
jq <= 1.6 rejects a keyword-named `$`-variable as a compile error, and this adapter pipes `jq`'s stderr to `/dev/null`, so on jq <= 1.6 the error silently becomes an empty result rather than a visible failure.
Use a distinct name such as `$want` instead; `tests/fm-backend-herdr.test.sh` greps `bin/` for this pattern so a new violation fails loudly rather than silently.

### Default-tab prune

`herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`) that firstmate never uses.
`fm_backend_herdr_create_task` prunes it (best-effort, via `fm_backend_herdr_workspace_prune_seeded_default_tab`) right after creating the first real task tab in a freshly created workspace, never earlier: closing a workspace's LAST tab deletes the whole workspace on real herdr, and immediately after creation the default tab is the only one present.

**The prune target is identified structurally (created-vs-adopted), never by label pattern.**
`fm_backend_herdr_workspace_ensure` captures the seeded default tab's `tab_id` straight from its OWN `workspace create` response (`.result.tab.tab_id`, verified empirically to be present on the same response as `.result.workspace.workspace_id` - no follow-up `tab list` call is needed) ONLY when that call itself just created the workspace.
`fm_backend_herdr_container_ensure` threads that id through to its caller as a second field: it echoes `"<session>:<workspace_id>\t<seeded_default_tab_id>"`, the second field empty whenever the workspace was adopted through its managed identity tokens or legacy label rather than created fresh.
`fm_backend_herdr_create_task` accepts that value as an explicit 4th argument and is the ONLY place allowed to act on it; it never re-derives "prunable" from a tab's label or the workspace's tab count.
An adopted workspace's caller always passes an empty 4th argument, so create_task never even looks for a prune candidate in that case - it is structurally impossible for an adopted workspace's tabs to be pruned, regardless of how they are labeled.

Defense in depth on top of that gate (not the primary safety mechanism): before closing the seeded tab, `fm_backend_herdr_workspace_prune_seeded_default_tab` re-verifies the tab is still present, re-checks it is still labeled `1`, and refuses if its pane's `agent get` reports `agent_status: working` (herdr's own native agent-state detection) - belt-and-suspenders against a live agent having landed there through some other path.

#### Incident: the 2026-07-02 self-kill

The previous implementation derived "prunable" at `create_task` time from a pure label heuristic run against whatever workspace `workspace_find` had just resolved: exactly one tab, labeled `1`.
Herdr enforces no label uniqueness (see "Label collisions" above) and derives an unlabeled workspace's DISPLAYED label from its pane cwd's basename.
A captain who launches herdr directly inside a directory named `firstmate` therefore gets a workspace whose label is `firstmate` - byte-identical, by coincidence, to the primary firstmate home's own derived label - with a single auto-created tab, also labeled `1`.
`fm_backend_herdr_workspace_find` adopted that pre-existing, captain-owned, LIVE workspace by the label match (a label match can never distinguish an explicitly `--label`-created workspace from one whose label only coincidentally matches); the old heuristic matched too, since it looked only at the adopted workspace's own tab shape, not at whether THIS spawn had actually created it.
The very next crewmate spawn's `create_task` call closed the captain's own live pane roughly 27ms after creating its own task tab, killing the primary firstmate agent and its watcher mid-turn.
Log evidence: `~/.config/herdr/herdr-server.log` showed `cli:tab:create` (the new task tab) immediately followed by `cli:pane:close` on the captain's pane (pid 36335, launched ~8 minutes earlier); `~/.config/herdr/session.json` showed the adopted workspace's `custom_name: null` with `identity_cwd` pointing at the firstmate repo.

The fix is structural, not another heuristic, and is unit- and E2E-tested: see `tests/fm-backend-herdr.test.sh`'s `test_adopted_workspace_never_prunes_default_tab` and `test_label_collision_startup_workspace_leaves_live_tab_alone`, and `tests/fm-backend-herdr-prune-safety-e2e.test.sh`'s isolated real-herdr reproduction of the exact incident shape.

Because closing a workspace's last tab deletes it, a project workspace does not outlive a fully idle project fleet.
The next spawn recreates it with the same physical owner/project identity tokens.
Managed workspace lookup never adopts, reuses, or tears down a workspace by its visible label.

## Target string and meta fields

A herdr task's `window=` meta field holds `<herdr-session>:<pane-id>`, for example `default:w1:p2`.
The pane id itself contains a colon, so the adapter splits on the FIRST colon only, never on every colon.
This mirrors tmux's `session:window` target shape closely enough that `fm_backend_resolve_selector` (in `bin/fm-backend.sh`) needed no backend-specific logic at all - it already just returns a task's recorded `window=` value verbatim.
Task-selector resolution is the shared contract owned by [`docs/configuration.md`](configuration.md) ("Runtime backend").
For a bare unknown non-`fm-` name, Herdr retains the legacy tmux live-window fallback.

Herdr tasks additionally record:

- `herdr_session=` - the named herdr session this task's server lives in.
- `herdr_workspace_id=` - the stable workspace id recorded at spawn.
- `herdr_tab_id=` - the stable task tab id.
- `herdr_pane_id=` - the stable task pane id and fast-path operational target.
- `herdr_workspace_managed=1` - marks a new token-owned project workspace.
- `herdr_project_key=` - the physical project identity used with the physical home token.
- `herdr_project_name=` - the resolved human display name.
- `outcome=` - the resolved concise human outcome.

## Verified CLI facts

| Operation | Verified herdr call | What was verified |
|---|---|---|
| Version/protocol gate | `herdr status --json` -> `.client.protocol` | Session-independent; `.server.*` fields ARE session-dependent. |
| Headless server start | `HERDR_SESSION=<name> herdr server --session <name>` (detached, see [Server ownership](#server-ownership)) | A bare socket call does NOT auto-start the server; a creating path starts-then-polls before any workspace/tab/pane call, and a read never starts one. This fact is for start only, not cleanup, and the explicit `--session` flag is intentional because `HERDR_SESSION` alone is not safe session targeting. |
| Duplicate task check | `herdr pane list --workspace <id>`, match hidden `.tokens.fm_task_id`; visible `fm-<id>` tab fallback for legacy rows | Herdr does not enforce label uniqueness, so mutable human titles are never task identity. |
| Send literal (unsubmitted) | `herdr pane send-text <pane> <text>` | Does NOT auto-submit, contrary to the original design addendum's guess. Verified directly: a unique marker sent this way sits unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send + submit atomically | `herdr pane run <pane> <command>` | Runs and submits a command in one call; used for the spawn-time pane-run commands (`treehouse get`, the `GOTMPDIR` export, and the `FM_HERDR_PROJECT_*` pin) exactly where tmux used one `send-keys ... Enter` call. |
| Send key | `herdr pane send-keys <pane> <key>` | Verified names: `enter`, `escape` (alias `esc`), `ctrl+c` (aliases `C-c`, `c-c`). `ctrl+c` verified to interrupt a running foreground process immediately. |
| Submit confirmation (idle baseline) | `herdr agent get <pane>` -> `.result.agent.agent_status` after Enter | `fm_backend_herdr_send_text_submit` records the pre-Enter status and, when it is idle/done, confirms delivery by polling for `working`/`blocked` across the Enter attempt's confirmation budget. Composer-state reads remain the affirmative-empty pre-injection guard and the conservative fallback for preexisting submit-active or unreadable baselines; see "Native agent-state submit confirmation". |
| Bounded capture | `herdr pane read <pane> --source recent --lines N` | See "Verified bug" below - N is never passed through directly. |
| ANSI capture | `herdr pane read <pane> --source recent --lines N --format ansi` | Herdr 0.7.3 preserves composer de-emphasis styling, letting the shared `fm_composer_strip_ghost` extractor treat dim/faint and dark-TRUECOLOR ghost/placeholder text as empty while retaining real typed input. The same small-`--lines` workaround applies. |
| Busy state | `herdr agent get <pane>` -> `.result.agent.agent_status` | Verified live against an interactive `claude` session: reports `working` while generating, `done` once idle. Mapped: `working` -> busy; `idle`/`done` -> idle; `blocked` -> idle (surfaced like a stale pane, not suppressed as busy - a blocked agent is stuck waiting on the human, not grinding); anything else -> unknown (the cue for the shared tail-regex fallback). |
| Kill | `herdr pane close <pane>` | Closing a tab's only (root) pane also closes the tab - no separate tab-close call needed for this adapter's one-pane-per-tab shape. Best-effort: closing an already-closed pane exits non-zero, matching tmux's `kill-window \|\| true` contract. Teardown itself only ever closes the task's own pane/tab, never the workspace - but closing a workspace's LAST tab (verified real-herdr behavior) deletes the workspace as a side effect, so a home's own workspace persists only while at least one task tab remains; see "Workspace lifecycle" above. |
| Default-tab prune (create_task, first task in a fresh workspace only) | `herdr workspace create`'s own response (`.result.tab.tab_id`) identifies the seeded tab; `herdr tab list` + `herdr agent get <pane>` re-verify it; `herdr pane close <pane>` closes exactly that tab id | `herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`, id captured straight from the create response) firstmate never uses. `fm_backend_herdr_create_task` closes EXACTLY that captured tab id right after creating the first real task tab in a freshly created workspace - never right after `workspace create` itself (see Kill row), and never re-derived from a tab's label or the workspace's tab count at create_task time (see "Default-tab prune" above for the created-vs-adopted safety gate and the 2026-07-02 incident it fixes). Best-effort; an ADOPTED workspace (not freshly created by this same call) is never a prune candidate at all. |
| Recovery / list-live | Workspace `fm_owner` token plus pane `fm_task_id`; legacy home label plus visible `fm-<id>` fallback | New recovery refuses another physical home's project workspace even when labels collide, while legacy rows remain readable. |
| Workspace create / tab create (focus) | `herdr workspace create --no-focus`, `herdr tab create --no-focus` | Verified: neither focuses by default once a workspace already exists in the session, matching pre-P3 (flagless) behavior; `--no-focus` is passed anyway for defense in depth, since the very first workspace ever created in a brand-new session focuses regardless of the flag. `--focus` was separately verified to reliably focus, confirming the flag has real effect. |
| Session targeting for DESTRUCTIVE calls | `herdr session stop <name> --session <name> --json`, then `herdr session delete <name> --session <name> --json`; never `herdr server stop` | Owned by `bin/fm-herdr-lab.sh` (which `tests/herdr-test-safety.sh` sources), re-querying `herdr session list --json` before every destructive call. See "Session targeting" below - `HERDR_SESSION` alone is not reliably honored once another herdr server is already running on the machine. |

## Incident (2026-07-13): the ASCII request separator erased the secondmate marker

A routed request reached a Pi/Herdr secondmate without the visible `[fm-from-firstmate]` label, so the secondmate correctly treated it as direct captain conversation and returned nothing to the parent status path.
The initial suspicion was selector classification, but a real isolated reproduction disproved that: exact-id lookup found the right metadata, read `kind=secondmate`, selected the recorded Herdr endpoint, and still delivered an unmarked Pi prompt.

The reproduction used Herdr 0.7.3 (protocol 16), Pi 0.80.6, a task-local sender home, a real `fm-spawn.sh --secondmate --harness pi --backend herdr` endpoint, and a generated non-`default` session from `bin/fm-herdr-lab.sh`.
Every adapter call was routed through the lab helper, and teardown verified the default-session fleet-state tripwire.
The end-user command was run with normal `FM_SEND_SETTLE`:

```sh
FM_HOME=<isolated-sender-home> bin/fm-send.sh marker-pi-sm \
  'FM_MARKER_E2E_CURRENT exact-id request'
```

Immediately before submission, the authoritative selector helpers reported:

```text
resolved-meta=<isolated-sender-home>/state/marker-pi-sm.meta
kind=secondmate
target=<generated-lab-session>:w1:p2
backend=herdr
expected-label=fm-marker-pi-sm
```

At the time, Pi's separator-only idle composer was outside the Herdr structural classifier's recognized bordered/bare shapes, so composer state was conservatively `unknown` both before and after the send.
The endpoint's native agent state was idle before submission, and the normal idle-to-working confirmation made `fm-send.sh` return successfully.
A task-local Pi `before_agent_start` hook then captured the exact received prompt and UTF-8 bytes:

```json
{"prompt":"FM_MARKER_E2E_CURRENT exact-id request","hex":"464d5f4d41524b45525f4532455f43555252454e542065786163742d69642072657175657374"}
```

The old marker should instead have started with label bytes `5b666d2d66726f6d2d66697273746d6174655d`, followed by ASCII `1f` and then those request bytes.
The Pi transcript independently rendered only `FM_MARKER_E2E_CURRENT exact-id request`, and the agent answered it conversationally as captain input.

The failure was in marker transport, not backend selection or metadata classification.
`fm-send.sh` correctly passed `[fm-from-firstmate]`, ASCII unit separator `0x1f`, and the request to `herdr pane send-text`.
Herdr's terminal input path treated the C0 byte as a control action rather than text, removing the preceding label before Pi submitted the remaining request.
A tmux-stub unit test could not expose this because it logged the string argument without driving a real terminal editor.

The single marker owner, `bin/fm-marker-lib.sh`, now uses U+2063 INVISIBLE SEPARATOR (UTF-8 `e2 81 a3`) after the visible label.
U+2063 has no normal keyboard keystroke but travels through terminal input as text rather than a C0 control byte.
The same owner now provides the idempotent marker transformation, so an already-marked request is not prefixed twice.
No Herdr-specific injection or classification branch was added.

The opt-in regression command is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

The real post-fix Pi capture reported exactly one marker followed by the request:

```text
evidence: exact-id received-hex=5b666d2d66726f6d2d66697273746d6174655de281a3464d5f4d41524b45525f48455244525f4532452065786163742d69642072657175657374
```

The same run injected direct terminal text without `fm-send.sh` and captured it byte-exact with no marker:

```text
evidence: direct-input received-hex=464d5f4d41524b45525f48455244525f444952454354206361707461696e20696e707574
```

Unit coverage in `tests/fm-send-secondmate-marker.test.sh` pins exact-id and stable-label secondmates, exact-id and stable-label ordinary crewmates, explicit endpoints with and without local metadata, key-only sends, direct unmarked input, exact U+2063 bytes, and idempotence.
Strict unresolved-selector behavior remains covered by `tests/fm-send-strict.test.sh`.

## Incident (2026-07-14): Pi-on-Herdr away escalation stayed non-injectable for 4555 seconds

A guarded reproduction used Herdr 0.7.3, Pi 0.80.7, a generated non-`default` session from `bin/fm-herdr-lab.sh`, an isolated Firstmate home, a real Pi primary pane, the public `bin/fm-afk-launch.sh start` entrypoint, a live synthetic child pane, the real daemon and wake queue, `bin/fm-afk-launch.sh stop`, `bin/fm-wake-drain.sh`, and `bin/fm-bearings-snapshot.sh`.
Every production-adapter and explicit Herdr command was routed through the lab helper, and teardown verified that the running `default` session was unchanged.
The synthetic child appended `blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token` while away mode was active.
The daemon classified the status as captain-relevant, retained it in `state/.subsuper-escalations`, and the watcher retained the matching `signal` in `state/.wake-queue`.
The oldest-escalation sidecar was backdated by 4555 seconds to reproduce the observed interval without waiting in wall-clock time.
The alarm then recorded `fm away-mode inject WEDGED: 4556s undelivered`, the active notifier fired exactly once, the buffer remained intact, and Pi captured zero injected prompts.

The causal probes against the exact recorded supervisor target were:

```text
target_exists=yes
busy_state=idle
composer_state=unknown
```

The plain Pi capture showed a blank content row between two horizontal separators:

```text
─────────────────────────────────────────────────────

─────────────────────────────────────────────────────
<project and model footer>
```

The ANSI capture showed the same two blue separator rows with a reverse-video cursor in the blank content row.
Real pending text occupied that same middle row and native `agent get` remained idle, which proved native agent state alone could not distinguish an empty Pi composer from an unsubmitted Pi draft.
The exact target was correct, the agent was not busy, and submit verification was never reached because the affirmative-empty pre-injection guard rejected the unrecognized structure.
This rules out target resolution, busy detection, submit acknowledgement, and shutdown ordering as the 4555-second cause.
The root cause was solely that the Herdr structural classifier recognized bordered composers and bare `❯` or `›` prompt rows, while Pi renders a separator-only composer.

`fm_backend_herdr_composer_state` remains the single backend owner of structural row recognition.
It now accepts content between the bottom-most complete pair of Pi separator rows only when Herdr's native identity says the target agent is exactly `pi` and its status is `idle`, `done`, or `blocked`.
A working Pi, a pending middle row, a missing or non-Pi identity, an incomplete pair, or an over-tall candidate remains `pending` or `unknown`, so dead shells and ambiguous panes are still non-injectable.
The extracted content still routes through the shared `bin/fm-composer-lib.sh` decision owner.

Making the Pi composer injectable exposed the already-proven terminal-control hazard from the 2026-07-13 incident: Herdr consumed a leading ASCII `0x1f`, so Pi received `Supervisor escalate...` without the away marker.
At the time of this reproduction, `FM_INJECT_MARK` used a bare leading U+2063 INVISIBLE SEPARATOR, while the from-firstmate marker remained a visible label followed by U+2063, so their full prefixes stayed distinct.
`bin/fm-operational-input.sh` owns current operational-input construction, while the `/afk` skill owns the daemon's stay-away handling and legacy bare-marker compatibility.
U+2063 has no normal keyboard keystroke and the real post-fix Pi prompt capture retained its `e281a3` prefix byte-exact.

The return half of the same reproduction showed that separate `stop` and `wake-drain` calls left policy ownership to the operator and allowed an ordinary Bearings request to begin while the live blocker remained open.
Bearings' authoritative structured projection was already correct:

```json
{"in_flight":[{"id":"synthetic-child","state":"blocked"}],"decisions_open":[{"id":"synthetic-child","verb":"blocked"}],"gates":[]}
```

The live blocker was never structured as queued work, so no return policy was duplicated into Bearings wording or its projection.
`bin/fm-afk-return.sh` now owns deterministic stop, drain, durable evidence, and the fail-closed return gate.
It refuses ordinary work until each live open `blocked:` key is resolved after immediate remediation or explicitly reclassified with a durable reason.
The `/afk` skill owns the situation-specific procedure, and the always-loaded `AGENTS.md` away stub contains only the safety-critical trigger to run that owner before processing the return message.
`bin/fm-bearings-snapshot.sh` consults the owner's read-only guard and contains no copy of the policy.

The guarded post-fix command was:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh tests/fm-afk-pi-herdr-return-e2e.test.sh
```

The real result was:

```text
ok - real Pi/Herdr pending composer refuses injection without forced submit and raises one observable fallback
ok - real idle Pi/Herdr accepts one marked escalation promptly, verifies submit, clears wedge state, and emits no duplicate alert
ok - real unmarked Pi return opens catch-up and blocks Bearings before the unresolved blocker can be deferred
ok - resolved return catch-up allows Bearings and a clean idempotent away re-entry
evidence: herdr=herdr 0.7.3 pi=0.80.7 inject-hex-prefix=e281a3 notifier-count=1
```

Unit coverage in `tests/fm-backend-herdr.test.sh` pins the exact idle and pending Pi captures plus working, non-Pi, unreadable, and over-tall refusal.
`tests/fm-afk-return.test.sh` pins durable catch-up evidence, blocker ownership, Bearings precedence, explicit reclassification, re-entry, and tmux/Herdr parity.
`tests/fm-bearings-snapshot.test.sh` pins that live blocked work remains live structured state and never becomes a queued gate.
The existing tmux injection E2E remains the transport-parity proof for type-once, verified-submit behavior.
The wedge alarm remains defense in depth and is not the primary delivery path.

## Incident (2026-07-21): Claude framed composer wiped by Pi separator heuristic

Away-mode delivery on this home's Claude-on-Herdr primary never succeeded.
`state/.supervise-daemon.log` across four daemon runs since 2026-07-19 recorded 1630 `inject deferred` lines, 76 undelivered-escalation wedge alarms, 9 buffered escalates, and 0 successful injects.
Every deferral used the same reason: `supervisor composer not confirmed-empty (state=unknown: ...)`.
The captain relied on away mode overnight 2026-07-20/21 and received nothing for 4.5 hours (last wedge age 16309s) while finished jobs sat idle.
Machine sleep and fleet failure were ruled out (`pmset` last real sleep 2026-07-18; fleet kept working).

**Live capture of the idle primary (`default:wT:p1`, Herdr 0.7.4, Claude Code, custom Firstmate statusLine):**

```text
───…─── FIRSTMATE ──
❯
───…───
  ⚓ Opus 4.8·high │ 🧠67% ⚡14% │ …
  ⏵⏵ bypass permissions on · 1 shell · ← for agents
```

`agent get` reported `claude` / `idle`.
The bare `❯` row was found, then discarded: the Pi incomplete-separator path treated the full-width bottom `─` frame as proof the generic row was stale and forced `found=0` → `unknown`.
Earlier Claude fixtures used short `──────` rows (<8 chars), so they never tripped `fm_backend_herdr_pi_separator_row` and never exposed the wipe.
The custom statusLine and bypass-permissions footer sit below that frame; they were not themselves misclassified as bordered composers (interior `│` only).

**Fix:**

1. Wipe a generic match on a lower unmatched separator only when that match was `bordered` (stale decorative box).
   Keep a bare agent glyph (`❯`/`›`) even when Claude/Codex frame it with full-width rules.
2. Daemon startup runs `probe_delivery_channel`: refuse to enter away mode (and clear `state/.afk`) when the idle supervisor composer reads `unknown`, so silent permanent non-delivery cannot advertise itself as active supervision.
   `empty` and `pending` pass; mid-turn busy defers the check; `FM_AFK_SKIP_DELIVERY_PROBE=1` remains for stub-pane topology tests.

Regression coverage: `tests/fm-backend-herdr.test.sh` (`test_composer_state_claude_framed_bare_prompt_with_statusline_is_empty`, pending twin) and `tests/fm-daemon.test.sh` (probe accept/refuse/skip, `startup_abort` clears `.afk`).
Live re-check after the wipe fix: `fm_backend_herdr_composer_state default:wT:p1` → `empty`.

## Verified bug: `pane read --lines N` returns empty for small N

This was the most significant finding of this verification pass.

`herdr pane read <pane> --source recent --lines N` returns **completely empty output** when `N` is smaller than the pane's current viewport height, instead of clamping to the last `N` lines.
Reproduced deterministically by binary search against a 23-row pane: `--lines 5/6/8/15` all returned zero bytes; `--lines 20` returned a partial read; `--lines 24` and above returned the full expected content, correctly clamping down even at `--lines 1000`.

This silently broke exactly the small bounded reads the adapter needs most - the composer-state guard/fallback reads around submit and injection, and would have affected any small `fm-peek.sh` line count too.
Before the workaround, an early version of the real-herdr smoke test flaked intermittently for exactly this reason.

**Workaround:** `fm_backend_herdr_capture` never passes a caller's small requested line count straight through to herdr's own `--lines` flag.
It always requests a generous floor (>= 200 lines, comfortably above any realistic pane viewport) from herdr, then trims to the caller's actual requested bound locally with `tail -n N`.
Verified this eliminates the flake across repeated full smoke-test runs.

## Verified gap: `agent.get` reads idle during a long foreground tool call

`herdr agent get <pane>` -> `.result.agent.agent_status` was verified against a short interactive `claude` exchange (see "Busy state" above): `working` while the model streams a turn, `done` once it stops.
That verification did not cover a crew blocked on its OWN long-running foreground tool call - e.g. `no-mistakes axi run` without `--yes`, which blocks synchronously for the whole pipeline (minutes to tens of minutes) until a gate or outcome, per `AGENTS.md` section 7.
For that entire span the model is not generating - it already finished the turn that invoked the tool and is waiting on the tool's result - so `agent_status` reads `idle` (or `blocked`, which the adapter also maps to `idle`), even though the pane's own rendered text keeps showing the harness's busy banner (`BUSY_REGEX`, e.g. `esc to interrupt`) the whole time, exactly as it would in a plain tmux pane.

This surfaced as a real fleet incident (2026-07-02): `bin/fm-watch.sh`'s absorb-only-when-provably-working stale path (`AGENTS.md` section 8) treated a herdr `idle` verdict from `crew_pane_is_busy` as final, so it skipped the shared tail-regex corroboration that `unknown` already got.
At the same time, an independent no-mistakes run-step attribution fallback could miss this crew's run when `axi status` reported another branch; current `bin/fm-crew-state.sh` falls back to top-level `no-mistakes runs --limit ${FM_CREW_STATE_RUNS_LIMIT:-200}` and applies its authoritative current-code matching rules before accepting a coarse verdict.
Together, those gaps let a genuinely still-working herdr crew read as not provably working, triggering an immediate stale wake instead of the intended absorb-then-escalate behavior.

**Fix:** `bin/fm-crew-state.sh`'s `crew_pane_is_busy` now corroborates BOTH `idle` and unknown/unparseable native verdicts with the shared tail-regex before concluding "not busy" - only a bare `busy` verdict is trusted outright.
The cross-branch attribution fallback now uses the real `no-mistakes runs` command with current-code matching, and the watcher checks provably-working evidence before a stale status-log verb can make a stale pane terminal.
This does not mask a genuinely human-blocked agent (a permission dialog, not mid-tool-call): that pane does not render the busy banner, so the corroboration still correctly reports not-busy for it.

## Slash/`$` autocomplete popup hazard (confirmed, same mitigation as tmux)

Typing `/mem` into a live `claude` composer inside a herdr pane and reading the pane back within 0.1 seconds already shows the full autocomplete popup.
This confirms the same hazard tmux already mitigates: submitting immediately after a `/`- or `$`-prefixed send risks Enter landing on a popup selection instead of the literal typed command.
`fm_backend_herdr_send_text_submit` takes the same settle-before-first-Enter parameter tmux's submit core does; the settle-duration DECISION itself lives in `fm-send.sh` (harness-aware, backend-independent), so neither adapter needs its own settle policy.

`escape` was verified to dismiss the popup while leaving the typed text in the composer, not a full clear.

## Incident (2026-07-03): a slash command left fully typed but unsubmitted, silently

Two grok/herdr crewmates were each sent `/no-mistakes` via `fm-send.sh`.
In both panes the command sat fully typed in the composer, unsubmitted (footer still read `Enter:send`), for minutes, until a manual `FM_HOME=<home> fm-send.sh <target> --key Enter` landed it instantly.
`fm-send.sh` had exited 0 both times - no failure surfaced to the caller.

Root cause, reproduced live against real grok 0.2.82 on an isolated herdr session: the send-text-submit verification at the time used the old delta-based strategy and declared success whenever the captured pane content changed AT ALL between before and after an Enter.
For an argument-taking slash command, the FIRST Enter does not submit - it closes the completion popup and, for a command like `/compact [context]`, EXPANDS the composer text into an argument-hint placeholder (`/compact` -> `/compact compaction instructions`).
The popup disappearing and the composer text changing is a real, visible content change, so the old delta check declared "submitted" after exactly one Enter, even though the composer still held real, unsubmitted text and the footer still read `Enter:send`.
A genuine second Enter was required to actually submit - exactly the manual recovery that worked both times in the incident.
Plain (non-argument) commands like `/new` did submit on the first Enter in the same live test, so the false-positive was specific to commands whose popup selection fills an argument placeholder rather than submitting outright - `/no-mistakes` (optional task-first argument) is exactly that shape.

The tmux backend was NOT affected by this incident: `fm_tmux_composer_state` reads the actual cursor row and classifies it as pending whenever real text remains, so its retry loop correctly issued the second Enter and landed the same live repro; this was confirmed side-by-side against the same real grok pane.

**Fix:** `fm_backend_herdr_composer_state` replaced the delta-based check with a structural read of the composer's OWN row, mirroring what the cursor-row read gives tmux.
Herdr's CLI exposes no cursor-row primitive, so the composer row is located by shape instead of position.
For bordered composers, the row is the only line in a generous tail capture whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, or a plain `|`) - the box's own top/bottom rows use rounded corners and never match, popup item rows and separator rows carry no border glyph at all, and the footer help line uses `│` only as an interior separator (never as the first/last character), so none of those can be mistaken for the composer.
For unbordered live composers, added after the 2026-07-07 incident below, the row is a bottom-most trimmed line starting with a verified agent prompt glyph; decorative bordered boxes above it lose to that bottom-most match.
`bin/fm-composer-lib.sh` is the fleet-wide owner of the current glyph set, which has since grown past the `❯` and `›` this adapter was first verified against.
For Pi, added after the 2026-07-14 incident above, the candidate is the content between the bottom-most complete separator pair, admitted only when native Herdr identity reports exactly `pi` with status `idle`, `done`, or `blocked` and the bounded structure is unambiguous.
A popup-close-with-placeholder-fill still reads as real content on that row, so composer fallback correctly classifies it as pending; on the normal idle-baseline path, the same first Enter also fails to start a turn, so native agent-state confirmation likewise retries instead of stopping early.
Known ghost/placeholder composer text is recognized and still reads as empty; the shared alternation lives in `FM_COMPOSER_IDLE_RE_DEFAULT` (`bin/fm-composer-lib.sh`), covering grok's `Type a message...` and cursor's placeholders.
When ANSI capture is available, the shared `fm_composer_strip_ghost` extractor removes de-emphasised ghost/placeholder runs before classification while retaining real typed input.
The full dim/faint and dark-TRUECOLOR contract is recorded in the 2026-07-10 incident below.
`FM_BACKEND_HERDR_IDLE_RE` extends that placeholder match, `FM_BACKEND_HERDR_BARE_PROMPT_RE` controls the recognized unbordered prompt glyphs, `FM_BACKEND_HERDR_COMPOSER_LINES` controls the tail-window scan depth, and `FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES` bounds a Pi separator candidate; all four are documented in [`docs/configuration.md`](configuration.md).
See `fm_backend_herdr_composer_state`, `fm_backend_herdr_wait_for_working`, and `fm_backend_herdr_send_text_submit` in `bin/backends/herdr.sh` for the implementation, and `tests/fm-backend-herdr.test.sh`'s composer-state, wait-for-working, and send-text-submit sections for the fake-harness coverage.

## Composer-state classifier: structural row read, not delta-based

The herdr adapter no longer diffs raw pane content before/after Enter (see the incident above for why that was unsafe).
It keeps `fm_backend_herdr_composer_state` as a structural classifier for the composer's own content - located as the bottom-most bordered row, verified bare prompt row, or identity-corroborated Pi separator region described above - and reports `empty`, `pending`, or `unknown`.
When ANSI capture is available, the classifier keeps the raw styled row long enough to route it through the shared `fm_composer_strip_ghost` extractor before classification.
The 2026-07-10 incident below records the supported dim/faint and dark-TRUECOLOR ghost/placeholder styling.
That classifier is still the away-mode daemon's affirmative-empty pre-injection guard and the conservative fallback when `fm_backend_herdr_send_text_submit` cannot use an idle/done native agent-state baseline.
Normal idle-baseline submit confirmation now uses herdr's native agent-state instead; see "Native agent-state submit confirmation" for the current submit path.
A dedicated composer-state or cursor-row/style primitive is still a candidate upstream Herdr feature request; it would let the guard/fallback classifier eventually reach tmux's cursor-row precision instead of relying on a structural approximation over captured tail rows and ANSI style.

All implemented backends expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching at all.
A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

## Current transport behavior

### Named server and session routing

Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

### Server ownership

A local Herdr server is started in exactly one place, `fm_backend_herdr_server_start_detached`, and only paths about to create something call it through `fm_backend_herdr_server_ensure`.
Those paths are a spawn and its recovery, the away-daemon launch, the absence proof behind `fm-control.sh` relaunch and exit, and the remote doctor's server fix.
Every read or send - capture, busy state, current path, text, keys, and kill - goes through `fm_backend_herdr_target_ready`, which only checks that the server is running.
When it is not, the read reports that on stderr and fails at once instead of starting one, because no server means no pane to read or send to.

Herdr 0.7.4 has no detach or no-autostart option of its own, and its status reports `detached_server_daemon` as false, so the owner detaches the server itself with Perl's `POSIX::setsid`:

- The server runs in its own session and process group, so killing the job that needed it, for example `launchctl kickstart -k` on a launch agent, cannot take the server and every pane with it.
- Its stdin, stdout, and stderr are `/dev/null` and every other inherited descriptor is closed, so it never holds a caller's pipe or lock open, and the caller returns as soon as the server has left its session, with a failed detach reported to the caller.
- Its working directory is `$HOME`, never a task worktree that cleanup may later remove.
- Its environment drops per-session harness identity (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_MESSAGING_*`, `CLAUDE_PID`, `CLAUDE_EFFORT`, `AI_AGENT`, `CODEX_THREAD_ID`, `CODEX_SANDBOX*`, `PI_CODING_AGENT`, `GEMINI_CLI`, `GROK_AGENT`, `GROK_SESSION_ID`, `GROK_HOOK_*`, `GROK_WORKSPACE_ROOT`, `OPENCODE`, the Cursor markers, the Rovo markers including `AGENT=rovodev_cli`, and the prime-agent `PRIME_AGENT_INTERNAL_DAEMON_WORKER`, `PRIME_AGENT_BUILD_ID`, `PRIME_AGENT_LAUNCHER_PATH`, and `PRIME_AGENT_KERNEL_VENV`), every `FM_*` home and task marker except `FM_REMOTE_JOB_ACTIVE`, which the remote owner-birth check reads to prove a worker-started server, the caller's own multiplexer pane identity (Herdr, tmux, Zellij, and cmux), trace context, and per-task Git config and Go temp root.
- It keeps user configuration and credential roots such as `CODEX_HOME`, `PI_CODING_AGENT_DIR`, `GROK_HOME`, `GEMINI_CLI_HOME`, `OPENCODE_CONFIG*`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, and `CLAUDE_CODE_OAUTH_TOKEN`, so an unpinned worker still runs on the launcher's account.

Herdr passes its server startup environment to every later pane, so retaining those values would give every pane a dead agent's session, effort, or task wiring.
An already-running server is reused without restart or environment changes.
Explicit named-session routing and unrelated launch environment remain intact.
A server that the captain starts by attaching the Herdr client from a terminal is outside this owner and keeps that terminal's environment.
`tests/fm-backend-herdr.test.sh` pins both halves: the detached start, and that no read starts a server.

### Sending text and keys

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane.
Ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.

Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter, so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

### Claude composer proof

When native `agent get` identity is Claude, the adapter types only into an empty composer.
A Claude composer that already holds text, or cannot be read, before the send is refused with nothing typed.
Before that Enter, the adapter continues only when the selected composer shows the typed payload, or only Claude paste placeholders with no literal remainder.
Every herdr adapter composer read (`fm_backend_herdr_composer_state`, `fm_backend_herdr_composer_content`) captures the full visible viewport, never a bounded tail, while the shared inbox pending-line confirmation read (bin/fm-task-inbox-lib.sh) stays a bounded tail on every backend: an overlay Claude renders between the composer and the pane bottom - the slash-command popup is the verified shape - pushes the composer outside a tail window, and the composer is by definition inside the viewport.
Dated measurement: docs/verification/runtime-backends.md "Claude exit behind the slash-command popup".

That comparison ignores whitespace and U+2063, the invisible mark that starts operational inputs and ends the from-firstmate label.
It ignores U+2063 because Claude's Herdr read-back never shows it.

A composer that holds a shorter suffix, or a placeholder plus a literal remainder, does not receive Enter.
Instead:

1. The adapter presses Ctrl+U until the shared classifier reads the composer as empty.
2. It then reports `send-failed`, so a resend starts from a clean composer.

Ctrl+C is not used for this, because Claude documents it as interrupting a running operation.
If the composer cannot be verified empty again, the submit reports `unknown` instead, because text may still be in the composer.

Other harnesses, and panes with no native identity, skip this proof and keep the type-then-Enter path.
They skip it because their paste placeholders and composer shapes are not live-verified.

### Submit confirmation

On an idle or done native baseline, submit confirmation proceeds in this order:

1. Wait for `working` or `blocked` across a bounded polling window.
2. If native status stays idle, use the shared composer verdict as the next positive signal.
   A cleared composer is delivery, and proven pending text retries Enter.
3. After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter.
   It keeps an idle pending composer as a genuine swallow.

On an already active or unreadable baseline, the adapter falls back to conservative composer clearance.
That fallback adds a pre-Enter rendered-footer transition when the baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.

`blocked` is not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

### Harnesses with no idle baseline

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.

Cursor is one such harness:

- Herdr reports a Cursor pane `blocked` in every state.
- Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token.
  That token is composer content, and therefore `pending` on a composer that holds no user text.

That fallback alone reported every delivered steer as unconfirmed.
So it is paired with a rendered-footer transition.
The pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.

A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery.
After retries, only proven pending text plus native `working` can establish that its Enter was accepted and queued.

The composer verdict itself is deliberately unchanged.
A right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.

The poll density bounds the residual possibility of an extremely fast complete turn.
A missed native transition falls through to the composer verdict rather than reporting a false swallow.

### Capture size

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for the small bounded reads that remain: peek and watch tails, the rendered busy-footer read, and the shared steering-inbox pending-line read.
The adapter's own composer reads are exempt because they read the visible viewport instead, which takes no line count (see [Claude composer proof](#claude-composer-proof)).

### Native idle state

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity.
It never accepts a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture.
It hands the visible pane's ANSI viewport plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape:

- Bordered boxes.
- Bare agent-glyph rows, including muse's `⟩`, which the adapter's retired local pattern silently omitted.
- opencode's left bar.
- The Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.

### Pi composer states

A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's.
That state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

### Placeholder and ghost text

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.

If the ANSI capture ever fails, the plain fallback declares itself unstyled.
The classifier then degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input.
That safely defers injection and eventually raises the wedge alarm.

### Away-mode injection

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

### Operational input markers

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
Claude Code itself then removes it from the submitted prompt, so a Claude Code primary receives away-mode escalations as the owner's record-backed doorbell instead.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

### Husks after a server restart

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids.
The underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.

Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

### Stale agent registrations

A registration alone never proves an agent.
Herdr keeps a Pi registration after the Pi process has exited to a plain shell, whenever a nested interactive shell sits under the pane's top shell.
In that case `agent get` still reports `agent=pi` with its last status.
That nested shell is the crew shape `treehouse get` leaves behind (measured on Herdr 0.9.0 - [verification](verification/runtime-backends.md) "Stale agent registration"; upstream issue #4115).

So before a registered agent counts as live, the pane classifier reads `pane process-info` and the real process table.
It uses the shared harness-process classifier in `bin/fm-agent-process-lib.sh`, the same rule the tmux adapter proves liveness with:

| What the process view shows | Verdict |
| --- | --- |
| A harness in the foreground process group, or still a descendant of the pane shell | The registration stays live. |
| A foreground that is nothing but shells, with no harness descendant | A `stale-agent` pane: agent-free, with that explicit reason. |
| A foreground holding anything else | The registration stays live, but only after the same bounded settle window the idle-shell proof uses. |
| An unreadable process view | The pane is `unknown`, trusting neither the registration nor its absence. |

The settle window exists because an idle shell transiently hosts prompt helpers such as starship in its foreground group.
The first agent or shell sample in that window decides.

No registered status outranks the process view, because an agent killed mid-turn leaves `working` behind just as a quit one leaves `idle`.
The native busy verdict is verified the same way, so a shell-only pane never reads busy.

### Process-view version support

The `pane process-info` subcommand that this process-level proof depends on is present in every supported release client from the 0.7.1 floor upward (measured 2026-09-10 on the pinned 0.7.1, 0.7.3, 0.7.4, and 0.7.5 release clients - [verification](verification/runtime-backends.md) "Stale agent registration").
The response shape the adapter parses (`result.type` of `pane_process_info`, `process_info.shell_pid`, and `foreground_processes` entries carrying `name`, `argv0`, `argv`, and `cmdline`) is verified live only on Herdr 0.9.0.
The idle-shell proof's narrower parse was previously verified on 0.7.5.
A server response below 0.9.0 has not been measured for this parse.
An unreadable or unparseable process view reads `unknown`, which refuses lifecycle verbs and recovery rather than trusting the registration.

### Agent-liveness probe

The generic Herdr agent-liveness probe reuses that pane classifier, then applies one recovery-only exception.

| Pane read | Probe verdict |
| --- | --- |
| A structurally gone pane, or a pane read from a session positively reported as having no running server | `missing` |
| A restored agent-less shell, or a stale registration over a shell-only pane | `dead` |
| A registered agent with a live process | `alive` |
| Every other unexpected read | `unreadable` |

Neither the stopped-server exception nor the stale-registration verdict widens husk detection or any close authority.
Those paths still refuse an unreadable pane.
A `stale-agent` pane is reused by recovery, never closed as a husk, because the shell it holds may be a nested worktree shell.

Native registration still identifies Pi by name where tmux would see a generic interpreter.
The process-level proof only decides whether that registration is backed by a running process.
`tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh` pins the live-Pi versus leftover-shell distinction.
[`verification/runtime-backends.md`](verification/runtime-backends.md#agent-lifecycle-control) owns the versioned evidence.

The session-start sweep and the watcher's dedicated secondmate liveness tick use this probe.
Idle secondmates remain exempt from stale-pane escalation.
[Secondmate endpoint recovery](architecture.md) owns the shared supervision mechanism.

## Agent status authority and relaunch

A pane has ONE status authority, and for Pi with the integration installed that authority is the lifecycle hooks - Herdr then skips screen detection for the pane, which is the `full_lifecycle_hook_authority` reason `herdr agent explain` prints for it.
That authority is bound to a session identity, and in the crew shape the registration outliving its process ([above](#restart-and-liveness-behavior)) is that same binding: the record stays, the agent it named is gone.

An agent started FRESH in such a pane reports a new session and Herdr ignores its reports, so the pane stays frozen at whatever the previous agent last reported - a crewmate running its pipeline reads `idle` until its task ends, and nothing from outside repairs it (measured 2026-09-21 on Herdr 0.9.1 against a real Pi; `pane report-agent-session` and `pane report-agent` for `herdr:pi` are accepted without being applied unless the reporter is the registered pane agent, and `pane release-agent` on the stale record changes nothing).
A fresh spawn never meets this: it gets a new pane with nothing bound.

So a **relaunch** preserves the binding instead of fighting it: before the Pi-family launch line is composed, `bin/fm-spawn.sh` reads the pane's recorded session reference through `fm_backend_herdr_pane_agent_session_ref` and passes it back as Pi's own `--session <path-or-id>` (`relaunch_resume_args`; `bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag` owns which adapters and which registration labels qualify).
The replacement therefore starts on the exact identity the authority is bound to, and its `working`/`idle`/`blocked` reports land again.
The reference is the endpoint's own record, never a guess about which session is recent, and only a `pi` label may supply it: a registration belonging to another adapter is ignored, as is an unreadable, missing, or malformed one, in which case the relaunch is the ordinary fresh session it always was.
A relaunch that changes harness AWAY from Pi is not repaired by this and keeps the pre-existing behavior; only the adapter the authority belongs to can resume its session.

The session file may not exist any more: Pi creates it at exactly that path, so the identity survives either way.
The read grants no send, close, or lifecycle authority of its own - it is a read of Herdr's record.
The portable halves are pinned by `tests/fm-backend-herdr.test.sh` (the read, against a canned CLI) and `tests/fm-control.test.sh` (the per-adapter rule), and `tests/fm-control-herdr-smoke.test.sh` exercises the relaunch path against the real binary; the versioned live measurement, including the reproduction and the resume that lifts it, is [`verification/runtime-backends.md`](verification/runtime-backends.md) "Pane status authority across a relaunch".

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.

The watcher maps the pane back to the task and skips these:

- Secondmate endpoints.
- Declared `paused:` waits, because the worker's declared wait already accounts for its quiet.
  It is left to the watcher's own bounded pause cadence.
- Verified `captain-held` transfers.
  A captain-held transfer remains silent without rechecks while the away-posture record exists.

### Polling fallback

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when any of these is unavailable:

- Protocol 16.
- The event schema.
- Python.
- The connection.
- The subscription.
- Repeated reader execution.

There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, cmux, and Paseo as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

### Where the daemon runs

- Harnesses with native tracked background execution can run the daemon in their terminal.
- Pi and pi-signed no longer launch the away daemon; their ordinary supervision session continues under the posture record.
- A non-Pi home that runs the supervision host also skips the daemon for `/afk`; see [supervision-host.md](supervision-host.md).
- For another harness without native tracked background execution, `bin/fm-afk-launch.sh` runs the daemon in a Herdr workspace, as described next.

In that last case, `bin/fm-afk-launch.sh`:

1. Creates a dedicated unfocused Herdr workspace.
2. Runs the daemon there with an explicit supervisor target and backend.
3. Records the exact daemon pane.
4. Closes only that pane on stop.

It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

### Stopping the daemon

On stop:

1. The daemon receives termination while `state/.afk` still exists, so its final flush can run.
2. The recorded terminal is closed.
3. The AFK flag is removed last.

A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server.
The ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
The helper:

- Provisions only non-default names beginning with `fm-lab-`.
- Supplies an explicit `--session` Herdr option before any `--` delimiter in allowed task commands.
- Refuses caller-supplied session flags and server/session lifecycle subcommands.
- Performs destructive stop/delete only through its guarded lifecycle actions.

Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Session targeting: the `--session` flag, not `HERDR_SESSION` alone

`HERDR_SESSION=<name>` is the adapter's normal way to select a named herdr session for NON-destructive operations: start, workspace, tab, pane, capture, send, and busy-state calls all still use it (via `fm_backend_herdr_cli`, below).

Destructive session cleanup is different, and this distinction was learned the hard way.
Verified empirically: on the installed herdr 0.7.1 client, neither an exported `HERDR_SESSION` nor an inline `HERDR_SESSION="$name"` prefix reliably targets a CLI subcommand once ANOTHER herdr server (e.g. the captain's live default session) is already bound on the machine - the client silently falls back to whatever server IS running instead of the requested one.
This is not a hypothetical: it killed the captain's live default herdr server, twice, from real-herdr test cleanup that relied on exactly this assumption (2026-07-02; this section is the full account, and `bin/fm-herdr-lab.sh` now owns the guard that prevents a recurrence).
`herdr server stop` is the sharpest edge of this, because it takes NO target argument at all - it always acts on "whatever server is running," resolved ambiently, with no positional name to catch a misroute.

The fix, verified against the real binary in an isolated session (both a genuinely separate isolated session and the default session's untouched state confirmed before and after):

- The `--session <name>` GLOBAL FLAG reliably routes every herdr subcommand tried (`status`, `workspace *`, `tab *`, `pane *`, `agent *`, `server`, `session stop`/`delete`) to the named session, in either leading (`herdr --session <name> <subcommand>`) or trailing (`herdr <subcommand> ... --session <name>`) position - both verified to work identically.
- `bin/backends/herdr.sh`'s `fm_backend_herdr_cli` helper wraps every herdr invocation in the adapter: it sets `HERDR_SESSION` (kept for cosmetic/forward-compat reasons - harmless, and it is what the client's own JSON echoes back) AND appends a trailing `--session <name>`, so every adapter call is correctly scoped regardless of what else is running on the machine.
- For destructive session cleanup specifically, use `herdr session stop <name>` / `herdr session delete <name>` (the explicit-by-name forms - `<name>` is a REQUIRED positional argument, so herdr cannot resolve it ambiguously; herdr's own help text requires literally typing `default` to affect the default session), never the ambient `herdr server stop`. `bin/fm-herdr-lab.sh` now owns this guard as the single source of truth: `fm_herdr_lab_teardown` does the stop-then-delete, gated by a read-only hard guard (`fm_herdr_lab_refuse_if_default`, re-querying `herdr session list --json` immediately before EVERY stop/delete call, refusing on a literal `default` name, a not-found name, or `default:true`) as a second, independent layer that fails closed on any ambiguity. `tests/herdr-test-safety.sh` now sources that helper, so its `herdr_safe_stop_and_delete`/`herdr_refuse_if_default` names are thin delegating wrappers over the same owner.

The same guard is now a first-class production helper, `bin/fm-herdr-lab.sh`, not just test scaffolding.
It provisions an isolated never-`default` lab session (names must start with `fm-lab-`), runs every task command through `run <session> ...` with a mandatory `--session` the helper places on every call (before any child-argv `--` delimiter for `agent start`, appended otherwise), and refuses caller-supplied `--session`, any leading option before the subcommand, every server or session-lifecycle subcommand, and any ambiguous child-argv delimiter shape, before invoking Herdr (the exact accepted/refused shapes are enumerated in the `bin/fm-herdr-lab.sh` header comment and pinned by `tests/fm-herdr-lab.test.sh`).
Destructive teardown goes only through `teardown <session>` (or a deliberate mid-run `stop <session>`), each re-running the refuse-default check immediately before every stop and delete.
It also adds a before/after fleet-state tripwire: `provision` records the live `default` session before creating the lab session, and `teardown` verifies that recorded state is byte-identical afterward before clearing it, treating any missing, stopped, or changed default session as a hard failure rather than a warning.
### Rendered-screen inspection: `view`

Herdr draws pane borders, border titles, and the agent sidebar in its TUI **client**, not in its server, so `pane read` - which returns terminal content - cannot observe any of them.
`fm-herdr-lab.sh view <session> [--cols N] [--rows N] [--seconds N] [--format text|raw-bytes]` closes that gap: it attaches a throwaway client to one lab session on a synthetic pty of an exact size and feeds the client's own output through a terminal emulator.
The default `text` format prints the rendered screen with row numbers; `raw-bytes` prints the client's own byte stream instead, because colour and erase behaviour live in the escape sequences and the rendered characters cannot show them.
`bin/fm-herdr-lab-view.py` is the engine; `python3` and the `pyte` module are required, and the command refuses with a clear message rather than half-running when either is absent.

It is a lab instrument, not a fleet operation, and it is deliberately not a session-lifecycle pass-through:

- `view` accepts only `--cols`, `--rows` and `--seconds` - each a whole number inside a bounded range - and `--format`, which accepts only the two literal values. Any other argument is refused, so no Herdr subcommand can be smuggled through it.
- The lab name is validated, this helper's own fleet-state tripwire must exist (so the session is one this helper provisioned), and `fm_herdr_lab_refuse_if_default` runs immediately before the client attaches - the same read-only hard guard the destructive paths use.
- The engine re-validates the `fm-lab-` pattern and the literal `default` refusal independently of the caller, so it cannot be pointed at the live session even when invoked directly, and it builds the Herdr argv literally from that one validated name.
- The engine strips **every** ambient `HERDR_*` variable from the client's environment. This is not cosmetic: `HERDR_SOCKET_PATH` points at the server owning the caller's own pane - the captain's live `default` server in normal use - so inheriting it would let an ambient value rather than the validated name decide which session gets attached. Stripping the prefix leaves the positional session name as the only selector, and it is also what lets the viewer run from inside a Herdr pane at all, since Herdr refuses a nested client when it sees the outer `HERDR_ENV`.
- The caller's stdin is never wired to the pty, so no keystroke can reach the attached client; it only ever draws. The run is bounded by a capped duration, after which the client is signalled and reaped.

Verified on herdr 0.7.4 (2026-09-10). What it established for the primary status surface, in a disposable session at 182x64, with the fleet-state tripwire clean before and after:

| observation | result |
|---|---|
| unsplit pane, `report-metadata --title` | **no border and no title rendered at all** |
| unsplit pane, `pane rename` label | no border and no label rendered |
| split present, `report-metadata --title` | primary's top border renders the full canonical row |
| split present, primary zoomed | companion hidden, all its rows reclaimed, border title still rendered |
| refresh while the primary is unfocused | border row replaced live |
| border title at 60 and 40 columns | Herdr truncates it itself, visibly, with its own ellipsis |
| `title` / `display_agent` store | silently clipped to **80 codepoints**, no marker |
| `report-metadata` across sources | each call REPLACES that source's whole record; tokens merge |
| 20 sequential `report-metadata` calls | 0.23 s total, ~11 ms each |
| `pane get` after `report-metadata --title` | `.result.pane.title` returns the published string exactly; the LAST source to publish is the one it resolves |
| `pane layout` on a two-pane tab | `.result.layout.panes` has 2 entries, `.result.layout.zoomed` is `false` |
| `pane zoom --on` | `.result.zoom.zoomed` is `true`; the pane COUNT is unchanged, so the companion still exists and the border survives |
| `pane layout` while zoomed | still 2 panes, `zoomed` now `true` - the count and the flag are independent |
| splitting a THIRD pane into a zoomed tab | Herdr releases the zoom **itself**: 3 panes, `zoomed` back to `false` |
| `pane zoom --off` on an already-unzoomed tab | accepted and idempotent: `zoom_changed: false`, `reason: "already_unzoomed"` |

The first row is why `bin/fm-status-bar.sh` chrome mode hides the companion pane by zoom instead of closing it: closing it removes the split, and removing the split removes the only border a title can render on.
The `pane get` row is what makes chrome mode's capability gate evidence rather than inference: the launcher publishes the row, reads it back, and requires an exact match before it hides anything.
The third-pane row is why the renderer's release is a confirmation rather than a rescue - Herdr already un-zooms when a co-tenant appears - and the idempotence row is why issuing that release costs nothing when it has already happened.
[`docs/status-bar.md`](status-bar.md) owns the resulting contract.
The zoom, layout, and readback rows are re-run against the real binary by [`tests/fm-status-chrome-herdr-lab-e2e.test.sh`](../tests/fm-status-chrome-herdr-lab-e2e.test.sh), which drives this same guarded lab and self-skips where `herdr`, `jq`, `python3`, or `pyte` is absent.

Crewmate briefs for tasks that drive Herdr lifecycle get this exact contract embedded by scaffolding with `bin/fm-brief.sh --herdr-lab`; every crewmate brief scaffolded without the flag instead carries a loud not-enabled gate, because the scaffold cannot detect from the caller-supplied repo string whether the task will touch Herdr lifecycle.

## ID stability across a server restart

The original design addendum flagged this as an open risk to verify.
It turned out better than feared.

`herdr session stop <name>` followed by a fresh `herdr server --session <name>` - the realistic "firstmate restarted, herdr server needs reattaching" recovery scenario - preserves workspace id, tab id, pane id, and every label exactly.
Herdr persists this metadata to disk per named session, independent of the live server process.
What does NOT survive is the underlying shell/agent process inside each pane (a fresh shell starts in its place) and each pane's live `agent_status` (resets to unknown).

P2 verified this in the single-workspace shape only.
Re-verified in the multi-workspace shape: a `session stop` plus fresh server restart preserved every workspace id, label, tab id, and pane id.

Practical consequence: a stored `herdr_pane_id=` remains a valid fast-path operational target across an ordinary server restart within the same named session.
Bulk recovery reads hidden workspace owner and task identity tokens for new rows, with the legacy home-label and `fm-<id>` fallback retained for old rows.

## Respawn idempotency: a restored task tab is a husk, not a duplicate

A restart's other consequence used to make every fleet respawn a manual chore: a restored task tab comes back with a fresh shell process and no registered agent, or its pane is structurally gone.
Before the husk fix, task duplication treated either shape identically to a genuinely live duplicate and refused unconditionally.

The guard is now husk-aware.
`fm_backend_herdr_pane_agent_state` classifies an existing same-identity pane as one of `dead` (`pane get` -> `pane_not_found`), `no-agent` (the pane exists but `agent get` -> `agent_not_found`), `live` (a real registered `agent_status`), or `unknown` (anything unparseable or unexpected).
New tasks match hidden `fm_task_id`, while legacy rows match visible `fm-<id>`.
Only `dead` and `no-agent` are treated as a husk; `live` and `unknown` both refuse exactly as before, fail-safe toward refusal whenever the state cannot be classified with confidence.
A confirmed husk is closed and replaced instead of refused: `fm_backend_herdr_create_task` always creates the replacement first, closes the preexisting husk tab by id only after that succeeds, and verifies no duplicate hidden identity or legacy label remains before returning success.
It never closes the husk first, because closing a workspace's last remaining tab deletes the whole workspace on real herdr (see "Workspace lifecycle" above) and a session-restore husk can legitimately be that workspace's only tab.
This is the identical create-before-close safety argument `fm_backend_herdr_workspace_prune_seeded_default_tab` already established for the seeded default tab.

Verified against the real binary (`tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, an isolated non-default session): a real `session stop` + fresh `herdr server` restart, followed by a same-labeled `fm_backend_herdr_create_task` call, closes and replaces the restored no-agent husk for both a crewmate/scout-shaped and a `--secondmate`-shaped task (the same function serves both spawn paths), while a pane carrying a genuinely registered agent (via herdr's own `pane report-agent`) still refuses.
The `dead` (`pane_not_found`) classification is covered at the unit level (`tests/fm-backend-herdr.test.sh`, canned-response fake) but not end-to-end against the real binary: killing a pane's underlying process on a live server was observed to make herdr immediately reap both the pane AND its tab together (so the tab never lingers in `tab list` for the duplicate check to even find), and a session restart was never observed to produce a structurally-dead-but-still-listed pane either - only a live, agent-less one.
The `dead` branch remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) that has not been reproduced against the real binary.

## Agent liveness probe reuses the husk classifier

`bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep needs the same underlying question the husk check above already answers with confidence: is this pane's agent actually alive, or is it a bare shell / gone pane pretending to be a live endpoint?
Rather than add a second herdr classifier, `fm_backend_herdr_agent_alive` (`bin/backends/herdr.sh`) is a thin wrapper around the already-verified `fm_backend_herdr_pane_agent_state`: `dead` and `no-agent` both collapse to the sweep's `dead` verdict (a structurally-gone pane and a restored, agent-less bare shell are equally not a live secondmate - the exact shape a dead secondmate leaves behind), `live` maps to `alive`, and `unknown` stays `unknown`.
No new empirical verification was needed for the mapping itself - `fm_backend_herdr_pane_agent_state`'s four states are already verified above (both at the unit level and, for `no-agent`, against the real binary via the respawn-idempotency e2e test); this wrapper only renames them for the generic `fm_backend_agent_alive` dispatcher (`bin/fm-backend.sh`) that also serves the tmux adapter (`docs/tmux-backend.md` "Agent liveness probe").
Unlike tmux's probe, herdr's has no equivalent "which harness is running under a generic interpreter name" ambiguity: the classification comes from herdr's own registered-agent state, not a process name, so herdr correctly resolves every verified harness including `pi` (the one tmux cannot confidently classify - see `docs/tmux-backend.md` "Known gap").

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`) and the real-CLI smoke tests (`tests/fm-backend-herdr-smoke.test.sh` and `tests/fm-backend-autodetect-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `HERDR_SESSION`:

1. `FM_HOME=<scratch> FM_BACKEND=herdr HERDR_SESSION=<isolated> bin/fm-spawn.sh herdr-e2e-t1 projects/scratch-e2e-project claude` - spawned successfully, printing `backend=herdr` in the summary and writing `herdr_session=`/`herdr_workspace_id=`/`herdr_tab_id=`/`herdr_pane_id=` to the task's meta.
2. `FM_HOME=<scratch> HERDR_SESSION=<isolated> bin/fm-peek.sh fm-herdr-e2e-t1` - showed the live claude trust dialog.
3. `FM_HOME=<scratch> HERDR_SESSION=<isolated> bin/fm-send.sh fm-herdr-e2e-t1 --key Enter` - accepted the trust dialog.
4. `FM_HOME=<scratch> HERDR_SESSION=<isolated> bin/fm-peek.sh fm-herdr-e2e-t1` again - showed claude actively working through the brief (creating the branch, writing the file).
5. `FM_HOME=<scratch> HERDR_SESSION=<isolated> bin/fm-send.sh fm-herdr-e2e-t1 "captain says: proceed as planned"` - a plain-text steer, exercising the send-and-verify path; the text appeared correctly in the pane.
6. The crewmate appended `done: hello.txt committed on fm/herdr-e2e-t1` to its status file, and its commit (`add hello.txt` on branch `fm/herdr-e2e-t1`) was confirmed present in the project's git history.
7. `bin/fm-teardown.sh herdr-e2e-t1` **REFUSED**, exactly as required: `REFUSED: local-only worktree ... has work not yet merged into main and not on any remote.`
8. `bin/fm-merge-local.sh herdr-e2e-t1` - fast-forwarded local `main` to the crewmate's commit.
9. `bin/fm-teardown.sh herdr-e2e-t1` now succeeded: returned the treehouse worktree, closed the herdr pane (verified gone via `herdr pane get`), and removed all of the task's `state/` files.

Two real, non-obvious bugs were caught and fixed by this pass alone, both already reflected above and in `bin/backends/herdr.sh`:

- The `pane read --lines N` small-N bug (see above) - without the fix, this E2E run flaked intermittently on the very first `send_text_line` call.
- `pane get`'s `.result.pane.cwd` field is frozen at pane-creation time and never updates; `fm_backend_herdr_current_path` originally read it and would have made `fm-spawn.sh`'s worktree-discovery poll misresolve the acquired treehouse worktree path (it would see the pane's ORIGINAL directory, not where `treehouse get`'s subshell actually landed) - fixed by reading `.result.pane.foreground_cwd` instead, which tracks the live running process.

The isolated herdr session, the treehouse pool worktree, and the scratch `FM_HOME` were all stopped/deleted/removed after this run, using the guarded teardown described in "Session targeting" above; the captain's default herdr session and the live tmux fleet were never touched at any point.

## End-to-end verification: project workspaces across primary and secondmate homes

`tests/fm-backend-herdr-workspace-per-home-e2e.test.sh` drives real spawn and cleanup against two scratch homes and two scratch projects in a guarded non-default lab session.
The updated assertions cover the compatibility boundary:

1. A primary-home worker lands in its human project workspace with compact physical owner/project identity tokens.
2. A secondmate primary pane retains its legacy `2ndmate-<id>` home workspace.
3. A project worker spawned from that secondmate home lands in a distinct token-owned human project workspace, never the secondmate primary workspace or the primary home's project workspace.
4. Recovery from each home combines that home's token-owned project workspaces with its readable legacy home workspace and excludes the other home.
5. Cleanup targets recorded pane ids and leaves every unrelated project and secondmate pane alive.

Every explicit inspection and lifecycle action in the test routes through `bin/fm-herdr-lab.sh`.
Guarded teardown confirms the default-session fleet tripwire is unchanged.

## Away-mode daemon: herdr supervisor-pane support

`bin/fm-supervise-daemon.sh` (the `/afk` sub-supervisor) was tmux-only through 2026-07-03: it discovered its own injection target from `$TMUX_PANE`, and injected via raw `tmux display-message`/`tmux capture-pane`/`tmux send-keys` calls with no backend indirection.
On a herdr-based fleet (firstmate itself running with `HERDR_ENV=1`, no `$TMUX_PANE`), this failed outright at startup: `TMUX_PANE` is unset, so discovery fell through to the legacy `firstmate:0` fallback, which then failed the tmux pane-exists probe and refused to start.

The fix is transport-layer only - discovery, injection, and the busy/composer guards now dispatch through the SAME `bin/fm-backend.sh` primitives every other backend-aware script already uses (`fm_backend_target_exists`, `fm_backend_busy_state`, `fm_backend_capture`, `fm_backend_send_text_submit`, and the new `fm_backend_composer_state` dispatcher added alongside this work).
At the time of this transport fix, classification policy, batching, the max-defer escape, the then-current sentinel contract, locks, and wake-queue handling were unchanged.
`bin/fm-operational-input.sh` owns the current input protocol.

**Discovery.** `FM_SUPERVISOR_TARGET` remains the explicit override, now accepting either a tmux target or a herdr `"<session>:<pane-id>"` target.
A new `FM_SUPERVISOR_BACKEND` override (`tmux`|`herdr`) resolves independently, mirroring `bin/fm-backend.sh`'s own `fm_backend_detect`: `$TMUX_PANE` set selects tmux (even nested inside herdr, matching the innermost-first rule); `$HERDR_ENV=1` with `$HERDR_PANE_ID` present selects herdr, composing the target as `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"`; absent both, the daemon falls back to tmux/`firstmate:0`, byte-identical to its pre-herdr-support behavior.
Other runtime backends, including zellij, orca, and cmux, are not yet supported as supervisor backends - the daemon refuses loudly at startup (`FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"`) rather than misapplying tmux primitives to a pane that isn't a tmux pane.

**Injection dispatch.** `inject_msg`'s pane-exists probe, busy-guard (`pane_is_busy`), composer-guard (a direct `fm_backend_composer_state` read; see the composer-safety note below), and verified submit all take an optional `<backend>` argument (defaulting to `tmux` when omitted, so every pre-existing caller/test is unaffected) and route through the generic dispatchers instead of calling `tmux` directly.
For `backend=tmux` every dispatch resolves to the exact same underlying call as before (`fm_backend_capture`'s tmux arm runs the identical `tmux capture-pane -p -t <target> -S -40`; `fm_backend_tmux_send_text_submit` re-exports `fm_tmux_submit_core` verbatim), so tmux behavior is unchanged byte-for-byte.
For `backend=herdr`, busy detection tries the native `agent.get`-backed `fm_backend_herdr_busy_state` first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the shared regex-over-capture reader before treating the supervisor pane as not busy.
This mirrors the per-task stale-pane busy check `bin/fm-supervise-daemon.sh`'s `stale_window_is_busy` already used; composer/pending detection and the verified submit route through `fm_backend_herdr_composer_state`/`fm_backend_herdr_send_text_submit`.
The wedge alarm's supervisor-client status-line flash (`tmux display-message ...`) is tmux-only cosmetic UI with no herdr equivalent, so it is skipped for non-tmux backends.
A max-defer wedge also attempts the configured backend-independent active alert described in [`wedge-alarm.md`](wedge-alarm.md), while the ERROR log line and durable `state/.subsuper-inject-wedged` marker remain backend-independent.

**A pre-existing bug this surfaced: `fm_backend_target_exists`'s herdr arm.** Before this task, that function's herdr case called `HERDR_SESSION="$session" herdr pane get "$pane"` directly, WITHOUT the `--session` flag.
Per "Session targeting" above, `HERDR_SESSION` alone is not reliably honored once another herdr server is already bound on the machine - it silently falls back to whatever server IS running.
This function happened to look correct in every prior test because those tests only ever had ONE herdr server running at a time.
Verifying the away-mode daemon end to end against a real, isolated `HERDR_SESSION` - while the ambient default herdr session was also running (the normal shape of an actual firstmate fleet) - reproduced it directly: the daemon's own startup target-exists check spuriously refused a genuinely live pane in the isolated session because the ambient default session's socket answered instead.
Fixed by routing through `fm_backend_herdr_cli` (which appends `--session` on top of the env var) instead of the raw ad hoc call.
This fix is backend-plumbing, not daemon-specific: it also corrects the same liveness check other callers use (`bin/fm-session-start.sh`'s per-task endpoint-liveness digest read).

**Empirical verification (real herdr, isolated session only).** `tests/fm-afk-inject-herdr-e2e.test.sh` mirrors `tests/fm-afk-inject-e2e.test.sh`'s three scenarios (human-partial-input deferral, swallowed-Enter retry, a normal single digest) plus a fourth (a persistently pending composer that never clears must alarm via `state/.subsuper-inject-wedged`, preserve the buffer, and never crash the daemon) against a real, throwaway, NEVER-default `HERDR_SESSION`, torn down with `herdr_safe_stop_and_delete` exactly like `tests/fm-backend-herdr-smoke.test.sh`.
The "supervisor pane" is a tiny deterministic bash loop, not a real harness binary, that draws a bordered composer row to exercise the bordered branch of `fm_backend_herdr_composer_state`.
Because submit confirmation now uses native agent-state on idle baselines, the fixture also registers itself as a herdr agent via `herdr pane report-agent` and reports an idle->working->idle cycle around each submitted line.
A thin `herdr` PATH shim swallows exactly one `pane send-keys <pane> enter` call to simulate the swallowed-Enter scenario, since herdr's real CLI has no built-in way to drop a keystroke.
Real claude/codex unbordered prompt coverage lives in `tests/fm-backend-herdr.test.sh`'s captured-fixture regression tests described in the 2026-07-07 incident below.

Building that test surfaced one more real finding worth recording for anyone writing a similar herdr-driven composer script: `tput cols`, called from WITHIN a script launched into a herdr pane via `pane run`/`send-text`, reported a stale/default `80` regardless of the pane's actual width, while an interactively-typed one-off `tput cols` in the same pane correctly reported its real width (54, in the environment this was verified in).
A composer redraw that trusts `tput cols` for its own line-wrapping math can therefore silently overflow the pane's real width and wrap across two terminal rows - breaking the structural single-row border classifier's assumption (the digest looked "concatenated with itself" because the guard never fired: the composer read `unknown` instead of `pending`, so the busy/composer guard did not defer a second attempt).
The test's composer script works around this with a hardcoded conservative width rather than trusting `tput cols` in this execution context.
This `tput` issue is a test-harness-only concern: once the test's own composer script stayed within the pane's real width, `fm_backend_herdr_composer_state` and `fm_backend_herdr_send_text_submit` behaved as expected, but it remains a sharp edge for any future herdr-launched interactive script that computes its own layout from `tput`.

## Incident (2026-07-07): away-mode escalation redelivery loop on herdr

While `state/.afk` was set on a herdr-backed fleet, `bin/fm-supervise-daemon.sh` re-injected the SAME buffered escalation digest into the primary's own supervisor pane every housekeeping cycle instead of clearing `state/.subsuper-escalations` once delivery landed.
Observed twice: 2026-07-06 (three byte-identical digests in a row) and 2026-07-07 (two byte-identical catch-all-scan digests), each redelivery waking the primary's LLM turn for an escalation it had already handled - defeating away-mode's whole point.

Reproduced live against a real, isolated `HERDR_SESSION`, a real `claude` process (the primary's own harness) as the supervisor pane, and the real `fm-supervise-daemon.sh` (not a synthetic composer script): with one buffered `stale persisted 241s` escalation and `FM_HOUSEKEEPING_TICK=1`, the daemon delivered the identical digest to the live pane at least 5 times in 40 seconds, and the agent itself eventually replied "The message is identical again and my position hasn't changed... I'll treat further identical escalations as noise" - an exact live match for the reported symptom.

Root cause: `fm_backend_herdr_composer_state`'s structural composer-row read (added for the 2026-07-03 incident above) recognizes only BORDERED composer rows - a line whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, `|`).
Real `claude`'s live input row is a BARE, unbordered `❯ …` - no border glyph anywhere around it - flanked by plain horizontal-rule separator lines, not a box.
Claude's own startup welcome banner IS bordered, so immediately after launch the classifier's "last bordered row wins" scan locks onto the banner's own blank interior spacer row and misreads it as the composer (a coincidental, and wrong, "empty").
Once ordinary conversation scrolls that banner out of the 20-line capture window - true of any real supervisor pane with any history at all, which is every production case - NO bordered row exists anywhere in view, so the classifier reports `unknown` for a genuinely empty composer, forever.
At the time, `fm_backend_herdr_send_text_submit` treated only a composer `empty` verdict as a confirmed submit; `unknown` counted as failure, so `escalate_flush` never cleared the buffer even though the real Enter genuinely submitted the digest to the real pane.
At the time, the composer-guard deferred only on `pending` (never `unknown`), so the next housekeeping tick's flush attempt retyped and resubmitted the SAME unmodified buffer content - the redelivery loop.
That guard has since been hardened to require an affirmatively-`empty` composer (see "Composer-emptiness safety" below), so an `unknown` verdict now defers injection instead of proceeding.

Also discovered while reproducing: real `codex` (0.142.x) has the identical unbordered-live-row shape, using `›` instead of claude's `❯`, confirming this is not claude-specific.
Codex additionally shows dynamic tip/hint text in its idle composer rather than a blank row.
The first fix deliberately left that as a conservative `pending` verdict at the composer-guard layer because plain text could not distinguish a ghost suggestion from real typed input.
The 2026-07-08 follow-up below closes that gap using herdr's ANSI capture, which preserves Codex's faint styling for ghost suggestions.

**Fix:** `fm_backend_herdr_composer_state` now recognizes TWO composer-row shapes in one scan - the existing bordered shape, and a new bare (unbordered) shape: a trimmed line that STARTS with a verified agent-specific prompt glyph (`❯` claude or `›` codex) with no closing border required at all.
The bare-row default is deliberately limited to `❯` and `›`, while generic shell-style glyphs (`>`, `$`, `%`, `#`) stay recognized only after the bordered shape has already identified a composer row, so a no-agent shell fallback cannot be misread as a delivered escalation.
Both shapes are checked in the SAME forward scan, keeping whichever match comes LAST (bottom-most on screen), rather than trying bordered-only first and falling back to bare-only when nothing bordered is found: a bordered decorative box (a welcome banner, an update notice) is always rendered ABOVE the live composer, never below it, in every harness observed, so "last match of either shape wins" always resolves to the genuinely live, bottom-most row instead of a stale decorative box still sitting in the capture window.
See `fm_backend_herdr_composer_state` in `bin/backends/herdr.sh` for the implementation, and `tests/fm-backend-herdr.test.sh`'s "unbordered (bare) composer rows" section (fixtures captured verbatim from real `claude`/`codex` panes) for the regression coverage - each of those tests read `unknown` before this fix and reads the correct verdict after.

## Incident (2026-07-08): away-mode delivery wedged on Codex ghost suggestions

While `state/.afk` was set on a herdr-backed Codex primary, `bin/fm-supervise-daemon.sh` repeatedly logged `inject deferred: supervisor pane has pending input (non-empty composer)` even though the captain had not typed anything.
The buffered escalations stayed in `state/.subsuper-escalations` until the max-defer alarm wrote `state/.subsuper-inject-wedged`.

**Environment.**

Commands:

```sh
herdr status --json | jq -c '{client:.client, server:.server}'
codex --version
```

Output:

```text
{"client":{"version":"0.7.3","channel":"stable","protocol":16,"binary":"/usr/local/bin/herdr","session":null},"server":{"status":"running","running":true,"version":"0.7.3","protocol":16,"capabilities":{"live_handoff":true,"detached_server_daemon":false},"compatible":true,"socket":"$HOME/.config/herdr/herdr.sock","session":null,"restart_needed":false}}
codex-cli 0.142.1
```

**Failing reproduction, before the fix.**

The reproduction used a throwaway `HERDR_SESSION=fm-afk-codex-ghost-12002`, a scratch `FM_STATE_OVERRIDE`, a real `codex` process in a herdr pane, and the real `bin/fm-supervise-daemon.sh`.
The supervisor target was `fm-afk-codex-ghost-12002:w1:p2`.
The pane capture showed an idle Codex composer with ghost suggestion text:

```text
› Run /review on my current changes

  gpt-5.5 xhigh · Context 100% left · /private/var/fo…
```

The composer classifier and daemon log showed the false pending-input guard:

```text
composer_state=pending
[2026-07-08T09:38:03-0700] daemon starting (pid 12747); target=fm-afk-codex-ghost-12002:w1:p2; target_source=FM_SUPERVISOR_TARGET; backend=herdr; backend_source=FM_SUPERVISOR_BACKEND; afk=on; inject_skip='heartbeat'; stale_escalate=240s; batch=0s
[2026-07-08T09:38:04-0700] inject deferred: supervisor pane has pending input (non-empty composer)
[2026-07-08T09:38:05-0700] inject deferred: supervisor pane has pending input (non-empty composer)
[2026-07-08T09:38:05-0700] ERROR: away-mode escalation undelivered 3s; inject could not confirm a submit (supervisor pane busy or wedged). Buffer + wake-queue preserved; alarm marker written.
```

The wedge marker preserved the buffered event:

```text
fm away-mode inject WEDGED: 7s undelivered as of 2026-07-08T09:38:09-0700
The supervisor pane could not accept an escalation. Buffered items:
Wheelhouse shipped status: done: PR ready
```

**Style evidence.**

Herdr's ANSI capture preserves Codex's distinction between ghost suggestion text and real typed text.
An idle suggestion is faint after the bold prompt:

```text
\e[0m\e[1m› \e[0m\e[2mRun /review on my current changes\e[0m
```

Real typed input with the same prompt is not faint:

```text
\e[0m\e[1m› \e[0mhello captain
```

**Fix.**

`fm_backend_herdr_composer_state` now prefers `herdr pane read --format ansi` for composer classification.
It still locates the same bottom-most bordered or bare prompt row, strips ANSI for shape matching, and then treats a bare-prompt tail as empty only when the raw ANSI row shows that tail rendered faint.
This ignores Codex ghost suggestions such as `Find and fix a bug in @filename`, `Write tests for @filename`, and `Run /review on my current changes` while preserving the `pending` verdict for non-faint real typed text after the same `›` prompt.

**Passing reproduction, after the fix.**

The same real-herdr shape used `HERDR_SESSION=fm-afk-codex-fixed-29849`, target `fm-afk-codex-fixed-29849:w1:p2`, real `codex`, and the real daemon.
The captured idle composer showed faint ghost suggestion text:

```text
\e[0m\e[1m› \e[0m\e[2mWrite tests for @filename\e[0m
```

The fixed classifier and daemon result:

```text
composer_state=empty
[2026-07-08T09:42:00-0700] daemon starting (pid 31034); target=fm-afk-codex-fixed-29849:w1:p2; target_source=FM_SUPERVISOR_TARGET; backend=herdr; backend_source=FM_SUPERVISOR_BACKEND; afk=on; inject_skip='heartbeat'; stale_escalate=240s; batch=0s
[2026-07-08T09:42:11-0700] daemon shutting down
```

No `inject deferred: supervisor pane has pending input` line was emitted, `state/.subsuper-escalations` was empty afterward, and no wedge marker was written.
The unit regression coverage is `tests/fm-backend-herdr.test.sh`'s `test_composer_state_codex_faint_suggestion_is_empty`, `test_composer_state_codex_non_faint_same_text_is_pending`, and `test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint`.

## Native agent-state submit confirmation (fixes the codex idle-tip gap)

`fm_backend_herdr_send_text_submit` now records a pre-Enter native agent-state baseline before choosing the confirmation signal.
When that baseline is legibly idle or done, it confirms a submit by polling herdr's own semantic agent-state (`agent get`) for a submit-active transition (`working` or `blocked`), via the new `fm_backend_herdr_wait_for_working` helper.
Composer content (`fm_backend_herdr_composer_state`) is still used for the pre-injection empty-box guard (`bin/fm-supervise-daemon.sh`'s `inject_msg`, which reads `fm_backend_composer_state` directly and requires an affirmatively-`empty` verdict; see "Composer-emptiness safety" below).
It is also the conservative fallback for submit attempts whose pre-Enter baseline is already submit-active or unreadable, because a preexisting `working`/`blocked` status cannot prove that this Enter landed.
This makes the normal idle-baseline confirmation path cross-agent: it no longer depends on what a harness's idle composer happens to display.

This originally fixed the practical submit-confirmation effect of the Codex idle-tip gap left open by the 2026-07-07 incident above.
The 2026-07-08 follow-up fixed the pre-injection composer guard itself by using herdr's ANSI capture to ignore faint Codex ghost suggestions.
The submit-confirmation path still deliberately uses native agent-state on idle baselines, so it remains independent of composer rendering.

### Design: two failure directions, both guarded

A message that lands from an idle or done baseline must move the target agent into a submit-active state.
Two ways this signal can be missed, and how the design guards each:

- **Slow transition.** A single check right after Enter could sample before herdr has updated `agent_status`, wrongly concluding "not submitted" and causing a needless extra Enter (harmless on its own here, since only Enter is retried, never the text - but wasteful and, for a stricter caller, could read as a false negative).
  Fix: `fm_backend_herdr_wait_for_working` samples repeatedly (`FM_BACKEND_HERDR_SUBMIT_POLLS`, default 6) across the larger of the caller's per-attempt budget (`<enter-sleep>`) and herdr's own minimum confirmation budget (`FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP`, default 0.6s), instead of checking once at the end.
  A transition landing anywhere in that window is caught, and the function returns the instant `busy` is observed, without waiting out the rest of the budget.
- **Instant round-trip.** A turn that starts and returns to idle entirely between two polls would, in the limit, never show as submit-active at all.
  This is not eliminated in principle, but it is bounded by how densely `FM_BACKEND_HERDR_SUBMIT_POLLS` samples the budget, and the empirical evidence below shows real turns take far longer than the sampling interval to even START, let alone finish.
  On the (unobserved) residual chance this happens, the function reports `pending`, and the caller's own invariant (retry Enter only, never retype) means the worst case is a redundant Enter landing on an already-empty composer - a no-op, not a duplicate delivery of the message text.

`fm_backend_herdr_wait_for_working` also distinguishes a genuine "not yet submit-active" reading (the target was legibly read at least once, `idle`/`done` was observed, `working`/`blocked` never was) from a hard read failure (every poll in the window failed to read the target at all).
Only the latter reports `unknown` and skips further Enter retries - matching the pre-existing "never retry past an unreadable target" invariant the composer-based design already had.

### Empirical evidence (2026-07-07, herdr 0.7.1, protocol 14, macOS aarch64)

Verified against real `claude` (2.1.203) and real `codex` (0.142.1) agents in an isolated, throwaway `HERDR_SESSION` (never the default session), using `herdr_safe_stop_and_delete` for cleanup exactly like every other real-herdr test in this document.

Method: for each agent, with the pane genuinely idle, `herdr pane send-text <pane> "<trivial prompt>"` followed by `herdr pane send-keys <pane> enter`, then `herdr agent get <pane>` polled at roughly 30ms intervals, timestamping the FIRST poll that reports `agent_status: working`.

Ten repeated trials per agent (a fresh trivial prompt each run, e.g. "reply with just the word pong"):

| Agent | First-observed-working latency across 10 runs |
|---|---|
| claude 2.1.203 | 0.154s - 0.489s (mean ~0.27s) |
| codex 0.142.1 | 0.087s - 0.435s (mean ~0.25s) |

Every trial's full turn (working -> idle/done) took at least ~1-3s end to end - orders of magnitude longer than the ~30ms sampling interval used to observe it, which is why an "instant round-trip" miss has not been observed in practice.

Additional scenarios verified directly against the real binaries:

- **Never-submitted text stays idle.** Typing real text into either agent's composer WITHOUT pressing Enter leaves `agent_status` unchanged (idle/`done`) indefinitely across repeated polls - confirming that an absence of a `working` observation is a genuine "not submitted" signal, not noise.
- **A popup-selection Enter that does not submit never flips to working.** Sending `/compact` to claude and pressing Enter once submitted immediately in this claude version (no placeholder-fill quirk reproduced here), transitioning to `working` right away - a real submission is what triggers the transition, exactly as designed.
  The 2026-07-03 incident's specific failure shape (an Enter that only fills an argument-hint placeholder without submitting) was not literally reproduced against real claude/codex in this pass (grok, the originally affected harness, was not available), but the fix generalizes on logical grounds that do not depend on which harness is used: filling a composer placeholder is not a submission, so by construction no real turn starts and `agent_status` cannot report `working` for that Enter - see `tests/fm-backend-herdr.test.sh`'s `test_send_text_submit_popup_autocomplete_requires_second_enter` for the corresponding fake-CLI regression coverage.
- **A codex idle composer's dynamic tip text does not affect idle-baseline confirmation.** With a real, genuinely idle codex pane showing its own rotating suggestion ("Summarize recent commits"), `fm_backend_herdr_send_text_submit` against the pane correctly reports `empty` (confirmed) based on the observed `working` transition alone, and the message is confirmed to have landed in the pane's own transcript.
- **Confirmation correctly reports `pending` for a genuinely swallowed Enter.** With `fm_backend_herdr_send_key` overridden to a no-op (simulating a dropped keystroke), `fm_backend_herdr_send_text_submit` against a real claude pane reported `pending` after exhausting its retries, and the typed text was confirmed still sitting, unsubmitted, in the real composer afterward - no duplicate, no false confirmation.
- **Confirmation correctly reports `unknown` for a target that cannot be read**, and does not retry past it: with `fm_backend_herdr_agent_status_raw` overridden to always fail, a real send against a real claude pane reported `unknown` after exactly one Enter attempt (no further retries).
- **Submitting to an already submit-active target is not confirmed by preexisting agent-state alone.** A pre-Enter `working` or `blocked` status now falls back to composer-clear confirmation, so a swallowed Enter that leaves the typed message visible reports `pending` instead of falsely accepting the already-active status as proof.
  If the composer clears, the adapter still reports `empty`; whether a queued message is reliably processed remains real-harness UI/UX behavior outside this adapter's control.

### Regression coverage

`tests/fm-backend-herdr.test.sh`'s "wait_for_working" and "send_text_submit" sections cover both failure directions (a slow transition caught mid-window, an unreadable target that never retries), endpoint-spread timing with no final trailing sleep, the submit-specific `blocked` mapping, the popup-placeholder-fill case using the new mechanism, the already-submit-active baseline fallback, and `test_send_text_submit_confirms_despite_codex_idle_tip_composer`, which asserts a confirmed `empty` verdict AND that `pane read` is never called on an idle baseline.
The composer-guard regression for the 2026-07-08 AFK delivery bug lives in `test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint`.
`test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change` is a regression guard for the pre-injection empty-box guard itself, confirming it still refuses genuine pending composer text after this change.

`tests/fm-afk-inject-herdr-e2e.test.sh`'s synthetic supervisor-pane fixture was updated alongside this fix: since confirmation is no longer composer-content-based, a bash script that only DRAWS composer text without being a registered herdr agent would read `agent_not_found` forever and never confirm a submission - discovered when the pre-existing (composer-only) fixture version of that test regressed against the new confirmation code (Scenario B: 0 digests instead of exactly 1, since the daemon treated every injection as unconfirmed and kept retyping it every housekeeping tick, which is exactly the duplicate-send failure mode this design change exists to prevent).
The fix: the fixture now registers itself as a real herdr agent via `herdr pane report-agent <pane> --source <id> --agent <label> --state idle|working|blocked|unknown` (herdr's own documented integration-protocol primitive for a non-built-in-harness process to report its own agent state, verified empirically here) and reports an idle->working->idle cycle around each submission, exactly as a real harness would.
With that fix, all four scenarios (A: partial-input deferral, B: swallowed-Enter retry, C: normal digest, D: max-defer wedge alarm) pass against the real binary.

## Composer classifier consolidation (verification record)

The structural composer-row read added for the incidents above lived here, in the herdr adapter, while tmux, orca, and cmux each kept their own copy of the "is this composer empty / pending / not an agent composer" decision.
Those copies drifted, and the dangerous drift was shared by tmux, orca, and cmux: a bare shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has exited to a plain login shell - was treated as an empty, ready-to-inject agent composer.
The away-mode escalation injector (`bin/fm-supervise-daemon.sh`) reads composer-emptiness to decide whether a supervisor pane is a safe injection target, so a dead-shell pane misread as "empty" meant an escalation could be typed into (and, worst case, executed by) that shell.
The herdr adapter was already safe here (its bare shape only matches the agent glyphs `❯`/`›`; a bare shell prompt has no composer row and reads `unknown`), which is why its structural classifier is the prior art for the fix.

**Consolidation.** The one glyph/idle/pending decision now lives in a single shared owner, `bin/fm-composer-lib.sh`'s `fm_composer_classify_content`, which every adapter delegates to: `fm_tmux_composer_state` (via `bin/fm-tmux-lib.sh`), `fm_backend_herdr_composer_state`, `fm_backend_orca_composer_state`, and `fm_backend_cmux_composer_state`.
Each adapter still owns its own capture and structural row-finding (genuinely different primitives), then hands the border-stripped, trimmed candidate content plus a `<bordered>` flag to the shared classifier.

**The safety rule.** A bare shell prompt glyph is a genuine empty agent composer ONLY inside a bordered composer container (where the harness draws its own prompt glyph, e.g. claude's older `| > ... |`).
On a bare, unstructured row it is a dead-shell prompt and reads `unknown` (not a safe injection target), never `empty`.
The agent prompt glyphs `❯` (claude) and `›` (codex) read `empty` either way.
`inject_msg` was hardened to match: its composer-guard now reads `fm_backend_composer_state` directly and defers on anything that is not affirmatively `empty` (`pending` real text, or `unknown` for a dead shell or an unreadable pane), instead of only deferring on `pending`.

**Regression coverage.** `tests/fm-composer-lib.test.sh` pins the shared owner directly (bare shell glyph -> `unknown`, the same glyph bordered -> `empty`, agent glyphs -> `empty` bordered or bare, idle placeholder, real text -> `pending`).
Per-backend dead-shell coverage: `tests/fm-daemon.test.sh`'s `test_tmux_composer_state_bare_shell_is_unknown` and `test_inject_msg_defers_on_dead_shell_unknown` (tmux + the injector), `tests/fm-backend-herdr.test.sh`'s `test_composer_state_unknown_when_no_composer_row_found`, `tests/fm-backend-orca.test.sh`'s `test_composer_state_bare_shell_prompt_is_unknown`, and `tests/fm-backend-cmux.test.sh`'s `test_composer_state_unknown_when_no_composer_row_found`.
The herdr incident regressions (`tests/fm-backend-herdr.test.sh`'s composer-state, wait-for-working, and send-text-submit sections) stay green, and `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` passes clean.

## Incident (2026-07-10): away-mode injection wedged all night on the primary claude-on-herdr composer's ghost text

The captain woke to find away-mode had never injected: 20 escalations buffered, the max-defer wedge marker at 30623s undelivered, the wake queue at 65.
Daemon triage and buffering worked perfectly; the injection leg deferred EVERY attempt with `inject deferred: supervisor pane has pending input (non-empty composer)` - 6524 lifetime occurrences in the daemon log, 2144 of them from the single overnight daemon (`pid 94088`, `backend=herdr`, `target=default:w1:p3`), dominating every other defer reason.

**Root cause.** The primary firstmate runs claude, and claude-code renders a rotating prompt SUGGESTION as ghost text in an otherwise-empty composer (the primary does not set `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`; crews do, via `fm-spawn`, so crew panes never show it).
Captured read-only from the live primary pane (no Herdr lifecycle touched):

```
$ herdr --session default pane read w1:p3 --source recent --lines 60 --format ansi | grep '❯'
❯ \033[0m\033[2mwhat's the latest on the wheelhouse healing check?\033[0m
# 3s later (the suggestion ROTATES, proving it is a placeholder, not typed input):
❯ \033[0m\033[2mwhat did the wheelhouse healing verification find?\033[0m
```

The ghost is a bare `❯` prompt followed by `\033[0m\033[2m<suggestion>\033[0m` - SGR-2 **dim**, which herdr 0.7.3 preserves in `--format ansi`.
The tmux composer reader already stripped SGR-2 dim (so tmux read this shape empty), but the herdr classifier did NOT strip dim generically: its only ghost check was a byte-pattern match for codex's shape, `\033[1m❯ \033[0m\033[2m` (a BOLD-wrapped prompt).
claude's prompt is not bold-wrapped (`❯ \033[0m\033[2m`), so the check never matched, the dim suggestion read as real pending text, and the away-mode injector deferred forever.
Prior herdr delivery fixes (the 2026-07-07 and 2026-07-08 incidents above) did not cover this shape - they addressed submit confirmation and codex's specific bold-wrapped faint suggestion.

**Fix (task afk-herdr-false-pending): one ANSI-aware classification owner.** Per captain direction, the fix consolidates ghost/placeholder stripping into a single fleet-wide owner rather than adding another per-harness special case.
`bin/fm-composer-lib.sh` now owns `fm_composer_strip_ghost`, the one ANSI-aware extractor of "real typed content", and both ANSI-capable backends route through it: `fm_tmux_composer_state` (`bin/fm-tmux-lib.sh`, via the now-thin `fm_tmux_strip_ghost` adapter) and `fm_backend_herdr_composer_state`.
It drops every de-emphasised run - dim/faint (SGR 2: claude's suggestion, codex's idle tip) AND a dark/muted TRUECOLOR foreground (grok's placeholder, see below) - and keeps only normal-intensity, normally-coloured text.
The herdr-only faint byte-pattern check (`fm_backend_herdr_prompt_tail_is_faint`) is removed: the generic dim strip subsumes it, and the codex faint regressions stay green through the shared mechanism.

**Also covered: the grok TRUECOLOR placeholder gap.** The harness-adapters skill documented a separate unfixed gap - grok's placeholder is styled with a dark 24-bit truecolor foreground, not SGR-2 dim, so no adapter stripped it.
The same owner now drops a dark truecolor foreground by perceived luminance (`0.299R + 0.587G + 0.114B` below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128).
Verified live against grok 0.2.93 in an isolated tmux session (no Herdr lifecycle):

```
$ tmux -L <sock> capture-pane -e -p -t g | grep '❯'
# empty composer / hint: dark truecolor  (border 38;2;86;82;110, muted 38;2;50;47;70, hint 38;2;110;106;134)
# after typing 'fix the login bug': BRIGHT truecolor  38;2;224;222;244
\033[38;2;86;82;110m│\033[38;2;224;222;244m ❯ fix the login bug ...
```

Real grok input is the bright `38;2;224;222;244` (luminance ~225, kept); grok's de-emphasised UI is dark truecolor (luminance ~51..110, dropped).
The luminance rule assumes a dark terminal theme (the fleet reality); the SGR-2 signal stays theme-independent.

**Regression coverage (deterministic, from the exact captured bytes).** `tests/fm-backend-herdr.test.sh` feeds the exact overnight claude ghost shape through the real `fm_backend_herdr_composer_state` and asserts `empty` (`test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty`), with the same row carrying REAL text still `pending` (`test_composer_state_claude_dim_ghost_row_with_real_text_is_pending`), plus the grok truecolor placeholder -> `empty` and grok bright input -> `pending` pair.
`tests/fm-composer-ghost.test.sh` pins `fm_composer_strip_ghost` directly for both dim and dark-truecolor ghost, and its two prior "keep truecolor" fixtures were corrected from a near-black `38;2;1;2;3` (never a realistic real-input colour; it was only exercising the truecolor payload-skip parser) to a bright `38;2;224;222;244`, which now represents realistic real input while still exercising the same parser path.
`shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` passes clean.

**Resolved: backend-independent wedge alarm.** The max-defer wedge alarm (`inject_wedge_alarm`, `bin/fm-supervise-daemon.sh`) formerly alarmed into the void because its only active signal was a tmux client status-line flash, skipped for herdr, leaving only the passive `state/.subsuper-inject-wedged` marker.
It now also attempts a configurable active alert independent of the supervisor backend; [`wedge-alarm.md`](wedge-alarm.md) owns its channels and verification evidence.

## Incident (2026-07-19): cursor mid-turn reported as blocked (waiting on human)

Herdr's native `agent_status` reported `blocked` for a healthy cursor worker on `default:wP:p4` while the pane still showed the mid-turn footer `ctrl+c to stop`.
The push path treated that as actionable and fired an immediate stale wake (`herdr: agent blocked - waiting on human`) instead of absorbing a busy turn.
Cursor's spinner verb (`Working` / `Running`) is not a safe busy signal - it changes mid-turn - so corroboration matches only the stable footer hint, the same `FM_BUSY_REGEX` entry documented in [`cursor-harness.md`](cursor-harness.md).

**Fix:** `fm_backend_herdr_capture_shows_busy` + `fm_backend_herdr_apply_transition` refuse to surface `blocked` while the busy footer is present; `handle_push_transition` applies the same check as defense-in-depth; `window_is_busy` corroborates native `idle` (herdr maps `blocked` to idle) against the pane-tail regex so the poll path agrees.
An idle cursor pane with no busy footer still escalates as waiting on human.

## Push events: mechanism and evidence (verification record)

Herdr exposes a native, push-based agent-state event stream, and firstmate folds it into the watcher so a crew entering `blocked` (waiting on the human at a permission/trust dialog, an interactive menu, or a wedged prompt) wakes its supervisor sub-second instead of after the ~240s stale-pane wedge timer.
This is the follow-up the former "No `events.subscribe` native push" gap note deferred; it is now implemented.

**Mechanism (one owner per contract).**
`bin/fm-transition-lib.sh` owns the backend-neutral normalized-transition record shape and the single-owner status->action policy table (`fm_transition_policy`: `blocked`=actionable, `working`=absorb-and-clear-dedupe, `idle`/`done`=defer, anything else=fall back to polling).
`bin/backends/herdr.sh` (`fm_backend_herdr_wait_transition`) subscribes to `pane.agent_status_changed` for this home's herdr panes over ONE raw `AF_UNIX` connection via `bin/backends/herdr-eventwait.py`, subscribing to ALL statuses (so `working` edges clear the per-pane dedupe marker) and returning the first fresh `blocked` edge; after the subscription acknowledgement it level-reconciles each pane's current state while the stream remains live, so a pane that went blocked during the gap is caught once and transitions during reconciliation are buffered.
`bin/fm-watch.sh` splices this in as the watcher's terminal wait (`event_wait_or_sleep`, replacing the blind `sleep POLL` for push-capable homes; the fork reaches it through the guarded either/or of hook W1): on a returned `blocked` it maps `pane_id -> <session>:<pane_id> -> task`, exempts `kind=secondmate` endpoints and a declared wait (`bin/fm-classify-lib.sh`'s `status_declared_wait_line`, which owns the verb set and the fold that decides a hold is still open; an idle composer after a captain hold is expected, not a surprise wait-on-human), corroborates against the rendered busy footer (so a mid-turn worker is not treated as waiting on human), and enqueues an immediate `stale` wake only when the pane is truly blocked.
When a watcher hook of the home's private add-on defines `fm_fork_event_wait_or_sleep` (hook W1 in `bin/fm-watch.sh`), that function takes the terminal wait over and may race this wait against its own bounded wait.
With no such hook the watcher runs `event_wait_or_sleep` itself.
`fm_backend_herdr_apply_transition` applies the same busy-footer gate before surfacing a blocked edge, so a false native `blocked` during a healthy turn never reaches the watcher.
Regression coverage: `tests/fm-backend-herdr.test.sh` and `tests/fm-supervision-events.test.sh` (2026-07-19 `default:wP:p4` cursor busy footer `ctrl+c to stop`).
There is no second watcher process: the reader is a short-lived subprocess of the single watcher, so the "exactly one live supervision cycle" invariant and every guard/beacon/arm/turn-end mechanism are unchanged.

**Polling is the permanent fail-closed backstop.**
The watcher's poll loop runs every cycle regardless, so the event path only ever shortens latency and can never drop an escalation.
Three documented triggers disable the Herdr event path (`fm_backend_herdr_events_capable` and the watcher's runtime-disable counter): a build below protocol 16 or missing the events surface in `herdr api schema`; a connect/subscribe failure; and repeated runtime failures, which disable the fast path for the rest of that watcher process (a restart re-probes).
The watcher then uses an add-on watcher hook's own bounded wait when one is loaded, otherwise it returns to pure polling.

**Empirical evidence (2026-07-11, herdr 0.7.3, protocol 16, macOS aarch64 Darwin 25.5.0, python3 3.13, jq present).**
Capability, verified read-only:

```
$ herdr --version
herdr 0.7.3

$ herdr status --json | jq -c '{client:.client.protocol, server:.server.protocol}'
{"client":16,"server":16}

$ herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

Live `idle -> blocked` transition, driven in an ISOLATED never-default lab session (`tests/fm-backend-herdr-eventwait-smoke.test.sh` via `bin/fm-herdr-lab.sh`, fleet-state tripwire clean before and after):

```
# register the pane's agent idle, background the bounded subscriber wait, then:
$ herdr pane report-agent <pane> --source fm-evwait-test --agent claude --state blocked --session <lab>
# fm_backend_herdr_wait_transition returns:
ok - real herdr (herdr 0.7.3): events.subscribe capability gate passes (protocol >= 16, events surface present in api schema)
ok - real herdr (herdr 0.7.3): a driven idle->blocked transition returns the blocked record in 0.129s (pane w1:p2)
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window from the live blocked transition
```

The subscriber returned the `blocked` transition in **0.129s** and the watcher fast-path enqueued a durable `stale` wake naming the task window - versus up to `FM_POLL` (15s) plus `FM_STALE_ESCALATE_SECS` (240s) on the poll path this shortcuts.
Dedupe (one wake per `->blocked` edge, marker cleared when the pane returns to `working`), subscribe-then-reconcile ordering (an already-blocked pane enqueued exactly once while newer edges buffer in the active stream), the `kind=secondmate` / `paused:` / `captain-held:` exemptions, and the three fail-closed fallbacks are covered by the fake-CLI unit tests in `tests/fm-backend-herdr.test.sh` (the `wait_transition`/`apply_transition` cases), `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh`.

## Away-mode daemon terminal launch (2026-07-12, herdr 0.7.3, protocol 16, macOS aarch64)

`bin/fm-afk-start.sh` execs the supervise daemon in the FOREGROUND of whatever terminal it is already in.
Harnesses with a native in-pane tracked-background tool (claude, grok) run it there and the daemon inherits the captain pane's env.
A harness with NO native background mechanism (pi) has no place to run it, and manufacturing one by SPLITTING the captain's active pane visibly shrinks it: `herdr pane split <pane> --direction down --ratio 0.20 --no-focus` creates a second pane whose `tab_id` equals the captain pane's, so the two co-tenant one tab's viewport.
`--no-focus` does not prevent this - it governs focus, not geometry.

`bin/fm-afk-launch.sh` is the single owner of the daemon TERMINAL lifecycle for that case.
On herdr it creates a dedicated background workspace with `workspace create --no-focus` and a unique `firstmate-afk-daemon-*` label in the captain's session, runs the daemon in its pane via `pane run` with `FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND` set to the captain pane, records the exact pane id in `state/.afk-daemon-terminal`, and on `stop` closes exactly that pane, which takes its single-tab workspace with it.
The explicit target and backend make injection reach the captain rather than the daemon's own pane.
No shell `&` is used.
Recovery reconciles a recorded-but-dead terminal by exact id, never by enumerating or matching other Herdr workspaces.

Verified in an isolated lab session (`bin/fm-herdr-lab.sh`, fleet-state tripwire armed; `default` byte-identical before/after). A workspace `w1`/tab `w1:t1`/pane `w1:p1` stood in for the captain's primary pane:

```
# start (FM_SUPERVISOR_TARGET=<lab>:w1:p1, FM_SUPERVISOR_BACKEND=herdr)
fm-afk-launch: daemon launched in non-visible herdr workspace w2 (pane <lab>:w2:p1), supervising <lab>:w1:p1
record: herdr <TAB> <lab>:w2:p1 <TAB> w2
captain-tab (w1:t1) pane count: BEFORE=1  DURING=1   # unchanged: NOT a split
workspace count:                BEFORE=1  DURING=2   # daemon in a separate space
daemon pane w2:p1 tab_id = w2:t1                     # NOT the captain tab w1:t1

# stop
captain-tab (w1:t1) pane count: AFTER=1             # restored/unchanged
workspace count:                AFTER=1             # daemon workspace removed by exact id
record removed, state/.afk cleared last
```

The topology invariant (entering AND exiting away mode leaves the captain's active tab pane set unchanged), the separate-terminal placement, and the exact-id teardown are covered per backend (herdr and tmux) by `tests/fm-afk-launch.test.sh`.

### Stale-artifact lifecycle fix (same change)

The away daemon's `state/.subsuper-escalations` (+ `.since`) and `state/.subsuper-inject-wedged` are a transient delivery cache, cleared only on a successful flush.
Two ordering/scoping bugs leaked them into the next away session: on a clean exit the `/afk` skill cleared `state/.afk` BEFORE stopping the daemon, so the daemon's shutdown flush hit its own presence gate (`inject_msg`: `afk_active || return 1`) and was a no-op; and nothing cleared them on entry.
The fix: `bin/fm-afk-launch.sh stop` SIGTERMs the daemon while `state/.afk` is still present so the flush can run, closes its recorded terminal by exact id, and then clears `state/.afk` last.
On entry the launcher drops the prior session's artifacts when the daemon is not already running, never on a refresh; the sourceable `bin/fm-afk-start.sh` exposes the shared clearing helper and also applies it for a direct, non-prepared fresh start.
This never drops a genuinely-pending escalation: the durable record is `state/.wake-queue` plus each crew's `state/<id>.status`, and any still-true condition is re-escalated by the daemon's heartbeat catch-all scan.
Covered by the unit cases in `tests/fm-afk-launch.test.sh` (clear-on-fresh-entry vs refresh, and the stop ordering asserting the daemon saw `state/.afk` present at SIGTERM).

## Incident (2026-08-13/2026-08-14): first-attempt spawns failed the agent-up gate because the launch pasted the whole brief through the pane shell

Five consecutive first-attempt spawns on this backend failed `bin/fm-spawn.sh`'s agent-up gate: three cursor, then two claude.
Each one refused with `no agent is running in <window> after 60 of 60 poll(s) x 1s (last liveness read: dead)`, and each pane showed the launch line sitting in a plain shell with the brief spilled behind it as quote continuation, so the launch never ran as a command and no agent ever started.
The same tasks came up processing within seconds on the one-line file-pointer relaunch the refusal already prints as its recovery: six of six, across both harnesses.

The gate itself was right, and it is unchanged.
What was wrong is what the launch typed.
Until an agent owns the pane, the launch line is shell input, and it carried the WHOLE encoded brief as its prompt argument: a multi-kilobyte, multi-line paste (this repo's own brief scaffold renders roughly 10KB across roughly 95 lines) in which every newline is a submit into whatever is reading the pane.
Delivering a brief that way is a bet that a terminal, a shell, and a line editor all keep about 10KB of open quoted continuation intact, and on this backend that bet lost reliably.
The first report named cursor because cursor spawns were the frequent victims, but the claude failures the following night establish it as a launch-delivery property of the backend, not of any harness.

**Fix:** on herdr only, the launch line carries a one-line pointer at the brief FILE rather than the brief, and the agent reads it.
The choice is a BACKEND decision in `bin/fm-spawn.sh` (`BRIEF_DELIVERY`), so every adapter keeps its own verified launch template and only the brief ARGUMENT changes; kimi, whose launch line cannot carry a brief at all, gets the same pointer as its separate post-launch delivery.
The pointer is still built through `bin/fm-operational-input.sh`, so what the agent receives stays typed `launch-brief` input.
Every other backend, tmux included, still delivers the brief inline and is byte-unchanged.
`spawn_brief_pointer` is the single owner of the pointer text, shared with the printed recovery, so the launch and its recovery cannot come to name different files.

**Regression coverage:** `tests/fm-spawn-agent-up.test.sh`'s brief-delivery section drives the real `bin/fm-spawn.sh` against a healthy fake herdr endpoint and asserts the exact bytes typed into the pane for claude, cursor, and kimi: one line, no newline, naming the brief file, never containing the brief body, and still carrying each harness's own launch flags.
Confirmed to reproduce the original shape against the pre-fix script (force `BRIEF_DELIVERY=inline` and rerun: `not ok - the launch line typed into the herdr pane still contains a newline, so it is a multi-line paste through the pane`, printing the two-line launch payload).
`tests/fm-backend-herdr.test.sh`, `tests/fm-spawn-herdr-presentation.test.sh`, `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-spawn-batch.test.sh`, `tests/fm-spawn-launch-preflight.test.sh`, `tests/fm-spawn-worktree-settle.test.sh`, `tests/fm-operational-input.test.sh`, `tests/fm-secondmate-lifecycle-e2e.test.sh`, and `tests/fm-cursor-adapter.test.sh` stay green, and `bin/fm-lint.sh` is clean on the changed files.

## Pane rendering: what the isolated lab measured about this client's compositing and erase storage (2026-09-12, herdr 0.7.4)

Measured in an isolated `fm-lab-*` session, with `bin/fm-herdr-lab.sh view --format raw-bytes` capturing exactly what Herdr's own client writes to a terminal.
A probe pane emitted four sequences: a background colour set and then `ESC[2K` with no reset; the same with a reset first; a 256-colour background followed by `ESC[J`; and plain rows.

Two measurements about this backend, recorded as observations and nothing more:

- **This client re-emits rather than forwards.** Across 63 KB of capture it emitted exactly one erase, the initial clear, and re-rendered every cell run as a fully specified `ESC[0;39;48;5;<n>m` sequence. The pane's own escape sequences never reach the terminal; the client reads the cell grid and paints it.
- **Cells erased while a background is set retain that background, and retain no glyphs.** The probe's un-reset `ESC[2K` rows came back as 212 runs carrying background colour 3, and the un-reset `ESC[J` came back as 593 runs carrying background colour 100. Those runs are empty: the erase removed the glyphs, and what survives in the buffer is the colour alone.

**This probe does NOT reproduce the reported solid-rectangle symptom, and must not be cited as if it did.**
In the report, selecting the affected region reveals its text and deselecting conceals it again, so the cells still hold their glyphs.
Erased cells hold none, so there would be nothing for a selection to reveal.
Background-colour erase is therefore disconfirmed as the mechanism behind that report, whatever else it explains.

What is still open, stated plainly so it is not read as settled:

- The **trigger** - what put the affected surface into that state - is unidentified.
- The **masking condition** - whatever renders the glyphs invisible while they remain present and selectable - is separate from the trigger and is also unidentified.
- The **visible symptom** - a solid block of colour over text that selection still exposes - is the only part directly observed, and only by the captain, at the time.
- The **incident-time evidence is MISSING**: no capture of the affected surface exists from while the symptom was present, so nothing here is measured against the actual failure.
- The **responsible component is UNRESOLVED.** No component is named. In particular, nothing above excludes this client: a small sample of well-formed probe input repainted faithfully is a statement about that sample, not a proof that the client cannot be causal under inputs nobody has captured.

No terminal workaround, forced style reset around foreign output, or blanket terminal setting is warranted by any of this, and none has been applied.

`view --format raw-bytes` (see [Rendered-screen inspection: `view`](#rendered-screen-inspection-view)) exists for exactly this class of question, and runs under the same bounds as the text format.

## Active limits

- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Project groups need protocol 22 and Python, are tested offline, and were checked live once against Herdr 0.9.5 on protocol 22.
- Mutable labels can collide; they are never placement or destructive authority.
- A Firstmate outside Herdr cannot resolve a launcher workspace, so a colliding home label refuses new spawns until the collision is cleared.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Only tmux and Herdr can host the away-mode supervisor terminal.

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
tests/fm-composer-lib.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
tests/fm-spawn-herdr-agent-up-live-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-control-herdr-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-herdr-groups.test.sh
tests/fm-herdr-attached-viewer-live-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.

## Known gaps and follow-up notes

- **A primary pane's published `display_agent` is a launch-time label, not current state.** `bin/fm-primary.sh`'s `mark_current_surface` reports the primary pane's `display_agent` once, at launch, as a fixed role-plus-`WAITING` string, and nothing updates it afterwards.
  A sidebar reading that field therefore shows `WAITING` for the whole life of the pane, including while the harness running in it is actively working.
  Separately, Herdr's own `agent_status` for such a pane has been observed disagreeing with the harness's own reported state, so the sidebar and the harness can differ for two independent reasons.
  `bin/fm-crew-state.sh` is the canonical authority for a task's current state and is what any consumer should ask.
  Resolving the PRIMARY's own live state is not decided here: it belongs to the run-state owner, and nothing in this document restates or re-implements state selection, mapping, or precedence.
- **RESOLVED: worktree-discovery isolation guard's symlinked-project-prefix false refusal.** Originally discovered while building the runtime-backend-auto-detection real smoke test (`tests/fm-backend-autodetect-smoke.test.sh`), which needed a scratch project.
  `fm-spawn.sh`'s `PROJ_ABS` was a LOGICAL `cd && pwd` (symlink components kept), while herdr's `foreground_cwd` (and real tmux's `pane_current_path`, on the same OS-level cwd primitive) report the PHYSICALLY resolved path.
  When the project itself lived under a symlinked directory (e.g. macOS's `/tmp` -> `/private/tmp`), the very first worktree-discovery poll saw two different strings for the identical starting directory and the isolation guard false-refused the spawn as "not isolated" before `treehouse get` ever moved the pane - backend-agnostic, not specific to herdr.
  Fixed 2026-07-06 (backlog `fm-spawn-symlink-guard-s8`): `bin/fm-spawn.sh` now canonicalizes once into `PROJ_ABS_REAL` (`cd "$PROJ_ABS" && pwd -P`) right after `PROJ_ABS` is resolved, canonicalizes each observed pane cwd for the worktree-discovery comparison, and uses `PROJ_ABS_REAL` in `validate_spawn_worktree`'s own primary-vs-worktree comparison instead of recomputing from the still-symlinked `PROJ_ABS`.
  This removes both failure directions: a symlinked prefix can no longer false-refuse an isolated spawn, and, since both sides are physically resolved for comparison, a genuinely tangled spawn (worktree resolves to the same physical directory as the project) still correctly refuses.
  Verified with GNU bash 5.3.9(1)-release (aarch64-apple-darwin25.3.0) and git 2.53.0 on macOS (Darwin 25.5.0): added `tests/fm-backend.test.sh:test_spawn_symlinked_project_prefix_avoids_false_refusal`, which drives the real `bin/fm-spawn.sh` against fake-tmux panes whose first `pane_current_path` poll returns both the project's `pwd -P`-resolved physical path and its logical symlink-preserving path while `PROJ_ABS` is reached through a synthetic symlinked prefix (`ln -s <real> <link>`, project passed as `<link>/proj`).
  Confirmed the test reproduces the original bug against the pre-fix script (`git stash` the `bin/fm-spawn.sh` change and rerun: `not ok - fm-spawn.sh should succeed for a project reached through a symlinked prefix` / `error: treehouse get did not yield an isolated worktree ...`), and passes against the fix (`bash tests/fm-backend.test.sh` reports `ok - fm-spawn.sh: a project reached through a symlinked prefix (e.g. macOS /tmp -> /private/tmp) does not trip the isolation guard's false refusal`, with the rest of that suite's assertions unaffected).
  `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` passes clean on the changed scripts.
- **RESOLVED: a restart's restored-layout husk no longer needs a manual pane close before respawn.** See "Respawn idempotency: a restored task tab is a husk, not a duplicate" above for the fix (`fm_backend_herdr_pane_agent_state`, `fm_backend_herdr_create_task`'s close-and-replace).
  Left over from that fix: the `dead` (`pane_not_found`) husk classification is exercised only at the unit level, never against the real binary - killing a pane's process on a live server was observed to make herdr reap the whole tab immediately (never leaving a dead-but-still-listed pane for the duplicate check to find), and a real session restart was never observed to produce one either.
  It remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) nobody has reproduced against the real binary yet.
- **Ghost/placeholder suggestion handling depends on ANSI style.** See "Incident (2026-07-08)" and "Incident (2026-07-10)" above.
  Herdr 0.7.3 preserves the harness's own de-emphasis style (dim/faint and truecolor foreground) in `pane read --format ansi`, and `fm_backend_herdr_composer_state` extracts real typed content with the shared `fm_composer_strip_ghost` (`bin/fm-composer-lib.sh`), which drops dim/faint AND dark-truecolor runs to distinguish ghost suggestions/placeholders from real typed text.
  If a future herdr build strips ANSI style from `--format ansi`, the classifier loses its ghost signal and falls back to reading the suggestion text as `pending` - the fail-safe direction (it defers rather than risks overwriting a human draft), which the max-defer alarm then surfaces.
- **RESOLVED: a "paused / awaiting-external" crew state for the stale-wedge escalation.** Raised alongside the 2026-07-07 incident: an in-flight crew intentionally idling on a known external wait (a vendor rate limit, say) still tripped `bin/fm-supervise-daemon.sh`'s "stale persisted ... (possible wedge)" escalation exactly like a genuinely wedged crew, with no way to mark the wait as expected.
  Fixed by the `paused:` external-wait verb: a crew declares a deliberate wait, and both `bin/fm-watch.sh` and `bin/fm-supervise-daemon.sh` absorb its idle pane through the shared `bin/fm-classify-lib.sh` vocabulary (`status_is_paused`, `crew_absorb_class`, `FM_PAUSE_RESURFACE_SECS`), re-surfacing it for a recheck on a long cadence instead of a wedge escalation.
  See `AGENTS.md` section 8 and the crew-facing brief contract in `bin/fm-brief.sh`.
- **RESOLVED: mid-session secondmate liveness.** The session-start sweep and the watcher's dedicated secondmate liveness tick now both use the agent-liveness probe; see "Agent-liveness probe" above, while idle secondmates stay exempt from stale-pane escalation.
- **RESOLVED: opencode busy-queued Enter on the herdr backend.** After the Enter-retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter; see "Submit confirmation" above.

<h1 align="center">Starship</h1>

<h3 align="center">Talk to one AI first mate. It runs a crew of coding agents for you.</h3>

Starship is a ready-to-use build of [Firstmate](https://github.com/kunchenguid/firstmate).
You ask for work in plain words, and the first mate hands each task to its own AI worker, keeps an eye on all of them, and brings back finished pull requests or written reports.
You only answer the real decisions.

## What Starship adds

- **A guided start** - a step-by-step setup from a blank computer to a first mate that has done one piece of real work, set up around Claude Code and launched with `bin/fm-primary.sh`, plus [a handbook](docs/handbook.md) for everything after that.
- **Herdr from the first launch** - on a Mac and on Windows, the setup installs [Herdr](https://herdr.dev) and starts the first mate inside it, so every worker shows up in Herdr's sidebar with whether it is working or waiting; tmux stays available, and a server uses it.
- **Mac, Windows and Linux** - besides the Mac, it runs on a Windows PC inside WSL 2, or on a rented Linux server you reach over SSH, both set up by one script, `bin/fm-linux-setup.sh`.
- **A desk floater you can talk to** - a small always-on-top control on the [Mac](docs/desk-floater.md) and on [Windows](docs/desk-floater-windows.md): hold a key to talk to the first mate and hear its replies.
- **A call recorder and starter settings** - an optional [call recorder](docs/call-companion.md) that keeps a live page of a call and writes notes when it ends, once everyone has agreed to be recorded, and starter settings for which Claude model does which job and transcription words, which a new home installs on its first launch; its first mate's thinking level follows the Claude plan it runs on, as the [onboarding guide](ONBOARDING.md#3-get-starship-and-start-your-first-mate) explains.
- **Easy updates** - say "update starship" and it pulls the latest shared instructions and scripts and restarts cleanly, without touching your private files.
- **A way to share improvements** - changes to Starship itself go back as pull requests through the `no-mistakes` review pipeline, as [CONTRIBUTING.md](CONTRIBUTING.md) explains.

## Who it is for

Starship is for people and teams who want several pieces of software work done at once - fixes, investigations, plans, reviews - without juggling a separate AI session for each.
Your setup stays yours: a fresh copy holds only the public files, and your preferences, task list, projects and sign-ins stay private on your own machine.

## Start here

| Your computer | Start with |
| --- | --- |
| Mac | [ONBOARDING.md](ONBOARDING.md) |
| Windows PC (through WSL 2) | [ONBOARDING-windows.md](ONBOARDING-windows.md) |
| Rented Linux server | [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md) |

Clone this repository, [Amplify-Logic/firstmate](https://github.com/Amplify-Logic/firstmate), not the upstream one.

## Credit

Starship is built on [Firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen, and like Firstmate it is MIT licensed - see [LICENSE](LICENSE).

# Built on Firstmate

The rest of this page is the original Firstmate introduction.

<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated firstmate homes on this machine or another SSH-reachable host.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it for your primary session instantiates your first mate - and makes you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own tmux window or Herdr tab, or in an experimental Zellij tab, experimental cmux workspace, or experimental Orca terminal you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver authorized changes; scout tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag, an optional `branch=<prefix>` override for the default `fm/` ship-branch prefix, an optional `alias=<name>` for a clone whose directory differs from its registered name, and an optional `forge=gerrit` binding under which the worker publishes a Gerrit change instead of opening a pull request.
- **Self-repo boundary** - a home runs as firstmate user/operator by default, so a firstmate bug is diagnosed and patched locally but never pushed, PRed, issued, commented, or forked upstream on its own; publishing to firstmate's own repository needs the `config/firstmate-role` maintainer opt-in or a per-task captain consent ([schema](docs/configuration.md#firstmate-role-configfirstmate-role)).
- **Optional secondmates** - opt in to persistent second mates that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, either locally or as a whole home on an SSH-reachable host, with guarded updates and recovery that never turns an unavailable remote route into a local replacement.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is under way and supervision is not live.
- **Optional status second look** - opt in per home so the heartbeat backstop takes one bounded look at the progress lines the verb-based classifier dropped, catching destroyed data, a spend you own, or a credential need written as a progress note; it can only add an escalation, never silence one, and with the gate absent or the service unreachable supervision behaves exactly as it does today.
- **Optional Relay** - opt in with one local `.env` pairing token so firstmate can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state that is reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Strict project boundary** - the first mate is read-only over your projects except for the narrow guarded and captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; crewmates make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr, rex, or cmux when selected or auto-detected - Starship's setup selects herdr on a Mac and on Windows - zellij/orca/paseo when explicitly selected); the next session reconciles after a restart, while ordinary supervision recovers confirmed-dead secondmate agents without waiting for one.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

Starship's setup is [ONBOARDING.md](ONBOARDING.md): five steps from a blank Mac to a first mate that has added a real project and brought back a worker's report, launched with `bin/fm-primary.sh`.

### Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Oh My Pi (`omp`), Codex, OpenCode, or Cursor Agent CLI; the onboarding guide uses Claude Code, and `bin/fm-primary.sh --help` lists every verified launch profile.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default, Starship's setup selects Herdr on a Mac and on Windows, and each backend's setup guide is linked in [Documentation](#documentation).

The first mate detects and offers to install supported missing tools after you approve.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Optional secondmates extend this to persistent local or whole-home remote second mates, dispatch profiles let you steer which harness handles which task, and opt-in Relay lets the same fleet answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional Relay, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: Pi's in-process branch, a [supervision host](docs/configuration.md#supervision-host-configsupervision-host) beside the other primaries (on by default for Claude), or the daemon handles wakes while you step away; see the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract |
| `/quiet`           | Keep routine wakes off main while staying and chatting; requested actions proceed now rather than waiting for your return. Where Pi's branch or an [attended supervision host](docs/supervision-host.md#quiet-mode) already does this, it only says so; otherwise it starts the quiet daemon, which stays active through ordinary chat until `/quiet off` |
| `/ahoy`            | Recap visible session events since the prior real captain message plus visibly unanswered captain decisions, then guide the captain through any open decisions one at a time in agent-judged impact order; fall back to Bearings when invoked as the session's first real captain message |
| `/bearings`        | Generate a concise four-section chat digest from bounded fleet state, including registered remote-home ledgers and measured follow-up for owned contributions; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/updatefirstmate` | Guardedly update the running firstmate and its secondmates - fast-forward, or reconcile a redundant post-squash-merge divergence - then persist and restart every live mate successfully left on the target commit - including already-current homes - with an honest re-read nudge only when restart cannot be proven |
| `/catchup`         | Catch this home up with its own upstream, on demand or weekly once the home opts in: prepare a real-merge catch-up on a branch, report which stack tools are behind, and stop for the captain to approve the merge |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered second mates, and report what is safe to reset |
| `/outward-fine-print` | Switch workers back to acting outward (sending mail, answering invites, changing the calendar, Zapier, browser control) only with their job's own permission or a narrow standing permission; the default |
| `/outward-broad` | Let every worker do whole kinds of outward action, such as send email or control browser, without a per-job permission; name switches to turn on exactly those |
| `/outward-no-block` | Switch the worker outward check off, so workers act outward whenever their instructions say to |

Bearings invocation examples:

- `/bearings` returns the fresh four-section digest in chat only.
- Owned-contribution follow-up comes from the cached coverage projection; `include PRs` remains the opt-in for repository-wide live PR enrichment.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the triggers stated in their skill descriptions, as [`AGENTS.md`](AGENTS.md#13-agent-only-reference-skills) directs.

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the crew, supervision, worktrees, secondmates, and project modes.
- [ONBOARDING.md](ONBOARDING.md) and [docs/handbook.md](docs/handbook.md) - blank Mac to a working first mate, then how the whole system works, making it your own, connecting your tools, and a first-week path to full use.
- [ONBOARDING-windows.md](ONBOARDING-windows.md) and [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md) - the same start on a Windows PC through WSL 2, or on a rented Linux server reached over SSH, using `bin/fm-linux-setup.sh`.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/porting.md](docs/porting.md) - bring Firstmate up on a second machine and keep captain-private portable material in step with explicit push/pull.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - current setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/calm.md](docs/calm.md) - current `/calm` behavior on Pi and Claude Code and its supported presentation limits.
- [docs/call-companion.md](docs/call-companion.md) - the macOS call recorder: a live call desk and end-of-call notes, recorded only after everyone on the call has agreed, and how to stop and delete a recording.
- [docs/meetings.md](docs/meetings.md) - the meeting intake over Anarlog, a local meeting recorder: clear follow-ups from finished personal meetings and shared glasses calls start on their own, everything else waits for a tap, and work meetings are never processed.
- [docs/voice-relay.md](docs/voice-relay.md) - the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/cloud-routines.md](docs/cloud-routines.md) - the scheduled Claude cloud routine that watches public creator repositories with the laptop closed and publishes to a separate reports repository, never to firstmate: setup, what it can touch, cost, and the kill switch.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) - the opt-in activity ledger outside tools can read to follow a home's tasks, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - current setup, socket security, and limits for the experimental cmux backend.
- [docs/paseo-backend.md](docs/paseo-backend.md) - current setup, terminal-name routing, and limits for the experimental Paseo backend.
- [docs/rex-backend.md](docs/rex-backend.md) - current setup, auto-detection, block-id routing, the absence proof, and limits for the experimental Rex backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - the current blocked Codex App backend boundary and rollout contract.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/gerrit-forge-integration.md](docs/gerrit-forge-integration.md) - maintainer architecture for the forge axis: why change-shaped review is not a forge variant, the mode/forge/shape composition test, and where responsibility for forge mechanics sits.
- [docs/external-review-forge.md](docs/external-review-forge.md) - maintainer architecture for `forge=external`, where a review tool uploads its own snapshot: the no-push invariant and its three layers, the personal backup remote, and the accepted residual.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/gerrit-change-watch.md](docs/gerrit-change-watch.md) - maintainer verification for watching Gerrit changes read-only, and why the merge path refuses one.
- [docs/forgejo-tea-integration.md](docs/forgejo-tea-integration.md) - maintainer verification for watching and merging Forgejo/Gitea pull requests via `tea`.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, omp, Grok, Cursor, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervisor contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=kunchenguid%2Ffirstmate&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&legend=top-left" />
 </picture>
</a>

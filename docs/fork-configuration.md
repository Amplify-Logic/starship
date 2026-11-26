# Fork configuration

This page documents the settings this fork, Starship, carries beyond upstream Firstmate.
[configuration.md](configuration.md) owns every other setting and stays as upstream wrote it, so a catch-up from upstream does not conflict over this fork's lines.
Where an entry below restates or extends a line of configuration.md, the entry describes this fork's current behavior and wins over that line.
Each setting section keeps the heading it had in configuration.md, so its title and anchor still find it.

## Find a fork setting

| What you want to configure | Start here |
| --- | --- |
| Worker permissions, accounts, or environment (this fork's additions) | [Worker command guard](#worker-command-guard-configcommand-guard), [worker outward actions](#worker-outward-actions-configoutward-permissions), [Claude concise prompt](#claude-concise-prompt-configclaude-concise-prompt), and [vendor account pinning](#vendor-account-pinning-configaccountsjson) |
| Backlog, preferences, and memory (this fork's additions) | [Startup digest trim](#startup-digest-trim-configstartup-digest-trim) and [address and tone](#address-and-tone) |
| Naming the factories the Factory pane shows | [Factory registry](#factory-registry-datafactoriesmd) |
| Light (cream) or dark for the whole workspace in one switch | [Workspace theme](#workspace-theme-configworkspace-theme) |
| Light or dark colours in the Factory pane and bridge strip | [Terminal theme](#terminal-theme-fm_terminal_theme) |
| The night shift line on the bridge strip | [Night shift window](#night-shift-window-confignight-shift-window) |
| What `starship` opens in Herdr: tabs, panes, Terminal or Ghostty windows and the sidebar | [Desk layout](#desk-layout-configdesk-layout) |
| Keeping the Factory pane out of the desk | [Factory pane kept hidden](#factory-pane-kept-hidden-configfactory-pane) |
| Starter settings for a new home: which model does which job, transcription words, and how hard the first mate thinks | [Starter settings](#starter-settings-first-launch), [crew dispatch profiles](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson), [speech-to-text vocabulary](#speech-to-text-vocabulary-configstt-vocabulary), and [primary effort](#primary-effort-configprimary-effort) |
| Spoken replies | [Desk voice-out](#desk-voice-out-configspeak) |
| The call recorder | [Call recorder](#call-recorder-configcall-companion) |
| The meeting intake | [Meeting intake](#meeting-intake-configmeetings) |
| Answering held decisions by tapping on the phone, and ready merges too once switched on | [Phone tap desk](#phone-tap-desk-configtap-desk) |
| Which pull requests land by themselves and who must say yes to the rest | [Merge rule table](#merge-rule-table-configmerge-rules) |
| Waking the first mate when something arrives in a Mothership room | [Mothership monitoring](#mothership-monitoring-configmothership-monitor) |
| The morning intake, the continuous channel intake and the daily to-do page | [Daily intake and to-do page](#daily-intake-and-to-do-page-configmorning-intake-configchannel-intake) |
| Which Starship version "update starship" follows | [Update channel](#update-channel-configupdate-channel) |
| A home's own private tools beside the shared code | [Private add-on](#private-add-on-configaddon) and [opt-in skills](#opt-in-skills-configadhd-configsecond-opinion) |
| Keeping private names out of this public repository | [Private leak words](#private-leak-words-configleak-words) |
| Paying a home's improvements back into the shared Starship as anonymous cards | [Backport](#backport-configbackport) |

## Workspace theme (`config/workspace-theme`)

`bin/fm-theme.sh light` switches the whole workspace to cream, a warm and soft light look, and `bin/fm-theme.sh dark` switches it back to the dark flight deck; `bin/fm-theme.sh status` shows what each part is in.
One run moves the Terminal windows to Starship's cream profile, swaps Herdr's theme and reloads it, and repaints the running bridge strip and Factory pane in place, so no tab or pane closes.
Dark gives back exactly the Terminal profile and Herdr theme that were in use before the first switch to light, and leaves both as they are when no switch to light saved them.
The choice is remembered in `config/workspace-theme` (`light` or `dark`), so new panes, restarts and the `starship` desk's Terminal views start in it.
Claude Code chats keep their own theme: type `/theme` in each and choose the matching light or dark mode.
The script's header owns what each step changes and what it keeps.

## Terminal theme (`FM_TERMINAL_THEME`)

The Factory pane and bridge strip share `FM_TERMINAL_THEME`: `auto` (default), `light` or `dark`.
An explicit `light` or `dark` wins over the remembered [workspace theme](#workspace-theme-configworkspace-theme) in panes started with it; leave it unset to follow the switch.
Invalid values behave as `auto`.
In automatic mode with no remembered workspace theme, they query the terminal background with OSC 11 at startup, wait at most 150 ms for an RGB reply and use its relative luminance to select readable colours.
If the terminal does not answer, the final ANSI background index in `COLORFGBG` is used when available; otherwise the original dark colours remain.
Redirected output does not query the terminal.
Detection runs once, not per frame; restart the pane after changing the terminal theme.
`bin/fm_terminal_theme.py` owns the detection, the order of these inputs and the shared palettes; no other pane or status surface uses this setting.

## Fork changes to upstream settings

Each entry names the configuration.md section it changes and carries this fork's text.

### Find a setting

The [Find a setting](configuration.md#find-a-setting) rows for worker permissions and for backlog, preferences, and memory also lead to this fork's settings, which the first two rows of [Find a fork setting](#find-a-fork-setting) list.

### Operational home layout and state

In [operational home layout and state](configuration.md#operational-home-layout-and-state), this fork's `data/` also holds a factory registry, so its registries line reads:

- Project, secondmate, and factory registries.

This fork's `data/` also holds:

- The captain ledger `data/captain-ledger.jsonl`, every captain prompt recorded before the primary answers in a home opted in through `config/captain-ledger` (`bin/fm-captain-ledger.sh`).
- Call recordings under `data/calls/`: the transcript, live desk, end-of-call notes and archive (`bin/fm-call-lib.sh`; [call-companion.md](call-companion.md)).
- The meeting intake's record of each meeting taken in under `data/meetings/` (`bin/fm-meetings.sh`; [meetings.md](meetings.md)).

This fork's `state/` also holds:

- The captain-ledger reconciliation cursor `state/.captain-ledger-cursor` (`bin/fm-captain-ledger.sh`).
- The dispatch decision record `state/dispatch-decisions.jsonl` (`bin/fm-dispatch-resolve.sh`; "Typed dispatch resolution" below).
- The localhost web page's token, pid, port and request log under `state/web/` (`bin/fm-web.sh`; [web.md](web.md)).
- The call recorder's process records, logs, short-lived audio chunks and decision logs under `state/calls/` (`bin/fm-call-lib.sh`; [call-companion.md](call-companion.md)).
- The meeting intake's check records under `state/meetings/` (`bin/fm-meetings.sh`; [meetings.md](meetings.md)).
- The Factory pane's cached record, pane activity, last look, who-steers log, opened tabs, and a spoken note while it is being written down under `state/factory/` (`bin/fm-factory.py`; [factory-pane.md](factory-pane.md)).

### Pi supervision branch

In [Pi supervision branch](configuration.md#pi-supervision-branch), this fork routes the branch's runtime files through the skill's inventory rather than `AGENTS.md`:

The `state/` inventory in [`operational-home-layout`](../.agents/skills/operational-home-layout/SKILL.md) routes the branch's runtime files to their format and lifecycle owners.

### Runtime backend

In [backend selection order](configuration.md#backend-selection-order), this fork's setup also chooses the runtime for a fresh home:

Starship's setup writes `herdr` into a fresh home's `config/backend` on a Mac and inside WSL 2, and never changes a home that already names a runtime or has already run; `bin/fm-herdr-setup.sh` owns that rule.

### Firstmate role

In [Firstmate role](configuration.md#firstmate-role-configfirstmate-role), this fork's publication target follows `gh`'s default repository, so these two lines replace upstream's two lines about the publication target:

The publication target is the repository `gh` resolves as its default: a remote's recorded `gh repo set-default` choice when one exists (`remote.<name>.gh-resolved` set to `base` for that remote's own repository, or to `<owner>/<repo>` on that remote's host, including custom remote names), so a fork whose default is its own repository is scoped to that fork, and otherwise the first configured remote in the order `upstream`, `github`, `origin`; selection is offline, and `bin/fm-role-lib.sh` owns URL and local-path normalization.
An unreadable or URL-less selected remote is not replaced by a fallback remote, and an undeterminable target never authorizes a task, even under task consent.

### Gate defaults

In [gate defaults](configuration.md#gate-defaults-no-mistakesyaml), this public fork keeps no-mistakes evidence local, so these lines replace upstream's evidence-storage paragraph:

The tracked [`.no-mistakes.yaml`](../.no-mistakes.yaml) sets `test.evidence.store_in_repo: false` and `test.evidence.attach_media: false`, and runs the canonical [shell/workflow lint](../bin/fm-lint.sh) followed by the [Pi production-consumer typecheck](../tests/fm-pi-primary-types.test.sh) in the compiler-owning lint phase.
This repository is public, so each run's evidence files and media stay in the local evidence directory under the no-mistakes home.
`store_in_repo: false` keeps them off every branch, and `attach_media: false` stops screenshots and recordings being uploaded to the PR, which no-mistakes does by default.
The short inline result text still appears in the public PR description, so the test step instructions keep it to a short result line under the public PR text rule, and the [leak check](#private-leak-words-configleak-words) still applies.
The worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.

The test step instructions also keep raw logs, transcripts and command output out of the PR: they stay as files in that local evidence directory, and the PR names them only in the scenario table.

#### PR text

Each pipeline PR opens with a short plain section a person can read in a minute, and the technical detail follows folded.
The tracked `.no-mistakes.yaml` sets no-mistakes' `pr.template` to [`.github/pull_request_template.md`](../.github/pull_request_template.md), whose comments tell the PR step to fill four sections, In short, See it, You need to and Risk, then a folded What Changed for maintainers, with no tool credit line.
It also sets `pr.appendix: collapsed`, so the recorded risk, test results and pipeline history sit in one closed Validation block at the end; outside that block, only the Intent section, when published, follows the template's text.
No-mistakes reads both settings and the template only from the default branch, so a change to them takes effect on the first run after it lands, and a pushed branch cannot change them.
No-mistakes owns the Validation block's contents: the test results table appears once in its Testing part and again in its pipeline history, and only `pr.appendix: minimal` drops both, leaving one risk line.
[fm-pr-merge.sh](../bin/fm-pr-merge.sh)'s opt-in squash summary still finds the folded What Changed section.

Another project opts in the same way, through a change to that project landed on its default branch: copy the template to the project's `.github/pull_request_template.md`, adjusting the product name in its comments, and add the same two `pr:` settings to the project's `.no-mistakes.yaml`.
Where the project should not carry that setting, the template file alone plus a `repository_overrides` entry for its remote in this machine's no-mistakes config, setting `pr.template` and `pr.appendix`, gives the same result on this machine only.
A PR whose description no-mistakes wrote before the template applied cannot be updated in template mode: the PR step refuses until that description's generated evidence is separated from its narrative by hand once.

### Captain preferences

In [captain preferences](configuration.md#captain-preferences-datacaptainmd--datacaptain-sharedmd), a new home's file comes from its first conversation:

A new primary home has none until its owner's first conversation writes it; the [`first-voyage`](../.agents/skills/first-voyage/SKILL.md) skill owns that conversation and the sections it records, and `bin/fm-session-start.sh` cues it with a `FIRST VOYAGE:` line while the file is missing in a home with no `data/projects.md` and no clone under `projects/`.

How the first mate addresses the person is recorded in that file's [address and tone](#address-and-tone) section.

### Self-update source

In [self-update source](configuration.md#self-update-source-configself-update-source):

A source follows a branch, so it works only on the `main` [update channel](#update-channel-configupdate-channel); combined with a release channel, from `config/update-channel` or `--channel`, the update stops before anything moves.

### Several Claude accounts

In [several Claude accounts](configuration.md#several-claude-accounts-configclaude-accounts), `--account` also names a [vendor account pinning](#vendor-account-pinning-configaccountsjson) entry, so these lines replace upstream's lines about `--account` refusing:

The list is opt-in: without it, every launch, including the single pin above, behaves exactly as before, and `--account` keeps naming a [vendor account registry](#vendor-account-pinning-configaccountsjson) entry; a Claude `--account` with neither the list nor that registry refuses.
Other runners ignore the list, and their `--account` keeps naming a vendor account registry entry, refusing where that registry has no account concept for them; in a home with the list and no `config/accounts.json`, their `--account` refuses because the list applies to Claude workers only.

### Home brief include

In [home brief include](configuration.md#home-brief-include-configbrief-includemd):

A new home's first conversation seeds it with the owner's outward-send house rule, as the owner left it, in worker form ([`first-voyage`](../.agents/skills/first-voyage/SKILL.md)).

### Crew dispatch profiles

In [crew dispatch profiles](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson), this fork ships a Claude-only starting file:

A home that runs Claude only starts from [`docs/examples/crew-dispatch-claude-only.json`](examples/crew-dispatch-claude-only.json) instead, which a new home's first Claude launch installs on its own ([starter settings](#starter-settings-first-launch)).
It is sized for a Claude Pro or Max 5x plan: Opus 5.5 at medium effort for nearly everything, Opus 5.5 at high effort for judgment-heavy planning and diagnosis, Sonnet 5.5 at medium for well-specified mechanical work, and Haiku 5.5 at low for tiny chores with nothing to decide, with no other provider or account assumed.
Extra-high effort is deliberately absent, because a Pro or Max 5x window runs out quickly at that depth; add it to a rule's `effort` on a larger plan.

### Typed dispatch resolution

In [typed dispatch resolution](configuration.md#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model), this fork pins the typesafe.ai model, so these lines replace upstream's two `jev-latest` lines:

With no provider setting and a valid base, the original typesafe.ai behavior is unchanged: the pinned `jev-1.13.0` is used when `TYPESAFE_API_KEY` is available, `FM_DISPATCH_MODEL` is ignored, and the resolver is off when no key is available and no `typesafe` credential source is declared.
Explicit `FM_DISPATCH_PROVIDER=typesafe` also uses the pinned `jev-1.13.0` when no model is set.

The same request also gives scope advice:

When the brief has both sections, the same request also asks one yes/no scope question over the same state: do the build instructions under `## Firstmate spec` add a change the ask under `## Captain's intent` did not need?
An answer of 0.5 or above prints one `scope:` line with the probability, as advice only: it never changes the status, rule, fallback, candidates, or profile.
A brief without both sections is not asked it, and a missing, malformed, or below-0.5 answer prints nothing; an `error` outcome, including an API failure or timeout, never carries a scope line.

The never-send list also covers the [status second look](#status-second-look-configtriage-second-look), so these lines replace upstream's lines about `config/dispatch-never-send`:

The optional local, gitignored `config/dispatch-never-send` keeps values you name from ever leaving the machine in a resolver request or a [status second look](#status-second-look-configtriage-second-look).
List the private words whose tasks must stay local, such as client, finance, or health names; nothing tracked in this repository seeds them.
Like `config/crew-dispatch.json`, it is inherited into secondmate homes, so a secondmate's resolver and second look withhold the same values.

Private projects are never sent:

A project listed in [`config/private-projects`](#private-projects-configprivate-projects) is never sent, with or without a never-send list, matching the [worker command guard](#worker-command-guard-configcommand-guard): when `--project` or the repository named by the brief's scaffolded setup line has a listed logical directory name, the resolver takes the same off path before reading the rules.

#### Private projects (config/private-projects)

The optional local, gitignored `config/private-projects` names projects whose work must never reach an additional outside service, one logical project directory name per line, as the project registry names it; blank lines and lines starting with `#` are ignored.
It has no default entries, and nothing tracked in this repository names a project for it.
The [worker command guard](#worker-command-guard-configcommand-guard), this resolver, the [status second look](#status-second-look-configtriage-second-look) and the [Mothership room's outcome reports](#mothership-monitoring-configmothership-monitor) each treat a listed project as never sent, whatever their own settings say, and a list that is present but not a readable regular file sends nothing.
Like `config/dispatch-never-send`, it is inherited into secondmate homes.

```text
# Projects that never leave this machine
private-app
```

#### Decision record (state/dispatch-decisions.jsonl)

Each resolve that Jev answered appends one JSON line to the home's `state/dispatch-decisions.jsonl`, so the bridge page's Routing section ([`bridge-view.md`](bridge-view.md#routing)) can show recent decisions after the printed answer is gone.
The line holds only the time, the task id taken from the `data/<id>/brief.md` path, the outcome, the rule whose profiles the result drew from (the answer's rule, or `default` when that rule's quota floor falls through) with the start of its `when` text, that rule's probability, and the chosen profile on a `clear` result.
It never holds brief text, quota, or candidate evidence, and the off, no-rules, and pre-answer error paths write nothing.
Writing is best effort: a home without `state/` or a failed write leaves the printed answer and exit status unchanged.
The file is append-only and local; empty it with `: > state/dispatch-decisions.jsonl` to clear the history.
The script header owns the exact line format.

In the installer notes of the same section, these lines replace upstream's confidence-floor line:

- With no provider set, the typesafe.ai model is pinned at `jev-1.13.0`, never an alias, because the floors were measured against that version.
- The default confidence floor remains 0.6 and the scope advice floor 0.5; request timeouts are 5 seconds for typesafe.ai and 10 seconds for OpenRouter, `systemone`, and OpenAI.

### Toolchain

In [Toolchain](configuration.md#toolchain), this fork requires a newer no-mistakes and names the watched instruction paths by their owner, so these lines replace upstream's:

- no-mistakes v1.59.2 or newer.
- When a running home advances and its loaded instruction surface (the paths `changed_instr` in `bin/fm-ff-lib.sh` watches) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.

### Process-to-event sources

In [process-to-event sources](configuration.md#process-to-event-sources-stateprocevent):

`bin/fm-procevent-mothership.sh` is the built-in adapter for [Mothership monitoring](#mothership-monitoring-configmothership-monitor).

### Spoken interface and captain inbox

In [spoken interface and captain inbox](configuration.md#spoken-interface-and-captain-inbox-configvoice--configinbox-), this fork's `bin/fm-inbox.sh` has more subcommands, so this line replaces upstream's opt-in line:

That configuration is the whole opt-in: an unconfigured home cannot start the relay and cannot run `fm-inbox.sh say` or `ask`, while every other subcommand needs no configuration at all because it makes no model call (the `bin/fm-inbox.sh` header owns that list).

### Environment variables

In [environment variables](configuration.md#environment-variables), these lines replace upstream's `FM_TASK_ID`, `TYPESAFE_API_KEY`, and `FM_WATCHER_STARTUP_LOCK_BOUND` lines, and `FM_ARM_START_BOUND` and `FM_ARM_SUSPEND_GAP` are this fork's own:

```sh
FM_TASK_ID=             # internal task-worker marker fm-spawn.sh delivers to ship and scout environments, never set by hand; bin/fm-test-run.sh refuses to execute in the repository primary checkout while it is set, and the native session-start wrappers stay silent
TYPESAFE_API_KEY=       # typesafe dispatch key and test failure cause opt-in, from the environment, .env, or the declared credential source; absent with no provider set means bin/fm-dispatch-resolve.sh is off and bin/fm-test-run.sh prints no cause labels ("Typed dispatch resolution", "Test failure cause")
FM_ARM_START_BOUND=600  # seconds fm-watch-arm keeps waiting for a fresh watcher that is still starting (lock identity and first beacon not both published) past FM_ARM_CONFIRM_TIMEOUT; default the confirmation backstop, never shorter (bin/fm-watch-arm.sh header)
FM_WATCHER_STARTUP_LOCK_BOUND=60   # per-lock startup wait in seconds for downtime publication during singleton steal, the startup captain-input baseline read and startup recovery transitions; later poll-time recovery checks remain blocking; independent of the arm backstop
FM_ARM_SUSPEND_GAP=60   # seconds between two clock reads of an attached fm-watch-arm that mark a host sleep, restarting the followed holder's stall age at the resume (bin/fm-watch-arm.sh header)
```

## Computer use (config/computer-use)

The optional local, gitignored `config/computer-use` presence flag says this home drives macOS app interfaces through the `macos-computer-use` skill.
With it present, that skill is linked in as an opt-in skill (below), and session-start bootstrap checks for the pinned Peekaboo and reports a missing, other-version or broken copy as `MISSING: peekaboo`; installing it still waits for the captain's consent.
With it absent, nothing is checked or reported.
The flag is not inherited by secondmate homes.
`bin/fm-computer-use.sh` owns the pin, the check, the installer and the guard; the skill owns when and how they are used.

## Opt-in skills (config/adhd, config/second-opinion)

A few bundled skills serve one home's own setup rather than every home, so they live in `.agents/opt-in-skills/` and no session lists them until the home switches them on.
Each switch is an optional local, gitignored presence flag; any file at the path turns it on, whatever it holds:

| Skill | Switched on by |
| --- | --- |
| `adhd` and `adhd-auto-fire` ([adhd.md](adhd.md)) | `config/adhd` |
| `second-opinion-auto-fire` ([second-opinion.md](second-opinion.md)) | `config/second-opinion` |
| `macos-computer-use` | `config/computer-use` (above) |
| `intake-digest-lines` and `daily-todo-freshness` | `config/morning-intake` or `config/channel-intake` ([below](#daily-intake-and-to-do-page-configmorning-intake-configchannel-intake)) |
| `meeting-intake` ([meetings.md](meetings.md)) | `config/meetings` ([below](#meeting-intake-configmeetings)) |
| `tap-desk` | `config/tap-desk` ([below](#phone-tap-desk-configtap-desk)) |
| `backport` | `config/backport` ([below](#backport-configbackport)) |

A switched-on skill is linked into `.agents/skills/` under its usual name, so it loads exactly as a tracked skill does, and the link is gitignored.
A harness lists skills when it starts, so a changed switch takes effect from the next launch.
The flags are home-local and are not inherited by secondmate homes.
`bin/fm-opt-in-skills.sh` owns the links and when they are made.

## Private add-on (config/addon)

A home can run its own tools from a separate, usually private repository, its add-on, on top of the shared Starship code, without the two repositories ever merging.
The optional local, gitignored `config/addon` names it:

```text
path = projects/starship-addon
origin = https://github.com/<owner>/starship-addon
```

`path` is the add-on's checkout, absolute, under `~/`, or relative to the home; `origin` is what `bin/fm-addon.sh install` clones when that checkout is missing.
With no `config/addon` a home behaves exactly as it does without add-ons.
The first conversation with a new owner ([`first-voyage`](../.agents/skills/first-voyage/SKILL.md)) gives every home one: `bin/fm-addon.sh create` makes the owner a private repository on their own GitHub account from a minimal starter and writes `config/addon`, and `bin/fm-addon.sh guards` confirms the home cannot publish anything personal by mistake.
A home that already names an add-on, such as a team's, keeps it.
`bin/fm-addon.sh first-project` holds back a home's first project until it has an add-on, and adding a project asks it first, so a new owner's own repository always comes before their first project.

An add-on keeps this repository's layout, so a tool moves between the two by moving its files:

- Every skill in the add-on's `.agents/skills/` is linked into the home's checkout as an opt-in skill is, and replaces an opt-in skill of the same name.
- Hooks in the add-on's `hooks/<point>/` run beside this repository's own built-in `hooks/<point>/`, in name order, and replace a built-in hook of the same name: `bootstrap` adds read-only startup checks, `session-start` adds standing instructions to the session-start digest, `sentinel` names work that keeps the host sentinel watching a home with no task in flight, `watcher` files are sourced into the watcher when it starts, `deck-staging` adds staging runs to the Action Deck, and `todo-admit`, `todo-verbs` and `todo-page` extend the daily to-do page (below).
- A `leak-words` file at the add-on's root adds its words to the home's [private leak words](#private-leak-words-configleak-words), so a private team add-on can carry that team's names to every teammate.

`/updatefirstmate` ("update starship") fast-forwards the add-on from its origin with the same guards as the shared code and relinks its skills, and a remote second mate's home fast-forwards the add-on its own `config/addon` names.
`bin/fm-home-port.sh` carries `config/addon` to another machine, clones the add-on during its one-command handoff, and fails `verify` while the checkout is missing, and `bin/fm-linux-setup.sh --addon <owner>/<repo>` names one on a new Linux machine.
Personal tools that serve one home only, such as glasses tools or device configuration staging, live in that home's own add-on rather than here.
The add-on is never registered automatically: rebuilding the project registry from the clones under `projects/` skips the checkout `bin/fm-addon.sh root` names.
Register the add-on as an ordinary project when workers should change it; that is how an owner builds their own changes into it, and first setup may register a new owner's add-on this way.
The add-on is home-local and is not inherited by secondmate homes, though its `leak-words` list reaches them inside the inherited word list.
`bin/fm-addon.sh` owns the configuration, the hook points and their contract, and the install.

## Update channel (config/update-channel)

The optional local, gitignored `config/update-channel` chooses what "update starship" (`/updatefirstmate`, `bin/fm-update.sh`) moves this home to.
It holds one line, with blank lines and `#` comment lines ignored:

| Value | Effect |
| --- | --- |
| `main` | The default, identical to an absent file: follow the newest merged default branch. |
| `release` | Follow the newest named release, a monthly `starship-YYYY.MM` tag, or `starship-YYYY.MM.N` for a fix release in that month, on the default branch. |
| `starship-YYYY.MM[.N]` | Stay on that one release; stepping back writes this. |

The owner and active contributors stay on `main`; a client or a teammate who does not write code chooses `release`, so changes arrive once a month with notes.
On a release value the update moves the home forward onto that release, never past it, and names the release in its result.
A release named for a month more than one month after the current month is ignored, and a release deleted from origin stops counting on the next update.
An update never moves a home back: a home already past the release, such as a fresh install or one that just switched from `main`, stays where it is and says so until a newer release passes it, and only stepping back goes back.
A dirty home is skipped, and a home with its own changes that are not on the default branch is skipped as diverged and left untouched, exactly as on `main`.
Each release's notes are its section of [CHANGELOG.md](../CHANGELOG.md).
Every local and remote second mate follows the same release as the primary home under the same never-back rule, while the [private add-on](#private-add-on-configaddon) keeps following its own default branch.
A remote second mate's host code root follows the primary home's channel too, `main` or its release, whatever that host's own file says.
A malformed file stops the update before anything moves, and names the file.

To go back one release, say so to the first mate, or run `bin/fm-update.sh --step-back` in `~/starship`.
It moves the home to the previous release, or from a home that is not on a release, to the newest release behind it, and writes that release's name into this file, so later updates stay there; write `release` again to follow new releases.
It refuses on a dirty home, a home with changes that are not on the default branch, a home with no release behind it, and the oldest release.
Step back covers only a home without second mates.
A home with second mates cannot step back; it can stop taking new releases instead by writing the name of the release it is on now, the one "update starship" reports, into this file.

A maintainer cuts a release with `bin/fm-release.sh` after the month's reviewed catch-up has landed on a green default branch; it needs the [maintainer role](configuration.md#firstmate-role-configfirstmate-role) and refuses unless every check on that commit is green.
The file is home-local and is not inherited by secondmate homes.
`bin/fm-release-lib.sh` owns the parsing and the release names and order, and `bin/fm-update.sh --help` and `bin/fm-release.sh --help` own the commands.

## Daily intake and to-do page (config/morning-intake, config/channel-intake)

Starship ships an optional daily intake that is off until a home turns it on.
Its three parts work as one system:

- The morning intake (`bin/fm-morning-intake.sh`) is a once-a-day gate that makes sure the morning read of the captain's channels happens, retries it, and shows a missed morning instead of skipping it.
- The continuous channel intake (`bin/fm-channel-intake.sh`) checks the home's enrolled sources, such as Slack, mail, calendar and Asana, through the day, remembers what it has seen and what the captain still owes, and sends one grouped private alert for anything urgent.
- The daily to-do page (`bin/fm-todo-render.sh`) is rebuilt from those records on every read, with no model call, as a calm front page with a back room behind one link; the front page says when everything was last checked at its source and flags any line that was not, and the back room shows each line's own last check.

Nothing reads, arms or schedules anything until the home's own private, gitignored config switches it on with an `enabled = true` line in `config/morning-intake` or `config/channel-intake`.
Each home names its own sources, with their ids, in its private source inventory (`data/channel-intake/sources.tsv` by default); this repository carries no names, ids or accounts.
`bin/fm-morning-intake.sh --help` and `bin/fm-channel-intake.sh --help` own every configuration key, and [`channel-intake.md`](channel-intake.md) owns the install, the source inventory, the alert recipient check and rollback.
To turn it on:

1. Write `config/morning-intake` and `config/channel-intake` with `enabled = true` and the home's `timezone`, then the source inventory.
2. Arm the live checks and the schedules: `bin/fm-morning-intake.sh arm-check` and `bin/fm-morning-intake-schedule.sh install`, and the same pair for `fm-channel-intake`.
3. Start a new session, so the `intake-digest-lines` and `daily-todo-freshness` skills are linked in.
   Either file being present switches those two skills on, as an opt-in skill (above).

The front page only counts captain-held backlog decisions, as questions asked in chat.
By default the back room folds them into its collapsed "Firstmate tooling approvals" section; a home whose held decisions are genuine calls for its owner, such as business calls, plans or purchases, adds `held_decisions_need_you = true` to `config/channel-intake` to list them in the back room's "Needs you now" instead, while approvals about Firstmate's own tooling keep their fold, and `bin/fm-todo-render.sh --help` owns how the page draws that line.
The front page heads the open asks that are not from a partner or customer "Waiting on you"; a work home adds `colleague_headings = true` to `config/channel-intake` to head them "Colleagues asking you" instead; the default is "Waiting on you", so a work home that already shows "Colleagues asking you" adds that line after updating to keep it.
The intakes print their state into the session-start digest through the built-in `hooks/bootstrap/10-morning-intake` and `hooks/bootstrap/20-channel-intake`, and stay silent on a home that has not opted in.
A home whose private add-on (above) carries same-named tools, hooks or skills keeps running the add-on's: its hooks and skills replace the built-in ones, and a schedule or live check it armed names its own scripts.
An add-on can also extend the to-do page without carrying its own copy: a `todo-admit` hook refuses a new ask the home never puts on the page, such as an announcement, a `todo-verbs` hook takes more verbs typed on a row, such as changes to a ticket the row names, moves the row with `bin/fm-todo.sh close` or `hand-over` and marks it with `bin/fm-todo.sh mark`, and a `todo-page` hook adds a section of its own; `bin/fm-channel-intake.sh --help`, `bin/fm-todo.sh --help` and `bin/fm-todo-render.sh --help` own those contracts.
An optional `config/todo-about` holds one `name regex` line per pattern, such as a device id or ticket number shape, whose matches in a line's words say what it is about, so a new ask about an open line joins it; `bin/fm-todo.sh --help` owns the matching.
The configuration and records are home-local and are not inherited by secondmate homes.

## Captain ledger (config/captain-ledger)

The optional local, gitignored `config/captain-ledger` presence flag opts this home into the captain ledger: a Claude prompt-submit hook that writes every prompt the lock-holding primary receives into `data/captain-ledger.jsonl` before the model answers, and a session-start section that lists unreconciled words until an agent marks them.
With it absent, the hook records nothing, so a fresh clone never writes a prompt to disk on its own.
Words a ledger already holds still print and can still be marked with the flag removed.
The flag is not inherited by secondmate homes.
`bin/fm-captain-ledger.sh` owns the record format, the filters, and the reconciliation commands.

## Mothership monitoring (config/mothership-monitor)

Mothership monitoring wakes the first mate within about a minute when something new for this Starship arrives in a Mothership room it has joined: a request to the ship, an answer to the ship's question, a message to the ship, or a change on a card the ship is on.
It is off by default and switched per room in the home's private, gitignored `config/mothership-monitor`, one `<room> = on` or `<room> = off` line per room, using the room name that `mothership rooms` lists:

```text
# A room switched on here wakes the first mate on new requests, answers and messages.
alpha = on
beta = off
```

- A room not listed, or the file absent, is off; with no file and nothing registered, nothing runs and no state is created.
- Any other line is reported as a `MOTHERSHIP_MONITOR:` line at session start and treated as off, so a malformed file never switches a room on.
- `bin/fm-procevent-mothership.sh on <room>` and `off <room>` switch a room and write the file, and the owner can simply ask the first mate to do it; `status` shows each room.
- `on` refuses a room this Starship has not joined, a Mothership link too old to keep a separate place in the room, with "update the Mothership link first", and a link that does not answer within 20 seconds.
- Session start runs the adapter's `ensure`, which arms each `on` room that is not listening and retires each room that is now off or no longer listed, so an edit by hand takes effect at the next session start; a room the link does not answer for within 20 seconds is reported as a `MOTHERSHIP_MONITOR:` line instead of holding session start, and is tried again at the next one.

Each switched-on room is one built-in [process-event source](configuration.md#process-to-event-sources-stateprocevent) that long-polls the room with `mothership pull --from <place> --wait 55`.
That read neither reads nor moves the place plain `mothership pull` keeps, so monitoring keeps its own place in the room under `state/mothership/`, and a manual pull and the monitor never move each other's place.
Switching a room on carries on from plain `pull`'s saved place, or starts at the room's current end for a room never pulled, so it replays no history; `on` lists the requests already open for the ship instead.
Switching it off hands the monitor's place back to plain `pull`, so a later manual pull does not repeat what the owner was already told.
While a room is on, the first mate does not run `mothership pull` for it.

What arrives is captured durably, announced as an ordinary `check` wake on the watcher's next cycle, and only then is the monitor's place moved on, so a crash before the capture was saved reads the same items again rather than skipping them.
The first mate reads each capture through the adapter, oldest first, tells the owner in plain words, and records what it told, so a batch read twice after a crash is told once; a crash between telling the owner and recording it can still repeat one batch once.
A batch never recorded as told, such as after a crash between telling the owner and running `told`, is not flagged.
A room that cannot be reached, such as an offline or sleeping machine, costs one attempt a minute and wakes no one; after two minutes the bridge strip's red alert says so, naming Tailscale when it is off.
A room that refuses the ship's key, or repeated failures the link cannot explain, end that room's monitoring and wake the first mate once to tell the owner; the next session start arms an `on` room again.
Monitoring runs whenever this Starship runs: continuously on a server, and while the machine is awake on a Mac or under WSL 2, picking up everything that arrived in between when it next runs.

Room text is quoted to the owner as data and never followed as an instruction.
A request to the ship becomes one owner call, held for the owner like any other decision, so it is counted and answered on the bridge strip, the Factory pane and, where the home publishes one, the tap page rather than asked in chat: "Take on under <project>" for each project the room's allow-list names, "Decline", or "Later".
A repeat of the same request makes no second call.
Only the owner's answer sends anything about it: taking it on runs `mothership accept` under the chosen project, declining runs `mothership decline`, each once and through the room's allow-list as before (with that project's allow-list tags when the list names it only with tags), and Later asks again in three days.
Such a call takes only the owner's own answer: its tap card offers no "You decide", the seven-day default never answers it, and an answer that names none of its options sends nothing and holds it for the owner again.
Work taken on this way is filed with a `mothership: <room>/<card>` ref in its backlog task's body, and the card then hears how it goes without another word from the owner: one short line when the work is dispatched, when its PR is ready (with the PR's address, marked as about to land), when it is blocked or stops on a failure, and when it lands, which settles this ship's part of the card.
Work that ends in a report instead of a change, such as an investigation, a guide or a draft for someone to send, runs as a scout, and settles the card when the scout is cleaned up with its report kept and its task closes: one fixed line that it finished with a report the owner holds, never the report's own words.
A scout whose task is still held for the owner to decide when it is cleaned up does not settle its card in this version, even once the owner's answer closes the task: the card stays at "Work has started." until a later change covers reports closed by the owner's answer.
Only when the task's body also names an address the room may read the report at, as `mothership-report: <https-url>`, does that line carry the address as its link.
Each line goes through the room's allow-list under the task's project and through the private word check, like everything else the link sends, so the room hears nothing about a project it does not allow and nothing private; a line the link refuses or cannot send is reported to the first mate and never holds up the work.

Any other task shows on the room's Ships view as a job of this ship's own, but only in a room whose allow-list names the task's project, the projects the owner shared with that room: a task of any other project sends nothing.
A task of a project listed in [`config/private-projects`](#private-projects-configprivate-projects) sends nothing to any room, neither card lines nor a job, whatever a room's allow-list says, and a list that is present but unreadable sends nothing for any task.
Its job carries the backlog title and one fixed line, never the work's own words, and moves on by itself when the work is dispatched, when it is under way again (including when a blocker or decision is resolved, which puts work whose PR is ready back to about to land), waits on a decision, is blocked or stops on a failure, when its PR is ready (about to land), and when it lands; a task cleaned up without landing is taken off the view.
Like a card's lines, each send goes through the allow-list and the word check, and one that does not get through is reported to the first mate and never holds up the work.
This needs a Mothership link and nothing else, so it works whether or not monitoring is on; a home with no link config and no Mothership state runs none of it.
Beyond these, the only thing monitoring sends to a room is the "read by your ship" mark that every `mothership pull` already sends in a room whose allow-list is not empty.
The setting and its records are home-local and are not inherited by secondmate homes.
`bin/fm-procevent-mothership.sh --help` owns the commands, the result document and the private state files, and the `process-event-sources` skill owns how the first mate relays a capture.

## Status second look (config/triage-second-look)

An opt-in, per-home and per-device second look over the status lines the deterministic wake classifier has already dropped, run only at the two heartbeat backstops.
It ships inert: with no `enabled = true` line in the private gitignored `config/triage-second-look`, no call is made and supervision behaves exactly as it does without it, so cloning this repo, seeding a secondmate home, or adding a device never starts making paid calls.
The gate is deliberately not inherited into secondmate homes for the same reason.

**The gap it closes.** Firstmate decides what is captain-relevant from a status line's leading verb ([`../bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh)).
That is deliberately verb-aware and correctly refuses to be fooled by prose, but a verb test cannot read a sentence.
A worker that writes `working: the backfill migration truncated public.users on staging; 4100 rows gone` is dropped permanently by every caller, and the heartbeat backstop does not save it either, because that backstop re-checks for captain-relevant events a later append moved past and this line was never captain-relevant by the only definition the code has.
This is a silence failure, and it is worst in away mode, where nobody is watching the pane and hours pass.

**Escalate-only, and that is the whole safety argument.**
The pass receives only lines the shipped classifier already dropped, and the only thing it can emit is a promotion.
There is no output that silences a line, so neither a model answer nor text a worker writes into a status line can suppress an escalation Firstmate would otherwise make; the worst a hostile status line can achieve is one extra line in a digest.
That containment is structural and does not depend on the model reading any particular line correctly.

**Fail-open to today.** No key, no `python3`, a timeout, a rate limit, a malformed body: each prints nothing and supervision is unchanged.
"The second look is down" and "the second look was never built" are the same state.

**Where it runs.** The two heartbeat backstops only, never the per-wake path, which must stay cheap and work offline: the always-on watcher's fleet scan ([`../bin/fm-watch.sh`](../bin/fm-watch.sh)) and the away-mode daemon's catch-all scan ([`../bin/fm-supervise-daemon.sh`](../bin/fm-supervise-daemon.sh)).
Each scan makes at most one request, never one request per line, covering every dropped line it found up to a fixed batch bound the engine pins; a scan carrying more than that looks at the newest lines, because a status log is append-only and the tail is what just happened.
Batching is a security property as well as the cheaper shape: a status line arguing for its own escalation measurably wins when evaluated alone and measurably loses when evaluated beside its peers, and it is also cheaper and faster.
Both margins were measured by the 2026-09-17 probe, which asked a richer request than the line-only one this home now sends; the verification page linked at the end of this section owns those numbers and says what has not been re-measured since.

**What a promotion does.** In the always-on watcher a promotion rides in that heartbeat's wake payload, which names each promoted line and why it was raised.
A heartbeat that would otherwise have been absorbed becomes an ordinary heartbeat wake instead, and one whose scan already found captain-relevant work wakes as it would have anyway, carrying the promoted lines with it.
In the away-mode daemon a promotion joins the escalation buffer with the same reason; when any promotion in a scan is one the model is both confident about and rates as interrupting, the buffer is flushed once after every promotion from that scan has joined it, so one scan delivers one digest however many lines it promoted.
That flush is the same delivery a zero-batch setting uses and preserves the buffer if the injection cannot be confirmed.
Low model confidence only ever demotes an interrupt to the next batch; it can never silence a promotion.

**Cost.** At most about 516 input tokens per dropped line: that is the 2026-09-17 measurement, taken before the request was narrowed to the line alone.
A scan carrying five new dropped lines is roughly $0.0001, and a busy home polling all day stays under $1 a month against three orders of magnitude of rate-limit headroom.
Most scans carry zero or one new dropped line.

Configuration is `key = value` lines and the only key is `enabled`.
Unlike `config/speak`, a malformed gate file reports on stderr and leaves this home inert rather than exiting loudly, because the caller is a supervision loop and a config typo must never change what that loop does.
`TYPESAFE_API_KEY` is read from the environment, else from this home's gitignored `.env`, and never appears in argv, stdout, stderr or any state file.
The dropped status line itself is the whole of what leaves this machine: the task's brief, its worker kind and its earlier status lines are never sent, so arming this gate does not ship a brief's client names, hostnames or unreleased plans to a third party.
A line from a task whose recorded project is listed in [`config/private-projects`](#private-projects-configprivate-projects), or one carrying a value from the [never-send list](configuration.md#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model), is left out before the request is built and is never promoted; a list that is present but unreadable withholds the whole scan.
The model is pinned to an exact version rather than an alias because the thresholds were tuned against that version.
[`../bin/fm-triage-second-look.sh`](../bin/fm-triage-second-look.sh)'s header and `--help` own the exact invocation, the environment overrides and the exit codes, and its engine owns the request shape, the four questions, the batch bound, the thresholds and the tier rule.
The tool reads its batch on stdin as `<task-id>` TAB `<status line>` records, one per line, so feed it one to read the exact request a scan would send:
`printf 'my-task\tworking: the backfill migration truncated public.users\n' | bin/fm-triage-second-look.sh --dry-run`.
Dated live evidence is in [`verification/triage-second-look.md`](verification/triage-second-look.md).

## Worker command guard (config/command-guard)

An opt-in, per-home check that runs before each shell command a spawned Claude worker (crewmate or scout) makes.
A local database deny list checks the command first, then TypeSafe's Jev judges it, and the command is blocked when it would change a live database, when it would remove, overwrite or send something with no way back, when it aims to wipe something, or when it carries text aimed at the judge itself.
The primary and secondmates are never guarded, and nor is any other worker harness.

It ships off.
With no `enabled = true` line in the private gitignored `config/command-guard`, `bin/fm-spawn.sh` installs nothing and no command leaves this machine.
The gate is not inherited into secondmate homes, so seeding a home or adding a device never starts sending worker commands anywhere.

```
enabled = true
exclude = private-client-app, family-notes
```

A project listed in [`config/private-projects`](#private-projects-configprivate-projects) is always excluded: its commands are never sent to an additional outside service such as Jev, whatever this file says, and a list that is present but unreadable sends nothing for any project.
`exclude` covers the rest, naming other project directories whose commands are never sent, separated by spaces or commas.
Excluded and private projects still get the local database list, because it sends nothing.
Both match the project's logical directory name, the name the project registry uses, even when that directory is a link to a differently named copy.
List every other project whose code or commands must not reach a third party.
Any other key or a malformed value leaves the guard off at spawn, and the spawn prints why.

**How it runs.** When the gate is on, `fm-spawn.sh` adds a Claude Code `PreToolUse` hook on `Bash` to the worker's own `.claude/settings.local.json`, beside its lifecycle hooks.
The hook reads the same gate again on every command, so switching it off or excluding a project takes effect at once, while switching it on reaches workers spawned or relaunched after the change.

**Local database list.** Before anything is sent, the hook matches the whole command, heredoc and `-c` bodies included, against a fixed list and blocks a match outright.
The list covers `prisma migrate dev` or `reset`, `prisma migrate diff` with `--shadow-database-url` or `--from-migrations`, a shadow database set on the command line, `prisma db push`, `drizzle-kit push` or `drop`, `supabase db push`, `db reset`, `migration repair`, `link`, `projects delete` or `branches delete` unless `--local` is set with no `--linked`, `--db-url` or `--project-ref`, Supabase Management API database queries and login-role calls, `DROP TABLE`, `SCHEMA` or `DATABASE`, `TRUNCATE` or a `DELETE FROM` with no `WHERE` in a `psql` or `sqlite3` command, `railway volume`, `down`, `delete`, `ssh` or `run`, and `vercel env rm` or `pull`.
The deny names the rule that fired and tells the worker to report the exact change to firstmate as a blocker, because workers never change a live database.
Nothing remote is involved, so this list never steps aside: it holds when Jev is down or no key is set, a crash in the check blocks, and a gate that turns malformed after the hook is installed stops only the Jev call while the list keeps blocking.
It matches text, not shell syntax, so a command that only mentions one of these, such as a search or a commit message, is blocked too; a script that runs one of them under another name is not seen.
Each command is one request of three questions, asked in this order: whether the command contains text addressed to the judge, whether its effect is read-only, reversible or irreversible, and whether it aims to remove or wipe something.
A redacted command longer than 2,000 characters is cut into overlapping parts of at most 2,000 characters, and the same request carries every part and asks the three questions of each, so every part of the command is judged.
Any one condition in any part blocks: text aimed at the judge at 0.8, irreversible at 0.6 confidence, or destructive intent at 0.7.
If that multi-part request fails (a timeout, an HTTP error or an unusable answer), the guard asks once more about the first 1,500 and last 500 characters alone before it steps aside, so a long command is never judged on less than that.
A command that needs more than 8 parts is not judged: it is allowed, and a warning goes to stderr and to `state/command-guard.log`.
A Jev block reaches the worker as a denied tool call whose reason names the condition and says the block is final, not to work around it, and to report it to firstmate as a blocked status line.
To let one blocked command through, switch the gate off, have the worker run it, then switch the gate back on; this switches the local list off too.

**What leaves the machine.** Only the command text, never the working directory, the task or the environment.
Redaction is best-effort: it removes `.env` values and secret-looking environment values of at least six characters, plus shorter nonempty values from secret-named `.env` keys at token boundaries.
It also replaces known key and token shapes, whole quoted or unquoted credential arguments, credentialed URLs and private-key blocks; a `NAME=value` assignment loses its value when the name looks secret (key, token, secret, password, auth and the like) or the value looks random.
These rules match text patterns, not shell syntax, so a quote after a credential name is read as the start of its value wherever it appears; redaction never skips or blocks a command, and every command is judged with whatever the rules removed.
Plain values such as paths, `env=prod` or `of=/dev/disk2` stay visible, so the judge can see what `T=../sibling-copy; rm -rf "$T"` removes.

**Jev steps aside on failure.** No key, a timeout, an HTTP error, an unreadable answer or a crash before Jev's verdict all allow a command the local list did not block, a multi-part command only once its head-and-tail request has failed too.
A single-part request is bounded at 4 seconds (`FM_COMMAND_GUARD_TIMEOUT`) and a multi-part one at 6 seconds (`FM_COMMAND_GUARD_MULTIPART_TIMEOUT`), and the whole hook at the sum of both plus 3 seconds.
A block is emitted before any logging, which then gets at most one more second, so a failure or timeout while logging never turns a block into an allow.
The first failure of an episode is written once to `state/command-guard.log` and to stderr, and the next good answer ends the episode.
`TYPESAFE_API_KEY` is read from the environment, else from this home's `.env`, and never appears in argv, output or the log.

**One signal among several.** The guard judges the whole command, heredoc bodies and redirections included, up to the 8-part cap, because the design it borrows from saw an agent route around a write-only file gate by writing the same file through a shell heredoc.
Known limit: only the Bash tool is judged, so a script written with the Write or Edit tool and then run as `bash x.sh` is judged only by that short command, not by the script's contents.
Known limit: the judge sees only the command text, so a target held in a secret-named variable, set by an earlier command, or read from a file or another program's output is judged by its name alone.
The guard is a best-effort advisory layer and does not try to close every way of hiding intent from the judge.
It is still an extra check on a worker that already runs in a disposable copy under supervision, not a sandbox.

**Log and benchmark.** Every Jev decision and every local block is one JSON line in `state/command-guard.log` with the redacted command, the answers, the outcome and the `path` that decided it (`local`, `whole`, `parts` or `head-and-tail`), rotated at 2 MB.
`python3 bin/fm-command-guard.py bench tests/fixtures/command-guard/benchmark.json` runs the labelled command set through the local list and then live, one request per command the list did not block, as the hook sends it, and prints each verdict and the agreement.
Grow that set when a real block or a real miss teaches something, and rerun it after changing a question, a threshold or the pinned model.
The engine's header owns the exact invocation, questions, criteria, thresholds and redaction, and dated results are in [`verification/command-guard.md`](verification/command-guard.md).

## Worker outward actions (config/outward-permissions)

A check that runs before a spawned Claude worker (crewmate or scout) uses a claude.ai connector, such as Gmail, Google Calendar, Drive, Zapier or Claude Docs, or the Claude in Chrome tools that control the captain's browser.
Anything that acts outward is refused unless this job or this home allows it, so no worker sends, replies, forwards, answers or changes a calendar event, shares, trashes, runs a Zapier action or opens a URL, clicks or types in the captain's browser without the captain's word.
Reading, searching, listing and creating or updating drafts always pass, and so does reading a page already open in the browser and moving between its tabs.

It is on in every home by default.
With no `config/outward-permissions` file, every worker can read and draft but cannot act outward.
The primary, secondmates, other worker harnesses and every other tool, including Bash and locally configured MCP servers, are not checked.

**What counts as outward.** The check reads only the tool name, so it keeps working as connectors add tools.
An action passes without permission only when its name, after a first word that repeats the connector's own name and does not itself read or draft (the last word of its server name, so `slack_read_channel` on Slack counts as `read_channel`), starts with a reading word (get, list, search, read, query, find, fetch, suggest, guide, export, download, view, count, describe, lookup), creates or updates a draft, or, in the browser, lists, opens or switches tabs, resizes the window, or records a GIF, and none of its words is an outward word such as send, reply, forward, share, publish, post, delete, trash, accept, decline or respond.
Every other action of a claude.ai connector or the browser needs a permission, and every Zapier tool is treated as an action.
Opening a URL in the browser needs `control browser`, because a link in the captain's logged-in browser can itself answer an invite, unsubscribe or submit a form.

**Permissions.** A permission is one line of plain words:

| Permission | Allows |
| --- | --- |
| `send email` | sending, replying to and forwarding mail |
| `send email to <addresses>` | the same, only when every recipient is listed |
| `reply to email` | only replies |
| `respond to invites [from <addresses>]` | answering calendar invites, optionally only from those organizers |
| `accept invites [from <addresses>]`, `decline invites [from <addresses>]` | only that answer |
| `change calendar` | creating, updating and deleting calendar events |
| `organise mail` | labels, trash, spam and other mailbox changes |
| `control browser` | opening URLs, clicking, typing, form input, scripts and uploads in the captain's browser |
| `use zapier` | every Zapier tool |
| `use <tool name or glob>` | exactly the named connector tools, for example `use mcp__claude_ai_Zapier_MCP__*` |

Addresses are full email addresses or `@domain` for everyone at that domain, separated by commas, spaces or `and`; names such as "the design team" are not understood.
`send email to` holds only when the recipients are visible in the request: a reply needs an explicit `to`, a reply-all also an explicit `cc`, and a draft sent by its id never shows its recipients, so only plain `send email` covers it.
Each `to`, `cc` and `bcc` entry must be exactly one plain address such as `ana@example.com`; an entry with a display name, angle brackets, a comma or a space cannot be confirmed, so `send email to` does not cover the send.
`invites from` holds only for an event the worker has read in the same job, because a hook records each event's organizer from the calendar connector's answer to `get_event`, `list_events` or `search_events`.

**Per job.** When the captain hands over a job that must act outward, pass the permission to both `bin/fm-brief.sh` and `bin/fm-spawn.sh` as `--outward '<permission>[; <permission>...]'`.
The brief shows it on its `Outward permission:` line, the spawn refuses a value that differs from the brief, and the task record keeps it as `outward=`.
It holds for that task only, including after a relaunch.
`bin/fm-outward-grant.sh <task-id> '<permission>'` adds a permission to a running task when the captain allows it mid-job, without a relaunch.

**Standing permissions.** The private gitignored `config/outward-permissions` lists permissions for routine work, one per line, that every worker in the home gets:

```
# Team invites and the weekly update
accept invites from @example.com
send email to team@example.com
```

Blank lines and `#` comments are ignored.
A line the check does not understand allows nothing; refusals name it, and `python3 bin/fm-outward-check.py check-config --config config` lists every such line.

**Outward styles.** The home runs in one of three styles, which the captain switches with `/outward-fine-print`, `/outward-broad` and `/outward-no-block`, each running `bin/fm-outward-style.sh`:

| Style | What a worker may do outward |
| --- | --- |
| fine print (the default) | only what its job's permission or a standing permission allows |
| broad switches | also every action of each switch that is on: `send email`, `reply to email`, `respond to invites`, `change calendar`, `control browser`, `use zapier` |
| no block | anything; the check is off for every worker in the home |

The script keeps the style as a `style` line in `config/outward-permissions`, and the broad switches as `broad <switch>` lines that allow nothing in any other style.
A switch never removes the other lines, so going back to fine print restores exactly the standing permissions there were.
`/outward-broad` with no switches keeps the ones chosen before; the first time it turns no switch on and asks which to allow.
Naming switches, such as `/outward-broad send email, control browser`, turns on exactly those.
The script takes only the exact style words `fine-print`, `broad` and `no-block` and the exact switch names above, comma-separated.
`bin/fm-outward-style.sh show` prints one line such as `Outward: fine print` for any surface that shows the style in force.
An older bare `no block` line still means no block, and lines naming two different styles leave fine print and are named in refusals.

The check reads the file on every connector or browser action, so a change, including a style switch, takes effect at once without a relaunch.
The file is not inherited into secondmate homes.

**How it runs.** `bin/fm-spawn.sh` adds a Claude Code `PreToolUse` hook on `mcp__claude_ai_.*|mcp__claude-in-chrome__.*` and a `PostToolUse` hook on `mcp__claude_ai_.*` to every Claude crewmate and scout's `.claude/settings.local.json`, beside its lifecycle hooks.
A refusal reaches the worker as a denied tool call that names the tool, what it would have done and any permission that came close, says that reading and drafting still work, tells the worker not to retry or route around it but to report a `blocked:` status line, and names the permission that would allow it.
It never shows the grant command, the permissions file or any other path, so the worker reports the permission and only the captain, through Firstmate, decides whether to give it.
Any failure inside the check refuses the action, and a check that cannot run at all, such as when `python3` is missing, refuses too.
Every refusal and every outward action a permission, a broad switch or no block let through is one JSON line in `state/outward-check.log` naming the task, tool, decision and deciding permission, never the message or event contents.
[`bin/fm-outward-check.py`](../bin/fm-outward-check.py)'s header owns the matching rules, and dated live results are in [`verification/outward-check.md`](verification/outward-check.md).

## Address and tone

How the first mate speaks to the person is recorded only as a `## Address and tone` section in the home's own `data/captain.md`; a section in `data/captain-shared.md` is not read for it.

```markdown
## Address and tone
- Call me: Partner
- Tone: warm and playful, like a close friend, still clear underneath
- Emoji: yes, a few per reply
- Length: short
- No-news reply: All good, Partner! ✨
```

Every bullet is optional free text, and a bullet that reads "keep the defaults" counts as absent.
`Call me:` replaces "captain" as the direct address, and `No-news reply:` replaces the routine no-news reply, which is otherwise `<Call me>, shipshape.` (`Captain, shipshape.` with no `Call me:`).
The recorded tone, emoji use, and length govern every other chat reply from the first message of every session, including short confirmations, bad news, and technical updates; the plain-language, outcome-first, and safety rules in [`AGENTS.md`](../AGENTS.md) stay in force.
The no-news reply is used verbatim as recorded, never reworded to fit the tone or emoji preferences.
A new owner's first conversation asks for it as its first question ([`first-voyage`](../.agents/skills/first-voyage/SKILL.md)).
Otherwise, in a primary home with no section, the first mate moves any address or tone preferences already written elsewhere in `data/captain.md` into this section, asks once early in the session only for what is still missing, and records the answer in that section, even when the answer is to keep the defaults; until then it uses the default "captain" address and house style.
The person changes it any time by saying so, and the first mate updates this section.
`bin/fm-session-start.sh` prints the section's first 15 non-blank lines, or in a primary home without one that is not cued for its first voyage the cue to ask, at the very top of the session-start digest, so it reaches the first reply even when the harness shows only a short preview of a large digest.
On a home with [desk voice-out](#desk-voice-out-configspeak), `bin/fm-claude-reply-speak.sh` reads `Call me:` and `No-news reply:` so the routine reply stays silent and its spoken notices use the recorded address.

## Startup digest trim (config/startup-digest-trim)

The optional local, gitignored `config/startup-digest-trim` presence flag opts this home into a default-off, shorter session-start digest.
With it present, the held part of the backlog listing prints counts by hold kind plus only the held items that need a look now: items that gate in-flight work, items whose recorded hold date has come, and items that are new or changed since the previous digest; items that stopped being held since then are named, and one line gives the command for the full held list.
Drift and upstream lines that the bootstrap part already printed are also not repeated under the network checks.

With the flag absent the digest is unchanged.
Only a session start that holds the fleet lock updates the record of what the previous digest showed, and a read-only session compares against that record without updating it.
The digest reprinted after a context compaction compares against the same earlier record the session start compared against, without updating anything, so held changes shown at start are shown again after a compaction.
With no such record yet, every held item is shown once.
Only the recorded hold date counts as a date, not dates written inside a hold reason.
The flag is a home-local preference and is not inherited by secondmate homes.
[`bin/fm-session-start.sh`](../bin/fm-session-start.sh)'s header owns the exact rules.

## Factory registry (data/factories.md)

The optional local `data/factories.md` names this home's factories for the [Factory pane](factory-pane.md).
Without it, every project in `data/projects.md` is its own factory, named by its `label=` token or its display name.

Each factory is one `## <name>` heading followed by optional fields, one per line, and two optional lists:

```markdown
## Sample Shop
id: sample-shop
about: online shop for handmade cups
projects: sample-shop, shop-api

Rules:
- English only.

Learned:
- 2026-11-12: Search results read better with the price on the first line.
```

- `id` is the factory's stable name in the record and the pane's own records; it defaults to the heading turned into lowercase words joined by dashes.
- `projects` maps work to the factory by each work item's project, as registered in `data/projects.md`, an `alias=` included; work no factory claims shows under `Other work`.
  A factory with no code project lists the project word its work items use in its `projects:` line.
- `Rules:` and `Learned:` are what the factory page shows under its rules and what it has learned lately; a learned line may start with its date.
- `Rules:` is also the factory's profile, such as domain rules, known traps and how its tests run: when a factory has rules, `bin/fm-brief.sh` ends every ship and scout brief for a project that factory claims, by the same mapping, with a `# Factory profile (private context, never quote)` section holding them in file order, never its `Learned:` lines, under a line saying every other section of the brief, the home additions included, wins on any conflict and a line forbidding copying the text into PR text, commit messages or the no-mistakes intent.
  A profile adds instructions only: it chooses no model or effort and grants no permission.
  Rules over 1,500 characters, counted as their `- ` lines, are left out whole with a warning naming the factory, and no registry, no claiming factory or no rules leaves the brief unchanged.
  The factory page shows that size against the cap under its rules, marked from nine tenths of the cap and said plainly to be left out over it.

The registry is per home: second mate seeding and inherited configuration never copy it, so a profile reaches only this home's own briefs.
In this fork the profile comes after the [home brief additions](configuration.md#home-brief-include-configbrief-includemd) as the brief's last section: the additions defer to every other section of the brief except the profile, and the profile defers to them.

## Night shift window (config/night-shift-window)

The optional local `config/night-shift-window` names the hours a home runs its night shift, as one line of local time, start and end:

```text
23:30-07:00
```

An end at or before the start is on the next day.
The [bridge strip](bridge-strip.md#what-it-shows) reads it to say when the night shift starts, that it is on, and in the morning how much finished in it.
Without the file, or with a line of any other shape, the strip shows no night shift.
`fm_night_shift_window` in `bin/fm-fleet-status-lib.sh` owns how the window and its evening and morning are read.

## Desk layout (config/desk-layout)

The optional local `config/desk-layout` is what the [desk](desk.md) command `starship` opens; without it, `starship` opens nothing and points at `onboard-starship`, which opens a new desk at once and ends by writing a starter one.
`starship layout` prints the running session in this format as a starting file, and `starship layout --save` writes it to `config/desk-layout` only once the reading succeeded.
One setting per line as `key = value`; blank lines and lines starting with `#` are ignored, and an unknown key or a bad value stops the command with its line number.

```text
workspace = starship
main = Bridge
sidebar = collapsed
terminal = Terminal
firstmate = firstmate claude-opus
tab = Sample Shop | factory sample-shop
tab = Recipe Box | factory recipe-box
tab = Scratch
view = Clear Dark | 14
view = Pro | 10
```

The desk always opens Herdr's default session.

- `workspace` is the label of the workspace the desk fills in, `starship` unless set.
- `main` is the label of the main tab, the one holding the first mate, the bridge strip and the Factory pane, which the desk always shows; without it, or when no tab carries that label, the main tab is the workspace's first tab.
  The desk never renames a tab that exists; it gives the label only to the first tab of a workspace it creates itself.
- `sidebar` is `collapsed` or `open`; when set, the desk writes Herdr's `[ui] sidebar_start_collapsed` to match, and leaves Herdr's config alone otherwise.
- `firstmate` is the command typed into the main tab's idle first-mate pane; without it the desk only notes an idle pane.
- Each `tab` line names one tab besides the main tab, in order; `| factory <id>` makes it that factory's page, by its id in the [factory registry](#factory-registry-datafactoriesmd), and a tab without it is a plain shell.
  A factory tab is named after the factory in the registry; the desk finds it by the tab the Factory pane recorded for it, else by the label.
- `terminal` is the app the views open in, `Terminal` (the default) or `Ghostty`; pick Ghostty where Terminal cannot show 24-bit color, as on macOS before 26.
- Each `view` line is one window: a Terminal profile name, then optionally `| <font size>`; an empty profile name uses Terminal's default, and Ghostty uses only the font size, as in `view = | 13`.

## Factory pane kept hidden (config/factory-pane)

The optional local `config/factory-pane` keeps the [Factory pane](factory-pane.md#hide-it-and-bring-it-back) out of the desk when its first word is `hidden`; anything else, or no file, shows it.
`bin/fm-factory-pane.sh hide` and the pane's `h` key write it, and `bin/fm-factory-pane.sh show` and the bridge strip's `+ Factories` remove it; you do not need to edit it by hand.
The web page keeps its own choice for Factories ([web.md](web.md#hiding-factories)).

## Claude concise prompt (config/claude-concise-prompt)

The optional local, gitignored `config/claude-concise-prompt` opts Claude task workers into a concise-communication system prompt.
Its aim is fewer output tokens and less scope creep from Claude workers.
The token is the file's whitespace-trimmed content.

| Token | Claude ship and scout launches |
| --- | --- |
| `off` | unchanged |
| `on` | [`docs/worker-prompts/claude-concise.md`](worker-prompts/claude-concise.md) appended to the task-worker system prompt |

An absent file means off, so an unconfigured home launches byte-for-byte as before.
With `on`, the prompt joins the existing task-worker `--append-system-prompt` statement after a blank line; the pane reads the tracked file at launch.
The prompt changes only how a worker writes: it defers to the launch brief, its status protocol, its Definition of done, and the no-mistakes gate instructions wherever they require a format or a step.
Claude secondmates, raw launch commands, and every other harness are unaffected.

Any other value, an unreadable file, or a missing prompt file refuses every spawn from that home before any endpoint, worktree, or task record exists.
`bin/fm-spawn.sh` reads the file on every spawn and relaunch, so a change takes effect at the next launch.
The file is not inherited into secondmate homes; set it in each home whose Claude workers should use it.

## Test failure cause (.env TYPESAFE_API_KEY)

When a `bin/fm-test-run.sh` run ends with failures, the runner asks typesafe.ai's Jev model in one request why each failing script failed and prints an advisory `FM_TEST_FAILURE_CAUSE` line per failure: `code-bug`, `test-out-of-date`, `environment`, or `unclear` when the model's confidence is under 0.6.
The labels are hints for whoever reads the failure and never change the run's exit status.
The same key turns it on: `TYPESAFE_API_KEY` from the environment, else from `$FM_HOME/.env`, where the runner defaults `FM_HOME` to its own repository root, so a run in a disposable task copy with neither stays silent.
With no key, no `python3`, a timeout, or an answer it cannot read, it prints nothing at all and the run reads exactly as it does without it.
CI holds no key, so it only ever runs locally.

What leaves the machine is each failing script's path and output tail and this repository's tracked diff against the `--base` merge base, trimmed to fit the model's window, with the captain-private paths excluded even if a fork tracks them and any copy of the key replaced.
The whole request, the state and one question per failure, is sized to fit that window.
Every failure in the run is labelled: the failures and their questions share one budget, so each output tail shrinks as the failure count grows.
Only a run with more failures than that budget can describe, a few dozen, leaves the last ones in run order out of the request, and each of those still gets a visible `FM_TEST_FAILURE_CAUSE script=<path> cause=not-labelled reason=over-size-limit` line beside the labels.
The runner's header owns when it runs and its marker; [`../bin/fm-test-failure-cause.py`](../bin/fm-test-failure-cause.py) owns the request, the pinned model version, the floor, the size bounds, and its environment overrides, and its `--dry-run` prints the exact request body without a network call.
Live evidence for the pinned model and the floor is recorded in [`verification/test-failure-cause.md`](verification/test-failure-cause.md).

## Standing upstream watch (config/upstream-watch)

`bin/fm-upstream-watch.sh run` writes dated reports, its watermark, and a standalone bare git cache under private gitignored `data/upstream-watch/`.
The cache shares neither objects nor refs with the live checkout, and every network fetch runs inside that cache.
`bin/fm-upstream-watch-generate.sh` is the fetch-free report generator that a future private-repository workflow can call without retaining the local delivery.
Reports contain only public upstream commit data, tracked fork-surface information, and installed tool versions, never captain preferences, backlog contents, project records, or other private operational context.
The session-start bootstrap section prints `UPSTREAM_REPORT: new private report at <path>` until the report is read and acknowledged with `bin/fm-upstream-watch.sh acknowledge <path>`.

`bin/fm-upstream-watch-schedule.sh` owns the inspectable macOS launchd schedule, written through the shared `bin/fm-launchd-schedule-lib.sh`.
Run `render` to inspect the complete definition, `install` to write and load it, `status` to print the installed file and live status, or `remove` to unload it.
The default cadence is 604800 seconds (weekly).
Set `interval_seconds = N` in private `config/upstream-watch`, or export `FM_UPSTREAM_WATCH_INTERVAL_SECONDS=N`, to override it.
The generator and delivery scripts never port, merge, rebase, or publish anything.

Every report ends with a tool-version section from `bin/fm-stack-versions.sh`: Herdr, treehouse, no-mistakes, and the AXI tools, each installed version against its latest release and the version Starship's own pins expect.
It only reports and never installs or upgrades anything; it flags Herdr and treehouse upgrades as needing a quiet window with no workers running.
The scheduled job runs with the PATH it was installed from, so reinstall the schedule after moving one of those tools.

Every home, whether or not it runs the weekly watch, also learns at session start which stack tools are behind.
The deferred network checks print one `STACK_TOOLS:` line naming each installed tool behind its target, with installed and target versions and whether it is a small update or a quiet-window upgrade, and otherwise print nothing, apart from the once-a-day could-not-check note below.
The target is the latest release, except for Herdr, which is judged against the version Starship pins in `bin/fm-install-herdr.sh`, so a newer unverified Herdr release is never reported.
`bin/fm-stack-versions.sh notice` owns that line and caches the whole lookup result, failed lookups included, in this home's `state/` for one day, so `/updatefirstmate`'s final report repeats the same result without looking again.
A tool whose version or release could not be read is named as not checked, never as current, at most once a day, and nothing is ever installed without the captain's yes.

### Catching up with the upstream

Catch-up is off by default for every home.
A home opts in with a `catchup = on` line in its own `config/upstream-watch`, beside any `interval_seconds` line; `bin/fm-upstream-lib.sh`'s `fm_upstream_watch_config` owns the file's format and refuses unknown keys and values.
Opted in, a scheduled run that finds new upstream work adds a catch-up plan to its report: this home's own commits the upstream lacks, the files both sides changed, and the files a trial merge would conflict on.
`bin/fm-upstream-watch.sh catchup` runs the same procedure on demand, with no opt-in, and plans every outstanding upstream commit.
Whichever run wrote the plan, session start prints `UPSTREAM_CATCHUP: catch-up ready to prepare, private report at <path>` until the report is acknowledged, and `bin/fm-upstream-watch.sh arm` registers a watcher check that tells a running firstmate once per prepared catch-up (`disarm` retires it).
Neither form merges anything: firstmate prepares the catch-up as a real merge on a branch through the home's normal delivery path, and the captain approves the merge.
The `catchup` skill owns turning it on and off, the merge rules, and landing.

## Dropped-threads digest (config/dropped-threads)

An opt-in, twice-daily digest of what has been left hanging in this home's own records, delivered as one spoken sentence and a short list.
It ships inert: with no `enabled = true` line in private gitignored `config/dropped-threads`, `bin/fm-dropped-threads.sh` does nothing at all, so cloning this repo, seeding a secondmate home, or adding a device never enrols it.
Each home and each device opts in separately.

At about the configured morning and evening times (08:30 and 19:30 local by default) it lists live and aged captain holds with any due date, open questions from work under way, other held items whose date has arrived, and in-flight tasks without a captain hold that have no stamped status event for over a day.
It reads local records only, through the canonical snapshot's local-only modes, and it only reports: it never changes the backlog, a hold or a task, never wakes firstmate, never writes a captain inbox note, and opens no network connection.
When nothing is waiting the slot is still recorded, with no sentence and no list, and nothing is spoken.

Delivery is a durable record under private `data/dropped-threads/`, which a later Starship Voice change will read for the phone card, plus the sentence spoken at the desk through `bin/fm-speak.sh`, which stays silent unless desk voice-out is on.
`bin/fm-dropped-threads.sh`'s header owns the record format (`fm-dropped-threads.v1`), the slot and catch-up rules, the exact commands and the config keys; `latest --json` is the reader's entry point and `preview` shows what the next digest would say without writing or speaking anything.

`bin/fm-dropped-threads-schedule.sh` owns the inspectable macOS launchd schedule, written through the shared `bin/fm-launchd-schedule-lib.sh`, and refuses to install on a home that has not opted in.
Run `render` to inspect the complete definition, `install` to write and load it, `status` to print the resolved knobs and installed file, or `remove` to unload it.
The default cadence is 900 seconds, read back from the digest owner; set `interval_seconds = N` in `config/dropped-threads` to change it.

## Weekly changes page (config/weekly-changes)

An opt-in weekly page that says in plain words what changed across your registered projects, for a reader who does not open pull requests.
It ships inert: with no `enabled = true` line in private gitignored `config/weekly-changes`, `bin/fm-weekly-changes.py` does nothing at all, so cloning this repo, seeding a secondmate home, or adding a device never enrols it.
Each home and each device opts in separately.

Once a week, at the configured local weekday and time (Monday 07:00 by default), it writes one local page covering the week before.
For each project, busiest first, it shows the changelog bullets added that week, then every pull request merged that week by its In short section (the first section of the [PR text](#pr-text) template), or by its title when it has none, each with a link to the pull request.
It names the projects where nothing landed and the ones it could not read, with why.
It reads GitHub through the signed-in `gh` and only reads; it never wakes firstmate, writes no backlog or inbox record, and never changes a project.

Pages live under private `data/weekly-changes/`, the newest as `latest.html`, and the [web page](web.md#this-week) has a This week button for it.
Each page covers the seven days before its slot.
The script's header owns the project and source rules, the page files, the exact commands and the config keys (`weekday`, `time`, `interval_seconds`).

`bin/fm-weekly-changes-schedule.sh` owns the inspectable macOS launchd schedule, written through the shared `bin/fm-launchd-schedule-lib.sh`, and refuses to install on a home that has not opted in.
Run `render` to inspect the complete definition, `install` to write and load it, `status` to print the resolved settings and installed file, or `remove` to unload it.
It polls hourly by default, read back from the page owner, and writes each week's page once, on the first poll after the weekly time.

## Desk voice-out (config/speak)

An opt-in, per-home and per-device gate for speaking a captain-facing outcome out of this machine's own speaker.
It ships inert: with no `enabled = true` line in private gitignored `config/speak`, `bin/fm-speak.sh` makes no sound at all, so cloning this repo, seeding a secondmate home, or adding a device never makes it talk.

This is a sink, not a companion.
The spoken register - outcome first, a few short sentences inside a bounded spoken length, never a URL, path or id, and never a request for a spoken yes - is owned once by an external register owner the home names, not by this repository.
`bin/fm-speak.sh` shapes every line through that owner and refuses to speak when it cannot reach it, because speaking unshaped text would read a URL aloud.
Reusing that owner is deliberate: a second copy of the register in this repository would drift from the one the owner already enforces.
The practical consequence is that desk voice-out needs the `shaper` key in `config/speak`, naming an executable that exposes the `--dry-run <text>` contract as an absolute path or one relative to the home; `FM_SPEAK_SHAPER` takes precedence over it, and with neither nothing is spoken.
The shaper contract has two parts: the owner implements `--dry-run <text>`, printing the shaped line on stdout or exiting 2 to refuse it, and it reads its spoken budget from the `GLASSES_ANNOUNCE_CONFIG` file `bin/fm-speak.sh` points it at ([`docs/examples/desk-speak-register.toml`](examples/desk-speak-register.toml), see **Desk spoken bound** below); an owner that ignores that variable uses its own budget instead.
**Upgrading an armed home.** Earlier versions found a default owner on their own, so a home that already has `enabled = true` needs a `shaper` line added to `config/speak` after updating; without it nothing is spoken.

**Speaker preference.** A named voice picks the speaker. With a non-empty `voice` in `config/speak`, `bin/fm-speak.sh` speaks through macOS `say` in that voice, because Deepgram takes its voice from `DEEPGRAM_TTS_MODEL`, set in the environment or this home's gitignored `.env`, and cannot honour that key. With no voice named, `DEEPGRAM_API_KEY` in the environment or this home's gitignored `.env` sends the line to Deepgram Aura (`bin/fm-deepgram-tts.sh`, default model `aura-2-thalia-en`), played with `afplay`. Either way the other speaker is the fallback: Deepgram when there is no usable `say` binary, `say` when the key is absent or Deepgram fails. The speaker is chosen before the line is handed over and never swapped afterwards, so a speaker that fails once it has the line is not re-spoken through the other one. A named `voice` is checked against the voices `say` actually has before the handoff, because `say` substitutes a voice it does not have and still exits 0; a voice this machine does not have is reported on stderr and nothing is spoken. The name is matched no more strictly than `say` resolves it - case is ignored, and a bare `Ava` reaches `Ava (Premium)` - so only a name that cannot resolve at all is refused. That check runs beside the register call under its own bound rather than after it, so it does not extend the worst case a turn can be held, and a voice confirmed once is remembered in `state/speak-voice-confirmed` so only the first spoken line waits for it. The key is never logged, and this covers speech out only - the desk floater's transcription still uses the same key.
**Desk spoken bound.** The register owner truncates before playback and its own default budget is the ~8s one tuned for the glasses, which cuts an ordinary desk outcome mid-message.
So `bin/fm-speak.sh` points that owner at [`docs/examples/desk-speak-register.toml`](examples/desk-speak-register.toml) via `GLASSES_ANNOUNCE_CONFIG` (unless already set) for every desk line, setting the spoken budget to **30 seconds** and seven sentences (about 78 words) while keeping the same URL/path/id and decision refusals.
The bound belongs to the desk, not to the speaker, so it is the same whichever speaker plays the line, macOS `say` or Deepgram Aura.
Override with `FM_SPEAK_DEEPGRAM_REGISTER`, or keep the short glasses cut with `FM_SPEAK_DEEPGRAM_REGISTER=` (empty); the variable keeps its historical name because it is the published opt-out.

Because the register owner refuses text that asks the captain to decide, a merge, a spend, an outward action, or any other approval structurally cannot be put to the captain by voice; those stay in the written reply.
Nothing here observes audio, so a successful call means the shaped line was handed to the speaker, never that it was produced or heard.

Configuration is `key = value` lines; unknown keys are refused rather than ignored.
`enabled` arms this home, `shaper` names the register owner, and the optional `voice` names a `say` voice, which also selects `say` as the speaker.
[`docs/examples/speak`](examples/speak) is an example file that turns spoken replies on; a new home never installs it on its own.
The script's header and `--help` own the exact invocation, the environment overrides, and the exit codes.
[`desk-voice-replies.md`](desk-voice-replies.md) owns when the orchestrator speaks; the session-start digest prints it only in a home opted in here.

**Automatic reply speech.** On a Claude primary, the tracked `Stop` hook `bin/fm-claude-reply-speak.sh` carries out that duty.
It runs in the background after every turn of the lock-holding plain primary checkout, never in a crew or scout worktree or a secondmate home, and speaks the turn's final reply through `bin/fm-speak.sh` only when nothing was spoken during that turn.
It speaks the reply's opening lead ([`desk-voice-replies.md`](desk-voice-replies.md)): the first plain paragraph, at most six sentences and about 75 words, without a trailing list lead-in, plus one short pointer when the rest of the reply holds a choice, a question, steps, or more than a one-line sign-off, with the lead cut back so the pointer fits the spoken budget; a line the register refuses is retried with only the lead sentences it refuses on their own dropped, then falls back to its first sentence, then to a short notice that names a waiting decision only when the register refused the line as one and the reply itself offers a choice, a question, or steps, or the lead asks a question.
The routine no-news reply, by default `Captain, shipshape.` and otherwise the form recorded under [address and tone](#address-and-tone), stays silent to save speech credits, and a reply that opens with that line speaks only what follows it.
In a home that has not opted in, the hook runs only its plain-language reply check, then asks `bin/fm-speak.sh --enabled` and does nothing else; mute applies unchanged, and the hook's header owns the exact rules and that check.
The Mac push-to-talk floater that feeds captain input into this home is documented in [`desk-floater.md`](desk-floater.md).

Each call is bounded on both halves so a captain-facing turn is never held open: the register call is waited on under a watchdog because its output is needed, and speaker playback is detached with its standard streams closed (Deepgram synthesis is waited only for the network `--to` file, then playback is detached).
Detachment also puts the speaker in a process group of its own, so a harness that reaps the speaking command's process group at the end of its turn cannot cut the spoken line short; the script's header owns that mechanic.
Playback is serialized per home: a second line waits for the current one to finish rather than overlapping, and that wait happens in the detached speaker so the calling turn is still not held open by audio.
The two bounds are deliberately separate because they protect different things: `FM_SPEAK_SHAPER_TIMEOUT` bounds the waited-on register call and is therefore the worst case a turn can be held, while `FM_SPEAK_TIMEOUT` bounds synthesis/playback runaways without ever holding the caller for the duration of the audio.
The script's header owns their defaults.
`bin/fm-speak.sh --enabled` answers whether this home is opted in, for the scripts above.
`bin/fm-speak.sh --check` answers whether a spoken line would actually be heard, naming each missing piece, such as no `shaper` line, a shaper that is not executable, or a shaper whose dry run fails on an interpreter too old for it, and speaks nothing; the first-hour checklist shows its answer ([ONBOARDING.md](../ONBOARDING.md#voice-a-deepgram-key-and-spoken-replies)).
`bin/fm-speak.sh`'s voice controls (stop, replay, the reply history, mute and volume) back the desk floater's reply bubble and right-click menu and the web page's Voice settings: a mute is a per-home runtime flag in `state/speak-muted` and the voice level a per-home runtime value in `state/speak-volume`, never `config/speak` keys, and both affect voice only, while the text reply stays authoritative; the script's header owns their behavior and flags, and docs/desk-floater.md describes the controls.

## Desk floater signing identity (config/desk-floater-signing-identity)

Optional, private, gitignored, and not inherited by secondmate homes.
One line naming the codesigning identity `bin/fm-desk-floater.sh` signs the desk floater with, as a SHA-1 hash or a name `codesign` accepts, or `-` to keep the linker's ad-hoc signature.
Absent, the launcher uses the first valid "Apple Development" identity in the keychain, and stays ad-hoc with a note when there is none.
A stable identity is what lets the floater keep its Accessibility and Screen Recording grants across rebuilds.
A named identity the keychain does not hold, one that has expired, or one that fails to sign never stops the launcher: it falls back to the first valid "Apple Development" identity, then to ad-hoc, with a note naming what happened.
Only the launched floater is signed; a `--build-only` copy stays ad-hoc and never looks in the keychain.
The script's header owns the mechanics, and [`desk-floater.md`](desk-floater.md#keeping-the-permissions-across-rebuilds) describes the effect.

## Speech-to-text vocabulary (config/stt-vocabulary)

Optional, private, gitignored, and not inherited by secondmate homes.
It teaches the desk floater's transcription (`bin/fm-deepgram-stt.sh`) the names and addresses this home's captain says, so a spoken email address arrives written correctly.
Absent, transcription behaves exactly as without it.
Lines starting with `#` and blank lines are ignored.
A plain line is a key term, sent to Deepgram as a recognition hint for that request.
A `heard => written` line rewrites the printed transcript after Deepgram returns it, for example `pat dot example 1 => pat.example1` for `Pat dot example 1`.
Use Deepgram's returned spelling and numbers on the left: smart formatting happens before rewrites, so spoken `one` may arrive as `1`.
Rewrites ignore case, match whole tokens (including email addresses, dotted names, contractions and hyphenated words) while still allowing a possessive `'s` or `’s` after the match, and try the longest heard phrase first.
`--json` output stays Deepgram's raw response, untouched by rewrites.
A malformed line is ignored, and a vocabulary that cannot be read never stops a transcription.
The default model is `nova-3` because only Nova-3 accepts Deepgram's keyterm hints; `DEEPGRAM_STT_MODEL` in the environment or this home's gitignored `.env` overrides it (the environment wins), and an older model gets the terms as boosted keywords instead.
The script's header owns the hint parameters, the term caps, and the matching rules.
[`docs/examples/stt-vocabulary`](examples/stt-vocabulary) is the starter template a new home installs on its first launch ([starter settings](#starter-settings-first-launch)); add your own names below its starter words.

## Call recorder (config/call-companion)

Optional, private, gitignored, and not inherited by secondmate homes.
It holds the call recorder's settings: the label for your own speech, the microphone and loopback devices, the transcription engine (whisper.cpp on this Mac, or Deepgram with the key the desk floater uses) and speech model, the Claude models for the live desk and the notes, and an optional second screen.
Absent, every setting takes its default.
`key = value` lines; `#` comments and blank lines are ignored, and an unknown key is refused so a typo never silently changes what is recorded.
[`docs/examples/call-companion`](examples/call-companion) lists every key with its default, `bin/fm-call-lib.sh`'s header owns their meaning, and [call-companion.md](call-companion.md) covers consent, setup, stopping and deleting.

## Meeting intake (config/meetings)

Optional, private, gitignored, and not inherited by secondmate homes.
Nothing polls, reads or acts until it holds `enabled = true`; `bin/fm-meetings.sh arm` then binds the standing check, and `enabled = false` or `bin/fm-meetings.sh disarm` turns the intake off again.
It names the sources finished meetings come from (`source = call-recorder`, the default, for calls recorded with the call recorder above, and `source = anarlog` for meetings recorded by Anarlog), the words that keep a meeting out of the intake altogether, any further transcript label that is you, the Claude model for the intake, and the Anarlog speaker-pass wait.
`key = value` lines; `#` comments and blank lines are ignored, and an unknown key or source is refused so a typo never silently changes what is read.
[`docs/examples/meetings`](examples/meetings) lists every key with its default, `bin/fm-meetings.sh`'s header owns their meaning and the intake's rules, `bin/fm_meeting_sources.py`'s header owns each source and the seam a new one plugs into, and [meetings.md](meetings.md) covers what Anarlog is, setup, keys and turning the intake off.
The file's presence also switches on the `meeting-intake` skill as an [opt-in skill](#opt-in-skills-configadhd-configsecond-opinion).

## Phone tap desk (config/tap-desk)

Optional, private, gitignored, and not inherited by secondmate homes; any file at the path turns it on, whatever it holds.
Its presence switches on the `tap-desk` [opt-in skill](#opt-in-skills-configadhd-configsecond-opinion), which has firstmate put every decision held for the captain that waits on him now on one private claude.ai artifact page where each is answered with a single tap, optionally with a short reason.
Ready merges are answered on the [Factory pane](factory-pane.md), which shows each PR's short section beside the merge choice, so the page lists them as not on it rather than carrying merge cards.
A file at `config/tap-desk-merges`, whatever it holds, turns phone merging back on: the page then carries a merge card for every ready task PR as well.
The page needs a Claude Code primary that can publish artifacts and read their database.
Its private records live under `data/tap-desk/`: the card file and page `bin/fm-tap-desk.sh export` writes, the artifact link, the downloaded taps, and `ledger.jsonl`, the record of every routed tap and seven-day default; reasons also land in the decision record and as rule candidates in `data/learnings.md`.
`bin/fm-tap-desk.sh`'s header owns the card format, routing, refusals, and default rules, and the skill owns when firstmate runs them.

## Backport (config/backport)

Optional, private, gitignored, and not inherited by secondmate homes; any file at the path turns it on, whatever it holds.
Without it Backport is off: `bin/fm-backport.sh` refuses every command and writes nothing, so cloning this repository, seeding a secondmate home or adding a device never enrols a home.
Its presence also switches on the `backport` [opt-in skill](#opt-in-skills-configadhd-configsecond-opinion), which runs the weekly pass that turns the home's improvements into anonymous cards for the shared Starship.
The card check needs the new-name check of the [leak guard](#private-leak-words-configleak-words), so it also refuses until the home keeps a private word list or a `config/leak-names-approved` file, which may be empty.
Cards, private notes and the ledger live under private `data/backport/`.
[backport.md](backport.md) owns the anonymity rule and the card, `bin/fm-backport.sh`'s header owns the commands and refusals, and the skill owns the weekly pass.

## Merge rule table (config/merge-rules)

Optional, private, gitignored, and not inherited by secondmate homes.
Without the file, merges behave as before.
Because the table is not inherited, a home without its own `config/merge-rules`, including a secondmate home, keeps its existing merge rules even when another home has a table.
With it, the file is the one written answer to which pull requests land by themselves: one row per project naming what lands by itself (docs, tests, deps, anything, or nothing) and who must say yes to everything else.

```text
# project      | lands by itself   | who must say yes
example-app    | docs, tests, deps | the owner
example-site   | nothing           | the owner
```

`bin/fm-pr-merge.sh` checks each GitHub merge against the task's project row: without `--captain-approved`, a pull request merges only when its row lets anything land or every file it changes sits in one single class the row lists, read from the pull request's changed files at merge time.
A project with no row, a mixed or unlisted class, and a pull request that no task owns wait for a yes, and a malformed table refuses every merge until it is fixed.
Each merge it confirms on GitHub then gets one generic comment saying who let it land and under which rule, such as "merged on the owner's yes" or "landed by itself under this project's merge rule (docs only)", with no names.
A dependency pull request says "dependency updates within the same major version" only when every package.json it changes passed the version check; one that changes only lockfiles had no version check and says "lockfile-only dependency refresh".
`bin/fm-merge-rules.sh`'s header owns the table format, row matching, the file classes, and the trail lines, and `bin/fm-pr-merge.sh`'s header owns how a merge uses them.

## Supervision active alert channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
The host-level macOS sentinel uses the same channels when a crew task is in flight or a sentinel hook reports work while supervision is down by the home's own supervision model, not during a normal hand-over gap between watcher cycles.
Beyond the durable alarm markers and the tmux status-line flash available to the injection case, these backend-independent alerts can reach the captain even when every pane and its backend status-line is unreadable.
In-harness turn-end and continuity guards write only the pending marker and return their own loud banner immediately; the independent scheduled host check exclusively owns external-channel delivery.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: a supervision outage must not be silent.
The injection alarm fires at most once per max-defer window after a genuine wedge, while one continuous watcher outage repeats after five minutes by default and then backs off exponentially to a one-hour cap.
A watcher that recovers and is reaped again starts a new outage episode, which resets that backoff and alerts on the next host check.
Failed watcher-outage delivery remains pending and retries after a short claim lease; only successful delivery advances that backoff.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
A tool in a home's private add-on may append and remove its own sentinel-delimited block here while it needs an extra channel, keeping `auto` beside its `command:` directive.
See [`wedge-alarm.md`](wedge-alarm.md) for the channel reference and macOS verification evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Context window

Every Firstmate session and every Claude or Codex worker is launched with its auto-compaction window capped at 500,000 tokens, so an orchestrator compacts itself instead of being managed by hand (captain's order, 2026-09-13).
The cap is applied per launch by [`bin/fm-primary.sh`](../bin/fm-primary.sh) and [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), whose headers are the single owners of the exact mechanism; it is never written into the captain's global config for any harness.
Existing sessions are not affected, because both launchers only shape new launches.

Claude Code reads `CLAUDE_CODE_AUTO_COMPACT_WINDOW` as a token count and says so itself: claude 2.1.270 renders the window as "<n> tokens (from CLAUDE_CODE_AUTO_COMPACT_WINDOW)" and tells `/config` that "CLAUDE_CODE_AUTO_COMPACT_WINDOW is set and takes precedence", and its resolver returns `min(model maximum window, the parsed value)`, so a model smaller than 500k stays capped by its own window.
Codex accepts `model_auto_compact_token_limit` as a launch-line config override: `codex debug models -c model_auto_compact_token_limit=500000` exits 0 on codex-cli 0.154.0 while the same key with a string value exits 1 with `invalid type: string "nope", expected i64`, which proves the key is real, typed, and settable without touching `config.toml`.
Pi has no context-window or auto-compaction launch knob: pi 0.80.10's `shouldCompact` is `contextTokens > contextWindow - settings.reserveTokens`, where `contextWindow` comes from the model catalog and `reserveTokens` exists only in `~/.pi/agent/settings.json` or a project's `.pi/settings.json`, so nothing is passed at launch and pi's threshold remains whatever its model allows.
The Cursor CLI exposes no context or compaction setting: `agent --help` on 2026.09.02-c22c1a3 lists no such flag, the binary carries no `CURSOR_*` context or compaction environment variable, and `contextWindowSize` appears only in its token-usage display code.

Every other worker adapter is outside that order and its launch is unchanged.

## Starter settings (first launch)

A new home's first launch with a Claude profile (`bin/fm-primary.sh opus`, or `claude`) installs the Claude starter settings into its private `config/`, so a new Starship starts with the starter settings without copying anything by hand.
A new home is one whose `state/` is absent or empty, which means it has never run.

| Installed as | Copied from | What it does |
| --- | --- | --- |
| `config/crew-dispatch.json` | [`docs/examples/crew-dispatch-claude-only.json`](examples/crew-dispatch-claude-only.json) | Which Claude model does which job, sized for a Pro or Max 5x plan ([crew dispatch profiles](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson)). |
| `config/stt-vocabulary` | [`docs/examples/stt-vocabulary`](examples/stt-vocabulary) | Starter words for the desk floater's transcription ([speech-to-text vocabulary](#speech-to-text-vocabulary-configstt-vocabulary)). |

A file already in `config/` is never overwritten, and a home that has run before gets nothing, so an existing home keeps exactly what it has; it can copy any of these files by hand.
Other primary profiles install nothing, because the routing sends every worker to Claude.
Spoken replies are not a starter setting, so a new home stays silent until it opts in through [desk voice-out](#desk-voice-out-configspeak).
`--preflight` and a dry run never write them.
The launcher prints the files it installed, and `bin/fm-primary.sh`'s header owns the mechanics.

## Primary effort (config/primary-effort)

`config/primary-effort` is an optional local, gitignored one-token file that sets the launch effort for the `claude-fable` and `claude-opus` primary profiles.
The `claude-fable52` profile (`firstmate fable`) always launches at `medium` and does not read it.
`bin/fm-primary.sh` reads it only at launch.
When the file is absent, the effort follows the Claude plan the first mate is signed in to:

| Plan | Default effort |
| --- | --- |
| Claude Pro | `medium` |
| Claude Max 5x | `high` |
| Claude Max 20x | `xhigh` |
| Anything the launcher cannot read as one of these | `high` |

`max` is never a default; it is reached only by writing it into this file.
The launch line names the effort and the plan it came from, and `bin/fm-primary.sh`'s header owns how the plan is read.
To choose your own, write one word into the file and start the first mate again, for example `echo high > config/primary-effort`.
When the file is present, its first line must trim to exactly one of `low`, `medium`, `high`, `xhigh`, or `max`.
Any other content, including an empty token, refuses rather than falling back.
The file is not inherited by secondmate homes.

## Primary Astra effort (config/astra-effort)

`config/astra-effort` is an optional local, gitignored one-token file that sets the launch effort for the `astra` primary profile.
`bin/fm-primary.sh` reads it only at launch.
When the file is absent, the launcher uses `xhigh`.
When the file is present, its first line must trim to exactly one of `low`, `medium`, `high`, or `xhigh`.
`max` is not accepted, and that refusal is retained pending the separate follow-up astra-max-effort.
Any other content, including an empty token, refuses rather than falling back.
The file is not inherited by secondmate homes.

## Primary Astra context window (config/astra-context, config/astra-compact-at)

`config/astra-context` is an optional local, gitignored one-token file that selects the context window for the `astra` primary profile.
`bin/fm-primary.sh` reads it only at launch.
When the file is absent nothing changes: no override is passed and Codex uses its own catalog default.
When the file is present, its first line must trim to either `max` or a positive integer.
`max` resolves to the installed Codex model catalog's own `max_context_window` for `gpt-6-astra`, read from `$CODEX_HOME/models_cache.json` at launch.
An explicit integer is honoured only up to that same ceiling; a larger request refuses rather than being clamped or passed through, because both would leave the launcher asserting a window the provider never granted.
An unreadable or malformed catalog refuses rather than supplying a remembered number.

The provider's published API maximum for a model and the window this subscription CLI will actually open are different quantities, and only the second one is ever used here.

`config/astra-compact-at` is an optional local, gitignored one-token file holding a positive integer, the token count at which Codex compacts the thread.
It is never derived: how much of a window to spend before summarising is an operational choice, and the catalog prescribes none.
It must be strictly below the selected window, and it refuses if `config/astra-context` selects no window.
When it is set, its value REPLACES the 500,000-token default from [Context window](#context-window) above rather than adding a second limit, so exactly one `model_auto_compact_token_limit` is ever passed.
When it is absent, the `astra` launch keeps that 500,000-token default even if `config/astra-context` selects a larger window.

Neither file is inherited by secondmate homes.
A raised window takes effect on the next launch, and the first `token_count` event in the new session reports the `model_context_window` that was actually granted, which is where to verify it.

## Calm presentation (config/calm)

`config/calm` is an optional LOCAL, gitignored one-token file recording whether the Pi primary's Calm presentation is on for this home.
`.pi/extensions/fm-calm.ts` writes it whenever the captain runs `/calm`, and reads it when a Pi session starts.
`on` restores Calm; `off` and an absent file both leave it off.
A home upgraded from the removed third presentation level still holds `max`, which restores as `on`.
Any other content restores as off rather than refusing, because a corrupt preference must never stop a primary from starting.
[calm.md](calm.md) owns what the presentation actually does.

## Private leak words (config/leak-words)

`config/leak-words` is an optional LOCAL, gitignored file listing words and phrases that must never appear in this public repository, such as the names of people and private projects.
It holds one word or phrase per line; blank lines and lines starting with `#` are ignored, and matching ignores case and takes whole words only.
Without the file or one of the lists below, which is the default, the scan is unchanged.
`bin/fm-leak-guard.sh` checks every tracked file against it, `tests/` included, and its header owns where it looks for the list, so a run from a task's isolated copy or a validation run's copy still finds the home's list.
`bin/fm-lint.sh` runs that check on every default lint, including the validation pipeline's lint step, and the pre-push hook below runs it on a push typed by hand, so these words are caught before each push; CI has no list, and without one the check is silent.

A home's [private add-on](#private-add-on-configaddon) may carry more words in a file named `leak-words` at the add-on's root, in the same format, and the guard checks them together with the home's own list.
This is how a private team add-on keeps every teammate's list current: the team's colleague, partner and customer names live in that one file, and `/updatefirstmate` ("update starship") brings each teammate the latest copy with the rest of the add-on.
Without that file, or without an add-on, nothing changes; an add-on that is configured but unusable is named on stderr and adds no words.
The guard never prints the list, and a hit on a listed word names only where it is, as file, line and column, never the word or its line, so checking a file that holds the list does not put the list on the screen.
`fm_leak_words_write` in `bin/fm-leak-lib.sh` owns how the lists are merged.

A list cannot keep up with every new name, so a home that keeps one also blocks new names by default.
Before each push, `bin/fm-leak-guard.sh --new-names` reads the lines the branch adds since its merge base with `origin/main` and refuses every name-shaped word that has never appeared anywhere in this repository's tracked files at the merge base, naming each word and the file and line it is on.
It reads the message of every commit in `origin/main..HEAD` the same way and names a hit there as `commit <short-sha>`.
In a fork that records its upstream as `upstream_base` in `fork-surface.conf`, the upstream's content is already public: the words in the tracked files at that commit are known too, and the messages of commits reachable from it are not checked for new names, so a catch-up merge does not ask the owner to approve the upstream's words or its contributors' names.
Those messages and the lines the upstream adds are still checked for private words, customer data shapes and keys, and this home's own lines and commit messages are still checked for new names; a recorded base that is no commit in the checkout, or that already holds the branch's merge base, is named on stderr and ignored.
Without `origin/main`, or without a merge base with it, the check refuses with exit 2.
A name-shaped word is a capitalised word made only of letters, such as a first name, or a CamelCase one, such as a product name, in any file; words in capitals, words with a digit or underscore, and words that start with a small letter are never name-shaped.
A word the repository already holds, in any case, never triggers, and once a change lands its words are part of the repository and stop being new.
The owner approves a new word once: firstmate then appends it as its own line to `config/leak-names-approved`, an optional LOCAL, gitignored file in the home's config, for example with `printf '%s\n' <word> >> "$FM_HOME/config/leak-names-approved"`, and the check passes it from then on.
That file uses the word list's format, is never printed, and is never copied into tracked files.
The private word lists stay as the backup for names that look like ordinary words.
A word or phrase from the private word list in those added lines or commit messages is refused too, placed by commit or file, line and column and never printed; no word inside a listed word or phrase is also named as new, here or in `--text --new-names`, while a word of a listed phrase that occurs on its own still counts as a new word.
The same added lines and commit messages are also checked for the shapes customer data takes: Slack user, channel and direct-message ids and links into a named Slack workspace, HubSpot record and portal links, phone numbers, and IBANs with valid check digits.
A phone number is one in international form, a plus and 8 to 15 digits, or a Dutch mobile number, 06 and 8 more digits, each optionally after a space or a dash.
The full scan CI runs checks those shapes in every tracked file, beside the email, home path and key checks, with the same `tests/` exemption.
The key check finds the provider key and token prefixes `bin/fm_secret_shapes.py` owns, the same list the worker command guard redacts, and an API key assigned a literal value under any name and in any case, such as `SOMETHING_API_KEY=...`; like a listed word, a key is reported by where it is and never printed.
`bin/fm-lint.sh` runs `--new-names` on every default lint, so the validation pipeline's lint step checks each push; without a word list or an approvals file, as in CI, it is silent.
`bin/fm-leak-shapes.py` owns what counts as name-shaped, as an occurrence and as each data shape, and the guard's header owns the modes.

A pre-push hook runs these checks on every push from a home's Starship checkout and its private add-on too, so a plain `git push` typed by hand is checked like a push through the pipeline.
Session-start bootstrap installs it, and keeps it current, in each checkout's hooks directory, which every task worktree of that checkout shares; a pre-push hook already there is kept and runs once the check passes.
In the Starship checkout a push runs the guard's full scan over every file the branch changes since its merge base with `origin/main`, then `--new-names`, and refuses the push on any hit with the guard's own lines; a push to the validation pipeline's gate is left to the pipeline's lint step.
In the add-on, which holds its own private words and names, a push is refused only for key and token shapes and customer data shapes in what it adds.
Only commits the remote does not have yet are checked, and because the checks read the checked-out commit and its working tree, a ref that brings new commits must be that commit and the tracked files must match it; any other ref is refused, naming it, and so is a working tree that differs, naming the files that do.
Bootstrap installs the hook only into the git directory's own hooks; a `core.hooksPath` pointing anywhere else, such as a tracked directory or a user-global one, is reported as a `LEAK_PREPUSH` line and nothing is installed.
git's own `--no-verify` is the only way past the check.
`bin/fm-leak-prepush.sh`'s header owns the details.

Secondmate homes inherit the merged list as `config/leak-words.inherited` under the primary-authoritative contract in `bin/fm-config-inherit-lib.sh`, so a secondmate that inherits the right to publish to this repository through `config/firstmate-role` also keeps these words out of what it publishes.
The guard checks a home's own `config/leak-words`, its `config/leak-words.inherited` and its add-on's list together.
Inheritance replaces only `config/leak-words.inherited`, and removes it when the primary has no words; a secondmate home's own `config/leak-words` is never touched, so inheriting never shrinks the words that home keeps out.
While the primary's add-on is configured but unusable, the inherited list is reported as an error and not pushed, each secondmate home keeps its last copy, and every other inherited item still converges.
A changed list is never written into the reread message a live secondmate receives; its guard reads the file on every run.

The same list keeps these words out of what workers publish to a public repository's pull requests: titles, descriptions, comments, and the intent and gate answers the validation pipeline turns into its PR.
`bin/fm-leak-guard.sh --text [<file>|-]` checks draft text, from the named files or stdin, for listed words and key or token shapes, and says how many it found and the line and column of each, never the word or token itself; it exits 1 on a hit and 0 when the text is clean.
Without a list it checks the key and token shapes alone and is silent on a clean text.
For text bound for this repository, `--text --new-names` also names every new word and data shape the text holds, with the repository's tracked files as what it already holds.
When it runs inside a checkout of this repository, one with a remote of the same owner/repo, the tracked files at that checkout's HEAD count as known too, so the words of the branch being published need no second approval.
Every direct-PR and no-mistakes ship brief tells the worker to run it before opening, editing or commenting on a PR and before passing intent to the pipeline, and to check the published title, description and every comment, the pipeline's included, once the PR exists.
On a public repository, a listed word in the captain's intent is replaced by its role before it reaches `--intent`; that is the one exception to passing the captain's words verbatim, and `bin/fm-dod-lib.sh` owns it.
For a spawned Claude worker (crewmate or scout), and for a first mate or second mate running on Claude through the tracked `.claude/settings.json`, `bin/fm-pr-text-guard.py` also checks each shell command that publishes such text through `gh` or `gh-axi`, or starts or answers the pipeline, and refuses it when the text holds a listed word or a key or token shape unless every repository the command could reach is proven private.
The refusal counts the words and tokens and names the command or file and the line each is on, never the words or tokens themselves.
Key and token shapes count only in the command and the files it sends as content: a `--body-file`, `--input` or `-F field=@file` value, a `$(cat file)`, `$(<file)` or backtick `cat file` outside single quotes and quoted heredoc bodies, and a file redirected or piped from `cat` into `--body-file -` or `--input -`; a file it merely names, such as a test fixture with synthetic keys, is checked for everything else.
It refuses a new word or data shape the same way when the command could reach this repository while it is public, and tells the worker to ask for the owner's approval of each new word; other public repositories may hold words new to this one.
A private repository's PRs may hold the words, a pipeline whose origin is not on GitHub is not checked, and a repository whose visibility cannot be read counts as possibly public and is refused; the script's header owns which commands count and which repositories a command could reach.
A job whose repository only another GitHub account can read is spawned with `bin/fm-spawn.sh --gh-account <login>`, so the check reads visibility through that account rather than the global gh login, which it never switches; the spawn script's header owns the flag.
Without any list or approvals file, only a key or token shape is refused.
The check reads the list on every command, so a list added later needs no relaunch.
Sessions on other harnesses, first mate, second mate or worker, are not checked by it.
This repository's `.no-mistakes.yaml` tells the review, document and test steps, whose summaries and findings become the pipeline's PR text, to name people, companies and projects only by role and never quote a private name from findings or evidence.
The pipeline's own PR title, description and comments are otherwise checked only by the worker's read-back after they are published, and an edit then does not erase GitHub's edit history or notifications already sent.
A true check before the pipeline publishes needs support inside no-mistakes and is a known gap.

## Bridge pinned links (config/bridge-links)

`config/bridge-links` is an optional LOCAL, gitignored file containing one pinned bridge-page link per line as `<label><TAB><https-url>`.
Blank lines and lines starting with `#` are ignored, and malformed entries or non-HTTPS URLs are skipped.
`bin/fm-bridge-view.py` reads the file at render time, so changes appear on the next page refresh without restarting the service.
The file is not inherited by secondmate homes.

## Bridge machines (config/bridge-machines)

`config/bridge-machines` is an optional LOCAL, gitignored file that tells the bridge's Machines page ([`bridge-view.md`](bridge-view.md#machines-machines)) which machines to watch and what else to check.
Each line is one entry with TAB-separated fields:

```text
machine<TAB><name>[<TAB><ssh-alias>]
probe<TAB><label><TAB><https-url>
service<TAB><label><TAB><loopback-http-url>
```

- `machine` watches a machine: when it is offline or unreachable the page raises an alert and the health score counts it.
  `<name>` matches a tailnet machine's name or MagicDNS label, case-insensitively; a name the tailnet does not know becomes its own card reached over ssh.
  With an `<ssh-alias>` (a plain alias from `~/.ssh/config`, which must already log in without a prompt), the page also reads that machine's load, memory, disk, uptime, and failed systemd units.
- `probe` checks a web address with one HTTPS GET; any 2xx or 3xx answer passes.
- `service` checks a local service's health address; it must be `http` or `https` on `127.0.0.1`, `localhost`, or `::1`, and passes on a 2xx answer.

Blank lines and lines starting with `#` are ignored, and a malformed line is skipped and named on the page.
The file is read on every Machines read, so changes appear within about 30 seconds without restarting the service.
Without the file the page still lists every tailnet machine and this Mac, and no machine raises an offline alert.
The file is not inherited by secondmate homes.

## Bridge voice mailbox (config/bridge-mailbox)

`config/bridge-mailbox` is an optional LOCAL, gitignored file that names the loopback voice mailbox the bridge page's hold-to-speak control forwards to ([`bridge-view.md`](bridge-view.md)).
It holds `key = value` lines; blank lines, lines starting with `#`, and unknown keys are ignored:

```text
port = <loopback port the mailbox serves>
token = <path under the home of the file holding its bearer token>
launchd = <optional LaunchAgent label, for the page's mailbox indicator>
```

`token` must be a relative path inside the home, never absolute and never through `..`.
Without the file the bridge has no mailbox: hold-to-speak answers that the mailbox is not configured and the indicator reads off.
`bin/fm-bridge-view.py` reads it on every request, so a change needs no restart.
To show the mailbox on the Machines page as well, add its health address as a `service` line in [`config/bridge-machines`](#bridge-machines-configbridge-machines).
The file is not inherited by secondmate homes.

## Primary orchestrator handoff (config/primary-handoff)

`config/primary-handoff` is an optional local, gitignored JSON file that enables automated rotation of the Firstmate primary orchestrator on two independent axes: provider quota and model-context used.
Absent or `"enabled": false` starts no handoff and leaves `bin/fm-primary.sh` launch behavior unchanged; `bin/fm-primary-handoff.sh` only reconciles an interrupted earlier attempt, as [`docs/primary-handoff.md`](primary-handoff.md) describes.
When enabled, `bin/fm-primary-handoff.sh` evaluates:

- **Quota** - when the minimum `percentRemaining` from `quota-axi` over the provider's general windows and the active profile's own model window (`model:fable` for `claude-fable` and `claude-fable52`) is at or below `threshold_percent_remaining`, rotate to the next profile in `chain`.
- **Context** - when durable context used (from `state/.primary-context`, written by `bin/fm-status-bar.sh`) is at or above `threshold_context_percent_used`, rotate to the **same** profile for a fresh empty session.
  Absent or null `threshold_context_percent_used` disables the context axis only.

Both axes share the atomic-lock protocol in [`docs/primary-handoff.md`](primary-handoff.md).
See [`docs/examples/primary-handoff.json`](examples/primary-handoff.json) for a starting point.

```json
{
  "enabled": true,
  "threshold_percent_remaining": 15,
  "threshold_context_percent_used": 50,
  "poll_seconds": 60,
  "cooldown_seconds": 300,
  "chain": ["claude-fable", "claude-opus"]
}
```

This section owns the config schema; `bin/fm-primary-handoff.sh` owns commands and test seams; `docs/primary-handoff.md` owns the lock-transfer protocol, same-runtime mode, and failure modes.
The feature is not inherited by secondmate homes.

## Vendor account pinning (config/accounts.json)

`config/accounts.json` is an optional local, gitignored file that names the vendor accounts this machine can run work on.
It is firstmate-maintained and human-editable, in the same spirit as `config/crew-dispatch.json`.
This section is the single owner of its schema; `bin/fm-primary.sh` and `bin/fm-spawn.sh` own their own selection flags, and `bin/fm-account-lib.sh` owns the resolution contract.

An absent file means one thing only: no pinning at all.
Every primary launch and every spawn then uses whichever account is live in the ambient vendor home, exactly as it did before account pinning existed.
That is the compatibility guarantee, and it is covered by tests in `tests/fm-primary.test.sh` and `tests/fm-spawn-account.test.sh`.

```json
{
  "claude": {
    "default": "team",
    "accounts": {
      "team": {"label": "Company Team (connectors)", "expect": "<that seat's organization id>"},
      "max": {"label": "Personal Max"}
    }
  },
  "codex": {
    "default": "robin",
    "accounts": {
      "robin": {"label": "Robin personal"},
      "alex": {"label": "Alex"}
    }
  }
}
```

The only vendors with an account concept are `claude` and `codex`.
Each account's isolated home is DERIVED as `data/accounts/<vendor>/<name>` and is never stored in the file, so the registry cannot point a launch at an arbitrary directory.
A claude home is exported as `CLAUDE_CONFIG_DIR` and a codex home as `CODEX_HOME`.
Account names are one path segment of letters, digits, dot, dash, or underscore, and must start with a letter or digit.
`label` is optional prose for the captain.
`default` is optional and names the account used when no account is selected explicitly; it must be one of that vendor's defined accounts.
`expect` is optional and is described below.

Selection is explicit and manual by design.
`bin/fm-primary.sh <profile> --account <name>` pins a primary and `bin/fm-spawn.sh <id> <project> --account <name>` pins a worker, which records `account=` with `account_source=registry` in that task's metadata.
There is no automatic switching, no fallback to another account when one is exhausted, and no quota-driven selection: which account work runs on is a spend and data-boundary decision that belongs to the captain.
A home's per-harness [worker account pin](configuration.md#worker-account-pin-configclaude-account-configpi-account) takes precedence for that harness's workers: registry selection is skipped there, and an explicit `--account` spawn is refused rather than silently combined with the pin.
In a home that declares [several Claude accounts](configuration.md#several-claude-accounts-configclaude-accounts), a Claude ship or scout's `--account` names one of that list's entries instead, and the registry stands down for that launch.
Recovery keeps the pin too: a secondmate respawn over its existing task record (`bin/fm-spawn.sh <id> --secondmate`, which the secondmate liveness relaunch in [`bin/fm-secondmate-liveness-lib.sh`](../bin/fm-secondmate-liveness-lib.sh) runs from both the session-start sweep and the watcher's liveness tick) and a control-plane relaunch (`bin/fm-control.sh <id> relaunch`, owned by [`docs/agent-control.md`](agent-control.md#transactional-relaunch)) both read `account=` back from the task's metadata.
While the replacement keeps the recorded harness and no worker account pin covers it, it is pinned exactly as the original was and refuses rather than falling back if that account can no longer be resolved.
A replacement on a different harness, one under a worker account pin, or one with no recorded `account=` resolves its account afresh, as a new spawn would.
Both carry back only a registry-written `account=`: the worker account pin records its own `account=` (`ordinary` or an absolute path), which is never read back as a registry name, so a task spawned under a since-removed pin resolves its account as a new spawn would rather than being refused.

Homes are created by `bin/fm-account.sh create <vendor> <name>`, which makes one empty directory and prints the login command for it.
Firstmate never copies, links, or seeds a credential directory, `auth.json`, `.credentials.json`, or keychain entry from one account home to another or from the ambient home, and never runs a login itself.
A pinned home that does not exist or is explicitly logged out refuses the launch and names the exact login command; that refusal is correct behavior.

`expect` closes the silent-wrong-account hole.
When an account declares it, the launch confirms the pinned home really resolves to that identity before anything runs on it, and refuses naming both the wanted and the actual identity when it does not.
It is matched case-insensitively against any identity field the vendor reports, so an organization id, an organization name, an email, or a plan name all work.
Two Claude seats can share one email address, so the organization id is the field that actually distinguishes them.
An identity that cannot be read at all also refuses, because `expect` is a demand for proof rather than a preference.
`expect` is only accepted for `claude`: `codex login status` reports no identity at all (verified codex-cli 0.153.4, 2026-09-09), so an `expect` on a codex account is reported as invalid rather than silently ignored.

When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: account pinning active config/accounts.json` plus one fact per vendor.
Malformed JSON, an unknown vendor, a malformed account, an unsafe account name, a non-string label, an empty or unverifiable `expect`, or a default naming an undefined account is reported as `ACCOUNTS: invalid config/accounts.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
A file that exists but cannot be read never fails a launch that asked for no pin: the launch warns and continues on the ambient account, and only an explicit `--account` it cannot resolve refuses.

### What is verified

Both vendors isolate a login, by different mechanisms, and both were proven on a maintainer's machine on 2026-09-09.

Codex keeps its credential in the `auth.json` inside `CODEX_HOME`, so two codex accounts are two independent logged-in homes (codex-cli 0.153.4: the ambient home reported `Logged in using ChatGPT` while an override home reported `Not logged in`).

Claude namespaces its macOS keychain item per config directory.
Logging a second seat in under `CLAUDE_CONFIG_DIR` added a `Claude Code-credentials-<hash>` item beside the original `Claude Code-credentials` item and left the ambient seat untouched (claude 2.1.258).
Both seats then reported `loggedIn: true` at the same time, and neither home held a `.credentials.json`, because the credential lives in that namespaced keychain item rather than in the config directory.
So two Claude seats do coexist on one machine, and a pinned home is unauthenticated only until its own login.

That same proof is why `expect` matters.
The two seats in that proof shared one email address and differed only in organization and plan: the ambient seat reported `subscriptionType: max` in a personal organization, and the pinned seat reported `subscriptionType: team` in a company organization.
An email would not have told them apart; the organization id does.

`claude auth status` prints its JSON on stdout for both outcomes and exits 0 when logged in and 1 when logged out.
Gate on the `loggedIn` field rather than the exit status, which cannot distinguish a logged-out home from a CLI that failed to answer.

Quota monitoring follows a pin rather than reporting the ambient account.
`quota-axi` 0.1.41 reads the pinned home's own credential for both vendors, and for a pinned Claude seat it finds that home's namespaced keychain item.
A newly logged-in seat costs one keychain approval before its first read, reported as `keychain_prompt_required` with the remedy `quota-axi --allow-keychain-prompt`; that approval is the captain's to grant, and reads succeed without a prompt afterwards.
Each seat then reports its own pools: on 2026-09-09 the two seats showed different session and weekly percentages, different reset times, and an extra-usage pool that only one of them has.

Hosted connectors are per seat, which is the practical reason to pin one.
Two workers launched at once on 2026-09-09, one pinned to the Team seat and one on the ambient Max seat, reported 38 and 4 connector tools respectively, and only the Team worker had the organization's Asana connector, which it called successfully.
Account pinning cannot move a connector between seats; it only makes it possible to run on the seat that already has one.

Secondmate homes do NOT inherit this file.
Account homes are per-machine and per-login: the derived paths live under one home's own `data/`, and the credentials in them are physically tied to the logins performed on that machine.
Copying the registry into another home would name accounts whose homes do not exist there and whose logins cannot be shared, so each home defines its own accounts or none at all.

## Capability outcome log (data/capability-outcomes.log)

Firstmate records how each harness/model/effort combination performs per task type so dispatch can consult recent evidence without replacing cost rules.
`bin/fm-capability-lib.sh` owns the wire format, the outcome rules, the 7-day recency window, ranking, and the advisory scout-tax suggestion.
`bin/fm-teardown.sh` appends one line on ship or scout cleanup (not secondmate), and `bin/fm-dispatch-select.sh --task-type <slug>` surfaces the window for that slug.
The log is a captain-inspectable plain-text file under the home's private `data/`; there is no new runtime dependency.

Each append-only line is:

```text
<unix-epoch>|<task-type>|<harness>|<model>|<effort>|<outcome>[|<fix-rounds>[|<steers>]]
```

`outcome` is derived from the task's recorded validation result at teardown, never from the teardown mode.
`green` means validation passed on the first try: exactly one pipeline attempt is recorded for the task branch.
`fixed` means validation passed only after earlier recorded attempts, and its `fix-rounds` field counts those earlier attempts.
`failed` means validation ran but its newest recorded attempt did not pass.
An attempt passed when it completed, or when it was cancelled after its own PR step completed and that PR merged, since firstmate may merge once every step before ci passed and then abort the run still monitoring ci.
`merged` means direct-PR or local-only work landed with no follow-up: its branch's content never changed after the worker's first `done:` report, so a pure rebase still counts as merged.
Teardown keeps `merged` or `revised` only when it proves the landing before removing the worktree: a merged PR for direct-PR, or for local-only a head on the local default branch or content already in it; unproven work records `unknown`.
`revised` means such work landed only after follow-up commits: the patch-ids of its branch-only commits at the ready-time head and at the final head differ, and its `fix-rounds` field counts the branch moves after that first report; when they cannot be compared the outcome is `unknown`.
`reported` means a scout left a non-empty report.
`unknown` means no result was derivable (no pipeline record, an untimed first `done:` report, a branch that never moved, an unproven landing, or no scout report); a ship whose worktree slot teardown finds reassigned to another task also records `unknown` with no `fix-rounds`, since that slot's branch history is no longer the task's.
`discarded` records an approved `--force` teardown.
Density counts `green` and `merged` as first-try successes, counts `revised` and every other outcome toward the total only, and leaves `reported` out of both.
The trailing counts are written only when derivable: `steers` counts confirmed supervisor sends recorded per task by `bin/fm-send.sh` into a counter `bin/fm-spawn.sh` starts empty, so an unsteered task records 0, and an empty `fix-rounds` slot is retained when only `steers` is known.
Older six-field lines without trailing counts stay valid, and readers treat missing counts as absent rather than guessing them.
`task-type` comes from meta `task_type=` when `fm-spawn.sh --task-type <slug>` recorded it, otherwise from `kind` (`ship` or `scout`).
Fields never contain `|` or newlines.

Cost rules in `config/crew-dispatch.json` always win: evidence only ranks or advises within the already cost-filtered `use` array and never bypasses the third-party-model guard.
With `--task-type`, dispatch-select prints `CAPABILITY_EVIDENCE:` lines on stderr for firstmate.
About 10% of those dispatches may also print one `CAPABILITY_SCOUT_TAX:` suggestion naming a different allowed profile; that suggestion is advisory and never changes the selected stdout profile.
`select: capability-recent` makes ranking choose the best recent density inside the allowed array, where density counts first-try successes (`green`, or `merged` with zero follow-ups) over counted samples; a sampled profile outranks an earlier unsampled one only when density is greater than 0, and absent or all-zero evidence keeps configured input order.
Overrides for tests and ops live under Environment variables (`FM_CAPABILITY_*`).

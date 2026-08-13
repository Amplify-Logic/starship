# Porting Firstmate to a second machine

How to bring Firstmate up on another machine, what private material can travel, and how the two supported follow-on models differ.

`bin/fm-home-port.sh` owns the refuse list, secret scan, push/pull mechanics, and the portable data-file list.
The live portable **config** allowlist is printed by `bin/fm-fork-surface.sh port-allowlist`.
`bin/fm-bootstrap.sh` owns toolchain detection - reuse it; do not duplicate missing-tool logic here.
`docs/configuration.md` owns the operational-home layout and config schemas.

## Why this exists

Captain decision 2026-07-21: Firstmate must run on a second machine without copying secrets and without silent two-way auto-sync.

Unattended bidirectional merges corrupt a backlog and lose decisions.
The agreed transport is a **private** git repo holding only portable captain material, with **explicit** pull and push triggered by the captain (or by a one-command handoff the captain pastes).

That transport supports two different follow-on models.
Choose one before you treat a later pull as routine.

## The three layers

| Layer | What | How it moves |
| --- | --- | --- |
| Tracked repo | `AGENTS.md`, `bin/`, skills, docs, workflows | `git clone` / `bin/fm-update.sh` |
| Captain-private portable | The portable data files plus allowlisted non-secret `config/` files (see "Portable allowlist" below) | `bin/fm-home-port.sh` push/pull against a private transport |
| Machine-local, never port | Secrets, `state/`, `projects/`, fleet registries, the capability outcome log, and anything naming an absolute path or a running process on one machine | Recreate on the destination; do not copy |

Porting machine-local material causes real confusion: dead panes, wrong worktree bindings, and watcher locks that belong to another computer.

The transport carries judgment (preferences, backlog, curated machine-independent operating facts), not capability.
Instructions, scripts, and skills stay current on every home through that home's ordinary git fast-forward from its tracked-repo remote, not through home-to-home sync.

## Portable allowlist

The live portable **config** allowlist is manifest-driven.
Print the authoritative list with:

```sh
bin/fm-fork-surface.sh port-allowlist
```

When `fork-surface.conf` is present, that output is the truth `bin/fm-home-port.sh` uses on export, import, push, and pull.
The script also keeps a synced fallback array for checkouts that predate the manifest.
Prose lists of config files in this document are illustrative and will rot; do not treat them as the allowlist.

The portable **data** files are the four regular files named in `bin/fm-home-port.sh`: `data/captain.md`, optional `data/captain-shared.md`, `data/learnings.md`, and `data/backlog.md`.
Exact flags remain in `bin/fm-home-port.sh --help` and its header.

## Secrets do not port

`.env` and any live API credentials stay on each machine.
Each machine holds its own.
`bin/fm-home-port.sh` refuses to include them and reports that refusal loudly rather than silently skipping, so a future operator cannot assume they came across.
It also scans exported material for accidentally embedded credentials before writing or pushing a bundle.

The standing loud-refusal set, when present in the source home, is `.env`, `state/`, `projects/`, `config/action-captain-secret`, `config/cmux-socket-password`, `config/x-mode.env`, `data/projects.md`, and `data/secondmates.md`.
Export and push print a `REFUSED:` line for each of those that exists (or `REFUSED: (none present)` when none of them do).

## What export omits without a transcript line

Loud refusal covers only that standing set.
Every other private path is simply never copied: it is not on the portable data list and not on the live config allowlist, so export and push never visit it.
An export or push transcript therefore shows `PORTABLE:` lines for what travelled and `REFUSED:` lines for the standing set, and **no evidence** that other private material was considered and left behind.

Paths that behave this way today include, when present:

- `data/capability-outcomes.log` (see below; this one must never port)
- `data/goals/` (goal charters; see below)
- `data/done-archive.md`
- `data/upstream-watch/`
- `data/action-gateway/`
- `data/harness-exam/`
- per-task `data/<id>/` briefs and reports
- any `config/` file the live allowlist command does not print

That silence is the current tool behavior, not proof those paths are safe to add later.

## Capability outcome log is machine-local forever

`data/capability-outcomes.log` is not merely unported today.
It must stay on the machine that produced it.

The log records harness, model, and effort outcomes against that machine's subscriptions and quotas (`docs/configuration.md` "Capability outcome log").
Copying it onto another machine would actively mislead dispatch there: routes that are cheap or available on the source can be expensive, missing, or forbidden on the destination.
Each home grows its own log as work on that machine completes.

## Goal charters do not port today

Per-project goal charters live at `data/goals/<project>.md` (`docs/chart-room.md`).
They are not on the portable data list.
The copy path only accepts regular files, so a directory of charters cannot travel without new directory-entry support that neither the data list nor the config manifest has.
Treat that as a known limitation: charters stay on the home that wrote them unless a later change adds that support.

## Step zero: push from the source machine first

Before the destination runs bootstrap against the private transport, the source machine must push portable material at least once:

```sh
bin/fm-home-port.sh push --remote <owner>/<portable-repo> [--create-private]
```

Otherwise the destination pull finds an empty transport and the first-run handoff fails for a chicken-and-egg reason, not a real porting bug.

For the independent-peer model, push a **pruned seed profile**, not the live source home as-is.
`push` accepts `--home`, so you can stage the files that should exist on the destination and push from that staging directory.

Optional fidelity aid on both machines after the toolchain is installed:

```sh
bin/fm-bootstrap.sh manifest
```

Compare the two manifests to catch tool-version drift before trusting the port.

## One-command handoff

Prerequisites:

1. Step zero above has already populated the private transport from the source machine.
2. On the destination machine: GitHub CLI already authenticated to the account that owns your private portable transport (`gh auth status`).

Paste **one** command into a terminal, substituting your tracked firstmate clone URL and private portable repo:

```sh
gh repo clone <owner>/firstmate ~/starship && cd ~/starship && bin/fm-home-port.sh bootstrap --portable-repo <owner>/<portable-repo>
```

That clones the tracked repo, pulls captain-private portable material from the private transport, creates empty `state/` and `projects/`, and runs bootstrap detection.
It does **not** log into harness CLIs - those need interactive logins (see below).

After this first pull, follow the model you chose under "Two models after the seed".
The independent-peer model treats this pull as the last one.

### Agent prompt to finish what the script cannot

After the one-command finishes, paste this into a coding agent launched inside `~/starship`:

```text
You are bringing Firstmate up on this second machine after the one-command bootstrap.
Read docs/porting.md and follow it.

Do this, in order:
1. Run `bin/fm-bootstrap.sh` and resolve every MISSING: / MISSING_MANUAL: / NEEDS_GH_AUTH line (ask before installing; reuse bootstrap, do not invent a parallel installer).
2. Confirm portable files landed: data/captain.md, data/learnings.md, data/backlog.md, and config/backend plus config/crew-harness and config/crew-dispatch.json when present.
3. Rewrite any absolute paths that still point at the other machine (especially CLAUDE_CONFIG_DIR under data/captain.md / data/learnings.md) to THIS machine's paths under ~/starship. Do not copy credential directories from the other machine.
4. Recreate Claude alternate-account isolation if needed: mkdir -p state/claude-alt-account and document CLAUDE_CONFIG_DIR=$PWD/state/claude-alt-account for login on this machine. Credentials are obtained by interactive `claude` login on this machine only.
5. Walk me through the interactive harness logins I must do myself, in this order: gh (already done), claude, Cursor CLI (agent), codex, kimi (if used), pi (if used). Do not claim you can automate those logins.
6. Verify before real work: session-start digest loads captain preferences and learnings; bootstrap is clean of actionable missing tools; no .env was imported; state/ and projects/ are empty or local-only. Report what you verified and what still needs my interactive login.
```

## Two models after the seed

Private transport: a GitHub repo that must remain **private** (example shape: `<owner>/<portable-repo>`).
The tool verifies GitHub reports `visibility=private` before any push.
If it cannot positively confirm private visibility, it stops and refuses to push.

First-time creation of the private transport (only when it does not exist yet):

```sh
bin/fm-home-port.sh push --remote <owner>/<portable-repo> --create-private
```

Pick **one** of the two models below.
Do not mix them on the same destination home.

### Replica sync

Use this when the destination should stay a replica of the source home: same preferences, same learnings, same task list, refreshed by explicit later pulls.

**Warning: a later pull overwrites the destination.**

`pull` replaces each allowlisted file that exists in the transport with the source copy.
It does not merge.
It does not keep a backup of the destination's copies.

If the destination home has started keeping its own preferences, learnings, or task list, a later pull replaces those files with the source's versions and those local edits are gone.
That is the replica contract working as designed, not a rare corruption edge.
Do not pull again unless you intend the destination to match the source.

On the machine that has newer portable material:

```sh
bin/fm-home-port.sh push --remote <owner>/<portable-repo>
```

On the machine that should receive it (only when you intend that overwrite):

```sh
bin/fm-home-port.sh pull --remote <owner>/<portable-repo>
```

#### Conflict story (replica only)

If both machines edited the same portable file before syncing:

1. Decide which machine is the source of truth for this sync (usually the one where the captain made the intentional change).
2. Push from that machine, or pull then manually merge the conflicting file in a checkout of the portable transport, then push.
3. Pull on the other machine.
4. Never set up unattended bidirectional sync, cron mirrors, or auto-merging agents against the portable repo - backlog and decision text are not merge-safe under silent reconcile.

### Independent-peer seed-once

Use this when the destination should become its own home after the first seed: its own preferences, its own task list, its own operating facts from then on.

1. On the source machine, stage a pruned profile (only the judgment that should exist on the destination).
2. Push that staging directory once to a private transport that exists for this seed (`push --home <staging> --remote <owner>/<portable-repo>`).
3. On the destination, pull exactly once (the one-command bootstrap already does this).
4. **Never pull that transport again.**

After that seed, the two homes evolve independently.
A later pull would still overwrite the destination the same way the replica model does, so the independent-peer contract is: do not pull again.

Tracked-repo updates still reach both homes through each home's ordinary git fast-forward from its fork remote (`bin/fm-update.sh` / `/updatefirstmate`).
That path updates instructions, scripts, and skills.
It does not copy `data/`.
Capability stays current without any home-to-home sync.

The seed transport is not a shared ongoing sync channel.
If a specific file later needs to move by hand, that is a named one-off the captain triggers, with an explicit source of truth for that file.
Each home may also push *its own* portable material to *its own* private backup remote; those backups must not cross.

## Required tooling

Do not maintain a second missing-tool list here.
Run `bin/fm-bootstrap.sh` (or start a primary session so `bin/fm-session-start.sh` runs it) and handle the diagnostic lines it prints.
Toolchain ownership and install hints live in `docs/configuration.md` ("Toolchain") and `bin/fm-bootstrap.sh`.

## Harness CLIs and logins (cannot be automated)

Each harness keeps its own interactive login.
Expect these, in order, on a fresh machine:

1. **GitHub CLI** - `gh auth login`.
2. **Claude Code** - run `claude` and complete its login; for an alternate account use a machine-local `CLAUDE_CONFIG_DIR` under this home's `state/` (pattern in `data/learnings.md`).
3. **Cursor CLI** - run the Cursor agent CLI login for worker dispatch.
4. **Codex** - run `codex` login when that pool is used.
5. **Kimi Code** - login when using the Kimi primary.
6. **Pi** - login when using Pi.

No script can complete those logins unattended.
The one-command bootstrap is successful when the portable material and toolchain detection are in place; harness auth remains a captain step.

## Absolute paths

Portable prose may still mention the other machine's paths (for example an old `CLAUDE_CONFIG_DIR=$HOME/starship/state/claude-alt-account` line).
After import, rewrite those to the new machine's home.
Never copy the credential directory itself across machines.

After a pull or import, run an advisory machine-local scan so path and email rewrites are not a hand hunt:

```sh
bin/fm-home-port.sh scan --warn-machine-local /path/to/exported-or-home-data
```

That pass reports emails and `/Users/<name>/` paths using the same pattern owner as the public-repo CI leak guard (`bin/fm-leak-lib.sh`).
It never fails the scan by itself; only embedded credentials change the exit code.

## Verify before trusting the port

Run the destination readiness command (owns the mechanical checks below plus `config/backend` / `config/crew-harness` presence):

```sh
bin/fm-home-port.sh verify
```

It reports `VERIFY_PASS` / `VERIFY_FAIL` / `VERIFY_INFO` per check and exits non-zero when any check fails.
The checks are:

1. `data/captain.md`, `data/learnings.md`, and `data/backlog.md` are present.
2. `.env` was not imported (informational only - the port refuses `.env` by construction; absent or a local file both report `VERIFY_INFO`).
3. `state/` and `projects/` exist (empty is fine).
4. `bin/fm-bootstrap.sh` prints no unresolved actionable `MISSING:` / `NEEDS_GH_AUTH` lines you have not accepted.
5. Captain preferences and learnings are non-empty inputs for the session-start digest (then start a primary of choice and confirm the digest visually).
6. Only then dispatch real work.

Also: when `config/backend` or `config/crew-harness` is set, verify confirms the backend is known with its tools present and the harness is a verified worker with its launch binary on `PATH`.

## Local export/import (USB or review)

```sh
bin/fm-home-port.sh export --dest /tmp/fm-portable-staging
bin/fm-home-port.sh import --source /tmp/fm-portable-staging --home /path/to/new-home
bin/fm-home-port.sh scan --warn-machine-local /tmp/fm-portable-staging
bin/fm-home-port.sh verify --home /path/to/new-home
```

Import uses the same overwrite copy as pull.
Do not import onto a home whose portable files you still need unless that overwrite is intended.

## Related owners

- Operational home layout: `docs/configuration.md`
- Toolchain detection: `bin/fm-bootstrap.sh`
- Tracked-repo self-update: `bin/fm-update.sh` / `/updatefirstmate`
- Live portable config allowlist: `bin/fm-fork-surface.sh port-allowlist`
- Exact port flags, data-file list, and refuse list: `bin/fm-home-port.sh --help` and its header
- Goal charter format: `docs/chart-room.md`
- Capability outcome log format: `docs/configuration.md` ("Capability outcome log")

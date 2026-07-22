# Porting Firstmate to a second machine

How to bring Firstmate up on another machine and keep captain-private material in step over time.

`bin/fm-home-port.sh` owns the portable allowlist, refuse list, secret scan, and push/pull mechanics.
`bin/fm-bootstrap.sh` owns toolchain detection - reuse it; do not duplicate missing-tool logic here.
`docs/configuration.md` owns the operational-home layout and config schemas.

## Why this exists

Captain decision 2026-07-21: Firstmate must run on a second machine and stay aligned, without copying secrets and without silent two-way auto-sync.

Unattended bidirectional merges corrupt a backlog and lose decisions.
The agreed design is a **private** git repo holding only portable captain material, with **explicit** pull and push triggered by the captain (or by a one-command handoff the captain pastes).

## The three layers

| Layer | What | How it moves |
| --- | --- | --- |
| Tracked repo | `AGENTS.md`, `bin/`, skills, docs, workflows | `git clone` / `bin/fm-update.sh` |
| Captain-private portable | `data/captain.md`, `data/learnings.md`, `data/backlog.md`, optional `data/captain-shared.md`, non-secret `config/` operating choices | `bin/fm-home-port.sh` push/pull against a private transport |
| Machine-local, never port | `state/`, `projects/`, `.env`, `config/cmux-socket-password`, `config/x-mode.env`, `data/projects.md`, `data/secondmates.md`, anything naming an absolute path or a running process on one machine | Recreate on the destination; do not copy |

Porting machine-local material causes real confusion: dead panes, wrong worktree bindings, and watcher locks that belong to another computer.

## Secrets do not port

`.env` and any live API credentials stay on each machine.
Each machine holds its own.
`bin/fm-home-port.sh` refuses to include them and fails loudly rather than silently skipping, so a future operator cannot assume they came across.
It also scans exported material for accidentally embedded credentials before writing or pushing a bundle.

## One-command handoff

Prerequisite on the destination machine: GitHub CLI already authenticated to the account that owns your private portable transport (`gh auth status`).

Paste **one** command into a terminal, substituting your tracked firstmate clone URL and private portable repo:

```sh
gh repo clone <owner>/firstmate ~/starship && cd ~/starship && bin/fm-home-port.sh bootstrap --portable-repo <owner>/<portable-repo>
```

That clones the tracked repo, pulls captain-private portable material from the private transport, creates empty `state/` and `projects/`, and runs bootstrap detection.
It does **not** log into harness CLIs - those need interactive logins (see below).

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

## Ongoing sync (explicit, captain-triggered)

Private transport: a GitHub repo that must remain **private** (example shape: `<owner>/<portable-repo>`).

On the machine that has newer portable material:

```sh
bin/fm-home-port.sh push --remote <owner>/<portable-repo>
```

On the machine that should receive it:

```sh
bin/fm-home-port.sh pull --remote <owner>/<portable-repo>
```

First-time creation of the private transport (only when it does not exist yet):

```sh
bin/fm-home-port.sh push --remote <owner>/<portable-repo> --create-private
```

The tool verifies GitHub reports `visibility=private` before any push.
If it cannot positively confirm private visibility, it stops and refuses to push.

### Conflict story

If both machines edited the same portable file before syncing:

1. Decide which machine is the source of truth for this sync (usually the one where the captain made the intentional change).
2. Push from that machine, or pull then manually merge the conflicting file in a checkout of the portable transport, then push.
3. Pull on the other machine.
4. Never set up unattended bidirectional sync, cron mirrors, or auto-merging agents against the portable repo - backlog and decision text are not merge-safe under silent reconcile.

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

## Verify before trusting the port

1. `test -f data/captain.md && test -f data/learnings.md && test -f data/backlog.md`
2. `test ! -e .env` unless this machine created its own deliberately
3. `test -d state && test -d projects` (empty is fine)
4. `bin/fm-bootstrap.sh` prints no unresolved actionable `MISSING:` / `NEEDS_GH_AUTH` lines you have not accepted
5. Start a primary (`bin/fm-primary.sh` profile of choice); confirm the session-start digest shows captain preferences and learnings
6. Only then dispatch real work

## Local export/import (USB or review)

```sh
bin/fm-home-port.sh export --dest /tmp/fm-portable-staging
bin/fm-home-port.sh import --source /tmp/fm-portable-staging --home /path/to/new-home
bin/fm-home-port.sh scan /tmp/fm-portable-staging
```

## Related owners

- Operational home layout: `docs/configuration.md`
- Toolchain detection: `bin/fm-bootstrap.sh`
- Tracked-repo self-update: `bin/fm-update.sh` / `/updatefirstmate`
- Exact port flags and allowlist: `bin/fm-home-port.sh --help` and its header

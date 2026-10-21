# Cloud routines

A Claude Code routine is a saved prompt that Anthropic's cloud runs on a schedule, so it keeps working while the laptop is closed or asleep.
Firstmate uses routines only for fixed, read-only research over public inputs, written to one capped place the captain reviews and imports from the laptop.
The first and only routine is the weekly creator-repo watch, the cloud twin of the laptop's own creator watch.
Both run side by side; the routine does not replace the laptop watch.

Routines have no remote ingress, no gatekeeper, no messaging or spending authority, and no connectors.
Never put a private repository or private data into a routine: its repositories are cloned into Anthropic's cloud.

## The creator-repo watch

[`bin/fm-routine-creator-watch.sh`](../bin/fm-routine-creator-watch.sh) is the whole job, and its header owns the mechanics.
It reads new tags on default-branch commits and recent default-branch commits of a fixed list of public repositories with plain git, and writes one rolling digest, `creator-watch.md`, on the `main` branch of a separate, dedicated public repository, [Amplify-Logic/firstmate-routine-reports](https://github.com/Amplify-Logic/firstmate-routine-reports), which holds nothing else.
Each run replaces that file with one new commit, so that repository's history is the audit log of every run.
A release tag on a commit that is not on a repository's default branch is not in the digest; the laptop creator watch, which keeps running alongside, covers those.
The routine holds no write access to firstmate as long as the claude.ai account's GitHub connection is the Claude GitHub App only, with no `/web-setup` gh token stored (setup step 3): its clone of this repository is only read to run the script, and the script builds its commit in a temporary repository.

The routine's saved prompt tells its model to run that one script and nothing else.
The model never reads the digest, so release names and commit subjects from other people's repositories never reach it as instructions.

| Setting | Value |
| --- | --- |
| Name at claude.ai/code/routines | firstmate creator-repo watch (public repos only) |
| Schedule | Mondays at 05:17 UTC |
| Model | Claude Haiku 4.5 |
| Tools | Bash only |
| Connectors | none; every connector the form adds by default was removed |
| Repositories | this firstmate repository, which is public, cloned and only read; and Amplify-Logic/firstmate-routine-reports, added in setup step 4 so the push can reach it |
| Publishes to | `main` of Amplify-Logic/firstmate-routine-reports |
| Environment | a dedicated environment with network access **None** (setup step 5); until then it points at the Default environment only because it stays disabled |

## What it can and cannot touch

It can:

- Clone this public repository at the start of each run.
- Read public git data of the repositories listed in the script.
- Push one commit to `main` of the reports repository, once the Claude GitHub App is installed on that repository (see below).

It cannot:

- Push to firstmate or any repository other than the reports repository, as long as the claude.ai account's GitHub connection is the Claude GitHub App only, with no `/web-setup` gh token stored: the Claude GitHub App is installed on the reports repository only. A stored `/web-setup` token lets cloud sessions push to any repository that token can reach, whether or not the App is installed there.
- Use the GitHub API or github.com pages for any repository other than its own: the cloud's GitHub proxy refuses them.
- Reach any host other than GitHub, once it runs in the **None** environment.
- Use Gmail, Drive, Calendar, Docs, or any other connector.
- Read anything on the laptop, the firstmate home, or a private repository.
- Delete a branch or push a tag: the GitHub proxy refuses both.

Probe runs of the routine on 3 October 2026 confirmed the GitHub API, github.com page, and outside-host refusals, a refused push to this repository, where the App is not installed, and that public git reads of other repositories succeed.
The push to the reports repository is not proven yet: the first manual **Run now** in setup step 6 verifies it before the schedule is trusted, and a refused push exits 1 and publishes nothing.

The GitHub proxy does not limit which branch a push updates, so the boundary is the repository the App is installed on, not the script: as long as the claude.ai account's GitHub connection is the Claude GitHub App only, with no `/web-setup` gh token stored, whatever the routine's model does, it cannot write to firstmate, the repository the laptop updates itself from.

## One-time setup

The routine stays disabled until the captain has done all of these, in order:

1. Create the empty public repository Amplify-Logic/firstmate-routine-reports, with no README or other initial file.
2. Install the Claude GitHub App on Amplify-Logic, scoped to that repository only.
3. Check how the claude.ai account connects to GitHub: it must be the Claude GitHub App only. If a `/web-setup` gh token is stored on the account, remove it before enabling the routine, and do not run `/web-setup` again while the routine exists.
4. Add Amplify-Logic/firstmate-routine-reports to the routine's repositories.
5. Create a dedicated cloud environment with network access **None** in the environment dialog at claude.ai, and point the routine at it.
6. Only then, with this script on firstmate's default branch, start one manual **Run now** at claude.ai/code/routines and confirm a commit landed on `main` of the reports repository; that run verifies the push before the schedule is trusted.
7. Turn the routine's schedule on.

## Reviewing a report

Each report is the `creator-watch.md` file on `main` of the reports repository, and that repository's history holds every earlier run.
The laptop check that wakes firstmate when a new report lands is not part of this repository: it lives in the private add-on of the home that reviews the reports (`docs/configuration.md` "Private add-on").

## Kill switch

- Pause the routine with its on/off switch at claude.ai/code/routines, or delete it from the menu next to its name.
- From a firstmate Claude session, the routine tools can set it to disabled; they cannot delete it.
- Add a file named `PAUSED` to `main` of the reports repository: the script then publishes nothing until it is removed.
- Uninstall the Claude GitHub App, or remove the reports repository from it, to take away write access entirely; this holds only while no `/web-setup` gh token is stored on the claude.ai account, so remove any such token as well.

## Cost and limits

Runs count against the Max plan's normal usage, with no separate bill and no overage unless usage credits are turned on.
One run is one short Haiku session a week.
The script bounds each git read, the whole sweep, the clone depth, and the digest size, and publishes nothing when every read fails.

## Network setting

GitHub traffic takes its own proxy at every network level, so **None** is the most restrictive setting that still reaches GitHub, and the routine requires it.
A dedicated environment with **None** can only be created in the environment dialog at claude.ai, not from the command line, which is why it is a setup step.
The routine points at the Default environment for now only because it is disabled until that step is done; it is never enabled there.
Changing the Default environment itself would also change every other cloud session.

---
name: catchup
description: >-
  Catch this home's firstmate checkout up with its own configured upstream, and report which stack tools are behind.
  Use when the captain invokes /catchup or asks to catch up Starship or firstmate with its upstream (e.g. "catch up Starship", "merge the latest from upstream"), on an `UPSTREAM_CATCHUP:` line from the session-start digest or a run, on an `upstream-catchup:` check wake, and before turning the weekly catch-up on or off for this home.
  Prepares the catch-up as a real merge on a branch through the home's normal delivery path and stops for the captain to approve the merge; never merges on its own, never publishes to the upstream, and installs no tool.
user-invocable: true
metadata:
  internal: true
---

# catchup

A home whose firstmate checkout is a fork carries changes of its own on top of an upstream: Starship on top of Kun Chen's firstmate, or a teammate's fork on top of Starship.
Catching up merges the upstream's new work into the home's own checkout while keeping every change the home made.
It is not `/updatefirstmate`, which only fast-forwards the home from its own origin and cannot bring upstream work into a fork.

Each home catches up with its own upstream, through its own opt-in or its own captain's request.
Never assume one home's catch-up result applies to another: a fork that looks like this one may carry its own customisations, so never push a catch-up branch to another home, never tell another home its merge is safe, and never turn catch-up on for a home other than this one.
A secondmate home runs no catch-up of its own; it receives the main home's landed result through `/updatefirstmate`.

`bin/fm-upstream-watch.sh` owns the fetch, the report, the catch-up plan, and the pending and notice records; its header and `--help` own the exact commands and output lines.
`bin/fm-stack-versions.sh` owns the tool-version section; it only reports.

## Turning it on or off

The weekly catch-up is off by default for every home, and only this home's captain switches it on, in their own words, for this home.
It needs a checkout with an `upstream` remote that differs from `origin`; a plain clone of Starship has nothing to catch up through this and stays current with `/updatefirstmate`.

To turn it on:

1. Add `catchup = on` to private `config/upstream-watch`, keeping any `interval_seconds` line; set `interval_seconds = N` there for a cadence other than weekly ([docs/configuration.md](../../../docs/configuration.md#standing-upstream-watch-configupstream-watch)).
2. Save the captain's own words asking for it, verbatim, to `data/upstream-watch/standing-request.md`; a scheduled catch-up quotes them as its captain's intent.
3. Run `bin/fm-upstream-watch-schedule.sh install` to load the schedule (macOS launchd), and `bin/fm-upstream-watch.sh arm` so a running firstmate hears about a prepared catch-up without waiting for the next session start.

To turn it off, set `catchup = off` and run `bin/fm-upstream-watch.sh disarm`; the weekly report itself keeps running until `bin/fm-upstream-watch-schedule.sh remove`.

## Preparing a catch-up

1. One catch-up at a time: when a catch-up task is already under way or its PR is waiting for the captain, do not start another; tell the captain the newer upstream work will be in the next one.
2. On the captain's request, run `bin/fm-upstream-watch.sh catchup`; on an `UPSTREAM_CATCHUP:` line or an `upstream-catchup:` notice, an earlier run, scheduled or on demand, has already written the report it names.
3. Read the report.
   When it says there is nothing to catch up, tell the captain so, relay the tool versions, and acknowledge the report.
4. Otherwise dispatch a ship on this home's firstmate checkout under the ordinary intake: load `firstmate-self-repo`, use the delivery mode this home registers for that checkout, and never add `--upstream-consent` for a catch-up.
   The PR targets the home's own `origin`, never the upstream.
   A home with no publication authority for its own fork delivers the catch-up `local-only`, which publishes nothing.
5. Fill the brief's captain's intent with the captain's own request; when the catch-up came from an `UPSTREAM_CATCHUP:` line or notice rather than a request in this session, use the words saved in `data/upstream-watch/standing-request.md`, and when none are saved, ask the captain for their request before dispatching.
   Add the report's substance: the upstream URL and the exact commit to merge, this home's own commit count, the files both sides changed, and the trial merge's conflicts.
   Put these build rules in the firstmate spec:
   - Fetch that upstream branch and merge exactly the named commit with `git merge --no-ff`, a real merge commit, never a squash, rebase, or cherry-pick.
   - Before merging, list this home's own commits the upstream lacks and the files both sides changed, and say plainly in the PR which overlaps the merge touched.
   - Resolve each conflict so both behaviours survive; where that is impossible, keep this home's behaviour and list the file and what was not taken from the upstream.
   - Delete, rename, or revert none of this home's own changes to match the upstream; when the checkout carries `bin/fm-fork-surface.sh`, run its check and follow its rules for the upstream base.
   - Open the PR body with "Merge this PR as a merge commit, not a squash or rebase", because a squash loses the merge base the next catch-up needs.

## Landing

The catch-up always stops for the captain's word, whatever the home's `yolo` posture: ask with the PR's full URL, the conflicts and how each was resolved, and anything kept from this home over the upstream.
Follow `ship-landing`, and merge the PR only with `bin/fm-pr-merge.sh <task-id> -- --merge`, never the default squash; a `local-only` catch-up lands through `bin/fm-merge-local.sh`, whose fast-forward keeps the merge commit.
After it lands, acknowledge the report with `bin/fm-upstream-watch.sh acknowledge <path>` and bring the running home onto it with `/updatefirstmate`.

## Tool versions

Every report ends with each stack tool's installed version against its latest release.
Relay what is behind in plain words, and install nothing on your own.
A small update waits for the captain's yes.
A Herdr or treehouse upgrade needs a quiet window with no workers running, because every worker window, including firstmate's, runs inside Herdr and every worker's isolated copy comes from treehouse: book it with the captain as a held item and run it only in that window, taking Herdr to the version Starship pins in `bin/fm-install-herdr.sh` rather than a newer unverified release.

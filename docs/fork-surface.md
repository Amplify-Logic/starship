# Declared fork surface

`fork-surface.conf` is the public inventory of capability this fork carries beyond its recorded upstream base.
`bin/fm-fork-surface.sh` is the single owner of its schema, queries, base snapshot, and CI assertions.

## Layers

- `shared` is fork-authored capability intended to ship to every clone of this fork.
- `personal` is capability declared publicly while its values remain in ignored `config/` or `data/` paths.
- `converged` records work ported from upstream so drift accounting does not mislabel it as fork invention.

Every capability also has a distribution scope.
`core` and `team` capabilities are required and their declared assertions fail CI when they disappear.
`personal` capabilities remain declared as a public inventory but are optional, so another copy can omit them without weakening required-surface checks.

The `topology = herdr-topology` marker is query metadata for the open Herdr topology choice.
It does not select a topology.
A capability with `assert = test` is defended by behavior rather than by the continued existence of its current owned files, so implementation files can change without deciding that choice in advance.

## Commands

Run `bin/fm-fork-surface.sh check` to validate the manifest and all declared assertions.
Run `bin/fm-fork-surface.sh list` for active and frozen capability titles, or add `--topology herdr-topology` to select topology-sensitive entries.
Run `bin/fm-fork-surface.sh list --config` to append each capability's optional config and secret paths.
Run `bin/fm-fork-surface.sh paths` to print each capability-owned path.
Run `bin/fm-fork-surface.sh port-allowlist` to print portable, non-secret config paths.

`fork-surface.upstream-base` is a sorted path snapshot, not a fetched reference.
After a reviewed merge-base advance, update the manifest's `upstream_base`, run `bin/fm-fork-surface.sh sync-base`, and review both changes together.
The command never fetches.

## Assertions

The check validates the schema and commit references, requires declared files according to each core or team capability's `assert` mode, verifies their proving tests and CI jobs, evaluates their optional anchors, and asserts ownership of every tracked path absent from the base snapshot.
Every `commits` entry must be an ancestor of the checked-out history, so a capability records the squash-merge commit on the default branch, which no later rebase or squash rewrites.
A branch commit is rejected even while it still resolves locally, because a clone keeps rebased-away objects that a fresh clone and CI never receive, which is what let an entry pass locally and fail CI.
A capability introduced by an unmerged pull request cannot yet know its squash-merge commit, so it records the literal `pre-merge`, which survives every rebase and squash, and is repaired to the squash-merge commit after landing.
It never records an unrelated commit that happens to be an ancestor, because `check` only proves that a reference is part of this history and cannot detect misattributed provenance.
Declared personal paths are checked for unique ownership when present but may be absent.
It also requires secret config to stay ignored and refused by home porting, and requires portable config declarations to agree with the home-port fallback.
Failures name the capability and concrete repair instead of modifying the tree.

## Refactors and retirement

Update `fork-surface.conf` in the same commit that adds, moves, or removes a fork-only path.
Anchors are stable regular expressions chosen by the capability author, not line numbers or hashes.
A legitimate refactor updates the owned paths and anchors with the implementation.

Retirement is explicit.
Set `status = retired`, add `retired_reason` and `retired_pr`, and remove all owned paths in the same reviewed change.
The gate rejects both silent deletion and a retired declaration whose files still remain.

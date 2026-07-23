---
name: second-opinion-auto-fire
description: >-
  Agent-only second-opinion auto-fire trigger for Firstmate's convergent rival-model review front-end.
  Load before committing to an architectural, security-sensitive, schema/API-contract, or otherwise high-stakes design or decision output.
  Owns when to stress-test via bin/fm-second-opinion.sh, when to refuse, when to offer on a borderline call, and the mandatory Codex/OpenAI-via-Pi cost announcement.
user-invocable: false
metadata:
  internal: true
---

# second-opinion-auto-fire

This skill is the single owner of Firstmate's convergent second-opinion auto-fire trigger.
It is the counterpart to `adhd-auto-fire`: ADHD fans out options before the pick; this skill stress-tests the pick after, before it becomes build orders.
Wrapper flags, the reviewer registry, the neutral-cwd rule, and the standing cost policy live in `docs/second-opinion.md`.
The CLI wrapper is `bin/fm-second-opinion.sh`.

## When to fire

Fire a rival-model second opinion only when about to commit to a high-stakes design or decision output:

- Architectural choices that will shape later work
- Security-sensitive designs or trust boundaries
- Schema or API contract decisions that will stick
- Other high-stakes picks where a hostile second look can still change the plan

When it fires, run `bin/fm-second-opinion.sh --out <path> -- "<decision-or-design>"` with optional `--context` files, then read the review before turning the pick into build orders.

## When never to fire

Never auto-fire for:

- Routine coding or mechanical edits
- Mechanical ports
- Status, monitoring, or fleet bookkeeping
- Decisions already stress-tested in this thread (or with an equivalent recent review on disk)
- Cheap or time-critical work where a Codex/OpenAI-via-Pi spend is unjustified

For those, proceed with ordinary reasoning and do not spend a second-opinion run.

## Borderline calls

On a borderline call, offer a rival-model second opinion rather than silently spending or silently skipping.
Ask the captain one concise yes-or-no whether to run it for the named decision.
If they decline, continue without it.
If they accept, treat it as an authorized fire and follow the cost announcement below.

## Cost transparency

Whenever a second opinion fired - auto-fire or an accepted offer - announce in the same turn that a rival-model second opinion was spent and that it drew the Codex/OpenAI pool via Pi.
Never hide a spend behind a quiet improvement in the answer.

## Boundaries

- Never set or require `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`; the wrapper strips ambient keys and keeps the Pi subscription path.
- The wrapper must run the reviewer from a neutral working directory; never launch `pi --print` from the firstmate checkout or a project clone for this purpose.
- Second-opinion output is evidence for the decision, not authorization to change code, open a PR, or merge.
- Quota below the wrapper floor is a loud refusal unless `FM_SECOND_OPINION_FORCE=1`; relay that refusal rather than inventing a bypass.

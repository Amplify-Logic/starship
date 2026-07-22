---
name: adhd-auto-fire
description: >-
  Agent-only ADHD auto-fire trigger for Firstmate's divergent-ideation front-end.
  Load before committing to a genuinely divergent, fuzzy, high-leverage decision (design, architecture, API/schema shape, naming, strategy, approach-selection, hard/ambiguous debugging).
  Owns when to fan out via bin/fm-adhd.sh, when to refuse, when to offer on a borderline call, and the mandatory ~2x cost announcement.
user-invocable: false
metadata:
  internal: true
---

# adhd-auto-fire

This skill is the single owner of Firstmate's ADHD auto-fire trigger.
Manual `/adhd` invocation is owned by the captain-invocable `adhd` skill.
Install, uninstall, wrapper flags, and the standing cost policy live in `docs/adhd.md`.

## When to fire

Fire ADHD only for a genuinely divergent, fuzzy, high-leverage decision where premature convergence is the risk:

- Design choices with multiple credible shapes
- Architecture tradeoffs
- API or schema shape
- Naming that will stick
- Strategy or approach-selection among real alternatives
- Hard or ambiguous debugging where several causal stories fit

When it fires, run `bin/fm-adhd.sh --out <path> --quiet -- "<decision>"` with the wrapper's bounded defaults unless a tighter bound is clearly enough, then read the distilled file before committing to one answer.

## When never to fire

Never auto-fire for:

- Routine coding or mechanical edits
- Factual lookups
- Status, monitoring, or fleet bookkeeping
- Already-decided questions
- Single-option questions with no real fork
- Cheap or time-critical work where about ~2x a single reasoning pass is unjustified

For those, proceed with ordinary reasoning and do not spend an ADHD run.

## Borderline calls

On a borderline call, offer to fan out rather than silently spending or silently skipping.
Ask the captain one concise yes-or-no whether to run ADHD for the named decision.
If they decline, continue without it.
If they accept, treat it as an authorized fire and follow the cost announcement below.

## Cost transparency

Whenever ADHD fired - auto-fire or an accepted offer - announce that ADHD fired and that it spent about ~2x a single reasoning pass.
Do this in the same turn the result is used.
Never hide a spend behind a quiet improvement in the answer.

## Boundaries

- Never set or require `ANTHROPIC_API_KEY`; the wrapper keeps the Claude subscription path.
- If the wrapper exits 127, relay the install instructions and `docs/adhd.md`; do not invent a local trial path.
- ADHD output is evidence for the decision, not authorization to change code, open a PR, or merge.

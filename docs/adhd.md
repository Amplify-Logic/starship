# ADHD divergent-ideation front-end

Firstmate uses the MIT [ADHD](https://github.com/UditAkhourii/adhd) project (`adhd-agent` on npm) as its divergent-ideation front-end for high-leverage decisions.
The captain adopted it on 2026-07-23 after a bounded trial.
This doc owns install, uninstall, usage, and the standing cost policy.
The captain-invocable skill is `.agents/skills/adhd/SKILL.md`.
The auto-fire trigger is `.agents/skills/adhd-auto-fire/SKILL.md`.
The CLI wrapper is `bin/fm-adhd.sh`.

## What it is for

ADHD fans out many parallel divergent thoughts under different cognitive frames, scores them, prunes traps, and deepens the survivors.
Reach for it on design, architecture, API or schema shape, naming, strategy, approach-selection, and hard or ambiguous debugging.
Do not use it for routine coding, factual lookups, mechanical or status work, already-decided or single-option questions, or cheap time-critical work.

## Cost policy

A typical ADHD run costs about ~2x a single reasoning pass at the bounded defaults Firstmate uses.
Whenever ADHD fires - captain `/adhd` or orchestrator auto-fire - the orchestrator must announce that ADHD fired and that it spent about ~2x a single reasoning pass.
On a borderline call, the orchestrator offers to fan out rather than silently spending or silently skipping.
Never set or require `ANTHROPIC_API_KEY`.
The trial confirmed ADHD rides the Claude subscription with no API key; cash API billing is out of scope for this integration.

## Install (reversible)

The npm package is `adhd-agent`; the installed CLI binary is `adhd`.

```bash
npm install -g adhd-agent
```

Verify:

```bash
command -v adhd
adhd --help
```

That global CLI install is the only sanctioned write outside a task worktree for this integration.
Do not bake a temporary trial path into tracked code.

## Uninstall

```bash
npm uninstall -g adhd-agent
```

Confirm removal with `command -v adhd` (it should print nothing).

## Usage

Captain manual path: invoke `/adhd` with a named decision; the skill runs the wrapper below.
Orchestrator path: load `adhd-auto-fire` before committing to a qualifying decision, then call the same wrapper when the trigger says fire or the captain accepts an offer.

```bash
bin/fm-adhd.sh --out data/adhd/example.md --quiet -- "design the schema for X"
```

Bounded defaults are `--frames 3 --ideas 4 --top 2`.
Pass `--context <file>`, `--json`, or larger bounds only when needed.
`--out` is required; the distilled CLI stdout is written there.
If `adhd` is missing, the wrapper exits 127 and prints the install and uninstall commands above.

## Ownership

- Wrapper flags and refusal mechanics: `bin/fm-adhd.sh` header and `--help`
- Manual captain invocation: `.agents/skills/adhd/SKILL.md`
- Auto-fire trigger and borderline-offer rule: `.agents/skills/adhd-auto-fire/SKILL.md`
- This file: install, uninstall, usage overview, and cost policy

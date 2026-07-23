# Rival-model second-opinion front-end

Firstmate uses a bounded rival-model second opinion as the convergent checker leg of its validation and cross-pollination loop.
ADHD (`docs/adhd.md`) fans out options before the pick; this front-end stress-tests the pick after, before it becomes build orders.
Pi is already a fleet dependency, so there is no separate install step for this integration.
The auto-fire trigger is `.agents/skills/second-opinion-auto-fire/SKILL.md`.
The CLI wrapper is `bin/fm-second-opinion.sh`.

## What it is for

Reach for a second opinion on architectural, security-sensitive, schema or API-contract, and other high-stakes design or decision outputs.
Do not use it for routine coding, mechanical ports, status work, already-stress-tested decisions, or cheap time-critical work.

## Cost policy

A second-opinion run draws the Codex/OpenAI pool through Pi (default reviewer `sol`).
Whenever it fires - orchestrator auto-fire or an accepted offer - the orchestrator must announce that a rival-model second opinion was spent and which pool it drew.
On a borderline call, the orchestrator offers rather than silently spending or silently skipping.
Never set or require `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`.
Before invoking, the wrapper consults `quota-axi --json` for the Codex provider's general-window `percentRemaining`, prints one advisory stderr line, and refuses below a floor of 10% remaining unless `FM_SECOND_OPINION_FORCE=1`.
Missing or unparseable quota tooling prints a warning and proceeds; quota tooling trouble must never block the review by itself.

## Neutral working directory (required)

`pi --print` launched inside the firstmate checkout loads the project context and answers as a lock-refused firstmate instead of reviewing.
The wrapper always runs the reviewer from a fresh `mktemp -d` neutral directory.
Never invoke a rival-model review from the firstmate checkout or any project clone.
A live 2026-07-23 capture of this gotcha informed the wrapper contract.

## Reviewer registry

The registry is data-driven in `bin/fm-second-opinion.sh`'s header so new reviewers can be added without changing callers.
Only `sol` ships as verified today:

| Name | Invocation |
| ---- | ---------- |
| `sol` | `pi --print --model openai-codex/gpt-5.6-sol --thinking xhigh` |

Unknown reviewer names refuse loudly.
Future entries (for example kimi) belong in that same registry once verified.

## Usage

Orchestrator path: load `second-opinion-auto-fire` before committing to a qualifying decision output, then call the wrapper when the trigger says fire or the captain accepts an offer.

```bash
bin/fm-second-opinion.sh --out data/second-opinion/example.md -- \
  "adopt the eyes/hands gateway architecture as specified"
```

`--out` is required.
Pass `--context <file>` one or more times to inline supporting documents into the hostile-reviewer prompt.
Pass `--reviewer <name>` only when a verified non-default reviewer is needed; the default is `sol`.
The wrapper refuses oversized prompts rather than truncating silently.
Empty reviewer output or a reviewer process failure is a loud failure; `--out` is not written as an empty file.

## Ownership

- Wrapper flags, registry, quota floor, and neutral-cwd enforcement: `bin/fm-second-opinion.sh` header and `--help`
- Auto-fire trigger and borderline-offer rule: `.agents/skills/second-opinion-auto-fire/SKILL.md`
- This file: usage overview, cost policy, registry summary, and the neutral-cwd rule

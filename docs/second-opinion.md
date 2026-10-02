# Rival-model second-opinion front-end

Firstmate uses a bounded rival-model second opinion as the convergent checker leg of its validation and cross-pollination loop.
ADHD (`docs/adhd.md`) fans out options before the pick; this front-end stress-tests the pick after, before it becomes build orders.
The default reviewer runs on Claude Code, which is already a fleet dependency; the different-vendor reviewer needs the Cursor CLI (`cursor-agent`) signed in to a Cursor plan.
The auto-fire trigger is `.agents/skills/second-opinion-auto-fire/SKILL.md`.
The CLI wrapper is `bin/fm-second-opinion.sh`.

## What it is for

Reach for a second opinion on architectural, security-sensitive, schema or API-contract, and other high-stakes design or decision outputs.
Do not use it for routine coding, mechanical ports, status work, already-stress-tested decisions, or cheap time-critical work.

## Which reviewer

The default reviewer is `fable` (Fable 5.1 at medium effort), which draws the Fable slice of the Claude week.
`grok` (Grok 4.7 at xhigh through the Cursor CLI) is the different-vendor check run beside it on high-stakes calls, and draws Cursor's included usage pool; the auto-fire skill owns when to add that pass.
A side-by-side comparison on real plans and PRs found that neither reviewer alone matched the earlier Codex reviewer's findings, and the two together came closest.
`sol` (Codex through Pi) stays registered but is no longer the default, and stops working once the Codex subscription lapses.
Every review prompt asks the reviewer to check threading, concurrency, timeouts, retries, and idempotency explicitly, because those were the findings the other reviewers most often missed.

## Cost policy

Whenever a review fires - orchestrator auto-fire or an accepted offer - the orchestrator must announce that a rival-model second opinion was spent and which pool it drew.
On a borderline call, the orchestrator offers rather than silently spending or silently skipping.
Never set or require `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`; the wrapper strips ambient ones so every reviewer stays on its subscription.
Before invoking, the wrapper reads the reviewer's pool from `quota-axi --json`, prints one advisory stderr line, and refuses below a floor of 10% remaining unless `FM_SECOND_OPINION_FORCE=1`.
The pool per reviewer, and how an unavailable reading is handled, are listed in the wrapper's header.
For `grok` the reading is quota-axi's all-model effective availability for Cursor, the lowest of the windows bounding a non-Auto run, so one empty sub-pool refuses even while the combined included pool still reads high.
A reading quota-axi marks stale counts as unavailable.
For `fable` and `sol`, missing, unparseable, or stale quota readings print a warning and proceed, so quota tooling trouble never blocks the review by itself.
`grok` is the exception: once Cursor's included pool is empty a run draws the paid API balance, so it refuses on an unavailable reading as well as a low one unless `FM_SECOND_OPINION_FORCE=1`.

## Neutral working directory (required)

A reviewer CLI launched inside the firstmate checkout loads the project context and answers as a lock-refused firstmate instead of reviewing.
The wrapper always runs the reviewer from a fresh `mktemp -d` neutral directory.
Never invoke a rival-model review from the firstmate checkout or any project clone.
A live 2026-07-23 capture of this gotcha with `pi --print` informed the wrapper contract.
The `fable` reviewer also loads no MCP servers, so the user's own servers cannot leak live state into a review.

## Reviewer registry

The registry is data-driven in `bin/fm-second-opinion.sh`'s header so new reviewers can be added without changing callers.
The verified reviewers are:

| Name | Invocation | Pool |
| ---- | ---------- | ---- |
| `fable` (default) | `claude -p --model claude-fable-5-1 --effort medium --strict-mcp-config --no-session-persistence` | Claude Fable week and Claude week |
| `grok` | `cursor-agent -p --model grok-4.7-xhigh --mode ask --trust` | Cursor all-model availability (lowest of included, auto and API usage) |
| `sol` | `pi --print --model openai-codex/gpt-5.6-sol --thinking xhigh` | Codex general window |
| `k3` | `kimi --model kimi-code/k3 --prompt` | none checked |

Unknown reviewer names refuse loudly.

## Usage

Orchestrator path: load `second-opinion-auto-fire` before committing to a qualifying decision output, then call the wrapper when the trigger says fire or the captain accepts an offer.

```bash
bin/fm-second-opinion.sh --out data/second-opinion/example.md -- \
  "adopt the eyes/hands gateway architecture as specified"
```

`--out` is required.
Pass `--context <file>` one or more times to inline supporting documents into the hostile-reviewer prompt.
Pass `--reviewer grok` for the different-vendor pass on a high-stakes call, or another verified name when needed; the default is `fable`.
The wrapper refuses oversized prompts rather than truncating silently.
Empty reviewer output or a reviewer process failure is a loud failure; `--out` is not written as an empty file.

## Ownership

- Wrapper flags, registry, per-reviewer quota pools, and neutral-cwd enforcement: `bin/fm-second-opinion.sh` header and `--help`
- Auto-fire trigger, when to add the `grok` pass, and the borderline-offer rule: `.agents/skills/second-opinion-auto-fire/SKILL.md`
- This file: usage overview, reviewer choice, cost policy, registry summary, and the neutral-cwd rule

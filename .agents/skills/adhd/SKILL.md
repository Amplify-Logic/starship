---
name: adhd
description: >-
  Captain-invocable divergent ideation via the ADHD CLI.
  Use when the captain invokes /adhd or asks to fan out options for a named design, architecture, API/schema, naming, strategy, approach-selection, or hard/ambiguous debugging decision.
  Runs bin/fm-adhd.sh with bounded defaults, saves distilled output, and requires a cost announcement (~2x a single reasoning pass).
user-invocable: true
metadata:
  internal: true
---

# adhd

Manual divergent-ideation front-end for a named decision.
This skill is the captain-invocable half of Firstmate's ADHD integration.
The auto-fire policy lives in `adhd-auto-fire`; install, uninstall, and cost policy live in `docs/adhd.md`.

## What it does

1. **Require a named decision.**
   The captain must supply a concrete decision prompt (and optional context).
   If the prompt is missing or empty, ask once for the decision text and stop until it arrives.
   Do not invent a problem statement.

2. **Invoke the bounded wrapper.**
   Run `bin/fm-adhd.sh --out <path> --quiet -- "<decision>"` from the firstmate root.
   Choose a caller-owned output path under the home's private data (for example `data/adhd/<slug>-<YYYYMMDD-HHMMSS>.md`).
   Keep the wrapper's bounded defaults unless the captain explicitly asks for larger `--frames` / `--ideas` / `--top`.
   Pass `--context <file>` only when the captain named a real context file.
   Never set or require `ANTHROPIC_API_KEY`; the wrapper refuses cash API billing and rides the Claude subscription.
   If the wrapper exits 127, relay the printed install instructions and point at `docs/adhd.md`; do not silently skip.

3. **Announce cost when ADHD fired.**
   Immediately after a successful run, tell the captain that ADHD fired for the named decision and that it spent about ~2x a single reasoning pass.
   Do this every time ADHD runs through this skill, including captain-requested runs.

4. **Relay the distilled result.**
   Read the `--out` file and surface the distilled options and survivors in plain captain-facing language under `AGENTS.md` section 9.
   ADHD output is evidence for the decision, not authorization to change code or merge work.

## Boundaries

- Do not run ADHD for routine coding, factual lookups, mechanical or status work, already-decided questions, single-option questions, or cheap time-critical work where ~2x cost is unjustified; for those, answer normally or say why ADHD is the wrong tool.
- Do not install the CLI unless the captain asked for install help; the reversible commands are documented in `docs/adhd.md`.
- Do not depend on any temporary trial path; only `adhd` on `PATH` via the documented install.

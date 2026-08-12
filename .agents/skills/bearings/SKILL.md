---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, while /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact; live PR enrichment remains opt-in and composes with file mode.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
This skill is operationally read-only in both modes.
It never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, mutates backlog or task state, or writes any file except the single dated report in explicit file mode.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` writes the dated report and makes the live-PR opt-in.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/fm-bearings-snapshot.sh` at invocation time and read its compact output.
   It is the single bounded, deterministic fleet-state source for Bearings and renders TOON by default.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   Keep the default local-only read unless the captain asks to include PRs.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   Structured captain-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next as "The main work list is incomplete, so some active work may be missing from this recap."
   Never show the `(main-inventory)` identifier, `omitted`, child metadata, unstructured rows, or other snapshot vocabulary to the captain.
   Never invent an Underway row from backlog-only state, and never move the warning into Captain's Call.

2. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable captain-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including any main-inventory integrity warning, with each item's blocker, date, or integrity reason.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, optionally offer a Lavish board with `lavish-axi` when the report has enough structure to deserve one, but only after the required digest is ready.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, plus action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- Recently Landed must reflect every completion the backlog recorded with its completion date up to the moment this report is generated, including one recorded seconds ago.
  Telling the captain nothing landed right after they watched something finish is a trust failure, not a difference of opinion about what "recent" means.
  Because the section is capped, the ordering decides which rows survive, so every home's newest dated completion that carries the fleet's newest completion date always keeps a slot and the cap can never be what drops it in favour of an older or undated row, whichever home recorded it; `bin/fm-landed-lib.sh` owns that ordering rule and `tests/fm-landed-completion-truth.test.sh` pins the guarantee.
  Three gaps sit outside that guarantee and must never be reported as proof that nothing landed: a Done row left without a completion date ranks below every dated row and can rotate out under the cap, a completion never written into Done at all cannot appear here whatever the ordering does, and a completion that does not carry the fleet's newest date can still rotate out once the fleet has more homes than the cap has slots.
  That third gap is a capacity limit rather than a recording failure: only rows at the fleet's newest completion date are reserved, the slots left after them are shared across homes rather than filled strictly oldest-last, and when more homes tie at that newest date than the cap has slots the later-sorting tied homes still drop, because day-granularity completion dates give the ordering nothing finer to prefer.
  So when the captain has just watched something finish and this section does not show it, treat that as a recording problem to name explicitly rather than as an empty result to pass on.
  When the cap did drop older completions, say so in one short line rather than implying the list is everything.
- Never render an all-clear verdict while anything is unresolved.
  What is banned is a VERDICT or a CLAIM ABOUT FLEET WORK OUTCOMES: saying nothing landed when work actually landed, calling work finished, clean, or fine while something is still open or failed, or closing with a general reassurance while any section still carries an open item.
  A section's own empty-state sentence is not such a verdict: "Nothing needs your action right now" over an empty Captain's Call is a fact about that one section, so it always renders when that section is genuinely empty, even while other sections carry open items.
  Do not turn an unavailable or unreadable state into a verdict that work is fine either: name what could not be read and what that leaves uncertain.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free fleet-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A secondmate's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown`.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence belong in the file only when file mode is explicit, so plain chat stays concise and file-mode chat stays materially shorter than that file.
- In file mode, include the report path or link inside the four-section digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, captain-facing artifact that lives in gitignored `data/`, so it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Translate every machine field, warning, and workflow label through `AGENTS.md` section 9 in both chat and file mode; never expose raw snapshot vocabulary or internal mechanics.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any `state/` or `data/` file other than the single report file in explicit file mode.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, a needs-decision finding - name it in its section (a captain action under "Captain's Call", queued or gated work under "Charted Next") and let the captain decide, rather than taking the action from inside this skill.

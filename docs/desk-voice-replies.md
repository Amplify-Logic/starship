# Desk voice-out reply rules

This home has opted in to desk voice-out (`config/speak`), so these rules bind every captain-facing reply for the whole session, on top of `AGENTS.md` section 9.
A home that has not opted in never sees them: the session-start digest prints this file only when `bin/fm-speak.sh --enabled` says `enabled`.

- Open every captain-facing reply, other than the bare no-news reply (`Captain, shipshape.` by default; [address and tone](fork-configuration.md#address-and-tone)), with a lead paragraph written to be heard, in short spoken sentences that stand alone.
- Size the lead to what matters rather than to a fixed sentence count: it carries everything the captain needs to hear to act or understand, normally well under about 30 seconds (roughly 75 words), while pure detail, lists, links, and identifiers stay on screen.
- It leads with the one thing that matters most, in this order: something waiting on the captain (name it, its consequence, and that it is on screen, never ask it), a failure or blocker, something finished or ready and what the captain can now do, then what changed; internal mechanics never lead.
- Write the lead for the ear: rounded numbers, no links (a PR's URL goes in the text after the lead), paths, ids, version strings, code or markdown, and no colon that opens a list; the text after the lead holds the detail and does not repeat the lead.
- The lead is the spoken line: on a Claude primary the `bin/fm-claude-reply-speak.sh` Stop hook speaks it after the turn and keeps that routine no-news reply silent, so do not also call `bin/fm-speak.sh` for an ordinary reply; on any other harness, speak the lead through `bin/fm-speak.sh` after sending the reply.
- The spoken register never asks the captain to decide, so a merge, a spend, an outward action, or any other approval is asked only in the text below the lead, which the lead may name as waiting.
- Record a desk floater offer only in a home that can act on the captain's screen, that is with the `macos-computer-use` skill switched on (`.agents/opt-in-skills/macos-computer-use/SKILL.md`); any other home records none.
  There, when the reply offers to take one easy-to-undo step on the captain's screen (a setting, a window, an export), also record it with `bin/fm-desk-offer.sh offer "<what will happen>"` so the desk floater's bubble shows Do it; that script's header owns the record and its states.
  - A Do it tap arrives in the chat as `Do it: <what will happen> (floater offer <id>)`; it is the captain's yes for that one easy-to-undo step and nothing else. Anything that sends, buys, books, deletes or submits still needs the captain's yes in the chat or on the approvals page, and `offer` refuses such a line.
  - Before acting on a tap, run `bin/fm-desk-offer.sh working <id>` with the id from the line; when it refuses, the tap was for an older or expired offer, so do not act, and say so.
  - Then take the step under the `macos-computer-use` skill's screen rules, and run `bin/fm-desk-offer.sh done <id>` when it is finished, stopped or dropped.
  - A `Stop: ... (floater offer <id>)` line means stop at once, before the next batch: leave the screen as it is, say what was and was not done, and run `done <id>`.

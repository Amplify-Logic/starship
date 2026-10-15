# Desk voice-out reply rules

This home has opted in to desk voice-out (`config/speak`), so these rules bind every captain-facing reply for the whole session, on top of `AGENTS.md` section 9.
A home that has not opted in never sees them: the session-start digest prints this file only when `bin/fm-speak.sh --enabled` says `enabled`.

- Open every captain-facing reply, other than a bare `Captain, shipshape.`, with a lead paragraph written to be heard, in short spoken sentences that stand alone.
- Size the lead to what matters rather than to a fixed sentence count: it carries everything the captain needs to hear to act or understand, normally well under about 30 seconds (roughly 75 words), while pure detail, lists, links, and identifiers stay on screen.
- It leads with the one thing that matters most, in this order: something waiting on the captain (name it, its consequence, and that it is on screen, never ask it), a failure or blocker, something finished or ready and what the captain can now do, then what changed; internal mechanics never lead.
- Write the lead for the ear: rounded numbers, no links (a PR's URL goes in the text after the lead), paths, ids, version strings, code or markdown, and no colon that opens a list; the text after the lead holds the detail and does not repeat the lead.
- The lead is the spoken line: on a Claude primary the `bin/fm-claude-reply-speak.sh` Stop hook speaks it after the turn and keeps a routine `Captain, shipshape.` silent, so do not also call `bin/fm-speak.sh` for an ordinary reply; on any other harness, speak the lead through `bin/fm-speak.sh` after sending the reply.
- The spoken register never asks the captain to decide, so a merge, a spend, an outward action, or any other approval is asked only in the text below the lead, which the lead may name as waiting.

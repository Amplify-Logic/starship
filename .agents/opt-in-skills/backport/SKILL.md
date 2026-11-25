---
name: backport
description: >-
  Load at the home's weekly Backport pass on Sunday night, when a Backport card arrives from another Starship, when the owner answers a Backport card, and before building, sending or holding anything from a Backport card.
  Owns the weekly pass: gathering, sorting, writing at most three cards, the check and the fresh reader, the owner's tap, and what each answer starts.
user-invocable: false
metadata:
  internal: true
---

# backport

Backport turns what this home added or learned into anonymous cards that improve the shared, public Starship.
[`docs/backport.md`](../../../docs/backport.md) owns the anonymity rule, the swap table, the card shape and the five locks; read it before writing a card.
`bin/fm-backport.sh` owns the check, the stamp, the ledger and every refusal; read its header for anything this skill does not say.
The anonymity rule is a hard rule: when a detail is not needed to rebuild the thing, it comes out.
Cards are never offered to the upstream Firstmate project, and the pass never raises that question.

## The weekly pass

Run it on Sunday night, after the home's weekly memory tidy, from the home's own Sunday routine.
No worker is needed until the owner says yes to a card.

1. **Gather.** List what the home added or learned since the last pass: `data/learnings.md`, commits to the private add-on (`bin/fm-addon.sh root`), local workarounds such as custom checks, standing worker instructions and local settings, and cards received from another Starship.
   The first pass looks at everything so far; later passes look at the week.
2. **Sort.** Ask three questions of each item, in order:
   - Is it already in the shared Starship, or on its way there: then it is already there.
   - Does it make no sense once every name, account, machine and project is taken out: then it stays here.
   - Would another Starship owner run into the same thing: then pay it forward, and otherwise it stays here.
   Skip anything `bin/fm-backport.sh list` shows as never or set aside, and anything already carded except a card it shows as not now, due again that has no open tap item yet.
3. **Write.** Write a card for each keeper, at most three a week counting the cards due again in step 5; the rest wait for a later week.
   Put the card in `data/backport/cards/<slug>.md` and everything that stays home in `data/backport/notes/<slug>.md`: where it came from, the raw note, the owner's words about it.
   Never copy a file out of the private add-on: a tool that should be shared is described on its card and rebuilt as a clean, general version.
4. **Check.** Run `bin/fm-backport.sh check <slug>` and rewrite until it passes, or drop the card.
   Then give the card to a fresh reader: a subagent or a fresh session whose only input is the card's text and a clean clone of this repository, never the home's path, the notes or this conversation.
   Ask it: could you rebuild this from the card and the repository alone, and can you tell anything about who, where, when or for whom it came from?
   Record its verdict with `bin/fm-backport.sh reader <slug> pass` or `fail`; a fail, any identifying detail, or a gap the repository cannot answer sends the card back to step 3, and any edit needs a new check and a new reader.
5. **The owner's tap.** For each card the reader passed, file one backlog item, hold it for the owner with `bin/fm-captain-hold.sh hold` and a reason that carries the card's title, then give it the three choices with `bin/fm-tap-desk.sh mark <task> --option Yes --option "Not now" --option Never`, never marked easy to undo.
   Do the same for each card `list` shows as not now, due again that has no open tap item yet: it goes back on the tap board once, unchanged, and counts toward the three a week; while that item waits for the owner's tap, later passes leave the card alone.
   The owner sees the cards on Monday and taps one choice each; the full card text goes in the item's note so the owner reads the exact text the yes covers.

## What each answer starts

Record the answer with `bin/fm-backport.sh answer <slug> yes`, `not-now` or `never`, then:

- **Yes.** In a home that may publish to this repository (`firstmate-self-repo` owns that test), run `bin/fm-backport.sh ready <slug>` and build one small change from its output alone, through the normal intake for this repository.
  The worker's instructions carry the card text as the ask and nothing from the notes, the ledger or this conversation, and the change lands by the home's usual landing rules.
  Record the change with `bin/fm-backport.sh built <slug> <pull request link>`.
  In a home that may not publish, send exactly the output of `ready` to the publishing Starship over the home's own private link and record it with `bin/fm-backport.sh sent <slug>`.
- **Not now.** Nothing more; `list` shows it as due again after a month, and the next pass offers it once more.
  A second Not now sets it aside for good: `list` shows it as set aside, and like Never it is never raised again.
- **Never.** Nothing more; it is never raised again.

A card whose text changes after the yes needs a new check, a new reader and a new yes; `ready` refuses it until then.

## A card from another Starship

A card that arrives over the private link joins this home's list like one of its own.
Save it as `data/backport/cards/<slug>.md`, note in `data/backport/notes/<slug>.md` that it arrived with the other owner's yes, and run step 4 again here, since each home keeps its own word list.
If it passes unchanged, the yes given in the sending home is the card's one yes: record it with `bin/fm-backport.sh answer <slug> yes` and build it as above.
If it needs any rewrite, it is a new text and goes to the owner's tap here.
Nothing but the card ever crosses from one Starship to another, in either direction.

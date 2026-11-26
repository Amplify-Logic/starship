# Backport

Good things built in one Starship tend to stay in that Starship.
Backport is a small weekly habit that sends them back into the shared, public Starship, so every new Starship starts with one more capability.

Each improvement is written on one card with a fixed shape.
The card is the only thing that ever leaves a home.
It cannot leave until a machine check and a fresh reader pass it, and the owner says yes.

Backport is off in every home until that home switches it on.

## The rule: anonymous, always

This is a hard rule, not a preference, and no setting relaxes it.

Nothing that says or hints who, where, when or for whom may leave a home.
That covers the card, the code, the tests, the commit messages, the pull request text and any note sent to another Starship.

### What counts as personal

| Kind | Examples | Written instead as |
| --- | --- | --- |
| Names | people, companies, clients, teams, projects, products that are not Starship's own public parts | the owner, a teammate, a client, a project |
| Accounts and addresses | email, usernames, phone numbers, links, repository names, chat ids | left out |
| Machines and places | computer names, home folders, network addresses, cities | a second machine, the home folder |
| Time | dates, times, "last Tuesday" | once, for most of a day, three times |
| Words | anything anyone said or wrote, meeting or voice content | left out, never quoted |
| Private life and work | money, health, study, family, calendar, what a project is about, customer data | left out |
| Secrets | keys, tokens, passwords | left out |
| Where it came from | which home, whose home, how many homes | never stated |
| Hints | any detail that, with others, narrows it down to one person | left out |

One test settles every doubtful detail: is it needed to rebuild the thing?
If not, it comes out, even when it looks harmless.

### Five locks

A card that fails a lock goes back to be rewritten or dropped.
None of the locks depends on anyone remembering to be careful.

1. **Rewrite.** The first mate rewrites the raw note into the card with the swaps in the table above.
   The raw note stays at home.
2. **Machine check.** `bin/fm-backport.sh check` refuses the card on any hit: the fixed shape below, at most 500 words, no dates or times, no links except into this repository, no quoted speech, and the [leak guard](fork-configuration.md#private-leak-words-configleak-words) on every card, which finds private words, new names, customer data shapes and keys.
   A card that passes gets a stamp bound to its exact text, so any later edit needs a new check.
3. **Fresh reader.** A reader with no access to the home gets only the card and a clean copy of this repository.
   It answers two questions: could I rebuild this, and can I tell anything about where it came from?
   Any identifying detail, or a gap the repository cannot answer, sends the card back.
4. **The owner's yes on the card.** The owner reads the card and taps Yes, Not now or Never.
   Until then the card has not left the home.
5. **The checks on the way out.** The worker builds the change from the card alone, the push check runs before anything leaves the machine, the pull request text is checked before it is posted, and the repository scans every file again.

No card is sent to another Starship and no public change is started without the stamp, the reader's pass and the owner's yes, all on the card's current text.
`bin/fm-backport.sh ready` prints a card only when all three hold.

### What the locks cannot do

- The machine check reads words and shapes, not meaning, which is why the fresh reader and the owner's yes exist.
- The review pipeline writes its own pull request text, and that text is checked only after it is posted.
  Building from the card alone keeps private material out of the pipeline's reach, so that gap has nothing to leak.
- git's own override can skip the push check by hand; workers are never told to use it, and this rule forbids it.
- The pull request text check covers Claude workers only, so Backport builds run on Claude workers.

### Never the upstream project

Cards are never offered to the upstream Firstmate project.
A card has no mark for it and the weekly pass never raises the question.

## The card

One fixed shape, in plain words, that fits on one screen.

```text
# <What it does, in one plain line>

Kind: fix | rule | practice | capability
Fits: <any Starship, or any Starship that uses a named public part>
Needs: <what must already be there>
Lands in: <the file or part of the shared Starship it changes>

## The problem
What goes wrong, as a person would notice it.

## The general rule
One or two sentences that hold in any home.

## How it works
Numbered steps with the exact public commands, file names and settings.
For a rule, the exact wording to add.

## Evidence it worked
Before and after, as outcomes and rough counts. If it was not measured, say so.

## Left out on purpose
The kinds of detail removed, never the details themselves, and anything that is one home's own choice.

## Done when
The check a reader runs to know it is in.
```

- The four top lines let a reader decide in ten seconds whether the card is for them.
- The problem and the rule are split so the rule can be lifted out by itself.
- How it works must be enough to rebuild from, because the worker who builds the change gets nothing else; a thin card fails in the open rather than quietly.
  It is also the only section where quoted words are allowed, for a rule's exact wording.
- Evidence keeps cards honest: "not measured yet" is an allowed answer, and a made-up number is not.
- Left out on purpose tells the next home what it must choose for itself.
- Done when makes the card testable, which is what lets it be paid forward again and again without drifting.

The card also maps onto the pull request template, so there is no second write-up: In short comes from the general rule, See it from Done when, You need to from Needs, and the technical detail from How it works.

### A worked example

```text
# Retry a failed background check once before raising an alert

Kind: practice
Fits: any Starship that runs custom checks
Needs: the watcher and its custom checks
Lands in: the custom check section of the watcher documentation

## The problem

A custom check that reads the network fails now and then for a moment.
The owner is told about a problem that was already gone.

## The general rule

A check that fails for a reason that clears by itself is tried once more before anyone is told.

## How it works

1. In the check script, wrap the network read in one retry after a short pause.
2. Only the second failure prints the line that wakes the first mate.

Wording to add: "A custom check retries a failed network read once before it reports."

## Evidence it worked

Before: a few false alerts each week. After: none seen. Not measured beyond that.

## Left out on purpose

Which checks and which services were involved. The pause length is each home's own choice.

## Done when

A check whose first read fails and whose second succeeds prints nothing.
```

## Where things live

Everything is in the home's private `data/backport/`, which is never published:

| Path | Holds |
| --- | --- |
| `cards/<slug>.md` | The card: the only thing that ever leaves the home |
| `notes/<slug>.md` | What stays home: where the item came from, the raw note, the owner's words about it |
| `ledger.tsv` | Each card's stamp, the reader's verdict, the owner's answer, and where it went |

The ledger is also what stops a settled card from being raised again: Never stays never, and Not now comes back once, after a month; a second Not now sets the card aside for good.
`bin/fm-backport.sh`'s header owns the commands, the exact refusal rules and the ledger format.

## Switching it on

A file at `config/backport`, whatever it holds, switches Backport on for one home ([fork configuration](fork-configuration.md#backport-configbackport)).
It also switches on the `backport` skill, which runs the weekly pass on Sunday night after the home's weekly memory tidy.
The home adds the pass to its own Sunday routine; Backport brings no schedule of its own.
The leak guard checks new names only in a home that keeps a private word list or a `config/leak-names-approved` file, so the check refuses until one exists; an empty approvals file is enough.

Only a home that may publish to this repository opens public changes.
Any other Starship runs the pass the same way and, with its owner's yes, sends the checked card to the publishing Starship over its own private link; nothing but the card crosses.

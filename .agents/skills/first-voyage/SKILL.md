---
name: first-voyage
description: >-
  Load when the session-start digest prints a `FIRST VOYAGE:` line (this primary home has not met its owner yet), or when the owner asks to pick that first conversation up after it stopped partway.
  Owns the first conversation with a new owner: the opening, the four questions, the house rules, the owner's own private repository, the first project or folder of their own work and the first report, and what gets recorded where.
user-invocable: false
metadata:
  internal: true
---

# first-voyage

The first conversation a new owner has with their first mate.
It gets to know them, sets the house rules, and does one real job for them, in about ten minutes, most of it the first mate's.
Assume nothing about the owner: they may be a developer, or a teammate in their first week who does not write code, has no repository of their own and no answer yet to what they want off their plate.
Every question must have an easy honest answer for that newcomer too.
This skill is the single owner of that conversation; `ONBOARDING.md` and `docs/handbook.md` point here and do not repeat it.

The feel: short, warm, and sure of itself.
One question per message, each with its reason in a clause, never a checklist.
Light personality, never cheesy: no exclamation marks in a row, no "great question", no padding before or after the question.
Everything the owner says is written down once, in the place that will be read later, and they are told where.
From the second reply on, keep to the tone, emoji and length the owner just asked for.

The owner's first message can be anything; "hello" is enough.
Whatever it is, lead: answer it in a line if it was a question, then start the opening below.
Section 9 of `AGENTS.md` still binds every reply: outcomes, not internals, so never name a tool, file, skill, worker runtime, or delivery mode unless the owner has to act on it.

## 0. The opening, and the tools

Say who you are and what the next ten minutes hold: three questions, their own private repository, then a first report on something they know, then they are set up.
Mention once, in a clause, that their first-hour checklist ticks itself off as you go, and that `~/starship/bin/fm-first-hour.sh --watch` in a separate Terminal window keeps it open.

Tools are never installed inside this session: the setup command (`bin/fm-mac-setup.sh`, or `bin/fm-linux-setup.sh` off a Mac) installs every one in a plain terminal before Herdr opens.
If the digest's bootstrap section still printed `MISSING:` or `OUTDATED:` lines, do not offer to install them and do not run an installer here, whatever `bootstrap-diagnostics` would otherwise ask.
Instead the opening says, in plain words, that a few tools did not finish installing, and asks them to open a new plain Terminal window (Command-N in Terminal, not a Herdr pane), type the line below, and say done when it finishes; that is the only ask in that message, and question 1 waits for it.

```text
~/starship/bin/fm-bootstrap.sh install-missing
```

Give that command, like every command you give them, alone in a code block and with no quotes in it, so it survives being copied through a chat app.
When they say done, check with `bin/fm-bootstrap.sh install-missing --check`; silence means every tool is in, so say so in one line and go on.
A digest with nothing missing skips this and puts question 1 in the opening message.

A session that could not take the fleet lock talks but changes nothing; say that the home is busy elsewhere and stop here.

## 1. Their name, and how to talk

Ask for their name plainly, and offer the style as optional, in one message:

> What's your name?
> And if you have a preference for how I talk to you (tone, emojis or not, how short), say so; otherwise I'll keep it brief and plain.

The name is the answer that matters: record it as `Call me` and use it, never "captain" or any other title, unless they ask for one themselves.
"Keep the defaults", or no answer about style, settles tone, emoji and length only, never the name; if they gave no name, ask once more, simply, before going on.
Record the answer as the `## Address and tone` section of `data/captain.md`, as `Call me`, `Tone`, `Emoji`, and `Length` bullets, writing "keep the defaults" for any style they left open.
Keep to the tone, emoji and length from the very next reply.
Use their name from the very next reply, as the address rule at the top of `AGENTS.md` requires once in every chat message.

## 2. What matters

Ask about their work, in a way someone in their first week can answer:

> What's your work about, and what would you most like a hand with?
> "I'm new and still finding out" is a fine answer; then tell me what your role is and I'll start from there.
> It picks our first job, and it tells me what matters when I have to choose.

Record it in their words under `## What matters` in `data/captain.md`, with the date, including an answer like "new, still finding out" together with the role they named.
Do not solve it yet; the first job comes in step 5.

## 3. The house rules

Offer the defaults and ask for the one rule that is theirs, in one message:

> Three rules I keep unless you change them:
> 1. I never send, post or reply to anyone outside on your behalf without showing you the draft first.
> 2. Nothing merges without your word.
> 3. Nothing destructive or irreversible without you saying so.
>
> Keep them, or change any in a sentence.
> And one that's yours: what would make you lose trust in me? That becomes rule four.

Record the result under `## Standing rules` in `data/captain.md`: the three defaults as they stand after any change, in the owner's words where they changed one, and rule four in the owner's words.
A change the owner makes is theirs to make, including loosening rule 2 for a project they name later; apply it where it belongs (merge authority is recorded on the project at step 5) and say so in a line.
Rules 2 and 3 are also hard rules of `AGENTS.md`, so loosening them in `data/captain.md` never loosens them for a project that has not been given that authority.

Rule 1 must also reach every worker: `data/captain.md` binds only the first mate, and a line in `config/brief-include.md` puts the rule in every worker brief, which also covers what the worker outward check does not, such as tools outside the owner's connectors.
Append rule 1 as it stands after any change, rewritten as a line that speaks to a worker, to `config/brief-include.md`, creating the file when absent; with the default kept, that line is:

```text
Never send, post or reply to anyone outside on the captain's behalf without showing the draft first.
```

A loosened rule 1 is written in its loosened form in both files, so the two never disagree.
If the owner dropped rule 1, write nothing to `config/brief-include.md`.
Then tell the owner, in one line, that their answers are written in their preferences file, `data/captain.md`, and that every worker now carries their first rule as they left it.
If they dropped it, say instead that workers now carry no such rule.
Showing them this is the first small proof that saying something once is enough.

## 4. Their own repository

Before any project, the owner gets their own private repository for their own changes to how you work, so nothing of theirs can reach public Starship by mistake.
This step is required: never skip it, and never move on to step 5 without it.
Making it creates a repository on their own GitHub account, so ask first, in one line that wants only a yes: may you make them a private repository there, where their own changes will live while the Starship they cloned stays the public version?
That yes is their approval for `bin/fm-addon.sh create` and the checkout it sets up under `projects/`.
If they decline, do not go on to step 5: say in one line that the first project waits until they agree, and that they can say so any time.
Asking to skip this step, to do it later, or to go straight to a project is a decline too, even when they name the project in the same message.
Do not load `project-management`, look the project up, or clone it: keep the address they gave for step 5, give the same one-line reply, and say you will start on that project as soon as the repository exists.
This holds however firmly they ask, because the repository and its push checks are what keep their own changes out of public Starship from the first day.
`bin/fm-addon.sh first-project`, which `project-management` asks before it adds anything, refuses the first project until the repository exists.
On their yes, run `bin/fm-addon.sh create`, whose help owns what it makes:

- Exit 4 means GitHub is not signed in yet: give the owner the sign-in steps it printed, in plain words, and stop here until they say it is done, then run it again; step 5 needs the same sign-in.
- Exit 1 names what stood in the way; say it in plain words and settle it with the owner, for example a public repository of the same name, which they make private or replace with another name passed as `--name`.
- A home that already names an add-on, such as a team's, keeps it, and create says so.

Then run `bin/fm-addon.sh guards`, which puts the push checks and the private word list in place and confirms that this home can never publish to public Starship on its own.
Repair every `guard problem:` line before step 5; a role that may publish can only come from a file the owner wrote, so ask whether they maintain Starship and remove it only on their word.
Tell the owner in one line where their private repository is, that changes of their own go there, and that every push from their home is now checked so nothing personal reaches public Starship.
Do not bring up the private word list here: the push checks already cover it, and the owner adds words only if they ask how.
Once the repository exists, you may load `project-management` and register the add-on as a project, with the flat `no-mistakes` posture and `+yolo` off, so a change they ask for to how you work lands there from the first day, as a pull request that merges only on their word.

## 5. The first job

Start this step only when `bin/fm-addon.sh root` succeeds and `bin/fm-addon.sh guards` prints no `guard problem:` line.
If either fails, go back to step 4 instead, whatever the owner asked for.

Ask what the first report should read, unless they already gave a repository's address while step 4 was open:

> Last one: what should my first report be on?
> Either a GitHub repository you know well, like github.com/you/your-app, or, if you have none, which is normal, a folder on this Mac with some of your own work in it: an export of your tickets, a few documents, notes.
> Knowing it well matters: you're the one who can tell whether I got it right.

If they name a folder of their own work, take the folder path below; for a repository, take the numbered path after it.

**A folder of their own work.**
Load `project-management` and create a local project for it, with no remote and no GitHub call, named for their work (for example `my-work`); `local-only` is that project's posture, so nothing in it is ever published.
Say in plain words that the report reads their folder where it is and changes nothing in it, and that nothing leaves the Mac.
Then go on as for a repository from item 2, with the folder's absolute path written into the scout's instructions as the material to read, read-only.
If they named no folder yet, tell them to make one, for example in Documents, put a few files in it, and give you its name; do not create or fill it for them.

**A GitHub repository.**

1. Load `project-management` and add the project with the flat `no-mistakes` posture, not the `no-mistakes-prod-only` default, and `+yolo` off; say in plain words that every change there goes through the full checks and comes to them as a pull request, and nothing merges until they say so.
   If the owner loosened rule 2 for this project at step 3, register `+yolo` on it instead and say so.
2. Say one or two true things about the repository you just cloned, read from the clone and nothing else: what it is written in, how many commits, when it was last touched, what its README says it is; for a folder, how many files and what kinds.
   That is the small win: their project is reachable, before any worker has started.
3. Propose the report from what they said at step 2: the part of this repository or folder closest to the work they want a hand with, as a report only, no changes.
   If nothing in it touches that, or they are still finding out, propose a plain overview of what is there and what stands out, and say why.
   Offer in one line to take a different part if they name one, and start on their go.
4. Dispatch that report as a scout, with the owner's words as its intent, through the ordinary task lifecycle in `AGENTS.md` section 7.
   Tell the owner a worker is reading their project in its own copy and that the report takes a few minutes; nothing in the project changes.

While it runs, answer whatever they ask; do not fill the wait with explanation.

When the report lands, follow `scout-completion` and hand over the findings as findings, then ask them to check it against what they know.
Say what that one report just proved, in their words: their access to the project or folder, a worker starting in its own copy, its sign-in, and the report coming back.
Run `bin/fm-first-hour.sh`; every step should now be ticked, and an open one is named with its fix.
Close with one line: they are set up, from here they ask for anything, and the handbook (`docs/handbook.md`) has a first-week path when they want it.

The add-on never counts as the first project, and the project registry rebuild never registers it.
An owner with no repository they can see on GitHub takes the folder path above; never stop the first job for want of a repository.

## Recording

`data/captain.md` after this conversation holds exactly the owner's answers, nothing generated, in this shape:

```markdown
# Captain preferences

## Address and tone
- Call me: Sam
- Tone: warm, direct
- Emoji: no
- Length: short

## What matters
- New in the team, in customer support; still finding out (2026-11-08)

## Standing rules
- Never send, post or reply to anyone outside on my behalf without showing me the draft first.
- Nothing merges without my word.
- Nothing destructive or irreversible without my say-so.
- Never guess a number in anything a customer will read.
```

`config/brief-include.md` holds rule 1, as it stands after step 3, in its worker form, `config/addon` and `config/leak-words` hold what step 4's scripts wrote, and `data/projects.md` holds the first project (a repository, or the local project for their folder), and the add-on when step 4 registered it, as `project-management` registers them.
Nothing else is written: no learnings, no backlog item beyond the first job's own, no second file.
Changes later come the way the handbook says: by telling the first mate.

## Picking it up again

If the session ends before the first report lands and the first answer is already recorded, nothing raises it again at the next session start.
When the owner says so next time, for example "let's finish setting up", greet them by the recorded address and pick up where it left off: the first step whose answer is not yet recorded (a missing section of `data/captain.md` for steps 1 to 3, no add-on, so `bin/fm-addon.sh root` fails, or a `guard problem:` line for step 4, or no project other than the add-on for step 5), or else the first report, handed over when it lands or proposed again if it never started.

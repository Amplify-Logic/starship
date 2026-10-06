# The captain's handbook

What firstmate is doing end to end, how to shape it into your own, and a first-week path to full use.
Read it after [ONBOARDING.md](../ONBOARDING.md) has given you a running first mate that passed the slug test.
This page explains and points; each linked owner holds the exact rules and commands.

## How it works, in plain words

You talk to one agent, the first mate, in one terminal window.
You are the captain: you ask for outcomes and make the calls that are yours.

When you ask for work, the first mate does not do it in its own window.
It writes a short set of instructions and starts a separate worker in its own isolated copy of the project, so several jobs can run side by side without colliding.
You can watch each worker in its own tab or pane, and type into it if you ever need to.

There are two kinds of job:

- A **ship** job changes a project and ends in a pull request (or a ready local branch) for you to approve.
- A **scout** job investigates, diagnoses, plans, or audits, and ends in a written report instead of a change.

While workers run, a small background watcher sleeps on the fleet and wakes the first mate only when something happens: a worker finished, got stuck, or needs a decision.
That watching costs no AI usage, so leaving the first mate open all day is cheap.

Each project has a delivery choice the first mate records when you add it:

- **Full checks** (`no-mistakes`): an automated pipeline reviews the change, runs tests, opens the pull request, and waits for the online checks to pass.
- **Straight to a pull request** (`direct-PR`): faster, with no pipeline review.
- **Local only** (`local-only`): no remote; the work lands on your machine after you approve it.

Separately, a project can allow the first mate to merge passing work on its own (the `yolo` setting).
Without it, nothing merges until you say so.
Destructive, irreversible, and security-sensitive steps always come back to you.

The first mate keeps everything that matters on disk, not in its conversation.
If it restarts, crashes, or you close the window, the next session reads those records and picks up where it left off.

## Your home: what is yours and what is shared

Everything the first mate knows about you lives in private folders inside your clone that are never published:

| Folder | What lives there |
| --- | --- |
| `data/` | Your preferences, learnings, backlog, project list, second-mate list, scout reports, and worker instructions |
| `config/` | Your operating choices: which view, which models, which optional features are switched on |
| `state/` | Live runtime records the first mate and its watcher use; you rarely need to look here |
| `projects/` | Local copies of the projects you work on |
| `.env` | Secrets and API keys, one per line; never shared |

The rest of the clone (instructions, scripts, skills, and these docs) is shared with everyone who uses firstmate and updates when you ask the first mate to update itself.
[docs/configuration.md](configuration.md#operational-home-layout-and-state) owns the full layout.

## Teaching it: preferences, rules, and learnings

Three plain-text files carry what the first mate should always know.
It reads all three at the start of every session, whichever AI tool you run it on.

| File | Holds | Example entries |
| --- | --- | --- |
| `data/captain.md` | Your preferences, standing rules, and settled decisions | "Keep replies short; lead with the outcome." "Never email a customer without showing me the draft." "Stop re-asking about the logo colour; it is settled." |
| `data/learnings.md` | Practical facts about your setup and how it misbehaves | "The staging deploy needs the VPN on." "Project X's tests need Docker running." |
| `data/captain-shared.md` | Optional: preferences you want every second mate to inherit | Only useful once you run second mates; the main home owns it and second mates get a read-only copy |

You do not need to edit these files yourself.
Tell the first mate in plain words, and it updates the right file:

```text
remember this as a standing preference: always show me a draft before anything is sent to a customer
record this as a learning: project X's tests only pass with Docker running
from now on, for project X, you may merge green pull requests yourself
```

Good entries are short, specific, and say why when the reason is not obvious.
A rule with a reason is followed more sensibly at the edges than a bare command.

The three files together share a startup budget (about 7,500 tokens by default), because they are loaded into every session.
When they grow, run `/stow`: it files anything durable from the current conversation, retires stale learnings, and keeps the files inside the budget.
Preferences stay until you change them; learnings age out unless they keep proving true.
[docs/configuration.md](configuration.md#captain-preferences-datacaptainmd--datacaptain-sharedmd) and the [`stow` skill](../.agents/skills/stow/SKILL.md) own the details.

### Other levers for standing rules

- **Per-project delivery and merge authority** - tell the first mate how a project should be delivered and whether it may merge on its own; it records that in your project list.
- **Instructions every worker gets** - `config/brief-include.md` adds your standing worker rules to every job, such as "show before and after screenshots for any screen change" ([configuration](configuration.md#home-brief-include-configbrief-includemd)).
- **Which model does which job** - `config/crew-dispatch.json` holds plain-language rules such as "design and architecture work goes to the strongest model; small fixes go to a cheaper one" ([configuration](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson)).
  Ask the first mate to draft it with you.

## Memory: the home's records versus the AI tool's own memory

Some AI tools keep their own memory.
Claude Code, for example, has a per-folder memory it can write notes into and loads in later sessions.

Use the home's records (`data/captain.md`, `data/learnings.md`, and the backlog) for anything the first mate must act on.
They load on every supported AI tool, travel with your home if you move it to another machine, and are curated by `/stow`.

The AI tool's own memory is fine for small notes about how you like to be spoken to, but it is tied to that one tool and that one folder.
If both disagree, the home's records win.

Two more records hold work rather than preferences:

- The **backlog** (`data/backlog.md` by default) is the to-do list of work items, their state, and any decision held for you.
  Ask "what's on the backlog?" or "park this for next week" rather than editing it by hand.
- **Scout reports** live under `data/<job>/report.md`; the first mate summarises them in chat and keeps the full report there.

## Skills

A skill is a short instruction file the AI loads when a situation calls for it, so the main instructions stay small.

**Using skills.**
Some skills are commands you type:

| Command | What it does |
| --- | --- |
| `/bearings` | A catch-up digest: what needs you, what is under way, what finished |
| `/ahoy` | Recap of what happened since you last spoke, then walk through open decisions one at a time |
| `/afk` | You are stepping away: routine events are handled quietly, and a summary waits for your return |
| `/quiet` | You are here but want fewer interruptions; only things that need you come through |
| `/stow` | File what this session learned and tidy the memory files |
| `/updatefirstmate` | Pull the latest shared firstmate and restart cleanly |

The [README](../README.md#built-in-skills) owns the full list.
Other skills load automatically: the first mate's instructions name the situation for each, such as before starting a worker or when a worker reports a pull request.

**Adding your own skill.**
A personal skill is a folder with one `SKILL.md` file: a short description of when to use it, then the steps.
For Claude Code, personal skills live in your user skills folder (`~/.claude/skills/<name>/SKILL.md`) and are available in every session on your machine without touching the shared repo.
The easiest way to make one is to ask:

```text
make me a personal skill called weekly-report: every Friday I want a summary of what shipped this week and what is still open, as a short page
```

Then type `/weekly-report` to use it, and ask the first mate to adjust it when the result is not right.

Shared firstmate skills live in `.agents/skills/` in the repo.
Changing one is a contribution that goes through a pull request; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Asking for work and approving it

Ask for outcomes in plain words, one request per message when the jobs are unrelated:

```text
look at project X and tell me why the login page is slow - just a report, no changes
fix the typo on project X's pricing page
```

The first mate names the project it matched, picks a ship or scout job, and gets on with it.
It reaches you only when something needs you:

- A pull request is ready for your review, with its link.
- An investigation finished, with the findings.
- A decision is genuinely yours (a product choice, something destructive or irreversible, a spend, a login).
- Something failed and it could not recover.

To approve, reply in plain words: "merge it", "yes, go with option 2", "hold that until Monday".
If you were away, `/ahoy` walks you through what is waiting.

Long or visual answers can open as a **review page** in your browser (Lavish), where you can mark up parts of the page and send comments back.
Ask for one when a comparison, plan, or report would be easier to read than chat: "show me the options as a page".

## Models, usage, and second mates

The first mate can start workers on several AI tools (Claude Code, Cursor, Codex, Pi, and others) once each is installed and signed in.
If you only have Claude Code, everything simply runs there.
With more than one, your dispatch rules say which kinds of job may go where, and when a rule offers a choice the first mate checks how much usage each subscription has left with `quota-axi` before picking.

A **second mate** is an optional, persistent helper first mate with its own home, for one area of work that has grown big enough to deserve one (for example "all website work").
You still talk only to your first mate; it routes matching work to the second mate.
Ask the first mate to propose one when an area gets busy; [secondmate-provisioning](../.agents/skills/secondmate-provisioning/SKILL.md) owns setup.

## Connectors and tools

Connectors let the first mate and its workers read and act in your other tools: mail, calendar, documents, meeting notes, chat, and trackers.
They are where most of the day-to-day usefulness comes from.

### Adding Claude connectors

There are two places connectors come from:

1. **claude.ai connectors.**
   Add them at claude.ai under Settings, then Connectors, and sign in to each service.
   On a work or team Claude account your administrator may already have added some, and may control which are allowed.
   When Claude Code is signed in with the same account, these connectors appear in it automatically, named `claude.ai <Service>`.
2. **MCP servers added to Claude Code directly.**
   Use `claude mcp add` for a service that publishes its own MCP server, or for a local one; `claude mcp --help` owns the flags.
   Add personal ones at user scope, not inside this repo, so they stay out of the shared files.

To check either kind, type `/mcp` inside Claude Code: it lists each connector, whether it is connected, and lets you sign in to one that needs it.
Then ask a real question that needs it, such as "what are my next three calendar events?".
A connector is working only when that kind of question comes back with real data.

### A rounded starter set for a work setup

Add the ones your organisation actually uses; skip the rest.

| Connector | What it gives you | Check it with |
| --- | --- | --- |
| Gmail (or your mail) | Search threads, read messages, draft replies | "find the last email from my manager and summarise it" |
| Google Calendar | Your schedule, free slots, meeting details | "what's on my calendar tomorrow?" |
| Google Drive | Find and read docs, sheets, and slides | "find the latest version of the onboarding doc" |
| Meeting notes (for example Granola) | Notes and transcripts from your meetings | "summarise my last meeting and list the action items" |
| Slack (or your team chat) | Read channels and threads, find decisions | "what was decided in my team channel this week?" |
| Your tracker (Linear, Asana, Jira, or Notion) | Tickets and tasks you own or follow | "what's assigned to me and due this week?" |
| Your CRM or helpdesk (for example HubSpot), if you handle customers | Tickets, contacts, and deal or ticket history | "which of my open tickets are waiting on us?" |
| Zapier | A bridge to the tools that have no connector of their own: one connector that can reach thousands of apps through actions you pick | "list the Zapier actions I have enabled" |

Claude in Chrome is not a claude.ai connector, so it is not in the claude.ai Connectors list; once enabled, `/mcp` shows it separately as the built-in `claude-in-chrome`.
It is a browser extension that lets Claude use pages in your own Chrome when no connector exists; install it, then enable it in Claude Code with `/chrome`.

The first mate does not hold outward sends by itself: a connector that can send, post, or change something can do so without asking you first.
Record a standing rule before you connect mail or chat ([ONBOARDING step 8](../ONBOARDING.md#8-connect-your-other-tools) prompts for it).
Record it in both places: `data/captain.md` binds the first mate, and the same line in `config/brief-include.md` puts it in every worker brief, since workers get the same connectors but do not read `data/captain.md`.
For example:

```text
remember this as a standing rule, and add the same line to config/brief-include.md so every worker brief carries it: never send, post, or reply to anyone outside on my behalf without showing me the draft first
```

Once you run second mates, also put the rule in `data/captain-shared.md`, which second mates inherit, and in each second mate home's `config/brief-include.md`, since neither of your main home's copies reaches them.

Record useful facts about your connectors as learnings, for example "the shared support inbox replies never show in my own Gmail".

### Firstmate's own tools

The first mate installs these during setup, after you say yes.

| Tool | What it is for | Check it with |
| --- | --- | --- |
| `gh-axi` | GitHub work: pull requests, checks, issues | `gh-axi` prints your repository and its open pull requests |
| `chrome-devtools-axi` | A browser the agents drive for web checks and screenshots | `chrome-devtools-axi --help` |
| `lavish-axi` | Review pages you read and comment on in the browser | Ask "show me a one-page summary of the fleet as a review page" |
| `quota-axi` | How much of each AI subscription is left | `quota-axi` prints remaining usage for each signed-in tool |
| `tasks-axi` | The backlog | `bin/fm-tasks-axi.sh` prints the backlog dashboard |
| `no-mistakes` | The full-checks delivery pipeline | `no-mistakes doctor` |

[docs/configuration.md](configuration.md#toolchain) owns the required list and versions.

## Optional extras, off until you switch them on

A fresh copy includes every feature, but anything that talks to a paid service, speaks out loud, or runs on a schedule stays off until you opt in.
Ask the first mate to set one up; each owner page lists what it needs.

| Feature | What it does | Needs |
| --- | --- | --- |
| Away and quiet modes (`/afk`, `/quiet`) | Keep routine events off your screen | Nothing extra |
| Chart room ([chart-room.md](chart-room.md)) | A private local page showing where every project stands | Nothing extra |
| Desk floater ([desk-floater.md](desk-floater.md)) | Push-to-talk button on your Mac that types what you say into the first mate | A Deepgram API key; spoken replies also need a separate voice project's speech shaper |
| Spoken replies ([configuration](configuration.md#desk-voice-out-configspeak)) | The first mate reads the start of each reply aloud | The same speech shaper |
| Phone bridge page ([bridge-view.md](bridge-view.md)) | A phone page showing what needs you, with photo drop and hold-to-speak | Tailscale and Python 3.12 |
| Morning intake ([configuration](configuration.md#morning-intake-configmorning-intake)) and dropped-threads digest ([configuration](configuration.md#dropped-threads-digest-configdropped-threads)) | A daily intake and a twice-daily "what is left hanging" summary | A scheduled job on this Mac |
| Computer use ([macos-computer-use](../.agents/skills/macos-computer-use/SKILL.md)) | Lets the agents operate Mac apps and windows | Peekaboo, which the first mate installs, and Mac Accessibility permissions |
| Activity ledger ([fleet-ledger.md](fleet-ledger.md)) | A file other tools can read to follow the fleet | Nothing extra |

## Keeping it current

Say "update firstmate" (or `/updatefirstmate`) every week or so.
It pulls the latest shared instructions and scripts and restarts cleanly; your private folders are never touched.
If you use firstmate on two of your own machines, [porting.md](porting.md) covers moving your private material between them.
Porting is for your own machines only: a colleague starts from a fresh clone and builds their own home.

## Your first week

Each step is small and proves one part of the system.

**Day 1 - running and connected.**

1. Finish [ONBOARDING.md](../ONBOARDING.md), including the slug test.
2. Record the outward-send standing rule from [Connectors and tools](#a-rounded-starter-set-for-a-work-setup), then add your connectors and check each with one real question.
3. Tell the first mate three things about how you work, as standing preferences, then ask "what's in captain.md now?".
4. Run `/bearings`.

**Day 2 - a first investigation.**

1. Add one real project: "add `github.com/<org>/<repo>` as a project; deliver with full checks", using your real project's address.
2. Ask a scout question about it: "how does sign-up work in this project? report only".
3. Read the findings, ask one follow-up, and record anything surprising as a learning.

**Day 3 - a first change.**

1. Ask for one small, low-risk fix on that project.
2. Watch the worker in its pane while it runs.
3. Review the pull request when the first mate brings it, then say "merge it".

**Day 4 - make it yours.**

1. Make one personal skill for something you do every week.
2. Add one standing worker rule to `config/brief-include.md`, with the first mate's help.
3. Run `/stow` at the end of the day and read what it filed.

**Day 5 - step away.**

1. Start two jobs, then run `/afk` and leave for an hour.
2. When you return, read the return summary and use `/ahoy` for anything waiting.
3. Ask for a review page comparing two options for something real on your plate.

By the end of the week you have used every part of the loop: asking, delegating, approving, teaching, and stepping away.
From there, ask the first mate for anything; when it does something you do not like, tell it, and ask it to record that as a standing preference.

# Onboarding: blank Mac to a working first mate

You're installing an AI project manager that runs in your terminal.
You talk to it in plain English; it does the coding work, uses other AI workers to help, and reports back.
Five steps, about 30 minutes, mostly waiting for installs.

This guide is for a blank macOS machine.
On a Windows PC, start with [ONBOARDING-windows.md](ONBOARDING-windows.md); on a rented Linux server, start with [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md).
Both set up the machine, then return here for steps 3 to 5.
The finish line is real work: your first mate brings back one report from a worker that read something you know.
That is one of your own GitHub repositories or, if you have none, a folder of your own work on your Mac, such as an export of your tickets or a few documents.
After that, [the captain's handbook](docs/handbook.md) explains the whole system, connects your other tools, and gives you a first-week path.

> **Sending these commands to someone over Slack or another chat app?** Send each one as a code block (the `</>` button, or three backticks around it).
> Chat apps turn straight quotes into curly ones, which breaks a command; the commands in this guide carry no quotes, so a code block keeps them exact.

> Your setup is yours alone.
> A fresh clone gets only the public repo - no one else's preferences, backlog, project list, or accounts.
> Your private folders (`data/`, `state/`, `config/`, `projects/`, `.env`) are created on first run, empty apart from Starship's starter settings in `config/`, stay on your machine, and are gitignored forever.

---

## 1. Accounts (browser, before the terminal)

1. **GitHub** - an account of your own; a free one is fine, and you need no repositories yet.
   Starship itself is public, so you install plain Starship; during setup your first mate makes you one private repository on this account, for your own changes.
   If you want your first report on a repository someone else owns, and it shows you a 404, ask its owner to invite you.
2. **Claude** - a Claude account with a paid plan (Pro or Max) for Claude Code.
   If your organisation has a Claude workspace, use that account: the connectors it offers (mail, calendar, documents, and so on) then come along into Claude Code.

You should see: both accounts signed in in a browser tab.

---

## 2. Install everything (Terminal, before anything else opens)

Your Mac user must be an administrator, because Homebrew, the installer everything else comes from, asks for your Mac password.
**System Settings**, then **Users & Groups**, shows "Admin" under your name when you are one; if it says "Standard", ask whoever manages the Mac to make you an admin first.

Open **Terminal** (press Command-Space, type Terminal, press Enter) and paste this one line:

```sh
curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/starship/main/bin/fm-mac-setup.sh | bash
```

It checks for Homebrew, Node and jq first and installs whatever is missing, so nothing later fails for want of them.
Then it installs Claude Code, gets Starship into `~/starship`, sets up [Herdr](https://herdr.dev), and installs every other tool your first mate needs, all in this Terminal window, before your first mate ever starts.
When it asks for your password, type your Mac password; nothing shows while you type, which is normal.
It takes about 10 to 20 minutes, mostly Apple's command line tools downloading.
If the text stops without `Setup finished.`, run the same line again: it keeps what is already installed and finishes the rest.

You should see: `Setup finished.`, then your first-hour checklist with the first three steps ticked.

Then open a **new** Terminal window (Command-N), so the new tools are found, and sign in twice:

```sh
gh auth login
claude
```

`gh auth login` asks four questions with the answers you want already selected, so press Enter at each: **GitHub.com**, **Login with a web browser**, **HTTPS**, then **Yes** to authenticate Git.
`claude` opens a browser login; complete it, then type `/exit`, or press Enter if it asks whether to trust your home folder, which just closes it.

You should see: `gh auth status` says you are logged in to github.com.

**Your first-hour checklist.** It lists every step from here to your first report and ticks each one off by itself as it completes.
To keep it open while you work, open one more Terminal window and run:

```sh
~/starship/bin/fm-first-hour.sh --watch
```

---

## 3. Get Starship and start your first mate

Your first mate and its workers run inside [Herdr](https://herdr.dev), a terminal view made for AI agents: every worker shows up in its sidebar, with whether it is working or waiting for you.

**On a Mac, one command opens everything.** Step 2 already got Starship and set up Herdr.
Open a **new** Terminal window and type:

```sh
onboard-starship
```

With nothing else to type or choose, it starts Herdr with your first mate, the bridge strip across the top and the Factory pane beside it, then opens your Starship web page, a plain-words view of the same desk ([docs/web.md](docs/web.md)), as its own window.
Last, it opens a Terminal window on the desk and brings it to the front, because Claude Code asks two questions there the first time (below).
The web page is one swipe or Command-Tab away; it shows your first mate's chat once those questions are answered.
The first time, Herdr shows a short welcome in that window; press Enter, then Esc to close the settings it opens.

You should see: a Terminal window with your first mate's pane, the bridge strip across its top and the Factory pane beside it, and a Starship window in your browser.

Coming from [ONBOARDING-windows.md](ONBOARDING-windows.md)? Its setup script already did the first part, and its step 8 opened Herdr; start at **Start your first mate**, in Herdr's shell.
Coming from [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md)? A server runs in tmux instead; start at **Start your first mate**, inside your tmux session.

**Get Starship and set up Herdr by hand** (only if you skipped step 2's setup line):

```sh
git clone https://github.com/Amplify-Logic/starship ~/starship
cd ~/starship
bin/fm-herdr-setup.sh
```

It installs Herdr, adds Herdr's Claude Code integration so Herdr can show what each Claude is doing, sets this Starship to run in Herdr, and adds the `starship` and `onboard-starship` commands ([docs/desk.md](docs/desk.md)).
You should see: `Herdr is ready.`; then run `onboard-starship` in a new Terminal window, as above.

**Start your first mate** (Windows and Linux servers; on a Mac, `onboard-starship` already did this): in Herdr's shell, or your tmux session, type:

```sh
cd ~/starship && bin/fm-primary.sh opus
```

That launches Claude Code on Opus, with its permission prompts turned off so the first mate can run its own scripts; [its house rules](docs/handbook.md#how-it-works-in-plain-words) are what keep it safe.

**Claude Code's first two questions.** Both start with **No, exit** selected, so pressing Enter alone quits.
For each, press the down arrow once, then Enter:

1. "Is this a project you created or one you trust?": choose **Yes, I trust this folder**.
   That loads the guards that let your first mate notice when a worker finishes or gets stuck; without them it may never notice.
2. "WARNING: Claude Code running in Bypass Permissions mode": choose **Yes, I accept**.

Claude Code may also offer to switch to its new full-screen display.
Either answer works; your first mate and its workers run the same way in both.

You should see: Claude Code open inside the `starship` folder, ready for a message.

That first launch also sets up your home with Starship's starter settings, with nothing to copy:

- **Which model does which job.** Opus 5.5 does nearly everything; Sonnet 5.5 and Haiku 5.5 take only small, fully specified chores, so a Claude Pro or Max 5x plan lasts.
- **How hard your first mate thinks.** It follows your Claude plan: `medium` on Pro, `high` on Max 5x, and `xhigh` only on Max 20x. The launch line names the level and your plan.
  A Team or Enterprise seat does not report a plan Starship can read, so it gets `high` and the launch line says "the default when the Claude plan cannot be read"; that is expected, not an error.
- **Transcription words** for the desk floater; replies stay text unless you set up [desk voice-out](docs/fork-configuration.md#desk-voice-out-configspeak).

To change how hard your first mate thinks, write one word, then start it again: `echo high > config/primary-effort`.
The words, from lightest to deepest, are `low`, `medium`, `high`, `xhigh` and `max`; deeper thinking uses your plan's allowance faster, and `rm config/primary-effort` goes back to your plan's level.

Each worker your first mate starts appears in Herdr's sidebar as its own space while it works, and goes away when it is cleaned up.
Click one to watch it, or press `Ctrl-b`, then `w`, to pick one; come back to your first mate the same way.

**Every day after this, on a Mac:** open Terminal and type `starship`.
It opens your desk again as you left it, and after the Mac restarts it starts your first mate, the bridge strip and the Factory pane again too; it changes nothing that is already open.
To open the web page again, run `~/starship/bin/fm-web.sh open`.
On Windows, follow the daily steps in [ONBOARDING-windows.md step 9](ONBOARDING-windows.md#9-finish-with-the-shared-steps) instead, because closing Ubuntu stops Herdr there.

**Prefer tmux?** Herdr is the default, and tmux still works: run `echo tmux > ~/starship/config/backend`, start the first mate inside `tmux new -s firstmate`, and workers open as tmux windows instead ([docs/tmux-backend.md](docs/tmux-backend.md)).

---

## 4. Say hello: your first mate takes it from here

Type anything; `hello` is enough.

Your first mate introduces itself and leads the rest of your setup.
Every tool is already installed by step 2, so it installs nothing here.
If it says a few tools did not finish installing, open a new plain Terminal window (not a Herdr pane), run the line it gives you, and tell it when it is done.

It may also mention that your Claude Code version is newer than the one Starship was checked with, and ask whether to re-certify or pin it.
You can ignore that: nothing is blocked, keeping that check current is the maintainers' job, and you can answer "leave it as it is".

Then it asks you four questions, one at a time, each with its reason:

1. Your name, and, if you like, how you like to be talked to.
2. What your work is about and what you would like a hand with; "I'm new and still finding out" is a fine answer.
3. Three house rules it keeps unless you change them, and the one rule that is yours.
4. What the first report should be on: a GitHub repository you know well or, if you have none, a folder on your Mac with some of your own work in it.

Answer in your own words; "keep the defaults" is a fine answer to the third, and to how you like to be talked to, while your name is always yours to give.
The three rules it offers are the ones that keep it safe: it never sends, posts or replies to anyone outside on your behalf without showing you the draft first, nothing merges without your word, and nothing destructive or irreversible happens without you saying so.
It writes your answers into your private preferences file (`data/captain.md`) and gives every worker your first rule as you left it, or no such rule if you dropped it.
The conversation itself lives in [the first-voyage skill](.agents/skills/first-voyage/SKILL.md), which is what your first mate follows.

You should see: it tells you your answers are written in your preferences file, `data/captain.md`, and that every worker now carries your first rule as you left it.

Before the fourth question, it asks your yes to make you your own private repository on your GitHub account, your add-on.
This step is not optional: if you say no, the first project waits until you agree.
Every change you want to how your first mate works goes there, never into public Starship, so nothing of yours can reach the public repository by mistake.
It also checks that every push from your home is screened, so nothing private reaches the public repository.
If GitHub is not signed in yet, it stops and tells you how to sign in; run `gh auth login` again if so, then tell it you're done.

You should see: it names your new private repository, and says every push from your home is now checked.

---

## 5. Finish line: the first report comes back

Right after the fourth answer, your first mate adds your first project.
A repository is added through no-mistakes: every change goes through the full no-mistakes checks and comes to you as a pull request, and nothing merges until you say so.
A folder of your own work becomes a project that stays on your Mac: the report reads the folder where it is, changes nothing in it, and publishes nothing.
It also tells you one or two true things about what it found.
Then it proposes the first job from what you said about your work: a report on the part closest to it, with no changes.
Say **go**, or name a different part you know well.

You should see: a few minutes later, a short plain-English report on that part.
Check it against what you know.
That one report proves the whole stack end to end: your access to the project, a worker starting in its own isolated copy, its Claude sign-in, and the report coming back to you.
Your setup is finished, and every step of your first-hour checklist is ticked.
To see this and every later job at a glance, ask your first mate to open the Factory pane (`bin/fm-factory-pane.sh install`, run inside Herdr; see [docs/factory-pane.md](docs/factory-pane.md)).

If the session ends before the first report, just say so next time, for example "let's finish setting up", and your first mate picks up where it left off.
If the report never comes back, ask "why can't you start a worker?" and fix what it names.

---

## Optional: starter settings and the call recorder

A new home gets the starter settings on its first launch (step 3).
A home that ran before they shipped can copy them into its private `config/` folder; `cp -n` never replaces a file you already have:

```sh
cp -n docs/examples/crew-dispatch-claude-only.json config/crew-dispatch.json
cp -n docs/examples/stt-vocabulary config/stt-vocabulary
```

- `crew-dispatch.json` decides which Claude model does which job: Opus 5.5 for nearly everything, Sonnet 5.5 for well-specified mechanical work, and Haiku 5.5 for tiny chores, sized for a Pro or Max 5x plan; it uses no other provider or account.
- `stt-vocabulary` teaches the desk floater's transcription the names you say; add your own below its starter words.
- Spoken replies are not a starter setting; [desk voice-out](docs/fork-configuration.md#desk-voice-out-configspeak) explains what they need.

You should see: after a restart, your first mate dispatches workers on Claude only.

Starship also carries a call recorder that turns a call into a live desk and end-of-call notes, on macOS.
It records only after everyone on the call has agreed; [docs/call-companion.md](docs/call-companion.md) explains setup, stopping and deleting.
It transcribes on your Mac by default, which needs a reasonably fast Mac; on a slower one or one short of memory, ask your first mate to set it to Deepgram instead, which transcribes the call as it happens on any Mac for a per-minute price shown on Deepgram's pricing page.
That needs a Deepgram key, the same one the desk floater uses, in your home's private `.env` file; put it there yourself and never paste it into the chat, as [the engine section](docs/call-companion.md#transcription-engine-on-this-mac-or-deepgram) shows, and `bin/fm-call-companion.sh engine` tells you which engine suits your Mac and how to switch back.

---

## Next

To get the latest Starship at any time, tell your first mate "update starship": it pulls the shared Starship and restarts any second mates on it.
A client or teammate who does not write code can choose a calm, named monthly version instead of the newest changes: `echo release > ~/starship/config/update-channel` ([configuration](docs/fork-configuration.md#update-channel-configupdate-channel)).
If you set up Starship before, [CHANGELOG.md](CHANGELOG.md) lists what changed for an existing home and what to do.

Read [the captain's handbook](docs/handbook.md).
It explains the whole system in plain words, how to connect your mail, calendar and documents, how to teach the first mate your preferences, how to approve work, and a five-day path of small practice tasks.

## Troubleshooting

| You see | Do this |
|---|---|
| `Invalid input. Please press 'y' to proceed` | Homebrew is asking yes or no; press `y`. |
| `command not found: brew` | Open a new Terminal window; step 2's setup line makes new windows find Homebrew. If it is still not found, run that line again. |
| `command not found: npm` or `claude` | Run step 2's setup line again, then open a new Terminal window. |
| Not sure what is left to do | `~/starship/bin/fm-first-hour.sh` lists every first-hour step, ticked or not, and says how to finish the next one. |
| A command someone sent you over chat fails with odd quote marks | Ask them to send it as a code block; chat apps turn straight quotes into curly ones. |
| `gh: not logged in` or `NEEDS_GH_AUTH` | `gh auth login`, answering its four questions with GitHub.com, the web browser, HTTPS, and Yes to authenticate Git. |
| `bin/fm-primary.sh` refuses to start | `bin/fm-primary.sh opus --preflight` names what is missing without starting anything. |
| `permission denied` on `bin/fm-primary.sh` | `chmod +x bin/*.sh`, then launch again. |
| `refuses another live Firstmate session` | One is already running, perhaps in another Herdr space or Terminal window; type `/exit` in the spare one, then launch again. |
| `command not found: herdr` | Open a new Terminal window; if it is still not found, run `bin/fm-herdr-setup.sh` again from `~/starship`. |
| It doesn't call you captain, or the name you gave it | You are not in the Starship folder; `cd ~/starship` and launch again. |
| Claude says you reached your usage limit, or workers stop until a reset time | On Claude Pro, your first mate and every Opus worker share one usage window. Wait for the reset time Claude names, then ask the first mate to run fewer workers at a time, or lower its thinking level with `echo low > config/primary-effort` and start it again. |
| It asks whether to re-certify or pin Claude Code | Ignore it; say "leave it as it is". Nothing is blocked, and that check is the maintainers' job. |
| `skipped: dirty working tree` after "update starship" | `git -C ~/starship status --short` lists the cause. Move a `??` file out of `~/starship`; for an `M` file, save a copy elsewhere if you want it, then `git -C ~/starship restore <path>`. Then update again. |
| It cannot add your first project | Your GitHub account cannot see that repository yet; ask its owner to invite you, or give it a folder of your own work instead. |
| It never notices a worker finished | The trust prompt was declined; quit, launch again, and choose **Yes, I trust this folder**. |
| Nothing happens for minutes | Normal - work runs in the background. Ask "what are you doing?" |

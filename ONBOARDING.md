# Onboarding: blank Mac to a working first mate

You're installing an AI project manager that runs in your terminal.
You talk to it in plain English; it does the coding work, uses other AI workers to help, and reports back.
Five steps, about 30 minutes, mostly waiting for installs.

This guide is for a blank macOS machine.
On a Windows PC, start with [ONBOARDING-windows.md](ONBOARDING-windows.md); on a rented Linux server, start with [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md).
Both set up the machine, then return here for steps 3 to 5.
The finish line is real work: your first mate adds the Harbour Logbook project and brings back one report from a worker that read it.
After that, [the captain's handbook](docs/handbook.md) explains the whole system, connects your other tools, and gives you a first-week path.

> Your setup is yours alone.
> A fresh clone gets only the public repo - no one else's preferences, backlog, project list, or accounts.
> Your private folders (`data/`, `state/`, `config/`, `projects/`, `.env`) are created on first run, empty apart from the team's starter settings in `config/`, stay on your machine, and are gitignored forever.

---

## 1. Accounts (browser, before the terminal)

1. **GitHub** - an account that can see the `harbourlogbook` organisation; ask its owner to invite you if `github.com/harbourlogbook/private-app` shows you a 404.
2. **Claude** - the Claude account your team uses for Claude Code.
   If your organisation has a Claude workspace, use that account: the connectors it offers (mail, calendar, documents, and so on) then come along into Claude Code.

You should see: both accounts signed in in a browser tab.

---

## 2. Install the tools (Terminal)

Install Homebrew:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

When it finishes it prints two lines that put `brew` on your `PATH`.
Run them, then open a **new** Terminal window for everything below.

```sh
brew install git node gh tmux jq
gh auth login
npm install -g @anthropic-ai/claude-code
claude
```

Homebrew asks `Do you want to proceed with the installation? [y/n]` before it installs; press `y`.
`gh auth login` asks four questions with the answers you want already selected, so press Enter at each: **GitHub.com**, **HTTPS**, **Yes** to authenticate Git, then **Login with a web browser**.
`claude` opens a browser login; complete it, then type `/exit`, or press Enter if it asks whether to trust your home folder, which just closes it.

You should see: `gh auth status` says you are logged in to github.com, and `claude --version` prints a version.

---

## 3. Get Starship and start your first mate

Your first mate and its workers run inside [Herdr](https://herdr.dev), a terminal view made for AI agents: every worker shows up in its sidebar, with whether it is working or waiting for you.

Coming from [ONBOARDING-windows.md](ONBOARDING-windows.md)? Its setup script already did the first part, and its step 8 opened Herdr; start at **Start your first mate**, in Herdr's shell.
Coming from [ONBOARDING-linux-server.md](ONBOARDING-linux-server.md)? A server runs in tmux instead; start at **Start your first mate**, inside your tmux session.

**Get Starship and set up Herdr:**

```sh
git clone https://github.com/Amplify-Logic/firstmate ~/starship
cd ~/starship
bin/fm-herdr-setup.sh
```

It installs Herdr, adds Herdr's Claude Code integration so Herdr can show what each Claude is doing, and sets this Starship to run in Herdr.

You should see: `Herdr is ready.`

**Open Herdr:** open a **new** Terminal window, so `herdr` is found, and type:

```sh
herdr
```

The first time, Herdr may first ask how it should notify you; any answer works, and you can change it later in Herdr's settings (`Ctrl-b`, then `s`).
Herdr then shows a shell, with a sidebar on the left.

**Start your first mate:** in that shell, type:

```sh
cd ~/starship && bin/fm-primary.sh opus
```

That launches Claude Code on Opus, with its permission prompts turned off so the first mate can run its own scripts; [its house rules](docs/handbook.md#how-it-works-in-plain-words) are what keep it safe.

The first time, Claude Code asks two questions, and both start with **No, exit** selected, so pressing Enter alone quits.
For each, press the down arrow once, then Enter:

1. "Is this a project you created or one you trust?": choose **Yes, I trust this folder**.
   That loads the guards that let your first mate notice when a worker finishes or gets stuck; without them it may never notice.
2. "WARNING: Claude Code running in Bypass Permissions mode": choose **Yes, I accept**.

Claude Code may also offer to switch to its new full-screen display.
Either answer works; your first mate and its workers run the same way in both.

You should see: Claude Code open inside the `starship` folder, ready for a message.

That first launch also sets up your home the team's way, with nothing to copy:

- **Which model does which job.** Opus 5.5 does nearly everything; Sonnet 5.5 and Haiku 5.5 take only small, fully specified chores, so a Claude Pro or Max 5x plan lasts.
- **How hard your first mate thinks.** It follows your Claude plan: `medium` on Pro, `high` on Max 5x, and `xhigh` only on Max 20x. The launch line names the level and your plan.
- **Spoken replies and transcription words**; replies stay text only until you set up voice ([desk voice-out](docs/configuration.md#desk-voice-out-configspeak)).

To change how hard your first mate thinks, write one word, then start it again: `echo high > config/primary-effort`.
The words, from lightest to deepest, are `low`, `medium`, `high`, `xhigh` and `max`; deeper thinking uses your plan's allowance faster, and `rm config/primary-effort` goes back to your plan's level.

Each worker your first mate starts appears in Herdr's sidebar as its own space while it works, and goes away when it is cleaned up.
Click one to watch it, or press `Ctrl-b`, then `w`, to pick one; come back to your first mate the same way.

**Every day after this, on a Mac:** open Terminal and type `herdr`.
Herdr keeps running when you close the window (or press `Ctrl-b`, then `q`, to leave it), so this brings back your first mate as you left it.
After the Mac restarts, Herdr reopens your spaces; if your first mate's space shows only a shell, run `cd ~/starship && bin/fm-primary.sh opus` there again, and it picks up its work from where it stopped.
On Windows, follow the daily steps in [ONBOARDING-windows.md step 9](ONBOARDING-windows.md#9-finish-with-the-shared-steps) instead, because closing Ubuntu stops Herdr there.

**Prefer tmux?** Herdr is the default, and tmux still works: run `echo tmux > ~/starship/config/backend`, start the first mate inside `tmux new -s firstmate`, and workers open as tmux windows instead ([docs/tmux-backend.md](docs/tmux-backend.md)).

---

## 4. Let it finish its own setup, and set one standing rule

Type:

```text
run your startup checks and install what's missing
```

It lists the tools still missing (for example `treehouse` and `no-mistakes`), says what each is for, and asks before installing.
Say **yes**.

You should see: it reports the tools installed, with nothing required still missing.

Next, before you ever connect mail or chat, tell it how to treat anything it would send on your behalf:

```text
remember this as a standing rule, and add the same line to config/brief-include.md so every worker brief carries it: never send, post, or reply to anyone outside on my behalf without showing me the draft first
```

You should see: it confirms it recorded the rule in `data/captain.md` and in `config/brief-include.md`.

---

## 5. Finish line: add Harbour Logbook and get one report back

Type:

```text
add github.com/harbourlogbook/private-app as a project, delivered through no-mistakes, and never merge anything there without asking me
```

That is the team's setting for Harbour Logbook: every change goes through the full no-mistakes checks and comes to you as a pull request, and nothing merges until you say so.
A merge to its main branch goes live, so leave automatic merging (`+yolo`) off for this project.

Then ask for one report, with no changes:

```text
how does the Play tab open in private-app? report only, no changes
```

You should see: a few minutes later, a short plain-English report on how the Play tab opens.

That one report proves the whole stack end to end: your GitHub access to the project, a worker starting in its own isolated copy, its Claude sign-in, and the report coming back to you.
Your setup is finished.

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
- Spoken replies are not a starter setting: `cp -n docs/examples/speak config/speak` turns them on, and they need the Starship Voice project and a Deepgram key or a macOS voice, as [desk voice-out](docs/configuration.md#desk-voice-out-configspeak) explains.

You should see: after a restart, your first mate dispatches workers on Claude only.

Starship also carries a call recorder that turns a call into a live desk and end-of-call notes, on macOS.
It records only after everyone on the call has agreed; [docs/call-companion.md](docs/call-companion.md) explains setup, stopping and deleting.

---

## Next

To get the team's latest Starship at any time, tell your first mate "update starship": it pulls the shared Starship and restarts any second mates on it.

Read [the captain's handbook](docs/handbook.md).
It explains the whole system in plain words, how to connect your mail, calendar and documents, how to teach the first mate your preferences, how to approve work, and a five-day path of small practice tasks.

## Troubleshooting

| You see | Do this |
|---|---|
| `Invalid input. Please press 'y' to proceed` | Homebrew is asking yes or no; press `y`. |
| `command not found: brew` | Run the two `PATH` lines Homebrew printed at the end, then open a new Terminal window. |
| `command not found: npm` or `claude` | `brew install node`, then `npm install -g @anthropic-ai/claude-code`, then open a new Terminal window. |
| `gh: not logged in` or `NEEDS_GH_AUTH` | `gh auth login`, answering its four questions with GitHub.com, HTTPS, Yes to authenticate Git, and the web browser. |
| `bin/fm-primary.sh` refuses to start | `bin/fm-primary.sh opus --preflight` names what is missing without starting anything. |
| `permission denied` on `bin/fm-primary.sh` | `chmod +x bin/*.sh`, then launch again. |
| `refuses another live Firstmate session` | One is already running, perhaps in another Herdr space or Terminal window; type `/exit` in the spare one, then launch again. |
| `command not found: herdr` | Open a new Terminal window; if it is still not found, run `bin/fm-herdr-setup.sh` again from `~/starship`. |
| It doesn't call you captain | You are not in the Starship folder; `cd ~/starship` and launch again. |
| It cannot add Harbour Logbook | Your GitHub account cannot see the `harbourlogbook` organisation yet; ask its owner to invite you. |
| It never notices a worker finished | The trust prompt was declined; quit, launch again, and choose **Yes, I trust this folder**. |
| Nothing happens for minutes | Normal - work runs in the background. Ask "what are you doing?" |

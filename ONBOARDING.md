# Onboarding: blank Mac to a working first mate

You're installing an AI project manager that runs in your terminal.
You talk to it in plain English; it does the coding work, uses other AI workers to help, and reports back.
Five steps, about 30 minutes, mostly waiting for installs.

This guide is for a blank macOS machine.
The finish line is real work: your first mate adds the Harbour Logbook project and brings back one report from a worker that read it.
After that, [the captain's handbook](docs/handbook.md) explains the whole system, connects your other tools, and gives you a first-week path.

> Your setup is yours alone.
> A fresh clone gets only the public repo - no one else's preferences, backlog, project list, or accounts.
> Your private folders (`data/`, `state/`, `config/`, `projects/`, `.env`) are created empty on first run, stay on your machine, and are gitignored forever.

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

For `gh auth login`, choose **GitHub.com**, then **HTTPS**, then **Login with a web browser**.
`claude` opens a browser login; complete it, then type `/exit`.

You should see: `gh auth status` says you are logged in to github.com, and `claude --version` prints a version.

---

## 3. Get Starship and start your first mate

```sh
git clone https://github.com/Amplify-Logic/firstmate ~/starship
cd ~/starship
bin/fm-primary.sh opus
```

That launches Claude Code on Opus, with its permission prompts turned off so the first mate can run its own scripts; [its house rules](docs/handbook.md#how-it-works-in-plain-words) are what keep it safe.

The first time, Claude Code asks whether you trust this folder.
**Say yes.**
That loads the guards that let your first mate notice when a worker finishes or gets stuck; without them it may never notice.

You should see: Claude Code open inside the `starship` folder, ready for a message.

Workers open as tmux windows, which needs nothing more.
[Herdr](docs/herdr-backend.md) is an optional, richer view you can add later; tell your first mate "use herdr" once it is installed.

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

## Next

Read [the captain's handbook](docs/handbook.md).
It explains the whole system in plain words, how to connect your mail, calendar and documents, how to teach the first mate your preferences, how to approve work, and a five-day path of small practice tasks.

## Troubleshooting

| You see | Do this |
|---|---|
| `command not found: brew` | Run the two `PATH` lines Homebrew printed at the end, then open a new Terminal window. |
| `command not found: npm` or `claude` | `brew install node`, then `npm install -g @anthropic-ai/claude-code`, then open a new Terminal window. |
| `gh: not logged in` or `NEEDS_GH_AUTH` | `gh auth login`, choosing GitHub.com, HTTPS, and the web browser. |
| `bin/fm-primary.sh` refuses to start | `bin/fm-primary.sh opus --preflight` names what is missing without starting anything. |
| `permission denied` on `bin/fm-primary.sh` | `chmod +x bin/*.sh`, then launch again. |
| `refuses another live Firstmate session` | One is already running; close the other window, or run `tmux ls` and exit the spare session. |
| It doesn't call you captain | You are not in the Starship folder; `cd ~/starship` and launch again. |
| It cannot add Harbour Logbook | Your GitHub account cannot see the `harbourlogbook` organisation yet; ask its owner to invite you. |
| It never notices a worker finished | The trust prompt was declined; quit, launch again, and accept it. |
| Nothing happens for minutes | Normal - work runs in the background. Ask "what are you doing?" |

# Onboarding: blank Mac to a working first mate

You're installing an AI project manager that runs in your terminal.
You talk to it in plain English; it does the coding work, uses other AI workers to help, and reports back.
About 20 minutes, mostly waiting for installs.

This guide is for a blank macOS machine.
When you finish, you will have a running first mate that can really dispatch a worker - not just chat back.
The real finish line is a **slug round-trip**: a worker writes a random word into a file in its own isolated copy and reports it back to you.

> Your setup is yours alone.
> A fresh clone gets only the public repo - no one else's preferences, backlog, project list, or accounts.
> Your private folders (`data/`, `state/`, `config/`, `projects/`, `.env`) are created empty on first run, stay on your machine, and are gitignored forever.

---

## 1. Two accounts (browser, before the terminal)

1. **GitHub** (free) - create an account if you do not have one.
2. **One AI coding subscription** - use **Claude Code**.
   Claude Pro (~$20/mo) works; Max also works.
   Cursor, Codex, Grok, Pi, and Kimi exist and can be added later - skip them for now.

You should see: both accounts signed in in a browser tab before you open Terminal.

---

## 2. Six things by hand

Do exactly these six steps.
Do **not** start the agent yet - a preflight checkpoint comes next, then you launch.
After that, the first mate takes over and installs the rest after you say yes.

### 2.1 Homebrew

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

When it finishes it prints two lines to run (they put `brew` on your `PATH`).
Run them, then reopen Terminal.

You should see something like:

```text
==> Installation successful!
```

Then, in a **new** Terminal window:

```sh
brew --version
```

You should see something like: `Homebrew 4.x` (or newer).

If `command not found: brew`, you skipped the two PATH lines - re-run them, reopen Terminal, then re-run the [preflight checkpoint](#3-preflight-checkpoint-before-you-start-the-agent) later.

### 2.2 git, node, and gh

```sh
brew install git node gh
```

You should see something like: `==> Pouring ...` lines, then a quiet shell prompt with no error.

Check:

```sh
git --version && node --version && gh --version
```

You should see three version lines (for example `git version 2.x`, `v22.x`, `gh version 2.x`).

### 2.3 Sign in to GitHub

```sh
gh auth login
```

Choose: **GitHub.com** → **HTTPS** → **Login with a web browser**.
Complete the browser flow, then return to Terminal.

You should see something like: `✓ Authentication complete.` / `Logged in as <your-username>`.

Confirm:

```sh
gh auth status
```

You should see: `✓ Logged in to github.com account <you>` (or similar).

### 2.4 Claude Code + login

```sh
npm install -g @anthropic-ai/claude-code
```

You should see something like: `added N packages` and no error.

```sh
claude
```

Complete the login in the browser, then type `/exit`.

You should see: a Claude Code welcome / login prompt, then a clean exit back to your shell.

Confirm:

```sh
claude --version
```

You should see a version line (for example `2.x.x`).

### 2.5 Herdr (or skip for the simple view)

Install Herdr from [herdr.dev](https://herdr.dev) - get **0.7.4 or newer** (protocol 16).
This is the **one tool your first mate cannot install for you**.
Skip this step if you want the simpler **tmux** view - see [Choosing your view](#choosing-your-view-herdr-or-the-simple-one).

```sh
herdr --version
```

You should see something like: `0.7.4` (or newer).

If you installed Herdr, also check protocol:

```sh
herdr status --json 2>/dev/null | jq -r '.client.protocol // empty'
```

You should see: `16` (or higher).
If that command prints nothing, run `herdr update` or reinstall 0.7.4+ from herdr.dev, then re-check.
If `jq` is not installed yet, skip this check - the first mate installs `jq` later, and the preflight checkpoint treats a missing `jq` as an advisory rather than a failure.

### 2.6 Clone firstmate (do not launch yet)

```sh
git clone https://github.com/Amplify-Logic/firstmate ~/starship
cd ~/starship
ls AGENTS.md bin/fm-primary.sh
```

You should see: `AGENTS.md` and `bin/fm-primary.sh` listed, and your prompt inside `~/starship`.

### Choosing your view (Herdr or the simple one)

**Herdr** is the richer view: every worker gets its own labelled pane, grouped by project, showing what each one is doing.
Download it from [herdr.dev](https://herdr.dev) and get **0.7.4 or newer** (protocol 16).
Older builds start but do not show the grouped labels.
It is dual-licensed **AGPL-3.0-or-later / commercial**.
You are free to install and use it as-is, and it does not affect the licence of anything you build.
Firstmate just runs it as a separate program.
**This is the one tool your first mate cannot install for you.**

**tmux** is the simpler, longest-tested option.
Fewer visuals, equally functional.
Your first mate can install it for you.

**You can switch later** by telling your first mate "use herdr" or "use tmux".

To pick durably yourself (still before launch):

```sh
mkdir -p ~/starship/config
echo herdr > ~/starship/config/backend
# or, if you skipped Herdr:
# echo tmux > ~/starship/config/backend
```

You should see: a file `~/starship/config/backend` whose only contents are `herdr` or `tmux`.

If you launch firstmate from inside Herdr later, it auto-selects Herdr and says so once.

---

## 3. Preflight checkpoint (before you start the agent)

Stay in Terminal.
Do **not** start Claude yet.
Paste this whole block, then fix every ❌ until the block prints no ❌ lines (✅ and optional ⚠️ advisory lines are fine).

```sh
if cd ~/starship; then

ok() { echo "✅ $1"; }
bad() { echo "❌ $1"; echo "   fix: $2"; }

command -v brew >/dev/null && ok "Homebrew" || bad "Homebrew" "re-run step 2.1 PATH lines, reopen Terminal"
command -v git  >/dev/null && ok "git"       || bad "git"  "brew install git"
command -v node >/dev/null && ok "node"      || bad "node" "brew install node"
command -v gh   >/dev/null && ok "gh"        || bad "gh"   "brew install gh"

if gh auth status >/dev/null 2>&1; then ok "gh logged in"
else bad "gh logged in" "gh auth login  (GitHub.com → HTTPS → browser)"; fi

if command -v claude >/dev/null; then
  ok "claude ($(claude --version 2>/dev/null | head -1))"
else
  bad "claude" "npm install -g @anthropic-ai/claude-code && claude  (login, then /exit)"
fi

if [ -f AGENTS.md ] && [ -f bin/fm-primary.sh ]; then
  ok "firstmate clone at $(pwd -P)"
else
  bad "firstmate clone" "git clone https://github.com/Amplify-Logic/firstmate ~/starship && cd ~/starship"
fi

# Herdr is optional - skip path is tmux (the first mate can install tmux later).
if command -v herdr >/dev/null; then
  ver=$(herdr --version 2>/dev/null | head -1)
  if command -v jq >/dev/null; then
    proto=$(herdr status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null || true)
    case "$proto" in
      ''|*[!0-9]*) bad "Herdr protocol" "herdr update  (need 0.7.4+ / protocol 16); got version=[$ver] protocol=[$proto]" ;;
      *)
        if [ "$proto" -ge 16 ]; then ok "Herdr $ver (protocol $proto)"
        else bad "Herdr too old (protocol $proto)" "herdr update  (need protocol 16+; 0.7.4+)"; fi
        ;;
    esac
  else
    echo "⚠️  Herdr protocol not checkable yet - fine, the first mate installs jq later (got version=[$ver])"
  fi
else
  echo "⚠️  Herdr not installed - OK if you chose tmux (step 2.5 skip). Say 'use tmux' after launch."
fi

else
  echo "❌ clone missing - re-run step 2.6"
fi
```

You should see: a checklist of ✅ lines for Homebrew, git, node, gh, gh login, claude, and the clone.
Herdr shows ✅ with protocol 16+, the ⚠️ advisory when `jq` is not installed yet, or the ⚠️ skip line if you chose tmux.

**Re-run this checkpoint after every fix.**
Only when it has no ❌ lines, continue to step 4.

---

## 4. Start your first mate + accept the trust prompt

From `~/starship`:

```sh
bin/fm-primary.sh claude
```

If that refuses, run `claude` from `~/starship` instead.

You should see: Claude Code opening inside the firstmate folder (not a bare shell error).

### 4b. Trust prompt (expected - say yes)

This is a **named step**, not a footnote.
The first time an agent runs in this folder it asks whether to trust the project's setup.

What it looks like (Claude Code): a dialog or inline prompt about trusting this folder / project hooks / workspace settings - often wording like **"Do you trust the authors of the files in this folder?"** or a project-trust / hooks-trust confirmation.
Press the key that accepts (**Yes** / **Trust** / Enter on the affirmative option - exact label varies by Claude Code version).

**Say yes / trust.**
That loads the guards that let your first mate notice when a worker finishes or gets stuck.
If you decline, supervision quietly degrades and it may never notice a finished worker.

For Grok this is `grok --trust` once per clone (or `/hooks-trust` inside Grok).
For Pi it is the project trust prompt on first launch - approve it once so the tracked extensions load.

You should see: the trust prompt dismissed, and the agent ready for a chat message (no repeated trust dialog on the next line).

---

## 5. Let it finish its own setup

Type:

```text
run your startup checks and tell me plainly what's missing
```

You should see: a plain list of still-missing tools (for example `jq`, `tmux`, `treehouse`, `no-mistakes`, GitHub helpers), each with what it is for, plus a clear ask for permission to install.

Say **yes, install them**.
It installs them itself via `bin/fm-bootstrap.sh install` after your consent.

The nine it can install for you after consent are: `jq`, `tmux`, `treehouse`, `no-mistakes`, `gh-axi`, `tasks-axi`, `lavish-axi`, `chrome-devtools-axi`, and `quota-axi`.

If it names something it cannot install for you - Herdr is the only one - it gives you the link.
Follow it, then say **check again**.

You should see: it reports those tools present (or only Herdr still manual), with no remaining required `MISSING:` lines for the path you chose.

If anything looks wrong, fix it, re-run the [preflight checkpoint](#3-preflight-checkpoint-before-you-start-the-agent) in another Terminal tab, then continue.

---

## 6. Confirm it's alive

Type:

```text
ahoy, are you my first mate? one-line status please
```

You should see: a reply that calls you **captain**.
If it does, chat is working - but chat alone is not the finish line.
Continue to the slug test.

---

## 7. Confirm it can actually work (slug round-trip)

Chat alone is not enough.
The finish line is a **slug round-trip**: a real worker, in an isolated copy, writes a slug you choose and reports it back.

1. Pick a random slug - any short nonsense word, for example `orchid-balloon-42`.
2. Type (paste your slug in place of `YOUR-SLUG`):

```text
Dispatch a short test worker - use this firstmate folder itself for the test - whose only job is to write the exact slug YOUR-SLUG into a file named onboarding-slug.txt inside its isolated worktree, then report done and quote the slug back to me. Do not change any project code.
```

3. Wait for the report.

You should see something like:

```text
done - wrote YOUR-SLUG to onboarding-slug.txt
```

(or the same slug quoted in the first mate's plain-English summary)

It may ask which project - answer: this folder (the firstmate checkout itself).

That one green line proves the whole stack end to end: spawn, isolated copy, agent login, and the report channel.
When your slug comes back, your setup is genuinely finished.

If the slug never comes back: ask "why can't you start a worker?" or "what happened to the test worker?", fix what it names, re-run the [preflight checkpoint](#3-preflight-checkpoint-before-you-start-the-agent), then retry this step.

---

## 8. Troubleshooting

Every recovery ends the same way: **re-run the [preflight checkpoint](#3-preflight-checkpoint-before-you-start-the-agent), then continue** from the step you were on.
That way you never leave setup in an undefined state.

| You see | Do this |
|---|---|
| `command not found: brew` | Homebrew printed two `echo` lines at the end. Run them, reopen Terminal. Re-run the checkpoint, then continue. |
| `command not found: claude` | `npm install -g @anthropic-ai/claude-code`, reopen Terminal. Re-run the checkpoint, then continue. |
| `command not found: npm` | `brew install node`. Re-run the checkpoint, then continue. |
| `gh: not logged in` / `NEEDS_GH_AUTH` | `gh auth login` → HTTPS → browser. Re-run the checkpoint, then continue. |
| `MISSING: treehouse` / `MISSING: no-mistakes` | Say "install those" - it can. Re-run the checkpoint, then continue. |
| It doesn't call you captain | You're not in the firstmate folder. `cd ~/starship`, start again. Re-run the checkpoint, then continue. |
| `refuses another live Firstmate session` | One is already running. Close the other window, or run `tmux ls` and exit the spare session. Re-run the checkpoint, then continue. |
| It won't start a worker / slug never comes back | Usually `treehouse` missing or `gh` not authenticated. Ask: "why can't you start a worker?" Re-run the checkpoint, then retry the slug test. |
| Nothing happens for minutes | Normal - work runs in the background. Ask "what are you doing?" |
| `permission denied` on `bin/fm-primary.sh` | `chmod +x bin/*.sh`. Re-run the checkpoint, then continue. |
| `backend=herdr selected but the 'herdr' CLI is not installed` | Install it from [herdr.dev](https://herdr.dev), or say "use tmux instead". Re-run the checkpoint, then continue. |
| `backend=herdr selected but 'jq' is not installed` | Say "install jq". Re-run the checkpoint, then continue. |
| `herdr protocol N … older than the verified minimum` | Run `herdr update`, or download 0.7.4+ from [herdr.dev](https://herdr.dev). Re-run the checkpoint, then continue. |
| Herdr runs but panes have no project/worker labels | Your Herdr is below protocol 16. Run `herdr update`. Re-run the checkpoint, then continue. |
| It never notices a worker finished | The trust prompt was declined. Restart, accept trust (step 4b). Re-run the checkpoint, then retry the slug test. |
| Preflight shows ❌ for something you think you installed | Follow that row's one-line fix hint. Re-run the checkpoint until green, then continue. |

---

## 9. House rules

- It never merges a pull request without your say-so.
- It only touches projects you point it at.
- Your setup is yours alone - nothing you do is shared back to anyone.

When you later contribute an improvement, open a PR against the tracked public files only.
Your private home never enters the PR.

---

## 10. Growing the fleet (optional)

Install only what you'll use.
Once a tool is on your machine and logged in, your first mate will start choosing between them on its own.

### More AI tools

| Add | Why you'd want it | Account |
|---|---|---|
| **Cursor CLI** (`agent`) | Cheap, fast workers on Grok 4.5 / Composer | Cursor Pro |
| **Codex** (`codex`) | Another strong worker; kept available for testing | OpenAI |
| **Pi** (`pi`) | Worker, and the second-opinion checker path | Bring-your-own key |
| **Kimi** (`kimi`) | Economical orchestrator and verified K3 worker | Moonshot |
| **Grok** (`grok`) | Another orchestrator option | xAI |
| **opencode** | Another worker option | Provider-dependent |

Kimi can run the primary session and also take worker jobs via `fm-spawn --harness kimi` (Kimi Code 0.27.0, K3).

If you later want a **second Claude login** without disturbing your main one: make a folder, set `CLAUDE_CONFIG_DIR` to it, and log in there.
Credentials come from logging in on that machine - a config directory is **never copied between machines**.

### More of the fleet

| Add | How |
|---|---|
| **More projects** | Tell your first mate the GitHub URL (or local path) and how you want work delivered. It clones under `projects/` and keeps a local registry. |
| **Second mates** | Persistent helpers with their own isolated firstmate home for a domain of work. Ask your first mate to set one up when one project area grows large enough to need a standing helper. |
| **X mode** | Optional public replies from eligible mentions. Opt in only by placing a pairing token in a local `.env` - see `docs/configuration.md`. Off by default; nothing changes until you opt in. |

---

## See also

- [README.md](README.md) - what firstmate is
- [docs/configuration.md](docs/configuration.md) - layout, backends, and X mode
- [docs/herdr-backend.md](docs/herdr-backend.md) - Herdr details
- [docs/porting.md](docs/porting.md) - moving a private home to a second machine

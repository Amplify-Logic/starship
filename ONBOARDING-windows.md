# Onboarding on Windows: WSL 2 to a working first mate

Firstmate runs on Linux and macOS, so on a Windows PC it runs inside WSL 2, Windows' built-in Linux.
Inside WSL 2 your PC behaves like a Linux machine, and every tool a first mate needs has a Linux build.
Plain Windows (PowerShell or Git Bash) is not supported.

This guide covers the Windows-only part, about 45 minutes, mostly waiting for installs.
Then you finish with the shared steps of [ONBOARDING.md](ONBOARDING.md), exactly as a Mac user does.

**You need:** Windows 11 (22H2 or newer is best) or Windows 10 version 2004 or newer, 16 GB of RAM or more, and admin rights once.
If your PC is work-managed, has less memory, or you cannot get admin rights, use [a small Linux server](ONBOARDING-linux-server.md) instead.

---

## 1. Two accounts

Do [step 1 of ONBOARDING.md](ONBOARDING.md#1-accounts-browser-before-the-terminal): a GitHub account and a Claude subscription.

---

## 2. Turn on WSL 2

Right-click the Start button, choose **Terminal (Admin)** (or **Windows PowerShell (Admin)**), and run:

```powershell
wsl --install -d Ubuntu-24.04
```

Restart the PC when it asks.
After the restart an Ubuntu window opens and asks for a new UNIX username and password.
Pick a short lowercase name and a password you will remember: Linux asks for it when it installs software.

Check, in PowerShell:

```powershell
wsl -l -v
```

You should see `Ubuntu-24.04` with `VERSION` `2`.
If it says `1`, run `wsl --set-version Ubuntu-24.04 2`.

If the install says virtualization is off, turn on "Virtualization Technology" (Intel VT-x or AMD-V) in your PC's BIOS or UEFI settings, then run the command again.

---

## 3. Give WSL the right network and memory

Still in PowerShell, open the WSL settings file:

```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

Let Notepad create it, paste this, and save:

```ini
[wsl2]
networkingMode=mirrored
memory=8GB
```

- `networkingMode=mirrored` lets review boards and the app's web preview open in your normal Windows browser through `localhost`.
  It needs Windows 11 22H2 or newer; on Windows 10, leave that line out, and `localhost` still works through WSL's default forwarding.
- `memory=8GB` suits a 16 GB PC: a first mate, a few workers, a dev server and Chrome want about 8 GB.
  With 32 GB or more you can leave it out.

Apply it:

```powershell
wsl --shutdown
```

---

## 4. Use Windows Terminal

Windows Terminal is built in on Windows 11 and in the Microsoft Store on Windows 10.
Open it, go to **Settings**, then **Startup**, and set **Default profile** to **Ubuntu-24.04**.
Every new tab now opens in Ubuntu, in your Linux home.

---

## 5. The one rule: everything lives in `~`

Keep Firstmate and every project in your Linux home, `~` (for example `/home/ana`).
**Never** under `/mnt/c/...`: that is your Windows C: drive seen through a slow bridge, where git is slow, file watching breaks, and file permissions do not stick.

```sh
cd ~
pwd
```

You should see `/home/<your-name>`.
To look at your Linux files from Windows, run `explorer.exe .` in Ubuntu.
To edit them, install VS Code on Windows with its WSL extension and run `code .` in Ubuntu.

---

## 6. Run the setup script

In an Ubuntu tab, from your home:

```sh
cd ~
curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/firstmate/main/bin/fm-linux-setup.sh | bash
```

It asks for your Ubuntu password once, then installs the build tools, Homebrew, git, node, gh, tmux, Claude Code and Chrome, and clones Firstmate into `~/starship`.
About 15 minutes.

You should see a list of `ok` lines and `Setup finished.`
First close the tab and open a new Ubuntu tab, so the new tools are on your PATH; in the old tab, `gh` and `claude` are not found.
Then, in the new tab, do the two sign-ins it prints:

```sh
gh auth login
claude
```

For `gh`, choose **GitHub.com**, then **HTTPS**, then **Login with a web browser**; the browser opens on Windows.
For `claude`, sign in, then type `/exit`.

---

## 7. Use tmux as your view

Workers open as tmux windows, as on a Mac; on Windows, stay with tmux rather than adding Herdr later, since tmux is the longest-tested option.
Tell Firstmate before you launch:

```sh
mkdir -p ~/starship/config
echo tmux > ~/starship/config/backend
```

Start the first mate inside a tmux session, so every worker appears as a window you can watch:

```sh
tmux new -s firstmate
```

`Ctrl-b` then `w` lists the windows; `Ctrl-b` then `d` detaches, and `tmux attach -t firstmate` brings it back.

---

## 8. Finish with the shared steps

Continue with [ONBOARDING.md step 3, get Starship and start your first mate](ONBOARDING.md#3-get-starship-and-start-your-first-mate), inside your tmux session in Ubuntu, and go on through the Harbour Logbook report in step 5.
Skip step 2 of that guide and the `git clone` line of step 3: the setup script did both.

When the first mate's startup checks run, it also tells you if anything sits under `/mnt/` or if `localhost` cannot reach Windows.

---

## 9. Talk to your first mate (optional)

The desk floater lets you hold a key and talk to your first mate, hear its replies, dictate into any Windows app, and send it screenshots.
Once your first mate runs, put your Deepgram key in `~/starship/.env` as a line `DEEPGRAM_API_KEY=...`, and for spoken replies put `enabled = true` in `~/starship/config/speak`.
Then, in Ubuntu:

```sh
cd ~/starship
bin/fm-desk-floater-windows.sh install
```

It needs no admin rights and nothing to download.
The floater appears at the bottom right of your screen and starts with Windows from now on.
Hold Right Alt and speak to talk to your first mate; [docs/desk-floater-windows.md](docs/desk-floater-windows.md) has the rest.

---

## Working on an app from Windows

- **Web preview:** a dev server started in Ubuntu (for example `pnpm web`) opens in your Windows browser at the `localhost` address it prints.
- **Phone preview with Expo Go:** your phone cannot reach WSL's network directly.
  Start Expo with `npx expo start --tunnel` and scan the QR code.
- **iOS simulator:** needs a Mac.
  Use the web build, an Android emulator, or a cloud build instead.

## Troubleshooting

| You see | Do this |
|---|---|
| `fm-linux-setup.sh: ... is on the Windows drive` | Run `cd ~` and start the setup again. |
| `this is WSL 1` | In PowerShell: `wsl --set-version Ubuntu-24.04 2`, then run the setup again. |
| A board link or `localhost` page does not open in Windows | Check `.wslconfig` from step 3, run `wsl --shutdown`, open a new Ubuntu tab, and start again. |
| `command not found: brew`, `claude`, or `gh` after setup | Open a new Ubuntu tab; the old one has the old PATH. |
| Everything is slow | Check `pwd`: your project must be under `/home/...`, never `/mnt/c/...`. |

For anything else, use the troubleshooting table in [ONBOARDING.md](ONBOARDING.md#troubleshooting).

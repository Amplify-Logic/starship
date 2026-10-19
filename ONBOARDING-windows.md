# Onboarding on Windows: WSL 2 to a working first mate

Firstmate runs on Linux and macOS, so on a Windows PC it runs inside WSL 2, Windows' built-in Linux.
Inside WSL 2 your PC behaves like a Linux machine, and every tool a first mate needs has a Linux build.
Plain Windows (PowerShell or Git Bash) is not supported.

This guide covers the Windows-only part, about 45 minutes, mostly waiting for installs.
Then you finish with the shared steps of [ONBOARDING.md](ONBOARDING.md), exactly as a Mac user does.

**You need:** Windows 11 (22H2 or newer is best) or Windows 10 version 2004 or newer, 16 GB of RAM or more, and admin rights once.
If your PC is work-managed, has less memory, or you cannot get admin rights, use [a small Linux server](ONBOARDING-linux-server.md) instead, or one of the [lighter options](#not-everyone-needs-the-full-setup) at the end.

**Two tips for typing commands:** to paste into a terminal window, right-click inside it (or press `Ctrl+Shift+V`).
When a command asks for a password, nothing appears while you type; that is normal, so type it and press Enter.

---

## 1. Two accounts

Do [step 1 of ONBOARDING.md](ONBOARDING.md#1-accounts-browser-before-the-terminal): a GitHub account and a Claude subscription.

---

## 2. Turn on WSL 2

Right-click the Start button, choose **Terminal (Admin)** (or **Windows PowerShell (Admin)**), and click **Yes** when Windows asks whether to allow the app to make changes.
Then run:

```powershell
wsl --install -d Ubuntu-24.04
```

After a minute or two it ends with "Changes will not be effective until the system is rebooted."
Nothing else asks you to restart, so restart the PC now: **Start**, the power button, **Restart**.

If the install says virtualization is off, turn on "Virtualization Technology" (Intel VT-x or AMD-V) in your PC's BIOS or UEFI settings, then run the command again.

---

## 3. Install Ubuntu and create your user

After the restart, an Ubuntu window may open by itself; if it does, go on in that window.
If nothing opens, open **Terminal (Admin)** again and run the same command a second time; this time it downloads and installs Ubuntu:

```powershell
wsl --install -d Ubuntu-24.04
```

Ubuntu then asks `Create a default Unix user account:` with your Windows name filled in.
Press Enter to keep it, or replace it with a short lowercase name.
Then it asks for a new password twice: pick one you will remember, because Linux asks for it when it installs software.

You are now inside Ubuntu, in your Windows folder (`/mnt/c/Users/<name>`).
Type `exit` to get back to PowerShell, then check:

```powershell
wsl -l -v
```

You should see `Ubuntu-24.04` with `VERSION` `2`.
If it says `1`, run `wsl --set-version Ubuntu-24.04 2`.

---

## 4. Give WSL the right network and memory

Still in PowerShell, open the WSL settings file:

```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

Click **Yes** when Notepad asks to create the file, paste this, and save:

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

It prints nothing.

---

## 5. Use Windows Terminal

Windows Terminal is built in on Windows 11 and in the Microsoft Store on Windows 10.
Open it, click the small down arrow next to the tab, choose **Settings**, then on **Startup** set **Default profile** to **Ubuntu-24.04**, and click **Save** at the bottom right.
If you cannot see **Save**, make the window bigger.
Close Terminal and open it again: every new tab now opens in Ubuntu.

If the new Ubuntu tab starts with `Failed to configure network (networkingMode Mirrored), falling back to networkingMode None`, Ubuntu has no internet.
Your Windows cannot use mirrored networking: delete the `networkingMode=mirrored` line from `.wslconfig` (step 4), run `wsl --shutdown` in PowerShell, and open a new Ubuntu tab.

---

## 6. The one rule: everything lives in `~`

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

## 7. Run the setup script

In an Ubuntu tab, from your home:

```sh
cd ~
curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/firstmate/main/bin/fm-linux-setup.sh | bash
```

It asks for your Ubuntu password once, then installs the build tools, Homebrew, git, node, gh, tmux, jq, Claude Code and Chrome, and clones Firstmate into `~/starship`.
It also installs [Herdr](https://herdr.dev), the terminal view your first mate and its workers run in, with Herdr's Claude Code integration, and sets your Starship to run in it.
It also makes sign-in links open in your normal Windows browser, rather than in the Linux Chrome it installs for the first mate's own checks.
About 15 minutes; a lot of text scrolls past, and it asks nothing more.

You should see a list of `ok` lines and `Setup finished.`
If the text stops without `Setup finished.`, run the same command again: it keeps what is already installed and finishes the rest.

First close the tab and open a new Ubuntu tab, so the new tools are on your PATH; in the old tab, `gh` and `claude` are not found.
Then, in the new tab, do the two sign-ins it prints:

```sh
gh auth login
claude
```

`gh auth login` asks four questions; the answers you want are already selected, so press Enter at each: **GitHub.com**, **HTTPS**, **Yes** to authenticate Git, then **Login with a web browser**.
It shows a one-time code; press Enter, and your Windows browser opens on GitHub, where you paste the code and authorize.

`claude` asks for a text style and a login method (**Claude account with subscription**), then opens your browser to sign in.
Back in Ubuntu, press Enter through its notes.
When it asks whether you trust your home folder, **No, exit** is selected; pressing Enter just closes Claude, and you stay signed in.

---

## 8. Open Herdr

Your first mate and its workers run inside Herdr, which the setup script installed.
In your Ubuntu tab, type:

```sh
herdr
```

The first time, Herdr may first ask how it should notify you; any answer works, and you can change it later in Herdr's settings (`Ctrl-b`, then `s`).
Herdr then shows a shell, with a sidebar on the left where each worker will appear.

---

## 9. Finish with the shared steps

Continue with [ONBOARDING.md step 3, get Starship and start your first mate](ONBOARDING.md#3-get-starship-and-start-your-first-mate) at **Start your first mate**, in Herdr's shell, and go on through the Harbour Logbook report in step 5.
Skip step 2 of that guide and the first part of step 3 (the `git clone` and `bin/fm-herdr-setup.sh` lines): the setup script did those.

When the first mate's startup checks run, it also tells you if anything sits under `/mnt/`, if Ubuntu has no network, or if `localhost` cannot reach Windows.

**Every day after this:** open Terminal (it opens Ubuntu) and type `herdr`.
If you left Herdr with `Ctrl-b`, then `q`, while an Ubuntu window stayed open, Herdr kept running and this brings back your first mate as you left it.
Closing the last Ubuntu window lets WSL shut Ubuntu down, which stops Herdr and your first mate; a Windows restart does the same.
After that, Herdr reopens your spaces; if your first mate's space shows only a shell, run `cd ~/starship && bin/fm-primary.sh opus` there again, and it starts fresh and picks up its work from its records.

**Prefer tmux?** Herdr is the default, and tmux still works: run `echo tmux > ~/starship/config/backend`, start the first mate inside `tmux new -s firstmate`, and workers open as tmux windows instead ([docs/tmux-backend.md](docs/tmux-backend.md)).

---

## 10. Talk to your first mate (optional)

The desk floater lets you hold a key and talk to your first mate, hear its replies, dictate into any Windows app, and send it screenshots.
Once your first mate runs, put your Deepgram key in `~/starship/.env` as a line `DEEPGRAM_API_KEY=...`, and for spoken replies put `enabled = true` in `~/starship/config/speak`.
Then, in Ubuntu:

```sh
cd ~/starship
bin/fm-desk-floater-windows.sh install
```

It needs no admin rights and nothing to download.
The floater appears at the bottom right of your screen and starts with Windows from now on.
Hold Right Alt and speak to talk to your first mate: your words go straight into its chat in Herdr, as screenshots do.
Tap Right Ctrl to dictate into whatever has your cursor; in the first mate's chat in Herdr, the dictated words wait there for you to press Enter.

Talking and dictation need a working microphone.
If the talk button shows an orange `!` and "Mic off - click !", Windows' privacy settings keep apps off the microphone: click it and turn on microphone access for desktop apps.
Without a microphone, screenshots still reach your first mate.
[docs/desk-floater-windows.md](docs/desk-floater-windows.md) has the rest.

---

## Working on an app from Windows

- **Web preview:** a dev server started in Ubuntu (for example `pnpm web`) opens in your Windows browser at the `localhost` address it prints.
- **Phone preview with Expo Go:** your phone cannot reach WSL's network directly.
  Start Expo with `npx expo start --tunnel` and scan the QR code.
- **iOS simulator:** needs a Mac.
  Use the web build, an Android emulator, or a cloud build instead.

## Not everyone needs the full setup

Starship is the full version.
Two lighter ways to use Claude work on Windows with no Linux at all:

- **The Claude desktop app:** download it from `claude.ai/download` with **Download for Windows**; it installs without admin rights.
- **Claude Code in the browser** at `claude.ai/code`, which runs in the cloud.

## Troubleshooting

| You see | Do this |
|---|---|
| No Ubuntu window and no user prompt after the restart | Run `wsl --install -d Ubuntu-24.04` again in Terminal (Admin) (step 3). |
| `Failed to configure network (networkingMode Mirrored)`, or nothing downloads in Ubuntu | Delete the `networkingMode=mirrored` line from `.wslconfig`, run `wsl --shutdown`, and open a new Ubuntu tab (step 4). |
| `fm-linux-setup.sh: ... is on the Windows drive` | Run `cd ~` and start the setup again. |
| `this is WSL 1` | In PowerShell: `wsl --set-version Ubuntu-24.04 2`, then run the setup again. |
| No `Setup finished.` at the end of the setup | Run the setup command again. |
| A board link or `localhost` page does not open in Windows | Check `.wslconfig` from step 4, run `wsl --shutdown`, open a new Ubuntu tab, and start again. |
| `command not found: brew`, `claude`, `gh`, or `herdr` after setup | Open a new Ubuntu tab; the old one has the old PATH. |
| A sign-in opens a Linux Chrome window instead of your normal browser | Open a new Ubuntu tab and sign in again; you can also just finish in that Chrome window. |
| Everything is slow | Check `pwd`: your project must be under `/home/...`, never `/mnt/c/...`. |

For anything else, use the troubleshooting table in [ONBOARDING.md](ONBOARDING.md#troubleshooting).

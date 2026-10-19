# Onboarding on a Linux server: a rented machine to a working first mate

Use this when your own computer cannot run a first mate well: a Windows PC that is work-managed, has less than 16 GB of RAM, or has no admin rights for [WSL 2](ONBOARDING-windows.md), or any computer when you want your crew to keep working while the laptop is closed.
You rent a small Ubuntu server, reach it over SSH, and run the same setup script a Windows PC runs inside WSL 2.
About an hour, then the shared steps of [ONBOARDING.md](ONBOARDING.md).

Your own computer only needs a terminal with `ssh` (built into macOS, Linux, and Windows 10 and 11) and a browser.

> The server holds your GitHub and Claude sign-ins and is always on the internet.
> Follow every step below, especially the SSH-key-only login and the firewall, and keep personal data you do not need off it.

---

## 1. Pick and size a server

Any provider with Ubuntu 24.04 on an **x86** (Intel or AMD) machine works; Chrome has no Linux package for Arm.
The example here is Hetzner Cloud (Germany and Finland, billed by the hour with a monthly cap).

| Use | Hetzner plan | Monthly price |
|---|---|---|
| **Recommended:** a first mate, a few workers, a dev server and Chrome | **CX43**: 8 vCPU, 16 GB RAM, 160 GB disk | EUR 15.99 + EUR 0.50 for the IPv4 address |
| Light use, one or two workers | CX33: 4 vCPU, 8 GB RAM, 80 GB disk | EUR 8.49 + EUR 0.50 for the IPv4 address |

Prices exclude VAT (about EUR 20 a month for a CX43 with Dutch VAT) and are the ones in force since 15 June 2026; check [Hetzner's price page](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/) before you buy.
Avoid the Arm `CAX` plans, because Chrome has no Arm Linux package.
If a plan shows as unavailable, try another location.

---

## 2. Make an SSH key and the server

On your own computer, in a terminal (PowerShell on Windows):

```sh
ssh-keygen -t ed25519
```

Press Enter at each question to accept the defaults, and set a passphrase if you like.
Print the public half:

```sh
cat ~/.ssh/id_ed25519.pub
```

In the [Hetzner Console](https://console.hetzner.com), create a project, then **Add Server**:

1. **Location:** Nuremberg, Falkenstein or Helsinki.
2. **Image:** Ubuntu 24.04.
3. **Type:** Shared vCPU, x86, CX43 (or CX33).
4. **SSH keys:** add a key and paste the `ssh-ed25519 ...` line you printed.
5. **Name:** for example `starship-<your-name>`, then **Create & Buy now**.

Note the server's IPv4 address from its overview page.

---

## 3. Make your own user and lock the door

Log in once as `root` (type `yes` when SSH asks about the server's fingerprint):

```sh
ssh root@<server-ip>
```

Make your own user with sudo rights and give it your SSH key (use a short lowercase name):

```sh
adduser <you>
usermod -aG sudo <you>
rsync --archive --chown=<you>:<you> ~/.ssh /home/<you>
```

Turn off password logins and root logins:

```sh
printf 'PasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-starship.conf
systemctl reload ssh
```

**Before you close this window,** open a second terminal on your computer and check that `ssh <you>@<server-ip>` works.
From now on, always log in as `<you>`.

Turn on the firewall, allowing only SSH:

```sh
sudo ufw allow OpenSSH
sudo ufw enable
```

Keep security updates automatic (Ubuntu's server image has this on; this confirms it):

```sh
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Answer **Yes**.

---

## 4. Join Tailscale (recommended)

Review boards and the app's dev server run on the server, so your browser needs a way to reach them.
**Tailscale is the recommended way:** a free private network between your own devices.
Review boards detect it and print links that open straight from your laptop or phone, and any dev server port is reachable without extra commands.

Install Tailscale on your own computer from [tailscale.com/download](https://tailscale.com/download) and sign in.
Then, on the server:

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Open the link it prints, sign in with the same account, and approve the server.
Let devices on your Tailscale network reach the server's ports:

```sh
sudo ufw allow in on tailscale0
```

Now `ssh <you>@starship-<your-name>` works from your computer too, through Tailscale.

The alternative is an **SSH port forward**, described in step 7.
It needs no extra account, but only reaches the ports you name, and only while that SSH connection is open.

---

## 5. Run the setup script

Logged in as `<you>`, from your home:

```sh
cd ~
curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/firstmate/main/bin/fm-linux-setup.sh | bash
```

It asks for your password once, then installs the build tools, Homebrew, git, node, gh, tmux, jq, Claude Code and Chrome, and clones Firstmate into `~/starship`.
Chrome runs headless here; no desktop is needed for the first mate's browser checks.

First log out (`exit`) and log back in with `ssh <you>@<server-ip>`, so the new tools are on your PATH; in the old login, `gh` and `claude` are not found.
Then do the two sign-ins it prints:

- `gh auth login`: answer its four questions with **GitHub.com**, **HTTPS**, **Yes** to authenticate Git, then **Login with a web browser**.
  It prints a code and a link; open the link on your own computer and type the code.
- `claude`: it prints a link; open it on your own computer, sign in, paste the code it shows back into the server, then type `/exit`.
  If it asks whether you trust your home folder, press Enter on **No, exit**, which just closes it; you stay signed in.

---

## 6. Run the first mate in tmux

On a server, the first mate and its workers run in tmux, which keeps them running after you disconnect and is what this guide is tested with.
(On a Mac or a Windows PC they run in Herdr instead.)
Tell Firstmate to use tmux, then start a session:

```sh
mkdir -p ~/starship/config
echo tmux > ~/starship/config/backend
tmux new -s firstmate
```

Continue with [ONBOARDING.md step 3, get Starship and start your first mate](ONBOARDING.md#3-get-starship-and-start-your-first-mate) at **Start your first mate**, inside this session, and go on through the Harbour Logbook report in step 5.
Skip step 2 of that guide and the first part of step 3 (the `git clone` and `bin/fm-herdr-setup.sh` lines, and opening Herdr): the setup script cloned Starship, and a server uses tmux.
Workers open as tmux windows; `Ctrl-b` then `w` lists them.

To leave everything running, press `Ctrl-b` then `d`.
Next time: `ssh <you>@<server>` and `tmux attach -t firstmate`.

---

## 7. Open boards and the app from your computer

**With Tailscale:** open the board links the first mate gives you as they are; they use the server's Tailscale name.
A dev server is at `http://starship-<your-name>:<port>`, for example port `8081` for Expo's web preview.
Expo Go on your phone works the same way with the Tailscale app on the phone, or with `npx expo start --tunnel`.

**With an SSH port forward:** connect with the ports you need forwarded, for example the review board server (`4387`) and Expo (`8081`):

```sh
ssh -L 4387:127.0.0.1:4387 -L 8081:127.0.0.1:8081 <you>@<server-ip>
```

While that connection is open, `http://localhost:4387/...` and `http://localhost:8081` on your computer reach the server.
Board links the first mate prints as `http://127.0.0.1:4387/...` work as they are.

Without Tailscale, the first mate's startup checks note once that boards and dev servers are reached this way.

---

## 8. Stop or delete the server

Hetzner bills while the server **exists**, even when it is powered off.

- **Pause for a while:** take a snapshot in the console (a small monthly fee), then delete the server; create a new one from the snapshot later.
- **Finish for good:** copy anything you want to keep, sign out with `gh auth logout` and `claude` then `/logout`, then in the Hetzner Console open the server and choose **Delete**.
  Remove the server from your Tailscale admin page too.

---

## Troubleshooting

| You see | Do this |
|---|---|
| `Permission denied (publickey)` | You are using the wrong user or key: `ssh <you>@<server-ip>`, with the key from step 2. |
| `run this as your own user, not root` | Log in as `<you>`, not `root`, and run the setup again. |
| A board link does not open | With Tailscale: check `tailscale status` on both machines. With a forward: reconnect with `-L` for that port. |
| The first mate stopped when you disconnected | It was not inside tmux. Reconnect, `tmux new -s firstmate`, and start it there. |
| `command not found: brew`, `claude`, or `gh` after setup | Log out and back in; the old login has the old PATH. |

For anything else, use the troubleshooting table in [ONBOARDING.md](ONBOARDING.md#troubleshooting).

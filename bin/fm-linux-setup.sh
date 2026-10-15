#!/usr/bin/env bash
# fm-linux-setup.sh - take a fresh Ubuntu 24.04 to the point where a first
# mate can start, whether it runs inside WSL 2 on a Windows PC
# (ONBOARDING-windows.md) or is a plain Linux server reached over SSH
# (ONBOARDING-linux-server.md).
#
# It installs only what must exist before the first mate starts; the first
# mate's own bootstrap (bin/fm-bootstrap.sh) installs the rest after the
# person's consent, exactly as on a Mac (ONBOARDING.md step 4):
#   - apt: build-essential procps curl file git ca-certificates (Homebrew's
#     Linux prerequisites)
#   - Homebrew on Linux, so the bootstrap's `brew install` and `npm install -g`
#     hints work unchanged and need no sudo later
#   - brew: git node gh tmux
#   - Claude Code through its Linux native installer (~/.local/bin/claude)
#   - Google Chrome stable on x86_64. It needs no desktop: chrome-devtools-axi
#     drives it headless by default, so the same package serves WSL and a
#     server. Google publishes no arm64 Linux package, so arm64 skips it with
#     a warning and browser checks stay unavailable there.
#   - a Firstmate clone at ~/starship (an existing clone is left untouched)
#   - one `brew shellenv` line and one ~/.local/bin PATH line in ~/.profile and
#     ~/.bashrc, so login shells, tmux panes, and new terminals find the tools
#
# It refuses, before changing anything, when: the host is not Linux; it runs
# as root (Homebrew refuses root; make your own user first); the current
# directory, $HOME, or ~/starship is on a Windows drive under /mnt/<letter>/
# (WSL's cross-filesystem bridge breaks git, file watching, and permissions);
# the kernel is WSL 1 (Claude Code needs WSL 2); apt-get is absent; or
# ~/starship exists but is not a Firstmate clone.
#
# Re-running is safe: present tools are kept, the clone is left as it is, and
# the profile lines are written once.
#
# Usage:
#   fm-linux-setup.sh [--ci]
#   curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/firstmate/main/bin/fm-linux-setup.sh | bash
#   --ci    skip the closing sign-in instructions (gh auth login, claude);
#           .github/workflows/windows-wsl.yml runs it this way with no person
#           at the keyboard.
# Exit: 0 when every tool answers --version; 1 on a refusal or failed step,
# with the reason on stderr; 2 on a usage error.
set -eu

REPO_URL=https://github.com/Amplify-Logic/firstmate
BREW_INSTALLER=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
CLAUDE_INSTALLER=https://claude.ai/install.sh
CHROME_DEB=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
APT_PACKAGES="build-essential procps curl file git ca-certificates"
BREW_PACKAGES="git node gh tmux"

usage() {
  cat <<'EOF'
usage: fm-linux-setup.sh [--ci]
  Takes a fresh Ubuntu 24.04 (inside WSL 2, or a server over SSH) to the point
  where a first mate can start, cloning Firstmate into ~/starship.
  Run it as your own user from your Linux home, never under /mnt/.
  --ci    skip the closing sign-in instructions (gh auth login, claude)
EOF
}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'fm-linux-setup.sh: %s\n' "$*" >&2; exit 1; }

CI_MODE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ci) CI_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-linux-setup.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"
TARGET="$HOME/starship"

# --- refusals: nothing has changed yet ---------------------------------------

[ "$(uname -s)" = Linux ] || die "this sets up Linux (WSL 2 or a server); on a Mac follow ONBOARDING.md"
[ "$(id -u)" != 0 ] || die "run this as your own user, not root: make one with 'adduser <name>' and 'usermod -aG sudo <name>', log in as it, then run this again (ONBOARDING-linux-server.md)"

on_windows_drive() {  # <path>
  case "$1/" in
    /mnt/[A-Za-z]/*) return 0 ;;
  esac
  return 1
}
for path in "$(pwd -P 2>/dev/null || pwd)" "$HOME" "$TARGET"; do
  on_windows_drive "$path" \
    && die "$path is on the Windows drive; run this from your Linux home (cd ~), never under /mnt/ - git, file watching and file permissions break there"
done

if [ -r /proc/version ]; then
  case "$(cat /proc/version)" in
    *microsoft-standard*|*WSL2*) ;;
    *Microsoft*) die "this is WSL 1; Claude Code needs WSL 2: in Windows PowerShell run 'wsl --set-version Ubuntu-24.04 2', then run this again" ;;
  esac
fi

command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script supports Ubuntu (24.04 is the tested release)"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  os_line=$(. /etc/os-release && printf '%s %s' "${ID:-}" "${VERSION_ID:-}")
  [ "$os_line" = "ubuntu 24.04" ] || warn "tested on Ubuntu 24.04; this is '$os_line' - continuing"
fi

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  if [ -f "$TARGET/bin/fm-primary.sh" ] && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    CLONE_PRESENT=1
  else
    die "$TARGET exists but is not a Firstmate clone; move it aside, then run this again"
  fi
else
  CLONE_PRESENT=0
fi

# --- installs ---------------------------------------------------------------

say "Asking for your password once, for the system packages"
sudo true || die "sudo is needed for the system packages"

say "System packages: $APT_PACKAGES"
sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q || die "apt-get update failed"
# shellcheck disable=SC2086  # deliberate word-split of the package list
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $APT_PACKAGES \
  || die "apt-get install failed"

BREW_PREFIX=${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}
BREW="$BREW_PREFIX/bin/brew"
if [ ! -x "$BREW" ]; then
  say "Homebrew on Linux"
  installer=$(curl -fsSL "$BREW_INSTALLER") || die "could not download the Homebrew installer"
  NONINTERACTIVE=1 /bin/bash -c "$installer" || die "the Homebrew installer failed"
  [ -x "$BREW" ] || die "Homebrew installed, but $BREW is missing"
else
  say "Homebrew already present at $BREW_PREFIX"
fi
eval "$("$BREW" shellenv)"

say "Homebrew packages: $BREW_PACKAGES"
# shellcheck disable=SC2086  # deliberate word-split of the package list
brew install $BREW_PACKAGES || die "brew install failed"

LOCAL_BIN="$HOME/.local/bin"
PATH="$LOCAL_BIN:$PATH"
export PATH
if [ -x "$LOCAL_BIN/claude" ]; then
  say "Claude Code already present"
else
  say "Claude Code (native installer)"
  installer=$(curl -fsSL "$CLAUDE_INSTALLER") || die "could not download the Claude Code installer"
  printf '%s\n' "$installer" | bash || die "the Claude Code installer failed"
fi

CHROME_WANTED=1
if command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
  say "Google Chrome already present"
else
  case "$(uname -m)" in
    x86_64|amd64)
      say "Google Chrome (runs headless; no desktop needed)"
      deb_dir=$(mktemp -d)
      curl -fsSL -o "$deb_dir/google-chrome-stable_current_amd64.deb" "$CHROME_DEB" \
        || die "could not download Google Chrome"
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        "$deb_dir/google-chrome-stable_current_amd64.deb" || die "installing Google Chrome failed"
      rm -rf "$deb_dir"
      ;;
    *)
      CHROME_WANTED=0
      warn "Google publishes no Chrome package for $(uname -m) Linux; skipped, so browser checks are unavailable here (an x86_64 machine has them)"
      ;;
  esac
fi

if [ "$CLONE_PRESENT" = 1 ]; then
  say "Firstmate already cloned at $TARGET; left as it is"
else
  say "Cloning Firstmate into $TARGET"
  git clone "$REPO_URL" "$TARGET" || die "git clone failed"
fi

ensure_line() {  # <file> <line>
  [ -f "$1" ] && grep -qxF "$2" "$1" && return 0
  printf '\n# Added by Firstmate bin/fm-linux-setup.sh\n%s\n' "$2" >> "$1"
}
# shellcheck disable=SC2016  # these lines are written for the shell to expand later
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  ensure_line "$rc" "eval \"\$($BREW shellenv)\""
  ensure_line "$rc" 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
done

# --- verification -------------------------------------------------------------

say "Checking every tool"
missing=0
check() {  # <label> <command...>
  local label=$1 version
  shift
  if version=$("$@" 2>/dev/null | head -n 1) && [ -n "$version" ]; then
    printf '  ok  %-14s %s\n' "$label" "$version"
  else
    printf '  --  %-14s missing\n' "$label"
    missing=1
  fi
}
check git git --version
check node node --version
check npm npm --version
check gh gh --version
check tmux tmux -V
check claude claude --version
if [ "$CHROME_WANTED" = 1 ]; then
  if command -v google-chrome >/dev/null 2>&1; then
    check chrome google-chrome --version
  else
    check chrome google-chrome-stable --version
  fi
fi
if [ -f "$TARGET/bin/fm-primary.sh" ] && [ -f "$TARGET/AGENTS.md" ]; then
  printf '  ok  %-14s %s\n' firstmate "$TARGET"
else
  printf '  --  %-14s missing at %s\n' firstmate "$TARGET"
  missing=1
fi
[ "$missing" = 0 ] || die "a tool above is missing; fix the step that failed, then run this again"

# --- what the person does next ---------------------------------------------

printf '\nSetup finished.\n'
if [ "$CI_MODE" = 1 ]; then
  printf 'Sign-ins skipped (--ci).\n'
  exit 0
fi
cat <<'EOF'

First open a NEW terminal, so the new tools are on your PATH: on Windows, a
new Ubuntu tab; on a server, log out and log back in. This one still has the
old PATH, so gh and claude are not found here.

Then, in the new terminal, two sign-ins are yours to do:

  1. gh auth login
     Choose GitHub.com, then HTTPS, then "Login with a web browser".
     On a server, open the link it prints on your own computer and type the code.

  2. claude
     Sign in, then type /exit.
     On a server, open the link it prints on your own computer and paste the code back.

Then go back to the guide you are following: step 7 of ONBOARDING-windows.md
on Windows, or step 6 of ONBOARDING-linux-server.md on a server. It starts the
first mate inside tmux and then hands over to step 3 of ONBOARDING.md.
Starship is already cloned in ~/starship.
EOF

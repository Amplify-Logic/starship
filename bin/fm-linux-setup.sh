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
#     Linux prerequisites), plus wslu inside WSL, whose wslview opens a link in
#     the Windows default browser
#   - Homebrew on Linux, so the bootstrap's `brew install` and `npm install -g`
#     hints work unchanged and need no sudo later
#   - brew: git node gh tmux jq (tmux is a server's runtime and the
#     fallback elsewhere)
#   - Claude Code through its Linux native installer (~/.local/bin/claude)
#   - Google Chrome stable on x86_64. It needs no desktop: chrome-devtools-axi
#     drives it headless by default, so the same package serves WSL and a
#     server. Google publishes no arm64 Linux package, so arm64 skips it with
#     a warning and browser checks stay unavailable there.
#   - a Firstmate clone at ~/starship (an existing clone is left untouched)
#   - inside WSL, Herdr with its Claude Code integration and, for a fresh
#     home, config/backend set to herdr, so the first mate starts in Herdr
#     from its first launch, as on a Mac (bin/fm-herdr-setup.sh owns all
#     three; a server keeps tmux, ONBOARDING-linux-server.md step 6)
#   - lines in ~/.profile and ~/.bashrc, so login shells, tmux panes, and new
#     terminals pick these up: one `brew shellenv` line, one ~/.local/bin PATH
#     line, `export HOMEBREW_NO_ASK=1` (Homebrew otherwise stops every install
#     at a y/n question), and inside WSL `export BROWSER=wslview`, so gh,
#     claude, and other sign-ins open in Windows rather than in the Linux
#     Chrome installed above
#
# Inside WSL means WSL_DISTRO_NAME is set, which WSL exports into every process
# it starts (bin/fm-bootstrap.sh HOST_ENV uses the same signal).
#
# The guides run it as `curl ... | bash`, where bash reads the script itself
# from standard input. So everything runs from main on the last line, after
# bash has read the whole script, and every installer gets </dev/null so none
# can wait on a question or read the script.
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
#   cat fm-linux-setup.sh | bash -s -- --ci
#   --ci    skip the closing sign-in instructions (gh auth login, claude);
#           .github/workflows/windows-wsl.yml runs it this way, through a
#           pipe as the guides do, with no person at the keyboard.
# Exit: 0 when every tool answers --version; 1 on a refusal or failed step,
# with the reason on stderr; 2 on a usage error.
set -eu

REPO_URL=https://github.com/Amplify-Logic/firstmate
BREW_INSTALLER=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
CLAUDE_INSTALLER=https://claude.ai/install.sh
CHROME_DEB=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
APT_PACKAGES="build-essential procps curl file git ca-certificates"
BREW_PACKAGES="git node gh tmux jq"

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

on_windows_drive() {  # <path>
  case "$1/" in
    /mnt/[A-Za-z]/*) return 0 ;;
  esac
  return 1
}

ensure_line() {  # <file> <line>
  [ -f "$1" ] && grep -qxF "$2" "$1" && return 0
  printf '\n# Added by Firstmate bin/fm-linux-setup.sh\n%s\n' "$2" >> "$1"
}

check() {  # <label> <command...>: sets missing=1 when the tool does not answer
  local label=$1 version
  shift
  if version=$("$@" 2>/dev/null | head -n 1) && [ -n "$version" ]; then
    printf '  ok  %-14s %s\n' "$label" "$version"
  else
    printf '  --  %-14s missing\n' "$label"
    missing=1
  fi
}

main() {
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

  ON_WSL=0
  apt_packages=$APT_PACKAGES
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    ON_WSL=1
    apt_packages="$apt_packages wslu"
  fi

  # --- installs ---------------------------------------------------------------

  say "Asking for your password once, for the system packages"
  sudo true || die "sudo is needed for the system packages"

  say "System packages: $apt_packages"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q </dev/null || die "apt-get update failed"
  # shellcheck disable=SC2086  # deliberate word-split of the package list
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $apt_packages </dev/null \
    || die "apt-get install failed"

  BREW_PREFIX=${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}
  BREW="$BREW_PREFIX/bin/brew"
  if [ ! -x "$BREW" ]; then
    say "Homebrew on Linux"
    installer=$(curl -fsSL "$BREW_INSTALLER") || die "could not download the Homebrew installer"
    NONINTERACTIVE=1 /bin/bash -c "$installer" </dev/null || die "the Homebrew installer failed"
    [ -x "$BREW" ] || die "Homebrew installed, but $BREW is missing"
  else
    say "Homebrew already present at $BREW_PREFIX"
  fi
  eval "$("$BREW" shellenv)"
  HOMEBREW_NO_ASK=1
  export HOMEBREW_NO_ASK

  say "Homebrew packages: $BREW_PACKAGES"
  # shellcheck disable=SC2086  # deliberate word-split of the package list
  brew install $BREW_PACKAGES </dev/null || die "brew install failed"

  LOCAL_BIN="$HOME/.local/bin"
  PATH="$LOCAL_BIN:$PATH"
  export PATH
  if [ -x "$LOCAL_BIN/claude" ]; then
    say "Claude Code already present"
  else
    say "Claude Code (native installer)"
    installer=$(curl -fsSL "$CLAUDE_INSTALLER") || die "could not download the Claude Code installer"
    bash -c "$installer" </dev/null || die "the Claude Code installer failed"
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
          "$deb_dir/google-chrome-stable_current_amd64.deb" </dev/null || die "installing Google Chrome failed"
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
    git clone "$REPO_URL" "$TARGET" </dev/null || die "git clone failed"
  fi

  HERDR_WANTED=0
  if [ "$ON_WSL" = 1 ]; then
    if [ -x "$TARGET/bin/fm-herdr-setup.sh" ]; then
      HERDR_WANTED=1
      FM_HOME="$TARGET" "$TARGET/bin/fm-herdr-setup.sh" --quiet </dev/null || die "setting up Herdr failed"
    else
      warn "this Starship copy predates the Herdr setup; update it with 'git -C $TARGET pull', then run $TARGET/bin/fm-herdr-setup.sh"
    fi
  fi

  # shellcheck disable=SC2016  # these lines are written for the shell to expand later
  for rc in "$HOME/.profile" "$HOME/.bashrc"; do
    ensure_line "$rc" "eval \"\$($BREW shellenv)\""
    ensure_line "$rc" 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    ensure_line "$rc" 'export HOMEBREW_NO_ASK=1'
    [ "$ON_WSL" = 0 ] || ensure_line "$rc" 'export BROWSER=wslview'
  done

  # --- verification -------------------------------------------------------------

  say "Checking every tool"
  missing=0
  check git git --version
  check node node --version
  check npm npm --version
  check gh gh --version
  check tmux tmux -V
  check jq jq --version
  check claude claude --version
  [ "$ON_WSL" = 0 ] || check wslview wslview --version
  [ "$HERDR_WANTED" = 0 ] || check herdr herdr --version
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
     Press Enter at each of its four questions: GitHub.com, HTTPS, Yes, and
     "Login with a web browser". Then press Enter again to open the browser.
     On a server, open the link it prints on your own computer and type the code.

  2. claude
     Sign in. When it then asks whether you trust your home folder, Enter on
     "No, exit" just closes it; you stay signed in.
     On a server, open the link it prints on your own computer and paste the code back.

Then go back to the guide you are following:
  - on Windows, step 8 of ONBOARDING-windows.md, which starts the first mate
    inside Herdr;
  - on a server, step 6 of ONBOARDING-linux-server.md, which starts it inside
    tmux.
Each then hands over to step 3 of ONBOARDING.md. Starship is already cloned
in ~/starship.
EOF
}

# Last line on purpose: nothing runs until bash has read the whole script.
main "$@"

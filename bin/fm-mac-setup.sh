#!/usr/bin/env bash
# fm-mac-setup.sh - take a Mac to the point where a first mate can start, in
# one plain Terminal window, before Herdr or the first mate ever opens
# (ONBOARDING.md step 2).
#
# It runs in this order, and each step is kept when already done:
#   1. Prerequisites, before anything else: Homebrew (installed when absent,
#      which needs a Mac administrator and asks for the Mac password once),
#      then from Homebrew whichever of git node gh tmux jq is absent or does
#      not run (a working one is left as it is; a Node older than the npm
#      tools accept counts as not working). Node must answer with a recent
#      enough version afterwards, so a broken or old Node is caught here
#      rather than by the first npm install.
#   2. Claude Code, from npm.
#   3. A Starship clone at ~/starship (an existing clone is left as it is).
#   4. Herdr, its Claude Code integration, Herdr as a fresh home's runtime,
#      and the `starship` and `onboard-starship` commands: the clone's own
#      bin/fm-herdr-setup.sh owns all four.
#   5. Every other tool the first mate needs (treehouse, no-mistakes and the
#      npm tools): the clone's own `bin/fm-bootstrap.sh install-missing`,
#      which owns the list. Running this script is the consent for those
#      installs, so the first mate never installs them inside its session.
#   6. Lines in ~/.zprofile, so new Terminal windows find Homebrew and ask no
#      y/n question on a later `brew install`.
# It then checks every tool, prints the first-hour checklist
# (bin/fm-first-hour.sh), and spells out the two sign-ins and how to start.
#
# Every command a person types is free of quotes, so it survives being sent
# through a chat app that curls straight quotes:
#   curl -fsSL https://raw.githubusercontent.com/Amplify-Logic/starship/main/bin/fm-mac-setup.sh | bash
# Under that pipe bash reads the script itself from standard input, so
# everything runs from main on the last line, after bash has read the whole
# script, and every installer gets </dev/null so none can read the script or
# stop at a question. sudo asks for the password on the terminal itself.
#
# It refuses, before changing anything, when: the host is not macOS; it runs
# as root; ~/starship exists but is not a Starship clone, or is a clone too old
# to have `fm-bootstrap.sh install-missing`; or Homebrew is absent and this
# Mac user is not an administrator.
#
# Usage:
#   fm-mac-setup.sh [--ci]
#   --ci   skip the closing sign-in instructions, for a run with no person
# Environment: HOMEBREW_PREFIX names where Homebrew lives or goes (default:
#   the brew already on PATH, else /opt/homebrew on Apple silicon and
#   /usr/local on Intel).
# Exit: 0 when every tool answers; 1 on a refusal or failed step, with the
# reason on stderr; 2 on a usage error.
set -eu

REPO_URL=https://github.com/Amplify-Logic/starship
BREW_INSTALLER=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
BREW_PACKAGES="git node gh tmux jq"

usage() {
  cat <<'EOF'
usage: fm-mac-setup.sh [--ci]
  Takes a Mac to the point where a first mate can start: Homebrew, Node and
  jq first, then Claude Code, Starship in ~/starship, Herdr and every tool
  the first mate needs, all in this Terminal window.
  --ci   skip the closing sign-in instructions
EOF
}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'fm-mac-setup.sh: %s\n' "$*" >&2; exit 1; }

ensure_line() {  # <file> <line>
  [ -f "$1" ] && grep -qxF "$2" "$1" && return 0
  printf '\n# Added by Starship bin/fm-mac-setup.sh\n%s\n' "$2" >> "$1"
}

check() {  # <label> <command...>: sets missing=1 when the tool does not answer
  local label=$1 version
  shift
  version=$("$@" 2>/dev/null </dev/null | head -n 1) || version=
  case "$version" in
    *[0-9]*) printf '  ok  %-14s %s\n' "$label" "$version" ;;
    '') printf '  --  %-14s missing\n' "$label"; missing=1 ;;
    *) printf '  --  %-14s not working: %s\n' "$label" "$version"; missing=1 ;;
  esac
}

# The oldest Node the first mate's npm tools accept: the highest engines floor
# among them (quota-axi asks for >=22.19). On an older Node, npm quietly
# installs an old release that fits it instead, below the floor
# bin/fm-bootstrap.sh checks, so the tool install could never succeed.
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=19

node_recent_enough() {  # true when node runs and is at least NODE_MIN
  local v major rest minor
  v=$(node --version 2>/dev/null </dev/null) || return 1
  v=${v#v}
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%.*}
  case "$major:$minor" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$major" -gt "$NODE_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NODE_MIN_MAJOR" ] && [ "$minor" -ge "$NODE_MIN_MINOR" ]
}

works() {  # <command...>: true when it runs and succeeds
  "$@" >/dev/null 2>&1 </dev/null
}

is_admin() {
  case " $(groups 2>/dev/null) " in *' admin '*) return 0 ;; esac
  return 1
}

main() {
  CI_MODE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ci) CI_MODE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'fm-mac-setup.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  [ -n "${HOME:-}" ] || die "HOME is not set"
  TARGET="$HOME/starship"

  # --- refusals: nothing has changed yet ---------------------------------------

  [ "$(uname -s)" = Darwin ] || die "this sets up a Mac; on Windows or Linux follow ONBOARDING-windows.md or ONBOARDING-linux-server.md"
  [ "$(id -u)" != 0 ] || die "run this as your own Mac user, not root"

  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    if [ -f "$TARGET/bin/fm-primary.sh" ] && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
      CLONE_PRESENT=1
      grep -qF 'fm-bootstrap.sh install-missing' "$TARGET/bin/fm-bootstrap.sh" 2>/dev/null \
        || die "$TARGET is an older Starship copy that cannot install the tools the first mate needs; update it by running: git -C $TARGET pull, then run this again"
    else
      die "$TARGET exists but is not a Starship clone; move it aside, then run this again"
    fi
  else
    CLONE_PRESENT=0
  fi

  if [ -z "${HOMEBREW_PREFIX:-}" ] && command -v brew >/dev/null 2>&1; then
    HOMEBREW_PREFIX=$(brew --prefix 2>/dev/null </dev/null) || HOMEBREW_PREFIX=
  fi
  if [ -z "${HOMEBREW_PREFIX:-}" ]; then
    case "$(uname -m)" in
      arm64) HOMEBREW_PREFIX=/opt/homebrew ;;
      *) HOMEBREW_PREFIX=/usr/local ;;
    esac
  fi
  BREW="$HOMEBREW_PREFIX/bin/brew"
  if [ ! -x "$BREW" ] && ! is_admin; then
    die "Homebrew needs a Mac administrator: System Settings, then Users & Groups, shows Admin under your name when you are one. Ask whoever manages this Mac to make you an admin, then run this again"
  fi

  # --- 1. prerequisites: Homebrew, then Node, jq and the rest ------------------

  if [ -x "$BREW" ]; then
    say "Homebrew already present at $HOMEBREW_PREFIX"
  else
    say "Homebrew needs your Mac password once (nothing shows while you type it)"
    sudo -v || die "the Mac password was not accepted; run this again"
    # Homebrew's unattended install uses sudo without asking, so keep the
    # password fresh while it runs; this loop ends with the script.
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) >/dev/null 2>&1 </dev/null &
    say "Homebrew (this can take several minutes, mostly Apple's command line tools)"
    installer=$(curl -fsSL "$BREW_INSTALLER") || die "could not download the Homebrew installer; check the internet connection, then run this again"
    NONINTERACTIVE=1 /bin/bash -c "$installer" </dev/null || die "the Homebrew installer failed; run this again"
    [ -x "$BREW" ] || die "Homebrew installed, but $BREW is missing"
  fi
  eval "$("$BREW" shellenv)"
  HOMEBREW_NO_ASK=1
  export HOMEBREW_NO_ASK

  # Only what is absent or does not run is installed, so a Mac that already
  # has a working Node or git keeps its own versions untouched.
  wanted=
  for pkg in $BREW_PACKAGES; do
    case "$pkg" in
      node) node_recent_enough && works npm --version && continue ;;
      tmux) works tmux -V && continue ;;
      *) works "$pkg" --version && continue ;;
    esac
    wanted="${wanted:+$wanted }$pkg"
  done
  if [ -n "$wanted" ]; then
    say "Homebrew packages: $wanted"
    # shellcheck disable=SC2086  # deliberate word-split of the package list
    brew install $wanted </dev/null || die "brew install failed; run this again"
  else
    say "git, Node, gh, tmux and jq already present"
  fi
  if ! node --version >/dev/null 2>&1 </dev/null || ! npm --version >/dev/null 2>&1 </dev/null; then
    die "Node is installed but does not run; run: brew reinstall node, then run this again"
  fi
  node_recent_enough || die "Node $(node --version) is older than $NODE_MIN_MAJOR.$NODE_MIN_MINOR, which the first mate's tools need; run: brew upgrade node, then run this again"

  # --- 2. Claude Code ------------------------------------------------------------

  if command -v claude >/dev/null 2>&1; then
    say "Claude Code already present"
  else
    say "Claude Code"
    npm install -g @anthropic-ai/claude-code </dev/null || die "installing Claude Code failed; run this again"
  fi

  # --- 3. Starship -----------------------------------------------------------------

  if [ "$CLONE_PRESENT" = 1 ]; then
    say "Starship already cloned at $TARGET; left as it is"
  else
    say "Cloning Starship into $TARGET"
    git clone "$REPO_URL" "$TARGET" </dev/null || die "git clone failed"
  fi

  # --- 4. Herdr, and 5. the first mate's tools -----------------------------------

  FM_HOME="$TARGET" "$TARGET/bin/fm-herdr-setup.sh" --quiet </dev/null || die "setting up Herdr failed; run this again"
  LOCAL_BIN="$HOME/.local/bin"
  PATH="$LOCAL_BIN:$PATH"
  export PATH
  say "The first mate's tools"
  FM_HOME="$TARGET" "$TARGET/bin/fm-bootstrap.sh" install-missing </dev/null \
    || die "a tool above did not install; run this again in a few minutes"

  # --- 6. new Terminal windows -----------------------------------------------------

  ensure_line "$HOME/.zprofile" "eval \"\$($BREW shellenv)\""
  ensure_line "$HOME/.zprofile" 'export HOMEBREW_NO_ASK=1'

  # --- verification ------------------------------------------------------------------

  say "Checking every tool"
  missing=0
  check git git --version
  check node node --version
  check npm npm --version
  check gh gh --version
  check jq jq --version
  check python3 python3 --version
  check claude claude --version
  check herdr herdr --version
  if FM_HOME="$TARGET" "$TARGET/bin/fm-bootstrap.sh" install-missing --check </dev/null; then
    printf '  ok  %-14s %s\n' tools "everything the first mate needs"
  else
    printf '  --  %-14s %s\n' tools "not all installed (listed above)"
    missing=1
  fi
  [ "$missing" = 0 ] || die "a tool above is missing; run this again, and if it fails the same way, ask for help with the line above"
  [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ] \
    || warn "Google Chrome is not installed; the first mate uses it to check web pages, so install it from google.com/chrome when you can"

  # --- what the person does next -------------------------------------------------------

  printf '\nSetup finished.\n\n'
  FM_HOME="$TARGET" "$TARGET/bin/fm-first-hour.sh" </dev/null || true
  if [ "$CI_MODE" = 1 ]; then
    printf '\nSign-ins skipped (--ci).\n'
    exit 0
  fi
  cat <<'EOF'

Now open a NEW Terminal window (Command-N), so the new tools are found; this
one still has the old settings. In the new window:

  1. gh auth login
     Press Enter at each of its four questions: GitHub.com, Login with a web
     browser, HTTPS, and Yes. Then press Enter again to open the browser.

  2. claude
     Sign in in the browser it opens. When it then asks whether you trust
     your home folder, press Enter on No, exit: that just closes it, and you
     stay signed in.

  3. onboard-starship
     Opens everything at once: your first mate in Herdr with the bridge
     strip and the Factory pane, your Starship web page, and a Terminal
     window in front. Answer the two questions Claude Code asks there
     the first time (ONBOARDING.md step 3), then say hello; it takes it
     from there.

To keep the checklist above open while you work, ticking itself off, open
one more Terminal window and run:

  ~/starship/bin/fm-first-hour.sh --watch
EOF
}

# Last line on purpose: nothing runs until bash has read the whole script.
main "$@"

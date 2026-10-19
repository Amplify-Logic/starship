#!/usr/bin/env bash
# fm-herdr-setup.sh - make a fresh Starship home start in Herdr from its first
# launch, on a Mac (ONBOARDING.md step 3) or inside WSL 2 on Windows, where
# bin/fm-linux-setup.sh runs it.
#
# It does three things, each kept when already done:
#   - Herdr: a herdr that passes the adapter's own version gate
#     (bin/backends/herdr.sh fm_backend_herdr_version_check) is kept; otherwise
#     bin/fm-install-herdr.sh installs its pinned, checksum-verified release
#     into ~/.local/bin. Whenever the herdr in use lives in ~/.local/bin, one
#     line in the shell profile (~/.zprofile on a Mac; ~/.profile and ~/.bashrc
#     on Linux) puts ~/.local/bin on PATH for new terminals.
#   - Herdr's Claude Code integration (`herdr integration install claude`),
#     which lets Herdr show each Claude's working, idle and blocked state.
#     Herdr needs ~/.claude to exist, so the folder is made first when Claude
#     Code has not run yet; installing again updates an outdated integration.
#   - The home's runtime: config/backend is written as `herdr` only for a
#     fresh home, one with no config/backend and no state/ records yet. A home
#     that names a runtime keeps it, and a home that already ran without one
#     (tmux, the built-in default) is left as it is, so a configured home is
#     never switched. docs/configuration.md "Runtime backend" owns the
#     selection order.
#
# It never signs in to anything and never starts Herdr or the first mate; it
# ends by printing how to start the first mate inside Herdr.
#
# Usage:
#   fm-herdr-setup.sh [--quiet]
#   --quiet   skip the closing start instructions (bin/fm-linux-setup.sh
#             prints its own)
# Environment: FM_HOME selects the home (default: this code root).
# Exit: 0 when Herdr and its Claude integration are in place; 1 on a failed
# step, with the reason on stderr; 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
INSTALL_HERDR="${FM_HERDR_SETUP_INSTALLER:-$SCRIPT_DIR/fm-install-herdr.sh}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'fm-herdr-setup.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

ensure_line() {  # <file> <line>
  [ -f "$1" ] && grep -qxF "$2" "$1" && return 0
  printf '\n# Added by Firstmate bin/fm-herdr-setup.sh\n%s\n' "$2" >> "$1"
}

herdr_usable() {
  ( fm_backend_herdr_version_check ) >/dev/null 2>&1
}

QUIET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-herdr-setup.sh: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"
command -v jq >/dev/null 2>&1 || die "jq is needed first (Mac: brew install jq)"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || die "could not load the Herdr adapter"

# --- Herdr --------------------------------------------------------------------

LOCAL_BIN="$HOME/.local/bin"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) PATH="$LOCAL_BIN:$PATH"; export PATH ;;
esac

if herdr_usable; then
  say "Herdr $(herdr --version 2>/dev/null | awk '{print $2; exit}') already present"
else
  say "Herdr (pinned release, into $LOCAL_BIN)"
  "$INSTALL_HERDR" "$LOCAL_BIN" >/dev/null || die "installing Herdr failed"
  herdr_usable || die "Herdr was installed to $LOCAL_BIN, but the herdr found on PATH is $(command -v herdr || echo none) and does not pass the version check; remove the older one, then run this again"
fi

if [ "$(command -v herdr)" = "$LOCAL_BIN/herdr" ]; then
  # shellcheck disable=SC2016  # written for the shell to expand later
  path_line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
  if [ "$(uname -s)" = Darwin ]; then
    ensure_line "$HOME/.zprofile" "$path_line"
  else
    ensure_line "$HOME/.profile" "$path_line"
    ensure_line "$HOME/.bashrc" "$path_line"
  fi
fi

# --- Herdr's Claude Code integration -----------------------------------------

if herdr integration status 2>/dev/null | grep -Eq '^claude: current( |$)'; then
  say "Herdr's Claude Code integration already current"
else
  say "Herdr's Claude Code integration"
  mkdir -p "$HOME/.claude" || die "could not create $HOME/.claude"
  herdr integration install claude >/dev/null || die "herdr integration install claude failed"
fi

# --- this home's runtime ------------------------------------------------------

CONFIG="$FM_HOME/config"
BACKEND_FILE="$CONFIG/backend"
current=
if [ -f "$BACKEND_FILE" ]; then
  current=$(awk 'NF { gsub(/[[:space:]]/, ""); print; exit }' "$BACKEND_FILE")
fi
if [ -n "$current" ]; then
  say "This home already runs on $current; left as it is"
elif [ -d "$FM_HOME/state" ] && [ -n "$(ls -A "$FM_HOME/state" 2>/dev/null)" ]; then
  say "This home already ran without a chosen runtime (tmux by default); left as it is."
  printf '    To move it to Herdr: echo herdr > %s\n' "$BACKEND_FILE"
else
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  printf 'herdr\n' > "$BACKEND_FILE" || die "could not write $BACKEND_FILE"
  say "This home runs its first mate and workers in Herdr ($BACKEND_FILE)"
fi

[ "$QUIET" = 0 ] || exit 0
cat <<EOF

Herdr is ready. Open a NEW terminal window (so herdr is on your PATH), then:

  herdr
      Opens Herdr. In the shell it shows, start your first mate:

  cd $FM_HOME && bin/fm-primary.sh opus

Each worker then appears in Herdr's sidebar as its own space while it works.
EOF

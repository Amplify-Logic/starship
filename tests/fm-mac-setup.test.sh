#!/usr/bin/env bash
# Behavior tests for bin/fm-mac-setup.sh, the one-command Mac setup that puts
# Homebrew, Node and jq in place before anything else and finishes every tool
# install in a plain terminal, before Herdr or the first mate opens.
#
# Every external effect is a PATH stub that records its call, under a narrow
# PATH pin, so no case installs anything on the host. The stubbed installers
# create the binaries a real install would, so the script's own closing check
# passes or fails on what it actually installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-mac-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-mac-setup)

# make_world <name>: a fresh HOME, Homebrew prefix, and stub toolchain.
# Echoes the case directory; the stubs append one line per call to calls.log.
make_world() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home" "$dir/sysbin"
  fakebin=$(fm_fakebin "$dir")
  : > "$dir/calls.log"
  fm_fake_real_tool "$fakebin" bash sh env cat grep sed head mkdir mktemp \
    chmod rm cp touch tr dirname awk sleep || fail "a basic tool is missing on this host"
  fm_fake_exit0 "$fakebin" true

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${FAKE_UNAME_M:-arm64}" ;;
  *) printf '%s\n' "${FAKE_UNAME_S:-Darwin}" ;;
esac
SH
  cat > "$fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-501}"
SH
  cat > "$fakebin/groups" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_ADMIN:-1}" = 1 ]; then echo "staff everyone admin"; else echo "staff everyone"; fi
SH
  cat > "$fakebin/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_WORLD/calls.log"
exit 0
SH
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo "Python 3.9.6"
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
for arg in "$@"; do case "$arg" in -*) ;; *) url=$arg ;; esac; done
printf 'curl %s\n' "$url" >> "$FAKE_WORLD/calls.log"
case "$url" in
  */Homebrew/install/*)
    printf '%s\n' 'mkdir -p "$HOMEBREW_PREFIX/bin"' 'cp "$FAKE_WORLD/brew.stub" "$HOMEBREW_PREFIX/bin/brew"' \
      'printf "brew-installer NONINTERACTIVE=%s\n" "${NONINTERACTIVE:-}" >> "$FAKE_WORLD/calls.log"' ;;
  *) exit 22 ;;
esac
SH
  # A clone of Starship carries stub setup steps that record their calls: the
  # Herdr setup installs a herdr, the tool install records how it was asked,
  # and the checklist prints a marker line.
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "git version 2.39.5"; exit 0 ;;
  clone)
    printf 'git clone %s %s\n' "$2" "$3" >> "$FAKE_WORLD/calls.log"
    mkdir -p "$3/bin" "$3/.git" && touch "$3/bin/fm-primary.sh"
    cat > "$3/bin/fm-herdr-setup.sh" <<'HS'
#!/usr/bin/env bash
printf 'herdr-setup %s FM_HOME=%s\n' "$*" "${FM_HOME:-}" >> "$FAKE_WORLD/calls.log"
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\necho herdr 0.9.5\n' > "$HOME/.local/bin/herdr"
chmod +x "$HOME/.local/bin/herdr"
HS
    cat > "$3/bin/fm-bootstrap.sh" <<'BS'
#!/usr/bin/env bash
printf 'bootstrap %s FM_HOME=%s\n' "$*" "${FM_HOME:-}" >> "$FAKE_WORLD/calls.log"
case "$*" in
  install-missing) [ "${FAKE_TOOLS_FAIL:-}" != 1 ] || { echo "error: not installed: treehouse" >&2; exit 1; }
    : > "$FAKE_WORLD/tools-installed" ;;
  "install-missing --check") [ -e "$FAKE_WORLD/tools-installed" ] || { echo "needs: treehouse (install)"; exit 1; } ;;
  *) echo "usage: fm-bootstrap.sh install-missing [--check]" >&2; exit 1 ;;
esac
BS
    cat > "$3/bin/fm-first-hour.sh" <<'FH'
#!/usr/bin/env bash
echo "Your first hour with Starship: 3 of 12 done"
FH
    chmod +x "$3/bin/"*.sh ;;
  -C) [ -d "$2/.git" ] ;;
esac
SH
  cat > "$dir/brew.stub" <<'SH'
#!/usr/bin/env bash
bin=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  shellenv) printf 'export PATH="%s:$PATH"\n' "$bin" ;;
  install)
    shift
    printf 'brew install %s HOMEBREW_NO_ASK=%s\n' "$*" "${HOMEBREW_NO_ASK:-}" >> "$FAKE_WORLD/calls.log"
    # Homebrew's first install reads standard input; under curl | bash that
    # is the rest of the setup script itself.
    [ "${FAKE_BREW_READS_STDIN:-}" = 1 ] && cat > /dev/null
    for tool in gh tmux jq; do
      printf '#!/usr/bin/env bash\necho %s-version-1\n' "$tool" > "$bin/$tool"
    done
    if [ "${FAKE_NODE_BROKEN:-}" = 1 ]; then
      printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/node"
    else
      printf '#!/usr/bin/env bash\necho v24.1.0\n' > "$bin/node"
    fi
    cat > "$bin/npm" <<'NPM'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo 11.3.0; exit 0; }
printf 'npm %s\n' "$*" >> "$FAKE_WORLD/calls.log"
bin=$(cd "$(dirname "$0")" && pwd)
printf '#!/usr/bin/env bash\necho 2.9.0 Claude Code\n' > "$bin/claude"
chmod +x "$bin/claude"
NPM
    chmod +x "$bin"/* ;;
esac
SH
  chmod +x "$fakebin"/* "$dir/brew.stub"
  printf '%s\n' "$dir"
}

# run_setup <world> [args...]: run the script inside the world; prints combined
# output and returns its exit status.
run_setup() {
  local dir=$1
  shift
  (
    cd "$dir/home" || exit 1
    PATH="$dir/fakebin:$dir/sysbin" HOME="${FAKE_HOME:-$dir/home}" FAKE_WORLD="$dir" \
      HOMEBREW_PREFIX="$dir/homebrew" bash "$SETUP" "$@" 2>&1
  )
}

# run_setup_piped <world> [args...]: as run_setup, but the script arrives on
# standard input the way the guide runs it, curl ... | bash.
run_setup_piped() {
  local dir=$1
  shift
  (
    cd "$dir/home" || exit 1
    cat "$SETUP" | PATH="$dir/fakebin:$dir/sysbin" HOME="$dir/home" FAKE_WORLD="$dir" \
      HOMEBREW_PREFIX="$dir/homebrew" bash -s -- "$@" 2>&1
  )
}

calls() { cat "$1/calls.log"; }

# line_of <world> <fixed text>: the calls.log line number of its first match.
line_of() { grep -nF -- "$2" "$1/calls.log" | head -n 1 | cut -d: -f1; }

test_help_and_usage_errors() {
  local w out status
  w=$(make_world usage)
  out=$(run_setup "$w" --help)
  status=$?
  [ "$status" -eq 0 ] || fail "--help should exit 0, got $status"
  assert_contains "$out" "usage: fm-mac-setup.sh [--ci]" "--help prints the usage"
  out=$(run_setup "$w" --bogus)
  status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument should exit 2, got $status: $out"
  [ ! -s "$w/calls.log" ] || fail "a usage error must change nothing: $(calls "$w")"
  pass "--help prints usage and an unknown argument is a usage error that changes nothing"
}

test_refusals_change_nothing() {
  local w out status
  w=$(make_world not-mac)
  out=$(FAKE_UNAME_S=Linux run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a non-Mac host should be refused, got $status: $out"
  assert_contains "$out" "ONBOARDING-linux-server.md" "the refusal names the other guides"
  [ ! -s "$w/calls.log" ] || fail "the non-Mac refusal changed something: $(calls "$w")"

  w=$(make_world root)
  out=$(FAKE_UID=0 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "root should be refused, got $status: $out"
  [ ! -s "$w/calls.log" ] || fail "the root refusal changed something: $(calls "$w")"

  w=$(make_world foreign-dir)
  mkdir -p "$w/home/starship"
  out=$(run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a foreign ~/starship should be refused, got $status: $out"
  assert_contains "$out" "exists but is not a Starship clone" "the foreign-directory refusal says so"
  [ ! -s "$w/calls.log" ] || fail "the foreign-directory refusal changed something: $(calls "$w")"

  w=$(make_world not-admin)
  out=$(FAKE_ADMIN=0 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a standard user without Homebrew should be refused, got $status: $out"
  assert_contains "$out" "Homebrew needs a Mac administrator" "the refusal says why"
  assert_contains "$out" "Users & Groups" "the refusal says where to look"
  [ ! -s "$w/calls.log" ] || fail "the admin refusal changed something: $(calls "$w")"
  pass "a non-Mac host, root, a foreign ~/starship, and a standard user with no Homebrew are refused before any change"
}

test_prerequisites_come_first_and_tools_finish_before_herdr_opens() {
  local w out status brew node claude clone herdr tools
  w=$(make_world fresh)
  out=$(run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "a fresh install should succeed, got $status: $out"
  assert_contains "$(calls "$w")" "sudo -v" "the Mac password is asked for once, before Homebrew"
  assert_contains "$(calls "$w")" "brew-installer NONINTERACTIVE=1" "Homebrew is installed unattended"
  assert_contains "$(calls "$w")" "brew install node gh tmux jq HOMEBREW_NO_ASK=1" \
    "Node, jq and the other absent tools come from Homebrew without its y/n question, and the working git is kept"
  brew=$(line_of "$w" "brew-installer")
  node=$(line_of "$w" "brew install node gh tmux jq")
  claude=$(line_of "$w" "npm install -g @anthropic-ai/claude-code")
  clone=$(line_of "$w" "git clone https://github.com/Amplify-Logic/starship $w/home/starship")
  herdr=$(line_of "$w" "herdr-setup --quiet FM_HOME=$w/home/starship")
  tools=$(line_of "$w" "bootstrap install-missing FM_HOME=$w/home/starship")
  for n in "$brew" "$node" "$claude" "$clone" "$herdr" "$tools"; do
    [ -n "$n" ] || fail "a setup step did not run: $(calls "$w")"
  done
  [ "$brew" -lt "$node" ] && [ "$node" -lt "$claude" ] && [ "$claude" -lt "$clone" ] \
    && [ "$clone" -lt "$herdr" ] && [ "$herdr" -lt "$tools" ] \
    || fail "the steps ran out of order (Homebrew, Node and jq must come first): $(calls "$w")"
  assert_contains "$out" "ok  tools" "the closing check confirms every tool the first mate needs"
  assert_contains "$out" "ok  herdr" "the closing check finds Herdr"
  assert_contains "$out" "Setup finished." "the setup reports finished"
  assert_contains "$out" "Your first hour with Starship" "the setup ends by showing the first-hour checklist"
  assert_contains "$(cat "$w/home/.zprofile")" "eval \"\$($w/homebrew/bin/brew shellenv)\"" \
    "new Terminal windows load Homebrew"
  assert_contains "$(cat "$w/home/.zprofile")" "export HOMEBREW_NO_ASK=1" "later brew installs ask no y/n question"
  pass "Homebrew, Node and jq come first, then Claude Code, the clone and Herdr, and every tool is installed before the first mate starts"
}

test_rerun_keeps_everything() {
  local w out status log
  w=$(make_world rerun)
  run_setup "$w" --ci >/dev/null || fail "the first run should succeed"
  : > "$w/calls.log"
  out=$(FAKE_ADMIN=0 run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a re-run, even by a standard user once Homebrew exists, should succeed, got $status: $out"
  log=$(calls "$w")
  assert_not_contains "$log" "sudo" "a re-run with Homebrew present asks for no password"
  assert_not_contains "$log" "brew-installer" "a re-run keeps Homebrew"
  assert_not_contains "$log" "npm install" "a re-run keeps Claude Code"
  assert_not_contains "$log" "brew install" "a re-run leaves working Homebrew packages as they are"
  assert_not_contains "$log" "git clone" "a re-run leaves the clone untouched"
  assert_contains "$out" "already cloned" "a re-run says the clone was left as it is"
  [ "$(grep -c 'brew shellenv' "$w/home/.zprofile")" -eq 1 ] \
    || fail "a re-run duplicated the profile lines: $(cat "$w/home/.zprofile")"
  pass "a re-run keeps Homebrew, Claude Code and the clone, and writes the profile lines once"
}

# stale_clone <world>: replace the clone's bootstrap with one from before
# install-missing existed, which ignores its arguments, runs its session-start
# sweep and exits 0.
stale_clone() {
  cat > "$1/home/starship/bin/fm-bootstrap.sh" <<'BS'
#!/usr/bin/env bash
printf 'bootstrap sweep %s\n' "$*" >> "$FAKE_WORLD/calls.log"
echo "MISSING: treehouse (install: brew install treehouse)"
BS
  chmod +x "$1/home/starship/bin/fm-bootstrap.sh"
}

test_clone_too_old_to_install_tools_stops_before_any_step() {
  local w out status q advice
  w=$(make_world stale-clone)
  run_setup "$w" --ci >/dev/null || fail "the first run should succeed"
  stale_clone "$w"
  : > "$w/calls.log"
  out=$(run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a clone too old to install tools should stop the setup, got $status: $out"
  assert_contains "$out" "git -C $w/home/starship pull, then run this again" "the refusal says how to update the clone"
  assert_not_contains "$out" "Setup finished." "an old clone never reports the setup finished"
  [ ! -s "$w/calls.log" ] || fail "an old clone must stop the setup before any step or sweep: $(calls "$w")"
  advice=${out#*update it by running: }
  for q in '"' "'" $'\xe2\x80\x9c' $'\xe2\x80\x9d' $'\xe2\x80\x98' $'\xe2\x80\x99'; do
    case "$advice" in
      *"$q"*) fail "the update command a person types must carry no quotes: $advice" ;;
    esac
  done
  pass "a clone from before install-missing stops the setup before any step, with a quote-free update command"
}

test_closing_steps_are_safe_to_send_through_chat() {
  local w out status closing
  w=$(make_world closing)
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a setup with sign-ins should succeed, got $status: $out"
  closing=${out#*Setup finished.}
  assert_contains "$closing" "gh auth login" "the GitHub sign-in is spelled out"
  assert_contains "$closing" "  2. claude" "the Claude sign-in is spelled out"
  assert_contains "$closing" "onboard-starship" "the closing steps say how to start the first mate"
  assert_contains "$closing" "fm-first-hour.sh --watch" "the closing steps say how to keep the checklist open"
  local q
  # Straight quotes, then the curly ones a chat app turns them into.
  for q in '"' "'" $'\xe2\x80\x9c' $'\xe2\x80\x9d' $'\xe2\x80\x98' $'\xe2\x80\x99'; do
    case "$closing" in
      *"$q"*) fail "the closing steps a person types must carry no quotes: $closing" ;;
    esac
  done
  # The setup runs as a child of curl | bash, so its PATH dies with it: the
  # new window must come before the sign-ins.
  newterm=$(printf '%s\n' "$closing" | grep -n 'open a NEW Terminal window' | head -n 1 | cut -d: -f1)
  signin=$(printf '%s\n' "$closing" | grep -n 'gh auth login' | head -n 1 | cut -d: -f1)
  [ -n "$newterm" ] && [ "$newterm" -lt "$signin" ] \
    || fail "the new Terminal window must come before the sign-ins, got: $closing"
  pass "the closing steps open a new window first and carry no quote a chat app could curl"
}

test_broken_node_stops_before_any_npm_install() {
  local w out status
  w=$(make_world broken-node)
  out=$(FAKE_NODE_BROKEN=1 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a Node that does not run should stop the setup, got $status: $out"
  assert_contains "$out" "Node is installed but does not run" "the failure names Node"
  assert_not_contains "$(calls "$w")" "npm install" "nothing is installed through a broken Node"
  pass "a Node that does not run stops the setup before any npm install"
}

test_failed_tool_install_stops_the_setup() {
  local w out status
  w=$(make_world tools-fail)
  out=$(FAKE_TOOLS_FAIL=1 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a failed tool install should stop the setup, got $status: $out"
  assert_contains "$out" "a tool above did not install; run this again in a few minutes" \
    "the failure says to run the setup again"
  assert_not_contains "$out" "Setup finished." "a failed tool install never reports the setup finished"
  pass "a tool that fails to install stops the setup before it reports finished"
}

test_piped_install_runs_to_the_end() {
  local w out status
  w=$(make_world piped)
  out=$(FAKE_BREW_READS_STDIN=1 run_setup_piped "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "a piped install should succeed, got $status: $out"
  assert_contains "$out" "Setup finished." "a piped install reaches the end even when brew reads standard input"
  assert_contains "$(calls "$w")" "bootstrap install-missing" "the steps after brew install still run when piped"
  pass "the setup runs to the end under curl | bash even when an installer reads standard input"
}

test_help_and_usage_errors
test_refusals_change_nothing
test_prerequisites_come_first_and_tools_finish_before_herdr_opens
test_rerun_keeps_everything
test_clone_too_old_to_install_tools_stops_before_any_step
test_closing_steps_are_safe_to_send_through_chat
test_broken_node_stops_before_any_npm_install
test_failed_tool_install_stops_the_setup
test_piped_install_runs_to_the_end

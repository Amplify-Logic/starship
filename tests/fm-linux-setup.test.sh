#!/usr/bin/env bash
# Behavior tests for bin/fm-linux-setup.sh, the one-command setup that takes a
# fresh Ubuntu 24.04 (inside WSL 2 or on a server) to a startable first mate.
#
# Every external effect is a PATH stub that records its call, under a narrow
# PATH pin, so no case installs anything on the host. The stubbed installers
# create the binaries a real install would, which lets the script's own
# closing version check pass or fail on what it actually installed. The real
# installs are proven end to end by .github/workflows/windows-wsl.yml on a
# fresh Ubuntu inside WSL 2 and in a fresh Ubuntu server container.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-linux-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-linux-setup)

# make_world <name>: a fresh HOME, Homebrew prefix, and stub toolchain.
# Echoes the case directory; the stubs append one line per call to calls.log.
make_world() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home" "$dir/sysbin"
  fakebin=$(fm_fakebin "$dir")
  : > "$dir/calls.log"
  fm_fake_real_tool "$fakebin" bash sh env cat grep sed head mkdir mktemp \
    chmod rm cp touch tr dirname awk || fail "a basic tool is missing on this host"
  fm_fake_exit0 "$fakebin" true

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
SH
  cat > "$fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-1000}"
SH
  # A passwordless sudo user, as the CI fixture and cloud-init servers set up:
  # real commands run, but sudo's default verifypw=all makes -v ask for a
  # password unless every sudoers entry is NOPASSWD.
  cat > "$fakebin/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_WORLD/calls.log"
if [ "${1:-}" = -v ]; then echo "sudo: a password is required" >&2; exit 1; fi
exec "$@"
SH
  cat > "$fakebin/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$FAKE_WORLD/calls.log"
for arg in "$@"; do
  case "$arg" in
    wslu)
      printf '#!/usr/bin/env bash\necho "wslu v3.2.3-1; wslview v10"\n' > "$FAKE_WORLD/sysbin/wslview"
      chmod +x "$FAKE_WORLD/sysbin/wslview"
      ;;
    *.deb)
      printf '#!/usr/bin/env bash\necho "Google Chrome 141.0.0.0"\n' > "$FAKE_WORLD/sysbin/google-chrome"
      chmod +x "$FAKE_WORLD/sysbin/google-chrome"
      ;;
  esac
done
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >> "$FAKE_WORLD/calls.log"
if [ -n "$out" ]; then printf 'deb' > "$out"; exit 0; fi
case "$url" in
  */Homebrew/install/*)
    printf '%s\n' 'mkdir -p "$HOMEBREW_PREFIX/bin"' 'cp "$FAKE_WORLD/brew.stub" "$HOMEBREW_PREFIX/bin/brew"' \
      'printf "brew-installer NONINTERACTIVE=%s\n" "${NONINTERACTIVE:-}" >> "$FAKE_WORLD/calls.log"' ;;
  */claude.ai/install.sh)
    printf '%s\n' 'echo claude-installer >> "$FAKE_WORLD/calls.log"' \
      '[ "${FAKE_CLAUDE_INSTALLS_NOTHING:-}" = 1 ] && exit 0' 'mkdir -p "$HOME/.local/bin"' \
      'printf "#!/usr/bin/env bash\necho 2.9.0 Claude Code\n" > "$HOME/.local/bin/claude"' \
      'chmod +x "$HOME/.local/bin/claude"' ;;
  *) exit 22 ;;
esac
SH
  # A clone of Firstmate carries the real add-on owner, so --addon runs the
  # same install a real clone would; a clone of an add-on whose URL matches
  # FAKE_ADDON_CLONE_FAILS fails the way a private repository does before the
  # GitHub sign-in.
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "git version 2.43.0"; exit 0 ;;
  clone)
    shift
    while [ "$#" -gt 2 ]; do shift; done
    printf 'git clone %s %s\n' "$1" "$2" >> "$FAKE_WORLD/calls.log"
    case "$1" in
      */firstmate)
        mkdir -p "$2/bin" "$2/.git" && touch "$2/bin/fm-primary.sh" "$2/AGENTS.md"
        cp "$FAKE_FM_BIN/fm-addon.sh" "$FAKE_FM_BIN/fm-timeout-lib.sh" "$2/bin/"
        # The clone's own Herdr setup: records its call and installs a herdr the
        # way bin/fm-herdr-setup.sh would.
        cat > "$2/bin/fm-herdr-setup.sh" <<'HS'
#!/usr/bin/env bash
printf 'herdr-setup %s FM_HOME=%s\n' "$*" "${FM_HOME:-}" >> "$FAKE_WORLD/calls.log"
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\necho herdr 0.9.5\n' > "$HOME/.local/bin/herdr"
chmod +x "$HOME/.local/bin/herdr"
HS
        chmod +x "$2/bin/fm-herdr-setup.sh" ;;
      *)
        if [ -n "${FAKE_ADDON_CLONE_FAILS:-}" ] && [ -z "${1##*"$FAKE_ADDON_CLONE_FAILS"*}" ]; then
          echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
          exit 128
        fi
        mkdir -p "$2/.git" ;;
    esac ;;
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
    # A fresh Homebrew's first install reads standard input; under curl | bash
    # that is the rest of the setup script itself.
    [ "${FAKE_BREW_READS_STDIN:-}" = 1 ] && cat > /dev/null
    for tool in node npm gh tmux jq; do
      printf '#!/usr/bin/env bash\necho %s-version-1\n' "$tool" > "$bin/$tool"
      chmod +x "$bin/$tool"
    done ;;
esac
SH
  chmod +x "$fakebin"/* "$dir/brew.stub"
  printf '%s\n' "$dir"
}

# run_setup <world> [args...]: run the script inside the world; prints combined
# output and returns its exit status. FAKE_WINDOWS_PATH appends a directory the
# way WSL appends the Windows PATH, and FAKE_WSL_DISTRO sets WSL_DISTRO_NAME the
# way WSL does; otherwise it is unset even when the tests themselves run in WSL.
run_setup() {
  local dir=$1
  shift
  (
    cd "$dir/home" || exit 1
    unset WSL_DISTRO_NAME
    [ -z "${FAKE_WSL_DISTRO:-}" ] || export WSL_DISTRO_NAME="$FAKE_WSL_DISTRO"
    PATH="$dir/fakebin:$dir/sysbin${FAKE_WINDOWS_PATH:+:$FAKE_WINDOWS_PATH}" HOME="${FAKE_HOME:-$dir/home}" FAKE_WORLD="$dir" \
      FAKE_FM_BIN="$ROOT/bin" HOMEBREW_PREFIX="$dir/linuxbrew" bash "$SETUP" "$@" 2>&1
  )
}

calls() { cat "$1/calls.log"; }

test_help_and_usage_errors() {
  local w out status
  w=$(make_world usage)
  out=$(run_setup "$w" --help)
  status=$?
  [ "$status" -eq 0 ] || fail "--help should exit 0, got $status"
  assert_contains "$out" "usage: fm-linux-setup.sh [--ci]" "--help prints the usage"
  out=$(run_setup "$w" --bogus)
  status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument should exit 2, got $status: $out"
  [ ! -s "$w/calls.log" ] || fail "a usage error must change nothing: $(calls "$w")"
  pass "--help prints usage and an unknown argument is a usage error that changes nothing"
}

test_refusals_change_nothing() {
  local w out status
  w=$(make_world not-linux)
  out=$(FAKE_UNAME_S=Darwin run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a non-Linux host should be refused, got $status: $out"
  assert_contains "$out" "on a Mac follow ONBOARDING.md" "the Mac refusal names the Mac guide"
  [ ! -s "$w/calls.log" ] || fail "the non-Linux refusal changed something: $(calls "$w")"

  w=$(make_world root)
  out=$(FAKE_UID=0 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "root should be refused, got $status: $out"
  assert_contains "$out" "run this as your own user, not root" "the root refusal says to make a user"
  [ ! -s "$w/calls.log" ] || fail "the root refusal changed something: $(calls "$w")"

  w=$(make_world windows-drive)
  out=$(FAKE_HOME=/mnt/c/Users/fm run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a home on the Windows drive should be refused, got $status: $out"
  assert_contains "$out" "/mnt/c/Users/fm is on the Windows drive" "the /mnt refusal names the path"
  [ ! -s "$w/calls.log" ] || fail "the /mnt refusal changed something: $(calls "$w")"

  w=$(make_world foreign-dir)
  mkdir -p "$w/home/starship"
  touch "$w/home/starship/notes.txt"
  out=$(run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a foreign ~/starship should be refused, got $status: $out"
  assert_contains "$out" "exists but is not a Firstmate clone" "the foreign-directory refusal says so"
  [ ! -s "$w/calls.log" ] || fail "the foreign-directory refusal changed something: $(calls "$w")"
  pass "a non-Linux host, root, a home under /mnt/<drive>/, and a foreign ~/starship are refused before any change"
}

test_fresh_install_then_rerun_is_idempotent() {
  local w out status log
  w=$(make_world fresh)
  out=$(run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "a fresh install should succeed, got $status: $out"
  log=$(calls "$w")
  assert_contains "$log" "sudo true" "sudo is asked for once up front, without -v"
  assert_contains "$log" "apt-get install -y -q build-essential procps curl file git ca-certificates" \
    "Homebrew's Linux prerequisites are installed with apt"
  assert_contains "$log" "brew-installer NONINTERACTIVE=1" "Homebrew is installed non-interactively"
  assert_contains "$log" "brew install git node gh tmux jq HOMEBREW_NO_ASK=1" \
    "the shared tools, jq included, come from Homebrew without its y/n question"
  assert_not_contains "$log" "wslu" "a server gets no WSL browser bridge"
  assert_not_contains "$log" "herdr-setup" "a server keeps tmux and gets no Herdr setup"
  assert_not_contains "$out" "  herdr" "a server does not check for Herdr"
  assert_contains "$log" "claude-installer" "Claude Code comes from its native installer"
  assert_contains "$log" "curl https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    "Chrome's package is downloaded"
  assert_contains "$log" "google-chrome-stable_current_amd64.deb" "Chrome's package is installed with apt"
  assert_contains "$log" "git clone https://github.com/Amplify-Logic/firstmate $w/home/starship" \
    "Firstmate is cloned into ~/starship"
  assert_contains "$out" "ok  jq" "the closing check finds jq"
  assert_contains "$out" "ok  chrome" "the closing check finds Chrome"
  assert_contains "$out" "ok  firstmate" "the closing check finds the clone"
  assert_contains "$out" "Sign-ins skipped (--ci)." "--ci says the sign-ins were skipped"
  assert_not_contains "$out" "gh auth login" "--ci prints no sign-in instructions"
  assert_contains "$(cat "$w/home/.profile")" "eval \"\$($w/linuxbrew/bin/brew shellenv)\"" \
    "login shells load Homebrew"
  assert_contains "$(cat "$w/home/.bashrc")" '.local/bin' "interactive shells find ~/.local/bin"
  assert_contains "$(cat "$w/home/.bashrc")" 'export HOMEBREW_NO_ASK=1' "later brew installs ask no y/n question"
  assert_not_contains "$(cat "$w/home/.bashrc")" 'BROWSER' "a server keeps its own browser setting"

  : > "$w/calls.log"
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a re-run should succeed, got $status: $out"
  log=$(calls "$w")
  assert_not_contains "$log" "brew-installer" "a re-run keeps the installed Homebrew"
  assert_not_contains "$log" "claude-installer" "a re-run keeps the installed Claude Code"
  assert_not_contains "$log" ".deb" "a re-run keeps the installed Chrome"
  assert_not_contains "$log" "git clone" "a re-run leaves the clone untouched"
  assert_contains "$out" "already cloned" "a re-run says the clone was left as it is"
  assert_contains "$out" "gh auth login" "without --ci the GitHub sign-in is spelled out"
  assert_contains "$out" "  2. claude" "without --ci the Claude sign-in is spelled out"
  # The setup runs as a child of curl | bash, so its PATH dies with it: the
  # new terminal must come before the sign-ins, or gh and claude are not found.
  newterm=$(printf '%s\n' "$out" | grep -n 'open a NEW terminal' | head -n 1 | cut -d: -f1)
  signin=$(printf '%s\n' "$out" | grep -n 'gh auth login' | head -n 1 | cut -d: -f1)
  [ -n "$newterm" ] && [ "$newterm" -lt "$signin" ] \
    || fail "the new terminal must be opened before the sign-ins, got: $out"
  assert_contains "$out" "step 8 of ONBOARDING-windows.md" "the closing text sends Windows users to the guide's Herdr step"
  assert_contains "$out" "inside Herdr;" "the Windows step starts the first mate in Herdr"
  assert_contains "$out" "step 6 of ONBOARDING-linux-server.md" "the closing text sends server users to the guide's tmux step"
  [ "$(grep -c 'brew shellenv' "$w/home/.profile")" -eq 1 ] \
    || fail "a re-run duplicated the profile lines: $(cat "$w/home/.profile")"
  pass "a fresh install runs every step once, and a re-run keeps everything and only prints the new-terminal step and the sign-ins"
}

test_wsl_sends_sign_ins_to_the_windows_browser() {
  local w out status rc
  w=$(make_world wsl)
  out=$(FAKE_WSL_DISTRO=Ubuntu-24.04 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "a WSL install should succeed, got $status: $out"
  assert_contains "$(calls "$w")" "apt-get install -y -q build-essential procps curl file git ca-certificates wslu" \
    "WSL gets wslu with the system packages"
  assert_contains "$out" "ok  wslview" "the closing check finds wslview"
  assert_contains "$(calls "$w")" "herdr-setup --quiet FM_HOME=$w/home/starship" \
    "inside WSL the clone's own Herdr setup runs for the new home"
  assert_contains "$out" "ok  herdr" "the closing check finds Herdr"
  for rc in .profile .bashrc; do
    [ "$(grep -cx 'export BROWSER=wslview' "$w/home/$rc")" -eq 1 ] \
      || fail "$rc should send links to the Windows browser once: $(cat "$w/home/$rc")"
  done
  out=$(FAKE_WSL_DISTRO=Ubuntu-24.04 run_setup "$w" --ci)
  [ "$(grep -cx 'export BROWSER=wslview' "$w/home/.bashrc")" -eq 1 ] \
    || fail "a re-run duplicated the browser line: $(cat "$w/home/.bashrc")"
  pass "inside WSL the setup installs wslu and Herdr, and points BROWSER at wslview, so sign-ins open in Windows"
}

test_arm64_skips_chrome() {
  local w out status
  w=$(make_world arm64)
  out=$(FAKE_UNAME_M=aarch64 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "arm64 should still finish, got $status: $out"
  assert_contains "$out" "no Chrome package for aarch64 Linux" "arm64 says why Chrome was skipped"
  assert_not_contains "$(calls "$w")" ".deb" "arm64 downloads no amd64 Chrome package"
  assert_not_contains "$out" "  chrome" "arm64 does not check for a Chrome it could not install"
  pass "arm64 finishes without Chrome and says browser checks are unavailable"
}

test_windows_claude_does_not_count_as_installed() {
  local w out status npm_dir
  w=$(make_world windows-claude)
  # Claude Code installed on Windows with npm leaves an executable sh shim in
  # %APPDATA%\npm, which WSL puts on the Linux PATH.
  npm_dir="$w/mnt/c/Users/fm/AppData/Roaming/npm"
  mkdir -p "$npm_dir"
  printf '#!/usr/bin/env bash\necho 1.0.0 Windows Claude Code\n' > "$npm_dir/claude"
  chmod +x "$npm_dir/claude"
  out=$(FAKE_WINDOWS_PATH="$npm_dir" run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "setup with a Windows claude on PATH should succeed, got $status: $out"
  assert_contains "$(calls "$w")" "claude-installer" "a Windows claude on PATH still gets the Linux install"
  assert_not_contains "$out" "Claude Code already present" "a Windows claude is not the Linux install"
  assert_contains "$out" "2.9.0 Claude Code" "the closing check runs the Linux claude"
  pass "a Windows Claude Code on the WSL PATH does not stand in for the Linux install"
}

test_missing_tool_fails_the_closing_check() {
  local w out status
  w=$(make_world broken-claude)
  # A Claude installer that reports success but installs nothing.
  out=$(FAKE_CLAUDE_INSTALLS_NOTHING=1 run_setup "$w" --ci)
  status=$?
  [ "$status" -eq 1 ] || fail "a tool missing after install should fail, got $status: $out"
  assert_contains "$out" "--  claude" "the closing check names the missing tool"
  pass "the closing check fails and names a tool an installer did not actually install"
}

# run_setup_piped <world> [args...]: as run_setup, but the script arrives on
# standard input the way the guides run it, curl ... | bash.
run_setup_piped() {
  local dir=$1
  shift
  (
    cd "$dir/home" || exit 1
    unset WSL_DISTRO_NAME
    cat "$SETUP" | PATH="$dir/fakebin:$dir/sysbin" HOME="$dir/home" FAKE_WORLD="$dir" \
      FAKE_FM_BIN="$ROOT/bin" HOMEBREW_PREFIX="$dir/linuxbrew" bash -s -- "$@" 2>&1
  )
}

test_piped_install_runs_to_the_end() {
  local w out status
  w=$(make_world piped)
  out=$(FAKE_BREW_READS_STDIN=1 run_setup_piped "$w" --ci)
  status=$?
  [ "$status" -eq 0 ] || fail "a piped install should succeed, got $status: $out"
  assert_contains "$out" "Setup finished." "a piped install reaches the end even when brew reads standard input"
  assert_contains "$(calls "$w")" "claude-installer" "the steps after brew install still run when piped"
  assert_contains "$out" "ok  firstmate" "the closing check runs when piped"
  pass "the setup runs to the end under curl | bash even when an installer reads standard input"
}

test_addon_is_named_and_cloned_once_signed_in() {
  local w out status config arg
  w=$(make_world addon)
  config="$w/home/starship/config/addon"
  out=$(FAKE_ADDON_CLONE_FAILS=starship-addon run_setup "$w" --addon example-org/starship-addon)
  status=$?
  [ "$status" -eq 0 ] || fail "a setup whose add-on cannot be cloned yet should still finish, got $status: $out"
  assert_equals "$(printf 'path = projects/starship-addon\norigin = https://github.com/example-org/starship-addon')" \
    "$(cat "$config")" "--addon must name the add-on's origin and its checkout under projects/"
  assert_contains "$out" "the add-on is not cloned yet" "a clone that needs the sign-in must be reported"
  assert_contains "$out" "3. ~/starship/bin/fm-addon.sh install" "the closing steps must name the command that finishes the add-on"
  out=$(FAKE_ADDON_CLONE_FAILS=starship-addon run_setup "$w" --ci --addon example-org/starship-addon)
  assert_not_contains "$out" "3. ~/starship/bin/fm-addon.sh install" "--ci prints no closing steps"

  : > "$w/calls.log"
  out=$(run_setup "$w" --addon example-org/starship-addon)
  status=$?
  [ "$status" -eq 0 ] || fail "a re-run after the sign-in should succeed, got $status: $out"
  assert_contains "$(calls "$w")" "git clone https://github.com/example-org/starship-addon $w/home/starship/projects/starship-addon" \
    "the add-on must be cloned into its configured checkout"
  assert_contains "$out" "add-on: cloned" "the clone must be reported"
  assert_not_contains "$out" "3. ~/starship/bin/fm-addon.sh install" "a cloned add-on needs no closing step"

  printf 'path = elsewhere\n' > "$config"
  out=$(run_setup "$w" --ci --addon other/repo)
  assert_contains "$out" "already names an add-on; left as it is" "a different add-on must not be overwritten"
  assert_equals "path = elsewhere" "$(cat "$config")" "an existing config/addon must be left as it is"

  w=$(make_world addon-usage)
  for arg in starship-addon https://github.com/example-org/starship-addon \
    git@github.com:example-org/starship-addon.git /srv/addon.git Amplify-Logic/..; do
    out=$(run_setup "$w" --addon "$arg" 2>&1)
    status=$?
    [ "$status" -eq 2 ] || fail "--addon $arg should be a usage error, got $status: $out"
    assert_contains "$out" "--addon needs OWNER/REPO, the add-on's GitHub repository" "--addon $arg must be refused by naming the OWNER/REPO form"
  done
  [ ! -s "$w/calls.log" ] || fail "an add-on usage error must change nothing: $(calls "$w")"
  [ ! -e "$w/home/starship/config/addon" ] || fail "an add-on usage error must write no config/addon"
  pass "--addon names the private add-on by OWNER/REPO only, clones it once the sign-in allows, and never overwrites another one"
}

test_help_and_usage_errors
test_addon_is_named_and_cloned_once_signed_in
test_piped_install_runs_to_the_end
test_refusals_change_nothing
test_fresh_install_then_rerun_is_idempotent
test_wsl_sends_sign_ins_to_the_windows_browser
test_arm64_skips_chrome
test_windows_claude_does_not_count_as_installed
test_missing_tool_fails_the_closing_check

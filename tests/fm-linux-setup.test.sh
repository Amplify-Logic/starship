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
    chmod rm cp touch tr dirname || fail "a basic tool is missing on this host"
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
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "git version 2.43.0"; exit 0 ;;
  clone)
    printf 'git clone %s %s\n' "$2" "$3" >> "$FAKE_WORLD/calls.log"
    mkdir -p "$3/bin" "$3/.git" && touch "$3/bin/fm-primary.sh" "$3/AGENTS.md" ;;
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
    printf 'brew install %s\n' "$*" >> "$FAKE_WORLD/calls.log"
    for tool in node npm gh tmux; do
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
# way WSL appends the Windows PATH.
run_setup() {
  local dir=$1
  shift
  (
    cd "$dir/home" || exit 1
    PATH="$dir/fakebin:$dir/sysbin${FAKE_WINDOWS_PATH:+:$FAKE_WINDOWS_PATH}" HOME="${FAKE_HOME:-$dir/home}" FAKE_WORLD="$dir" \
      HOMEBREW_PREFIX="$dir/linuxbrew" bash "$SETUP" "$@" 2>&1
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
  assert_contains "$log" "brew install git node gh tmux" "the shared tools come from Homebrew"
  assert_contains "$log" "claude-installer" "Claude Code comes from its native installer"
  assert_contains "$log" "curl https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    "Chrome's package is downloaded"
  assert_contains "$log" "google-chrome-stable_current_amd64.deb" "Chrome's package is installed with apt"
  assert_contains "$log" "git clone https://github.com/Amplify-Logic/firstmate $w/home/starship" \
    "Firstmate is cloned into ~/starship"
  assert_contains "$out" "ok  chrome" "the closing check finds Chrome"
  assert_contains "$out" "ok  firstmate" "the closing check finds the clone"
  assert_contains "$out" "Sign-ins skipped (--ci)." "--ci says the sign-ins were skipped"
  assert_not_contains "$out" "gh auth login" "--ci prints no sign-in instructions"
  assert_contains "$(cat "$w/home/.profile")" "eval \"\$($w/linuxbrew/bin/brew shellenv)\"" \
    "login shells load Homebrew"
  assert_contains "$(cat "$w/home/.bashrc")" '.local/bin' "interactive shells find ~/.local/bin"

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
  assert_contains "$out" "step 7 of ONBOARDING-windows.md" "the closing text sends Windows users to the guide's tmux step"
  assert_contains "$out" "step 6 of ONBOARDING-linux-server.md" "the closing text sends server users to the guide's tmux step"
  [ "$(grep -c 'brew shellenv' "$w/home/.profile")" -eq 1 ] \
    || fail "a re-run duplicated the profile lines: $(cat "$w/home/.profile")"
  pass "a fresh install runs every step once, and a re-run keeps everything and only prints the new-terminal step and the sign-ins"
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

test_help_and_usage_errors
test_refusals_change_nothing
test_fresh_install_then_rerun_is_idempotent
test_arm64_skips_chrome
test_windows_claude_does_not_count_as_installed
test_missing_tool_fails_the_closing_check

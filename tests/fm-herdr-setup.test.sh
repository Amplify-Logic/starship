#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-setup.sh, which makes a fresh Starship home
# start in Herdr from its first launch.
#
# Herdr and its installer are PATH stubs that record their calls, under a
# narrow PATH pin, so no case installs anything on the host or reaches a real
# Herdr server. The installer stub creates the herdr a real install would, so
# the script's own version gate passes or fails on what was installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-herdr-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-setup)

# A herdr stub reporting client protocol $FAKE_HERDR_PROTOCOL (22, Herdr
# 0.9.5's, by default), whose Claude integration is current once installed.
write_fake_herdr() {  # <bin-dir>
  mkdir -p "$1"
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$FAKE_WORLD/calls.log"
case "${1:-} ${2:-}" in
  "--version "*) echo "herdr 0.9.5" ;;
  "status --json") printf '{"client":{"version":"0.9.5","protocol":%s},"server":{"running":false}}\n' "${FAKE_HERDR_PROTOCOL:-22}" ;;
  "integration status")
    if [ -e "$HOME/.claude/hooks/herdr-agent-state.sh" ]; then
      echo "claude: current (v11) ($HOME/.claude/hooks/herdr-agent-state.sh)"
    else
      echo "claude: not installed ($HOME/.claude/hooks/herdr-agent-state.sh)"
    fi ;;
  "integration install")
    [ -d "$HOME/.claude" ] || { echo "claude directory not found at $HOME/.claude. install claude code first" >&2; exit 1; }
    mkdir -p "$HOME/.claude/hooks" && : > "$HOME/.claude/hooks/herdr-agent-state.sh" ;;
esac
SH
  chmod +x "$1/herdr"
}

# make_world <name>: a fresh HOME, an empty Starship home, a stub installer.
make_world() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home" "$dir/fmhome"
  fakebin=$(fm_fakebin "$dir")
  : > "$dir/calls.log"
  fm_fake_real_tool "$fakebin" bash sh env cat grep sed awk head tail mkdir mktemp \
    chmod rm cp touch tr dirname uname ls jq || fail "a basic tool is missing on this host"
  cat > "$dir/install-herdr" <<'SH'
#!/usr/bin/env bash
printf 'install-herdr %s\n' "$*" >> "$FAKE_WORLD/calls.log"
[ "${FAKE_INSTALL_FAILS:-}" = 1 ] && exit 1
. "$FAKE_WORLD/fake-herdr.sh"
write_fake_herdr "$1"
SH
  declare -f write_fake_herdr > "$dir/fake-herdr.sh"
  chmod +x "$dir/install-herdr"
  printf '%s\n' "$dir"
}

run_setup() {  # <world> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin" HOME="$dir/home" FAKE_WORLD="$dir" FM_HOME="$dir/fmhome" \
    FM_HERDR_SETUP_INSTALLER="$dir/install-herdr" bash "$SETUP" "$@" 2>&1
}

calls() { cat "$1/calls.log"; }

profile_files() {
  if [ "$(uname -s)" = Darwin ]; then printf '.zprofile\n'; else printf '.profile\n.bashrc\n'; fi
}

test_fresh_home_gets_herdr_its_integration_and_the_runtime() {
  local w out status rc
  w=$(make_world fresh)
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a fresh setup should succeed, got $status: $out"
  assert_contains "$(calls "$w")" "install-herdr $w/home/.local/bin" "Herdr's pinned installer puts it in ~/.local/bin"
  assert_contains "$(calls "$w")" "herdr integration install claude" "Herdr's Claude Code integration is installed"
  [ -d "$w/home/.claude" ] || fail "the Claude folder Herdr needs was not made"
  assert_equals herdr "$(cat "$w/fmhome/config/backend")" "a fresh home runs on Herdr"
  for rc in $(profile_files); do
    assert_contains "$(cat "$w/home/$rc")" '.local/bin' "new terminals find ~/.local/bin through $rc"
  done
  assert_contains "$out" "  herdr" "the closing text opens Herdr"
  assert_contains "$out" "cd $w/fmhome && bin/fm-primary.sh opus" "the closing text starts the first mate inside it"

  : > "$w/calls.log"
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a re-run should succeed, got $status: $out"
  assert_not_contains "$(calls "$w")" "install-herdr" "a re-run keeps the installed Herdr"
  assert_not_contains "$(calls "$w")" "integration install" "a re-run keeps a current integration"
  assert_contains "$out" "already runs on herdr" "a re-run says the runtime was left as it is"
  for rc in $(profile_files); do
    [ "$(grep -c '.local/bin' "$w/home/$rc")" -eq 1 ] || fail "a re-run duplicated the PATH line in $rc"
  done
  pass "a fresh home gets Herdr, its Claude integration and the Herdr runtime, and a re-run changes nothing"
}

test_a_usable_herdr_is_kept_and_an_old_one_replaced() {
  local w out status
  w=$(make_world present)
  write_fake_herdr "$w/fakebin"
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "setup with Herdr present should succeed, got $status: $out"
  assert_not_contains "$(calls "$w")" "install-herdr" "a Herdr that passes the version gate is kept"
  assert_contains "$out" "Herdr 0.9.5 already present" "the kept Herdr is named"
  for rc in $(profile_files); do
    [ ! -e "$w/home/$rc" ] || fail "a Herdr outside ~/.local/bin should not add a PATH line to $rc"
  done

  w=$(make_world earlier-install)
  write_fake_herdr "$w/home/.local/bin"
  out=$(run_setup "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "setup with an earlier ~/.local/bin Herdr should succeed, got $status: $out"
  assert_not_contains "$(calls "$w")" "install-herdr" "an earlier ~/.local/bin Herdr is kept"
  for rc in $(profile_files); do
    assert_contains "$(cat "$w/home/$rc" 2>/dev/null)" '.local/bin' "a kept ~/.local/bin Herdr is found by new terminals through $rc"
  done

  w=$(make_world old)
  write_fake_herdr "$w/old"
  out=$(PATH="$w/home/.local/bin:$w/fakebin:$w/old" HOME="$w/home" FAKE_WORLD="$w" FM_HOME="$w/fmhome" \
    FM_HERDR_SETUP_INSTALLER="$w/install-herdr" FAKE_HERDR_PROTOCOL=13 bash "$SETUP" 2>&1)
  status=$?
  [ "$status" -eq 1 ] || fail "a still-too-old herdr on PATH after install should fail, got $status: $out"
  assert_contains "$(calls "$w")" "install-herdr $w/home/.local/bin" "a Herdr below the protocol floor is replaced"
  assert_contains "$out" "does not pass the version check" "the failure says the herdr found is still too old"
  pass "a Herdr that passes the adapter's version gate is kept, one in ~/.local/bin gets the PATH line, and one below the gate gets the pinned release"
}

test_a_configured_home_keeps_its_runtime() {
  local w out
  w=$(make_world tmux-home)
  mkdir -p "$w/fmhome/config"
  printf 'tmux\n' > "$w/fmhome/config/backend"
  out=$(run_setup "$w") || fail "setup on a tmux home should succeed: $out"
  assert_equals tmux "$(cat "$w/fmhome/config/backend")" "a home that chose tmux keeps tmux"
  assert_contains "$out" "already runs on tmux" "the kept runtime is named"

  w=$(make_world used-home)
  mkdir -p "$w/fmhome/state"
  : > "$w/fmhome/state/.lock"
  out=$(run_setup "$w") || fail "setup on a home that already ran should succeed: $out"
  [ ! -e "$w/fmhome/config/backend" ] || fail "a home that already ran on the default runtime was switched"
  assert_contains "$out" "echo herdr > $w/fmhome/config/backend" "the note says how to move it to Herdr"
  pass "a home that names a runtime, or already ran without one, is never switched"
}

test_failures_and_usage() {
  local w out status
  w=$(make_world install-fails)
  out=$(FAKE_INSTALL_FAILS=1 run_setup "$w")
  status=$?
  [ "$status" -eq 1 ] || fail "a failed install should exit 1, got $status: $out"
  assert_contains "$out" "installing Herdr failed" "the failed step is named"
  [ ! -e "$w/fmhome/config/backend" ] || fail "a failed setup must not set the runtime"

  w=$(make_world quiet)
  out=$(run_setup "$w" --quiet) || fail "--quiet setup failed: $out"
  assert_not_contains "$out" "bin/fm-primary.sh opus" "--quiet prints no start instructions"
  out=$(run_setup "$w" --bogus)
  status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument should exit 2, got $status: $out"
  pass "a failed install stops before the runtime is set, --quiet drops the closing text, and a bad argument is a usage error"
}

test_fresh_home_gets_herdr_its_integration_and_the_runtime
test_a_usable_herdr_is_kept_and_an_old_one_replaced
test_a_configured_home_keeps_its_runtime
test_failures_and_usage

#!/usr/bin/env bash
# Behavior tests for bin/fm-first-hour.sh, the first-hour checklist that ticks
# each step off from evidence on the machine as the step completes.
#
# The tools it asks (brew, node, npm, jq, claude, gh) are PATH stubs under a
# narrow PATH pin, and the toolchain check is the script's own test seam, so a
# case changes nothing on the host and every tick comes from the case's own
# fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKLIST="$ROOT/bin/fm-first-hour.sh"
TMP_ROOT=$(fm_test_tmproot fm-first-hour)

# make_world <name>: an empty home and a stub toolchain in which nothing is
# installed yet. Echoes the case directory.
make_world() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/fmhome" "$dir/tools"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_real_tool "$fakebin" bash sh env cat grep sed awk head mkdir ls \
    dirname uname git sleep tr cut perl python3 mktemp rm || fail "a basic tool is missing on this host"
  cat > "$dir/bootstrap" <<'SH'
#!/usr/bin/env bash
[ -e "$FAKE_WORLD/tools-installed" ] && exit 0
echo "needs: treehouse (install)"
exit 1
SH
  chmod +x "$dir/bootstrap"
  printf '%s\n' "$dir"
}

# install_tools <world>: the state the setup command leaves behind.
install_tools() {
  local dir=$1 tool
  for tool in brew jq node npm; do
    printf '#!/usr/bin/env bash\necho %s 1.0.0\n' "$tool" > "$dir/tools/$tool"
  done
  cat > "$dir/tools/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in
  --version) echo "2.9.0 (Claude Code)" ;;
  "auth status")
    if [ -e "$FAKE_WORLD/claude-signed-in" ]; then echo '{"loggedIn": true}'; else echo '{"loggedIn": false}'; exit 1; fi ;;
esac
SH
  cat > "$dir/tools/gh" <<'SH'
#!/usr/bin/env bash
[ "$*" = "auth status" ] && [ -e "$FAKE_WORLD/gh-signed-in" ]
SH
  chmod +x "$dir/tools/"*
  : > "$dir/tools-installed"
}

# The optional steps read Tailscale, the SSH port, the Deepgram key and the
# spoken voice; each is pinned to the case's own fixture, so the host's real
# Tailscale, Remote Login, keys and config/speak never reach a case.
run_checklist() {  # <world> [args...]
  local dir=$1
  shift
  env -u DEEPGRAM_API_KEY -u FM_SPEAK_SHAPER -u GLASSES_ANNOUNCE_CONFIG \
    PATH="$dir/fakebin:$dir/tools" FAKE_WORLD="$dir" FM_HOME="$dir/fmhome" \
    FM_FIRST_HOUR_BOOTSTRAP="$dir/bootstrap" \
    FM_FIRST_HOUR_TAILSCALE="${FAKE_TAILSCALE:-$dir/no-tailscale}" \
    FM_FIRST_HOUR_SSH_PORT="${FAKE_SSH_PORT:-$CLOSED_PORT}" \
    FM_SPEAK_SAY="$dir/tools/say" bash "$CHECKLIST" "$@" 2>&1
}

# A port nothing listens on: bound and released, so a connect is refused.
CLOSED_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

test_blank_machine_has_nothing_ticked() {
  local w out status
  w=$(make_world blank)
  out=$(run_checklist "$w")
  status=$?
  [ "$status" -eq 1 ] || fail "an unfinished checklist should exit 1, got $status: $out"
  assert_contains "$out" "Your first hour with Starship: 0 of 12 done" "a blank machine has nothing done"
  assert_contains "$out" "  [ ] Homebrew, Node and jq" "the prerequisites are the first step"
  assert_contains "$out" "Next: Homebrew, Node and jq - " "the next step is the prerequisites"
  assert_contains "$out" "| bash" "the next step names the one setup command"
  pass "a blank machine shows every step open and sends the person to the setup command first"
}

test_each_step_ticks_itself_off_as_its_evidence_appears() {
  local w out addon
  w=$(make_world progress)
  install_tools "$w"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] Homebrew, Node and jq" "installed prerequisites tick off"
  assert_contains "$out" "  [x] Claude Code" "an installed Claude Code ticks off"
  assert_contains "$out" "  [x] Starship's tools" "an installed toolchain ticks off"
  assert_contains "$out" "Next: Signed in to GitHub - in a new terminal window, run: gh auth login" \
    "the next step after the setup is the GitHub sign-in"

  : > "$w/gh-signed-in"
  : > "$w/claude-signed-in"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] Signed in to GitHub" "the GitHub sign-in ticks off"
  assert_contains "$out" "  [x] Signed in to Claude" "the Claude sign-in ticks off"
  assert_contains "$out" "Next: First mate started - " "the next step is starting the first mate"

  mkdir -p "$w/fmhome/state" "$w/fmhome/data"
  : > "$w/fmhome/state/session.lock"
  printf '# Captain preferences\n\n## Address and tone\n- Call me: Sam\n- Tone: keep the defaults\n' \
    > "$w/fmhome/data/captain.md"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] First mate started" "a home with state ticks off the first start"
  assert_contains "$out" "  [x] Your name, and how you like to be talked to" "a recorded name ticks off"
  assert_contains "$out" "  [ ] What you'd like help with" "an unanswered question stays open"

  printf '\n## What matters\n- New in the team; a report on my own tickets (2026-11-20)\n\n## Standing rules\n- Nothing merges without my word.\n' \
    >> "$w/fmhome/data/captain.md"
  addon="$w/fmhome/projects/my-addon"
  mkdir -p "$addon/.git" "$w/fmhome/config"
  printf 'path = projects/my-addon\norigin = https://github.com/example/my-addon\n' > "$w/fmhome/config/addon"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] What you'd like help with" "a recorded answer ticks off"
  assert_contains "$out" "  [x] House rules" "recorded rules tick off"
  assert_contains "$out" "  [x] Your private repository" "a configured private repository ticks off"
  assert_contains "$out" "  [ ] Your first project" "the private repository never counts as the first project"

  git init -q "$w/fmhome/projects/my-work"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [ ] Your first project" "a project with no commit yet cannot take a worker, so it stays open"
  git -C "$w/fmhome/projects/my-work" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m start
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] Your first project" "a project with a first commit ticks off"
  mkdir -p "$w/fmhome/data/first-report"
  : > "$w/fmhome/data/first-report/report.md"
  out=$(run_checklist "$w")
  status=$?
  [ "$status" -eq 0 ] || fail "a finished checklist should exit 0, got $status: $out"
  assert_contains "$out" "12 of 12 done" "every step is done"
  assert_contains "$out" "All done: you are set up." "a finished checklist says so"
  assert_not_contains "$out" "Next:" "a finished checklist has no next step"
  pass "each step ticks itself off as its evidence appears, in order, ending with the first report"
}

test_a_name_left_blank_does_not_tick() {
  local w out
  w=$(make_world blank-name)
  mkdir -p "$w/fmhome/data"
  printf '## Address and tone\n- Call me:\n- Tone: keep the defaults\n' > "$w/fmhome/data/captain.md"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [ ] Your name, and how you like to be talked to" \
    "a Call me line with no name is not a recorded name"
  pass "a Call me line with no name leaves the name step open"
}

test_a_plain_folder_in_a_cloned_home_is_not_a_project() {
  # A real home is itself a git clone of Starship with commits, so git run
  # inside a plain folder under projects/ walks up and finds the home's own
  # HEAD. Only the folder's own repository, with its own first commit, may
  # tick the first project; a folder made before `git init`, or one whose
  # clone failed, is not a project a worker can be dispatched into.
  local w out
  w=$(make_world cloned-home)
  git init -q "$w/fmhome"
  git -C "$w/fmhome" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m home
  mkdir -p "$w/fmhome/projects/my-work"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [ ] Your first project" "a plain folder inside a cloned home is not a project"
  git init -q "$w/fmhome/projects/my-work"
  git -C "$w/fmhome/projects/my-work" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m start
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] Your first project" "the folder's own first commit ticks it off"
  pass "inside a cloned home, only a project's own repository with a first commit counts as the first project"
}

test_watch_redraws_until_done_and_usage() {
  local w out status
  w=$(make_world watch)
  install_tools "$w"
  out=$(run_checklist "$w" --watch 0)
  status=$?
  [ "$status" -eq 2 ] || fail "--watch 0 should be a usage error, got $status: $out"
  out=$(run_checklist "$w" --bogus)
  status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument should be a usage error, got $status: $out"

  # A finished checklist under --watch prints once and exits 0.
  : > "$w/gh-signed-in"; : > "$w/claude-signed-in"
  mkdir -p "$w/fmhome/state" "$w/fmhome/data/r" "$w/fmhome/projects/my-addon/.git" "$w/fmhome/config"
  git init -q "$w/fmhome/projects/p"
  git -C "$w/fmhome/projects/p" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m start
  : > "$w/fmhome/state/x"; : > "$w/fmhome/data/r/report.md"
  printf 'path = projects/my-addon\norigin = https://github.com/example/my-addon\n' > "$w/fmhome/config/addon"
  printf '## Address and tone\n- Call me: Sam\n## What matters\n- Reports\n## Standing rules\n- Ask first\n' > "$w/fmhome/data/captain.md"
  out=$(run_checklist "$w" --watch 1)
  status=$?
  [ "$status" -eq 0 ] || fail "--watch on a finished checklist should exit 0, got $status: $out"
  assert_contains "$out" "All done: you are set up." "--watch shows the finished list before it exits"
  pass "--watch exits as soon as every step is done, and a bad interval or argument is a usage error"
}

test_the_optional_steps_guide_and_tick_without_being_counted() {
  local w out status port listener
  w=$(make_world optional)
  out=$(run_checklist "$w")
  assert_contains "$out" "Joining a teammate's Starship (optional, not counted above):" "the teammate group is shown"
  assert_contains "$out" "  [ ] Tailscale - install Tailscale from tailscale.com/download" \
    "a machine without Tailscale is sent to install it"
  assert_contains "$out" "  [ ] Remote Login (SSH) - turn on Remote Login in System Settings, General, Sharing" \
    "Remote Login off says where to turn it on"
  assert_contains "$out" "  [ ] Deepgram key - for speech-to-text and the spoken voice" "a missing Deepgram key is a guided step"
  assert_contains "$out" "  [ ] Spoken voice - spoken replies are not turned on" "an unarmed voice says so"
  assert_contains "$out" "0 of 12 done" "the optional steps are never counted"

  cat > "$w/tailscale" <<'SH'
#!/usr/bin/env bash
[ "$*" = "status --json" ] || exit 64
cat "$FAKE_WORLD/tailscale.json"
SH
  chmod +x "$w/tailscale"
  printf '{"BackendState": "Stopped"}\n' > "$w/tailscale.json"
  out=$(FAKE_TAILSCALE="$w/tailscale" run_checklist "$w")
  assert_contains "$out" "  [ ] Tailscale - open the inviter's invite link and sign in with a personal account, not a Google login on a company domain" \
    "a signed-out Tailscale explains which account to use"
  assert_contains "$out" "join the inviter's tailnet rather than creating a new one" "it says to join, not create"
  printf '{"BackendState": "Running", "Self": {"DNSName": "this-mac.example-tailnet.ts.net."}}\n' > "$w/tailscale.json"
  out=$(FAKE_TAILSCALE="$w/tailscale" run_checklist "$w")
  assert_contains "$out" "  [x] Tailscale - connected, on the tailnet example-tailnet.ts.net: check its addresses end the same way as those on the inviter's Machines page" \
    "a connected Tailscale ticks and names the tailnet to compare"
  assert_contains "$out" "ask the inviter to check this Mac shows there" "it asks for the Machines page check"

  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  python3 -c 'import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8); time.sleep(30)' "$port" &
  listener=$!
  sleep 0.5
  out=$(FAKE_SSH_PORT=$port run_checklist "$w")
  kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
  assert_contains "$out" "  [x] Remote Login (SSH)" "an answering SSH port ticks Remote Login"

  printf 'DEEPGRAM_API_KEY=dg-test-key\n' > "$w/fmhome/.env"
  mkdir -p "$w/fmhome/config"
  printf 'enabled = true\nshaper = shaper\n' > "$w/fmhome/config/speak"
  printf '#!/usr/bin/env bash\necho "needs Python 3.11 or newer" >&2\nexit 1\n' > "$w/fmhome/shaper"
  chmod +x "$w/fmhome/shaper"
  out=$(run_checklist "$w")
  assert_contains "$out" "  [x] Deepgram key - " "a key in the home's .env ticks the Deepgram step"
  assert_not_contains "$out" "dg-test-key" "the key itself is never printed"
  assert_contains "$out" "  [ ] Spoken voice - the shaper's dry run failed (exit 1): needs Python 3.11 or newer" \
    "a failing shaper is named instead of speech silently doing nothing"
  printf '#!/usr/bin/env bash\nshift\nprintf "%%s\\n" "$*"\n' > "$w/fmhome/shaper"
  out=$(run_checklist "$w")
  status=$?
  assert_contains "$out" "  [x] Spoken voice" "a shaper that runs ticks the spoken voice"
  [ "$status" -eq 1 ] || fail "ticked optional steps must not finish the checklist, got $status"
  pass "the optional Tailscale, Remote Login, Deepgram and spoken-voice steps guide and tick, and are never counted"
}

test_blank_machine_has_nothing_ticked
test_the_optional_steps_guide_and_tick_without_being_counted
test_each_step_ticks_itself_off_as_its_evidence_appears
test_a_name_left_blank_does_not_tick
test_watch_redraws_until_done_and_usage
test_a_plain_folder_in_a_cloned_home_is_not_a_project

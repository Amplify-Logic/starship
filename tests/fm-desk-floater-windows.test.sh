#!/usr/bin/env bash
# Behavior tests for the Windows desk floater's WSL side
# (bin/fm-desk-floater-windows.sh and bin/fm-desk-play-windows.sh), its
# Windows player in bin/fm-speak.sh, and its C# decisions
# (desk-floater-windows/SelfTest.cs) where a C# compiler is reachable.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WIN="$ROOT/bin/fm-desk-floater-windows.sh"
PLAY="$ROOT/bin/fm-desk-play-windows.sh"
SPEAK="$ROOT/bin/fm-speak.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk-floater-windows)

# Ambient captain keys and state overrides must not leak into these fixtures.
unset DEEPGRAM_API_KEY DEEPGRAM_STT_MODEL FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DEEPGRAM_AFPLAY || true
export FM_DEEPGRAM_ENV_FILE=/dev/null
export FM_DESK_VOICE_RING_DELAYS=

# Every home gets a tmux stand-in, so no case can reach a real tmux server on
# the machine running the tests. It reports no server unless the case writes
# its focus-events setting to tmux-focus; the server started at the time in
# tmux-start-time.
new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  cat > "$home/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/tmux.log"
[ -e "$home/tmux-focus" ] || exit 1
case "\$1" in
  list-sessions) printf 'firstmate: 1 windows\n' ;;
  show-options)
    case "\$3" in
      @fm-focus-since) cat "$home/tmux-focus-since" 2>/dev/null ;;
      *) cat "$home/tmux-focus" ;;
    esac ;;
  display-message) [ "\$3" = '#{start_time}' ] && cat "$home/tmux-start-time" ;;
  set-option)
    case "\$3" in
      focus-events) printf '%s\n' "\$4" > "$home/tmux-focus" ;;
      @fm-focus-since) printf '%s\n' "\$4" > "$home/tmux-focus-since" ;;
    esac ;;
esac
EOF
  chmod +x "$home/bin/tmux"
  printf '%s\n' "$home"
}

# A Deepgram stand-in, as tests/fm-deepgram-desk.test.sh has it.
stt_says() {  # <home> <transcript> | <home> --fail
  local home=$1 code=200 body
  if [ "$2" = --fail ]; then
    code=502
    body='{"err_msg":"bad gateway"}'
  else
    body="{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"$2\"}]}]}}"
  fi
  printf '%s' "$body" > "$home/stt-body.json"
  cat > "$home/curl" <<EOF
#!/usr/bin/env bash
out=
prev=
for a in "\$@"; do
  [ "\$prev" != -o ] || out=\$a
  prev=\$a
done
cat "$home/stt-body.json" > "\$out"
printf '%s' "$code"
EOF
  chmod +x "$home/curl"
}

wav() {  # <path> <seconds>
  python3 - "$1" "$2" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(b"\0\0" * int(16000 * float(sys.argv[2])))
PY
}

bridge() {  # <home> <verb> [args...] -> stdout; standard input is passed through
  local home=$1
  shift
  HOME="$home" FM_HOME="$home" DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    PATH="$home/bin:$PATH" "$WIN" bridge "$@"
}

recordings_in() {  # <home>
  find "$1/state/desk-voice/recording" -name '*.wav' 2>/dev/null | wc -l | tr -d ' '
}

test_bridge_transcribes_and_holds_a_talk_recording_until_delivered() {
  local home out rec mailbox
  home=$(new_home talk)
  wav "$home/in.wav" 1
  stt_says "$home" "Merge the finances PR when it is green"
  mkdir -p "$home/state/desk-voice/windows-received/00000000old00000" "$home/state/desk-voice/windows-received/00000000new00000"
  touch -t 202001010000 "$home/state/desk-voice/windows-received/00000000old00000"
  out=$(bridge "$home" transcribe 0123abcd0123abcd firstmate < "$home/in.wav") || fail "transcribe failed: $out"
  [ ! -e "$home/state/desk-voice/windows-received/00000000old00000" ] || fail "a hand-over claim older than 30 days is pruned"
  [ -d "$home/state/desk-voice/windows-received/00000000new00000" ] || fail "a recent hand-over claim is kept"
  rec="$home/state/desk-voice/recording/0123abcd0123abcd-firstmate.wav"
  assert_equals "text	$rec	Merge the finances PR when it is green" "$out" "the words and the recording held for delivery"
  cmp -s "$home/in.wav" "$rec" || fail "the recording must arrive byte for byte"
  out=$(bridge "$home" transcribe 0123abcd0123abcd firstmate < "$home/in.wav") || fail "second hand-over failed: $out"
  assert_equals "known	0123abcd0123abcd" "$out" "a recording handed over twice is taken once"

  out=$(printf 'Merge the finances PR when it is green' | bridge "$home" deliver --recording "$rec" 2>/dev/null) \
    || fail "deliver failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "with no primary running the words go to the mailbox, got: $out" ;; esac
  mailbox=${out#mailbox: }
  assert_contains "$(cat "$mailbox")" "Merge the finances PR when it is green" "the mailbox holds the words"
  assert_contains "$(cat "$mailbox")" '"source": "desk-floater"' "the message comes from the floater"
  [ ! -e "$rec" ] || fail "a delivered recording is removed"
  pass "bridge transcribe/deliver: words go to Firstmate once and the recording goes with them"
}

test_bridge_dictation_returns_the_words_without_keeping_audio() {
  local home out
  home=$(new_home dictate)
  wav "$home/in.wav" 1
  stt_says "$home" "Dear Sam, thanks for the notes"
  out=$(bridge "$home" transcribe abcdef0123456789 dictate < "$home/in.wav") || fail "transcribe failed: $out"
  assert_equals "text	-	Dear Sam, thanks for the notes" "$out" "dictated words come back for pasting"
  [ "$(recordings_in "$home")" = 0 ] || fail "a transcribed dictation keeps no audio"
  out=$(printf 'Dear Sam' | bridge "$home" dictate 2>/dev/null) || fail "dictate failed: $out"
  assert_equals not-in-front "$out" "with no primary in front, dictation is left to paste"
  [ -z "$(find "$home/state/desk-voice/inbox" -name '*.json' 2>/dev/null)" ] || fail "dictation meant elsewhere must not land in the mailbox"
  pass "bridge transcribe/dictate: dictated words come back to paste where the cursor is"
}

test_bridge_keeps_a_recording_it_could_not_transcribe() {
  local home out saved path
  home=$(new_home keep)
  wav "$home/long.wav" 3
  stt_says "$home" --fail
  out=$(bridge "$home" transcribe 1111aaaa2222bbbb firstmate < "$home/long.wav" 2>/dev/null) || fail "transcribe failed: $out"
  case "$out" in "saved	$home/state/desk-voice/unsent/"*.wav) ;; *) fail "a failed transcription is saved, got: $out" ;; esac
  saved=${out#saved	}
  assert_contains "$(cat "${saved%.wav}.json")" '"last_reason": "transcription failed"' "the reason is kept"
  stt_says "$home" ""
  out=$(bridge "$home" transcribe 3333aaaa4444bbbb dictate < "$home/long.wav") || fail "transcribe failed: $out"
  case "$out" in "saved	"*) ;; *) fail "three seconds with no words are kept, got: $out" ;; esac
  path=${out#saved	}
  cmp -s "$home/long.wav" "$path" || fail "the saved audio is the recording"
  assert_contains "$(cat "${path%.wav}.json")" '"purpose": "dictate"' "a dictation is saved as one"
  wav "$home/short.wav" 0.3
  out=$(bridge "$home" transcribe 5555aaaa6666bbbb firstmate < "$home/short.wav" 2>/dev/null) || fail "transcribe failed: $out"
  assert_equals "nothing	no-speech" "$out" "a stray press with no words is dropped"
  stt_says "$home" --fail
  out=$(bridge "$home" transcribe 7777aaaa8888bbbb firstmate < "$home/short.wav" 2>/dev/null) || fail "transcribe failed: $out"
  assert_equals "nothing	transcribe-failed" "$out" "a press too short to hold a word is dropped"
  [ "$(recordings_in "$home")" = 0 ] || fail "nothing is left in the recording folder"
  out=$(bridge "$home" recover) || fail "recover failed: $out"
  assert_equals "retry	$saved	1" "$out" "only the saved talk-to-Firstmate recording is retried"
  pass "bridge transcribe: a recording worth keeping is saved for retry, a stray press is dropped"
}

test_bridge_keeps_recordings_when_delivery_fails() {
  local home out rec
  home=$(new_home deliver-fails)
  wav "$home/in.wav" 1
  stt_says "$home" "Ship it"
  out=$(bridge "$home" transcribe 9999aaaa0000bbbb firstmate < "$home/in.wav") || fail "transcribe failed: $out"
  rec=$(printf '%s' "$out" | cut -f2)
  # A mailbox that cannot be written is a delivery that fails: a python3
  # stand-in refuses to write the mailbox record and runs everything else.
  cat > "$home/bin/python3" <<EOF
#!/usr/bin/env bash
script=\$(mktemp)
cat > "\$script"
if grep -q fm-desk-voice-transcript.v1 "\$script"; then rm -f "\$script"; exit 1; fi
"$(command -v python3)" "\$script" "\${@:2}"
status=\$?
rm -f "\$script"
exit \$status
EOF
  chmod +x "$home/bin/python3"
  out=$(printf 'Ship it' | bridge "$home" deliver --recording "$rec" 2>/dev/null) || fail "deliver failed: $out"
  rm -f "$home/bin/python3"
  case "$out" in
    "saved	$home/state/desk-voice/unsent/"*".wav
failed") ;;
    *) fail "an undelivered message keeps its recording, got: $out" ;;
  esac
  [ ! -e "$rec" ] || fail "the kept recording moved to the unsent folder"
  local status=0
  out=$(printf 'x' | bridge "$home" deliver --recording /etc/passwd 2>&1) || status=$?
  [ "$status" = 2 ] || fail "only recordings in the home's recording folder may be named, got $status: $out"
  pass "bridge deliver: a message that cannot be delivered keeps its recording for retry"
}

test_bridge_adopts_and_recovers_left_recordings() {
  local home out
  home=$(new_home adopt)
  wav "$home/in.wav" 2
  out=$(bridge "$home" adopt aaaa1111bbbb2222 firstmate < "$home/in.wav") || fail "adopt failed: $out"
  case "$out" in "saved	$home/state/desk-voice/unsent/"*.wav) ;; *) fail "an adopted recording is saved, got: $out" ;; esac
  assert_equals "known	aaaa1111bbbb2222" "$(bridge "$home" adopt aaaa1111bbbb2222 firstmate < "$home/in.wav")" \
    "an adopted recording is taken once"
  wav "$home/state/desk-voice/recording/cccc3333dddd4444-firstmate.wav" 2
  wav "$home/state/desk-voice/recording/eeee5555ffff6666-dictate.wav" 0.2
  touch -t 202001010000 "$home/state/desk-voice/recording/"*.wav
  wav "$home/state/desk-voice/recording/fresh0000fresh00-firstmate.wav" 2
  out=$(bridge "$home" recover) || fail "recover failed: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^retry	')" = 2 ] || fail "the adopted and the left recording are retried, got: $out"
  [ -e "$home/state/desk-voice/recording/fresh0000fresh00-firstmate.wav" ] || fail "a recording still arriving is left alone"
  [ ! -e "$home/state/desk-voice/recording/eeee5555ffff6666-dictate.wav" ] || fail "a left stray press is dropped"
  local status=0
  bridge "$home" transcribe ../../etc firstmate < "$home/in.wav" >/dev/null 2>&1 || status=$?
  [ "$status" = 2 ] || fail "a recording id with path characters is refused, got $status"
  status=0
  bridge "$home" transcribe aaaa1111bbbb9999 other < "$home/in.wav" >/dev/null 2>&1 || status=$?
  [ "$status" = 2 ] || fail "an unknown purpose is refused, got $status"
  pass "bridge adopt/recover: recordings that missed Ubuntu or a stopped floater are kept and retried"
}

test_bridge_turns_on_tmux_focus_events_for_dictation() {
  local home out
  home=$(new_home focus)
  out=$(bridge "$home" hello) || fail "hello without a tmux server failed: $out"
  assert_contains "$out" "version	" "hello reports the version with no tmux server running"
  printf 'off\n' > "$home/tmux-focus"
  bridge "$home" hello >/dev/null || fail "hello failed"
  assert_equals on "$(cat "$home/tmux-focus")" "hello turns focus-events on in a running tmux server"
  grep -Eqx '[0-9]{10,}' "$home/tmux-focus-since" \
    || fail "the time focus tracking began is kept for the dictation check: $(cat "$home/tmux-focus-since" 2>&1)"
  printf 'off\n' > "$home/tmux-focus"
  printf 'Dear Sam' | bridge "$home" dictate >/dev/null 2>&1 || fail "dictate failed"
  assert_equals on "$(cat "$home/tmux-focus")" "dictate turns it on too"
  : > "$home/tmux.log"
  bridge "$home" hello >/dev/null || fail "hello failed"
  assert_no_grep set-option "$home/tmux.log" "an option already on is left alone"

  # focus-events already on with nothing recorded: the server's start counts
  # only when ~/.tmux.conf turned it on before the server started.
  printf 'on\n' > "$home/tmux-focus"
  printf '1700000000\n' > "$home/tmux-start-time"
  printf 'set -g mouse on\nset -g focus-events on\n' > "$home/.tmux.conf"
  touch -t 202001010000 "$home/.tmux.conf"
  rm -f "$home/tmux-focus-since"
  bridge "$home" hello >/dev/null || fail "hello failed"
  assert_equals 1700000000 "$(cat "$home/tmux-focus-since")" \
    "a server that started with focus-events on tracks focus from its start"
  printf '1000\n' > "$home/tmux-start-time"
  rm -f "$home/tmux-focus-since"
  printf 'Dear Sam' | bridge "$home" dictate >/dev/null 2>&1 || fail "dictate failed"
  grep -Eqx '[0-9]{10,}' "$home/tmux-focus-since" \
    || fail "a tmux config changed after the server started counts from now: $(cat "$home/tmux-focus-since" 2>&1)"
  printf '1700000000\n' > "$home/tmux-start-time"
  printf '# set -g focus-events on\n' > "$home/.tmux.conf"
  touch -t 202001010000 "$home/.tmux.conf"
  rm -f "$home/tmux-focus-since"
  bridge "$home" hello >/dev/null || fail "hello failed"
  [ "$(cat "$home/tmux-focus-since")" -gt 1700000000 ] \
    || fail "focus-events turned on some other way counts from now: $(cat "$home/tmux-focus-since" 2>&1)"
  pass "bridge hello/dictate: tmux keeps track of which terminal has focus"
}

test_bridge_shot_and_speak_reach_the_shared_scripts() {
  local home out
  home=$(new_home shot)
  printf '\211PNG\r\n\032\nimage' > "$home/in.png"
  out=$(bridge "$home" shot < "$home/in.png") || fail "shot failed: $out"
  case "$out" in "$home/state/desk-voice/shots/"*.png) ;; *) fail "the screenshot lands in the home's shots, got: $out" ;; esac
  assert_equals unmuted "$(bridge "$home" speak --muted)" "speak controls reach bin/fm-speak.sh"
  bridge "$home" speak --mute >/dev/null || fail "mute failed"
  assert_equals muted "$(bridge "$home" speak --muted)" "and act on this home"
  assert_equals "$("$WIN" version)" "$(bridge "$home" version)" "the bridge reports the source version"
  assert_equals "version	$("$WIN" version)" "$(bridge "$home" hello)" "the floater's check-in reports it too"
  local status=0
  bridge "$home" launch-rockets >/dev/null 2>&1 || status=$?
  [ "$status" = 2 ] || fail "an unknown verb is refused, got $status"
  pass "bridge shot/speak/version: screenshots and voice controls use the shared scripts"
}

# A Windows stand-in: cmd.exe answers the folders, wslpath maps them into the
# fixture, csc.exe "builds" a stand-in floater that logs how it was called,
# and reg.exe, tasklist.exe and powershell.exe log theirs.
windows_fixture() {  # <home>
  local home=$1 win="$1/win" bin="$1/bin"
  mkdir -p "$win/Windows/Microsoft.NET/Framework64/v4.0.30319" "$win/Users/ana/AppData/Local"
  cat > "$bin/cmd.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/cmd.log"
case "\$*" in
  *'echo %LOCALAPPDATA%'*) printf 'C:\\\\Users\\\\ana\\\\AppData\\\\Local\r\n' ;;
  *'echo %SystemRoot%'*) printf 'C:\\\\Windows\r\n' ;;
  *) printf '%%%s%%\r\n' unknown ;;
esac
EOF
  cat > "$bin/wslpath" <<EOF
#!/usr/bin/env bash
[ "\$1" = -u ] || exit 1
p=\${2#C:}
printf '%s%s\n' "$win" "\$(printf '%s' "\$p" | tr '\\\\' /)"
EOF
  cat > "$win/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/csc.log"
out=
for a in "\$@"; do case "\$a" in /out:*) out=\${a#/out:} ;; esac; done
[ ! -e "$home/csc-fails" ] || { echo 'src\\Floater.cs(1,1): error CS1002: ; expected'; exit 1; }
cat > "\$out" <<'EXE'
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$(dirname "\$0")/exe.log"
case "\${1:-}" in
  --play) [ ! -e "\$(dirname "\$0")/slow-play" ] || sleep 30 ;;
esac
exit 0
EXE
chmod +x "\$out"
EOF
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/reg.log"\n' "$home" > "$bin/reg.exe"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/tasklist.exe"
  cat > "$bin/powershell.exe" <<EOF
#!/usr/bin/env bash
printf 'started %s: %s\n' "\$PWD" "\$*" >> "$home/started.log"
EOF
  chmod +x "$bin/cmd.exe" "$bin/wslpath" "$bin/reg.exe" "$bin/tasklist.exe" "$bin/powershell.exe" \
    "$win/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
}

win() {  # <home> <args...>
  local home=$1
  shift
  HOME="$home" FM_HOME="$home" WSL_DISTRO_NAME=Ubuntu-24.04 PATH="$home/bin:$PATH" "$WIN" "$@"
}

test_install_builds_registers_and_starts_the_floater() {
  local home out dir
  home=$(new_home install)
  windows_fixture "$home"
  printf 'set -g mouse on\n' > "$home/.tmux.conf"
  out=$(win "$home" install) || fail "install failed: $out"
  dir="$home/win/Users/ana/AppData/Local/Starship/Floater"
  assert_contains "$out" 'installed and started: C:\Users\ana\AppData\Local\Starship\Floater\StarshipFloater.exe' "install says where"
  [ -x "$dir/StarshipFloater.exe" ] || fail "the floater is built into LOCALAPPDATA"
  cmp -s "$ROOT/desk-floater-windows/Floater.cs" "$dir/src/Floater.cs" || fail "the sources are copied beside it"
  [ ! -e "$dir/src/SelfTest.cs" ] || fail "the self-test is not part of the floater"
  assert_contains "$(cat "$home/csc.log")" "/target:winexe" "it is built as a windowed app"
  assert_contains "$(cat "$home/csc.log")" 'src\Logic.cs src\Floater.cs' "from the floater's sources"
  assert_equals "distro=Ubuntu-24.04
root=$ROOT
home=$home
version=$("$WIN" version)" "$(tr -d '\r' < "$dir/floater.ini")" "floater.ini names this distribution, code and home"
  assert_contains "$(cat "$home/reg.log")" 'add HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v StarshipFloater /t REG_SZ /d "C:\Users\ana\AppData\Local\Starship\Floater\StarshipFloater.exe" /f' \
    "it starts with Windows, for this user only"
  assert_contains "$(cat "$home/started.log")" "started $dir" "it is started from its own folder"
  assert_contains "$(cat "$home/started.log")" "Start-Process -FilePath 'C:\Users\ana\AppData\Local\Starship\Floater\StarshipFloater.exe'" \
    "it is started apart from this WSL session, so install returns"
  assert_contains "$(cat "$home/state/desk-floater-windows/install")" "linux_dir=$dir" "the install is recorded for the player"
  assert_contains "$(cat "$home/.tmux.conf")" "set -g focus-events on" "tmux tracks focus from its next start"
  assert_equals "installed: yes
version: current
running: no" "$(win "$home" status)" "status reports a current install"

  : > "$dir/exe.log"
  out=$(win "$home" install --no-start) || fail "reinstall failed: $out"
  [ -x "$dir/StarshipFloater.exe" ] && [ -e "$dir/StarshipFloater.old.exe" ] || fail "a reinstall moves the running floater aside"
  [ ! -s "$dir/exe.log" ] || fail "--no-start leaves the running floater alone: $(cat "$dir/exe.log")"
  out=$(win "$home" install) || fail "second reinstall failed: $out"
  assert_contains "$(cat "$dir/exe.log")" "--quit" "a reinstall that starts the floater asks the running one to quit first"
  : > "$home/csc-fails"
  local status=0
  out=$(win "$home" install 2>&1) || status=$?
  [ "$status" = 1 ] || fail "a failed build fails the install, got $status"
  assert_contains "$out" "error CS1002" "the compiler's own words are shown"
  [ -x "$dir/StarshipFloater.exe" ] || fail "a failed build leaves the installed floater in place"
  rm -f "$home/csc-fails"
  sed -i.bak 's/^version=.*/version=old/' "$home/state/desk-floater-windows/install"
  assert_contains "$(win "$home" status)" "version: stale" "status notices sources newer than the build"
  assert_equals 1 "$(grep -c 'focus-events' "$home/.tmux.conf")" "reinstalls add focus-events to tmux's config once"

  out=$(win "$home" uninstall) || fail "uninstall failed: $out"
  [ ! -e "$dir" ] || fail "uninstall removes the floater's folder"
  [ ! -e "${dir%/Floater}" ] || fail "and its Starship folder once empty"
  [ ! -e "$home/state/desk-floater-windows/install" ] || fail "uninstall removes the install record"
  assert_contains "$(cat "$home/reg.log")" 'delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v StarshipFloater /f' "and the startup entry"
  assert_equals "installed: no
version: unknown
running: unknown" "$(win "$home" status)" "status after uninstall"
  assert_equals "set -g mouse on" "$(cat "$home/.tmux.conf")" "uninstall takes back only its own tmux lines"
  printf 'set -g focus-events off\n' > "$home/.tmux.conf"
  win "$home" install --no-start >/dev/null || fail "install over an own focus-events line failed"
  assert_equals "set -g focus-events off" "$(cat "$home/.tmux.conf")" "a focus-events line of the teammate's own is left alone"
  rm -f "$home/.tmux.conf"
  win "$home" install --no-start >/dev/null || fail "install without a tmux config failed"
  win "$home" uninstall >/dev/null || fail "uninstall without a tmux config failed"
  [ ! -e "$home/.tmux.conf" ] || fail "a tmux config the install created is removed again: $(cat "$home/.tmux.conf")"
  printf 'set -g mouse on' > "$home/.tmux.conf"
  win "$home" install --no-start >/dev/null || fail "install over a tmux config without a final newline failed"
  assert_equals "set -g mouse on" "$(head -n 1 "$home/.tmux.conf")" "the teammate's last line stays whole"
  assert_equals "set -g focus-events on" "$(tail -n 1 "$home/.tmux.conf")" "focus-events goes on a line of its own"
  win "$home" uninstall >/dev/null || fail "uninstall failed"
  assert_equals "set -g mouse on" "$(cat "$home/.tmux.conf")" "uninstall finds and takes back its lines"
  pass "fm-desk-floater-windows install: builds with Windows' own compiler, starts with Windows, updates in place"
}

test_install_refuses_outside_wsl() {
  local home out status=0
  home=$(new_home outside)
  out=$(FM_HOME="$home" WSL_DISTRO_NAME='' "$WIN" install 2>&1) || status=$?
  [ "$status" = 1 ] || fail "install outside WSL fails, got $status"
  assert_contains "$out" "inside WSL 2" "and says where to run it"
  pass "fm-desk-floater-windows install: refuses to run outside WSL"
}

test_player_plays_through_the_floater_and_stops_on_term() {
  local home out dir pid i
  home=$(new_home player)
  windows_fixture "$home"
  win "$home" install --no-start >/dev/null || fail "install failed"
  dir="$home/win/Users/ana/AppData/Local/Starship/Floater"
  printf 'ID3audio' > "$home/line.mp3"
  : > "$dir/exe.log"
  FM_HOME="$home" "$PLAY" -v 0.40 "$home/line.mp3" || fail "playback failed"
  assert_contains "$(cat "$dir/exe.log")" "--play C:\\Users\\ana\\AppData\\Local\\Starship\\Floater\\play\\" "the line is played by the floater from its own folder"
  assert_contains "$(cat "$dir/exe.log")" "--volume 400" "at the set level"
  [ -z "$(ls "$dir/play")" ] || fail "the copy is removed after playing"
  : > "$dir/exe.log"
  FM_HOME="$home" "$PLAY" -v 1.50 "$home/line.mp3" || fail "playback failed"
  assert_contains "$(cat "$dir/exe.log")" "--volume 1000" "Windows plays no louder than its own volume"

  : > "$dir/slow-play"
  : > "$dir/exe.log"
  FM_HOME="$home" "$PLAY" "$home/line.mp3" &
  pid=$!
  for i in $(seq 1 50); do grep -q -- --play "$dir/exe.log" && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid" || fail "a stopped line still exits 0"
  assert_contains "$(cat "$dir/exe.log")" "--stop-playback" "a stop reaches Windows playback"
  rm -f "$dir/slow-play"
  local status=0
  out=$(FM_HOME="$(new_home no-floater)" "$PLAY" "$home/line.mp3" 2>&1) || status=$?
  [ "$status" = 1 ] || fail "with no floater installed playback fails, got $status"
  assert_contains "$out" "fm-desk-floater-windows.sh install" "and says how to install it"
  pass "fm-desk-play-windows: replies play through the Windows floater, at the set level, and stop on a stop"
}

test_speak_plays_through_windows_when_the_floater_is_installed() {
  local home dir i
  if [ -x /usr/bin/afplay ]; then
    pass "fm-speak Windows player: skipped where afplay exists (macOS keeps afplay)"
    return
  fi
  home=$(new_home speak)
  windows_fixture "$home"
  win "$home" install --no-start >/dev/null || fail "install failed"
  dir="$home/win/Users/ana/AppData/Local/Starship/Floater"
  printf 'enabled = true\n' > "$home/config/speak"
  printf '#!/usr/bin/env bash\nshift\nprintf "%%s\\n" "$*"\n' > "$home/shaper"
  cat > "$home/tts" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in --to) out=$2; shift 2 ;; *) shift ;; esac; done
printf 'ID3audio' > "$out"
EOF
  chmod +x "$home/shaper" "$home/tts"
  : > "$dir/exe.log"
  FM_HOME="$home" FM_SPEAK_SHAPER="$home/shaper" FM_SPEAK_DEEPGRAM_TTS="$home/tts" FM_SPEAK_SAY=/nonexistent \
    DEEPGRAM_API_KEY=test-key-not-real PATH="$home/bin:$PATH" "$SPEAK" "The build is green." >/dev/null \
    || fail "speak failed"
  for i in $(seq 1 50); do grep -q -- --play "$dir/exe.log" && break; sleep 0.1; done
  assert_contains "$(cat "$dir/exe.log")" "--play" "a reply is spoken through the Windows floater"
  pass "fm-speak: with the Windows floater installed and no afplay, replies play through Windows"
}

# The C# decisions are built and run where Windows' own compiler is reachable
# (inside WSL).
test_floater_csharp_self_test() {
  local csc out dir
  csc=/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe
  # tests/lib.sh drops WSL_DISTRO_NAME, so WSL is told by its kernel name.
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && [ -f "$csc" ] && command -v wslpath >/dev/null 2>&1; then
    dir=$(mktemp -d /mnt/c/Windows/Temp/fm-floater-test.XXXXXX 2>/dev/null) \
      || dir=$(mktemp -d "$(wslpath -u "$(cd /mnt/c && cmd.exe /d /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')")/fm-floater-test.XXXXXX") \
      || fail "no Windows folder to build the self-test in"
    cp "$ROOT/desk-floater-windows/Logic.cs" "$ROOT/desk-floater-windows/SelfTest.cs" "$dir/"
    out=$(cd "$dir" && "$csc" /nologo /target:exe /codepage:65001 /out:SelfTest.exe Logic.cs SelfTest.cs 2>&1) \
      || fail "the C# self-test did not build: $out"
    out=$(cd "$dir" && ./SelfTest.exe 2>&1 | tr -d '\r') || fail "C# self-test failed: $out"
    rm -rf "$dir"
    assert_contains "$out" "ok:" "the C# decisions hold"
    pass "Windows floater: C# self-test passes with Windows' own compiler ($out)"
    return
  fi
  pass "Windows floater: C# self-test skipped (needs WSL with Windows' .NET Framework compiler)"
}

test_bridge_transcribes_and_holds_a_talk_recording_until_delivered
test_bridge_dictation_returns_the_words_without_keeping_audio
test_bridge_keeps_a_recording_it_could_not_transcribe
test_bridge_keeps_recordings_when_delivery_fails
test_bridge_adopts_and_recovers_left_recordings
test_bridge_turns_on_tmux_focus_events_for_dictation
test_bridge_shot_and_speak_reach_the_shared_scripts
test_install_builds_registers_and_starts_the_floater
test_install_refuses_outside_wsl
test_player_plays_through_the_floater_and_stops_on_term
test_speak_plays_through_windows_when_the_floater_is_installed
test_floater_csharp_self_test

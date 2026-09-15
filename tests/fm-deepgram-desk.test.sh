#!/usr/bin/env bash
# Behavior tests for Deepgram desk speak preference and the desk-voice mailbox.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEAK="$ROOT/bin/fm-speak.sh"
TTS="$ROOT/bin/fm-deepgram-tts.sh"
STT="$ROOT/bin/fm-deepgram-stt.sh"
FLOATER="$ROOT/bin/fm-desk-floater.sh"
DESK="$ROOT/bin/fm-desk-voice.sh"
TMP_ROOT=$(fm_test_tmproot fm-deepgram-desk)

# Ambient captain keys must not leak into these fixtures.
unset DEEPGRAM_API_KEY || true
export FM_DEEPGRAM_ENV_FILE=/dev/null

new_home() {  # <name> [config-lines...]
  local name=$1
  shift
  mkdir -p "$TMP_ROOT/$name/config" "$TMP_ROOT/$name/state"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$TMP_ROOT/$name/config/speak"
  fi
  printf '%s\n' "$TMP_ROOT/$name"
}

install_shaper() {
  local home=$1
  cat > "$home/shaper" <<'EOF'
#!/usr/bin/env bash
# argv: --dry-run <text>
shift
printf '%s\n' "$*"
EOF
  chmod +x "$home/shaper"
}

install_speaker() {
  local home=$1
  cat > "$home/speaker" <<EOF
#!/usr/bin/env bash
printf 'argv: %s\n' "\$*" >> "$home/spoken.log"
prev=
for a in "\$@"; do
  [ "\$prev" != -f ] || printf 'text: %s\n' "\$(cat "\$a")" >> "$home/spoken.log"
  prev=\$a
done
exec sleep 0.5
EOF
  chmod +x "$home/speaker"
}

install_deepgram_tts_ok() {
  local home=$1
  cat > "$home/deepgram-tts" <<EOF
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --to) out=\$2; shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
printf 'mock-deepgram:%s\n' "\$*" >> "$home/deepgram.log"
if [ -n "\$out" ]; then
  printf 'dg' > "\$out"
fi
exit 0
EOF
  chmod +x "$home/deepgram-tts"
}

install_deepgram_tts_fail() {
  local home=$1
  cat > "$home/deepgram-tts" <<EOF
#!/usr/bin/env bash
printf 'mock-deepgram-fail\n' >> "$home/deepgram.log"
exit 1
EOF
  chmod +x "$home/deepgram-tts"
}

install_afplay() {
  local home=$1
  cat > "$home/afplay" <<EOF
#!/usr/bin/env bash
printf 'afplay: %s\n' "\$*" >> "$home/afplay.log"
exit 0
EOF
  chmod +x "$home/afplay"
}


wait_for_file() {  # <path> <msg>
  local path=$1 msg=$2 waited=0
  while [ "$waited" -lt 50 ]; do
    [ -f "$path" ] && return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$msg (timed out waiting for $path)"
}

# --- Deepgram TTS helper ----------------------------------------------------

test_tts_refuses_without_key() {
  local out status=0
  out=$(FM_DEEPGRAM_ENV_FILE=/dev/null env -u DEEPGRAM_API_KEY "$TTS" "hello" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 without a key, got $status: $out"
  assert_contains "$out" "DEEPGRAM_API_KEY" "missing-key diagnostic"
  pass "fm-deepgram-tts: refuses when the key is absent"
}

test_tts_dry_run_with_key() {
  local out
  out=$(DEEPGRAM_API_KEY=test-key-not-real "$TTS" --dry-run "Captain, checks are green." 2>&1) \
    || fail "dry-run with key should succeed: $out"
  assert_contains "$out" "model=" "dry-run names the model"
  assert_contains "$out" "chars=" "dry-run reports length"
  pass "fm-deepgram-tts: dry-run succeeds when a key is present"
}

# --- Deepgram STT helper ----------------------------------------------------

install_stt_curl() {  # <home> <http-code> <body>
  local home=$1 code=$2 body=$3
  printf '%s' "$body" > "$home/stt-body.json"
  cat > "$home/curl" <<EOF
#!/usr/bin/env bash
out=
prev=
for a in "\$@"; do
  [ "\$prev" != -o ] || out=\$a
  prev=\$a
done
printf 'curl-argv: %s\n' "\$*" >> "$home/curl.log"
cat "$home/stt-body.json" > "\$out"
printf '%s' "$code"
EOF
  chmod +x "$home/curl"
}

test_stt_refuses_without_key_or_file() {
  local home out status=0
  home=$(new_home stt-nokey)
  printf 'RIFF' > "$home/clip.wav"
  out=$(FM_DEEPGRAM_ENV_FILE=/dev/null env -u DEEPGRAM_API_KEY "$STT" "$home/clip.wav" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 without a key, got $status: $out"
  assert_contains "$out" "DEEPGRAM_API_KEY" "missing-key diagnostic"
  status=0
  out=$(DEEPGRAM_API_KEY=test-key-not-real "$STT" "$home/missing.wav" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 for a missing file, got $status: $out"
  assert_contains "$out" "not found" "missing-file diagnostic"
  pass "fm-deepgram-stt: refuses when the key or the audio file is absent"
}

test_stt_prints_transcript_from_mocked_deepgram() {
  local home out raw
  home=$(new_home stt-ok)
  printf 'RIFF' > "$home/clip.wav"
  install_stt_curl "$home" 200 \
    '{"results":{"channels":[{"alternatives":[{"transcript":"merge the finances pull request"}]}]}}'
  out=$(DEEPGRAM_API_KEY=super-secret-test-key FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/clip.wav" 2>&1) || fail "stt failed: $out"
  [ "$out" = "merge the finances pull request" ] || fail "unexpected transcript: $out"
  assert_contains "$(cat "$home/curl.log")" "model=nova-2" "default model reaches the request"
  assert_contains "$(cat "$home/curl.log")" "Content-Type: audio/wav" "wav content type"
  case "$(cat "$home/curl.log")" in
    *super-secret*) fail "key leaked into curl argv" ;;
  esac
  raw=$(DEEPGRAM_API_KEY=super-secret-test-key FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" --json "$home/clip.wav" 2>&1) || fail "stt --json failed: $raw"
  assert_contains "$raw" '"transcript"' "--json passes the raw body through"
  pass "fm-deepgram-stt: mocked Deepgram transcript is printed and the key stays out of argv"
}

test_stt_reports_http_failure() {
  local home out status=0
  home=$(new_home stt-fail)
  printf 'RIFF' > "$home/clip.wav"
  install_stt_curl "$home" 401 '{"err_msg":"invalid credentials"}'
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/clip.wav" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 on HTTP failure, got $status: $out"
  assert_contains "$out" "HTTP 401" "HTTP status is reported"
  pass "fm-deepgram-stt: a Deepgram failure exits 1 with the status"
}

# --- desk floater launcher -------------------------------------------------

test_floater_help_and_option_refusal() {
  local out status=0
  out=$("$FLOATER" --help 2>&1) || fail "--help should exit 0: $out"
  assert_contains "$out" "push-to-talk" "help names push-to-talk"
  assert_contains "$out" "DEEPGRAM_API_KEY" "help names the key source"
  out=$("$FLOATER" --bogus 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for an unknown option, got $status: $out"
  assert_contains "$out" "unexpected option" "unknown option is refused"
  pass "fm-desk-floater: --help exits 0 and unknown options are refused"
}

# --- fm-speak Deepgram preference ------------------------------------------

test_speak_uses_say_when_key_absent() {
  local home out
  home=$(new_home say-fallback "enabled = true")
  install_shaper "$home"
  install_speaker "$home"
  install_deepgram_tts_ok "$home"
  install_afplay "$home"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      FM_DEEPGRAM_ENV_FILE=/dev/null \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "The finances fix is green." 2>&1
  ) || fail "speak failed: $out"
  wait_for_file "$home/spoken.log" "say should have recorded the shaped line"
  assert_contains "$(cat "$home/spoken.log")" "finances fix" "say received the line"
  [ ! -f "$home/deepgram.log" ] || fail "deepgram should not run without a key"
  pass "fm-speak: key absent uses say"
}

test_speak_prefers_deepgram_when_key_present() {
  local home out
  home=$(new_home dg-prefer "enabled = true")
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  install_shaper "$home"
  install_speaker "$home"
  install_deepgram_tts_ok "$home"
  install_afplay "$home"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      FM_DEEPGRAM_ENV_FILE="$home/.env" \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "The scout report is done." 2>&1
  ) || fail "speak failed: $out"
  wait_for_file "$home/deepgram.log" "deepgram mock should have recorded the line"
  wait_for_file "$home/afplay.log" "afplay mock should have played the file"
  assert_contains "$(cat "$home/deepgram.log")" "scout report" "deepgram received the line"
  [ ! -f "$home/spoken.log" ] || fail "say must not run when deepgram succeeds"
  assert_contains "$(cat "$home/afplay.log")" ".mp3" "afplay played the synthesized file"
  pass "fm-speak: key present prefers Deepgram"
}

test_speak_falls_back_to_say_when_deepgram_fails() {
  local home out
  home=$(new_home dg-fail "enabled = true")
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  install_shaper "$home"
  install_speaker "$home"
  install_deepgram_tts_fail "$home"
  install_afplay "$home"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      FM_DEEPGRAM_ENV_FILE="$home/.env" \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "Checks passed on the first run." 2>&1
  ) || fail "speak failed: $out"
  wait_for_file "$home/deepgram.log" "deepgram mock should have recorded the failure attempt"
  wait_for_file "$home/spoken.log" "say should have recorded the fallback line"
  assert_contains "$(cat "$home/deepgram.log")" "fail" "deepgram was attempted"
  assert_contains "$(cat "$home/spoken.log")" "Checks passed" "say received the fallback"
  pass "fm-speak: Deepgram failure falls back to say"
}

# --- desk-voice mailbox -----------------------------------------------------

test_desk_voice_deliver_pending_drain() {
  local home path pending drained wake
  home=$(new_home mailbox)
  path=$(
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$DESK" deliver --source test-suite "Merge the finances PR when green"
  ) || fail "deliver failed"
  [ -f "$path" ] || fail "deliver did not create $path"
  pending=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" pending) \
    || fail "pending failed"
  assert_contains "$pending" "$path" "pending lists the inbox file"
  [ -f "$home/state/.wake-queue" ] || fail "wake queue missing"
  wake=$(cat "$home/state/.wake-queue")
  assert_contains "$wake" "desk-voice" "wake names desk-voice"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain) \
    || fail "drain failed"
  assert_contains "$drained" "Merge the finances PR when green" "drain prints transcript"
  [ ! -f "$path" ] || fail "inbox file should be gone after drain"
  pass "fm-desk-voice: deliver, wake, pending, drain"
}

test_deepgram_lib_reads_dotenv_without_logging_key() {
  local home out
  home=$(new_home dotenv)
  printf 'DEEPGRAM_API_KEY=super-secret-test-key\n' > "$home/.env"
  out=$(
    FM_HOME="$home" FM_DEEPGRAM_ENV_FILE="$home/.env" bash -c '
      . "'"$ROOT"'/bin/fm-deepgram-lib.sh"
      k=$(fm_deepgram_api_key)
      printf "len=%s\n" "${#k}"
    ' 2>&1
  ) || fail "dotenv load failed: $out"
  assert_contains "$out" "len=21" "key length loaded"
  case "$out" in
    *super-secret*) fail "key leaked into output: $out" ;;
  esac
  pass "fm-deepgram-lib: loads .env key without printing it"
}

test_tts_refuses_without_key
test_tts_dry_run_with_key
test_stt_refuses_without_key_or_file
test_stt_prints_transcript_from_mocked_deepgram
test_stt_reports_http_failure
test_floater_help_and_option_refusal
test_speak_uses_say_when_key_absent
test_speak_prefers_deepgram_when_key_present
test_speak_falls_back_to_say_when_deepgram_fails
test_desk_voice_deliver_pending_drain
test_deepgram_lib_reads_dotenv_without_logging_key

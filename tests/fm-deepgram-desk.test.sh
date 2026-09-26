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
if [ "\${1:-}" = -v ] && [ "\${2:-}" = '?' ]; then
  printf 'asked\n' >> "$home/voices.log"
  [ ! -f "$home/voices" ] || cat "$home/voices"
  exit \$(cat "$home/voices.status" 2>/dev/null || printf 0)
fi
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

install_speaker_refusing_voice() {
  local home=$1
  cat > "$home/speaker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -v ] && [ "\${2:-}" = '?' ]; then
  printf 'asked\n' >> "$home/voices.log"
  [ ! -f "$home/voices" ] || cat "$home/voices"
  exit \$(cat "$home/voices.status" 2>/dev/null || printf 0)
fi
printf 'argv: %s\n' "\$*" >> "$home/spoken.log"
printf 'Voice not found\n' >&2
exit 1
EOF
  chmod +x "$home/speaker"
}

# The stand-in speaker answers `-v ?` from this file, the way `say` lists the
# voices it has. A home without one answers with an empty list, which the script
# treats as "could not be asked" rather than as "voice missing".
install_voices() {  # <home> <voice-name...>
  local home=$1
  shift
  : > "$home/voices"
  for v in "$@"; do
    printf '%-20s en_US    # Hello! My name is %s.\n' "$v" "$v" >> "$home/voices"
  done
}

# A voice list that was cut off part-way: `say` wrote some names and then died,
# so the names it never reached say nothing about which voices exist.
install_truncated_voices() {  # <home> <voice-name...>
  local home=$1
  shift
  install_voices "$home" "$@"
  printf '1\n' > "$home/voices.status"
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

# A mock writes its log in more than one step, so waiting for the file to exist
# is not waiting for the line being asserted on. Wait for the content instead.
wait_for_content() {  # <path> <needle> <msg>
  local path=$1 needle=$2 msg=$3 waited=0
  while [ "$waited" -lt 50 ]; do
    grep -qF "$needle" "$path" 2>/dev/null && return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$msg (timed out waiting for '$needle' in $path)"
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

DEV_HASH=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
DEV_NAME="Apple Development: Test Person (TEAM123)"
DIST_HASH=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
DIST_NAME="iPhone Distribution: Test Person (TEAM456)"

# A copy of the launcher in its own code root, with fake swift, security,
# codesign, open and lsregister recording what the launcher asked of them.
# The fake codesign writes its signature into the app binary, so copying a
# fresh binary over it drops the signature as a real one would, and fails to
# sign with any hash listed in codesign.fail. Every security and codesign call
# lands in tools.log.
new_floater_root() {  # <name> <identities-listing>
  local fx="$TMP_ROOT/$1"
  mkdir -p "$fx/root/bin" "$fx/root/desk-floater/Sources" "$fx/fake" "$fx/root/config"
  fx=$(cd "$fx" && pwd -P)
  cp "$FLOATER" "$fx/root/bin/fm-desk-floater.sh"
  : > "$fx/root/desk-floater/Sources/DeskFloater.swift"
  : > "$fx/root/desk-floater/Package.swift"
  printf '%s\n' "$2" > "$fx/identities"
  cat > "$fx/fake/swift" <<EOF
#!/usr/bin/env bash
printf 'build\n' >> "$fx/swift.log"
mkdir -p .build/release
printf '#!/bin/sh\n' > .build/release/DeskFloater
chmod +x .build/release/DeskFloater
EOF
  cat > "$fx/fake/security" <<EOF
#!/usr/bin/env bash
printf 'security %s\n' "\$*" >> "$fx/tools.log"
cat "$fx/identities"
EOF
  cat > "$fx/fake/codesign" <<EOF
#!/usr/bin/env bash
printf 'codesign %s\n' "\$*" >> "$fx/tools.log"
app=\${!#}
bin="\$app/Contents/MacOS/DeskFloater"
if [ "\$1" = -dvv ]; then
  sig=\$(sed -n 's/^# fake-sig //p' "\$bin")
  if [ -z "\$sig" ]; then
    printf 'Identifier=DeskFloater\nSignature=adhoc\n' >&2
    exit 0
  fi
  printf 'Identifier=%s\n' "\${sig#* }" >&2
  case "\${sig%% *}" in
    $DEV_HASH) printf 'Authority=%s\n' "$DEV_NAME" >&2 ;;
    $DIST_HASH) printf 'Authority=%s\n' "$DIST_NAME" >&2 ;;
  esac
  printf 'Authority=Apple Root CA\n' >&2
  exit 0
fi
printf '%s\n' "\$*" >> "$fx/codesign.log"
if [ -f "$fx/codesign.fail" ]; then
  while IFS= read -r bad; do
    case " \$* " in *" --sign \$bad "*) exit 1 ;; esac
  done < "$fx/codesign.fail"
fi
while [ "\$#" -gt 1 ]; do
  case "\$1" in
    --sign) hash=\$2; shift ;;
    --identifier) ident=\$2; shift ;;
  esac
  shift
done
printf '# fake-sig %s %s\n' "\$hash" "\$ident" >> "\$bin"
EOF
  cat > "$fx/fake/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fx/open.log"
EOF
  cat > "$fx/fake/lsregister" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -dump ]; then
  cat <<DUMP
--------------------------------------------------------------------------------
bundle id:                  DeskFloater (0x10)
path:                       $fx/root/desk-floater/.build/DeskFloater.app (0x11)
identifier:                 com.firstmate.desk-floater
--------------------------------------------------------------------------------
bundle id:                  DeskFloater (0x20)
path:                       $fx/stray copy/desk-floater/.build/DeskFloater.app (0x21)
identifier:                 com.firstmate.desk-floater
--------------------------------------------------------------------------------
bundle id:                  DeskFloater (0x30)
path:                       $fx/checked/desk-floater/.build/DeskFloater-build-only.app (0x31)
identifier:                 com.firstmate.desk-floater.build-only
--------------------------------------------------------------------------------
bundle id:                  Other (0x40)
path:                       /Applications/Other.app (0x41)
identifier:                 com.example.other
DUMP
  exit 0
fi
printf '%s\n' "\$*" >> "$fx/lsregister.log"
EOF
  chmod +x "$fx/fake/"*
  touch "$fx/swift.log" "$fx/codesign.log" "$fx/open.log" "$fx/lsregister.log" "$fx/tools.log"
  printf '%s\n' "$fx"
}

run_floater() {  # <fixture> [args...]
  local fx=$1
  shift
  PATH="$fx/fake:$PATH" FM_HOME="$fx/root" FM_DESK_FLOATER_LSREGISTER="$fx/fake/lsregister" \
    "$fx/root/bin/fm-desk-floater.sh" "$@" 2>&1
}

bundle_id_of() {  # <fixture> [app-name]
  plutil -extract CFBundleIdentifier raw -o - "$1/root/desk-floater/.build/${2:-DeskFloater}.app/Contents/Info.plist"
}

floater_listing() {
  printf '  1) %s "%s"\n  2) %s "%s"\n     2 valid identities found\n' "$DIST_HASH" "$DIST_NAME" "$DEV_HASH" "$DEV_NAME"
}

test_floater_signs_with_a_stable_identity() {
  local fx out
  if [ "$(uname)" != Darwin ]; then
    pass "fm-desk-floater: signing tests skipped (need macOS)"
    return
  fi
  fx=$(new_floater_root floater-sign "$(floater_listing)")

  out=$(run_floater "$fx") || fail "launch failed: $out"
  assert_equals "com.firstmate.desk-floater" "$(bundle_id_of "$fx")" "the launched build carries the reopen identifier"
  assert_grep "--sign $DEV_HASH --identifier com.firstmate.desk-floater --timestamp=none" "$fx/codesign.log" "the launched build is signed with the first Apple Development identity"
  assert_grep "--env FM_HOME=$fx/root --env FM_DESK_FLOATER_ROOT=$fx/root $fx/root/desk-floater/.build/DeskFloater.app" "$fx/open.log" "the home build is opened with its home"
  assert_grep "-u $fx/stray copy/desk-floater/.build/DeskFloater.app" "$fx/lsregister.log" "another registered copy is forgotten"
  assert_no_grep "$fx/root/" "$fx/lsregister.log" "the launched copy stays registered"
  assert_no_grep "$fx/checked/" "$fx/lsregister.log" "a build-only copy is left alone"
  assert_no_grep "Other.app" "$fx/lsregister.log" "other apps are left alone"

  : > "$fx/codesign.log"
  out=$(run_floater "$fx") || fail "second launch failed: $out"
  [ ! -s "$fx/codesign.log" ] || fail "an unchanged, correctly signed app was re-signed: $(cat "$fx/codesign.log")"

  touch "$fx/root/desk-floater/Sources/DeskFloater.swift"
  sleep 1
  touch "$fx/root/desk-floater/Sources/DeskFloater.swift"
  out=$(run_floater "$fx") || fail "rebuild launch failed: $out"
  assert_equals 2 "$(grep -c build "$fx/swift.log")" "a source change rebuilds"
  assert_grep "--sign $DEV_HASH --identifier com.firstmate.desk-floater --timestamp=none" "$fx/codesign.log" "a rebuild is signed with the same identity, so its grants carry over"
  pass "fm-desk-floater: every launched build is signed with one stable identity, and only the launched copy can be reopened"
}

test_floater_build_only_leaves_the_launched_app_alone() {
  local fx out launched
  if [ "$(uname)" != Darwin ]; then
    pass "fm-desk-floater: build-only tests skipped (need macOS)"
    return
  fi
  fx=$(new_floater_root floater-build-only "$(floater_listing)")
  launched="$fx/root/desk-floater/.build/DeskFloater.app"
  out=$(run_floater "$fx") || fail "launch failed: $out"
  cp "$launched/Contents/MacOS/DeskFloater" "$fx/launched.bin"
  cp "$launched/Contents/Info.plist" "$fx/launched.plist"
  : > "$fx/open.log"
  : > "$fx/lsregister.log"
  : > "$fx/tools.log"

  touch "$fx/root/desk-floater/Sources/DeskFloater.swift"
  sleep 1
  touch "$fx/root/desk-floater/Sources/DeskFloater.swift"
  out=$(run_floater "$fx" --build-only) || fail "--build-only failed: $out"
  assert_equals "$fx/root/desk-floater/.build/DeskFloater-build-only.app" "$(printf '%s\n' "$out" | tail -n 1)" "--build-only prints its own bundle"
  assert_equals 2 "$(grep -c build "$fx/swift.log")" "--build-only compiles the changed source"
  assert_equals "com.firstmate.desk-floater.build-only" "$(bundle_id_of "$fx" DeskFloater-build-only)" "a build-only copy never carries the identifier macOS reopens"
  assert_no_grep "fake-sig" "$fx/root/desk-floater/.build/DeskFloater-build-only.app/Contents/MacOS/DeskFloater" "a build-only copy keeps the linker's ad-hoc signature"
  [ ! -s "$fx/tools.log" ] || fail "--build-only ran codesign or looked in the keychain: $(cat "$fx/tools.log")"
  cmp -s "$launched/Contents/MacOS/DeskFloater" "$fx/launched.bin" || fail "--build-only rewrote the launched binary or its signature"
  cmp -s "$launched/Contents/Info.plist" "$fx/launched.plist" || fail "--build-only rewrote the launched bundle's Info.plist"
  [ ! -s "$fx/open.log" ] || fail "--build-only launched the app"
  [ ! -s "$fx/lsregister.log" ] || fail "--build-only touched LaunchServices"
  pass "fm-desk-floater: --build-only assembles its own ad-hoc bundle and never touches the launched one"
}

test_floater_signing_identity_config_and_fallbacks() {
  local fx out
  if [ "$(uname)" != Darwin ]; then
    pass "fm-desk-floater: signing fallback tests skipped (need macOS)"
    return
  fi
  fx=$(new_floater_root floater-adhoc "     0 valid identities found")
  out=$(run_floater "$fx") || fail "launch without an identity failed: $out"
  assert_contains "$out" "keeping the ad-hoc signature" "a missing identity is explained"
  [ ! -s "$fx/codesign.log" ] || fail "signed without an identity: $(cat "$fx/codesign.log")"
  assert_grep "DeskFloater.app" "$fx/open.log" "still launches ad-hoc"

  fx=$(new_floater_root floater-config "$(floater_listing)")
  printf 'iPhone Distribution\n' > "$fx/root/config/desk-floater-signing-identity"
  out=$(run_floater "$fx") || fail "launch with a configured identity failed: $out"
  assert_grep "--sign $DIST_HASH --identifier com.firstmate.desk-floater" "$fx/codesign.log" "the configured identity wins over Apple Development"

  printf -- '-\n' > "$fx/root/config/desk-floater-signing-identity"
  : > "$fx/codesign.log"
  out=$(run_floater "$fx") || fail "launch with configured ad-hoc failed: $out"
  [ ! -s "$fx/codesign.log" ] || fail "configured ad-hoc still signed: $(cat "$fx/codesign.log")"
  assert_not_contains "$out" "keeping the ad-hoc signature" "a chosen ad-hoc signature needs no warning"

  printf 'Nobody\n' > "$fx/root/config/desk-floater-signing-identity"
  : > "$fx/codesign.log"
  : > "$fx/open.log"
  out=$(run_floater "$fx") || fail "a missing configured identity stopped the launch: $out"
  assert_contains "$out" "'Nobody'" "the missing identity is named"
  assert_contains "$out" "signing with $DEV_NAME instead" "the fallback identity is named"
  assert_grep "--sign $DEV_HASH --identifier com.firstmate.desk-floater" "$fx/codesign.log" "a missing configured identity falls back to Apple Development"
  assert_grep "DeskFloater.app" "$fx/open.log" "still launches with the fallback identity"

  fx=$(new_floater_root floater-config-alone "$(printf '  1) %s "%s"\n     1 valid identities found\n' "$DIST_HASH" "$DIST_NAME")")
  printf 'Nobody\n' > "$fx/root/config/desk-floater-signing-identity"
  out=$(run_floater "$fx") || fail "a missing configured identity without Apple Development stopped the launch: $out"
  assert_contains "$out" "'Nobody'" "the missing identity is named"
  assert_contains "$out" "keeping the ad-hoc signature" "the ad-hoc fallback is explained"
  [ ! -s "$fx/codesign.log" ] || fail "signed with an identity nobody chose: $(cat "$fx/codesign.log")"
  assert_grep "DeskFloater.app" "$fx/open.log" "still launches ad-hoc"

  fx=$(new_floater_root floater-config-signfail "$(floater_listing)")
  printf 'iPhone Distribution\n' > "$fx/root/config/desk-floater-signing-identity"
  printf '%s\n' "$DIST_HASH" > "$fx/codesign.fail"
  out=$(run_floater "$fx") || fail "a configured identity that fails to sign stopped the launch: $out"
  assert_contains "$out" "codesign failed with $DIST_NAME; signing with $DEV_NAME instead" "the signing failure and the fallback are named"
  assert_grep "--sign $DEV_HASH --identifier com.firstmate.desk-floater" "$fx/codesign.log" "falls back to Apple Development"
  assert_contains "$(tail -n 1 "$fx/root/desk-floater/.build/DeskFloater.app/Contents/MacOS/DeskFloater")" "$DEV_HASH" "the launched app carries the fallback signature"
  assert_grep "DeskFloater.app" "$fx/open.log" "still launches with the fallback identity"

  fx=$(new_floater_root floater-signfail "$(floater_listing)")
  printf '%s\n' "$DIST_HASH" "$DEV_HASH" > "$fx/codesign.fail"
  printf 'iPhone Distribution\n' > "$fx/root/config/desk-floater-signing-identity"
  out=$(run_floater "$fx") || fail "a signing failure should fall back to ad-hoc: $out"
  assert_contains "$out" "codesign failed with $DEV_NAME; keeping the ad-hoc signature" "the last signing failure is explained"
  assert_no_grep "fake-sig" "$fx/root/desk-floater/.build/DeskFloater.app/Contents/MacOS/DeskFloater" "the fallback app is ad-hoc"
  assert_grep "DeskFloater.app" "$fx/open.log" "still launches after the fallback"
  pass "fm-desk-floater: a configured identity wins, and an unusable one falls back to Apple Development, then ad-hoc, without stopping the launch"
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

# A configured voice is the captain choosing how the desk sounds, and Deepgram
# cannot speak in it - its voice comes from DEEPGRAM_TTS_MODEL. So a home that
# names one must reach `say` even with a Deepgram key sitting right there, or the
# outcome comes back in a voice nobody asked for.
test_speak_prefers_the_configured_voice_over_deepgram() {
  local home out
  home=$(new_home voice-prefer "enabled = true" "voice = Ava (Premium)")
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  install_voices "$home" "Ava (Premium)" "Eddy (English (UK))"
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
      "$SPEAK" "The desk voice fix is green." 2>&1
  ) || fail "speak failed: $out"
  wait_for_content "$home/spoken.log" "text: " "say should have recorded the shaped line"
  assert_contains "$(cat "$home/spoken.log")" "desk voice fix" "say received the line"
  assert_contains "$(cat "$home/spoken.log")" "Ava (Premium)" "say was given the configured voice"
  [ ! -f "$home/deepgram.log" ] || fail "deepgram must not run when a voice is configured"
  [ ! -f "$home/afplay.log" ] || fail "afplay must not run when a voice is configured"
  pass "fm-speak: a configured voice is spoken by say, not by Deepgram"
}

# Asking `say` for its voice list creates a temporary file before the register
# has had its say. A refused line must not leave that file behind: an orphaned
# fm-speak temporary file is how this repo tells that a speaker was cut short.
test_speak_leaves_no_voice_list_behind_when_the_register_refuses() {
  local home out status=0 leftover
  home=$(new_home voice-refused-register "enabled = true" "voice = Ava (Premium)")
  printf '#!/usr/bin/env bash\nexit 2\n' > "$home/shaper"
  chmod +x "$home/shaper"
  install_speaker "$home"
  install_voices "$home" "Ava (Premium)"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE=/dev/null \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_SHAPER_TIMEOUT=2 \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      "$SPEAK" "Shall I merge it?" 2>&1
  ) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 from a refusing register, got $status: $out"
  sleep 4
  leftover=$(find "$home" -maxdepth 1 -name 'fm-speak-*' | wc -l | tr -d ' ')
  [ "$leftover" -eq 0 ] || fail "a refused line left $leftover temporary file(s) behind"
  pass "fm-speak: a refused line leaves no voice list or watchdog marker behind"
}

# A voice list killed part-way has already flushed whole blocks of the alphabet,
# so a name missing from it proves nothing. Refusing on that evidence would turn a
# degraded speech subsystem into a silent desk and blame the captain's config.
test_speak_still_speaks_when_the_voice_list_was_cut_off() {
  local home out
  home=$(new_home voice-list-truncated "enabled = true" "voice = Samantha")
  install_shaper "$home"
  install_speaker "$home"
  install_truncated_voices "$home" "Albert" "Alice"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE=/dev/null \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      "$SPEAK" "The truncated list line is green." 2>&1
  ) || fail "an unanswerable voice question must not stop the line: $out"
  wait_for_content "$home/spoken.log" "text: " "the line should still have been spoken"
  assert_contains "$(cat "$home/spoken.log")" "truncated list line" "say received the line"
  assert_contains "$(cat "$home/spoken.log")" "Samantha" "say was given the configured voice"
  pass "fm-speak: an incomplete voice list never refuses a voice"
}

# Only the first line of a home waits for the voice list; a confirmed voice is
# remembered. Renaming the voice must ask again, or the memory would outlive the
# answer it stands for.
test_speak_asks_for_the_voice_list_once_per_confirmed_voice() {
  local home out asked
  home=$(new_home voice-remembered "enabled = true" "voice = Ava (Premium)")
  install_shaper "$home"
  install_speaker "$home"
  install_voices "$home" "Ava (Premium)" "Samantha"
  speak_here() {
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE=/dev/null \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      "$SPEAK" "$1" 2>&1
  }
  out=$(speak_here "The first line is green.") || fail "first speak failed: $out"
  asked=$(wc -l < "$home/voices.log" | tr -d ' ')
  [ "$asked" -eq 1 ] || fail "expected one voice-list question on the first line, got $asked"
  out=$(speak_here "The second line is green.") || fail "second speak failed: $out"
  asked=$(wc -l < "$home/voices.log" | tr -d ' ')
  [ "$asked" -eq 1 ] || fail "a confirmed voice must not be asked about again, got $asked questions"
  wait_for_content "$home/spoken.log" "second line" "the second line should still have been spoken"

  printf 'enabled = true\nvoice = Nonexistent Voice\n' > "$home/config/speak"
  out=$(speak_here "The renamed line is green.") && fail "a voice this machine lacks must be refused: $out"
  assert_contains "$out" "Nonexistent Voice" "the renamed voice is checked again, not remembered"
  pass "fm-speak: a confirmed voice is asked about once, a renamed one is asked again"
}

# `say` does not refuse a voice it does not have - it substitutes one and exits 0
# - and the substitution happens inside the detached speaker, where nothing can
# reach the caller. So a voice this machine does not have has to be caught before
# the handoff and reported there, rather than heard as some other voice.
test_speak_refuses_a_voice_this_machine_does_not_have() {
  local home out status=0
  home=$(new_home voice-missing "enabled = true" "voice = Nonexistent Voice")
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  install_shaper "$home"
  install_speaker "$home"
  install_voices "$home" "Ava (Premium)" "Samantha"
  install_deepgram_tts_ok "$home"
  install_afplay "$home"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE="$home/.env" \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "The missing voice line is green." 2>&1
  ) || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for a voice this machine lacks, got $status: $out"
  assert_contains "$out" "Nonexistent Voice" "the caller is told which voice is missing"
  assert_contains "$out" "config/speak" "the caller is told where the voice is configured"
  sleep 1
  [ ! -f "$home/spoken.log" ] || fail "the line must not be spoken in a substitute voice"
  [ ! -f "$home/deepgram.log" ] || fail "a missing voice must not spend Deepgram credit"
  [ ! -f "$home/afplay.log" ] || fail "a missing voice must not reach the Deepgram player"

  # `say` resolves a bare name up to its qualified voice, never the other way:
  # `Zarvox (Premium)` reaches no voice and falls through to the substitute.
  printf 'enabled = true\nvoice = Samantha (Premium)\n' > "$home/config/speak"
  status=0
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE="$home/.env" \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "The over-qualified voice line is green." 2>&1
  ) || status=$?
  [ "$status" -eq 1 ] || fail "a qualifier the listed name does not carry must be refused, got $status: $out"
  assert_contains "$out" "Samantha (Premium)" "the caller is told which voice is missing"
  pass "fm-speak: a voice this machine does not have is reported, not substituted"
}

# The check must never be stricter than `say` itself, or it refuses a name say
# speaks perfectly well and the desk goes silent - the failure it exists to
# prevent. Both spellings below were proved on this machine to render audio
# byte-identical to the listed name they resolve to.
test_speak_accepts_the_spellings_say_itself_resolves() {
  local home out
  home=$(new_home voice-spellings "enabled = true" "voice = Ava")
  install_shaper "$home"
  install_speaker "$home"
  install_voices "$home" "Ava (Premium)" "Samantha" "Zarvox"
  speak_spelling() {
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE=/dev/null \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      "$SPEAK" "$1" 2>&1
  }
  out=$(speak_spelling "The bare name line is green.") \
    || fail "a bare name that say resolves must not be refused: $out"
  wait_for_content "$home/spoken.log" "bare name line" "the bare-name line should have been spoken"
  assert_contains "$(cat "$home/spoken.log")" "-v Ava -f" "say was given the configured spelling unchanged"

  printf 'enabled = true\nvoice = samantha\n' > "$home/config/speak"
  rm -f "$home/state/speak-voice-confirmed"
  out=$(speak_spelling "The lowercase name line is green.") \
    || fail "a lowercase name that say resolves must not be refused: $out"
  wait_for_content "$home/spoken.log" "lowercase name line" "the lowercase-name line should have been spoken"
  pass "fm-speak: a spelling say resolves is spoken, not refused"
}

# A `say` that fails once it already has the line is left to fail: the speaker is
# chosen before the handoff and never swapped afterwards, so a local speaker
# problem never turns into paid Deepgram synthesis behind the captain's back.
test_speak_does_not_swap_to_deepgram_when_say_fails() {
  local home out leftover waited
  home=$(new_home voice-say-fails "enabled = true" "voice = Nonexistent Voice")
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  install_shaper "$home"
  install_speaker_refusing_voice "$home"
  install_deepgram_tts_ok "$home"
  install_afplay "$home"
  out=$(
    env -u DEEPGRAM_API_KEY \
      FM_HOME="$home" \
      TMPDIR="$home" \
      FM_DEEPGRAM_ENV_FILE="$home/.env" \
      FM_SPEAK_SHAPER="$home/shaper" \
      FM_SPEAK_SAY="$home/speaker" \
      FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
      FM_SPEAK_DEEPGRAM_REGISTER= \
      FM_DEEPGRAM_AFPLAY="$home/afplay" \
      "$SPEAK" "The rejected voice line is green." 2>&1
  ) || fail "speak failed: $out"
  wait_for_content "$home/spoken.log" "Nonexistent Voice" "say should have been tried in the configured voice"
  leftover=1
  waited=0
  while [ "$waited" -lt 25 ]; do
    leftover=$(find "$home" -maxdepth 1 -name 'fm-speak-*' | wc -l | tr -d ' ')
    [ "$leftover" -eq 0 ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  [ "$leftover" -eq 0 ] || fail "a failed say left $leftover temporary file(s) behind"
  [ ! -f "$home/deepgram.log" ] || fail "a failed say must not spend Deepgram credit"
  [ ! -f "$home/afplay.log" ] || fail "a failed say must not reach the Deepgram player"
  pass "fm-speak: a say that fails is not re-spoken through Deepgram"
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

# --- desk-voice send: straight into the primary's chat pane ------------------
#
# A stand-in primary: a live process whose command line names a harness (a
# python script under a claude/ directory, which the session-lock identity
# accepts) and whose environment names a Herdr pane (or a tmux pane). It holds
# the fixture home's session lock, and runs beneath a stand-in multiplexer
# server. The herdr and tmux on PATH are fakes that log every call, so no real
# pane ever receives text or keys.

desk_send_fixture() {  # <name> [tmux] -> home; starts the stand-in primary
  local name=$1 backend=${2:-herdr} home dir fb pid i envs marker
  local -a pane_env
  home=$(new_home "$name")
  dir="$home/fixture"
  fb="$dir/bin"
  mkdir -p "$fb" "$dir/claude"
  printf 'import time\ntime.sleep(60)\n' > "$dir/claude/holder.py"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/herdr.log"
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.4","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    if [ -e "$dir/unfocused" ]; then f=false; else f=true; fi
    printf '{"result":{"pane":{"pane_id":"%s","focused":%s}}}\n' "$3" "$f" ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[]}}}\n' \
      "$4" "$(cat "$dir/shell-pid")" ;;
  "pane read")
    if [ -e "$dir/modal" ]; then
      cat "$dir/modal"
    else
      printf '❯ %s\n' "$(cat "$dir/draft" 2>/dev/null)"
    fi ;;
  "pane send-text")
    [ ! -e "$dir/send-text-fails" ] || exit 1
    printf '%s' "$4" >> "$dir/draft" ;;
  "pane send-keys")
    : > "$dir/entered"
    [ -e "$dir/never-works" ] || : > "$dir/draft" ;;
  "agent get")
    if [ -e "$dir/entered" ] && [ ! -e "$dir/never-works" ]; then s=working; else s=idle; fi
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$s" ;;
esac
exit 0
SH
  # The tmux fake answers only what reaching the pane and the front check
  # read; its chat input cannot be read, so a message that gets that far lands
  # in the mailbox.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/tmux.log"
case "$*" in
  *'#{pane_pid}'*) cat "$dir/shell-pid" ;;
  *'#{session_id} #{window_active}#{pane_active}'*) cat "$dir/tmux-active" ;;
  *'#{pane_id}'*) printf '%%9\n' ;;
  list-clients*) cat "$dir/tmux-clients" 2>/dev/null ;;
  *) exit 1 ;;
esac
SH
  printf '#!/bin/sh\nexit 0\n' > "$fb/osascript"
  chmod +x "$fb/herdr" "$fb/tmux" "$fb/osascript"
  : > "$dir/herdr.log"
  : > "$dir/tmux.log"
  if [ "$backend" = tmux ]; then
    pane_env=(TMUX="$dir/tmux.sock,1,0" TMUX_PANE=%9)
    marker=TMUX_PANE=%9
  else
    pane_env=(HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fm-desk-send-test
      HERDR_SOCKET_PATH="$dir/herdr.sock")
    marker=HERDR_PANE_ID=w7:p3
  fi
  # The stand-in server is the stand-in primary's parent, as a multiplexer
  # server is the parent of the pane that hosts a real primary.
  # shellcheck disable=SC2016  # expanded by the inner shell
  env "${pane_env[@]}" bash -c \
    'python3 "$1" >/dev/null 2>&1 & printf "%s\n" "$!" > "$2.tmp"; mv "$2.tmp" "$2"; wait' \
    _ "$dir/claude/holder.py" "$dir/holder-pid" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/server-pid"
  for i in $(seq 1 50); do
    [ -s "$dir/holder-pid" ] && break
    sleep 0.1
  done
  pid=$(cat "$dir/holder-pid" 2>/dev/null) || return 1
  printf '%s\n' "$pid" > "$home/state/.lock"
  # The pane's root process is the stand-in itself unless a case says otherwise.
  printf '%s\n' "$pid" > "$dir/shell-pid"
  : > "$dir/draft"
  for i in $(seq 1 50); do
    if [ -r "/proc/$pid/environ" ]; then
      envs=$(tr '\0' '\n' < "/proc/$pid/environ")
    else
      envs=$(ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n')
    fi
    case "$envs" in *"$marker"*) break ;; esac
    sleep 0.1
  done
  case "$envs" in
    *"$marker"*) ;;
    *) kill "$pid" 2>/dev/null; return 1 ;;
  esac
  printf '%s\n' "$home"
}

# Each case starts its own stand-in; stop it when the case is done.
desk_send_done() {  # <home>
  kill "$(cat "$1/fixture/holder-pid")" 2>/dev/null || true
}

desk_send_skip() {  # <case>
  printf 'skip: %s: this host does not expose the stand-in primary environment\n' "$1"
}

desk_send() {  # <home> [--image <png>]... <text> -> stdout of fm-desk-voice.sh send
  local home=$1 dir="$1/fixture"
  shift
  (
    unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
      FM_BACKEND_HERDR_BIN FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
    PATH="$dir/bin:$PATH" FM_FAKE_HERDR_DIR="$dir" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.1 \
      "$DESK" send --source test-suite "$@"
  )
}

herdr_calls() {  # <home> <subcommand words...> -> matching log lines, readable
  local home=$1 pattern
  shift
  pattern=$(printf '\x1f%s' "$@")
  grep -F -- "$pattern" "$home/fixture/herdr.log" | tr '\037' ' '
}

inbox_count() {  # <home>
  find "$home/state/desk-voice/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

test_desk_voice_send_types_into_the_primary_pane() {
  local home out typed
  home=$(desk_send_fixture send-direct) || { desk_send_skip send-direct; return 0; }
  out=$(desk_send "$home" $'Merge the\nfinances PR\r when green\033[201~ please\t') \
    || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "send reports the primary pane"
  typed=$(herdr_calls "$home" pane send-text)
  assert_contains "$typed" "pane send-text w7:p3 Merge the finances PR when green [201~ please --session fm-desk-send-test" \
    "the transcript is typed as one plain line"
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "text typed more than once"
  assert_contains "$(herdr_calls "$home" pane send-keys)" "pane send-keys w7:p3 enter" "Enter submits it"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  [ ! -s "$home/state/.wake-queue" ] || fail "a pane delivery must not queue a mailbox wake"
  desk_send_done "$home"
  pass "fm-desk-voice send: types the transcript into the primary's own pane and submits it"
}

test_desk_voice_send_falls_back_without_a_live_primary() {
  local home out path
  home=$(desk_send_fixture send-no-lock) || { desk_send_skip send-no-lock; return 0; }
  rm -f "$home/state/.lock"
  out=$(desk_send "$home" "Check the backlog") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  path=${out#mailbox: }
  [ -f "$path" ] || fail "mailbox file missing: $path"
  assert_contains "$(cat "$path")" "Check the backlog" "mailbox keeps the transcript"
  assert_contains "$(cat "$home/state/.wake-queue")" "desk-voice" "mailbox delivery queues a wake"
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed without a lock holder"
  desk_send_done "$home"
  pass "fm-desk-voice send: no live primary falls back to the mailbox"
}

test_desk_voice_send_refuses_a_pane_not_hosting_the_primary() {
  local home out
  home=$(desk_send_fixture send-foreign-pane) || { desk_send_skip send-foreign-pane; return 0; }
  # A root pid that is neither the stand-in nor any of its ancestors.
  printf '%s\n' 99999999 > "$home/fixture/shell-pid"
  out=$(desk_send "$home" "Status please") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "a pane that does not host the primary must not be typed into"
  [ "$(inbox_count "$home")" = 1 ] || fail "the transcript must land in the mailbox once"
  desk_send_done "$home"
  pass "fm-desk-voice send: a pane that does not host the primary gets nothing"
}

test_desk_voice_send_falls_back_when_the_pane_refuses_text() {
  local home out
  home=$(desk_send_fixture send-refused) || { desk_send_skip send-refused; return 0; }
  : > "$home/fixture/send-text-fails"
  out=$(desk_send "$home" "Ship it") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "no Enter may follow refused text"
  [ "$(inbox_count "$home")" = 1 ] || fail "the refused transcript must land in the mailbox once"
  desk_send_done "$home"
  pass "fm-desk-voice send: a refused send falls back to the mailbox"
}

test_desk_voice_send_never_doubles_an_unconfirmed_submit() {
  local home out
  home=$(desk_send_fixture send-unconfirmed) || { desk_send_skip send-unconfirmed; return 0; }
  : > "$home/fixture/never-works"
  out=$(desk_send "$home" "Pause the scout") || fail "send failed: $out"
  case "$out" in sent-unconfirmed:\ *) ;; *) fail "expected an unconfirmed pane delivery, got: $out" ;; esac
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "text must be typed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "typed text must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: typed text whose submit is unproven is never re-sent to the mailbox"
}

test_desk_voice_send_falls_back_when_the_pane_shows_a_dialog() {
  local home out screen n=0
  for screen in \
    $' Bash command\n\n   gh pr merge 42\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don\'t ask again for gh commands\n   3. No, and tell Claude what to do differently (esc)\n' \
    $' Which branch should I merge?\n\n   main\n   release\n\n Enter to select · ↑/↓ to navigate · Esc to cancel\n' \
    $' Pick a model\n  > 1. Opus\n    2. Sonnet\n'; do
    n=$((n + 1))
    home=$(desk_send_fixture "send-modal-$n") || { desk_send_skip "send-modal-$n"; return 0; }
    printf '%s' "$screen" > "$home/fixture/modal"
    out=$(desk_send "$home" "2 and then merge it") || fail "send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
    [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed into a dialog"
    [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "no Enter may reach a dialog"
    [ "$(inbox_count "$home")" = 1 ] || fail "the transcript must land in the mailbox once"
    desk_send_done "$home"
  done
  pass "fm-desk-voice send: a pane showing a dialog instead of its chat input gets nothing"
}

test_desk_voice_send_joins_a_pending_draft() {
  local home out
  home=$(desk_send_fixture send-draft) || { desk_send_skip send-draft; return 0; }
  printf 'half typed ' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a pending draft still takes the transcript"
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "text must be typed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a half-typed draft is joined and submitted"
}

test_desk_voice_send_types_screenshots_into_the_primary_pane() {
  local home out shot1 shot2
  home=$(desk_send_fixture send-shots) || { desk_send_skip send-shots; return 0; }
  shot1="$home/one.png"
  shot2="$home/two.png"
  printf PNG > "$shot1"
  printf PNG > "$shot2"
  out=$(desk_send "$home" --image "$shot1" --image "$shot2" -- "Why is this red") \
    || fail "send with screenshots failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "screenshots go into the primary pane"
  assert_contains "$(herdr_calls "$home" pane send-text)" \
    "pane send-text w7:p3 Why is this red Screenshots: $shot1 $shot2 --session fm-desk-send-test" \
    "the words and the image paths are typed as one plain line"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  : > "$home/fixture/herdr.log"
  out=$(desk_send "$home" --image "$shot1" --) || fail "send of screenshots alone failed: $out"
  assert_contains "$(herdr_calls "$home" pane send-text)" "pane send-text w7:p3 Screenshots: $shot1 --session" \
    "screenshots alone are typed too"
  desk_send_done "$home"
  pass "fm-desk-voice send: screenshots, alone or with words, are typed into the primary's pane"
}

test_desk_voice_send_screenshots_fall_back_to_the_mailbox() {
  local home out shot path drained
  home=$(desk_send_fixture send-shots-refused) || { desk_send_skip send-shots-refused; return 0; }
  shot="$home/one.png"
  printf PNG > "$shot"
  : > "$home/fixture/send-text-fails"
  out=$(desk_send "$home" --image "$shot" -- "Look at this") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  path=${out#mailbox: }
  assert_contains "$(cat "$path")" "$shot" "the mailbox record lists the image"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain) || fail "drain failed"
  [ "$drained" = "Look at this
Screenshots: $shot" ] || fail "unexpected mailbox message: $drained"
  desk_send_done "$home"
  pass "fm-desk-voice send: screenshots the pane refuses land in the mailbox with the words"
}

# --- desk-voice send --front-app/--front-tty: dictation into the chat -------
#
# A stand-in terminal app with a stand-in multiplexer client beneath it, and a
# fake lsof reporting the kernel's socket facts for them: the client's unix
# socket peers with a socket of the stand-in server, and its standard input is
# <tty>. The tmux fake lists the same client.

desk_front_fixture() {  # <home> <tty>
  local dir="$1/fixture" i
  bash -c 'sleep 60 >/dev/null 2>&1 & printf "%s\n" "$!" > "$1.tmp"; mv "$1.tmp" "$1"; wait' \
    _ "$dir/client-pid" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/app-pid"
  for i in $(seq 1 50); do
    [ -s "$dir/client-pid" ] && break
    sleep 0.1
  done
  printf '%s\n' "$2" > "$dir/client-tty"
  printf '%s %s\n' "$(cat "$dir/client-pid")" "$2" > "$dir/tmux-clients"
  printf '%s 11\n' "\$1" > "$dir/tmux-active"
  desk_front_peer "$1" 0xb2
  cat > "$dir/bin/lsof" <<'SH'
#!/usr/bin/env bash
dir=${FM_FAKE_HERDR_DIR:?}
case " $* " in
  *" -U "*) cat "$dir/lsof-unix" ;;
  *" -d 0 "*)
    [ "$3" = "$(cat "$dir/client-pid")" ] || exit 1
    printf 'p%s\nf0\nn%s\n' "$3" "$(cat "$dir/client-tty")" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/lsof"
}

# Rewrites the socket listing so the stand-in client's socket peers with
# <address>; the stand-in server's own client socket is 0xb2.
desk_front_peer() {  # <home> <address>
  local dir="$1/fixture"
  cat > "$dir/lsof-unix" <<EOF
p$(cat "$dir/server-pid")
f4
d0xa1
n$dir/herdr.sock
f7
d0xb2
n$dir/herdr-client.sock
p$(cat "$dir/client-pid")
f5
d0xc3
n->$2
EOF
}

desk_front_done() {  # <home>
  kill "$(cat "$1/fixture/client-pid")" 2>/dev/null || true
  desk_send_done "$1"
}

desk_dictate() {  # <home> <tty> <text> -> stdout of send from the stand-in app
  desk_send "$1" --front-app "$(cat "$1/fixture/app-pid")" --front-tty "$2" -- "$3"
}

test_desk_voice_dictation_sends_when_the_chat_is_in_front() {
  local home out
  home=$(desk_send_fixture front-sent) || { desk_send_skip front-sent; return 0; }
  desk_front_fixture "$home" /dev/ttys042
  out=$(desk_dictate "$home" /dev/ttys042 "Merge the finances PR") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "dictation into the chat is sent"
  assert_contains "$(herdr_calls "$home" pane send-text)" "pane send-text w7:p3 Merge the finances PR" \
    "the dictated words are typed into the primary's pane"
  assert_contains "$(herdr_calls "$home" pane send-keys)" "pane send-keys w7:p3 enter" "Enter submits it"
  [ "$(inbox_count "$home")" = 0 ] || fail "a sent dictation must not also land in the mailbox"
  desk_front_done "$home"
  pass "fm-desk-voice send: dictation into the Firstmate chat in front is typed and submitted"
}

test_desk_voice_dictation_elsewhere_is_left_to_paste() {
  local home out case
  for case in unfocused other-tty other-app other-server no-lock; do
    home=$(desk_send_fixture "front-$case") || { desk_send_skip "front-$case"; return 0; }
    desk_front_fixture "$home" /dev/ttys042
    case "$case" in
      unfocused) : > "$home/fixture/unfocused" ;;
      other-tty) printf '/dev/ttys007\n' > "$home/fixture/client-tty" ;;
      other-app) cat "$home/fixture/server-pid" > "$home/fixture/app-pid" ;;
      other-server) desk_front_peer "$home" 0xff ;;
      no-lock) rm -f "$home/state/.lock" ;;
    esac
    out=$(desk_dictate "$home" /dev/ttys042 "draft reply to Sam") || fail "$case: send failed: $out"
    [ "$out" = not-in-front ] || fail "$case: expected not-in-front, got: $out"
    [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "$case: nothing may be typed into the chat"
    [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "$case: no Enter may be sent"
    [ "$(inbox_count "$home")" = 0 ] || fail "$case: text meant elsewhere must not land in the mailbox"
    desk_front_done "$home"
  done
  pass "fm-desk-voice send: dictation anywhere but the Firstmate chat in front sends nothing"
}

test_desk_voice_dictation_keeps_the_send_checks() {
  local home out
  home=$(desk_send_fixture front-modal) || { desk_send_skip front-modal; return 0; }
  desk_front_fixture "$home" /dev/ttys042
  printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' > "$home/fixture/modal"
  out=$(desk_dictate "$home" /dev/ttys042 "1 and merge") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed into a dialog"
  [ "$(inbox_count "$home")" = 1 ] || fail "the dictation must land in the mailbox once"
  desk_front_done "$home"
  pass "fm-desk-voice send: dictation into a chat showing a dialog goes to the mailbox"
}

test_desk_voice_dictation_front_check_on_tmux() {
  local home out
  home=$(desk_send_fixture front-tmux tmux) || { desk_send_skip front-tmux; return 0; }
  desk_front_fixture "$home" /dev/ttys042
  # In front, the fake's unreadable chat input sends it on to the mailbox.
  out=$(desk_dictate "$home" /dev/ttys042 "Status please") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected the front check to pass, got: $out" ;; esac
  assert_contains "$(tr '\037' ' ' < "$home/fixture/tmux.log")" "list-clients -t \$1" \
    "the clients of the pane's own session are read"
  printf '%s 10\n' "\$1" > "$home/fixture/tmux-active"
  out=$(desk_dictate "$home" /dev/ttys042 "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "an inactive pane must not count as in front, got: $out"
  printf '%s 11\n' "\$1" > "$home/fixture/tmux-active"
  out=$(desk_dictate "$home" /dev/ttys007 "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "a client on another terminal must not count, got: $out"
  ! grep -qF send-keys "$home/fixture/tmux.log" || fail "no keys may reach the tmux pane"
  desk_front_done "$home"
  pass "fm-desk-voice send: on tmux, only the active pane shown on the front terminal is in front"
}

test_desk_voice_dictation_refuses_bad_front_arguments() {
  local home out status
  home=$(new_home front-args)
  for args in "--front-app 0 --front-tty /dev/ttys001" "--front-app 12x --front-tty /dev/ttys001" \
    "--front-app 12 --front-tty /tmp/x" "--front-app 12"; do
    status=0
    # shellcheck disable=SC2086
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" send $args -- words 2>&1) || status=$?
    [ "$status" -eq 2 ] || fail "expected exit 2 for '$args', got $status: $out"
  done
  [ "$(inbox_count "$home")" = 0 ] || fail "a refused send must deliver nothing"
  pass "fm-desk-voice send: malformed front arguments are refused"
}

# The floater's screenshots are captured by a stand-in here: a test must never
# photograph the real screen.
# nodot behaves like macOS screencapture, which cannot write to a file name
# starting with a dot: it complains, writes nothing, and still exits 0.
install_capture() {  # <home> [fail|empty|nodot]
  local home=$1 mode=${2:-ok}
  cat > "$home/capture" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$home/capture.log"
for a in "\$@"; do out=\$a; done
case "$mode" in
  fail) exit 1 ;;
  empty) : > "\$out" ;;
  nodot)
    case "\${out##*/}" in
      .*) echo "screencapture: cannot write file to intended destination, \$out" >&2; exit 0 ;;
    esac
    printf 'PNG' > "\$out"
    ;;
  *) printf 'PNG' > "\$out" ;;
esac
EOF
  chmod +x "$home/capture"
}

shoot_in() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DESK_SHOT_CAPTURE="$home/capture" \
    "$DESK" shot "$@"
}

test_desk_voice_shot_captures_the_named_display() {
  local home path perms
  home=$(new_home shot)
  install_capture "$home"
  path=$(shoot_in "$home" --display 2) || fail "shot failed: $path"
  case "$path" in
    "$home/state/desk-voice/shots/"*.png) ;;
    *) fail "shot path is not in the home's screenshot folder: $path" ;;
  esac
  [ "$(cat "$path")" = PNG ] || fail "shot did not keep the captured image"
  assert_contains "$(cat "$home/capture.log")" "-x -t png -D 2" "the display under the pointer is captured, silently"
  if [ "$(uname)" = Darwin ]; then perms=$(stat -f %Lp "$path"); else perms=$(stat -c %a "$path"); fi
  [ "$perms" = 600 ] || fail "screenshot should be private (600), got $perms"
  path=$(shoot_in "$home") || fail "shot without a display failed: $path"
  case "$(tail -n 1 "$home/capture.log")" in
    *-D*) fail "no --display must leave the display choice to the capture tool" ;;
  esac
  [ ! -d "$home/state/desk-voice/inbox" ] || [ -z "$(ls "$home/state/desk-voice/inbox")" ] \
    || fail "a shot on its own must not send anything"
  pass "fm-desk-voice: shot captures the named display into the home's screenshot folder"
}

test_desk_voice_shot_capture_file_name_has_no_leading_dot() {
  local home path left
  home=$(new_home shot-nodot)
  install_capture "$home" nodot
  path=$(shoot_in "$home" 2>"$home/shot.err") \
    || fail "shot failed with a capture tool that refuses dot-prefixed names: $(cat "$home/shot.err")"
  [ "$(cat "$path")" = PNG ] || fail "shot did not keep the captured image"
  left=$(find "$home/state/desk-voice/shots" -type f | wc -l | tr -d ' ')
  [ "$left" -eq 1 ] || fail "expected only the finished screenshot, found $left file(s)"
  pass "fm-desk-voice: shot works with a capture tool that cannot write dot-prefixed file names"
}

test_desk_voice_shot_keeps_only_the_newest() {
  local home first second third left
  home=$(new_home shot-prune)
  install_capture "$home"
  first=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home") || fail "first shot failed"
  second=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home") || fail "second shot failed"
  third=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home") || fail "third shot failed"
  left=$(find "$home/state/desk-voice/shots" -name '*.png' | wc -l | tr -d ' ')
  [ "$left" -eq 2 ] || fail "expected 2 screenshots kept, got $left"
  [ ! -f "$first" ] || fail "the oldest screenshot should have been pruned"
  [ -f "$second" ] && [ -f "$third" ] || fail "the newest screenshots must be kept"
  pass "fm-desk-voice: the screenshot folder keeps only the newest images"
}

test_desk_voice_shot_failure_leaves_nothing() {
  local home out status=0 left
  home=$(new_home shot-fail)
  install_capture "$home" fail
  out=$(shoot_in "$home" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for a failed capture, got $status: $out"
  install_capture "$home" empty
  status=0
  out=$(shoot_in "$home" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for an empty capture, got $status: $out"
  left=$(find "$home/state/desk-voice/shots" -type f | wc -l | tr -d ' ')
  [ "$left" -eq 0 ] || fail "a failed capture left $left file(s) behind"
  status=0
  out=$(shoot_in "$home" --display 0 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 for display 0, got $status: $out"
  pass "fm-desk-voice: a failed capture exits 1 and leaves no screenshot"
}

test_desk_voice_deliver_with_screenshots() {
  local home shot1 shot2 path drained json out status=0
  home=$(new_home mailbox-shots)
  install_capture "$home"
  shot1=$(shoot_in "$home") || fail "shot failed"
  shot2=$(shoot_in "$home") || fail "shot failed"
  path=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$DESK" deliver --source test-suite --image "$shot1" --image "$shot2" -- "Why is this red") \
    || fail "deliver with screenshots failed"
  json=$(cat "$path")
  assert_contains "$json" "$shot1" "the message record lists the first image"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain) || fail "drain failed"
  [ "$drained" = "Why is this red
Screenshots: $shot1 $shot2" ] || fail "unexpected combined message: $drained"
  path=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" deliver --image "$shot1" --) \
    || fail "deliver of screenshots alone failed"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain) || fail "drain failed"
  [ "$drained" = "Screenshots: $shot1" ] || fail "unexpected screenshots-only message: $drained"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" deliver --image shot.png 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 for a relative image path, got $status: $out"
  status=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" deliver --image "$home/missing.png" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 for a missing image, got $status: $out"
  status=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" deliver -- 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 with neither words nor images, got $status: $out"
  pass "fm-desk-voice: screenshots are delivered by path, alone or with the transcript, as one message"
}

# The floater's screenshot-stacking rules and capture conversion are Swift, so they need macOS and swift.
test_floater_swift_tests() {
  local out
  if [ "$(uname)" != Darwin ] || ! command -v swift >/dev/null 2>&1; then
    pass "desk floater: Swift tests skipped (need macOS and swift)"
    return
  fi
  out=$(swift test --package-path "$ROOT/desk-floater" 2>&1) || fail "desk floater Swift tests failed: $out"
  pass "desk floater: Swift tests pass"
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

# The voice the captain chose lives in the home's .env beside the key, and the
# automatic reply speech runs without it in its environment, so the helper must
# read it from there; an explicit environment value still wins.
test_tts_reads_the_voice_from_dotenv() {
  local home out
  home=$(new_home dotenv-voice)
  printf 'DEEPGRAM_API_KEY=test-key-not-real\nDEEPGRAM_TTS_MODEL="aura-2-helena-en"\n' > "$home/.env"
  out=$(env -u DEEPGRAM_TTS_MODEL -u DEEPGRAM_API_KEY FM_HOME="$home" FM_DEEPGRAM_ENV_FILE="$home/.env" \
    "$TTS" --dry-run -- "Captain, checks are green." 2>&1) || fail "dry-run failed: $out"
  assert_contains "$out" "model=aura-2-helena-en" "the .env voice must be used when the environment has none"
  out=$(env -u DEEPGRAM_API_KEY DEEPGRAM_TTS_MODEL=aura-2-luna-en FM_HOME="$home" FM_DEEPGRAM_ENV_FILE="$home/.env" \
    "$TTS" --dry-run -- "Captain, checks are green." 2>&1) || fail "dry-run failed: $out"
  assert_contains "$out" "model=aura-2-luna-en" "an environment voice must win over the .env one"
  out=$(env -u DEEPGRAM_TTS_MODEL DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_ENV_FILE=/dev/null \
    "$TTS" --dry-run -- "Captain, checks are green." 2>&1) || fail "dry-run failed: $out"
  assert_contains "$out" "model=aura-2-thalia-en" "the documented default must apply when neither sets a voice"
  pass "fm-deepgram-tts: reads the voice from .env, the environment wins, else the default"
}

test_tts_refuses_without_key
test_tts_dry_run_with_key
test_stt_refuses_without_key_or_file
test_stt_prints_transcript_from_mocked_deepgram
test_stt_reports_http_failure
test_floater_help_and_option_refusal
test_floater_signs_with_a_stable_identity
test_floater_build_only_leaves_the_launched_app_alone
test_floater_signing_identity_config_and_fallbacks
test_speak_uses_say_when_key_absent
test_speak_prefers_deepgram_when_key_present
test_speak_prefers_the_configured_voice_over_deepgram
test_speak_refuses_a_voice_this_machine_does_not_have
test_speak_accepts_the_spellings_say_itself_resolves
test_speak_still_speaks_when_the_voice_list_was_cut_off
test_speak_asks_for_the_voice_list_once_per_confirmed_voice
test_speak_leaves_no_voice_list_behind_when_the_register_refuses
test_speak_does_not_swap_to_deepgram_when_say_fails
test_speak_falls_back_to_say_when_deepgram_fails
test_desk_voice_deliver_pending_drain
test_desk_voice_send_types_into_the_primary_pane
test_desk_voice_send_falls_back_without_a_live_primary
test_desk_voice_send_refuses_a_pane_not_hosting_the_primary
test_desk_voice_send_falls_back_when_the_pane_refuses_text
test_desk_voice_send_never_doubles_an_unconfirmed_submit
test_desk_voice_send_falls_back_when_the_pane_shows_a_dialog
test_desk_voice_send_joins_a_pending_draft
test_desk_voice_send_types_screenshots_into_the_primary_pane
test_desk_voice_send_screenshots_fall_back_to_the_mailbox
test_desk_voice_dictation_sends_when_the_chat_is_in_front
test_desk_voice_dictation_elsewhere_is_left_to_paste
test_desk_voice_dictation_keeps_the_send_checks
test_desk_voice_dictation_front_check_on_tmux
test_desk_voice_dictation_refuses_bad_front_arguments
test_desk_voice_shot_captures_the_named_display
test_desk_voice_shot_capture_file_name_has_no_leading_dot
test_desk_voice_shot_keeps_only_the_newest
test_desk_voice_shot_failure_leaves_nothing
test_desk_voice_deliver_with_screenshots
test_floater_swift_tests
test_deepgram_lib_reads_dotenv_without_logging_key
test_tts_reads_the_voice_from_dotenv

#!/usr/bin/env bash
# Behavior tests for the desk voice-out sink.
#
# The property under test is not "audio came out" - nothing here can observe
# that, and the script deliberately claims no more. What is tested is everything
# that must be true BEFORE a sentence reaches a speaker:
#   - a home that never opted in stays silent;
#   - nothing is spoken that the register owner refused;
#   - nothing is spoken that the register owner never shaped;
#   - the caller's turn is never held open by audio or by a hung shaper.
# The register itself is owned by the glasses project and tested there. These
# tests drive a fake owner that implements its documented exit contract, so the
# suite runs anywhere and never depends on that project being cloned.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Ambient Deepgram keys must not divert these say-path fixtures, and an ambient
# register choice would silently replace the one each case is asserting on.
unset DEEPGRAM_API_KEY || true
unset GLASSES_ANNOUNCE_CONFIG || true
export FM_DEEPGRAM_ENV_FILE=/dev/null

SPEAK="$ROOT/bin/fm-speak.sh"
TMP_ROOT=$(fm_test_tmproot fm-speak)

# Each case gets its own home, its own fake owner, and its own speaker log, so
# one case can never read another's state.
new_home() {  # <name> [config-lines...]
  local name=$1
  shift
  mkdir -p "$TMP_ROOT/$name/config"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$TMP_ROOT/$name/config/speak"
  fi
  printf '%s\n' "$TMP_ROOT/$name"
}

# A stand-in for the glasses register owner, faithful to its documented
# contract: exit 0 with the shaped line on stdout, exit 2 with a reason on
# stderr when it refuses, notes on stderr either way.
install_shaper() {  # <home>
  local home=$1
  cat > "$home/shaper" <<'EOF'
#!/usr/bin/env bash
# argv is: --dry-run <text>
shift
text=$*
case "$text" in
  *"Shall I"*|*"shall i"*)
    printf 'refused: asks the captain to decide\n' >&2
    exit 2
    ;;
esac
stripped=$(printf '%s\n' "$text" | sed -E 's#https?://[^ ]*##g; s#(^| )/[^ ]*##g')
case "$stripped" in
  *[![:space:]]*) ;;
  *)
    printf 'refused: nothing speakable left after removing URLs and paths\n' >&2
    exit 2
    ;;
esac
[ "$stripped" = "$text" ] || printf 'note: stripped a url or path\n' >&2
printf '%s\n' "$stripped"
EOF
  chmod +x "$home/shaper"
  printf '%s\n' "$home/shaper"
}

# A stand-in speaker that records exactly what it was handed. It is a single
# exec'd process so a watchdog can kill it the way it kills the real one.
install_speaker() {  # <home> [linger-seconds]
  local home=$1 linger=${2:-0}
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
exec sleep $linger
EOF
  chmod +x "$home/speaker"
  printf '%s\n' "$home/speaker"
}

# The two bounds are driven separately on purpose: SHAPER_TIMEOUT bounds the
# waited-on register call and SPEAKER_TIMEOUT the detached speaker. A case that
# bounds one half must never be able to pass because of the other.
speak() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_SPEAK_SHAPER="$home/shaper" FM_SPEAK_SAY="$home/speaker" \
    FM_SPEAK_SHAPER_TIMEOUT="${SHAPER_TIMEOUT:-15}" \
    FM_SPEAK_TIMEOUT="${SPEAKER_TIMEOUT:-60}" "$SPEAK" "$@"
}

# A register owner that also enforces a spoken budget, the way the real one does:
# it reads GLASSES_ANNOUNCE_CONFIG and cuts the line to seconds x words_per_second
# words BEFORE returning it, which is where a desk line actually loses its
# ending - nothing downstream of this ever sees the missing words. The fallback
# numbers are the glasses announce defaults, so a case that asserts the full line
# survived is asserting that fm-speak chose the desk register, not that this
# stand-in is lenient.
install_register_shaper() {  # <home>
  local home=$1
  cat > "$home/shaper" <<'EOF'
#!/usr/bin/env bash
# argv is: --dry-run <text>
shift
seconds=8
wps=2.6
if [ -n "${GLASSES_ANNOUNCE_CONFIG:-}" ] && [ -f "${GLASSES_ANNOUNCE_CONFIG:-}" ]; then
  value=$(sed -n 's/^[[:space:]]*max_spoken_seconds[[:space:]]*=[[:space:]]*//p' \
    "$GLASSES_ANNOUNCE_CONFIG" | head -1)
  [ -z "$value" ] || seconds=$value
  value=$(sed -n 's/^[[:space:]]*words_per_second[[:space:]]*=[[:space:]]*//p' \
    "$GLASSES_ANNOUNCE_CONFIG" | head -1)
  [ -z "$value" ] || wps=$value
fi
printf '%s\n' "$*" | awk -v s="$seconds" -v w="$wps" '
  NR == 1 {
    n = int(s * w)
    if (n < 1 || NF <= n) { print; next }
    out = $1
    for (i = 2; i <= n; i++) out = out " " $i
    print out
    print "announce note: truncated to the spoken register" > "/dev/stderr"
  }
'
EOF
  chmod +x "$home/shaper"
}

# The desk budget is chosen from the environment before the register owner runs,
# so a case that drives it has to set that environment on the call itself: a
# `VAR=value func` assignment survives a bash function return and would leak the
# case's register choice into every case after it.
speak_env() {  # <home> <name=value> <args...>
  local home=$1 assignment=$2
  shift 2
  env "$assignment" \
    FM_HOME="$home" FM_SPEAK_SHAPER="$home/shaper" FM_SPEAK_SAY="$home/speaker" \
    FM_SPEAK_SHAPER_TIMEOUT="${SHAPER_TIMEOUT:-15}" \
    FM_SPEAK_TIMEOUT="${SPEAKER_TIMEOUT:-60}" "$SPEAK" "$@"
}

# Long enough to be cut by the glasses budget (8s x 2.6 wps = 20 words) and
# short enough to survive the desk one (30s x 2.6 wps = 78 words). It is an
# ordinary three-sentence outcome, which is the point: this is not an unusually
# long line, it is the shape of the lines the captain was losing the end of.
LONG_OUTCOME="The finances fix is on the branch and the checks came back green on the first run. The review found nothing to change. The pull request is waiting for your word before anything lands."

# A register owner that never answers, for the bound cases.
install_hung_shaper() {  # <home>
  printf '#!/usr/bin/env bash\nexec sleep 120\n' > "$1/shaper"
  chmod +x "$1/shaper"
}

# A speaker that would hold the audio device for far longer than any line. It
# records its own pid so a case watches exactly that process: matching a command
# line would pick up any unrelated sleep on the host and pass or fail for
# reasons that have nothing to do with the bound.
install_runaway_speaker() {  # <home>
  local home=$1
  cat > "$home/speaker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$home/speaker.pid"
printf 'started\n' >> "$home/spoken.log"
exec sleep 120
EOF
  chmod +x "$home/speaker"
}

wait_until_gone() {  # <pid> <max-tenths>
  local pid=$1 waited=0
  while [ "$waited" -lt "$2" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  return 1
}

# The speaker is handed the line and detached on purpose, so the call returns
# before any audio starts. Every assertion about what the speaker received has
# to wait for that handoff rather than read the log the instant speak returns.
wait_for_spoken() {  # <log> <msg>
  local log=$1 msg=$2 waited=0
  while [ "$waited" -lt 50 ]; do
    [ ! -s "$log" ] || return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$msg"
}

# The mirror of the wait above: an assertion that nothing was spoken has to give
# a detached speaker time to appear, or it would pass for the wrong reason.
assert_stayed_silent() {  # <log> <msg>
  sleep 0.5
  assert_absent "$1" "$2"
}

# A clone or a new device must never start talking on its own: opt-in is the
# whole reason this can ship to every home without any of them making a sound.
# The bug this repays: desk speech was left on the glasses budget whenever the
# Deepgram key was not detected, so the same outcome finished through one sink
# and stopped mid-sentence through the other. The desk budget belongs to the
# desk, so it applies with no key present at all.
test_a_desk_line_is_not_cut_by_the_glasses_budget() {
  local home out spoken
  home=$(new_home desk-budget "enabled = true")
  install_register_shaper "$home"
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "$LONG_OUTCOME" 2>&1) || fail "speak failed: $out"
  wait_for_spoken "$home/spoken.log" "the shaped line never reached the speaker"
  spoken=$(cat "$home/spoken.log")
  assert_contains "$spoken" "before anything lands." "the line must reach the speaker whole"
  case "$out" in
    *truncated*) fail "the desk register must not truncate this line: $out" ;;
  esac
  pass "fm-speak: a multi-sentence desk line keeps its ending with no Deepgram key present"
}

# The published opt-out for anyone who wants the short glasses cut at the desk.
test_an_empty_register_override_restores_the_glasses_cut() {
  local home out spoken
  home=$(new_home desk-budget-optout "enabled = true")
  install_register_shaper "$home"
  install_speaker "$home" >/dev/null

  out=$(speak_env "$home" FM_SPEAK_DEEPGRAM_REGISTER= "$LONG_OUTCOME" 2>&1) \
    || fail "speak failed: $out"
  wait_for_spoken "$home/spoken.log" "the shaped line never reached the speaker"
  spoken=$(cat "$home/spoken.log")
  assert_contains "$out" "truncated" "the opt-out must still report the cut"
  case "$spoken" in
    *"anything lands"*) fail "the opt-out must keep the glasses cut: $spoken" ;;
  esac
  pass "fm-speak: an empty register override restores the glasses cut"
}

# A caller that has already chosen a register owns that choice: the desk default
# is a default, not an override.
test_an_already_chosen_register_is_never_replaced() {
  local home out spoken
  home=$(new_home desk-budget-preset "enabled = true")
  install_register_shaper "$home"
  install_speaker "$home" >/dev/null
  printf '[register]\nmax_spoken_seconds = 4\nwords_per_second = 2.6\n' > "$home/own-register.toml"

  out=$(speak_env "$home" GLASSES_ANNOUNCE_CONFIG="$home/own-register.toml" "$LONG_OUTCOME" 2>&1) \
    || fail "speak failed: $out"
  wait_for_spoken "$home/spoken.log" "the shaped line never reached the speaker"
  spoken=$(cat "$home/spoken.log")
  assert_contains "$spoken" "and the checks" "the caller's own budget must be the one applied"
  case "$spoken" in
    *green*) fail "the caller's own 4s budget was not applied: $spoken" ;;
  esac
  pass "fm-speak: a register the caller already chose is never replaced by the desk default"
}

test_a_home_that_never_opted_in_stays_silent() {
  local home out code
  home=$(new_home not-opted-in)
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "The fix is green and ready for your review." 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "an unopted home must not look like a failure"
  assert_contains "$out" "not opted in" "the silence must be explicable"
  assert_stayed_silent "$home/spoken.log" "an unopted home must not reach the speaker"
  pass "fm-speak: a home that never opted in stays silent and says why"
}

test_an_absent_config_is_the_same_as_not_opted_in() {
  local home code
  home=$(new_home no-config)
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "The fix is green." >/dev/null 2>&1 && code=0 || code=$?
  expect_code 0 "$code" "an absent config must be inert, not an error"
  assert_stayed_silent "$home/spoken.log" "an absent config must not reach the speaker"
  pass "fm-speak: an absent config leaves the home inert"
}

test_an_opted_in_home_speaks_the_shaped_line() {
  local home out code
  home=$(new_home opted-in "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "The fix is green and ready for your review.") && code=0 || code=$?
  expect_code 0 "$code" "a clean line must be spoken"
  assert_contains "$out" "The fix is green" "the shaped line is reported back to the caller"
  wait_for_spoken "$home/spoken.log" "the speaker was never handed the line"
  assert_grep "text: The fix is green and ready for your review." "$home/spoken.log" \
    "the speaker must receive the shaped line"
  pass "fm-speak: an opted-in home speaks the shaped line"
}

# The captain's standing rule, enforced by the register owner and honored here:
# money, outward and destructive choices are never put to him by voice.
test_a_request_for_a_spoken_yes_is_never_spoken() {
  local home out code
  home=$(new_home refusal "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "Shall I merge the PR and delete the branch?" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "a refusal has its own exit code"
  assert_contains "$out" "asks the captain to decide" "the owner's reason must reach the caller"
  assert_contains "$out" "nothing was spoken" "the refusal must say nothing was spoken"
  assert_stayed_silent "$home/spoken.log" "a refused line must never reach the speaker"
  pass "fm-speak: a request for a spoken yes is reported, never spoken"
}

# Speaking a URL aloud is the one thing the register forbids outright, so a line
# that is nothing but a link must end in silence rather than in a read-out link.
test_a_line_that_is_only_a_link_is_not_spoken() {
  local home code
  home=$(new_home only-link "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "https://github.com/x/y/pull/42" >/dev/null 2>&1 && code=0 || code=$?
  expect_code 2 "$code" "an unspeakable line must be refused"
  assert_stayed_silent "$home/spoken.log" "an unspeakable line must never reach the speaker"
  pass "fm-speak: a line that is only a link ends in silence"
}

test_the_speaker_receives_the_stripped_line_not_the_raw_one() {
  local home
  home=$(new_home stripped "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "The fix is green at https://example.com/pr/42 now." >/dev/null 2>&1

  wait_for_spoken "$home/spoken.log" "the speaker was never handed the line"
  assert_no_grep "example.com" "$home/spoken.log" "the speaker must never receive a URL"
  assert_grep "text: The fix is green at  now." "$home/spoken.log" \
    "the speaker must receive exactly what the owner shaped"
  pass "fm-speak: the speaker receives the shaped line, never the raw one"
}

test_dry_run_never_reaches_the_speaker() {
  local home out code
  home=$(new_home dry "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" --dry-run "The fix is green.") && code=0 || code=$?
  expect_code 0 "$code" "a dry run reports success"
  assert_contains "$out" "The fix is green." "a dry run prints what would be spoken"
  assert_stayed_silent "$home/spoken.log" "a dry run must make no sound"
  pass "fm-speak: a dry run prints the line and makes no sound"
}

# The turn-blocking property. A caller reading this through a command
# substitution must not be held open until the audio finishes.
test_the_caller_is_never_held_open_by_audio_still_playing() {
  local home started finished elapsed out
  home=$(new_home nonblocking "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" 20 >/dev/null

  started=$(date +%s)
  out=$(speak "$home" "The fix is green.")
  finished=$(date +%s)
  elapsed=$((finished - started))

  assert_contains "$out" "The fix is green." "the caller still gets the spoken line"
  [ "$elapsed" -lt 10 ] \
    || fail "fm-speak: the caller waited ${elapsed}s for audio that plays for 20s"
  pass "fm-speak: the caller is never held open by audio that is still playing"
}

test_a_runaway_speaker_is_killed_at_the_bound() {
  local home speaker_pid
  home=$(new_home bounded "enabled = true")
  install_shaper "$home" >/dev/null
  install_runaway_speaker "$home"

  SPEAKER_TIMEOUT=1 speak "$home" "The fix is green." >/dev/null 2>&1
  wait_for_spoken "$home/spoken.log" "the speaker was never started"
  speaker_pid=$(cat "$home/speaker.pid")
  kill -0 "$speaker_pid" 2>/dev/null || fail "fm-speak: the speaker was never running to bound"

  if ! wait_until_gone "$speaker_pid" 50; then
    kill "$speaker_pid" 2>/dev/null || true
    fail "fm-speak: a runaway speaker outlived its bound"
  fi
  pass "fm-speak: a runaway speaker is killed at its bound"
}

# The two bounds protect different things and must not collapse into one value:
# a short speaker bound must not cut the register call short, and a short
# register bound must not cut the speaker short.
test_the_speaker_bound_does_not_bound_the_register_call() {
  local home started elapsed code
  home=$(new_home speaker-bound-only "enabled = true")
  install_speaker "$home" >/dev/null
  install_hung_shaper "$home"

  started=$(date +%s)
  SHAPER_TIMEOUT=3 SPEAKER_TIMEOUT=1 speak "$home" "The fix is green." >/dev/null 2>&1 && code=0 || code=$?
  elapsed=$(( $(date +%s) - started ))

  expect_code 1 "$code" "a bounded owner that never answered is an error"
  [ "$elapsed" -ge 2 ] \
    || fail "fm-speak: the register call was cut at ${elapsed}s by the speaker bound of 1s"
  [ "$elapsed" -lt 30 ] || fail "fm-speak: a hung owner held the turn for ${elapsed}s"
  pass "fm-speak: the speaker bound does not bound the register call"
}

test_the_register_bound_does_not_bound_the_speaker() {
  local home speaker_pid
  home=$(new_home register-bound-only "enabled = true")
  install_shaper "$home" >/dev/null
  install_runaway_speaker "$home"

  SHAPER_TIMEOUT=1 SPEAKER_TIMEOUT=3 speak "$home" "The fix is green." >/dev/null 2>&1
  wait_for_spoken "$home/spoken.log" "the speaker was never started"
  speaker_pid=$(cat "$home/speaker.pid")

  sleep 2
  if ! kill -0 "$speaker_pid" 2>/dev/null; then
    fail "fm-speak: the speaker was cut before its 3s bound by the register bound of 1s"
  fi
  if ! wait_until_gone "$speaker_pid" 50; then
    kill "$speaker_pid" 2>/dev/null || true
    fail "fm-speak: a runaway speaker outlived its own bound"
  fi
  pass "fm-speak: the register bound does not bound the speaker"
}

# Speaking unshaped text would read a URL aloud, so an unreachable owner must
# end in silence rather than in a fallback that bypasses the register.
test_an_unreachable_register_owner_ends_in_silence() {
  local home out code
  home=$(new_home no-shaper "enabled = true")
  install_speaker "$home" >/dev/null

  out=$(FM_HOME="$home" FM_SPEAK_SHAPER="$home/missing" FM_SPEAK_SAY="$home/speaker" \
    "$SPEAK" "The fix is green at https://example.com/pr/42." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an unreachable owner is an error, not a refusal"
  assert_contains "$out" "register owner is not executable" "the caller must learn what is missing"
  assert_stayed_silent "$home/spoken.log" "unshaped text must never reach the speaker"
  pass "fm-speak: an unreachable register owner ends in silence, never in unshaped speech"
}

test_a_failing_register_owner_ends_in_silence() {
  local home out code
  home=$(new_home broken-shaper "enabled = true")
  install_speaker "$home" >/dev/null
  printf '#!/usr/bin/env bash\nprintf "boom\\n" >&2\nexit 7\n' > "$home/shaper"
  chmod +x "$home/shaper"

  out=$(speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an owner failure is an error"
  assert_contains "$out" "nothing was spoken" "the caller must learn nothing was spoken"
  assert_stayed_silent "$home/spoken.log" "a failed shaping must never reach the speaker"
  pass "fm-speak: a failing register owner ends in silence"
}

test_a_hung_register_owner_does_not_hold_the_turn_open() {
  local home started elapsed out code
  home=$(new_home hung-shaper "enabled = true")
  install_speaker "$home" >/dev/null
  install_hung_shaper "$home"

  started=$(date +%s)
  out=$(SHAPER_TIMEOUT=1 speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  elapsed=$(( $(date +%s) - started ))

  expect_code 1 "$code" "a bounded owner that never answered is an error"
  [ "$elapsed" -lt 30 ] || fail "fm-speak: a hung owner held the turn for ${elapsed}s"
  assert_contains "$out" "exceeded its 1s bound" \
    "a bounded-out owner must be reported as exceeding its bound, not as a generic failure"
  assert_contains "$out" "FM_SPEAK_SHAPER_TIMEOUT" "the diagnostic must name the bound's override"
  assert_contains "$out" "nothing was spoken" "the caller must learn nothing was spoken"
  assert_stayed_silent "$home/spoken.log" "a bounded-out shaping must never reach the speaker"
  pass "fm-speak: a hung register owner does not hold the caller's turn open"
}

# The register owner must never see the caller's stdin: an owner that reads it
# while this script is driven through a pipe or a terminal would hang until its
# bound and turn every spoken line into an owner failure.
test_the_register_owner_never_inherits_the_callers_stdin() {
  local home started elapsed out code holder
  home=$(new_home stdin-closed "enabled = true")
  install_speaker "$home" >/dev/null
  cat > "$home/shaper" <<'EOF'
#!/usr/bin/env bash
shift
while IFS= read -r _; do :; done
printf '%s\n' "$*"
EOF
  chmod +x "$home/shaper"

  # A stdin that stays open without ever closing, the way a terminal or a live
  # pipe would, held by a writer outside the command substitution so the
  # substitution itself is not what waits for it.
  mkfifo "$home/stdin"
  sleep 20 > "$home/stdin" &
  holder=$!

  started=$(date +%s)
  out=$(SHAPER_TIMEOUT=5 speak "$home" "The fix is green." 2>&1 < "$home/stdin") && code=0 || code=$?
  elapsed=$(( $(date +%s) - started ))
  { kill "$holder" && wait "$holder"; } 2>/dev/null || true

  expect_code 0 "$code" "an owner that reads stdin must still answer promptly"
  [ "$elapsed" -lt 4 ] || fail "fm-speak: the owner hung on inherited stdin for ${elapsed}s"
  assert_contains "$out" "The fix is green." "the shaped line must still come back"
  pass "fm-speak: the register owner never inherits the caller's stdin"
}

test_a_non_integer_bound_is_refused() {
  local home out code
  home=$(new_home bad-bound "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(SHAPER_TIMEOUT=soon speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a non-integer register bound must be refused"
  assert_contains "$out" "FM_SPEAK_SHAPER_TIMEOUT must be a positive integer" \
    "the refusal must name the register bound"

  out=$(SPEAKER_TIMEOUT=0 speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a zero speaker bound must be refused"
  assert_contains "$out" "FM_SPEAK_TIMEOUT must be a positive integer" \
    "the refusal must name the speaker bound"
  assert_stayed_silent "$home/spoken.log" "an invalid bound must never reach the speaker"
  pass "fm-speak: a non-integer bound is refused for either half"
}

test_a_missing_speech_binary_is_reported_not_guessed() {
  local home out code
  home=$(new_home no-say "enabled = true")
  install_shaper "$home" >/dev/null

  out=$(FM_HOME="$home" FM_SPEAK_SHAPER="$home/shaper" FM_SPEAK_SAY="$home/absent-say" \
    "$SPEAK" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a missing speaker is an error"
  assert_contains "$out" "no speech binary" "the caller must learn which binary is missing"
  pass "fm-speak: a missing speech binary is reported rather than guessed around"
}

test_the_configured_voice_reaches_the_speaker() {
  local home
  home=$(new_home voiced "enabled = true" "voice = Eddy (English (UK))")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "The fix is green." >/dev/null 2>&1

  wait_for_spoken "$home/spoken.log" "the speaker was never handed the line"
  assert_grep "argv: -v Eddy (English (UK)) -f " "$home/spoken.log" \
    "a voice name with spaces must reach the speaker as one argument"
  pass "fm-speak: the configured voice reaches the speaker intact"
}

# A shaped sentence is handed over in a file, so no sentence can ever be parsed
# as an option by the speaker.
test_a_sentence_is_never_passed_as_a_speaker_argument() {
  local home
  home=$(new_home argv-safe "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "The fix is green." >/dev/null 2>&1
  wait_for_spoken "$home/spoken.log" "the speaker was never handed the line"
  grep '^argv:' "$home/spoken.log" > "$home/argv-only"

  assert_no_grep "The fix is green" "$home/argv-only" \
    "the sentence must not appear in the speaker's argument list"
  assert_grep "text: The fix is green." "$home/spoken.log" \
    "the sentence must arrive through the handed-over file"
  pass "fm-speak: a sentence is handed over in a file, never as an argument"
}

test_an_unknown_config_key_is_refused_rather_than_parked() {
  local home out code
  home=$(new_home unknown-key "enabled = true" "relay_token = secret")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an unknown key must refuse rather than be ignored"
  assert_contains "$out" "unknown config key: relay_token" "the refusal must name the key"
  assert_stayed_silent "$home/spoken.log" "an invalid config must never reach the speaker"
  pass "fm-speak: an unknown config key is refused rather than parked in this file"
}

test_a_non_boolean_enabled_is_refused() {
  local home out code
  home=$(new_home bad-enabled "enabled = yes")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a non-boolean opt-in must not be guessed"
  assert_contains "$out" "enabled must be true or false" "the refusal must say what is wrong"
  assert_stayed_silent "$home/spoken.log" "an invalid opt-in must never reach the speaker"
  pass "fm-speak: a non-boolean opt-in is refused rather than guessed"
}

test_a_symlinked_config_is_refused() {
  local home out code
  home=$(new_home symlink-config)
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  printf 'enabled = true\n' > "$TMP_ROOT/elsewhere-speak"
  ln -s "$TMP_ROOT/elsewhere-speak" "$home/config/speak"

  out=$(speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a symlinked config must be refused"
  assert_contains "$out" "config must be a regular file" "the refusal must say why"
  assert_stayed_silent "$home/spoken.log" "a symlinked config must never reach the speaker"
  pass "fm-speak: a symlinked config is refused"
}

test_blank_text_is_refused_before_anything_is_shaped() {
  local home out code
  home=$(new_home blank "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" "   " 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "blank text is a usage error"
  assert_contains "$out" "nothing to speak" "the refusal must say what was missing"
  assert_stayed_silent "$home/spoken.log" "blank text must never reach the speaker"
  pass "fm-speak: blank text is refused before anything is shaped"
}

# A speaker that records the moment it finished, not just the moment it started.
# Every other case here can settle for the handoff; this one has to know whether
# the line reached its end, because that is the whole difference between a
# captain who heard the outcome and a captain who heard half of it.
install_finishing_speaker() {  # <home> <linger-seconds>
  local home=$1 linger=$2
  cat > "$home/speaker" <<EOF
#!/usr/bin/env bash
printf 'started\n' >> "$home/spoken.log"
sleep $linger
printf 'finished\n' >> "$home/spoken.log"
EOF
  chmod +x "$home/speaker"
}

# The cutoff the captain actually reported, and the one property the earlier
# fixes to this script never covered. Closing the speaker's standard streams
# detaches it from the caller's turn but leaves it in the caller's PROCESS
# GROUP, and an agent harness reaps a finished command's process group when its
# turn ends - which is precisely when firstmate speaks, right after a
# captain-facing reply. So the audio was killed a moment after it started.
#
# The signature that made it visible is asserted here too: a speaker removes the
# temporary file it was handed only after the line has finished, so a file left
# behind is the same evidence as a sentence that stopped halfway.
test_a_reap_of_the_callers_process_group_does_not_cut_the_line() {
  local home scratch caller waited left
  home=$(new_home group-reap "enabled = true")
  install_shaper "$home" >/dev/null
  install_finishing_speaker "$home" 4
  scratch="$TMP_ROOT/group-reap-scratch"
  mkdir -p "$scratch"

  # Job control puts the stand-in caller in a process group of its own, so the
  # reap below is aimed exactly where a harness aims it and can never reach this
  # suite.
  set -m
  ( TMPDIR="$scratch" speak "$home" "The fix is green." >/dev/null 2>&1 ) &
  caller=$!
  set +m
  wait "$caller" 2>/dev/null || true
  wait_for_spoken "$home/spoken.log" "the speaker was never started"
  kill -TERM "-$caller" 2>/dev/null || true

  # The speaker writes its end marker and only then removes the file it was
  # handed, so both halves of the signature have to be waited for together -
  # counting the moment the marker lands would read a file the speaker is still
  # a few milliseconds from cleaning up.
  waited=0
  left=1
  while [ "$waited" -lt 50 ]; do
    left=$(find "$scratch" -name 'fm-speak-*' 2>/dev/null | wc -l | tr -d ' ')
    ! grep -q finished "$home/spoken.log" 2>/dev/null || [ "$left" != 0 ] || break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_grep finished "$home/spoken.log" \
    "fm-speak: the line was cut short when the caller's process group was reaped"

  [ "$left" = 0 ] \
    || fail "fm-speak: a cut-short speaker left $left temporary file(s) behind"
  pass "fm-speak: a reap of the caller's process group does not cut the line short"
}

test_no_temporary_files_are_left_behind() {
  local home scratch left
  home=$(new_home tempfiles "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  scratch="$TMP_ROOT/tempfiles-scratch"
  mkdir -p "$scratch"

  TMPDIR="$scratch" speak "$home" "The fix is green." >/dev/null 2>&1
  TMPDIR="$scratch" speak "$home" "Shall I merge the PR?" >/dev/null 2>&1
  sleep 2

  left=$(find "$scratch" -name 'fm-speak-*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$left" = 0 ] || fail "fm-speak: $left temporary file(s) were left behind"
  pass "fm-speak: no temporary files are left behind"
}

# A speaker that records when a line starts and when it actually finishes, so
# overlapping playback is visible as a second start before the first end.
install_marking_speaker() {  # <home> <linger-seconds>
  local home=$1 linger=$2
  cat > "$home/speaker" <<EOF
#!/usr/bin/env bash
text=
prev=
for a in "\$@"; do
  [ "\$prev" != -f ] || text=\$(cat "\$a")
  prev=\$a
done
printf 'start: %s\n' "\$text" >> "$home/spoken.log"
sleep $linger
printf 'end: %s\n' "\$text" >> "$home/spoken.log"
EOF
  chmod +x "$home/speaker"
}

wait_for_content() {  # <path> <needle> <msg>
  local path=$1 needle=$2 msg=$3 waited=0
  while [ "$waited" -lt 250 ]; do
    grep -qF "$needle" "$path" 2>/dev/null && return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$msg"
}

assert_playback_did_not_overlap() {  # <log>
  local log=$1 in_progress=0 line snapshot
  snapshot=$(cat "$log")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      start:*)
        [ "$in_progress" -eq 0 ] || fail "fm-speak: a second line started before the first ended: $snapshot"
        in_progress=1
        ;;
      end:*)
        [ "$in_progress" -eq 1 ] || fail "fm-speak: an end marker arrived with no line in progress: $snapshot"
        in_progress=0
        ;;
    esac
  done <<EOF
$snapshot
EOF
  [ "$in_progress" -eq 0 ] || fail "fm-speak: a line started and never ended: $snapshot"
}

# The Helena 2026-09-17 failure: two sequential speak calls from one shell
# handed audio off and returned, so the second line started while the first
# was still playing. The caller must still return before either line finishes.
test_two_sequential_calls_do_not_overlap_playback() {
  local home started finished elapsed
  home=$(new_home serialize "enabled = true")
  install_shaper "$home" >/dev/null
  # One line of audio has to outlast the handoff budget below by a wide
  # margin: the proof is that both calls returned while the first line was
  # still playing, not that the pair happened to be quick.
  install_marking_speaker "$home" 12

  started=$(date +%s)
  speak "$home" "The first line is green." >/dev/null 2>&1 \
    || fail "fm-speak: the first sequential call failed"
  speak "$home" "The second line is ready." >/dev/null 2>&1 \
    || fail "fm-speak: the second sequential call failed"
  finished=$(date +%s)
  elapsed=$((finished - started))

  [ "$elapsed" -lt 8 ] \
    || fail "fm-speak: sequential calls waited ${elapsed}s for audio instead of handing off"

  # Nothing orders the two speakers, so both end markers have to land before
  # the log is a complete snapshot: waiting on one of them can catch the other
  # line mid-play and read its dangling start as an overlap.
  wait_for_content "$home/spoken.log" "end: The first line is green." \
    "fm-speak: sequential calls never finished the first line"
  wait_for_content "$home/spoken.log" "end: The second line is ready." \
    "fm-speak: sequential calls never finished the second line"
  assert_grep "start: The first line is green." "$home/spoken.log" \
    "the first line must reach the speaker"
  assert_grep "start: The second line is ready." "$home/spoken.log" \
    "the second line must reach the speaker"
  assert_playback_did_not_overlap "$home/spoken.log"
  pass "fm-speak: two sequential calls from one shell do not overlap playback"
}

# The lock is per home, so two homes may speak at the same time.
test_two_homes_may_speak_at_the_same_time() {
  local home_a home_b waited=0
  home_a=$(new_home serialize-a "enabled = true")
  home_b=$(new_home serialize-b "enabled = true")
  install_shaper "$home_a" >/dev/null
  install_shaper "$home_b" >/dev/null
  # The linger has to outlast the poll below by a wide margin: home A's `end:`
  # marker landing while the loop is still waiting for home B would fail the
  # overlap proof with a complaint about lock scope that scheduling caused.
  install_marking_speaker "$home_a" 15
  install_marking_speaker "$home_b" 15

  speak "$home_a" "Home A is speaking." >/dev/null 2>&1 \
    || fail "fm-speak: home A failed to speak"
  speak "$home_b" "Home B is speaking." >/dev/null 2>&1 \
    || fail "fm-speak: home B failed to speak"

  while [ "$waited" -lt 20 ]; do
    if grep -qF "start: Home A is speaking." "$home_a/spoken.log" 2>/dev/null \
      && grep -qF "start: Home B is speaking." "$home_b/spoken.log" 2>/dev/null; then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  grep -qF "start: Home A is speaking." "$home_a/spoken.log" 2>/dev/null \
    || fail "fm-speak: home A never started"
  grep -qF "start: Home B is speaking." "$home_b/spoken.log" 2>/dev/null \
    || fail "fm-speak: home B never started within the overlap window"
  grep -qF "end:" "$home_a/spoken.log" 2>/dev/null \
    && fail "fm-speak: home A finished before home B started, so the lock is not home-scoped"
  pass "fm-speak: two homes may speak at the same time"
}

# A speaker that is killed outright leaves its lock behind in persistent state,
# and that pid number is eventually handed to some unrelated process. Liveness
# alone then reads the lock as held forever and the home never speaks again, so
# the recorded identity has to be what decides. The squatter here stands in for
# the reusing process: alive, holding the lock, and not the speaker that took
# it.
test_a_lock_whose_pid_was_reused_is_reclaimed() {
  local home owner squatter
  home=$(new_home reused-lock "enabled = true")
  install_shaper "$home" >/dev/null
  install_marking_speaker "$home" 1

  owner="$home/state/.speak.lock.owner.stale"
  mkdir -p "$owner"
  # Outliving the whole case is the point: a squatter that exits on its own
  # hands the lock back through the ordinary dead-owner steal, and the case
  # would then pass without ever reclaiming anything.
  sleep 300 &
  squatter=$!
  fm_test_track_pid "$squatter"
  printf '%s\n' "$squatter" > "$owner/pid"
  printf '%s\n' 'the identity of a speaker that is long gone' > "$owner/pid-identity"
  ln -s "$owner" "$home/state/.speak.lock"

  speak "$home" "The stale lock did not silence me." >/dev/null 2>&1 \
    || fail "fm-speak: the call behind a reused-pid lock failed"
  wait_for_content "$home/spoken.log" "end: The stale lock did not silence me." \
    "fm-speak: a lock left behind on a reused pid silenced the home"
  kill "$squatter" 2>/dev/null || true
  pass "fm-speak: a lock whose recorded pid was reused is reclaimed"
}

# A register owner that records every call, so "nothing was shaped" is an
# observable fact rather than an inference from the absence of leftovers.
install_recording_shaper() {  # <home>
  local home=$1
  cat > "$home/shaper" <<EOF
#!/usr/bin/env bash
printf 'called: %s\n' "\$*" >> "$home/shaper.log"
shift
printf '%s\n' "\$*"
EOF
  chmod +x "$home/shaper"
}

# The lock lives in the state directory, so a state directory that cannot be
# created has to be refused before a word is shaped. Refusing it afterwards
# would spend the register owner on a line that is then thrown away, abort a
# line that was already spoken for, and leave its temporary file behind,
# spending the one signal this script keeps for a speaker that was cut short.
test_an_unusable_state_directory_is_refused_before_anything_is_shaped() {
  local home scratch out status=0 left
  home=$(new_home unusable-state "enabled = true")
  install_recording_shaper "$home"
  install_speaker "$home" >/dev/null
  scratch="$TMP_ROOT/unusable-state-scratch"
  mkdir -p "$scratch"
  printf 'a regular file where the state directory belongs\n' > "$home/state"

  out=$(TMPDIR="$scratch" speak "$home" "The fix is green." 2>"$home/refusal") || status=$?
  [ "$status" -ne 0 ] \
    || fail "fm-speak: an unusable state directory was reported as a spoken line"
  [ ! -f "$home/shaper.log" ] \
    || fail "fm-speak: the register owner was spent on a line that was never spoken"
  assert_grep "fm-speak:" "$home/refusal" \
    "the refusal must name the tool that refused"
  [ -z "$out" ] \
    || fail "fm-speak: a line was reported spoken with no state directory: $out"
  [ ! -f "$home/spoken.log" ] \
    || fail "fm-speak: a line reached the speaker with no state directory"
  left=$(find "$scratch" -name 'fm-speak-*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$left" = 0 ] \
    || fail "fm-speak: $left temporary file(s) were left behind by the refusal"
  pass "fm-speak: an unusable state directory is refused before anything is shaped"
}

# The desk floater's Mute button: voice goes quiet until unmuted, while the
# caller still sees success because the text reply is the authoritative one.
test_mute_silences_every_line_until_unmuted() {
  local home out code
  home=$(new_home mute "enabled = true")
  install_recording_shaper "$home"
  install_speaker "$home" >/dev/null

  out=$(speak "$home" --muted) || fail "fm-speak: --muted failed"
  assert_equals "unmuted" "$out" "a fresh home must read as unmuted"
  speak "$home" --mute >/dev/null 2>&1 || fail "fm-speak: --mute failed"
  out=$(speak "$home" --muted) || fail "fm-speak: --muted failed"
  assert_equals "muted" "$out" "--mute must be visible through --muted"

  out=$(speak "$home" "The fix is green." 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "a muted line must not look like a failure"
  assert_contains "$out" "muted" "the silence must be explicable"
  assert_stayed_silent "$home/spoken.log" "a muted home must not reach the speaker"
  [ ! -f "$home/shaper.log" ] || fail "fm-speak: a muted line was still shaped"

  speak "$home" --unmute >/dev/null 2>&1 || fail "fm-speak: --unmute failed"
  speak "$home" "The fix is green." >/dev/null 2>&1 || fail "fm-speak: an unmuted line failed"
  wait_for_spoken "$home/spoken.log" "an unmuted home must speak again"
  pass "fm-speak: mute silences every line until unmuted"
}

# The Stop button: the line playing now is cut, a line already queued behind it
# never starts, and a line handed over after the stop still plays.
test_stop_cuts_the_current_line_and_cancels_the_queued_one() {
  local home waited=0
  home=$(new_home stop "enabled = true")
  install_shaper "$home" >/dev/null
  install_marking_speaker "$home" 20

  speak "$home" "The first line is long." >/dev/null 2>&1 || fail "fm-speak: the first line failed"
  wait_for_content "$home/spoken.log" "start: The first line is long." \
    "fm-speak: the first line never started"
  speak "$home" "The queued line waits." >/dev/null 2>&1 || fail "fm-speak: the queued line failed"
  speak "$home" --stop || fail "fm-speak: --stop failed"
  while [ -e "$home/state/.speak.lock" ] && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ ! -e "$home/state/.speak.lock" ] || fail "fm-speak: the stopped line kept the playback lock"

  speak "$home" "The line after the stop plays." >/dev/null 2>&1 \
    || fail "fm-speak: the line after the stop failed"
  wait_for_content "$home/spoken.log" "start: The line after the stop plays." \
    "fm-speak: a line handed over after the stop was cancelled too"
  assert_no_grep "end: The first line is long." "$home/spoken.log" \
    "fm-speak: the playing line was not cut short"
  assert_no_grep "The queued line waits." "$home/spoken.log" \
    "fm-speak: a line queued before the stop still started"
  speak "$home" --stop || fail "fm-speak: the cleanup --stop failed"
  pass "fm-speak: stop cuts the current line and cancels the one queued behind it"
}

# The Repeat button replays the last line that was actually handed to a speaker,
# as it was shaped: never a refused line, and never before anything was spoken.
test_repeat_speaks_the_last_spoken_line_again() {
  local home out code
  home=$(new_home repeat "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" --repeat 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "repeat with nothing spoken is an error"
  assert_contains "$out" "nothing to repeat" "the refusal must say why"

  speak "$home" "The fix is green, see https://example.test/pr/1" >/dev/null 2>&1 \
    || fail "fm-speak: the first line failed"
  speak "$home" "Shall I merge it?" >/dev/null 2>&1 || true
  wait_for_spoken "$home/spoken.log" "the first line never reached the speaker"
  : > "$home/spoken.log"
  out=$(speak "$home" --repeat) || fail "fm-speak: --repeat failed"
  assert_contains "$out" "The fix is green, see" "repeat reports the line it replayed"
  wait_for_spoken "$home/spoken.log" "the repeat never reached the speaker"
  assert_grep "text: The fix is green, see" "$home/spoken.log" \
    "the repeat must replay the last spoken line"
  assert_no_grep "https://" "$home/spoken.log" "the repeat must replay the shaped line"
  assert_no_grep "Shall I" "$home/spoken.log" "a refused line must never be repeated"

  : > "$home/spoken.log"
  speak "$home" --mute >/dev/null 2>&1 || fail "fm-speak: --mute failed"
  speak "$home" --repeat >/dev/null 2>&1 || fail "fm-speak: a muted repeat must not fail"
  sleep 0.5
  [ ! -s "$home/spoken.log" ] || fail "fm-speak: a repeat was spoken while muted"
  pass "fm-speak: repeat replays the last spoken line, never a refused one, and honours mute"
}

# The floater's recent-replies list: newest first, each with a number that stays
# with its reply, bounded to the newest ten, and never holding a refused line.
test_history_lists_the_newest_ten_replies_newest_first() {
  local home out n first last count
  home=$(new_home history "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  out=$(speak "$home" --history) || fail "fm-speak: --history failed on an empty home"
  assert_equals "" "$out" "an empty history must print nothing"

  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    speak "$home" "Reply $n is green." >/dev/null 2>&1 || fail "fm-speak: reply $n failed"
  done
  speak "$home" "Shall I merge it?" >/dev/null 2>&1 || true

  out=$(speak "$home" --history) || fail "fm-speak: --history failed"
  count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  assert_equals 10 "$count" "the history must keep only the newest ten replies"
  first=$(printf '%s\n' "$out" | head -n 1)
  last=$(printf '%s\n' "$out" | tail -n 1)
  assert_equals "12" "$(printf '%s' "$first" | cut -f 1)" "the newest reply must be listed first"
  assert_equals "Reply 12 is green." "$(printf '%s' "$first" | cut -f 3)" "the listed text is the shaped line"
  assert_equals "Reply 3 is green." "$(printf '%s' "$last" | cut -f 3)" "the oldest kept reply must be listed last"
  printf '%s' "$first" | cut -f 2 | grep -Eq '^[0-9]+$' \
    || fail "fm-speak: the listed time must be epoch seconds: $first"
  assert_equals 3 "$(printf '%s' "$first" | awk -F '\t' '{ print NF }')" "each listed reply has exactly three columns"
  assert_not_contains "$out" "Shall I" "a refused line must never be kept"
  pass "fm-speak: the history lists the newest ten replies, newest first"
}

# Choosing a reply from the list plays that reply, even after a newer one has
# arrived, and a number that is not kept is refused rather than guessed.
test_replay_speaks_the_chosen_reply() {
  local home out code number
  home=$(new_home replay "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null

  speak "$home" "The first reply." >/dev/null 2>&1 || fail "fm-speak: the first reply failed"
  number=$(speak "$home" --history | cut -f 1)
  speak "$home" "The second reply." >/dev/null 2>&1 || fail "fm-speak: the second reply failed"
  speak "$home" "The third reply." >/dev/null 2>&1 || fail "fm-speak: the third reply failed"
  # Queued lines play one at a time but in no fixed order, so all three must
  # have played before the log is cleared.
  wait_for_content "$home/spoken.log" "text: The first reply." "fm-speak: the first reply never played"
  wait_for_content "$home/spoken.log" "text: The second reply." "fm-speak: the second reply never played"
  wait_for_content "$home/spoken.log" "text: The third reply." "fm-speak: the third reply never played"
  : > "$home/spoken.log"

  out=$(speak "$home" --replay "$number") || fail "fm-speak: --replay failed"
  assert_equals "The first reply." "$out" "replay reports the line it replayed"
  wait_for_content "$home/spoken.log" "text: The first reply." \
    "fm-speak: the replay did not speak the chosen reply"
  assert_no_grep "second" "$home/spoken.log" "the replay must speak only the chosen reply"
  assert_no_grep "third" "$home/spoken.log" "the replay must speak only the chosen reply"
  out=$(speak "$home" --history | wc -l | tr -d ' ')
  assert_equals 3 "$out" "a replay must not add a reply to the history"

  out=$(speak "$home" --replay 99 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a reply number that is not kept is an error"
  assert_contains "$out" "no reply numbered 99" "the refusal must say why"
  for bad in 0 abc ''; do
    speak "$home" --replay "$bad" >/dev/null 2>&1 && code=0 || code=$?
    expect_code 1 "$code" "--replay '$bad' must be refused"
  done
  speak "$home" --replay >/dev/null 2>&1 && code=0 || code=$?
  expect_code 1 "$code" "--replay without a number must be refused"

  : > "$home/spoken.log"
  speak "$home" --mute >/dev/null 2>&1 || fail "fm-speak: --mute failed"
  out=$(speak "$home" --replay "$number" 2>&1) || fail "fm-speak: a muted replay must not fail"
  assert_contains "$out" "muted" "a muted replay must say why it stayed silent"
  sleep 0.5
  [ ! -s "$home/spoken.log" ] || fail "fm-speak: a replay was spoken while muted"
  pass "fm-speak: replay speaks the chosen reply, refuses unknown numbers, and honours mute"
}

# The Deepgram stand-ins: synthesis writes audio naming the line it was asked
# for, and the player records what it played, so a replay that skipped the
# network is visible as a play with no synthesis beside it.
install_deepgram() {  # <home> [player-linger-seconds]
  local home=$1 linger=${2:-0}
  printf 'DEEPGRAM_API_KEY=test-key-not-real\n' > "$home/.env"
  cat > "$home/deepgram-tts" <<EOF
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --to) out=\$2; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
printf 'synth: %s\n' "\$*" >> "$home/deepgram.log"
printf 'audio of %s' "\$*" > "\$out"
EOF
  cat > "$home/afplay" <<EOF
#!/usr/bin/env bash
printf 'start: %s\n' "\$(cat "\$1")" >> "$home/played.log"
sleep $linger
printf 'end: %s\n' "\$(cat "\$1")" >> "$home/played.log"
EOF
  chmod +x "$home/deepgram-tts" "$home/afplay"
}

speak_dg() {  # <home> <env-file> <args...>
  local home=$1 envfile=$2
  shift 2
  FM_DEEPGRAM_ENV_FILE="$envfile" FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
    FM_DEEPGRAM_AFPLAY="$home/afplay" speak "$home" "$@"
}

count_lines() {  # <file>
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '0\n'; fi
}

wait_for_lines() {  # <file> <count> <msg>
  local waited=0
  while [ "$waited" -lt 50 ]; do
    [ "$(count_lines "$1")" -lt "$2" ] || return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$3"
}

# The captain's complaint: Repeat was slow because it synthesized the line over
# the network again. A reply Deepgram already synthesized replays from its kept
# audio; one with no kept audio is synthesized once and kept for next time.
test_a_replay_plays_kept_audio_without_synthesizing_again() {
  local home out
  home=$(new_home replay-audio "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  install_deepgram "$home"

  speak_dg "$home" "$home/.env" "The fix is green." >/dev/null 2>&1 || fail "fm-speak: the line failed"
  wait_for_content "$home/played.log" "end: audio of The fix is green." \
    "fm-speak: the synthesized line never played"
  assert_equals 1 "$(count_lines "$home/deepgram.log")" "the line must be synthesized once"

  out=$(speak_dg "$home" "$home/.env" --repeat) || fail "fm-speak: --repeat failed"
  assert_equals "The fix is green." "$out" "repeat reports the line it replayed"
  wait_for_lines "$home/played.log" 4 "fm-speak: the kept audio never played"
  assert_equals 4 "$(count_lines "$home/played.log")" "the kept audio must play a second time"
  assert_equals 1 "$(count_lines "$home/deepgram.log")" "a repeat with kept audio must not synthesize again"
  [ ! -s "$home/spoken.log" ] || fail "fm-speak: say spoke a reply that had kept audio"

  # A reply spoken by say has no kept audio: its replay goes through the normal
  # speaker choice once, and what that synthesized is kept for the next replay.
  speak_dg "$home" /dev/null "The scout is done." >/dev/null 2>&1 || fail "fm-speak: the say line failed"
  wait_for_spoken "$home/spoken.log" "the say line never reached the speaker"
  speak_dg "$home" "$home/.env" --repeat >/dev/null 2>&1 || fail "fm-speak: the say repeat failed"
  wait_for_content "$home/played.log" "end: audio of The scout is done." \
    "fm-speak: a reply with no kept audio was not synthesized for its replay"
  assert_equals 2 "$(count_lines "$home/deepgram.log")" "the replay must synthesize exactly once"
  speak_dg "$home" "$home/.env" --repeat >/dev/null 2>&1 || fail "fm-speak: the second repeat failed"
  wait_for_lines "$home/played.log" 8 "fm-speak: the kept audio never played again"
  assert_equals 2 "$(count_lines "$home/deepgram.log")" "audio synthesized for a replay must be kept"
  assert_equals 8 "$(count_lines "$home/played.log")" "the kept audio must play again"
  pass "fm-speak: a replay plays kept audio without synthesizing again"
}

# Kept audio is Deepgram's voice; a home that named a `say` voice hears that
# voice on a replay too.
test_a_named_voice_is_kept_on_replay() {
  local home
  home=$(new_home replay-voice "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  install_deepgram "$home"
  printf 'Ava en_US # Hello\n' > "$home/voices"

  speak_dg "$home" "$home/.env" "The fix is green." >/dev/null 2>&1 || fail "fm-speak: the line failed"
  wait_for_content "$home/played.log" "end: audio of The fix is green." \
    "fm-speak: the synthesized line never played"
  printf 'enabled = true\nvoice = Ava\n' > "$home/config/speak"
  speak_dg "$home" "$home/.env" --repeat >/dev/null 2>&1 || fail "fm-speak: --repeat failed"
  wait_for_content "$home/spoken.log" "text: The fix is green." \
    "fm-speak: a home with a named voice did not replay through say"
  assert_grep "argv: -v Ava" "$home/spoken.log" "the replay must use the named voice"
  assert_equals 2 "$(count_lines "$home/played.log")" "kept audio must not play for a named voice"
  pass "fm-speak: a named voice wins over kept audio on a replay"
}

# Stop covers a replay from kept audio exactly as it covers any other line.
test_stop_cuts_a_replay_of_kept_audio() {
  local home waited=0
  home=$(new_home replay-stop "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  install_deepgram "$home" 20

  speak_dg "$home" "$home/.env" "The long reply." >/dev/null 2>&1 || fail "fm-speak: the line failed"
  wait_for_content "$home/played.log" "start: audio of The long reply." \
    "fm-speak: the line never started"
  speak "$home" --stop || fail "fm-speak: --stop failed"
  while [ -e "$home/state/.speak.lock" ] && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  : > "$home/played.log"

  speak_dg "$home" "$home/.env" --repeat >/dev/null 2>&1 || fail "fm-speak: --repeat failed"
  wait_for_content "$home/played.log" "start: audio of The long reply." \
    "fm-speak: the replay never started"
  speak "$home" --stop || fail "fm-speak: --stop failed"
  waited=0
  while [ -e "$home/state/.speak.lock" ] && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ ! -e "$home/state/.speak.lock" ] || fail "fm-speak: the stopped replay kept the playback lock"
  assert_no_grep "end: audio of The long reply." "$home/played.log" \
    "fm-speak: the replay was not cut short"
  pass "fm-speak: stop cuts a replay of kept audio"
}

# Permission bits of a path, as octal digits, on macOS and Linux alike.
mode_of() {  # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# The captain's spoken replies are private: other accounts on the Mac must not
# be able to read the kept text or audio, even under a permissive umask and
# even when a history directory already exists with looser permissions.
test_the_reply_history_is_readable_only_by_its_owner() {
  local home history entry path
  home=$(new_home history-private "enabled = true")
  install_shaper "$home" >/dev/null
  install_speaker "$home" >/dev/null
  install_deepgram "$home"
  history="$home/state/speak-history"
  mkdir -p "$history"
  chmod 755 "$history"

  (umask 022 && speak_dg "$home" "$home/.env" "The fix is green.") >/dev/null 2>&1 \
    || fail "fm-speak: the line failed"
  wait_for_content "$home/played.log" "end: audio of The fix is green." \
    "fm-speak: the synthesized line never played"

  assert_equals 700 "$(mode_of "$history")" "an existing history directory must be tightened to 0700"
  entry=$(find "$history" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -n "$entry" ] || fail "fm-speak: no reply was kept"
  assert_equals 700 "$(mode_of "$entry")" "a kept reply's directory must be 0700"
  for path in "$entry"/*; do
    assert_equals 600 "$(mode_of "$path")" "kept file ${path##*/} must be 0600"
  done
  [ -f "$entry/audio.mp3" ] || fail "fm-speak: the reply's audio was not kept"
  [ -f "$entry/text" ] || fail "fm-speak: the reply's text was not kept"
  pass "fm-speak: the reply history is readable only by its owner"
}

test_a_home_that_never_opted_in_stays_silent
test_an_absent_config_is_the_same_as_not_opted_in
test_an_opted_in_home_speaks_the_shaped_line
test_a_request_for_a_spoken_yes_is_never_spoken
test_a_line_that_is_only_a_link_is_not_spoken
test_the_speaker_receives_the_stripped_line_not_the_raw_one
test_dry_run_never_reaches_the_speaker
test_the_caller_is_never_held_open_by_audio_still_playing
test_a_runaway_speaker_is_killed_at_the_bound
test_the_speaker_bound_does_not_bound_the_register_call
test_the_register_bound_does_not_bound_the_speaker
test_an_unreachable_register_owner_ends_in_silence
test_a_failing_register_owner_ends_in_silence
test_a_hung_register_owner_does_not_hold_the_turn_open
test_the_register_owner_never_inherits_the_callers_stdin
test_a_non_integer_bound_is_refused
test_a_missing_speech_binary_is_reported_not_guessed
test_the_configured_voice_reaches_the_speaker
test_a_sentence_is_never_passed_as_a_speaker_argument
test_an_unknown_config_key_is_refused_rather_than_parked
test_a_non_boolean_enabled_is_refused
test_a_symlinked_config_is_refused
test_blank_text_is_refused_before_anything_is_shaped
test_no_temporary_files_are_left_behind
test_a_reap_of_the_callers_process_group_does_not_cut_the_line
test_a_desk_line_is_not_cut_by_the_glasses_budget
test_an_empty_register_override_restores_the_glasses_cut
test_an_already_chosen_register_is_never_replaced
test_two_sequential_calls_do_not_overlap_playback
test_two_homes_may_speak_at_the_same_time
test_a_lock_whose_pid_was_reused_is_reclaimed
test_an_unusable_state_directory_is_refused_before_anything_is_shaped
test_mute_silences_every_line_until_unmuted
test_stop_cuts_the_current_line_and_cancels_the_queued_one
test_repeat_speaks_the_last_spoken_line_again
test_history_lists_the_newest_ten_replies_newest_first
test_replay_speaks_the_chosen_reply
test_a_replay_plays_kept_audio_without_synthesizing_again
test_a_named_voice_is_kept_on_replay
test_stop_cuts_a_replay_of_kept_audio
test_the_reply_history_is_readable_only_by_its_owner

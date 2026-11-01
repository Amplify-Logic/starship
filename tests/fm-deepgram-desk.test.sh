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
unset DEEPGRAM_API_KEY DEEPGRAM_STT_MODEL DEEPGRAM_TTS_MODEL || true
unset FM_DEEPGRAM_DEFAULT_STT_MODEL FM_DEEPGRAM_DEFAULT_TTS_MODEL || true
export FM_DEEPGRAM_ENV_FILE=/dev/null
# A mailbox delivery rings the primary in the background; cases that test the
# ring turn it back on with their own short schedule.
export FM_DESK_VOICE_RING_DELAYS=

# Every mailbox delivery raises a macOS notification. A stand-in osascript
# records it instead, so a test never pops "Desk voice transcript ready" on the
# captain's screen for a message that is not in his real mailbox.
NOTIFY_BIN="$TMP_ROOT/notify-bin"
NOTIFY_LOG="$TMP_ROOT/osascript.log"
mkdir -p "$NOTIFY_BIN"
cat > "$NOTIFY_BIN/osascript" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_BIN/osascript"
export PATH="$NOTIFY_BIN:$PATH"

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
  assert_contains "$(cat "$home/curl.log")" "model=nova-3" "default model reaches the request"
  assert_contains "$(cat "$home/curl.log")" "/v1/listen?" "the request goes to the listen endpoint"
  assert_contains "$(cat "$home/curl.log")" "mip_opt_out=true" "the listen request opts out of model improvement"
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

# A desk recording of <seconds>: 16 kHz, 16-bit, mono, as the floater records.
long_wav() {  # <path> <seconds>
  python3 - "$1" "$2" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(b"\0\0" * int(16000 * float(sys.argv[2])))
PY
}

# A curl stand-in that also records the size of the audio it was given.
install_stt_curl_sizing() {  # <home> <http-code> <body>
  local home=$1 code=$2
  install_stt_curl "$@"
  cat > "$home/curl" <<SH
#!/usr/bin/env bash
out=
prev=
for a in "\$@"; do
  [ "\$prev" != -o ] || out=\$a
  [ "\$prev" != --data-binary ] || wc -c < "\${a#@}" | tr -d ' ' > "$home/uploaded-bytes"
  prev=\$a
done
printf 'curl-argv: %s\n' "\$*" >> "$home/curl.log"
cat "$home/stt-body.json" > "\$out"
printf '%s' "$code"
SH
  chmod +x "$home/curl"
}

test_stt_bounds_a_long_request_and_retries_without_a_length_cap() {
  local home out bytes
  home=$(new_home stt-long)
  long_wav "$home/long.wav" 600
  bytes=$(wc -c < "$home/long.wav" | tr -d ' ')
  install_stt_curl_sizing "$home" 200 \
    '{"results":{"channels":[{"alternatives":[{"transcript":"ten minutes of thoughts"}]}]}}'
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/long.wav" 2>&1) || fail "stt failed on a ten-minute recording: $out"
  [ "$out" = "ten minutes of thoughts" ] || fail "unexpected transcript: $out"
  [ "$(cat "$home/uploaded-bytes")" = "$bytes" ] || fail "the whole ten-minute file must be uploaded"
  assert_contains "$(cat "$home/curl.log")" "--connect-timeout 15" "connecting is bounded"
  assert_contains "$(cat "$home/curl.log")" "--max-time $(( 120 + bytes / 100000 ))" \
    "the request bound grows with the recording instead of capping it"
  assert_contains "$(cat "$home/curl.log")" "--speed-limit 1 --speed-time $(( 20 + bytes / 1000000 ))" \
    "a stalled request gives up after a window that covers Deepgram's work on the file"
  assert_contains "$(cat "$home/curl.log")" "--retry 2" "a dropped or busy request is retried"
  pass "fm-deepgram-stt: a ten-minute recording is uploaded whole, with a bounded, retried request"
}

test_stt_names_the_bound_when_deepgram_never_answers() {
  local home out status=0
  home=$(new_home stt-timeout)
  printf 'RIFF' > "$home/clip.wav"
  printf '#!/bin/sh\nexit 28\n' > "$home/curl"
  chmod +x "$home/curl"
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/clip.wav" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "a timed-out request must fail with 1, got $status: $out"
  assert_contains "$out" "no answer within 120s, nothing moving for 20s" "the failure names the bounds"
  pass "fm-deepgram-stt: a request that times out fails instead of hanging"
}

# A local stand-in for Deepgram's listen endpoint, for real curl to talk to.
# It reads each upload whole and answers <transcript>, except in two modes:
# "stall-once" takes the first upload and never answers it, as Deepgram did on
# 22 Oct 2026; "trickle" reads every upload slowly, over <seconds>, so the
# bytes keep moving the whole time. Each upload it read lands in server.log as
# "<bytes> <seconds-since-start>". FM_DEEPGRAM_CURL then runs real curl with
# the request the helper built, sent to the stand-in.
start_stt_server() {  # <home> <mode> <transcript> [seconds]
  local home=$1 i
  python3 - "$home" "$2" "$3" "${4:-0}" > /dev/null 2>&1 <<'PY' &
import json, os, socket, sys, threading, time
home, mode, transcript, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
began = time.monotonic()
srv = socket.socket()
if mode == "trickle":
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
lock = threading.Lock()
served = [0]

def handle(conn):
    with lock:
        served[0] += 1
        n = served[0]
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = conn.recv(4096)
        if not chunk:
            return
        head += chunk
    head, body = head.split(b"\r\n\r\n", 1)
    fields = {}
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        fields[name.strip().lower()] = value.strip()
    length = int(fields[b"content-length"])
    if fields.get(b"expect", b"").lower() == b"100-continue":
        conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
    start = time.monotonic()
    while len(body) < length:
        if mode == "trickle":
            time.sleep(max(0.0, start + seconds * len(body) / length - time.monotonic()))
        chunk = conn.recv(min(4096, length - len(body)))
        if not chunk:
            return
        body += chunk
    with lock, open(home + "/server.log", "a") as log:
        log.write("%d %.1f\n" % (len(body), time.monotonic() - began))
    if mode == "stall-once" and n == 1:
        time.sleep(600)
        return
    reply = json.dumps({"results": {"channels": [{"alternatives": [{"transcript": transcript}]}]}}).encode()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                 b"Connection: close\r\n\r\n%s" % (len(reply), reply))
    conn.close()

with open(home + "/port.tmp", "w") as f:
    f.write(str(srv.getsockname()[1]))
os.rename(home + "/port.tmp", home + "/port")
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
  printf '%s\n' "$!" > "$home/server.pid"
  fm_test_track_pid "$!"
  for i in $(seq 1 50); do
    [ ! -f "$home/port" ] || break
    sleep 0.1
  done
  [ -f "$home/port" ] || fail "the stand-in Deepgram did not start"
  cat > "$home/curl" <<SH
#!/usr/bin/env bash
printf 'curl-argv: %s\n' "\$*" >> "$home/curl.log"
args=()
for a in "\$@"; do
  case "\$a" in
    https://api.deepgram.com/*) a="http://127.0.0.1:$(cat "$home/port")/\${a#https://api.deepgram.com/}" ;;
  esac
  args+=("\$a")
done
exec curl -q --noproxy '*' "\${args[@]}"
SH
  chmod +x "$home/curl"
}

stop_stt_server() {  # <home>
  kill "$(cat "$1/server.pid")" 2>/dev/null || true
}

# On 22 Oct 2026 Deepgram took a 4.6-second recording and never answered; the
# attempt waited out its two-minute bound before the retry answered, so the
# message sat on "Transcribing..." for minutes. The stalled attempt now gives
# up once nothing has moved for the stall window, and the retry answers.
test_stt_gives_up_on_a_stalled_request_and_retries() {
  local home out bytes began elapsed status=0
  home=$(new_home stt-stall)
  long_wav "$home/short.wav" 4.6
  bytes=$(wc -c < "$home/short.wav" | tr -d ' ')
  [ "$bytes" -gt 140000 ] || fail "the stand-in recording must be the size of 4.6 seconds of speech"
  start_stt_server "$home" stall-once "a short reply"
  began=$(date +%s)
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/short.wav" 2> "$home/stderr") || status=$?
  elapsed=$(( $(date +%s) - began ))
  stop_stt_server "$home"
  [ "$status" -eq 0 ] || fail "the retry must answer after a stalled attempt, got $status: $(cat "$home/stderr")"
  [ "$out" = "a short reply" ] || fail "unexpected transcript: $out"
  [ "$(awk '{ print $1 }' "$home/server.log" | tr '\n' ' ')" = "$bytes $bytes " ] \
    || fail "the stalled upload must be sent whole once more: $(cat "$home/server.log")"
  [ "$elapsed" -ge 20 ] || fail "the stalled attempt must wait out the stall window, gave up after ${elapsed}s"
  [ "$elapsed" -lt 60 ] || fail "a stalled short recording must not wait minutes, took ${elapsed}s"
  pass "fm-deepgram-stt: a request Deepgram takes and never answers is retried after ${elapsed}s, not minutes"
}

# A slow uplink keeps the upload moving for longer than the stall window; the
# attempt must run on toward its full bound rather than be cut off and resent.
test_stt_keeps_a_slow_upload_that_is_still_moving() {
  local home out bytes began elapsed status=0
  home=$(new_home stt-trickle)
  long_wav "$home/minute.wav" 60
  bytes=$(wc -c < "$home/minute.wav" | tr -d ' ')
  start_stt_server "$home" trickle "a minute of thoughts" 24
  began=$(date +%s)
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    "$STT" "$home/minute.wav" 2> "$home/stderr") || status=$?
  elapsed=$(( $(date +%s) - began ))
  stop_stt_server "$home"
  [ "$status" -eq 0 ] || fail "a slow upload must not be cut off, got $status: $(cat "$home/stderr")"
  [ "$out" = "a minute of thoughts" ] || fail "unexpected transcript: $out"
  [ "$(awk '{ print $1 }' "$home/server.log" | tr '\n' ' ')" = "$bytes " ] \
    || fail "the slow upload must arrive whole, once: $(cat "$home/server.log")"
  [ "$elapsed" -gt $(( 20 + bytes / 1000000 )) ] \
    || fail "the upload must outlast the stall window to prove anything, took ${elapsed}s"
  assert_contains "$(cat "$home/curl.log")" "--max-time $(( 120 + bytes / 100000 ))" \
    "the full per-byte bound still applies"
  pass "fm-deepgram-stt: a slow upload that keeps moving outlasts the stall window and is answered"
}

# Runs the helper against a mocked Deepgram that returns <transcript>, with the
# home's vocabulary file holding the remaining arguments as lines (no file
# when none are given). Prints the transcript; the request lands in curl.log.
stt_with_vocab() {  # <home> <transcript> [vocab-lines...]
  local home=$1 transcript=$2
  shift 2
  printf 'RIFF' > "$home/clip.wav"
  rm -f "$home/curl.log" "$home/config/stt-vocabulary"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$home/config/stt-vocabulary"
  install_stt_curl "$home" 200 \
    "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"$transcript\"}]}]}}"
  DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" \
    FM_HOME="$home" "$STT" "$home/clip.wav"
}

test_stt_without_vocabulary_sends_no_hints() {
  local home out
  home=$(new_home stt-vocab-absent)
  out=$(stt_with_vocab "$home" "Call Pat dot example 1." 2>&1) || fail "stt failed: $out"
  [ "$out" = "Call Pat dot example 1." ] || fail "transcript changed without a vocabulary: $out"
  case "$(cat "$home/curl.log")" in
    *keyterm=*|*keywords=*) fail "hints sent without a vocabulary: $(cat "$home/curl.log")" ;;
  esac
  printf '%s\n' "$(cat "$home/curl.log")" | grep -q 'smart_format=true&mip_opt_out=true$' || fail "the request must be unchanged"
  pass "fm-deepgram-stt: an absent vocabulary changes nothing"
}

test_stt_vocabulary_key_terms_reach_the_request_encoded() {
  local home out log
  home=$(new_home stt-vocab-terms)
  out=$(stt_with_vocab "$home" "hello" \
    '# names the transcriber keeps missing' '' '   ' \
    'Quillan' 'Zorbit Labs' 'a&b=c') || fail "stt failed: $out"
  log=$(cat "$home/curl.log")
  assert_contains "$log" "keyterm=Quillan&keyterm=Zorbit%20Labs&keyterm=a%26b%3Dc" \
    "nova-3 key terms are URL-encoded keyterm parameters"
  case "$log" in
    *names*|*keyterm=%23*|*keyterm=\&*) fail "a comment or blank line became a key term: $log" ;;
  esac
  out=$(DEEPGRAM_STT_MODEL=nova-2 stt_with_vocab "$home" "hello" 'Quillan' 'Zorbit Labs') \
    || fail "stt failed: $out"
  log=$(cat "$home/curl.log")
  assert_contains "$log" "model=nova-2" "the model override still wins"
  assert_contains "$log" "keywords=Quillan%3A2&keywords=Zorbit%20Labs%3A2" \
    "nova-2 key terms are boosted keywords"
  case "$log" in *keyterm=*) fail "nova-2 must not get keyterm: $log" ;; esac
  pass "fm-deepgram-stt: key terms reach Deepgram encoded in the model's hint form"
}

# The starter template a new home copies is read as key terms only: its
# comments and commented-out examples never reach Deepgram or rewrite anything.
test_stt_starter_vocabulary_sends_only_its_terms() {
  local home out log
  home=$(new_home stt-vocab-starter)
  printf 'RIFF' > "$home/clip.wav"
  cp "$ROOT/docs/examples/stt-vocabulary" "$home/config/stt-vocabulary"
  install_stt_curl "$home" 200 '{"results":{"channels":[{"alternatives":[{"transcript":"Call pat dot example 1 about Starship."}]}]}}'
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" FM_HOME="$home" "$STT" "$home/clip.wav") \
    || fail "stt failed with the starter vocabulary: $out"
  [ "$out" = "Call pat dot example 1 about Starship." ] || fail "a commented-out example rewrote the transcript: $out"
  log=$(cat "$home/curl.log")
  assert_contains "$log" "keyterm=Starship&keyterm=Firstmate&keyterm=no-mistakes&keyterm=treehouse" \
    "the starter key terms reach the request"
  case "$log" in *Pat*|*Harbour*|*%23*) fail "a commented-out example became a key term: $log" ;; esac
  pass "fm-deepgram-stt: the starter vocabulary sends its key terms and nothing commented out"
}

test_stt_vocabulary_caps_key_terms() {
  local home out log i terms=()
  home=$(new_home stt-vocab-cap)
  for i in $(seq 1 150); do terms+=("term$i"); done
  out=$(DEEPGRAM_STT_MODEL=nova-2 stt_with_vocab "$home" "hello" "${terms[@]}") \
    || fail "stt failed: $out"
  log=$(cat "$home/curl.log")
  [ "$(printf '%s' "$log" | grep -o 'keywords=' | wc -l | tr -d ' ')" = 100 ] \
    || fail "nova-2 keywords must stop at 100"
  out=$(stt_with_vocab "$home" "hello" "${terms[@]}") || fail "stt failed: $out"
  log=$(cat "$home/curl.log")
  i=$(printf '%s' "$log" | grep -o 'keyterm=' | wc -l | tr -d ' ')
  [ "$i" -gt 0 ] && [ "$i" -lt 150 ] || fail "nova-3 keyterms must be trimmed to the token budget, got $i"
  pass "fm-deepgram-stt: an oversized vocabulary is trimmed, not refused"
}

test_stt_vocabulary_rewrites_the_printed_transcript() {
  local home out raw
  home=$(new_home stt-vocab-rewrite)
  out=$(stt_with_vocab "$home" \
    "I'll make one on Pat dot example 1, and one at p dot example acme corp." \
    'pat dot example 1 => pat.example1' \
    'p dot example acme corp => p.example@acmecorp' \
    'example => WRONG') || fail "stt failed: $out"
  [ "$out" = "I'll make one on pat.example1, and one at p.example@acmecorp." ] \
    || fail "the two addresses were not rewritten: $out"
  raw=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_CURL="$home/curl" FM_HOME="$home" \
    "$STT" --json "$home/clip.wav") || fail "stt --json failed: $raw"
  [ "$raw" = "$(cat "$home/stt-body.json")" ] || fail "--json must keep the raw formatted response"
  assert_contains "$(cat "$home/curl.log")" 'smart_format=true' "rewrites receive formatted text"
  pass "fm-deepgram-stt: rewrites turn spoken addresses into written ones"
}

test_stt_vocabulary_rewrites_longest_whole_phrase_first() {
  local home out
  home=$(new_home stt-vocab-longest)
  out=$(stt_with_vocab "$home" "ask Robin and Robin Vale about robinsons" \
    'robin => Robyn' 'Robin   Vale => R. Vale') || fail "stt failed: $out"
  [ "$out" = "ask Robyn and R. Vale about robinsons" ] \
    || fail "rewrites must be whole-phrase, case-insensitive, longest first: $out"
  pass "fm-deepgram-stt: rewrites match whole phrases, longest first, ignoring case"
}

test_stt_vocabulary_ignores_malformed_lines() {
  local home out log
  home=$(new_home stt-vocab-malformed)
  out=$(stt_with_vocab "$home" "send it to sam dot test" \
    '=> orphan' 'dangling =>' '=>' 'sam dot test => sam.test' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  [ "$out" = "send it to sam.test" ] || fail "malformed lines broke the rewrite: $out"
  log=$(cat "$home/curl.log")
  assert_contains "$log" "keyterm=Quillan" "the good key term still reaches the request"
  case "$log" in *orphan*|*dangling*) fail "a malformed rewrite became a key term: $log" ;; esac
  pass "fm-deepgram-stt: malformed vocabulary lines are ignored"
}

test_stt_vocabulary_preserves_compound_tokens() {
  local home out compounds
  home=$(new_home stt-vocab-boundaries)
  compounds="robin.gray@example.test robin@example.test a+robin@example.test a/robin@example.test a!robin@example.test a++robin@example.test a.o'robin@example.test team@robin.test robin.gray gray.robin robin-gray gray-robin robin‐gray robin‑gray don't don’t o'robin o’robin robins _robin robin_"
  out=$(stt_with_vocab "$home" "$compounds; Robin, (robin). 'robin' ‘robin’ don!" \
    'robin => Robyn' 'don => Donald' 'example => WRONG' 'test => WRONG') \
    || fail "stt failed: $out"
  [ "$out" = "$compounds; Robyn, (Robyn). 'Robyn' ‘Robyn’ Donald!" ] \
    || fail "compound tokens must stay intact while standalone words change: $out"
  pass "fm-deepgram-stt: email addresses, dotted names, contractions and hyphenated words stay intact"
}

test_stt_vocabulary_rewrites_possessive_names() {
  local home out
  home=$(new_home stt-vocab-possessive)
  out=$(stt_with_vocab "$home" "kai's laptop, quillan’s PR, don't, don’t, kai.example's, kai@example.test" \
    'kai => KAI' 'quillan => Quillan' 'don => Donald') || fail "stt failed: $out"
  [ "$out" = "KAI's laptop, Quillan’s PR, don't, don’t, kai.example's, kai@example.test" ] \
    || fail "a possessive must take the rewrite while contractions, dotted names and emails stay intact: $out"
  pass "fm-deepgram-stt: possessive names take the rewrite"
}

test_stt_vocabulary_rewrites_complete_compounds_and_valid_shorter_phrases() {
  local home out
  home=$(new_home stt-vocab-complete)
  out=$(stt_with_vocab "$home" "Ask robin.gray, don't ask robin.gray@example.test. Robin   Vale!" \
    'ask robin => WRONG' 'ask => Ask' 'robin => WRONG' \
    'robin.gray => robyn.gray' "don't => do not" \
    'robin.gray@example.test => robyn.gray@example.test' \
    'robin vale => R. Vale' 'robyn => WRONG') || fail "stt failed: $out"
  [ "$out" = "Ask robyn.gray, do not Ask robyn.gray@example.test. R. Vale!" ] \
    || fail "whole compounds and shorter valid alternatives must still rewrite once: $out"
  pass "fm-deepgram-stt: whole compound rewrites and shorter valid alternatives still work"
}

test_stt_reads_the_model_from_dotenv() {
  local home out log
  home=$(new_home stt-dotenv-model)
  printf 'export DEEPGRAM_STT_MODEL="nova-2"\n' > "$home/.env"
  out=$(unset FM_DEEPGRAM_ENV_FILE; stt_with_vocab "$home" 'Hello.' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  [ "$out" = 'Hello.' ] || fail "model settings must not appear in the transcript output"
  log=$(cat "$home/curl.log")
  case "$log" in *'model=nova-2&smart_format=true&mip_opt_out=true&keywords=Quillan%3A2'*) ;; *) fail "home .env must select model and keyword hints" ;; esac
  out=$(unset FM_DEEPGRAM_ENV_FILE; DEEPGRAM_STT_MODEL=nova-3 stt_with_vocab "$home" 'Hello.' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  log=$(cat "$home/curl.log")
  case "$log" in *'model=nova-3&smart_format=true&mip_opt_out=true&keyterm=Quillan'*) ;; *) fail "the environment must win over .env" ;; esac
  printf 'DEEPGRAM_STT_MODEL=\n' > "$home/.env"
  out=$(unset FM_DEEPGRAM_ENV_FILE; stt_with_vocab "$home" 'Hello.' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  case "$(cat "$home/curl.log")" in *'model=nova-3&'*) ;; *) fail "empty .env model must use the default" ;; esac
  printf 'DEEPGRAM_STT_MODEL=nova-2\n' > "$home/model.env"
  out=$(FM_DEEPGRAM_ENV_FILE="$home/model.env" stt_with_vocab "$home" 'Hello.' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  case "$(cat "$home/curl.log")" in *'model=nova-2&'*) ;; *) fail "the explicit dotenv path must be respected" ;; esac
  rm "$home/.env"
  out=$(unset FM_DEEPGRAM_ENV_FILE; stt_with_vocab "$home" 'Hello.' 'Quillan' 2>&1) \
    || fail "stt failed: $out"
  case "$(cat "$home/curl.log")" in *'model=nova-3&'*) ;; *) fail "absent .env model must use the default" ;; esac
  pass "fm-deepgram-stt: model and hints follow environment, home .env, then default"
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
  : > "$NOTIFY_LOG"
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
  assert_contains "$(cat "$NOTIFY_LOG")" "Desk voice transcript ready" \
    "the delivery notification reached the stand-in, never the real one"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain) \
    || fail "drain failed"
  assert_contains "$drained" "Merge the finances PR when green" "drain prints transcript"
  [ ! -f "$path" ] || fail "inbox file should be gone after drain"
  pass "fm-desk-voice: deliver, wake, pending, drain"
}

# --- desk-voice saved recordings: never lost ---------------------------------

desk() {  # <home> <args...> -> stdout of fm-desk-voice.sh, with Deepgram mocked
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" DEEPGRAM_API_KEY=test-key-not-real \
    FM_DEEPGRAM_CURL="$home/curl" "$DESK" "$@"
}

stt_says() {  # <home> <transcript> | <home> --fail
  if [ "$2" = --fail ]; then
    install_stt_curl "$1" 502 '{"err_msg":"bad gateway"}'
  else
    install_stt_curl "$1" 200 "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"$2\"}]}]}}"
  fi
}

mode_of() {  # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

saved_at_of() {  # <json>
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["saved_at"])' "$1"
}

test_desk_voice_keeps_a_recording_until_its_words_are_delivered() {
  local home saved out json mailbox
  home=$(new_home recordings-keep)
  long_wav "$home/capture.wav" 3
  saved=$(desk "$home" keep --reason "transcription failed" "$home/capture.wav") || fail "keep failed: $saved"
  [ ! -e "$home/capture.wav" ] || fail "keep must move the recording, not copy it"
  [ -f "$saved" ] || fail "the saved recording is missing: $saved"
  case "$saved" in "$home/state/desk-voice/unsent/"*.wav) ;; *) fail "saved outside the unsent folder: $saved" ;; esac
  [ "$(mode_of "$home/state/desk-voice/unsent")" = 700 ] || fail "the unsent folder must be private"
  [ "$(mode_of "$saved")" = 600 ] || fail "a saved recording must be readable only by its owner"
  json="${saved%.wav}.json"
  [ "$(mode_of "$json")" = 600 ] || fail "the recording record must be private"
  out=$(desk "$home" recordings) || fail "recordings failed"
  assert_equals "$saved	firstmate	1	$(saved_at_of "$json")	transcription failed" "$out" \
    "recordings lists the saved recording, its purpose, attempts and reason"

  stt_says "$home" --fail
  out=$(desk "$home" retry) || fail "retry failed: $out"
  assert_equals "unsent	$saved	2	transcription failed: Deepgram listen failed HTTP 502" "$out" \
    "a failed retry keeps the recording and counts the attempt"
  stt_says "$home" ""
  out=$(desk "$home" retry "$saved") || fail "retry failed: $out"
  assert_equals "unsent	$saved	3	no speech heard" "$out" "an empty transcript is not a delivery"
  [ -f "$saved" ] || fail "an undelivered recording must stay saved"
  [ "$(inbox_count "$home")" = 0 ] || fail "nothing is delivered before there are words"

  stt_says "$home" "Merge the finances PR when it is green"
  out=$(desk "$home" retry "$saved" 2>/dev/null) || fail "retry failed: $out"
  case "$out" in
    "delivered	$saved	mailbox: "*) ;;
    *) fail "the words must be delivered through send, here to the mailbox: $out" ;;
  esac
  mailbox=${out##*mailbox: }
  assert_contains "$(cat "$mailbox")" "Merge the finances PR when it is green" "the mailbox holds the retried words"
  assert_contains "$(cat "$mailbox")" '"source": "desk-floater-retry"' "the message says it was retried"
  [ ! -e "$saved" ] && [ ! -e "$json" ] || fail "a delivered recording is removed with its record"
  out=$(desk "$home" retry "$saved") || fail "retry of a delivered recording failed: $out"
  assert_equals "gone	$saved" "$out" "a delivered recording is reported gone"
  [ -z "$(desk "$home" recordings)" ] || fail "nothing is left saved"
  pass "fm-desk-voice keep/retry: a recording is kept, private, until its words are delivered"
}

test_desk_voice_retry_of_a_ten_minute_recording_delivers_every_word() {
  local home saved out words
  home=$(new_home recordings-long)
  long_wav "$home/capture.wav" 600
  words=$(python3 -c 'print(" ".join("word%d" % i for i in range(1500)))')
  stt_says "$home" "$words"
  saved=$(desk "$home" keep --reason "transcription failed" "$home/capture.wav") || fail "keep failed"
  out=$(desk "$home" retry "$saved" 2>/dev/null) || fail "retry failed: $out"
  case "$out" in "delivered	$saved	mailbox: "*) ;; *) fail "a long recording must be delivered: $out" ;; esac
  assert_contains "$(cat "${out##*mailbox: }")" "word0 word1 " "the start of a long note arrives"
  assert_contains "$(cat "${out##*mailbox: }")" "word1498 word1499" "the end of a long note arrives"
  pass "fm-desk-voice retry: a ten-minute recording is transcribed and delivered whole"
}

test_desk_voice_retry_of_dictation_returns_the_words() {
  local home saved out
  home=$(new_home recordings-dictate)
  long_wav "$home/capture.wav" 3
  saved=$(desk "$home" keep --purpose dictate --reason "no speech heard" "$home/capture.wav") || fail "keep failed"
  assert_contains "$(desk "$home" recordings)" "	dictate	1	" "the purpose is kept"
  stt_says "$home" "Dear team"
  out=$(desk "$home" retry) || fail "retry failed: $out"
  assert_equals "transcript	$saved	Dear team" "$out" "dictation comes back as words to paste"
  [ "$(inbox_count "$home")" = 0 ] || fail "dictation is never sent to Firstmate by a retry"
  [ ! -e "$saved" ] || fail "a returned dictation is removed"
  pass "fm-desk-voice retry: dictation returns its words to the floater, never to Firstmate"
}

test_desk_voice_keep_never_removes_a_saved_recording() {
  local home old i
  home=$(new_home recordings-never-pruned)
  long_wav "$home/old.wav" 1
  old=$(desk "$home" keep "$home/old.wav") || fail "keep failed"
  touch -t 202001010000 "$old" "${old%.wav}.json"
  for i in $(seq 1 25); do
    long_wav "$home/capture-$i.wav" 0.1
    desk "$home" keep "$home/capture-$i.wav" >/dev/null || fail "keep $i failed"
  done
  [ -e "$old" ] && [ -e "${old%.wav}.json" ] || fail "an old undelivered recording must stay saved"
  [ "$(desk "$home" recordings | wc -l | tr -d ' ')" = 26 ] || fail "every undelivered recording must stay saved"
  pass "fm-desk-voice keep: an undelivered recording is never removed, however old or many"
}

test_desk_voice_retry_keeps_the_recording_when_the_mailbox_cannot_save() {
  local home saved out real
  home=$(new_home recordings-mailbox-fails)
  long_wav "$home/capture.wav" 1
  saved=$(desk "$home" keep "$home/capture.wav") || fail "keep failed"
  stt_says "$home" "words that must not vanish"
  # A python3 that cannot write a mailbox message, as on a full disk.
  real=$(command -v python3)
  mkdir -p "$home/pybin"
  cat > "$home/pybin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = - ]; then
  script=\$(cat)
  case "\$script" in *fm-desk-voice-transcript.v1*) exit 1 ;; esac
  exec "$real" "\$@" <<<"\$script"
fi
exec "$real" "\$@"
SH
  chmod +x "$home/pybin/python3"
  out=$(PATH="$home/pybin:$PATH" desk "$home" retry "$saved" 2>/dev/null) || fail "retry failed: $out"
  assert_equals "unsent	$saved	2	delivery failed" "$out" "a mailbox that cannot save is not a delivery"
  [ -e "$saved" ] && [ -e "${saved%.wav}.json" ] || fail "the recording must stay saved when its words were stored nowhere"
  [ "$(inbox_count "$home")" = 0 ] || fail "nothing reached the mailbox"
  pass "fm-desk-voice retry: a mailbox that cannot save leaves the recording saved"
}

test_desk_voice_retry_refuses_anything_but_a_saved_recording() {
  local home out status=0
  home=$(new_home recordings-refuse)
  long_wav "$home/capture.wav" 1
  out=$(desk "$home" retry "$home/capture.wav" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "a file outside the unsent folder must be refused, got $status: $out"
  [ -e "$home/capture.wav" ] || fail "a refused file is left alone"
  status=0
  out=$(desk "$home" keep "$home/notes.txt" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "keep must refuse a missing file, got $status: $out"
  printf 'x' > "$home/notes.txt"
  status=0
  out=$(desk "$home" keep "$home/notes.txt" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "keep must refuse a file that is not audio, got $status: $out"
  pass "fm-desk-voice retry/keep: only saved audio recordings are touched"
}

test_desk_voice_retries_run_one_at_a_time() {
  local home saved out
  home=$(new_home recordings-busy)
  long_wav "$home/capture.wav" 1
  saved=$(desk "$home" keep "$home/capture.wav") || fail "keep failed"
  stt_says "$home" "slow words"
  # A slow Deepgram holds the first retry while the second one is asked.
  printf '#!/usr/bin/env bash\nsleep 2\nexec %q "$@"\n' "$home/curl" > "$home/curl-slow"
  chmod +x "$home/curl-slow"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" DEEPGRAM_API_KEY=test-key-not-real \
    FM_DEEPGRAM_CURL="$home/curl-slow" "$DESK" retry "$saved" > "$home/first.out" 2>/dev/null &
  sleep 1
  out=$(desk "$home" retry "$saved") || fail "second retry failed: $out"
  assert_equals "busy	$saved" "$out" "a retry under way keeps the recording to itself"
  wait
  case "$(cat "$home/first.out")" in "delivered	$saved	"*) ;; *) fail "the first retry must deliver: $(cat "$home/first.out")" ;; esac
  pass "fm-desk-voice retry: one retry at a time, the other is told it is busy"
}

# --- desk-voice send: straight into the primary's chat pane ------------------
#
# A stand-in primary: a live process whose command line names a harness (a
# python script under a claude/ directory, or another harness's, which the
# session-lock identity accepts) and whose environment names a Herdr pane (or
# a tmux pane). It holds the fixture home's session lock, and runs beneath a
# stand-in multiplexer server. The herdr and tmux on PATH are fakes that log
# every call, so no real pane ever receives text or keys.
#
# The herdr fake draws Claude's chat box between two rules: the draft file is
# typed text, the ghost file a dim suggested prompt shown while nothing is
# typed, and the stash file a draft set aside with Ctrl+S, shown as
# `› stashed` in the footer. Its keys behave as Claude's do: Ctrl+S stashes a
# typed draft or pops the stash into an empty box, Ctrl+U clears the box, and
# Enter submits the box (the suggestion when nothing is typed) to the
# submitted log, then restores a stash into the box. Knob files bend it: wrap
# draws the box 40 columns wide, where Ctrl+U deletes one wrapped row;
# drop-head loses the first typed character; no-marker hides `› stashed`;
# narrow draws `› stashed` on a footer row of its own, as a narrow pane wraps it;
# pop-fails refuses the Ctrl+S that pops a stash; refold makes Enter redraw
# the box as a pasted-text placeholder plus the typed tail without submitting;
# late-paste holds sent text back from the box for the number of screen reads
# it names, as a busy Claude draws input late, yet handles it before any key.
# Text over 800 characters folds as Claude folds it (verified live on claude
# 2.1.283): a bracketed paste into one `[Pasted text #N]` placeholder, a typed
# burst into a placeholder plus its literal tail. Enter expands a placeholder
# back into its text.

desk_send_fixture() {  # <name> [tmux|herdr] [harness] -> home; starts the stand-in primary
  local name=$1 backend=${2:-herdr} harness=${3:-claude} home dir fb pid i envs marker
  local -a pane_env
  home=$(new_home "$name")
  dir="$home/fixture"
  fb="$dir/bin"
  mkdir -p "$fb" "$dir/$harness"
  # A node linked under the harness's own name is a process whose name the
  # session-lock identity reads as that harness, as a real `claude` is.
  # Without node, a python script under the harness's directory stands in.
  if command -v node >/dev/null 2>&1; then
    ln -s "$(command -v node)" "$dir/$harness/$harness"
    set -- "$dir/$harness/$harness" -e 'setTimeout(() => {}, 60000)'
  else
    printf 'import time\ntime.sleep(60)\n' > "$dir/$harness/holder.py"
    set -- python3 "$dir/$harness/holder.py"
  fi
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/herdr.log"
draw_queued() {
  [ -e "$dir/queued" ] || return 0
  cat "$dir/queued" >> "$dir/draft"
  rm -f "$dir/queued" "$dir/queued-reads"
}
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
    if [ -e "$dir/queued" ]; then
      left=$(( $(cat "$dir/queued-reads") - 1 ))
      if [ "$left" -le 0 ]; then draw_queued; else printf '%s' "$left" > "$dir/queued-reads"; fi
    fi
    case " $* " in *' ansi '*) ansi=1 ;; *) ansi=0 ;; esac
    if [ -e "$dir/modal" ]; then
      if [ "$ansi" = 1 ]; then cat "$dir/modal"; else sed $'s/\033\\[[0-9;:]*m//g' "$dir/modal"; fi
      exit 0
    fi
    # The screen is the case's capture, or a bare chat box, with its last
    # prompt row redrawn from the box's state the way Claude draws it.
    screen="$dir/screen"
    if [ ! -e "$screen" ]; then
      screen="$dir/screen.default"
      printf '%s\n' '────────────────────────────────────────' '❯' \
        '────────────────────────────────────────' '  ⏵⏵ auto mode on' > "$screen"
    fi
    esc=$'\033'
    if [ -e "$dir/stale-left" ]; then
      draft=$(cat "$dir/stale-draft")
      left=$(( $(cat "$dir/stale-left") - 1 ))
      if [ "$left" -le 0 ]; then rm -f "$dir/stale-left"; else printf '%s' "$left" > "$dir/stale-left"; fi
    else
      draft=$(cat "$dir/draft" 2>/dev/null)
    fi
    row="❯"$'\302\240'"${esc}[0m"
    if [ -n "$draft" ] && [ -e "$dir/wrap" ]; then
      row+="${esc}[38;2;255;255;255m${draft:0:40}"
      rest=${draft:40}
      while [ -n "$rest" ]; do
        row+='\n  '"${rest:0:40}"
        rest=${rest:40}
      done
      row+="${esc}[0m"
    elif [ -n "$draft" ]; then
      row+="${esc}[38;2;255;255;255m${draft}${esc}[0m"
    elif [ -e "$dir/ghost" ]; then
      row+="${esc}[2m$(cat "$dir/ghost")${esc}[0m"
    fi
    stash=0
    [ ! -e "$dir/stash" ] || [ -e "$dir/no-marker" ] || stash=1
    [ "$stash" = 0 ] || [ ! -e "$dir/narrow" ] || stash=2
    last=$(grep -n '❯' "$screen" | tail -n 1 | cut -d: -f1)
    awk -v n="$last" -v row="$row" -v stash="$stash" -v rows="$(wc -l < "$screen")" '
      NR == n { print row "\r"; next }
      NR == rows && stash == 2 { print; print "                    › stashed\r"; next }
      NR == rows && stash == 1 { sub(/\r$/, ""); print $0 "    › stashed\r"; next }
      { print }
    ' "$screen" > "$dir/screen.now"
    if [ "$ansi" = 1 ]; then cat "$dir/screen.now"; else sed $'s/\033\\[[0-9;:]*m//g' "$dir/screen.now"; fi ;;
  "pane send-text")
    [ ! -e "$dir/send-text-fails" ] || exit 1
    if [ -e "$dir/hold-send" ]; then
      : > "$dir/send-held"
      for _ in $(seq 1 150); do
        [ -e "$dir/release-send" ] && break
        sleep 0.1
      done
      [ -e "$dir/release-send" ] || exit 1
    fi
    if [ -e "$dir/drop-head" ]; then text=${4:1}; else text=$4; fi
    open=$'\033[200~' close=$'\033[201~'
    n=$(( $(cat "$dir/pastes" 2>/dev/null || echo 0) + 1 ))
    if [ "${text#"$open"}" != "$text" ] && [ "${text%"$close"}" != "$text" ]; then
      text=${text#"$open"}
      text=${text%"$close"}
      if [ "${#text}" -gt 800 ]; then
        printf '%s' "$n" > "$dir/pastes"
        printf '%s' "$text" > "$dir/paste-$n"
        text="[Pasted text #$n]"
      fi
    else
      text=${text%"$close"}
      if [ "${#text}" -gt 800 ]; then
        printf '%s' "$n" > "$dir/pastes"
        printf '%s' "${text:0:${#text}-40}" > "$dir/paste-$n"
        text="[Pasted text #$n]${text: -40}"
      fi
    fi
    if [ -e "$dir/late-paste" ]; then
      printf '%s' "$text" >> "$dir/queued"
      cp "$dir/late-paste" "$dir/queued-reads"
    else
      printf '%s' "$text" >> "$dir/draft"
    fi
    [ ! -e "$dir/type-before-enter" ] || cat "$dir/type-before-enter" >> "$dir/draft" ;;
  "pane send-keys")
    draw_queued
    case "$4" in
      ctrl+s)
        [ ! -e "$dir/no-stash" ] || exit 0
        if [ -s "$dir/draft" ]; then
          mv "$dir/draft" "$dir/stash"
          : > "$dir/draft"
        elif [ -e "$dir/stash" ]; then
          [ ! -e "$dir/pop-fails" ] || exit 1
          mv "$dir/stash" "$dir/draft"
        fi ;;
      ctrl+u)
        draft=$(cat "$dir/draft" 2>/dev/null)
        if [ -e "$dir/wrap" ] && [ "${#draft}" -gt 40 ]; then
          printf '%s' "${draft:0:$(( (${#draft} - 1) / 40 * 40 ))}" > "$dir/draft"
        else
          : > "$dir/draft"
        fi ;;
      *)
        : > "$dir/entered"
        if [ -e "$dir/swallow-enter-once" ]; then
          rm "$dir/swallow-enter-once"
          exit 0
        fi
        [ ! -e "$dir/never-works" ] || exit 0
        if [ -e "$dir/refold" ]; then
          draft=$(cat "$dir/draft")
          printf '[Pasted text #2 +3 lines]%s' "${draft: -40}" > "$dir/draft"
          exit 0
        fi
        if [ -s "$dir/draft" ]; then
          draft=$(cat "$dir/draft")
          for paste in "$dir"/paste-*; do
            [ -e "$paste" ] || continue
            draft=${draft//"[Pasted text #${paste##*-}]"/$(cat "$paste")}
          done
          printf '%s\n' "$draft" >> "$dir/submitted"
          if [ -e "$dir/stale-reads" ]; then
            printf '%s' "$draft" > "$dir/stale-draft"
            cp "$dir/stale-reads" "$dir/stale-left"
          fi
        elif [ -e "$dir/ghost" ]; then
          { cat "$dir/ghost"; printf '\n'; } >> "$dir/submitted"
        fi
        : > "$dir/draft"
        [ ! -e "$dir/stash" ] || mv "$dir/stash" "$dir/draft"
        [ ! -e "$dir/type-after-enter" ] || mv "$dir/type-after-enter" "$dir/draft" ;;
    esac ;;
  "agent get")
    if [ -e "$dir/entered" ] && [ ! -e "$dir/never-works" ] && [ ! -e "$dir/agent-idle" ]; then s=working; else s=idle; fi
    if [ -e "$dir/agent" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$(cat "$dir/agent")" "$s"
    else
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$s"
    fi ;;
esac
exit 0
SH
  # By default the tmux fake answers only the pane and front checks. Ring
  # race cases opt into the same composer model as Herdr, through tmux's
  # capture, buffer and key operations.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
{ printf 'call'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$dir/tmux.log"
case "$*" in
  *'show-options -gv focus-events'*) cat "$dir/tmux-focus-events" 2>/dev/null || printf 'on\n' ;;
  *'@fm-focus-since'*) cat "$dir/tmux-focus-since" 2>/dev/null ;;
  *'#{pane_pid}'*) cat "$dir/shell-pid" ;;
  *'#{session_id} #{window_active}#{pane_active}'*) cat "$dir/tmux-active" ;;
  *'#{pane_id}'*) printf '%%9\n' ;;
  list-clients*) cat "$dir/tmux-clients" 2>/dev/null ;;
  *)
    [ -e "$dir/tmux-composer" ] || exit 1
    case "$1" in
      capture-pane) "$dir/bin/herdr" pane read --pane w7:p3 --format ansi ;;
      display-message)
        case "$*" in *'#{cursor_y}'*) printf '1\n' ;; *) exit 1 ;; esac ;;
      load-buffer) cat > "$dir/tmux-buffer" ;;
      paste-buffer) "$dir/bin/herdr" pane send-text w7:p3 "$(cat "$dir/tmux-buffer")" ;;
      send-keys)
        case "$4" in
          -l) "$dir/bin/herdr" pane send-text w7:p3 "$5" ;;
          Enter) "$dir/bin/herdr" pane send-keys w7:p3 enter ;;
          *) exit 1 ;;
        esac ;;
      *) exit 1 ;;
    esac ;;
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
    'out=$1; shift; "$@" >/dev/null 2>&1 & printf "%s\n" "$!" > "$out.tmp"; mv "$out.tmp" "$out"; wait' \
    _ "$dir/holder-pid" "$@" >/dev/null 2>&1 &
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
  # A Herdr first mate needs no tmux at all: the Windows floater's talk path
  # reaches it with no tmux session open.
  [ ! -s "$home/fixture/tmux.log" ] || fail "talking to a herdr primary must never call tmux: $(cat "$home/fixture/tmux.log")"
  desk_send_done "$home"
  pass "fm-desk-voice send: types the transcript into the primary's own pane and submits it, with no tmux"
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
    $' Pick a model\n  > 1. Opus\n    2. Sonnet\n' \
    "$(cat "$ROOT/tests/fixtures/composer-claude-dialogs/claude-2.1.283-permission-prompt.ansi")" \
    "$(cat "$ROOT/tests/fixtures/composer-claude-dialogs/claude-2.1.283-ask-user-question.ansi")" \
    "$(cat "$ROOT/tests/fixtures/composer-claude-dialogs/claude-2.1.283-model-picker.ansi")"; do
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

# --- desk-voice mailbox messages ring the busy primary ------------------------
#
# A message that goes to the mailbox because the primary's chat could not take
# it (here a permission dialog) rings the primary once the chat is free, so a
# busy primary drains it within seconds instead of at its next turn end.

desk_send_ringing() {  # <home> <text> -> stdout of send, with a fast ring schedule
  FM_DESK_VOICE_RING_DELAYS="0 1 1 1 1 1 1 1" desk_send "$@"
}

wait_for_desk_ring() {  # <home>
  local i
  for i in $(seq 1 100); do
    [ -n "$(herdr_calls "$1" pane send-text)" ] && [ -e "$1/fixture/entered" ] && return 0
    sleep 0.1
  done
  return 1
}

test_desk_voice_mailbox_rings_the_primary_once_its_chat_is_free() {
  local home out started elapsed typed
  home=$(desk_send_fixture mailbox-ring) || { desk_send_skip mailbox-ring; return 0; }
  printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' > "$home/fixture/modal"
  started=$(date +%s)
  out=$(desk_send_ringing "$home" "a really long voice note") || fail "send failed: $out"
  elapsed=$(( $(date +%s) - started ))
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  [ "$elapsed" -le 3 ] || fail "send waited ${elapsed}s for its background ring"
  sleep 1.5
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed into a dialog"
  rm -f "$home/fixture/modal"
  wait_for_desk_ring "$home" || fail "the primary was never rung once its chat was free"
  typed=$(herdr_calls "$home" pane send-text)
  assert_contains "$typed" "[firstmate desk-voice] a desk voice message is waiting in the mailbox" \
    "the primary's chat gets one labelled line asking it to drain now"
  assert_not_contains "$typed" "a really long voice note" "the ring carries no words of the message"
  sleep 2
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "a rung primary is rung only once"
  [ "$(inbox_count "$home")" = 1 ] || fail "the message stays in the mailbox for the drain"
  assert_contains "$(cat "$home/state/.wake-queue")" "desk-voice" "the durable wake is still queued"
  desk_send_done "$home"
  pass "fm-desk-voice: a mailbox message rings the primary as soon as its chat is free"
}

test_desk_voice_mailbox_ring_stops_once_drained_or_away() {
  local home out posture
  for posture in drained away; do
    home=$(desk_send_fixture "mailbox-ring-$posture") || { desk_send_skip "mailbox-ring-$posture"; return 0; }
    printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' > "$home/fixture/modal"
    # The first ring waits two seconds, so the message is drained (or the
    # captain away) before any ring reads the chat.
    out=$(FM_DESK_VOICE_RING_DELAYS="2 1 1 1" desk_send "$home" "status please") || fail "send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
    if [ "$posture" = drained ]; then
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DESK" drain >/dev/null || fail "drain failed"
    else
      printf 'away\n' > "$home/state/.afk"
    fi
    rm -f "$home/fixture/modal"
    sleep 6
    [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "$posture: the primary must not be rung"
    desk_send_done "$home"
  done
  pass "fm-desk-voice: the mailbox ring stops once the message is drained, and never rings in away mode"
}

test_desk_voice_mailbox_ring_never_submits_a_draft_or_stash() {
  local home out when
  for when in draft stash; do
    home=$(desk_send_fixture "mailbox-ring-$when") || { desk_send_skip "mailbox-ring-$when"; return 0; }
    printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' > "$home/fixture/modal"
    out=$(desk_send_ringing "$home" "status please") || fail "send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
    case "$when" in
      draft) printf 'half typed thought' > "$home/fixture/type-before-enter" ;;
      stash) printf 'half typed thought' > "$home/fixture/stash" ;;
    esac
    rm -f "$home/fixture/modal"
    sleep 4
    [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "$when: no Enter may submit the captain's words"
    [ ! -e "$home/fixture/submitted" ] || fail "$when: nothing may be submitted"
    case "$when" in
      draft)
        [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "draft: a ring that met the captain's typing is not typed again"
        assert_contains "$(cat "$home/fixture/draft")" 'half typed thought' "the captain's typing must be kept"
        ;;
      stash)
        [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "stash: nothing may be typed over a stash"
        [ "$(cat "$home/fixture/stash")" = 'half typed thought' ] || fail "stash: the stash must be kept"
        ;;
    esac
    desk_send_done "$home"
  done
  pass "fm-desk-voice: the mailbox ring re-reads its payload before Enter and never rings over a stash"
}

# --- captain inbox notes ring the busy primary -------------------------------
#
# A Starship Voice or glasses note goes through bin/fm-inbox.sh note, which
# queues its durable wake and then rings the primary through
# fm-desk-voice.sh ring: one labelled line typed into the same proven pane the
# desk floater uses, so a primary busy mid-turn sees the note within seconds.

inbox_note_in() {  # <home> <text> -> stdout of fm-inbox.sh note
  local home=$1 dir="$1/fixture"
  (
    unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
      FM_BACKEND_HERDR_BIN FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
    PATH="$dir/bin:$PATH" FM_FAKE_HERDR_DIR="$dir" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.1 \
      "$ROOT/bin/fm-inbox.sh" note "$2"
  )
}

desk_ring() {  # <home> <line>
  local home=$1 dir="$1/fixture"
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    PATH="$dir/bin:$PATH" FM_FAKE_HERDR_DIR="$dir" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$DESK" ring "$2"
}

test_ring_checks_the_payload_before_each_enter() {
  local home out backend when
  for backend in tmux herdr; do
    for when in before after retry; do
      home=$(desk_send_fixture "ring-race-$backend-$when" "$backend") \
        || { desk_send_skip "ring-race-$backend-$when"; return 0; }
      : > "$home/fixture/tmux-composer"
      case "$when" in
        before|after) printf 'half typed thought' > "$home/fixture/type-$when-enter" ;;
        retry) : > "$home/fixture/swallow-enter-once" ;;
      esac
      out=$(desk_ring "$home" '[firstmate inbox] ring') || fail "ring failed: $out"
      case "$when" in
        before)
          [ ! -e "$home/fixture/entered" ] || fail "$backend: ring submitted a changed draft"
          assert_contains "$(cat "$home/fixture/draft")" 'half typed thought' "human text must be kept"
          ;;
        after)
          [ "$(cat "$home/fixture/submitted")" = '[firstmate inbox] ring' ] || fail "$backend: ring retried over a new draft"
          [ "$(cat "$home/fixture/draft")" = 'half typed thought' ] || fail "$backend: new draft must remain unsent"
          [ "$(herdr_calls "$home" pane send-keys | wc -l | tr -d ' ')" = 1 ] || fail "$backend: no Enter retry over a new draft"
          ;;
        retry)
          assert_contains "$out" "rung: $backend" "an unchanged ring can retry a swallowed Enter"
          [ "$(cat "$home/fixture/submitted")" = '[firstmate inbox] ring' ] || fail "$backend: retry must submit only the ring"
          [ "$(herdr_calls "$home" pane send-keys | wc -l | tr -d ' ')" = 2 ] || fail "$backend: exactly one safe retry is expected"
          ;;
      esac
      [ "$(inbox_count "$home")" = 0 ] || fail "a ring must not write a duplicate mailbox message"
      desk_send_done "$home"
    done
  done
  pass "desk ring: both backends re-read the payload before every Enter, including retries"
}

test_ring_waits_for_a_late_paste_and_a_late_redraw() {
  local home out backend when
  for backend in tmux herdr; do
    for when in paste suggestion redraw stash; do
      home=$(desk_send_fixture "ring-late-$backend-$when" "$backend") \
        || { desk_send_skip "ring-late-$backend-$when"; return 0; }
      : > "$home/fixture/tmux-composer"
      case "$when" in
        paste) printf '6' > "$home/fixture/late-paste" ;;
        suggestion)
          printf '6' > "$home/fixture/late-paste"
          printf 'suggested words' > "$home/fixture/ghost"
          ;;
        redraw) printf '5' > "$home/fixture/stale-reads" ;;
        stash)
          printf 'half typed thought' > "$home/fixture/stash"
          printf '5' > "$home/fixture/stale-reads"
          ;;
      esac
      out=$(desk_ring "$home" '[firstmate inbox] ring') || fail "ring failed: $out"
      case "$when" in
        paste|suggestion|redraw)
          assert_contains "$out" "rung: $backend" "a late $when must still be proven and submitted"
          [ "$(cat "$home/fixture/submitted")" = '[firstmate inbox] ring' ] || fail "$backend: only the ring may be submitted"
          [ "$(herdr_calls "$home" pane send-keys | wc -l | tr -d ' ')" = 1 ] || fail "$backend: a late $when needs exactly one Enter"
          [ ! -s "$home/fixture/draft" ] || fail "$backend: the ring must not stay in the box"
          ;;
        stash)
          [ "$out" = not-rung ] || fail "$backend: a ring must leave a stashed draft alone: $out"
          [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "$backend: nothing may be typed over a stash"
          [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "$backend: no Enter may restore and submit a stash"
          [ "$(cat "$home/fixture/stash")" = 'half typed thought' ] || fail "$backend: the stash must be kept"
          [ ! -e "$home/fixture/submitted" ] || fail "$backend: nothing may be submitted"
          ;;
      esac
      [ "$(inbox_count "$home")" = 0 ] || fail "a ring must not write a duplicate mailbox message"
      desk_send_done "$home"
    done
  done
  pass "desk ring: a late paste is still proven, even under a dim suggestion, a late redraw gets no retry, and a stash is never rung over"
}

test_ring_and_send_share_one_writer_lock() {
  local home first out pid i
  for first in ring send; do
    home=$(desk_send_fixture "pane-writer-$first") || { desk_send_skip "pane-writer-$first"; return 0; }
    : > "$home/fixture/hold-send"
    if [ "$first" = ring ]; then
      desk_ring "$home" '[firstmate inbox] ring' > "$home/first.out" &
    else
      desk_send "$home" 'first message' > "$home/first.out" &
    fi
    pid=$!
    fm_test_track_pid "$pid"
    for i in $(seq 1 100); do
      [ -e "$home/fixture/send-held" ] && break
      sleep 0.1
    done
    [ -e "$home/fixture/send-held" ] || fail "first writer never reached the pane"
    out=$(desk_ring "$home" 'second ring') || fail "contending ring failed"
    [ "$out" = not-rung ] || fail "contending ring must leave its durable wake alone: $out"
    out=$(desk_send "$home" 'second message') || fail "contending send failed"
    case "$out" in mailbox:\ *) ;; *) fail "contending send must use its mailbox: $out" ;; esac
    [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "only the lock holder may type"
    : > "$home/fixture/release-send"
    wait "$pid" || fail "first writer failed"
    rm "$home/fixture/hold-send"
    out=$(desk_ring "$home" 'next ring') || fail "ring after lock release failed"
    assert_contains "$out" 'rung:' "the writer lock must be released after submission"
    desk_send_done "$home"
  done
  pass "desk ring and send: concurrent writers use one lock and release it after delivery"
}

test_inbox_ring_respects_contract_only_away_posture() {
  local home out probe posture i
  home=$(new_home note-ring-contract)
  mkdir -p "$home/fixture/bin"
  # A transport probe records a ring launch without needing any live primary.
  cat > "$home/fixture/bin/nohup" <<'SH'
#!/bin/sh
printf 'ring\n' >> "$FM_HOME/rings"
SH
  chmod +x "$home/fixture/bin/nohup"
  for posture in present away quiet contract; do
    rm -f "$home/state/.afk" "$home/state/.afk-contract" "$home/rings"
    case "$posture" in
      away|quiet) printf '%s\n' "$posture" > "$home/state/.afk" ;;
      contract) printf '{}\n' > "$home/state/.afk-contract" ;;
    esac
    out=$(inbox_note_in "$home" "status $posture") || fail "note failed: $out"
    if [ "$posture" = present ]; then
      for i in $(seq 1 50); do [ ! -e "$home/rings" ] || break; sleep 0.1; done
      [ -s "$home/rings" ] || fail "present posture must launch the ring"
    else
      sleep 0.3
      [ ! -e "$home/rings" ] || fail "$posture posture must suppress the ring"
    fi
    probe=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-inbox.sh" ready)
    [ "$posture" != contract ] || assert_equals away "$(printf '%s' "$probe" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
      "ready and ring must agree on contract-only away mode"
  done
  [ "$(find "$home/state/inbox" -name '*.note' | wc -l | tr -d ' ')" = 4 ] || fail "all postures must retain their notes"
  pass "fm-inbox: ring uses the same .afk and .afk-contract posture as readiness"
}

# The ring is detached from the note, so a case waits for it to finish: its
# Enter, or its composer read followed by the exit of the ring process, whose
# command line names the note.
wait_for_ring() {  # <home> <note-id>
  local home=$1 id=$2 i=0
  while [ "$i" -lt 150 ]; do
    [ -e "$home/fixture/entered" ] && return 0
    if [ -n "$(herdr_calls "$home" pane read)" ] \
      && ! pgrep -f "captain inbox note $id" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_inbox_note_rings_the_busy_primary() {
  local home out id typed started elapsed
  home=$(desk_send_fixture note-ring) || { desk_send_skip note-ring; return 0; }
  started=$(date +%s)
  out=$(inbox_note_in "$home" "connection test ping") || fail "note failed: $out"
  id=$(printf '%s\n' "$out" | sed -n 's/^queued //p')
  [ -n "$id" ] || fail "the note was not queued: $out"
  wait_for_ring "$home" "$id" || fail "the ring never finished"
  elapsed=$(( $(date +%s) - started ))
  typed=$(herdr_calls "$home" pane send-text)
  assert_contains "$typed" "[firstmate inbox] captain inbox note $id is queued" \
    "the primary's pane gets one labelled line naming the note"
  assert_not_contains "$typed" "connection test ping" "the ring carries no note text, only its id"
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "the ring was typed more than once"
  assert_contains "$(herdr_calls "$home" pane send-keys)" "pane send-keys w7:p3 enter" "Enter submits the ring"
  assert_contains "$(cat "$home/state/.wake-queue")" "inbox:$id" "the durable wake is still queued"
  [ "$elapsed" -le 10 ] || fail "ringing took ${elapsed}s, not seconds"
  [ "$(inbox_count "$home")" = 0 ] || fail "a ring must not write the desk mailbox"
  desk_send_done "$home"
  pass "fm-inbox note: a new captain note rings the busy primary within seconds and stays queued"
}

test_inbox_note_ring_never_submits_a_draft_or_rings_away() {
  local home out
  home=$(desk_send_fixture note-ring-draft) || { desk_send_skip note-ring-draft; return 0; }
  printf 'half typed ' > "$home/fixture/draft"
  out=$(inbox_note_in "$home" "status please") || fail "note failed: $out"
  wait_for_ring "$home" "$(printf '%s\n' "$out" | sed -n 's/^queued //p')" \
    || fail "the ring never read the composer"
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "a ring must never be typed onto the captain's draft"
  [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "a ring must never submit the captain's draft"
  assert_contains "$(cat "$home/state/.wake-queue")" "inbox:" "the note still reaches the queue"
  desk_send_done "$home"
  home=$(desk_send_fixture note-ring-away) || { desk_send_skip note-ring-away; return 0; }
  printf 'away\n' > "$home/state/.afk"
  out=$(inbox_note_in "$home" "status please") || fail "note failed: $out"
  [ -z "$(herdr_calls "$home" pane)" ] || fail "away mode's own supervision path must not even be probed"
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "away mode's own supervision path must not be rung over"
  assert_contains "$(cat "$home/state/.wake-queue")" "inbox:" "the note still reaches the queue while away"
  desk_send_done "$home"
  out=$(FM_HOME="$TMP_ROOT/ring-nobody" FM_STATE_OVERRIDE="$TMP_ROOT/ring-nobody/state" "$DESK" ring "hello") \
    || fail "ring with no primary failed: $out"
  [ "$out" = not-rung ] || fail "ring with no primary must report not-rung, got: $out"
  pass "fm-inbox note: the ring never submits a draft, never rings away mode, and falls back to the queue"
}

# Claude 2.1.283's idle chat in Herdr 0.7.4, read from the primary's own pane
# with the transcript text replaced: titled rules, a status line, a new
# message pill, and a dim suggested prompt in the box.
HERDR_CLAUDE_SCREEN="$ROOT/tests/fixtures/composer-claude-dialogs/claude-2.1.283-herdr-suggested-prompt.ansi"

# The line number of the first herdr call matching <words...>, or nothing.
herdr_call_line() {  # <home> <subcommand words...>
  local home=$1 pattern
  shift
  pattern=$(printf '\x1f%s' "$@")
  grep -n -F -- "$pattern" "$home/fixture/herdr.log" | head -n 1 | cut -d: -f1
}

test_desk_voice_send_ignores_a_suggested_prompt() {
  local home out
  home=$(desk_send_fixture send-ghost) || { desk_send_skip send-ghost; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  printf 'Yes, land both glasses changes' > "$home/fixture/ghost"
  out=$(desk_send "$home" "Check the second screenshot") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a suggested prompt does not block the message"
  [ "$(cat "$home/fixture/submitted")" = "Check the second screenshot" ] \
    || fail "only the message may be submitted, got: $(cat "$home/fixture/submitted")"
  [ "$(herdr_calls "$home" pane send-text | wc -l | tr -d ' ')" = 1 ] || fail "text must be typed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: Claude's dim suggested prompt counts as an empty chat box"
}

test_desk_voice_send_goes_past_a_claude_draft() {
  local home out stash typed
  home=$(desk_send_fixture send-draft) || { desk_send_skip send-draft; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  # Normal-intensity text in the box, as a suggestion accepted with Tab or a
  # typed draft reads: the pre-send check Herdr runs for Claude refused it.
  printf 'Yes, land both glasses changes' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a draft does not block the message"
  [ "$(cat "$home/fixture/submitted")" = "and ship it" ] \
    || fail "only the message may be submitted, got: $(cat "$home/fixture/submitted")"
  [ "$(cat "$home/fixture/draft")" = "Yes, land both glasses changes" ] \
    || fail "the draft must be back in the chat box, got: $(cat "$home/fixture/draft")"
  [ ! -e "$home/fixture/stash" ] || fail "the draft must not stay stashed"
  stash=$(herdr_call_line "$home" pane send-keys w7:p3 ctrl+s)
  typed=$(herdr_call_line "$home" pane send-text)
  [ -n "$stash" ] && [ -n "$typed" ] && [ "$stash" -lt "$typed" ] \
    || fail "the draft must be set aside before the message is typed"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 ctrl+s | wc -l | tr -d ' ')" = 1 ] \
    || fail "the draft is set aside once and restored by the chat itself"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
    || fail "Enter must be pressed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a Claude draft is set aside, the message sent alone, and the draft put back"
}

# A herdr read with a line count of an idle Claude pane makes herdr scroll
# Claude's conversation up to collect its history and back again, which the
# captain sees as the chat jumping while a message is delivered. Every screen
# check on the send path reads the viewport instead.
test_desk_voice_send_reads_only_the_visible_screen() {
  local home out reads
  home=$(desk_send_fixture send-viewport-draft) || { desk_send_skip send-viewport-draft; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  printf 'Yes, land both glasses changes' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "the message goes past the draft"
  reads=$(herdr_calls "$home" pane read)
  [ -n "$reads" ] || fail "the send must still read the screen"
  assert_not_contains "$reads" "--lines" "a send past a draft never asks herdr for history"
  assert_not_contains "$reads" "--source recent" "a send past a draft reads only the visible screen"
  desk_send_done "$home"
  home=$(desk_send_fixture send-viewport-dialog) || { desk_send_skip send-viewport-dialog; return 0; }
  # An empty chat box under a picker's footer: the composer check passes it,
  # so only the dialog check keeps the words out of the picker.
  printf '%s\n' ' Which branch should I merge?' ' Enter to select · Esc to cancel' \
    '────────────────────────────────────────' '❯' \
    '────────────────────────────────────────' '  ⏵⏵ auto mode on' > "$home/fixture/screen"
  out=$(desk_send "$home" "main please") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  reads=$(herdr_calls "$home" pane read)
  [ -n "$reads" ] || fail "the dialog check must still read the screen"
  assert_not_contains "$reads" "--lines" "the dialog check never asks herdr for history"
  desk_send_done "$home"
  pass "fm-desk-voice send: every screen check reads the visible screen, never herdr history"
}

test_desk_voice_send_goes_past_a_draft_in_a_narrow_pane() {
  local home out
  home=$(desk_send_fixture send-draft-narrow) || { desk_send_skip send-draft-narrow; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  # A narrow or busy pane wraps Claude's `› stashed` onto a footer row of its
  # own (verified live on claude 2.1.283, herdr and tmux): that marker is not
  # text in the box, so the emptied box still takes the message.
  : > "$home/fixture/narrow"
  printf 'CURLEW draft typed while busy' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a wrapped stash marker does not block the message"
  [ "$(cat "$home/fixture/submitted")" = "and ship it" ] \
    || fail "only the message may be submitted, got: $(cat "$home/fixture/submitted" 2>/dev/null)"
  [ "$(cat "$home/fixture/draft")" = "CURLEW draft typed while busy" ] || fail "the draft must be back in the chat box"
  [ ! -e "$home/fixture/stash" ] || fail "the draft must not stay stashed"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
    || fail "Enter must be pressed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a stash marker wrapped onto its own footer row is not read as text in the box"
}

test_desk_voice_send_goes_past_a_pasted_text_draft() {
  local home out
  home=$(desk_send_fixture send-draft-paste) || { desk_send_skip send-draft-paste; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  # A multi-line paste collapsed by Claude: the whole draft is its placeholder.
  printf '[Pasted text #1 +42 lines]' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a restored paste placeholder is not the message"
  [ "$(cat "$home/fixture/submitted")" = "and ship it" ] \
    || fail "only the message may be submitted, got: $(cat "$home/fixture/submitted")"
  [ "$(cat "$home/fixture/draft")" = "[Pasted text #1 +42 lines]" ] || fail "the pasted draft must be back in the chat box"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
    || fail "Enter must be pressed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a draft that is only a pasted-text placeholder is put back and the send confirmed"
}

test_desk_voice_send_keeps_a_draft_it_cannot_set_aside() {
  local home out case
  for case in stashed no-stash; do
    home=$(desk_send_fixture "send-draft-$case") || { desk_send_skip "send-draft-$case"; return 0; }
    cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
    printf 'claude' > "$home/fixture/agent"
    printf 'half typed thought' > "$home/fixture/draft"
    if [ "$case" = stashed ]; then
      printf 'an earlier stash' > "$home/fixture/stash"
    else
      : > "$home/fixture/no-stash"
    fi
    out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "$case: expected a mailbox delivery, got: $out" ;; esac
    [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "$case: nothing may be typed"
    [ -z "$(herdr_calls "$home" pane send-keys w7:p3 enter)" ] || fail "$case: no Enter may be pressed"
    [ ! -e "$home/fixture/submitted" ] || fail "$case: nothing may be submitted"
    [ "$(cat "$home/fixture/draft")" = "half typed thought" ] || fail "$case: the draft must stay in the box"
    if [ "$case" = stashed ]; then
      [ "$(cat "$home/fixture/stash")" = "an earlier stash" ] || fail "an earlier stash must be kept"
      [ -z "$(herdr_calls "$home" pane send-keys w7:p3 ctrl+s)" ] || fail "an earlier stash must not be replaced"
    fi
    [ "$(inbox_count "$home")" = 1 ] || fail "$case: the message must land in the mailbox once"
    desk_send_done "$home"
  done
  pass "fm-desk-voice send: a draft that cannot be set aside safely stays put and the message goes to the mailbox"
}

test_desk_voice_send_proves_a_long_message_past_a_claude_draft() {
  local home out long
  home=$(desk_send_fixture send-draft-long) || { desk_send_skip send-draft-long; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  : > "$home/fixture/wrap"
  printf 'half typed thought' > "$home/fixture/draft"
  # 759 characters, short enough for Claude to show as text, wrap to 19 box
  # rows, more than a 20-row read can hold with the rules and footer.
  long=$(printf 'word%03d ' $(seq 1 95))
  long=${long% }
  out=$(desk_send "$home" "$long") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a long message is proven whole and sent"
  [ "$(cat "$home/fixture/submitted")" = "$long" ] || fail "only the whole message may be submitted"
  [ "$(cat "$home/fixture/draft")" = "half typed thought" ] || fail "the draft must be back in the chat box"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a message that wraps past a 20-row read still goes past a Claude draft"
}

test_desk_voice_send_pastes_a_voice_length_message_past_a_claude_draft() {
  local home out long case draft
  # About 3.2k characters, the length of a long voice transcript: typed, Claude
  # would fold it into a placeholder plus a literal tail that cannot be proven.
  long=$(printf 'word%03d ' $(seq 1 400))
  long=${long% }
  for case in typed pasted; do
    home=$(desk_send_fixture "send-draft-voice-$case") || { desk_send_skip "send-draft-voice-$case"; return 0; }
    cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
    printf 'claude' > "$home/fixture/agent"
    if [ "$case" = typed ]; then draft='half typed thought'; else draft='[Pasted text #1 +42 lines]'; fi
    printf '%s' "$draft" > "$home/fixture/draft"
    out=$(desk_send "$home" "$long") || fail "$case: send failed: $out"
    assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "$case: a voice-length message goes past the draft"
    [ "$(cat "$home/fixture/submitted")" = "$long" ] || fail "$case: only the whole message may be submitted"
    [ "$(cat "$home/fixture/draft")" = "$draft" ] || fail "$case: the draft must be back in the chat box"
    [ ! -e "$home/fixture/stash" ] || fail "$case: the draft must not stay stashed"
    [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
      || fail "$case: Enter must be pressed exactly once"
    [ "$(inbox_count "$home")" = 0 ] || fail "$case: a pane delivery must not also land in the mailbox"
    desk_send_done "$home"
  done
  pass "fm-desk-voice send: a voice-length message is pasted past a Claude draft, shown as one placeholder, and sent"
}

test_desk_voice_send_waits_for_a_late_drawn_message_past_a_claude_draft() {
  local home out
  home=$(desk_send_fixture send-draft-late) || { desk_send_skip send-draft-late; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  printf 'half typed thought' > "$home/fixture/draft"
  # A busy chat that has not drawn the paste yet reads empty; a Ctrl+S then
  # would stash the message over the captain's draft.
  printf '6' > "$home/fixture/late-paste"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a message drawn late still goes past the draft"
  [ "$(cat "$home/fixture/submitted")" = "and ship it" ] \
    || fail "only the message may be submitted, got: $(cat "$home/fixture/submitted" 2>/dev/null)"
  [ "$(cat "$home/fixture/draft")" = "half typed thought" ] \
    || fail "the draft must be back in the chat box, got: $(cat "$home/fixture/draft")"
  [ ! -e "$home/fixture/stash" ] || fail "the draft must not stay stashed"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 ctrl+s | wc -l | tr -d ' ')" = 1 ] \
    || fail "Ctrl+S must not be pressed again while the message may still arrive"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
    || fail "Enter must be pressed exactly once"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: a message the chat draws late is waited for, not stashed over the draft"
}

test_desk_voice_send_never_confirms_a_redrawn_message_past_a_draft() {
  local home out long
  home=$(desk_send_fixture send-draft-refold) || { desk_send_skip send-draft-refold; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  : > "$home/fixture/refold"
  printf 'half typed thought' > "$home/fixture/draft"
  long=$(printf 'word%03d ' $(seq 1 60))
  long=${long% }
  out=$(desk_send "$home" "$long") || fail "send failed: $out"
  case "$out" in
    sent-unconfirmed:\ *) ;;
    *) fail "a message redrawn in the box but never submitted must not read as sent, got: $out" ;;
  esac
  [ ! -e "$home/fixture/submitted" ] || fail "nothing was submitted"
  [ "$(herdr_calls "$home" pane send-keys w7:p3 enter | wc -l | tr -d ' ')" = 1 ] \
    || fail "Enter must be pressed exactly once"
  desk_send_done "$home"
  pass "fm-desk-voice send: a message Claude redraws instead of submitting is not reported as sent"
}

test_desk_voice_send_keeps_the_stash_when_paste_outlives_proof() {
  local home out suggestion
  for suggestion in absent shown; do
    home=$(desk_send_fixture "send-draft-too-late-$suggestion") || { desk_send_skip "send-draft-too-late-$suggestion"; return 0; }
    printf 'half typed thought' > "$home/fixture/draft"
    printf '200' > "$home/fixture/late-paste"
    [ "$suggestion" = absent ] || printf 'suggested words' > "$home/fixture/ghost"
    out=$(desk_send "$home" 'delayed message') || fail "send failed: $out"
    assert_contains "$out" 'sent-unconfirmed:' "unseen buffered input has an unknown outcome"
    [ "$(cat "$home/fixture/stash")" = 'half typed thought' ] || fail "the original draft must remain stashed"
    [ "$(cat "$home/fixture/queued")" = 'delayed message' ] || fail "the paste must still be buffered"
    [ "$(herdr_calls "$home" pane send-keys | wc -l | tr -d ' ')" = 1 ] || fail "only the initial stash key may be sent"
    [ ! -e "$home/fixture/submitted" ] || fail "nothing may be submitted"
    [ "$(inbox_count "$home")" = 0 ] || fail "buffered input must not also reach the mailbox"
    desk_send_done "$home"
  done
  pass "desk send: a paste delayed beyond the proof window never receives recovery Ctrl+S"
}

test_desk_voice_send_never_submits_a_draft_left_stashed() {
  local home out backend
  for backend in herdr tmux; do
    home=$(desk_send_fixture "send-after-stash-$backend" "$backend") \
      || { desk_send_skip "send-after-stash-$backend"; return 0; }
    : > "$home/fixture/tmux-composer"
    : > "$home/fixture/agent-idle"
    if [ "$backend" = herdr ]; then
      printf 'half typed thought' > "$home/fixture/draft"
      printf '200' > "$home/fixture/late-paste"
      out=$(desk_send "$home" 'delayed message') || fail "send failed: $out"
      assert_contains "$out" 'sent-unconfirmed:' "the delayed paste leaves the draft stashed"
      # The delayed paste is lost, so the box is empty over the kept stash.
      rm -f "$home/fixture/queued" "$home/fixture/queued-reads" "$home/fixture/late-paste"
    else
      printf 'half typed thought' > "$home/fixture/stash"
    fi
    out=$(desk_send "$home" 'next message') || fail "send failed: $out"
    assert_contains "$out" "$backend" "the next message still goes to the primary's pane"
    [ "$(cat "$home/fixture/submitted")" = 'next message' ] || fail "$backend: only the new message may be submitted"
    [ "$(cat "$home/fixture/draft")" = 'half typed thought' ] || fail "$backend: the restored draft must stay unsent"
    [ "$(inbox_count "$home")" = 0 ] || fail "$backend: a typed message must not also reach the mailbox"
    desk_send_done "$home"
  done
  pass "desk send: a message sent over a stashed draft presses Enter once, so the restored draft stays unsent"
}

test_desk_voice_send_clears_a_refused_message_and_restores_the_draft() {
  local home out long case
  long=$(printf 'word%03d ' $(seq 1 125))
  long=${long% }
  for case in restored pop-fails; do
    home=$(desk_send_fixture "send-draft-refused-$case") || { desk_send_skip "send-draft-refused-$case"; return 0; }
    cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
    printf 'claude' > "$home/fixture/agent"
    : > "$home/fixture/wrap"
    : > "$home/fixture/drop-head"
    [ "$case" = restored ] || : > "$home/fixture/pop-fails"
    printf 'half typed thought' > "$home/fixture/draft"
    out=$(desk_send "$home" "$long") || fail "send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "$case: a message not proven in the box must go to the mailbox, got: $out" ;; esac
    [ -z "$(herdr_calls "$home" pane send-keys w7:p3 enter)" ] || fail "$case: no Enter may be pressed"
    [ ! -e "$home/fixture/submitted" ] || fail "$case: nothing may be submitted"
    if [ "$case" = restored ]; then
      [ "$(cat "$home/fixture/draft")" = "half typed thought" ] || fail "the draft must be back in the chat box"
    else
      [ "$(cat "$home/fixture/stash")" = "half typed thought" ] || fail "the draft must stay stashed"
      [ -z "$(cat "$home/fixture/draft")" ] || fail "the refused message must be cleared"
    fi
    [ "$(inbox_count "$home")" = 1 ] || fail "$case: the message must land in the mailbox once"
    desk_send_done "$home"
  done
  pass "fm-desk-voice send: a long message refused before Enter is cleared and sent to the mailbox"
}

test_desk_voice_send_restores_a_draft_stashed_without_a_marker() {
  local home out
  home=$(desk_send_fixture send-draft-no-marker) || { desk_send_skip send-draft-no-marker; return 0; }
  cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
  printf 'claude' > "$home/fixture/agent"
  : > "$home/fixture/no-marker"
  printf 'half typed thought' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "expected a mailbox delivery, got: $out" ;; esac
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed"
  [ "$(cat "$home/fixture/draft")" = "half typed thought" ] || fail "the draft must be put back in the chat box"
  [ ! -e "$home/fixture/stash" ] || fail "the draft must not stay stashed"
  [ "$(inbox_count "$home")" = 1 ] || fail "the message must land in the mailbox once"
  desk_send_done "$home"
  pass "fm-desk-voice send: a draft stashed without a readable marker is put back before the mailbox"
}

test_desk_voice_send_joins_another_harness_draft() {
  local home out
  home=$(desk_send_fixture send-draft-codex herdr codex) || { desk_send_skip send-draft-codex; return 0; }
  printf 'half typed ' > "$home/fixture/draft"
  out=$(desk_send "$home" "and ship it") || fail "send failed: $out"
  assert_contains "$out" "sent: herdr fm-desk-send-test:w7:p3" "a pending draft still takes the transcript"
  [ "$(cat "$home/fixture/submitted")" = "half typed and ship it" ] \
    || fail "the draft and message must be submitted together, got: $(cat "$home/fixture/submitted")"
  [ -z "$(herdr_calls "$home" pane send-keys w7:p3 ctrl+s)" ] || fail "only Claude's draft is stashed"
  [ "$(inbox_count "$home")" = 0 ] || fail "a pane delivery must not also land in the mailbox"
  desk_send_done "$home"
  pass "fm-desk-voice send: another harness's half-typed draft is joined and submitted"
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

# A screenshot nobody spoke about can arrive while the captain is typing, so it
# never sets the draft aside or joins it: it waits in the mailbox instead.
test_desk_voice_send_screenshots_alone_never_go_past_a_draft() {
  local home out shot path harness
  for harness in claude codex; do
    home=$(desk_send_fixture "send-shots-draft-$harness" herdr "$harness") \
      || { desk_send_skip "send-shots-draft-$harness"; return 0; }
    shot="$home/one.png"
    printf PNG > "$shot"
    if [ "$harness" = claude ]; then
      cp "$HERDR_CLAUDE_SCREEN" "$home/fixture/screen"
      printf 'claude' > "$home/fixture/agent"
    fi
    printf 'What if we did 2. with 3. somehow' > "$home/fixture/draft"
    out=$(desk_send "$home" --image "$shot" --) || fail "$harness: send failed: $out"
    case "$out" in mailbox:\ *) ;; *) fail "$harness: expected a mailbox delivery, got: $out" ;; esac
    path=${out#mailbox: }
    assert_contains "$(cat "$path")" "Screenshots: $shot" "$harness: the mailbox record holds the screenshot"
    [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "$harness: nothing may be typed over a draft"
    [ -z "$(herdr_calls "$home" pane send-keys)" ] || fail "$harness: no key may reach a pane with a draft"
    [ "$(cat "$home/fixture/draft")" = 'What if we did 2. with 3. somehow' ] \
      || fail "$harness: the draft must stay as typed, got: $(cat "$home/fixture/draft")"
    [ ! -s "$home/fixture/submitted" ] || fail "$harness: nothing may be submitted"
    desk_send_done "$home"
  done
  pass "fm-desk-voice send: screenshots alone wait in the mailbox while a draft is in the chat box"
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

# The Windows floater cannot name a terminal device, so it asks whether the
# chat's tmux client has its terminal's focus (docs/desk-floater-windows.md).
test_desk_voice_dictation_front_focused_on_tmux() {
  local home out
  home=$(desk_send_fixture front-focused tmux) || { desk_send_skip front-focused; return 0; }
  printf '%s 11\n' "\$1" > "$home/fixture/tmux-active"
  # The fake tmux server tracks focus since 1000.
  printf '1000\n' > "$home/fixture/tmux-focus-since"
  printf '1001 attached,focused,UTF-8\n' > "$home/fixture/tmux-clients"
  # In front, the fake's unreadable chat input sends it on to the mailbox.
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "a focused client on the active pane is in front, got: $out" ;; esac
  assert_contains "$(tr '\037' ' ' < "$home/fixture/tmux.log")" "list-clients -t \$1 -F #{client_created} #{client_flags}" \
    "the focus of the pane's own session's clients is read"
  printf '1001 attached,UTF-8\n1002 attached,UTF-8,read-only\n' > "$home/fixture/tmux-clients"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "no focused client must not count as in front, got: $out"
  # focus-events turned on at 2000 in the running server: a client attached
  # at 1500 keeps a stale focused flag, one attached at 2000 is tracked.
  printf '2000\n' > "$home/fixture/tmux-focus-since"
  printf '1500 attached,focused,UTF-8\n' > "$home/fixture/tmux-clients"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "a client attached before focus tracking began must not count, got: $out"
  printf '1500 attached,focused,UTF-8\n2000 attached,focused,UTF-8\n' > "$home/fixture/tmux-clients"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  case "$out" in mailbox:\ *) ;; *) fail "a client attached once focus was tracked counts, got: $out" ;; esac
  printf 'off\n' > "$home/fixture/tmux-focus-events"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "without focus-events nothing counts as in front, got: $out"
  rm -f "$home/fixture/tmux-focus-events" "$home/fixture/tmux-focus-since"
  printf '1001 attached,focused,UTF-8\n' > "$home/fixture/tmux-clients"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "with no record of when focus tracking began nothing counts, got: $out"
  printf '1000\n' > "$home/fixture/tmux-focus-since"
  printf '%s 10\n' "\$1" > "$home/fixture/tmux-active"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "an inactive pane must not count as in front, got: $out"
  rm -f "$home/state/.lock"
  printf '%s 11\n' "\$1" > "$home/fixture/tmux-active"
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "no primary must not count as in front, got: $out"
  ! grep -qF send-keys "$home/fixture/tmux.log" || fail "no keys may reach the tmux pane"
  [ "$(inbox_count "$home")" = 2 ] || fail "only the in-front dictations may land in the mailbox"
  desk_send_done "$home"
  home=$(desk_send_fixture front-focused-herdr) || { desk_send_skip front-focused-herdr; return 0; }
  out=$(desk_send "$home" --front-focused -- "Status please") || fail "send failed: $out"
  [ "$out" = not-in-front ] || fail "a herdr primary is never in front this way, got: $out"
  [ -z "$(herdr_calls "$home" pane send-text)" ] || fail "nothing may be typed into a herdr chat"
  [ ! -s "$home/fixture/tmux.log" ] || fail "dictation toward a herdr primary must never call tmux: $(cat "$home/fixture/tmux.log")"
  desk_send_done "$home"
  pass "fm-desk-voice send --front-focused: only the active tmux pane of a focus-tracked client is in front"
}

test_desk_voice_dictation_refuses_bad_front_arguments() {
  local home out status
  home=$(new_home front-args)
  for args in "--front-app 0 --front-tty /dev/ttys001" "--front-app 12x --front-tty /dev/ttys001" \
    "--front-app 12 --front-tty /tmp/x" "--front-app 12" \
    "--front-focused --front-app 12 --front-tty /dev/ttys001"; do
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

# The Windows floater takes its screenshots on Windows and hands them over.
test_desk_voice_shot_stores_a_png_from_stdin() {
  local home path status=0 out left first second third
  home=$(new_home shot-stdin)
  printf '\211PNG\r\n\032\nwindows-image' > "$home/in.png"
  path=$(shoot_in "$home" --stdin < "$home/in.png") || fail "shot --stdin failed: $path"
  case "$path" in
    "$home/state/desk-voice/shots/"*.png) ;;
    *) fail "shot --stdin path is not in the home's screenshot folder: $path" ;;
  esac
  cmp -s "$home/in.png" "$path" || fail "shot --stdin must keep the image exactly"
  [ "$(mode_of "$path")" = 600 ] || fail "a handed-over screenshot must be private"
  [ ! -e "$home/capture.log" ] || fail "shot --stdin must not capture the screen"
  printf 'not an image' | shoot_in "$home" --stdin >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for input that is not a PNG, got $status"
  : | shoot_in "$home" --stdin >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "expected exit 1 for no input, got $status"
  left=$(find "$home/state/desk-voice/shots" -type f | wc -l | tr -d ' ')
  [ "$left" -eq 1 ] || fail "refused input left $((left - 1)) file(s) behind"
  status=0
  out=$(shoot_in "$home" --stdin --display 2 < "$home/in.png" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "expected exit 2 for --stdin with --display, got $status: $out"
  first=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home" --stdin < "$home/in.png") || fail "shot failed"
  second=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home" --stdin < "$home/in.png") || fail "shot failed"
  third=$(FM_DESK_SHOTS_KEEP=2 shoot_in "$home" --stdin < "$home/in.png") || fail "shot failed"
  [ ! -e "$path" ] && [ ! -e "$first" ] && [ -f "$second" ] && [ -f "$third" ] \
    || fail "handed-over screenshots are pruned to the newest like captured ones"
  pass "fm-desk-voice: shot --stdin stores a handed-over PNG, refuses anything else, and prunes"
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

# The floater's screenshot-stacking rules, voice capture and capture conversion are Swift, so they need macOS and swift.
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

test_tts_request_opts_out_of_model_improvement() {
  local home out
  home=$(new_home tts-mip)
  install_stt_curl "$home" 200 'mp3-bytes'
  out=$(DEEPGRAM_API_KEY=test-key-not-real FM_DEEPGRAM_ENV_FILE=/dev/null FM_DEEPGRAM_CURL="$home/curl" \
    "$TTS" --to "$home/out.mp3" -- "Captain, checks are green." 2>&1) || fail "tts failed: $out"
  assert_contains "$(cat "$home/curl.log")" "/v1/speak?" "the request goes to the speak endpoint"
  assert_contains "$(cat "$home/curl.log")" "mip_opt_out=true" "the speak request opts out of model improvement"
  pass "fm-deepgram-tts: the speak request opts out of Deepgram model improvement"
}

test_tts_refuses_without_key
test_tts_dry_run_with_key
test_tts_request_opts_out_of_model_improvement
test_stt_refuses_without_key_or_file
test_stt_prints_transcript_from_mocked_deepgram
test_stt_reports_http_failure
test_stt_bounds_a_long_request_and_retries_without_a_length_cap
test_stt_names_the_bound_when_deepgram_never_answers
test_stt_gives_up_on_a_stalled_request_and_retries
test_stt_keeps_a_slow_upload_that_is_still_moving
test_stt_without_vocabulary_sends_no_hints
test_stt_vocabulary_key_terms_reach_the_request_encoded
test_stt_starter_vocabulary_sends_only_its_terms
test_stt_vocabulary_caps_key_terms
test_stt_vocabulary_rewrites_the_printed_transcript
test_stt_vocabulary_rewrites_longest_whole_phrase_first
test_stt_vocabulary_ignores_malformed_lines
test_stt_vocabulary_preserves_compound_tokens
test_stt_vocabulary_rewrites_possessive_names
test_stt_vocabulary_rewrites_complete_compounds_and_valid_shorter_phrases
test_stt_reads_the_model_from_dotenv
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
test_desk_voice_keeps_a_recording_until_its_words_are_delivered
test_desk_voice_retry_of_a_ten_minute_recording_delivers_every_word
test_desk_voice_retry_of_dictation_returns_the_words
test_desk_voice_keep_never_removes_a_saved_recording
test_desk_voice_retry_keeps_the_recording_when_the_mailbox_cannot_save
test_desk_voice_retry_refuses_anything_but_a_saved_recording
test_desk_voice_retries_run_one_at_a_time
test_desk_voice_send_types_into_the_primary_pane
test_desk_voice_send_falls_back_without_a_live_primary
test_desk_voice_send_refuses_a_pane_not_hosting_the_primary
test_desk_voice_send_falls_back_when_the_pane_refuses_text
test_desk_voice_send_never_doubles_an_unconfirmed_submit
test_desk_voice_send_falls_back_when_the_pane_shows_a_dialog
test_desk_voice_send_ignores_a_suggested_prompt
test_desk_voice_send_goes_past_a_claude_draft
test_desk_voice_send_reads_only_the_visible_screen
test_desk_voice_send_goes_past_a_draft_in_a_narrow_pane
test_desk_voice_send_goes_past_a_pasted_text_draft
test_desk_voice_send_keeps_a_draft_it_cannot_set_aside
test_desk_voice_send_proves_a_long_message_past_a_claude_draft
test_desk_voice_send_pastes_a_voice_length_message_past_a_claude_draft
test_desk_voice_send_clears_a_refused_message_and_restores_the_draft
test_desk_voice_send_waits_for_a_late_drawn_message_past_a_claude_draft
test_desk_voice_send_keeps_the_stash_when_paste_outlives_proof
test_desk_voice_send_never_submits_a_draft_left_stashed
test_desk_voice_send_never_confirms_a_redrawn_message_past_a_draft
test_desk_voice_send_restores_a_draft_stashed_without_a_marker
test_desk_voice_send_joins_another_harness_draft
test_desk_voice_mailbox_rings_the_primary_once_its_chat_is_free
test_desk_voice_mailbox_ring_stops_once_drained_or_away
test_desk_voice_mailbox_ring_never_submits_a_draft_or_stash
test_inbox_note_rings_the_busy_primary
test_inbox_note_ring_never_submits_a_draft_or_rings_away
test_ring_checks_the_payload_before_each_enter
test_ring_waits_for_a_late_paste_and_a_late_redraw
test_ring_and_send_share_one_writer_lock
test_inbox_ring_respects_contract_only_away_posture
test_desk_voice_send_types_screenshots_into_the_primary_pane
test_desk_voice_send_screenshots_fall_back_to_the_mailbox
test_desk_voice_send_screenshots_alone_never_go_past_a_draft
test_desk_voice_dictation_sends_when_the_chat_is_in_front
test_desk_voice_dictation_elsewhere_is_left_to_paste
test_desk_voice_dictation_keeps_the_send_checks
test_desk_voice_dictation_front_check_on_tmux
test_desk_voice_dictation_front_focused_on_tmux
test_desk_voice_dictation_refuses_bad_front_arguments
test_desk_voice_shot_captures_the_named_display
test_desk_voice_shot_capture_file_name_has_no_leading_dot
test_desk_voice_shot_keeps_only_the_newest
test_desk_voice_shot_failure_leaves_nothing
test_desk_voice_shot_stores_a_png_from_stdin
test_desk_voice_deliver_with_screenshots
test_floater_swift_tests
test_deepgram_lib_reads_dotenv_without_logging_key
test_tts_reads_the_voice_from_dotenv

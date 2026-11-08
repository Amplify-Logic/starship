#!/usr/bin/env bash
# Real Deepgram guard for the call recorder's Deepgram engine.
# bin/fm-call-mic.sh sends each mixed chunk to Deepgram through
# bin/fm-deepgram-stt.sh --segments and labels the answer by track, so this
# drives one real chunk end to end: a short sentence spoken by macOS `say`
# (nobody is recorded), mixed and transcribed by the real worker path, then
# written into a transcript. It spends a few seconds of Deepgram time, so it
# is opt-in: FM_CALL_DEEPGRAM_LIVE=1, with DEEPGRAM_API_KEY in the environment
# or FM_DEEPGRAM_ENV_FILE naming the .env that holds it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CALL_DEEPGRAM_LIVE say ffmpeg jq python3

TMP_ROOT=$(fm_test_tmproot fm-call-deepgram-live)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state"
printf 'transcription_engine = deepgram\n' > "$HOME_DIR/config/call-companion"

key_present() {
  ( cd "$ROOT" && FM_HOME="$HOME_DIR" bash -c '. bin/fm-call-lib.sh && fm_call_deepgram_key_present' )
}
key_present || fail 'FM_CALL_DEEPGRAM_LIVE=1 but no Deepgram key: set DEEPGRAM_API_KEY or FM_DEEPGRAM_ENV_FILE'

SENTENCE='The quick brown fox jumps over the lazy dog'
say -o "$TMP_ROOT/clip.aiff" "$SENTENCE" || fail 'say could not synthesize the sentence'
PREFIX="$HOME_DIR/state/calls/audio/chunk-live-1"
mkdir -p "$(dirname "$PREFIX")"
ffmpeg -nostdin -hide_banner -loglevel error -i "$TMP_ROOT/clip.aiff" -ar 16000 -ac 1 -c:a pcm_s16le -y "$PREFIX-mic.wav" \
  || fail 'ffmpeg could not make the 16 kHz chunk'

# The helper alone: timed segments that carry the sentence.
segments=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-deepgram-stt.sh" --segments "$PREFIX-mic.wav" 2> "$TMP_ROOT/stt.stderr") \
  || fail "fm-deepgram-stt.sh --segments failed: $(cat "$TMP_ROOT/stt.stderr")"
printf '%s\n' "$segments" | jq -e '.transcription | length >= 1 and (.[0].offsets.to > .[0].offsets.from)' >/dev/null \
  || fail "segments carry no timed text: $segments"
printf '%s\n' "$segments" | jq -r '[.transcription[].text] | join(" ")' | tr '[:upper:]' '[:lower:]' | grep -q 'quick brown fox' \
  || fail "Deepgram did not hear the sentence: $segments"

# The real worker path: mix, send, label by track, write the line, delete the audio.
FM_HOME="$HOME_DIR" MIC_ENGINE=deepgram MIC_CHUNK_SECONDS=30 \
  "$ROOT/bin/fm-call-mic.sh" --transcribe "$PREFIX" 12:00:00 2> "$TMP_ROOT/worker.stderr" \
  || fail "the chunk worker failed: $(cat "$TMP_ROOT/worker.stderr")"
transcript="$HOME_DIR/data/calls/transcript.txt"
[ -s "$transcript" ] || fail "no transcript line was written: $(cat "$TMP_ROOT/worker.stderr")"
grep -q '^\[12:00:[0-9][0-9]\] unknown speaker: ' "$transcript" || fail "the line is not labelled by track: $(cat "$transcript")"
tr '[:upper:]' '[:lower:]' < "$transcript" | grep -q 'quick brown fox' || fail "the transcript does not carry the sentence: $(cat "$transcript")"
[ -z "$(find "$HOME_DIR/state/calls/audio" -type f 2>/dev/null)" ] || fail "chunk audio outlived its transcript: $(find "$HOME_DIR/state/calls/audio" -type f)"
[ ! -e "$HOME_DIR/state/calls/engine-note" ] || fail "a working Deepgram left a note: $(cat "$HOME_DIR/state/calls/engine-note")"
key=$(cd "$ROOT" && FM_HOME="$HOME_DIR" bash -c '. bin/fm-deepgram-lib.sh && fm_deepgram_api_key')
! grep -rqF -- "$key" "$transcript" "$TMP_ROOT/worker.stderr" "$TMP_ROOT/stt.stderr" || fail 'the key leaked into the transcript or a log'

pass "a spoken sentence went through the real Deepgram chunk path into a labelled transcript line: $(cat "$transcript")"
fm_test_cleanup

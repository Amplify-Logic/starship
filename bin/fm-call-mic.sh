#!/usr/bin/env bash
# fm-call-mic.sh - record the microphone and the call audio as separate tracks
# in overlapping chunks, and transcribe each chunk locally with whisper.cpp.
#
# Usage:
#   fm-call-mic.sh                 run until stopped (started by fm-call-companion.sh)
#   fm-call-mic.sh --test <seconds>  record once and print the transcript
#
# Normal mode starts a 30-second chunk every 28 seconds, then measures,
# gain-stages, limits and mixes each finished chunk and transcribes it. Every
# chunk's audio is deleted as soon as its transcript line is written, so no
# recording outlives its text. Speech is labelled by the track that carried it
# (bin/fm-call-speaker-split.py): the speaker_name setting for microphone-only
# speech, "others" for the call audio, "unknown speaker" otherwise.
#
# macOS only: capture uses ffmpeg's avfoundation input. Settings and paths come
# from bin/fm-call-lib.sh. Environment overrides: FFMPEG_BIN, WHISPER_BIN,
# WHISPER_MODEL, MIC_DEVICE_NAME, LOOPBACK_DEVICE_PATTERN, MIC_CHUNK_SECONDS,
# MIC_CHUNK_OVERLAP_SECONDS, MIC_MAX_CHUNKS (0 = unlimited),
# CALL_COMPANION_TRANSCRIPT, CALL_COMPANION_WORK_DIR, CALL_COMPANION_PYTHON_BIN.

set -euo pipefail

# shellcheck source=bin/fm-call-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-call-lib.sh"
SCRIPT_PATH="$FM_CALL_BIN/$(basename "${BASH_SOURCE[0]}")"
TRANSCRIPT=${CALL_COMPANION_TRANSCRIPT:-$FM_CALL_DATA/transcript.txt}
WORK_DIR=${CALL_COMPANION_WORK_DIR:-$FM_CALL_STATE/audio}
STATE_DIR=$FM_CALL_STATE
MODEL_STATE="$STATE_DIR/whisper-model"
FFMPEG_BIN=${FFMPEG_BIN:-$(fm_call_tool ffmpeg /opt/homebrew/bin/ffmpeg)}
WHISPER_BIN=${WHISPER_BIN:-$(fm_call_tool whisper-cli /opt/homebrew/bin/whisper-cli)}
BASE_MODEL="$HOME/.cache/whisper/ggml-base.en.bin"
TURBO_MODEL="$HOME/.cache/whisper/ggml-large-v3-turbo.bin"
MODEL_OVERRIDE=${WHISPER_MODEL:-$(fm_call_setting whisper_model '')}
WHISPER_MODEL=
MIC_DEVICE_NAME=${MIC_DEVICE_NAME-$(fm_call_setting mic_device '')}
LOOPBACK_DEVICE_PATTERN=${LOOPBACK_DEVICE_PATTERN-$(fm_call_setting loopback_device BlackHole)}
CHUNK_SECONDS=${MIC_CHUNK_SECONDS:-30}
OVERLAP_SECONDS=${MIC_CHUNK_OVERLAP_SECONDS:-2}
MAX_CHUNKS=${MIC_MAX_CHUNKS:-0}
PYTHON_BIN=${CALL_COMPANION_PYTHON_BIN:-$(fm_call_tool python3 /usr/bin/python3)}
SPEAKER_SPLIT=${CALL_COMPANION_SPEAKER_SPLIT:-$FM_CALL_BIN/fm-call-speaker-split.py}
LOCAL_SPEAKER=$(fm_call_setting speaker_name me)

child_pid=
mic_device=
loopback_device=
started_record_pid=
measured_max=
session_id="$(date '+%Y%m%d-%H%M%S')-$$"
record_pids=()
worker_pids=()
chunk_prefixes=()

usage() {
  cat <<'EOF' >&2
usage: fm-call-mic.sh
       fm-call-mic.sh --test <seconds>

Normal mode starts a 30-second source-separated chunk every 28 seconds,
then measures, gain-stages, limits, mixes, and transcribes completed chunks.
EOF
}

select_model() {
  if [ -n "$MODEL_OVERRIDE" ]; then
    WHISPER_MODEL=$MODEL_OVERRIDE
  elif [ -s "$MODEL_STATE" ] && [ -f "$(sed -n '1p' "$MODEL_STATE")" ]; then
    WHISPER_MODEL=$(sed -n '1p' "$MODEL_STATE")
  elif [ -f "$TURBO_MODEL" ]; then
    WHISPER_MODEL=$TURBO_MODEL
  else
    WHISPER_MODEL=$BASE_MODEL
  fi
}

require_tools() {
  [ -x "$FFMPEG_BIN" ] || { printf 'fm-call-mic: ffmpeg not executable at %s\n' "$FFMPEG_BIN" >&2; exit 127; }
  [ -x "$WHISPER_BIN" ] || { printf 'fm-call-mic: whisper-cli not executable at %s\n' "$WHISPER_BIN" >&2; exit 127; }
  select_model
  [ -f "$WHISPER_MODEL" ] || { printf 'fm-call-mic: Whisper model not found at %s\n' "$WHISPER_MODEL" >&2; exit 1; }
}

validate_timing() {
  [[ "$CHUNK_SECONDS" =~ ^[0-9]+$ ]] && [ "$CHUNK_SECONDS" -ge 2 ] || { printf 'fm-call-mic: chunk duration must be at least 2 seconds\n' >&2; exit 2; }
  [[ "$OVERLAP_SECONDS" =~ ^[0-9]+$ ]] && [ "$OVERLAP_SECONDS" -ge 1 ] && [ "$OVERLAP_SECONDS" -le 2 ] && [ "$OVERLAP_SECONDS" -lt "$CHUNK_SECONDS" ] || { printf 'fm-call-mic: overlap must be 1 or 2 seconds and shorter than the chunk\n' >&2; exit 2; }
  [[ "$MAX_CHUNKS" =~ ^[0-9]+$ ]] || { printf 'fm-call-mic: MIC_MAX_CHUNKS must be a non-negative integer\n' >&2; exit 2; }
}

list_audio_devices() { "$FFMPEG_BIN" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; }
device_index_named() { local name=$1; awk -v name="$name" 'index(tolower($0),tolower(name)) {if(match($0,/\[[0-9]+\]/)){print substr($0,RSTART+1,RLENGTH-2);exit}}'; }

resolve_devices() {
  local devices
  devices=$(list_audio_devices)
  mic_device=
  [ -z "$MIC_DEVICE_NAME" ] || mic_device=$(printf '%s\n' "$devices" | device_index_named "$MIC_DEVICE_NAME")
  if [ -z "$mic_device" ]; then
    # The first input that is not a loopback or meeting-app virtual device.
    mic_device=$(printf '%s\n' "$devices" | awk -v loop="$LOOPBACK_DEVICE_PATTERN" '/AVFoundation audio devices:/{a=1;next} a&&/\[[0-9]+\]/&&tolower($0)!~/blackhole|krisp|teams|zoom/&&(loop==""||!index(tolower($0),tolower(loop))){match($0,/\[[0-9]+\]/);print substr($0,RSTART+1,RLENGTH-2);exit}')
  fi
  [ -n "$mic_device" ] || { printf 'fm-call-mic: no physical microphone found\n' >&2; exit 1; }
  loopback_device=
  [ -z "$LOOPBACK_DEVICE_PATTERN" ] || loopback_device=$(printf '%s\n' "$devices" | device_index_named "$LOOPBACK_DEVICE_PATTERN")
  mkdir -p "$STATE_DIR"
  if [ -n "$loopback_device" ]; then
    rm -f "$STATE_DIR/far-side-note"
  else
    printf '%s\n' 'Far side not captured: no loopback input' > "$STATE_DIR/far-side-note"
  fi
}

terminate_and_reap() {
  local pid=$1
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local pid prefix
  trap - EXIT INT TERM
  terminate_and_reap "$child_pid"
  for pid in "${record_pids[@]-}"; do terminate_and_reap "$pid"; done
  for pid in "${worker_pids[@]-}"; do terminate_and_reap "$pid"; done
  for prefix in "${chunk_prefixes[@]-}"; do [ -z "$prefix" ] || rm -f "$prefix"-mic.wav "$prefix"-loop.wav "$prefix"-mic.wav.level "$prefix"-loop.wav.level "$prefix"-mix.wav "$prefix"-mix.txt "$prefix"-mix.json; done
}

on_signal() {
  exit 0
}

start_recording() {
  local seconds=$1 prefix=$2 mic_wav loop_wav
  mic_wav="$prefix-mic.wav"
  loop_wav="$prefix-loop.wav"
  if [ -n "$loopback_device" ]; then
    "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning \
      -f avfoundation -i ":$mic_device" -f avfoundation -i ":$loopback_device" \
      -map 0:a -t "$seconds" -ar 16000 -ac 1 -c:a pcm_s16le -y "$mic_wav" \
      -map 1:a -t "$seconds" -ar 16000 -ac 1 -c:a pcm_s16le -y "$loop_wav" &
  else
    "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -f avfoundation -i ":$mic_device" \
      -t "$seconds" -ar 16000 -ac 1 -c:a pcm_s16le -y "$mic_wav" &
  fi
  started_record_pid=$!
  record_pids+=("$started_record_pid")
}

forget_record_pid() {
  local completed=$1 pid remaining=()
  for pid in "${record_pids[@]-}"; do
    if [ -n "$pid" ] && [ "$pid" != "$completed" ]; then remaining+=("$pid"); fi
  done
  record_pids=("${remaining[@]-}")
}

run_child() {
  "$@" &
  child_pid=$!
  wait "$child_pid"
  child_pid=
}

measure_level() {
  local input=$1 label=$2 level_log mean max
  level_log="$input.level"
  "$FFMPEG_BIN" -nostdin -hide_banner -i "$input" -af volumedetect -f null - > /dev/null 2> "$level_log" &
  child_pid=$!
  wait "$child_pid"
  child_pid=
  mean=$(awk '/mean_volume:/ {value=$(NF-1)} END {print value}' "$level_log")
  max=$(awk '/max_volume:/ {value=$(NF-1)} END {print value}' "$level_log")
  rm -f "$level_log"
  mean=${mean:--inf}
  max=${max:--inf}
  printf 'fm-call-mic: %s level mean=%sdB max=%sdB\n' "$label" "$mean" "$max" >&2
  measured_max=$max
}

gain_for_level() {
  awk -v maximum="$1" 'BEGIN { if (maximum == "-inf" || maximum == "") { print 0; exit } gain=-6-maximum; if (gain>18) gain=18; if (gain< -18) gain=-18; printf "%.1f", gain }'
}

mix_sources() {
  local prefix=$1 mic_wav loop_wav mixed mic_max loop_max mic_gain loop_gain
  mic_wav="$prefix-mic.wav"
  loop_wav="$prefix-loop.wav"
  mixed="$prefix-mix.wav"
  measure_level "$mic_wav" microphone
  mic_max=$measured_max
  mic_gain=$(gain_for_level "$mic_max")
  if [ -f "$loop_wav" ]; then
    measure_level "$loop_wav" loopback
    loop_max=$measured_max
    loop_gain=$(gain_for_level "$loop_max")
    printf 'fm-call-mic: gains microphone=%sdB loopback=%sdB\n' "$mic_gain" "$loop_gain" >&2
    run_child "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -i "$mic_wav" -i "$loop_wav" \
      -filter_complex "[0:a]volume=${mic_gain}dB,alimiter=limit=0.891[mic];[1:a]volume=${loop_gain}dB,alimiter=limit=0.891[loop];[mic][loop]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.891[mix]" \
      -map '[mix]' -ar 16000 -ac 1 -c:a pcm_s16le -y "$mixed"
  else
    printf 'fm-call-mic: gain microphone=%sdB\n' "$mic_gain" >&2
    run_child "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -i "$mic_wav" \
      -af "volume=${mic_gain}dB,alimiter=limit=0.891" -ar 16000 -ac 1 -c:a pcm_s16le -y "$mixed"
  fi
}

transcribe_worker() {
  local prefix=$1 spoken_at=$2 mixed text_file text lines started elapsed model_tmp
  mixed="$prefix-mix.wav"
  text_file="$prefix-mix.txt"
  trap cleanup EXIT
  trap on_signal INT TERM
  chunk_prefixes+=("$prefix")
  mix_sources "$prefix"
  started=$(date +%s)
  run_child "$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$mixed" -l en -np -otxt -oj -of "$prefix-mix" > /dev/null
  elapsed=$(($(date +%s) - started))
  if [ "$WHISPER_MODEL" = "$TURBO_MODEL" ] && [ "$elapsed" -gt 20 ] && [ -f "$BASE_MODEL" ]; then
    mkdir -p "$STATE_DIR"
    model_tmp="$MODEL_STATE.tmp.$$"
    printf '%s\n' "$BASE_MODEL" > "$model_tmp"
    mv "$model_tmp" "$MODEL_STATE"
    printf 'fm-call-mic: turbo took %ss; using base.en for later chunks\n' "$elapsed" >&2
  fi
  if lines=$(speaker_lines "$prefix" "$spoken_at"); then
    [ -n "$lines" ] || return 0
    if [ "${MIC_TRANSCRIBE_STDOUT:-0}" = 1 ]; then printf '%s\n' "$lines"; else printf '%s\n' "$lines" >> "$TRANSCRIPT"; fi
    return 0
  fi
  text=$(tr '\n' ' ' < "$text_file" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
  if [ "${MIC_TRANSCRIBE_STDOUT:-0}" = 1 ]; then
    printf '%s\n' "$text"
  elif [ -n "$text" ]; then
    printf '[%s] unknown speaker: %s\n' "$spoken_at" "$text" >> "$TRANSCRIPT"
  fi
}

# Speaker turns from the source tracks: the local name only for microphone-only speech,
# "others" only for loopback speech, "unknown speaker" otherwise. Fails when labelling is impossible.
speaker_lines() {
  local prefix=$1 spoken_at=$2 args
  [ -x "$PYTHON_BIN" ] && [ -f "$SPEAKER_SPLIT" ] && [ -s "$prefix-mix.json" ] || return 1
  args=(--whisper "$prefix-mix.json" --mic "$prefix-mic.wav" --start "$spoken_at" --local-name "$LOCAL_SPEAKER")
  [ ! -f "$prefix-loop.wav" ] || args+=(--loop "$prefix-loop.wav")
  [ ! -e "$STATE_DIR/shared-room" ] || args+=(--shared-room)
  "$PYTHON_BIN" "$SPEAKER_SPLIT" "${args[@]}"
}

sleep_until() {
  local target=$1 now remaining
  now=$(date +%s)
  remaining=$((target - now))
  if [ "$remaining" -gt 0 ]; then
    sleep "$remaining" &
    child_pid=$!
    wait "$child_pid"
    child_pid=
  fi
}

launch_worker() {
  local prefix=$1 spoken_at=$2
  CALL_COMPANION_TRANSCRIPT="$TRANSCRIPT" CALL_COMPANION_WORK_DIR="$WORK_DIR" CALL_COMPANION_STATE_DIR="$STATE_DIR" \
    FFMPEG_BIN="$FFMPEG_BIN" WHISPER_BIN="$WHISPER_BIN" WHISPER_MODEL="$MODEL_OVERRIDE" \
    "$SCRIPT_PATH" --transcribe "$prefix" "$spoken_at" &
  worker_pids+=("$!")
}

run_test() {
  local seconds=$1 prefix pid
  [[ "$seconds" =~ ^[0-9]+$ ]] && [ "$seconds" -ge 1 ] && [ "$seconds" -le 300 ] || { printf 'fm-call-mic: test duration must be an integer from 1 to 300 seconds\n' >&2; exit 2; }
  prefix="$WORK_DIR/test-$session_id"
  chunk_prefixes+=("$prefix")
  printf 'Recording %s seconds from microphone device %s%s...\n' "$seconds" "$mic_device" "${loopback_device:+ plus loopback device $loopback_device}" >&2
  start_recording "$seconds" "$prefix"
  pid=$started_record_pid
  wait "$pid"
  forget_record_pid "$pid"
  MIC_TRANSCRIBE_STDOUT=1 transcribe_worker "$prefix" "$(date '+%H:%M:%S')"
}

run_loop() {
  local index=1 stride active_prefix active_pid active_started active_spoken next_prefix next_pid next_started next_spoken target pid
  stride=$((CHUNK_SECONDS - OVERLAP_SECONDS))
  touch "$TRANSCRIPT"
  active_prefix="$WORK_DIR/chunk-$session_id-$index"
  chunk_prefixes+=("$active_prefix")
  active_started=$(date +%s)
  active_spoken=$(date '+%H:%M:%S')
  start_recording "$CHUNK_SECONDS" "$active_prefix"
  active_pid=$started_record_pid
  while :; do
    next_pid=
    if [ "$MAX_CHUNKS" -eq 0 ] || [ "$index" -lt "$MAX_CHUNKS" ]; then
      target=$((active_started + stride))
      sleep_until "$target"
      index=$((index + 1))
      next_prefix="$WORK_DIR/chunk-$session_id-$index"
      chunk_prefixes+=("$next_prefix")
      next_started=$(date +%s)
      next_spoken=$(date '+%H:%M:%S')
      start_recording "$CHUNK_SECONDS" "$next_prefix"
      next_pid=$started_record_pid
    fi
    wait "$active_pid"
    forget_record_pid "$active_pid"
    launch_worker "$active_prefix" "$active_spoken"
    [ -n "$next_pid" ] || break
    active_prefix=$next_prefix
    active_pid=$next_pid
    active_started=$next_started
    active_spoken=$next_spoken
  done
  for pid in "${worker_pids[@]-}"; do [ -z "$pid" ] || wait "$pid"; done
  worker_pids=()
}

main() {
  local test_seconds=
  if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = --test ]; then
      test_seconds=$2
    elif [ "$#" -eq 3 ] && [ "$1" = --transcribe ]; then
      require_tools
      mkdir -p "$WORK_DIR" "$(dirname "$TRANSCRIPT")"
      transcribe_worker "$2" "$3"
      exit 0
    else
      usage
      exit 2
    fi
  fi
  [ -n "$test_seconds" ] || rm -f "$MODEL_STATE"
  require_tools
  validate_timing
  mkdir -p "$WORK_DIR" "$(dirname "$TRANSCRIPT")"
  resolve_devices
  trap cleanup EXIT
  trap on_signal INT TERM
  if [ -n "$test_seconds" ]; then run_test "$test_seconds"; else run_loop; fi
}

main "$@"

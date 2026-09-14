#!/usr/bin/env bash
# Transcribe one audio file with Deepgram (push-to-talk desk floater path).
#
# Usage:
#   fm-deepgram-stt.sh [--json] <audio-file>
#   fm-deepgram-stt.sh --help
#
# Reads DEEPGRAM_API_KEY from the environment or the home's gitignored .env.
# Never logs the key. Default model: nova-2 (override with DEEPGRAM_STT_MODEL).
#
# Prints the transcript text on stdout (or the raw JSON with --json).
#
# Exit:
#   0  transcript printed (may be empty if Deepgram heard silence)
#   1  request failure
#   2  missing key, missing file, or bad usage
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

CURL_BIN="${FM_DEEPGRAM_CURL:-curl}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-deepgram-stt: %s\n' "$*" >&2
}

refuse() {
  note "$*"
  exit 2
}

die() {
  note "$*"
  exit 1
}

extract_transcript() {  # <json-file>
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
try:
    text = data["results"]["channels"][0]["alternatives"][0].get("transcript", "")
except (KeyError, IndexError, TypeError) as exc:
    print(f"fm-deepgram-stt: unexpected JSON shape: {exc}", file=sys.stderr)
    raise SystemExit(1)
sys.stdout.write(text)
if text and not text.endswith("\n"):
    sys.stdout.write("\n")
PY
}

main() {
  local json_out=false audio='' key model http tmp ctype auth_cfg
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) json_out=true; shift ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-deepgram-stt.sh [--json] <audio-file>"
  audio=$1
  [ -f "$audio" ] || refuse "audio file not found: $audio"

  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || refuse "DEEPGRAM_API_KEY is not set (env or gitignored .env)"
  model=$(fm_deepgram_stt_model)

  case "$audio" in
    *.wav|*.WAV) ctype=audio/wav ;;
    *.mp3|*.MP3) ctype=audio/mpeg ;;
    *.m4a|*.M4A) ctype=audio/mp4 ;;
    *.webm|*.WEBM) ctype=audio/webm ;;
    *.ogg|*.OGG) ctype=audio/ogg ;;
    *) ctype=application/octet-stream ;;
  esac

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deepgram-stt.XXXXXX") || die "cannot create a temporary file"
  auth_cfg=$(fm_deepgram_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --config "$auth_cfg" \
    --header "Content-Type: ${ctype}" \
    --data-binary @"$audio" \
    --url "https://api.deepgram.com/v1/listen?model=${model}&smart_format=true") || {
    rm -f "$tmp"
    die "curl failed talking to Deepgram"
  }
  rm -f "$auth_cfg"

  if [ "$http" != "200" ]; then
    note "Deepgram listen failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ "$json_out" = true ]; then
    cat "$tmp"
    rm -f "$tmp"
    exit 0
  fi

  if ! extract_transcript "$tmp"; then
    rm -f "$tmp"
    die "could not parse Deepgram transcript JSON"
  fi
  rm -f "$tmp"
  exit 0
}

main "$@"

#!/usr/bin/env bash
# Synthesize one line with Deepgram Aura and play it on this Mac.
#
# Usage:
#   fm-deepgram-tts.sh [--dry-run] [--to <audio-file>] <text>
#   fm-deepgram-tts.sh --help
#
# Reads DEEPGRAM_API_KEY from the environment or the home's gitignored .env
# (see bin/fm-deepgram-lib.sh). Never logs the key.
#
# Default model: aura-2-thalia-en (override with DEEPGRAM_TTS_MODEL).
# Output encoding: mp3. Played with /usr/bin/afplay unless --to writes the
# bytes and skips playback, or FM_DEEPGRAM_AFPLAY names another player.
#
# Exit:
#   0  synthesized (and played, unless --to / --dry-run)
#   1  request or playback failure
#   2  missing key or empty text
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

AFPLAY_BIN="${FM_DEEPGRAM_AFPLAY:-/usr/bin/afplay}"
CURL_BIN="${FM_DEEPGRAM_CURL:-curl}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-deepgram-tts: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

main() {
  local dry_run=false out_file='' text='' key model tmp http body auth_cfg
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) dry_run=true; shift ;;
      --to)
        [ "$#" -ge 2 ] || refuse "--to needs a path"
        out_file=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || refuse "nothing to speak"
  text=$*
  case "$text" in
    *[![:space:]]*) ;;
    *) refuse "nothing to speak" ;;
  esac

  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || refuse "DEEPGRAM_API_KEY is not set (env or gitignored .env)"

  model=$(fm_deepgram_tts_model)
  if [ "$dry_run" = true ]; then
    printf 'deepgram-tts model=%s chars=%s\n' "$model" "${#text}"
    exit 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deepgram-tts.XXXXXX") || die "cannot create a temporary file"
  # Rename to .mp3 so afplay sniffs correctly on some macOS builds.
  mv "$tmp" "$tmp.mp3"
  tmp=$tmp.mp3
  body=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text") || {
    rm -f "$tmp"
    die "cannot encode request body"
  }

  auth_cfg=$(fm_deepgram_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --config "$auth_cfg" \
    --header "Content-Type: application/json" \
    --data "$body" \
    --url "https://api.deepgram.com/v1/speak?model=${model}&encoding=mp3") || {
    rm -f "$tmp"
    die "curl failed talking to Deepgram"
  }
  rm -f "$auth_cfg"

  if [ "$http" != "200" ]; then
    note "Deepgram speak failed HTTP $http"
    # Body may be an error JSON; never echo headers that could carry the key.
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ -n "$out_file" ]; then
    mv "$tmp" "$out_file" || die "cannot write $out_file"
    printf '%s\n' "$out_file"
    exit 0
  fi

  if [ ! -x "$AFPLAY_BIN" ]; then
    rm -f "$tmp"
    die "no audio player at $AFPLAY_BIN (set FM_DEEPGRAM_AFPLAY)"
  fi
  "$AFPLAY_BIN" "$tmp" || {
    rm -f "$tmp"
    die "afplay failed"
  }
  rm -f "$tmp"
  exit 0
}

main "$@"

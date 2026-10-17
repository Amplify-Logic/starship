#!/usr/bin/env bash
# Play one audio file through the Windows speakers from inside WSL 2: the
# afplay stand-in bin/fm-speak.sh uses when the Windows desk floater is
# installed for this home.
#
# Usage:
#   fm-desk-play-windows.sh [-v <gain>] <audio-file>
#   fm-desk-play-windows.sh --help
#
# It takes afplay's arguments as bin/fm-speak.sh passes them: -v is the
# playback volume, where 1 is the Windows volume. Windows playback cannot go
# louder than the Windows volume, so a gain above 1 plays at 1.
#
# The audio is copied into the floater's own folder on the Windows side (the
# install record state/desk-floater-windows/install names it) and played by
# StarshipFloater.exe --play, which returns when the line ends. This script
# waits for it the way afplay is waited for, so bin/fm-speak.sh's serial
# playback, its bound and its stop all keep working: a TERM or INT, which is
# how --stop cuts a line short, runs StarshipFloater.exe --stop-playback and
# ends the line at once.
#
# A tmux server that outlives the terminal it started from keeps a stale
# WSL_INTEROP socket, and Windows programs then fail to start from inside it;
# a stale socket is replaced with the newest live one in /run/WSL.
#
# Environment: FM_HOME selects the home whose install record is read
# (default: this code root).
#
# Exit: 0 played (or cut short by a stop), 1 cannot play, 2 bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
RECORD="$FM_HOME/state/desk-floater-windows/install"

note() {
  printf 'fm-desk-play-windows: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

gain=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    -v)
      [ "$#" -ge 2 ] || refuse "-v needs a volume"
      gain=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) refuse "unexpected option: $1" ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || refuse "usage: fm-desk-play-windows.sh [-v <gain>] <audio-file>"
audio=$1
[ -s "$audio" ] || die "no audio to play: $audio"

# MCI's volume runs from 0 to 1000, where 1000 is the Windows volume.
volume=1000
if [ -n "$gain" ]; then
  volume=$(awk -v g="$gain" 'BEGIN {
    if (g !~ /^[0-9]*\.?[0-9]+$/) exit 1
    v = int(g * 1000 + 0.5); if (v > 1000) v = 1000; print v }') \
    || refuse "-v needs a number: $gain"
fi

win_dir='' lin_dir=''
if [ -f "$RECORD" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      windows_dir) win_dir=$value ;;
      linux_dir) lin_dir=$value ;;
    esac
  done < "$RECORD"
fi
[ -n "$win_dir" ] && [ -n "$lin_dir" ] && [ -f "$lin_dir/StarshipFloater.exe" ] \
  || die "the Windows floater is not installed for this home; run bin/fm-desk-floater-windows.sh install"
exe="$lin_dir/StarshipFloater.exe"

if [ -n "${WSL_INTEROP:-}" ] && [ ! -S "$WSL_INTEROP" ]; then
  newest=''
  for sock in /run/WSL/*_interop; do
    [ -S "$sock" ] || continue
    [ -n "$newest" ] && [ ! "$sock" -nt "$newest" ] || newest=$sock
  done
  [ -z "$newest" ] || export WSL_INTEROP=$newest
fi

ext=${audio##*.}
case "$ext" in
  mp3|wav|aiff|aif|m4a) ;;
  *) ext=mp3 ;;
esac
mkdir -p "$lin_dir/play" || die "cannot create $lin_dir/play"
name="$(date +%s)-$$.$ext"
copy="$lin_dir/play/$name"
cp "$audio" "$copy" || die "cannot copy the audio to $lin_dir/play"

player=''
finish() {
  if [ -n "$player" ]; then
    "$exe" --stop-playback >/dev/null 2>&1 || true
    kill "$player" 2>/dev/null || true
    wait "$player" 2>/dev/null || true
  fi
  rm -f "$copy"
  exit 0
}
trap finish TERM INT

"$exe" --play "$win_dir\\play\\$name" --volume "$volume" &
player=$!
status=0
wait "$player" || status=$?
player=''
rm -f "$copy"
[ "$status" = 0 ] || die "Windows playback failed (exit $status)"

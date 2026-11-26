#!/usr/bin/env bash
# tests/fm-web-front-chrome-live-e2e.test.sh - live guard proving the web
# page's "I am in front" beats keep reaching bin/fm-web.py in the real Chrome.
#
# Why this file exists: the desk floater keeps its reply bubble quiet while a
# Starship page is in front, from a marker the server touches on every beat.
# The page used to send each beat with fetch's keepalive and never read the
# answer. Chrome holds such a request against a fixed allowance per page
# until its answer is read and refuses every later one once that is spent, so
# after a couple of hours in front every beat failed quietly, the marker went
# stale and the bubble came back over the page. That rule is Chrome's, not
# ours, so the portable regression in tests/fm-web.test.sh can only model it;
# this guard proves both that the rule still holds in the installed Chrome and
# that the page's own beat (FMFront, served as /front.js) is untouched by it.
#
# It drives a headless Chrome through chrome-devtools-axi in a session of its
# own and never reaches the owner's browser: ambient connect settings are
# stripped, and a Chrome for Testing build is preferred when one is installed.
# Standard CI has no chrome-devtools-axi, so this reports a capability skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_WEB_FRONT_CHROME_LIVE chrome-devtools-axi python3 curl

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL CHROME_DEVTOOLS_AXI_WS_HEADERS \
  CHROME_DEVTOOLS_AXI_HEADED CHROME_DEVTOOLS_AXI_USER_DATA_DIR CHROME_DEVTOOLS_AXI_PORT
export CHROME_DEVTOOLS_AXI_SESSION="fm-web-front-live-$$"
if [ -z "${CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH:-}" ]; then
  for candidate in "$HOME"/.cache/puppeteer/chrome/*/chrome-mac*/"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
    "$HOME"/.cache/puppeteer/chrome/*/chrome-linux*/chrome; do
    [ -x "$candidate" ] && export CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH="$candidate"
  done
fi

LAB='' SERVER=''
cleanup() {
  chrome-devtools-axi stop >/dev/null 2>&1 || true
  [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
  [ -z "$LAB" ] || rm -rf "$LAB"
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

note "chrome-devtools-axi $(chrome-devtools-axi --version 2>/dev/null | tr -d '[:space:]'), Chrome ${CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH:-installed}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-web-front-live.XXXXXX") || fail "cannot create the guard lab"
HOME_DIR=$LAB/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
HOME="$HOME_DIR" python3 "$ROOT/bin/fm-web.py" serve --home "$HOME_DIR" --root "$ROOT" --port 0 >"$LAB/serve.log" 2>&1 &
SERVER=$!
PORT=''
for _ in $(seq 1 50); do
  PORT=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$LAB/serve.log")
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || fail "the web server did not start: $(cat "$LAB/serve.log")"
TOKEN=$(head -n 1 "$HOME_DIR/state/web/token")

chrome-devtools-axi open "http://127.0.0.1:$PORT/?token=$TOKEN" >"$LAB/open.out" 2>&1 \
  || fail "Chrome did not open the page: $(cat "$LAB/open.out")"

# Many more words than the allowance holds: about 1,400 beats of the old
# shape spend it, a couple of hours in front.
BURST=2500

# eval <label> <js>: runs <js> in the page and prints its result line.
run_js() {
  local out
  out=$(chrome-devtools-axi eval "$2" 2>&1) || fail "$1: the page did not run it: $out"
  printf '%s\n' "$out" | sed -n 's/^result: //p' | tr -d '\\"'
}

ours=$(run_js "the page's own beat" "(async()=>{const f=FMFront.start({doc:document,win:window,
  fetch:window.fetch.bind(window),csrf:document.body.dataset.csrf,beatMs:3600000,page:'liveguardours',every:()=>{}});
  let ok=0;for(let i=0;i<$BURST;i++)if(await f.say(true,true,false))ok++;return 'ok='+ok;})()")
assert_equals "ok=$BURST" "$ours" "every beat the page sends reaches its server"
[ -f "$HOME_DIR/state/desk-voice/web-front" ] || fail "the page in front must leave the floater's marker"
pass "the page's own beat reaches its server $BURST times running in Chrome"

# The old shape, in a fresh page: keepalive, answer never read.
chrome-devtools-axi reload >/dev/null 2>&1 || fail "Chrome did not reload the page"
old=$(run_js "the old shape" "(async()=>{const C=document.body.dataset.csrf;let ok=0,refused=0;
  for(let i=0;i<$BURST;i++){try{await fetch('/api/front',{method:'POST',credentials:'same-origin',keepalive:true,
  headers:{'Content-Type':'application/json','X-FM-CSRF':C},body:JSON.stringify({page:'liveguardold'+i,front:false})});ok++;}
  catch(e){refused++;}}return 'ok='+ok+' refused='+refused;})()")
case "$old" in
  ok=*' refused='[1-9]*) ;;
  *) fail "Chrome no longer refuses unread keepalive requests ($old); the reason for FMFront's shape is gone, so revisit it" ;;
esac
pass "Chrome still refuses keepalive requests whose answers go unread ($old), the rule FMFront avoids"

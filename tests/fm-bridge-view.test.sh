#!/usr/bin/env bash
# Behavior tests for the phone bridge view: loopback bind, Tailscale Funnel
# refusal, Host/Origin checks including Safari form POSTs that omit Origin
# or send Origin: null, session cookie isolation from port 8765, read-only
# snapshot subprocess, away-mode passive refresh, auth headers, authenticated
# photo drops into the quarantined inbox, multi-file Origin-null uploads,
# hold-to-speak mailbox forwarding with the relay token kept server-side,
# captain-facing glance titles, pinned links, needs-you selection, waiting project chips, keep-alive body drain after early error
# returns, the What I remember section's privacy guard, and the Action Deck page over bin/fm-deck.sh --json.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge-view)
HOST_NAME=bridge.test.example
ORIGIN="https://$HOST_NAME"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

BRIDGE_PIDS=()
fm_bridge_cleanup() {
  local pid
  for pid in "${BRIDGE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap fm_bridge_cleanup EXIT

make_fakebin() {  # <dir> [off|on|serve|legacy-serve]
  local fb funnel=${2:-off}
  fb=$(fm_fakebin "$1")
  cat > "$fb/tailscale" <<SH
#!/usr/bin/env bash
if [ "\$*" = "funnel status --json" ]; then
  if [ "$funnel" = on ]; then
    printf '%s\\n' '{"AllowFunnel":{"funnel.example.ts.net:443":true}}'
    exit 0
  fi
  if [ "$funnel" = serve ]; then
    printf '%s\\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"bridge.test.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8766"}}}}}'
    exit 0
  fi
  if [ "$funnel" = legacy-serve ]; then
    printf 'unknown flag: --json\n' >&2
    exit 1
  fi
  printf '{}\\n'
  exit 0
fi
if [ "\$*" = "funnel status" ]; then
  if [ "$funnel" = on ]; then
    printf 'https://funnel.example.ts.net\\n|-- proxy http://127.0.0.1:8766 (Funnel)\\n'
    exit 0
  fi
  if [ "$funnel" = serve ]; then
    printf 'https://bridge.test.example (tailnet only)\\n|-- / proxy http://127.0.0.1:8766\\n'
    exit 0
  fi
  if [ "$funnel" = legacy-serve ]; then
    printf 'https://bridge.test.example\n|-- / proxy http://127.0.0.1:8766\n'
    exit 0
  fi
  printf 'No serve config\\n'
  exit 0
fi
if [ "\$*" = "serve status" ]; then
  if [ "$funnel" = serve ]; then
    printf 'https://bridge.test.example (tailnet only)\\n|-- / proxy http://127.0.0.1:8766\\n'
    exit 0
  fi
  printf 'No serve config\\n'
  exit 0
fi
exit 0
SH
  cat > "$fb/launchctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/tailscale" "$fb/launchctl"
  printf '%s\n' "$fb"
}

make_broken_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tailscale" <<'SH'
#!/usr/bin/env bash
printf 'tailscaled unavailable\n' >&2
exit 1
SH
  chmod +x "$fb/tailscale"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - VoiceLoop tap trigger (repo: firstmate) (kind: ship) (since 2026-08-19)

## Queued
- [ ] cloud-hold - Always-on cloud, host+budget (repo: firstmate) (kind: ship)
- [ ] captain-q - Add Qwen to the fleet? (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] done-a - Spoken updates on the glasses https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-08-18)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  mkdir -p "$home/projects/ship-wt"
  printf 'working: building the page\n' > "$home/state/ship-task.status"
  printf '%s\n' "$home"
}

fingerprint() {  # <home>
  (cd "$1" && find data state -type f -print | LC_ALL=C sort | xargs cksum)
}

wait_listening() {  # <log>
  local log=$1 n=0 line
  while [ "$n" -lt 50 ]; do
    line=$(grep -E '^listening on 127.0.0.1:[0-9]+$' "$log" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s\n' "${line##*:}"
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  fail "bridge server did not print a loopback listener: $(cat "$log" 2>/dev/null)"
}

# HOME is pinned to the fixture home as well as PATH: resolve_child_path admits
# $HOME/.local/bin and $HOME/.nvm/versions/node/*/bin ahead of the parent PATH,
# so on a machine where the developer has a real tasks-axi installed under nvm
# that binary would shadow this fixture's stub and the child would read the
# machine's own backlog instead of the one the test wrote.
#
# NVM_BIN is cleared for the same reason, and pinning HOME alone is not enough:
# when the pinned home has no .nvm tree at all, _nvm_bin_from_home falls back to
# whatever NVM_BIN the developer's shell exports, which puts the machine's real
# nvm bin - real tasks-axi included - at the FRONT of the child PATH again. An
# nvm-loaded shell would then read the developer's own backlog through the
# fixture's server.
start_bridge() {  # <home> <fakebin>
  local home=$1 fakebin=$2 log
  log=$home/bridge-serve.log
  : > "$log"
  FM_BRIDGE_VIEW_TEST=1 FM_BRIDGE_VIEW_LAUNCHCTL="$fakebin/launchctl" \
    FM_BRIDGE_VIEW_MAILBOX_PORT="${FM_BRIDGE_VIEW_MAILBOX_PORT:-}" \
    PATH="$fakebin:$PATH" HOME="$home" NVM_BIN='' FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIDGE" serve --host "$HOST_NAME" --port 0 >"$log" 2>&1 &
  BRIDGE_PIDS+=("$!")
  wait_listening "$log"
}

init_passcode() {  # <home>
  local path
  path=$(FM_HOME="$1" "$BRIDGE" init-passcode)
  [ -f "$path" ] || fail "init-passcode did not write a plaintext envelope: $path"
  printf '%s\n' "$(cat "$path")"
}

curl_bridge() {  # <port> <path> <headers-file> <body-file> [curl args...]
  local port=$1 path=$2 hdr=$3 body=$4
  shift 4
  curl -sS --max-time 30 \
    --header "Host: $HOST_NAME" \
    -D "$hdr" -o "$body" \
    "$@" \
    "http://127.0.0.1:${port}${path}"
}

bridge_cookie() {  # <home> <port>
  local home=$1 port=$2 hdr body cookie pass
  pass=$(cat "$home/data/bridge-view-passcode.txt")
  hdr=$home/login-cookie.hdr
  body=$home/login-cookie.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --data "passcode=$pass"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2)); exit}' "$hdr")
  [ -n "$cookie" ] || fail "login did not set a session cookie"
  printf '%s\n' "${cookie%%;*}"
}

tiny_jpeg() {  # <path>
  # Minimal JPEG SOI + marker so magic-byte sniffing accepts it.
  printf '\xff\xd8\xff\xd9' > "$1"
}

tiny_m4a() {  # <path>
  # Minimal ISO BMFF ftyp/M4A so magic-byte sniffing treats it as mp4 audio.
  printf '\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00mp42isom' > "$1"
}

test_bind_is_loopback_constant() {
  grep -q '^LOOPBACK = "127.0.0.1"$' "$ROOT/bin/fm-bridge-view.py" \
    || fail "bridge server lost the literal loopback bind constant"
  grep -Eq '0\.0\.0\.0' "$ROOT/bin/fm-bridge-view.py" \
    && fail "bridge server mentions 0.0.0.0"
  pass "bridge bind address is the literal loopback constant"
}

test_funnel_on_refuses_to_serve() {
  local home fakebin log rc=0
  home=$(make_home funnel-on)
  fakebin=$(make_fakebin "$home" on)
  init_passcode "$home" >/dev/null
  log=$home/funnel.log
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BRIDGE_VIEW_TEST=1 \
    "$BRIDGE" serve --host "$HOST_NAME" --port 0 >"$log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "serve must refuse when Funnel is on: $(cat "$log")"
  assert_contains "$(cat "$log")" "Funnel" "funnel refusal did not name Funnel"
  pass "serve refuses to start while Tailscale Funnel is on"
}

test_funnel_off_serve_starts() {
  local home fakebin port hdr body rc=0
  home=$(make_home funnel-off-serve)
  fakebin=$(make_fakebin "$home" serve)
  init_passcode "$home" >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BRIDGE_VIEW_TEST=1 \
    "$BRIDGE" check-funnel >/dev/null || fail "check-funnel must pass for tailnet-only Serve"
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/off.hdr; body=$home/off.body
  curl_bridge "$port" / "$hdr" "$body" || rc=$?
  expect_code 0 "$rc" "Funnel-off Serve should answer on loopback"
  assert_contains "$(head -n 1 "$hdr")" "200" "Funnel-off Serve must serve the login page"
  pass "serve starts when Funnel is off and Serve HTTPS is claimed"
}

test_funnel_off_legacy_serve_output_starts() {
  local home fakebin
  home=$(make_home funnel-off-legacy-serve)
  fakebin=$(make_fakebin "$home" legacy-serve)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BRIDGE_VIEW_TEST=1 \
    "$BRIDGE" check-funnel >/dev/null || fail "legacy Serve HTTPS output must not be classified as Funnel"
  pass "Serve HTTPS without an explicit Funnel marker remains Funnel off"
}

test_unverifiable_funnel_refuses_to_serve() {
  local home fakebin log rc=0
  home=$(make_home funnel-unverifiable)
  fakebin=$(make_broken_fakebin "$home")
  init_passcode "$home" >/dev/null
  log=$home/funnel-unverifiable.log
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BRIDGE_VIEW_TEST=1 \
    "$BRIDGE" serve --host "$HOST_NAME" --port 0 >"$log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "serve must refuse when Funnel state is unverifiable"
  assert_contains "$(cat "$log")" "could not verify Funnel is off" \
    "unverifiable Funnel refusal was not explicit"
  pass "serve fails closed when Funnel status is unavailable"
}

test_lan_and_unauthorized_hosts_are_rejected() {
  local home fakebin port hdr body rc=0
  home=$(make_home hosts)
  fakebin=$(make_fakebin "$home")
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/lan.hdr; body=$home/lan.body
  curl -sS --max-time 8 -D "$hdr" -o "$body" \
    --header "Host: 192.168.1.10" \
    "http://127.0.0.1:${port}/" || rc=$?
  expect_code 0 "$rc" "LAN Host request should complete"
  assert_contains "$(head -n 1 "$hdr")" "403" "LAN Host must be forbidden"
  hdr=$home/ip.hdr; body=$home/ip.body
  curl -sS --max-time 8 -D "$hdr" -o "$body" \
    "http://127.0.0.1:${port}/" || true
  assert_contains "$(head -n 1 "$hdr")" "403" "default loopback Host must be forbidden"
  pass "LAN and unauthorized Host headers are rejected"
}

test_auth_cookie_headers_and_isolation() {
  local home fakebin port pass hdr body cookie token sessions jar sink_pid sink_port n
  home=$(make_home auth)
  fakebin=$(make_fakebin "$home")
  pass=$(init_passcode "$home")
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/bad.hdr; body=$home/bad.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --data "passcode=wrong-passcode"
  assert_contains "$(head -n 1 "$hdr")" "401" "bad passcode must be rejected"
  hdr=$home/origin.hdr; body=$home/origin.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: https://evil.example" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "403" "wrong Origin must be rejected"
  hdr=$home/ok.hdr; body=$home/ok.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "303" "good passcode must redirect"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2))}' "$hdr")
  assert_contains "$cookie" "HttpOnly" "session cookie must be HttpOnly"
  assert_contains "$cookie" "Secure" "session cookie must be Secure"
  assert_contains "$cookie" "SameSite=Strict" "session cookie must be SameSite=Strict"
  assert_contains "$cookie" "Path=/" "session cookie must stay on the bridge path"
  case "$cookie" in
    *[Dd]omain=*) fail "session cookie must be host-only, got: $cookie" ;;
  esac
  hdr=$home/obs.hdr; body=$home/obs.body
  curl_bridge "$port" /api/observation "$hdr" "$body" \
    --header "Cookie: ${cookie%%;*}"
  assert_contains "$(head -n 1 "$hdr")" "200" "authed observation must succeed"
  assert_contains "$(cat "$hdr")" "Cache-Control: no-store" "observation must not be stored"
  assert_contains "$(cat "$hdr")" "Referrer-Policy: no-referrer" "observation must set Referrer-Policy"
  assert_contains "$(cat "$hdr")" "Content-Security-Policy:" "observation must set CSP"
  printf '%s' "$(cat "$body")" | jq -e '.needs_you and .under_way and .just_finished and .waiting' >/dev/null \
    || fail "observation JSON missing buckets: $(cat "$body")"
  assert_not_contains "$(cat "$body")" "ship-task" "observation must not leak task ids"
  hdr=$home/page.hdr; body=$home/page.body
  curl_bridge "$port" / "$hdr" "$body" --header "Cookie: ${cookie%%;*}"
  assert_contains "$(cat "$body")" "Summary only. Do not approve from this page." \
    "glance page missing the summary-only warning"
  assert_contains "$(cat "$body")" "Send photos" "glance page missing the photo drop"
  assert_contains "$(cat "$body")" "multiple" "photo input must accept several files"
  assert_contains "$(cat "$body")" "Hold to speak" "glance page missing hold-to-speak"
  assert_contains "$(cat "$body")" "<h2>Waiting</h2>" \
    "glance page missing the waiting heading"
  assert_contains "$(cat "$body")" 'class="wait-chip"' "waiting chips must be in the page script"
  assert_contains "$(cat "$body")" "more waiting on you - show all" \
    "needs you must offer a show-all remainder"
  python3 - "$body" <<'PY' || fail "captain glance sections are out of order"
import pathlib
import sys

page = pathlib.Path(sys.argv[1]).read_text()
markers = [
    '<h2>Talk</h2>',
    '<h2>Send photos</h2>',
    '<h2>Needs you</h2>',
    '<h2>Under way</h2>',
    '<h2>Waiting</h2>',
    '<h2>Just finished</h2>',
    '<h2>Routing</h2>',
    '<h2>What I remember</h2>',
]
positions = [page.index(marker) for marker in markers]
if positions != sorted(positions):
    raise SystemExit(1)
PY
  assert_not_contains "$(cat "$body")" "waiting-summary" "waiting must not hide behind a collapsed fold"
  assert_not_contains "$(cat "$body")" "GLASSES_RELAY_TOKEN" "page must not mention the relay token"
  assert_not_contains "$(cat "$body")" "relay-token" "page must not mention the relay token path"
  assert_not_contains "$(cat "$body")" "Bearer " "page must not ship a bearer token"
  assert_contains "$(cat "$body")" 'accept="image/jpeg,image/png,image/webp,image/heic,image/heif,image/*"' \
    "photo input must keep the image accept list"
  assert_not_contains "$(cat "$body")" "capture=" \
    "photo input must omit capture so iOS offers the camera roll"
  assert_contains "$(cat "$body")" 'action="/upload"' "photo form must post to /upload"
  assert_not_contains "$(cat "$body")" "http-equiv=\"refresh\"" "page must not use meta-refresh"
  jar=$home/cookies.txt
  curl -sS --max-time 8 --resolve "$HOST_NAME:$port:127.0.0.1" \
    --cookie-jar "$jar" --header "Origin: $ORIGIN" --data "passcode=$pass" \
    -o /dev/null "http://$HOST_NAME:$port/login"
  python3 - "$home/port-8765.headers" <<'PY' &
import pathlib, socket, sys
out = pathlib.Path(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
(out.parent / "port-8765.port").write_text(str(sock.getsockname()[1]))
sock.listen(1)
conn, _ = sock.accept()
conn.settimeout(2)
data = conn.recv(8192)
out.write_bytes(data)
conn.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
conn.close()
sock.close()
PY
  sink_pid=$!
  BRIDGE_PIDS+=("$sink_pid")
  n=0
  while [ "$n" -lt 30 ] && [ ! -f "$home/port-8765.port" ]; do
    sleep 0.1
    n=$((n + 1))
  done
  sink_port=$(cat "$home/port-8765.port")
  curl -sS --max-time 8 --noproxy "$HOST_NAME" \
    --connect-to "$HOST_NAME:8765:127.0.0.1:$sink_port" \
    --cookie "$jar" -o /dev/null "http://$HOST_NAME:8765/"
  wait "$sink_pid"
  assert_not_contains "$(cat "$home/port-8765.headers")" "Cookie:" \
    "Secure bridge cookie was sent to the HTTP service on port 8765"
  token=${cookie%%;*}
  token=${token#*=}
  sessions=$home/bridge/sessions.json
  python3 - "$sessions" "$token" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["sessions"][sys.argv[2]]["expires"] = 0
path.write_text(json.dumps(data))
PY
  hdr=$home/expired.hdr; body=$home/expired.body
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: ${cookie%%;*}"
  assert_contains "$(head -n 1 "$hdr")" "401" "expired session must be rejected"
  hdr=$home/revoked.hdr; body=$home/revoked.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" --data "passcode=$pass"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2)); exit}' "$hdr")
  hdr=$home/revoked.hdr; body=$home/revoked.body
  FM_HOME="$home" "$BRIDGE" revoke-sessions >/dev/null
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: ${cookie%%;*}"
  assert_contains "$(head -n 1 "$hdr")" "401" "revoked session must be rejected"
  pass "passcode login, security headers, host-only cookie, and revoke all work"
}

test_safari_login_without_origin_and_keepalive_body_drain() {
  local home fakebin port pass hdr body cookie output
  home=$(make_home safari-login)
  fakebin=$(make_fakebin "$home")
  pass=$(init_passcode "$home")
  port=$(start_bridge "$home" "$fakebin")

  hdr=$home/safari.hdr; body=$home/safari.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Sec-Fetch-Site: same-origin" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "303" \
    "Safari same-origin login without Origin must succeed"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2)); exit}' "$hdr")
  [ -n "$cookie" ] || fail "Safari-shaped login did not set a session cookie"

  hdr=$home/safari-none.hdr; body=$home/safari-none.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Sec-Fetch-Site: none" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "303" \
    "absent Origin with Sec-Fetch-Site none must succeed"

  hdr=$home/safari-referer.hdr; body=$home/safari-referer.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Referer: $ORIGIN/" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "303" \
    "absent Origin with https Referer to the expected host must succeed"

  hdr=$home/no-proof.hdr; body=$home/no-proof.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "403" \
    "absent Origin without same-origin proof must be rejected"

  hdr=$home/http-referer.hdr; body=$home/http-referer.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Referer: http://$HOST_NAME/" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "403" \
    "absent Origin with http Referer must be rejected"

  hdr=$home/wrong-origin.hdr; body=$home/wrong-origin.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: https://evil.example" \
    --header "Sec-Fetch-Site: same-origin" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "403" \
    "present but wrong Origin must be rejected even with Sec-Fetch-Site"

  hdr=$home/null-origin.hdr; body=$home/null-origin.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: null" \
    --header "Sec-Fetch-Site: same-origin" \
    --header "Sec-Fetch-Mode: navigate" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "303" \
    "Safari Origin null with same-origin fetch must succeed"

  hdr=$home/null-origin-noproof.hdr; body=$home/null-origin-noproof.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: null" \
    --data "passcode=$pass"
  assert_contains "$(head -n 1 "$hdr")" "403" \
    "Origin null without same-origin proof must be rejected"

  output=$(python3 - "$HOST_NAME" "$port" "$pass" <<'PY'
import socket
import sys
import threading
import time

host, port, password = sys.argv[1], int(sys.argv[2]), sys.argv[3]
body = ("passcode=" + password).encode("utf-8")


def recv_http(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    if b"\r\n\r\n" not in data:
        raise SystemExit("incomplete HTTP response: %r" % (data[:200],))
    header, rest = data.split(b"\r\n\r\n", 1)
    length = 0
    for line in header.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    while len(rest) < length:
        chunk = sock.recv(4096)
        if not chunk:
            break
        rest += chunk
    return header, rest[:length]


sock = socket.create_connection(("127.0.0.1", port), timeout=8)
try:
    sock.sendall(
        (
            "GET / HTTP/1.1\r\n"
            "Host: %s\r\n"
            "Connection: keep-alive\r\n"
            "\r\n" % host
        ).encode("ascii")
    )
    header, _ = recv_http(sock)
    status = header.split(b"\r\n", 1)[0]
    if b" 200 " not in status:
        raise SystemExit("expected initial 200, got %r" % (status,))
    sock.sendall(
        (
            "POST /login HTTP/1.1\r\n"
            "Host: %s\r\n"
            "Content-Type: application/x-www-form-urlencoded\r\n"
            "Content-Length: %d\r\n"
            "Connection: keep-alive\r\n"
            "\r\n" % (host, len(body))
        ).encode("ascii")
        + body
    )
    header, _ = recv_http(sock)
    status = header.split(b"\r\n", 1)[0]
    if b" 403 " not in status:
        raise SystemExit("expected 403 on unproven login, got %r" % (status,))
    sock.sendall(
        (
            "GET / HTTP/1.1\r\n"
            "Host: %s\r\n"
            "Connection: close\r\n"
            "\r\n" % host
        ).encode("ascii")
    )
    header, _ = recv_http(sock)
    status = header.split(b"\r\n", 1)[0]
    if b" 400 " in status or b" 501 " in status:
        raise SystemExit("keep-alive follow-up parsed as garbage: %r" % (status,))
    if b" 200 " not in status:
        raise SystemExit("expected 200 on drained follow-up GET, got %r" % (status,))
finally:
    sock.close()

sock = socket.create_connection(("127.0.0.1", port), timeout=4)
try:
    sock.sendall(
        (
            "POST /login HTTP/1.1\r\n"
            "Host: %s\r\n"
            "Content-Type: application/x-www-form-urlencoded\r\n"
            "Content-Length: 4096\r\n"
            "Connection: keep-alive\r\n"
            "\r\n"
            "passcode=x" % host
        ).encode("ascii")
    )
    started = time.monotonic()

    def drip_body():
        try:
            for _ in range(12):
                time.sleep(0.4)
                sock.sendall(b"x")
        except OSError:
            pass

    threading.Thread(target=drip_body, daemon=True).start()
    header, _ = recv_http(sock)
    elapsed = time.monotonic() - started
    status = header.split(b"\r\n", 1)[0]
    if b" 403 " not in status:
        raise SystemExit("expected 403 on incomplete unproven login, got %r" % (status,))
    if b"connection: close" not in header.lower():
        raise SystemExit("incomplete body response did not close the connection")
    if elapsed >= 2.5:
        raise SystemExit("slow-drip body held the handler for %.2f seconds" % elapsed)
finally:
    sock.close()
PY
  ) || fail "keep-alive body after 403 was not drained: $output"
  pass "Safari-shaped login without Origin works and 403 drains the body"
}

test_snapshot_subprocess_does_not_write_fleet_state() {
  local home fakebin port before after hdr body spies
  home=$(make_home readonly)
  fakebin=$(make_fakebin "$home")
  spies=$home/spies
  mkdir -p "$spies"
  for cmd in fm-lock.sh fm-wake-drain.sh fm-afk-launch.sh; do
    cat > "$spies/$cmd" <<'SH'
#!/usr/bin/env bash
printf 'spy:%s\n' "$(basename "$0")" >> "$(dirname "$0")/../state/spy.log"
exit 0
SH
    chmod +x "$spies/$cmd"
  done
  init_passcode "$home" >/dev/null
  before=$(fingerprint "$home")
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/login.hdr; body=$home/login.body
  pass=$(cat "$home/data/bridge-view-passcode.txt")
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" --data "passcode=$pass"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2)); exit}' "$hdr")
  hdr=$home/obs.hdr; body=$home/obs.body
  PATH="$spies:$PATH" curl_bridge "$port" /api/observation "$hdr" "$body" \
    --header "Cookie: ${cookie%%;*}"
  assert_contains "$(head -n 1 "$hdr")" "200" "observation failed: $(cat "$hdr") $(cat "$body")"
  after=$(fingerprint "$home")
  [ "$before" = "$after" ] || fail "observation mutated fleet files"
  assert_absent "$home/state/spy.log" "snapshot PATH spies were invoked"
  assert_absent "$home/state/.watch.lock" "bridge took a session lock"
  assert_absent "$home/data/bridge-inbox" "observation must not create the photo inbox"
  pass "snapshot subprocess does not write fleet state or take the session lock"
}

test_snapshot_output_is_bounded_during_capture() {
  local home fixture output child_pid rc=0
  home=$(make_home snapshot-cap)
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
(sleep 300) &
printf '%s\n' "$!" > "$FM_HOME/oversized-child.pid"
head -c 2000000 /dev/zero
SH
  chmod +x "$fixture/bin/fm-bearings-snapshot.sh"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" "$fixture" 2>&1 <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.run_snapshot(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
except RuntimeError as exc:
    if "exceeded size cap" in str(exc):
        raise SystemExit(0)
    raise
raise SystemExit("snapshot unexpectedly completed")
PY
  ) || rc=$?
  expect_code 0 "$rc" "oversized snapshot must be stopped during capture: $output"
  child_pid=$(cat "$home/oversized-child.pid")
  kill -0 "$child_pid" 2>/dev/null && fail "oversized snapshot left descendant $child_pid running"
  pass "snapshot output is bounded during capture"
}

test_snapshot_requests_complete_glance_rows() {
  local home fixture output
  home=$(make_home snapshot-all-in-flight)
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --all-in-flight '*--all-queued*) printf '%s\n' '{"schema":"fm-bearings.v1"}' ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$fixture/bin/fm-bearings-snapshot.sh"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" "$fixture" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.run_snapshot(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
PY
  ) || fail "bridge snapshot did not request complete glance rows: $output"
  pass "snapshot requests complete in-flight and waiting rows"
}

test_bridge_page_async_progress_and_release() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.PAGE_JS)
`,
  encoding: 'utf8'
});

let resolveMedia;
let resolveUpload;
let recorderCount = 0;
let trackStopped = false;
const elements = {
  'hold-speak': {classList: {add() {}, remove() {}}, textContent: ''},
  'speak-result': {className: '', textContent: ''},
  'photo': {files: [{name: 'one.jpg'}], value: ''},
  'photo-result': {className: '', textContent: ''}
};
const context = vm.createContext({
  AbortController,
  console,
  document: {
    hidden: false,
    addEventListener() {},
    getElementById(id) { return elements[id] || null; }
  },
  window: {addEventListener() {}},
  navigator: {mediaDevices: {getUserMedia() {
    return new Promise(resolve => { resolveMedia = resolve; });
  }}},
  MediaRecorder: class {
    static isTypeSupported() { return true; }
    constructor() { recorderCount += 1; }
  },
  FormData: class {append() {}},
  fetch() { return new Promise(resolve => { resolveUpload = resolve; }); },
  setInterval() {},
  setTimeout,
  clearTimeout
});
vm.runInContext(script, context);

(async () => {
  const start = vm.runInContext('startSpeak()', context);
  await vm.runInContext('finishSpeak()', context);
  resolveMedia({getTracks() { return [{stop() { trackStopped = true; }}]; }});
  await start;
  if (!trackStopped || recorderCount !== 0) {
    throw new Error('release during microphone permission started recording');
  }

  const upload = vm.runInContext('sendPhotos({preventDefault() {}})', context);
  await Promise.resolve();
  if (elements['photo-result'].textContent !== 'Sending 1 of 1…') {
    throw new Error('pending upload was reported as sent');
  }
  resolveUpload({ok: true, json: async () => ({received_today: 1})});
  await upload;
  if (elements['photo-result'].textContent !== 'Photo received.') {
    throw new Error('successful upload did not finish its progress state');
  }
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
JS
  ) || fail "bridge page async state regression failed: $output"
  pass "bridge page handles early release and honest upload progress"
}

test_bridge_page_speak_assembles_chunks_and_rejects_tiny() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const {setTimeout: delay} = require('timers/promises');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.PAGE_JS)
`,
  encoding: 'utf8'
});

function chunk(size) {
  return new Blob([new Uint8Array(size)], {type: 'audio/mp4'});
}

function makeRecorderClass(recorders, opts) {
  return class MediaRecorder {
    static isTypeSupported() { return true; }
    constructor() {
      this.mimeType = 'audio/mp4';
      this.state = 'inactive';
      this.listeners = {};
      this.timeslice = 0;
      this.requested = false;
      recorders.push(this);
    }
    addEventListener(name, fn) {
      (this.listeners[name] || (this.listeners[name] = [])).push(fn);
    }
    emit(name, event) {
      (this.listeners[name] || []).forEach(fn => fn(event || {}));
    }
    start(timeslice) {
      this.state = 'recording';
      this.timeslice = timeslice;
      (opts.onStartChunks || []).forEach(size => this.emit('dataavailable', {data: chunk(size)}));
    }
    requestData() { this.requested = true; }
    stop() {
      this.state = 'inactive';
      this.emit('stop');
      if (opts.lateChunk) this.emit('dataavailable', {data: chunk(opts.lateChunk)});
    }
  };
}

function pageContext({recorders, nowRef, uploaded, fetchImpl, recorderOpts}) {
  const elements = {
    'hold-speak': {classList: {add() {}, remove() {}}, textContent: 'Hold to speak'},
    'speak-result': {className: '', textContent: ''},
    'speak-answer': {textContent: ''}
  };
  return vm.createContext({
    AbortController,
    Blob,
    console,
    Date: {now() { return nowRef.value; }},
    document: {
      hidden: false,
      addEventListener() {},
      getElementById(id) { return elements[id] || null; }
    },
    window: {addEventListener() {}},
    navigator: {mediaDevices: {getUserMedia() {
      return Promise.resolve({getTracks() { return [{stop() {}}]; }});
    }}},
    MediaRecorder: makeRecorderClass(recorders, recorderOpts),
    FormData: class {
      append(key, value, name) { uploaded.push({key, value, name, size: value && value.size}); }
    },
    fetch: fetchImpl,
    setInterval() {},
    setTimeout,
    clearTimeout,
    elements
  });
}

(async () => {
  const recorders = [];
  const uploaded = [];
  const nowRef = {value: 1_000_000};
  const context = pageContext({
    recorders,
    nowRef,
    uploaded,
    recorderOpts: {onStartChunks: [2000, 2000], lateChunk: 2500},
    fetchImpl() {
      return Promise.resolve({ok: true, json: async () => ({})});
    }
  });
  vm.runInContext(script, context);
  await vm.runInContext('startSpeak()', context);
  if (!recorders[0] || recorders[0].timeslice !== 1000) {
    throw new Error('recorder must start with a timeslice so Safari flushes chunks');
  }
  nowRef.value += 3000;
  await vm.runInContext('finishSpeak()', context);
  await delay(20);
  if (!recorders[0].requested) {
    throw new Error('release must request a final flush before stop');
  }
  if (uploaded.length !== 1 || uploaded[0].size !== 6500) {
    throw new Error('upload must be every chunk including the post-stop flush, got ' + JSON.stringify(uploaded));
  }
  if (context.elements['speak-result'].textContent !== 'Sent' || context.elements['speak-result'].className !== 'ok') {
    throw new Error('full capture must report Sent: ' + context.elements['speak-result'].textContent);
  }

  const tinyUploaded = [];
  const tinyRecorders = [];
  const tinyNow = {value: 2_000_000};
  let spokeFetch = false;
  const tiny = pageContext({
    recorders: tinyRecorders,
    nowRef: tinyNow,
    uploaded: tinyUploaded,
    recorderOpts: {onStartChunks: [400], lateChunk: 384},
    fetchImpl() {
      spokeFetch = true;
      return Promise.resolve({ok: true, json: async () => ({})});
    }
  });
  vm.runInContext(script, tiny);
  await vm.runInContext('startSpeak()', tiny);
  tinyNow.value += 8000;
  await vm.runInContext('finishSpeak()', tiny);
  await delay(20);
  if (spokeFetch || tinyUploaded.length) {
    throw new Error('undersized capture must not POST');
  }
  if (tiny.elements['speak-result'].className !== 'warn') {
    throw new Error('undersized capture must use the failure state');
  }
  if (tiny.elements['speak-result'].textContent === 'Sent') {
    throw new Error('undersized capture claimed Sent');
  }
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
JS
  ) || fail "bridge speak chunk assembly regression failed: $output"
  pass "bridge speak uploads every chunk and rejects an undersized capture"
}

test_session_revoke_serializes_with_login_create() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$TMP_ROOT/session-race" <<'PY'
import importlib.util, multiprocessing, pathlib, sys, time
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = pathlib.Path(sys.argv[2]) / "sessions.json"
path.parent.mkdir(parents=True)
context = multiprocessing.get_context("fork")
started = context.Event()
release = context.Event()

class PausingStore(module.SessionStore):
    def _load(self):
        data = super()._load()
        started.set()
        release.wait(5)
        return data

creator = context.Process(target=lambda: PausingStore(path).create())
revoker = context.Process(target=lambda: module.SessionStore(path).revoke_all())
creator.start()
if not started.wait(5):
    raise SystemExit("creator did not reach the serialized update")
revoker.start()
time.sleep(0.2)
if not revoker.is_alive():
    raise SystemExit("revoke did not wait for the in-flight session update")
release.set()
creator.join(5)
revoker.join(5)
if creator.exitcode or revoker.exitcode:
    raise SystemExit(f"child failure: create={creator.exitcode} revoke={revoker.exitcode}")
if module.SessionStore(path)._load()["sessions"]:
    raise SystemExit("revoke left a concurrently created session valid")
PY
  ) || fail "session revoke/create serialization failed: $output"
  pass "session revoke serializes across processes with login creation"
}

test_away_mode_passive_refresh_works() {
  local home fakebin port pass hdr body cookie rc=0
  home=$(make_home away)
  fakebin=$(make_fakebin "$home")
  date '+%s' > "$home/state/.afk"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "ordinary bearings must still refuse while away"
  pass=$(init_passcode "$home")
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/login.hdr; body=$home/login.body
  curl_bridge "$port" /login "$hdr" "$body" \
    --header "Origin: $ORIGIN" --data "passcode=$pass"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print substr($0, index($0,$2)); exit}' "$hdr")
  hdr=$home/obs.hdr; body=$home/obs.body
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: ${cookie%%;*}"
  assert_contains "$(head -n 1 "$hdr")" "200" "passive observation must work while away: $(cat "$body")"
  printf '%s' "$(cat "$body")" | jq -e '.under_way.items | any(.title == "VoiceLoop tap trigger")' >/dev/null \
    || fail "away-mode observation lost live work titles: $(cat "$body")"
  pass "away-mode passive refresh works while ordinary Bearings still refuses"
}

test_mailbox_listener_never_consumes_announcements() {
  local home
  home=$(make_home mailbox)
  python3 - "$home" <<'PY' &
import socket, pathlib, sys
home = pathlib.Path(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
(home / "mb.port").write_text(str(port))
sock.settimeout(3)
sock.listen(1)
try:
    conn, _ = sock.accept()
    data = conn.recv(4096)
    (home / "mb.got").write_bytes(data)
    conn.close()
except Exception:
    (home / "mb.got").write_bytes(b"")
sock.close()
PY
  BRIDGE_PIDS+=("$!")
  n=0
  while [ "$n" -lt 30 ] && [ ! -f "$home/mb.port" ]; do
    sleep 0.1
    n=$((n + 1))
  done
  FM_BRIDGE_VIEW_TEST=1 FM_BRIDGE_VIEW_MAILBOX_PORT="$(cat "$home/mb.port")" \
    FM_BRIDGE_VIEW_LAUNCHCTL=/usr/bin/false \
    "$BRIDGE" mailbox-listener >/dev/null
  sleep 0.3
  if [ -f "$home/mb.got" ]; then
    assert_not_contains "$(cat "$home/mb.got")" "GET /v1/announcements" \
      "mailbox listener check consumed announcements"
    [ ! -s "$home/mb.got" ] || assert_not_contains "$(cat "$home/mb.got")" "HTTP/" \
      "mailbox listener check sent HTTP"
  fi
  pass "mailbox listener check never calls GET /v1/announcements"
}

test_render_plist_keep_alive_pattern() {
  local home out
  home=$(make_home plist)
  out=$(FM_HOME="$home" "$BRIDGE" render-plist)
  assert_contains "$out" "com.firstmate.bridge-view" "plist missing launchd label"
  assert_contains "$out" "<key>KeepAlive</key>" "plist missing KeepAlive"
  assert_contains "$out" "<key>RunAtLoad</key>" "plist missing RunAtLoad"
  assert_contains "$out" "fm-bridge-view.sh" "plist must launch the tracked wrapper"
  assert_contains "$out" "/opt/homebrew/bin" "plist PATH must include Homebrew python3"
  pass "launchd plist uses the KeepAlive pattern"
}

test_unauthenticated_upload_rejected() {
  local home fakebin port hdr body inbox
  home=$(make_home upload-unauth)
  fakebin=$(make_fakebin "$home")
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  tiny_jpeg "$home/ok.jpg"
  hdr=$home/unauth.hdr; body=$home/unauth.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    -F "photo=@$home/ok.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "401" "unauthenticated upload must be rejected"
  inbox=$home/data/bridge-inbox
  if [ -d "$inbox" ]; then
    [ -z "$(find "$inbox" -type f ! -name '.*' -print)" ] || fail "unauthenticated upload wrote an inbox file"
  fi
  pass "unauthenticated upload is rejected"
}

test_upload_rejects_oversize_non_image_and_rates() {
  local home fakebin port cookie hdr body token sessions today count mode
  home=$(make_home upload-reject)
  fakebin=$(make_fakebin "$home")
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  cookie=$(bridge_cookie "$home" "$port")

  tiny_jpeg "$home/ok.jpg"
  hdr=$home/ok.hdr; body=$home/ok.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/ok.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "200" "valid jpeg upload must succeed: $(cat "$body")"
  printf '%s' "$(cat "$body")" | jq -e '.ok == true and .received_today == 1' >/dev/null \
    || fail "upload JSON missing ok/count: $(cat "$body")"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.jpg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "expected one jpeg in inbox, got $count"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "expected one sidecar in inbox, got $count"
  mode=$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$home/data/bridge-inbox")
  [ "$mode" = "0o700" ] || fail "inbox directory mode must be 0700, got $mode"
  today=$(date -u +%Y-%m-%d)
  python3 - "$home/data/bridge-inbox" "$today" <<'PY' || fail "sidecar contract mismatch"
import json, pathlib, sys
inbox, today = pathlib.Path(sys.argv[1]), sys.argv[2]
sides = list(inbox.glob("*.json"))
assert len(sides) == 1, sides
data = json.loads(sides[0].read_text())
for key in ("received_at", "original_name", "size", "content_type"):
    assert key in data, data
assert data["received_at"].startswith(today)
assert data["content_type"] == "image/jpeg"
assert data["original_name"] == "ok.jpg"
assert data["size"] == 4
images = list(inbox.glob("*.jpg"))
assert images[0].read_bytes()[:3] == b"\xff\xd8\xff"
PY

  tiny_jpeg "$home/ok2.jpg"
  hdr=$home/ok2.hdr; body=$home/ok2.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/ok2.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "200" "second jpeg upload must succeed: $(cat "$body")"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.jpg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected two uniquely named jpegs, got $count"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected two sidecars, got $count"
  python3 - "$home/data/bridge-inbox" <<'PY' || fail "second upload overwrote the first"
import pathlib, sys
inbox = pathlib.Path(sys.argv[1])
payloads = sorted(p.read_bytes() for p in inbox.glob("*.jpg"))
assert len(payloads) == 2
names = sorted(p.name for p in inbox.glob("*.jpg"))
assert names[0] != names[1]
PY

  printf 'GIF89a not-an-image' > "$home/fake.jpg"
  hdr=$home/magic.hdr; body=$home/magic.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/fake.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "415" "non-image magic bytes must be rejected"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.jpg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "rejected upload must not write an image"

  hdr=$home/oversize.hdr; body=$home/oversize.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --header "Cookie: $cookie" \
    --header "Content-Type: image/jpeg" \
    --header "Content-Length: 15728641" \
    --data-binary @/dev/null || true
  assert_contains "$(head -n 1 "$hdr")" "413" "oversize upload must return 413: $(cat "$hdr" 2>/dev/null) $(cat "$body" 2>/dev/null)"

  token=${cookie#*=}
  sessions=$home/bridge/sessions.json
  python3 - "$sessions" "$token" <<'PY'
import json, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
now = int(time.time())
data["sessions"][sys.argv[2]]["uploads"] = [now] * 30
path.write_text(json.dumps(data))
PY
  tiny_jpeg "$home/rate.jpg"
  hdr=$home/rate.hdr; body=$home/rate.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/rate.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "429" "rate-limited upload must return 429: $(cat "$body")"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.jpg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "rate-limited upload wrote an inbox file"

  hdr=$home/obs.hdr; body=$home/obs.body
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: $cookie"
  assert_contains "$(head -n 1 "$hdr")" "200" "observation after upload must still work"
  printf '%s' "$(cat "$body")" | jq -e '.photos_today == 2' >/dev/null \
    || fail "observation photos_today should be 2: $(cat "$body")"
  pass "upload rejects oversize, non-image magic, and rate-limited sessions"
}

test_inbox_unique_names_never_overwrite() {
  local home output
  home=$(make_home inbox-unique)
  mkdir -p "$home/data"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = pathlib.Path(sys.argv[2])
payload = b"\xff\xd8\xff\xd9"
stems = []
calls = {"hex8": 0}

real_hex = module.secrets.token_hex

def fake_hex(n):
    if n == 8:
        calls["hex8"] += 1
        if calls["hex8"] <= 2:
            return "aaaaaaaaaaaaaaaa"
        return "bbbbbbbbbbbbbbbb"
    return real_hex(n)

module.secrets.token_hex = fake_hex
stems.append(module.write_inbox_pair(home, payload, "one.jpg", "image/jpeg", "jpeg"))
sentinel = home / "data" / "bridge-inbox" / f"{stems[0]}.jpg"
original = sentinel.read_bytes()
stems.append(module.write_inbox_pair(home, b"\xff\xd8\xff\xdb", "two.jpg", "image/jpeg", "jpeg"))
if sentinel.read_bytes() != original:
    raise SystemExit("first inbox object was overwritten")
if stems[0] == stems[1]:
    raise SystemExit("writer reused a name")
inbox = home / "data" / "bridge-inbox"
if len(list(inbox.glob("*.jpg"))) != 2:
    raise SystemExit("expected two image files")
PY
  ) || fail "unique inbox naming failed: $output"
  pass "inbox writes never overwrite an existing name"
}

test_inbox_pair_failure_leaves_no_partial_upload() {
  local home output
  home=$(make_home inbox-atomic)
  mkdir -p "$home/data"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import errno, importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = pathlib.Path(sys.argv[2])
real_link = module.os.link
calls = 0

def fail_image_publication(source, destination):
    global calls
    calls += 1
    if calls == 2:
        raise OSError(errno.ENOSPC, "simulated full inbox")
    return real_link(source, destination)

module.os.link = fail_image_publication
try:
    module.write_inbox_pair(home, b"\xff\xd8\xff\xd9", "one.jpg", "image/jpeg", "jpeg")
except OSError as error:
    if error.errno != errno.ENOSPC:
        raise
else:
    raise SystemExit("pair publication unexpectedly succeeded")
inbox = home / "data" / "bridge-inbox"
if list(inbox.iterdir()):
    raise SystemExit(f"partial upload or staged remnants remain: {list(inbox.iterdir())}")
PY
  ) || fail "failed inbox pair cleanup failed: $output"
  pass "failed inbox pair publication leaves no partial upload"
}

test_photos_received_today_counts_utc_sidecars() {
  local home output
  home=$(make_home photo-count)
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, json, pathlib, sys, time
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = pathlib.Path(sys.argv[2])
inbox = module.ensure_inbox_dir(home)
today = time.strftime("%Y-%m-%d", time.gmtime())
yesterday = "1999-01-01"
(inbox / "today.json").write_text(json.dumps({
    "received_at": today + "T16:39:18Z",
    "original_name": "one.jpg",
    "size": 4,
    "content_type": "image/jpeg",
}))
stem = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
(inbox / (stem + "-deadbeef.json")).write_text("{}\n")
(inbox / "old.json").write_text(json.dumps({"received_at": yesterday + "T00:00:00Z"}))
count = module.photos_received_today(home)
if count != 2:
    raise SystemExit("expected 2 of today's sidecars, got %s" % count)
PY
  ) || fail "photos_received_today failed: $output"
  pass "photos_received_today counts today's sidecars by received_at and filename date"
}

test_child_path_resolves_tool_dirs_without_hardcoded_nvm() {
  local home output
  home=$(make_home child-path)
  mkdir -p "$home/.local/bin" "$home/.nvm/versions/node/v99.0.0/bin"
  printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/herdr"
  printf '#!/bin/sh\nexit 0\n' > "$home/.nvm/versions/node/v99.0.0/bin/tasks-axi"
  printf '#!/bin/sh\nexit 0\n' > "$home/.nvm/versions/node/v99.0.0/bin/node"
  chmod +x "$home/.local/bin/herdr" "$home/.nvm/versions/node/v99.0.0/bin/tasks-axi" \
    "$home/.nvm/versions/node/v99.0.0/bin/node"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = sys.argv[2]
resolved = module.resolve_child_path(source_path="/usr/bin:/bin", home=home)
if "/v99.0.0/bin" not in resolved:
    raise SystemExit("nvm bin missing from resolved PATH: %s" % resolved)
if ".local/bin" not in resolved:
    raise SystemExit("local bin missing from resolved PATH: %s" % resolved)
if "v22.23.1" in resolved:
    raise SystemExit("hardcoded nvm version leaked into PATH: %s" % resolved)
PY
  ) || fail "resolve_child_path failed: $output"
  pass "child PATH resolves HOME tool dirs without a hardcoded nvm version"
}

test_glance_page_pinned_links() {
  local home output
  home=$(make_home pinned-links)
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = pathlib.Path(sys.argv[2])

without = module.glance_html("nonce", home)
baseline = module.glance_html("nonce")
if without != baseline:
    raise SystemExit("absent bridge-links file changed the rendered page")

(home / "config" / "bridge-links").write_text("")
if module.glance_html("nonce", home) != baseline:
    raise SystemExit("empty bridge-links file changed the rendered page")

(home / "config" / "bridge-links").write_text(
    "Harbour phone build\thttps://harbour.example/build?mode=phone&v=1\n"
    "Dell health\thttps://dell.example/health\n"
    "Not secure\thttp://example.com\n"
    "malformed line\n"
    "<script>alert me</script>\thttps://example.com/?q=\"quoted\"&x=1\n"
)
rendered = module.glance_html("nonce", home)
expected = [
    '<a href="https://harbour.example/build?mode=phone&amp;v=1" target="_blank" rel="noopener noreferrer">Harbour phone build</a>',
    '<a href="https://dell.example/health" target="_blank" rel="noopener noreferrer">Dell health</a>',
    '&lt;script&gt;alert me&lt;/script&gt;',
    'href="https://example.com/?q=&quot;quoted&quot;&amp;x=1"',
]
for value in expected:
    if value not in rendered:
        raise SystemExit("missing pinned-link rendering: %s" % value)
if 'href="http://example.com"' in rendered or "malformed line" in rendered:
    raise SystemExit("invalid pinned link was rendered")
if rendered.count('target="_blank" rel="noopener noreferrer"') != 3:
    raise SystemExit("unexpected pinned-link anchor count")
if rendered.index('<nav class="bridge-links"') < rendered.index("</header>"):
    raise SystemExit("pinned links were not rendered below the page header")
PY
  ) || fail "pinned links rendering failed: $output"
  pass "glance page renders only escaped HTTPS pinned links"
}

test_observation_error_fails_fast_and_keeps_photo_count() {
  local home fakebin fixture port cookie hdr body started elapsed
  home=$(make_home obs-error)
  fakebin=$(make_fakebin "$home")
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
echo "missing tool: herdr" >&2
exit 1
SH
  chmod +x "$fixture/bin/fm-bearings-snapshot.sh"
  init_passcode "$home" >/dev/null
  python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = pathlib.Path(sys.argv[2])
module.write_inbox_pair(home, b"\xff\xd8\xff\xd9", "one.jpg", "image/jpeg", "jpeg")
module.write_inbox_pair(home, b"\xff\xd8\xff\xd9", "two.jpg", "image/jpeg", "jpeg")
PY
  log=$home/bridge-serve.log
  : > "$log"
  FM_BRIDGE_VIEW_TEST=1 FM_BRIDGE_VIEW_LAUNCHCTL="$fakebin/launchctl" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fixture" \
    "$BRIDGE" serve --host "$HOST_NAME" --port 0 >"$log" 2>&1 &
  BRIDGE_PIDS+=("$!")
  port=$(wait_listening "$log")
  cookie=$(bridge_cookie "$home" "$port")
  hdr=$home/page.hdr; body=$home/page.body
  curl_bridge "$port" / "$hdr" "$body" --header "Cookie: $cookie"
  node - "$body" <<'JS' || fail "initial observation error did not render unreachable state"
const fs = require('fs');
const vm = require('vm');

const page = fs.readFileSync(process.argv[2], 'utf8');
const match = page.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/);
if (!match) throw new Error('page script not found');

const elements = {};
for (const id of ['needs', 'underway', 'finished', 'waiting']) {
  elements[id] = {textContent: 'Loading…', innerHTML: ''};
}
elements.stale = {
  classList: {
    active: false,
    toggle(name, on) {
      if (name === 'on') this.active = on;
    }
  }
};
elements['photo-count'] = {textContent: 'Photos received today: 0'};

const context = vm.createContext({
  AbortController,
  console,
  document: {
    hidden: false,
    addEventListener() {},
    getElementById(id) { return elements[id] || null; }
  },
  fetch: async () => ({
    ok: false,
    status: 503,
    json: async () => ({error: 'snapshot failed', photos_today: 2})
  }),
  setInterval() {},
  setTimeout,
  clearTimeout,
  window: {addEventListener() {}}
});

vm.runInContext(match[1], context);
(async () => {
  await vm.runInContext('refresh()', context);
  for (const id of ['needs', 'underway', 'finished', 'waiting']) {
    if (!elements[id].innerHTML.includes('Cannot reach the desk.')) {
      throw new Error(`${id} remained ${elements[id].textContent}`);
    }
    if (elements[id].innerHTML.includes('Loading')) {
      throw new Error(`${id} remained loading`);
    }
  }
  if (!elements.stale.classList.active) throw new Error('unreachable overlay is not active');
  if (elements['photo-count'].textContent !== 'Photos received today: 2') {
    throw new Error('photo count from error response was not rendered');
  }
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
JS
  hdr=$home/obs.hdr; body=$home/obs.body
  started=$(python3 -c 'import time; print(time.monotonic())')
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: $cookie"
  elapsed=$(python3 -c "import time; print(time.monotonic() - $started)")
  assert_contains "$(head -n 1 "$hdr")" "503" "broken snapshot must return 503: $(cat "$body")"
  printf '%s' "$(cat "$body")" | jq -e '.photos_today == 2 and .error' >/dev/null \
    || fail "503 must keep today's photo count: $(cat "$body")"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 8 else 1)" "$elapsed" \
    || fail "observation 503 hung ${elapsed}s: $(cat "$body")"
  pass "observation errors fail fast and render the unreachable client state"
}

test_scrubbed_snapshot_with_herdr_meta_fails_fast() {
  local home output
  home=$(make_home scrubbed-herdr)
  mkdir -p "$home/projects/ship-wt"
  fm_write_meta "$home/state/herdr-task.meta" \
    "window=default:w1:p2" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "backend=herdr"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" "$ROOT" <<'PY'
import importlib.util, pathlib, sys, time
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.CHILD_PATH = module.BASE_CHILD_PATH
home = pathlib.Path(sys.argv[2])
root = pathlib.Path(sys.argv[3])
started = time.monotonic()
outcome = "ok"
try:
    module.run_snapshot(home, root)
except RuntimeError as exc:
    outcome = str(exc)
elapsed = time.monotonic() - started
if elapsed >= 8:
    raise SystemExit("scrubbed snapshot hung %.2fs: %s" % (elapsed, outcome))
if "timed out" in outcome:
    raise SystemExit("scrubbed snapshot timed out: %s" % outcome)
print("elapsed=%.2f outcome=%s" % (elapsed, outcome.splitlines()[0][:120]))
PY
  ) || fail "scrubbed herdr snapshot did not fail fast: $output"
  pass "scrubbed-env snapshot with a herdr task succeeds or fails fast"
}

test_human_titles_drop_internal_primary_lines() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
model = {
    "generated": "now",
    "omitted": [{"surface": "in_flight showing 8 of 80"}, {"surface": "gates showing 20 of 92"}],
    "decisions_open": [{"summary": "Merge the bridge PR?"}],
    "in_flight": [
        {"state": "working", "title": "VoiceLoop tap trigger"},
        {"state": "working", "title": "repro: env -i HOME=/tmp PATH=/usr/bin"},
        {"state": "working", "title": "glasses-bridge-upgrades-b3"},
    ],
    "landed": [{"what": "Spoken updates on the glasses", "artifact": "https://github.com/kunchenguid/firstmate/pull/7"}],
    "gates": [
        {"title": "in-flight backlog item has no child metadata"},
        {"title": "Always-on cloud, host+budget"},
        {"title": "Queued follow-up after photos"},
    ],
}
obs = module.project_observation(model)
titles = [row["title"] for row in obs["under_way"]["items"]]
waiting = [row["title"] for group in obs["waiting"]["groups"] for row in group["items"]]
if "VoiceLoop tap trigger" not in titles:
    raise SystemExit("kept human in-flight title missing: %s" % titles)
if any("repro:" in t or "env -i" in t for t in titles):
    raise SystemExit("repro string leaked as a primary line: %s" % titles)
if any(t == "glasses-bridge-upgrades-b3" for t in titles):
    raise SystemExit("raw id leaked as a primary line: %s" % titles)
if any("child metadata" in t for t in waiting):
    raise SystemExit("inventory diagnostic leaked into waiting: %s" % waiting)
if "Always-on cloud, host+budget" not in waiting or "Queued follow-up after photos" not in waiting:
    raise SystemExit("human waiting titles dropped: %s" % waiting)
if obs["waiting"]["more"] != 0:
    raise SystemExit("waiting list still reports a truncated remainder")
if obs["needs_you"]["items"][0]["title"] != "Merge the bridge PR?":
    raise SystemExit("decision title changed: %s" % obs["needs_you"])
print("ok")
PY
  ) || fail "human title projection failed: $output"
  pass "glance titles stay human and drop internal primary lines"
}

test_needs_you_excludes_deferred_holds_and_caps_at_five() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
model = {
    "generated": "now",
    "omitted": [],
    "decisions_open": [
        {"summary": "Parked web pricing", "hold_kind": "parked",
         "hold_reason": "Parked 2026-08-02 on captain order", "repo": "atelier"},
        {"summary": "Duplicate accounts question", "hold_kind": "parked",
         "hold_reason": "Parked 2026-08-02 as a duplicate - asked once under the live item",
         "repo": "city-guide"},
        {"summary": "Confirm retiring the Miro rebuild", "hold_kind": "captain",
         "hold_reason": "Confirm retiring or reshaping this task.",
         "repo": "city-guide"},
        {"summary": "Choose the Qwen route", "hold_kind": "captain",
         "hold_reason": "captain choice pending", "repo": "firstmate"},
        {"summary": "Approve the advisor call", "hold_kind": "captain",
         "hold_reason": "needs the captain's word", "repo": "household-finances"},
        {"summary": "Raise the Claude spend limit", "hold_kind": "captain",
         "hold_reason": "the captain raises the limit", "repo": "firstmate"},
        {"summary": "Pick the DeepSeek route", "hold_kind": "captain",
         "hold_reason": "captain choice pending", "repo": "starship"},
        {"summary": "Supply the LoanOffice facts", "hold_kind": "captain",
         "hold_reason": "only he can answer", "repo": "starship"},
        {"summary": "Fund worker capacity", "hold_kind": "captain",
         "hold_reason": "spend approval", "repo": "firstmate"},
        {"summary": "Choose house versus debt", "hold_kind": "captain",
         "hold_reason": "the couple's choice", "repo": "household-finances"},
    ],
    "in_flight": [
        {"state": "blocked", "title": "Mailbox token missing"},
        {"state": "working", "title": "VoiceLoop tap trigger"},
    ],
    "landed": [],
    "gates": [],
}
obs = module.project_observation(model)
shown = [row["title"] for row in obs["needs_you"]["items"]]
hidden = [row["title"] for row in obs["needs_you"].get("rest") or []]
deferred = [
    "Parked web pricing",
    "Duplicate accounts question",
    "Confirm retiring the Miro rebuild",
]
for title in deferred:
    if title in shown or title in hidden:
        raise SystemExit("deferred hold leaked into needs you: %s" % title)
if shown[0] != "Mailbox token missing":
    raise SystemExit("stuck live work should lead needs you: %s" % shown)
if len(shown) != 5:
    raise SystemExit("needs you must cap at 5, got %s" % shown)
if obs["needs_you"]["more"] != 3:
    raise SystemExit("needs you remainder should be 3, got %s" % obs["needs_you"])
if "Fund worker capacity" not in hidden or "Choose house versus debt" not in hidden:
    raise SystemExit("capped live decisions missing from rest: %s" % hidden)
waiting = [row["title"] for group in obs["waiting"]["groups"] for row in group["items"]]
for title in deferred:
    if title not in waiting:
        raise SystemExit("deferred hold missing from waiting: %s %s" % (title, waiting))
print("ok")
PY
  ) || fail "needs-you selection failed: $output"
  pass "needs you drops parked, duplicate, and retire holds and caps at five"
}

test_waiting_groups_by_project_counts() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fm_bridge_view", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
model = {
    "generated": "now",
    "omitted": [],
    "decisions_open": [],
    "in_flight": [{"state": "paused", "title": "Waiting on a vendor"}],
    "landed": [],
    "gates": [
        {"title": "Atelier pricing", "repo": "atelier", "hold_kind": "parked",
         "reason": "Parked 2026-08-02 on captain order"},
        {"title": "Atelier brand", "repo": "atelier-workspace", "hold_kind": "parked",
         "reason": "Parked 2026-08-02 on captain order"},
        {"title": "Journey board refresh", "repo": "city-guide",
         "hold_kind": "parked", "reason": "Parked 2026-08-02 as a duplicate"},
        {"title": "Rotate finances secrets", "repo": "household-finances",
         "hold_kind": "captain", "reason": "captain call on history purge"},
        {"title": "Cloud slice go", "repo": "firstmate", "hold_kind": "captain",
         "reason": "awaiting captain go"},
        {"title": "Always-on cloud, host+budget", "repo": "Amplify-Logic/firstmate",
         "hold_kind": "captain", "reason": "awaiting captain go"},
    ],
}
obs = module.project_observation(model)
groups = obs["waiting"]["groups"]
counts = {group["label"]: group["count"] for group in groups}
if counts.get("Atelier") != 2:
    raise SystemExit("Atelier count wrong: %s" % groups)
if counts.get("Journey") != 1:
    raise SystemExit("Journey count wrong: %s" % groups)
if counts.get("Finances") != 1:
    raise SystemExit("Finances count wrong: %s" % groups)
if counts.get("Fleet") != 2:
    raise SystemExit("Fleet count wrong: %s" % groups)
if any(group["count"] != len(group["items"]) for group in groups):
    raise SystemExit("group count does not match items: %s" % groups)
if obs["waiting"]["more"] != 0:
    raise SystemExit("waiting groups must not truncate")
labels = [group["label"] for group in groups]
if "Other" in labels and counts.get("Other") != 1:
    raise SystemExit("paused live work should be its own reachable group: %s" % groups)
print("ok")
PY
  ) || fail "waiting project grouping failed: $output"
  pass "waiting collapses to complete per-project counts"
}

test_glance_page_renders_chips_and_needs_remainder() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.PAGE_JS)
`,
  encoding: 'utf8'
});

const elements = {
  needs: {innerHTML: '', textContent: ''},
  underway: {innerHTML: '', textContent: ''},
  finished: {innerHTML: '', textContent: ''},
  waiting: {innerHTML: '', textContent: ''},
  observed: {textContent: ''},
  desk: {textContent: ''},
  mailbox: {textContent: ''},
  stale: {classList: {toggle() {}}},
  'photo-count': {textContent: ''}
};
const context = vm.createContext({
  document: {
    hidden: false,
    addEventListener() {},
    getElementById(id) { return elements[id] || null; }
  },
  window: {addEventListener() {}},
  Date,
  setInterval() {},
  setTimeout,
  clearTimeout
});
vm.runInContext(script, context);
vm.runInContext('apply', context)({
  mailbox_listener: true,
  photos_today: 0,
  needs_you: {
    items: [
      {title: 'Choose the Qwen route', dot: 'Needs you'},
      {title: 'Approve the advisor call', dot: 'Needs you'}
    ],
    rest: [{title: 'Fund worker capacity', dot: 'Needs you'}],
    more: 1
  },
  under_way: {items: [{title: 'VoiceLoop tap trigger', dot: 'Under way'}]},
  just_finished: {items: []},
  waiting: {
    groups: [
      {label: 'Atelier', count: 2, items: [{title: 'Atelier pricing', dot: 'Waiting'}, {title: 'Atelier brand', dot: 'Waiting'}]},
      {label: 'Journey', count: 1, items: [{title: 'Journey board refresh', dot: 'Waiting'}]}
    ],
    more: 0
  }
});
if (!elements.waiting.innerHTML.includes('wait-chip')) {
  throw new Error('waiting chips were not rendered: ' + elements.waiting.innerHTML);
}
if (!elements.waiting.innerHTML.includes('Atelier 2') || !elements.waiting.innerHTML.includes('Journey 1')) {
  throw new Error('chip labels missing counts: ' + elements.waiting.innerHTML);
}
if (!elements.waiting.innerHTML.includes('Atelier pricing')) {
  throw new Error('expanded chip list dropped items: ' + elements.waiting.innerHTML);
}
if (!elements.needs.innerHTML.includes('more waiting on you - show all')) {
  throw new Error('needs remainder missing: ' + elements.needs.innerHTML);
}
if (!elements.needs.innerHTML.includes('Fund worker capacity')) {
  throw new Error('hidden needs item not reachable: ' + elements.needs.innerHTML);
}
if (elements.needs.innerHTML.includes('Nothing needs you')) {
  throw new Error('empty copy shown beside live needs');
}
JS
  ) || fail "glance page chip rendering failed: $output"
  pass "glance page renders waiting chips and a needs-you show-all line"
}

# The Routing section: the roster, the latest dispatch decisions, the worker
# graph, and live workers, from bin/fm-routing-snapshot.sh joined to the
# bearings read the glance already makes. It names tasks only by the titles the
# glance shows and never fails the glance with it.
test_routing_projection_joins_live_rows() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
routing = {
    "schema": "fm-routing.v1",
    "roster": [
        {"rule": "rule_1", "label": "COURSE WRITING", "profiles": [{"harness": "claude", "model": "claude-fable-5-1", "effort": "medium"}]},
        {"rule": "rule_2", "label": "Hostile read", "profiles": [{"harness": "cursor", "model": "grok-4.7-xhigh", "effort": None}, {"harness": "pi", "model": "openai-codex/gpt-5.6-sol", "effort": "high"}]},
        {"rule": "default", "label": "default", "profiles": [{"harness": "claude", "model": "opus", "effort": "high"}]},
    ],
    "roster_error": None,
    "decisions": [
        {"at": 900, "task": "ship-a", "status": "clear", "rule": "rule_1", "label": "COURSE WRITING", "p": 0.81, "profile": {"harness": "claude", "model": "claude-sonnet-5-5", "effort": "medium"}},
        {"at": 800, "task": "landed-z", "status": "ambiguous", "rule": "rule_2", "label": "Hostile read", "p": 0.4, "profile": None},
        {"at": 700, "task": "gone-task-q7", "status": "clear", "rule": "default", "label": "default", "p": True, "profile": None},
    ],
    "workers": [
        {"id": "ship-a", "kind": "ship", "model": "claude-sonnet-5-5", "effort": "medium", "started": 400},
        {"id": "mate", "kind": "secondmate", "model": "opus", "effort": "default", "started": None},
        {"id": "unlisted-record", "kind": "scout", "model": "opus", "effort": "high", "started": 100},
    ],
}
bearings = {
    "in_flight": [
        {"id": "ship-a", "kind": "ship", "state": "working", "name": "Phone routing panel"},
        {"id": "mate/child-b", "kind": "scout", "state": "paused", "name": "Setlist evidence"},
    ],
    "secondmates": [
        {"id": "(registry)", "state": "unknown", "doing": "Registered secondmate table unavailable"},
        {"id": "mate", "state": "active_child_work", "doing": "child-b: paused"},
    ],
    "landed": [{"id": "landed-z", "what": "Spoken updates on the glasses"}],
}
out = module.project_routing(routing, bearings, 1000.0)
text = json.dumps(out)
assert [r["profile"] for r in out["roster"]] == ["fable-5.1 · medium", "grok-4.7-xhigh / gpt-5.6-sol · high", "opus · high"], out["roster"]
assert out["roster"][-1]["default"] is True
assert [d["task"] for d in out["decisions"]] == ["Phone routing panel", "Spoken updates on the glasses", "Earlier task"], out["decisions"]
assert out["decisions"][0]["profile"] == "sonnet-5.5 · medium" and out["decisions"][0]["p"] == 0.81
assert out["decisions"][1]["profile"] == "" and out["decisions"][2]["p"] is None
assert [(w["title"], w["kind"], w["model"], w["effort"], w["age_secs"], w["state"]) for w in out["workers"]] == [
    ("Phone routing panel", "ship", "sonnet-5.5", "medium", 600, "working"),
    ("Setlist evidence", "scout", "-", "", -1, "paused"),
], out["workers"]
assert [(n["kind"], n["model"], n["state"], [(c["kind"], c["model"]) for c in n["children"]]) for n in out["graph"]] == [
    ("ship", "sonnet-5.5", "working", []),
    ("secondmate", "opus", "active_child_work", [("scout", "-")]),
], out["graph"]
for leaked in ("ship-a", "landed-z", "gone-task-q7", "unlisted-record", "child-b"):
    assert leaked not in text, leaked
PY
  ) || fail "routing projection failed: $output"
  pass "routing joins live rows to records, names tasks by glance titles, and nests second-mate children"
}

test_routing_failure_leaves_glance_whole() {
  local home fixture output
  home=$(make_home routing-failure)
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-bearings.v1","in_flight":[{"id":"ship-a","kind":"ship","state":"working","name":"Phone routing panel"}]}'
SH
  chmod +x "$fixture/bin/fm-bearings-snapshot.sh"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" "$fixture" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home, root = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
module.mailbox_listener_available = lambda: False
obs = module.SnapshotCache(home, root).get()
assert obs["under_way"]["items"][0]["title"] == "Phone routing panel", obs
assert "routing snapshot missing" in obs["routing"]["error"], obs["routing"]
script = root / "bin" / "fm-routing-snapshot.sh"
script.write_text("#!/usr/bin/env bash\necho nope >&2\nexit 3\n")
script.chmod(0o755)
obs = module.SnapshotCache(home, root).get()
assert obs["under_way"]["items"], obs
assert obs["routing"]["error"] == "nope", obs["routing"]
PY
  ) || fail "routing failure broke the glance: $output"
  pass "a missing or failing routing snapshot leaves the glance whole and says why"
}

test_observation_carries_routing_from_local_records() {
  local home fakebin port cookie hdr body before after
  home=$(make_home routing-live)
  fakebin=$(make_fakebin "$home")
  ln -s "$(command -v jq)" "$fakebin/jq"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "STANDING DEFAULT: ordinary work.", "use": { "harness": "claude", "model": "opus", "effort": "high" } } ],
  "default": { "harness": "claude", "model": "opus", "effort": "high" } }
JSON
  printf '%s\n' '{"at":1790000000,"task":"ship-task","status":"clear","rule":"rule_1","rule_when":"STANDING DEFAULT: ordinary work.","p":0.9,"profile":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}' \
    > "$home/state/dispatch-decisions.jsonl"
  printf 'model=gpt-5.6-sol\neffort=high\nspawn_gen=s1790000000.1.2\noutcome=PRIVATE-OUTCOME-TEXT\n' >> "$home/state/ship-task.meta"
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  cookie=$(bridge_cookie "$home" "$port")
  before=$(fingerprint "$home")
  hdr=$home/obs.hdr; body=$home/obs.body
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: $cookie"
  after=$(fingerprint "$home")
  assert_contains "$(head -n 1 "$hdr")" "200" "observation with routing must succeed"
  [ "$before" = "$after" ] || fail "reading routing changed fleet records"
  jq -e '.routing.roster[0].label == "STANDING DEFAULT" and .routing.roster[0].profile == "opus · high"' "$body" >/dev/null \
    || fail "routing roster missing: $(cat "$body")"
  jq -e '.routing.decisions[0] | .task == "VoiceLoop tap trigger" and .status == "clear" and .profile == "gpt-5.6-sol · high"' "$body" >/dev/null \
    || fail "routing decision missing or unnamed: $(jq -c .routing "$body")"
  jq -e '.routing.workers[0] | .title == "VoiceLoop tap trigger" and .model == "gpt-5.6-sol" and .kind == "ship"' "$body" >/dev/null \
    || fail "routing worker missing: $(jq -c .routing "$body")"
  assert_not_contains "$(cat "$body")" "ship-task" "routing must not leak task ids"
  assert_not_contains "$(cat "$body")" "PRIVATE-OUTCOME-TEXT" "routing must not leak a record's outcome"
  pass "the observation carries the routing section from local records without ids or outcomes"
}

test_glance_page_renders_routing() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.PAGE_JS)
`,
  encoding: 'utf8'
});
const bar = {getAttribute() { return '0.81'; }, style: {}};
const routing = {innerHTML: '', textContent: '', querySelectorAll() { return [bar]; }};
const elements = {
  needs: {innerHTML: '', textContent: ''},
  underway: {innerHTML: '', textContent: ''},
  finished: {innerHTML: '', textContent: ''},
  waiting: {innerHTML: '', textContent: ''},
  routing,
  observed: {textContent: ''},
  desk: {textContent: ''},
  mailbox: {textContent: ''},
  stale: {classList: {toggle() {}}},
  'photo-count': {textContent: ''}
};
const context = vm.createContext({
  document: {hidden: false, addEventListener() {}, getElementById(id) { return elements[id] || null; }},
  window: {addEventListener() {}},
  Date, setInterval() {}, setTimeout, clearTimeout
});
vm.runInContext(script, context);
const apply = vm.runInContext('apply', context);
const base = {mailbox_listener: true, photos_today: 0, needs_you: {items: []}, under_way: {items: []},
  just_finished: {items: []}, waiting: {groups: []}, server_unix: 10000};
apply(Object.assign({}, base, {routing: {
  roster: [{label: 'COURSE WRITING', profile: 'fable-5.1 · medium', default: false},
           {label: 'default', profile: 'opus · high', default: true}],
  decisions: [{task: 'Phone <b>routing</b> panel', status: 'clear', rule: 'STANDING DEFAULT', p: 0.81,
               profile: 'opus · high', at: 9400},
              {task: 'Setlist evidence', status: 'ambiguous', rule: 'Hostile read', p: 0.4, profile: '', at: 9000}],
  graph: [{kind: 'ship', model: 'opus', children: []},
          {kind: 'secondmate', model: 'opus', children: [{kind: 'scout', model: 'sonnet-5.5', children: []}]}],
  workers: [{title: 'Phone routing panel', kind: 'ship', model: 'opus', effort: 'high', age_secs: 720,
             state: 'working', dot: 'Under way'}]
}}));
const html = routing.innerHTML;
for (const want of ['Model roster', 'COURSE WRITING', 'fable-5.1 · medium', 'route-row default',
                    'Jev decisions', 'verdict clear', 'p 0.81', '→ opus · high', '10m ago',
                    'Phone &lt;b&gt;routing&lt;/b&gt; panel', 'Agent graph', 'firstmate\n├ ship · opus\n└ secondmate · opus\n  └ scout · sonnet-5.5',
                    'verdict ambiguous', 'left to firstmate&#39;s own call',
                    'Live workers · 1', 'ship · opus · high · 12m · working']) {
  if (!html.includes(want)) throw new Error('routing render missing ' + JSON.stringify(want) + ': ' + html);
}
if (bar.style.width !== '81%') throw new Error('probability bar width not set: ' + bar.style.width);
apply(Object.assign({}, base, {routing: {roster: [], decisions: [], graph: [], workers: []}}));
for (const want of ['No routing rules configured.', 'No routing decisions recorded yet.', 'No workers under way.']) {
  if (!routing.innerHTML.includes(want)) throw new Error('empty routing missing ' + want + ': ' + routing.innerHTML);
}
apply(Object.assign({}, base, {routing: {error: 'routing snapshot timed out'}}));
if (!routing.innerHTML.includes('Routing is unavailable: routing snapshot timed out')) {
  throw new Error('routing error not shown: ' + routing.innerHTML);
}
JS
  ) || fail "glance routing rendering failed: $output"
  pass "glance page renders the roster, decisions, graph, and workers, with empty and error copy"
}

# The What I remember section: only the captain files, learnings and goal
# charters under data/, rendered as plain text, with any gift, surprise or
# present line withheld and counted.
test_memory_reads_only_allowlisted_sources() {
  local home outside output
  home=$(make_home memory-sources)
  outside=$TMP_ROOT/memory-outside
  mkdir -p "$outside" "$home/data/goals" "$home/data/some-task" "$home/.claude/projects/x/memory"
  cat > "$home/data/captain.md" <<'EOF'
# Captain

## Settled matters
- Plain outcome language, **outcome first**.
  Detail lives in the `report`.
- Gift for Alex is the green scarf.
- Mornings are for reading.

## Surprise plans
- Booked the community hall for the 12th.
### Guests
- Sam and Kim
## Music
- Two to four hours a week.
EOF
  printf '# Learnings\n- Full disk looks like low memory.\n- Present the PR link in full.\n' > "$home/data/learnings.md"
  printf '# Firstmate\nStatus: APPROVED\n\n## Goals\n- The fleet keeps working.\n' > "$home/data/goals/firstmate.md"
  printf '# Gifts\n- HIDDEN-GIFT-CHARTER\n' > "$home/data/goals/gift-list.md"
  printf '%s\n' '- HIDDEN-UNDERSCORE-CHARTER' > "$home/data/goals/birthday_gift.md"
  printf '%s\n' '- Rotate the deploy keys monthly.' > "$home/data/goals/api-key.md"
  printf '%s\n' '- LEAKED-LINK-TARGET' > "$outside/linked.md"
  ln -s "$outside/linked.md" "$home/data/goals/linked.md"
  printf '%s\n' 'TOKEN=LEAKED-ENV' > "$home/data/.env"
  printf '%s\n' 'LEAKED-PROJECT-DATA' > "$home/data/some-task/report.md"
  printf '%s\n' '- LEAKED-HARNESS-MEMORY' > "$home/.claude/projects/x/memory/MEMORY.md"
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
out = module.read_memory(pathlib.Path(sys.argv[2]))
text = json.dumps(out)
paths = [s["path"] for s in out["sources"]]
assert paths == ["data/captain.md", "data/captain-shared.md", "data/learnings.md",
                 "data/goals/api-key.md", "data/goals/firstmate.md", "data/goals/linked.md"], paths
captain, shared, learnings, keys, goal, linked = out["sources"]
assert keys["label"] == "Goals: api key" and keys["sections"][0]["entries"] == ["Rotate the deploy keys monthly."], keys
assert shared.get("missing") is True and "sections" not in shared, shared
assert "link" in linked["error"] and "sections" not in linked, linked
assert [s["heading"] for s in captain["sections"]] == ["Settled matters", "Music"], captain["sections"]
assert captain["sections"][0]["entries"] == [
    "Plain outcome language, outcome first.\nDetail lives in the report.",
], captain["sections"][0]
assert captain["entries"] == 2 and len(captain["changed_date"]) == 10, captain
assert learnings["sections"][0]["entries"] == ["Full disk looks like low memory."], learnings
assert goal["label"] == "Goals: firstmate" and goal["sections"][1]["entries"] == ["The fleet keeps working."], goal
# captain: the gift entry and the Mornings entry after it, the Surprise
# heading and its entry, the Guests heading and its entry (6); learnings: the
# Present line (1); the gift-list charter, withheld whole by its name (2); the
# birthday_gift charter (1).
assert out["withheld"] == 10, out["withheld"]
for leaked in ("gift", "Gift", "Mornings", "Surprise", "community hall", "Sam", "Present", "HIDDEN-GIFT-CHARTER", "HIDDEN-UNDERSCORE-CHARTER",
               "LEAKED-LINK-TARGET", "LEAKED-ENV", "LEAKED-PROJECT-DATA",
               "LEAKED-HARNESS-MEMORY", "VoiceLoop", "ship-task", "**", chr(96)):
    assert leaked not in text, leaked
PY
  ) || fail "memory read failed: $output"
  pass "what I remember reads only the captain files, learnings and goals, and withholds gift lines with a count"
}

test_memory_withholds_gift_blocks_after_any_lead_in() {
  local output
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cases = [
    ("paragraph lead-in",
     "## Family\nGift ideas for Alex:\n- Green scarf\n- Book on sailing\n\nMornings are for reading.\n## Music\n- Two hours a week.\n",
     [{"heading": "Music", "entries": ["Two hours a week."]}], 4),
    ("bold label",
     "## Family\n- Call on Sundays.\n\n**Gifts**\n\n- Green scarf\n\n- Book on sailing\n  with a chart\n\n### Ideas\n- Kite\n# Music\n- Two hours a week.\n",
     [{"heading": "Family", "entries": ["Call on Sundays."]}, {"heading": "Music", "entries": ["Two hours a week."]}], 6),
    ("setext heading",
     "Gift ideas\n----------\n- Green scarf\n\nMore\n### Ideas\n- Book on sailing\n\nMusic\n=====\n- Two hours a week.\n# Coda\n- Sail on Sundays.\n",
     [{"heading": "Coda", "entries": ["Sail on Sundays."]}], 9),
    ("hidden paragraph over a Setext dash underline",
     "## Family\nGift ideas for Alex:\n\nA green scarf, or a book on sailing.\n---\n- more\n",
     [], 4),
    ("hidden paragraph over a Setext equals underline",
     "Gift ideas:\n\nGreen scarf\n===\n- x\n",
     [], 4),
    ("fenced gift list over a Setext underline",
     "## Family\nNote\n```gift-list\nGreen scarf\n```\n---\n- Book on sailing\n",
     [], 6),
    ("bullet continuation",
     "- Gift for Alex:\n\n  Green scarf\n  ---\n- Mornings are for reading.\n# Music\n- Two hours a week.\n",
     [{"heading": "Music", "entries": ["Two hours a week."]}], 4),
    ("table after a blank line",
     "Gift ideas:\n\n| who | what |\n| Alex | watch |\n",
     [], 3),
    ("paragraph after a blank line",
     "Gift ideas for Alex:\n\nA green scarf, or a book on sailing.\n",
     [], 2),
    ("plain setext heading",
     "Settled matters\n---\n- Plain outcome language.\n",
     [{"heading": "Settled matters", "entries": ["Plain outcome language."]}], 0),
]
for name, text, sections, withheld in cases:
    got = module.memory_sections(text)
    assert got == (sections, withheld), (name, got)
PY
  ) || fail "memory gift blocks leaked: $output"
  pass "what I remember withholds everything after a gift line up to the next heading of its level or higher"
}

test_observation_carries_memory_without_writes() {
  local home fixture output before after
  home=$(make_home memory-observation)
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-bearings.v1","in_flight":[]}'
SH
  chmod +x "$fixture/bin/fm-bearings-snapshot.sh"
  printf '# Captain\n- Plain outcome language.\n- A present for Alex.\n' > "$home/data/captain.md"
  before=$(fingerprint "$home")
  output=$(python3 - "$ROOT/bin/fm-bridge-view.py" "$home" "$fixture" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home, root = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
module.mailbox_listener_available = lambda: False
obs = module.SnapshotCache(home, root).get()
assert obs["routing"].get("error"), obs
memory = obs["memory"]
assert memory["sources"][0]["sections"][0]["entries"] == ["Plain outcome language."], memory
assert memory["withheld"] == 1, memory
PY
  ) || fail "memory observation failed: $output"
  after=$(fingerprint "$home")
  [ "$before" = "$after" ] || fail "reading memory changed home records"
  pass "the observation carries what I remember beside a failed routing read, without writing"
}

test_glance_page_renders_memory() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.PAGE_JS)
`,
  encoding: 'utf8'
});
const memory = {innerHTML: '', textContent: ''};
const foot = {textContent: ''};
const elements = {
  needs: {innerHTML: '', textContent: ''},
  underway: {innerHTML: '', textContent: ''},
  finished: {innerHTML: '', textContent: ''},
  waiting: {innerHTML: '', textContent: ''},
  memory,
  'memory-withheld': foot,
  observed: {textContent: ''},
  desk: {textContent: ''},
  mailbox: {textContent: ''},
  stale: {classList: {toggle() {}}},
  'photo-count': {textContent: ''}
};
const context = vm.createContext({
  document: {hidden: false, addEventListener() {}, getElementById(id) { return elements[id] || null; }},
  window: {addEventListener() {}},
  Date, setInterval() {}, setTimeout, clearTimeout
});
vm.runInContext(script, context);
const apply = vm.runInContext('apply', context);
const base = {mailbox_listener: true, photos_today: 0, needs_you: {items: []}, under_way: {items: []},
  just_finished: {items: []}, waiting: {groups: []}, server_unix: 10000};
const kept = {withheld: 3, sources: [
  {label: 'About you', path: 'data/captain.md', changed_date: '2026-10-04', entries: 2,
   sections: [{heading: 'Settled <b>matters</b>', entries: ['Plain outcome language.\nDetail in the report.', 'Mornings are for reading.']}]},
  {label: 'About you, shared with second mates', path: 'data/captain-shared.md', missing: true},
  {label: 'Goals: linked', path: 'data/goals/linked.md', error: 'skipped: a link, not a file this home keeps'}
]};
apply(Object.assign({}, base, {memory: kept}));
const html = memory.innerHTML;
for (const want of ['About you', 'changed 2026-10-04 · 2 entries', 'data/captain.md',
                    '<h3>Settled &lt;b&gt;matters&lt;/b&gt;</h3>', '<li>Plain outcome language.\nDetail in the report.</li>',
                    'About you, shared with second mates · nothing kept',
                    'Goals: linked · skipped: a link, not a file this home keeps', 'class="more-fold mem-fold"']) {
  if (!html.includes(want)) throw new Error('memory render missing ' + JSON.stringify(want) + ': ' + html);
}
if (foot.textContent !== 'What I remember withheld 3 lines about a gift, surprise or present.') {
  throw new Error('withheld footer wrong: ' + foot.textContent);
}
memory.innerHTML = 'OPEN FOLD';
apply(Object.assign({}, base, {memory: JSON.parse(JSON.stringify(kept))}));
if (memory.innerHTML !== 'OPEN FOLD') throw new Error('unchanged memory re-rendered and closed an open fold');
apply(Object.assign({}, base, {memory: {withheld: 1, sources: []}}));
if (foot.textContent !== 'What I remember withheld 1 line about a gift, surprise or present.') {
  throw new Error('singular footer wrong: ' + foot.textContent);
}
apply(Object.assign({}, base, {memory: {error: 'memory read failed'}}));
if (!memory.innerHTML.includes('Memory is unavailable: memory read failed')) {
  throw new Error('memory error not shown: ' + memory.innerHTML);
}
JS
  ) || fail "glance memory rendering failed: $output"
  pass "glance page renders what I remember per source, keeps open folds, and counts withheld lines"
}

test_observation_selects_and_groups_live_backlog() {
  local home fakebin port cookie hdr body
  home=$(make_home glance-select)
  fakebin=$(make_fakebin "$home")
  # resolve_child_path admits each required tool's directory once. Put jq in
  # the fixture directory so Linux /usr/bin/tmux cannot outrank the fake tmux.
  ln -s "$(command -v jq)" "$fakebin/jq"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - VoiceLoop tap trigger (repo: firstmate) (kind: ship) (since 2026-08-19)
- [ ] vendor-wait - Waiting on the Atelier vendor (repo: atelier) (kind: ship) (since 2026-08-19)

## Queued
- [ ] decide-qwen - Choose the Qwen route (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)
- [ ] decide-advisor - Approve the advisor call (repo: household-finances) (kind: captain) (hold: needs the captain's word) (hold-kind: captain)
- [ ] decide-limit - Raise the Claude spend limit (repo: firstmate) (kind: captain) (hold: the captain raises the limit) (hold-kind: captain)
- [ ] decide-deepseek - Pick the DeepSeek route (repo: starship) (kind: captain) (hold: captain choice pending) (hold-kind: captain)
- [ ] decide-loanoffice - Supply the LoanOffice facts (repo: starship) (kind: captain) (hold: only he can answer) (hold-kind: captain)
- [ ] decide-capacity - Fund worker capacity (repo: firstmate) (kind: captain) (hold: spend approval) (hold-kind: captain)
- [ ] retire-miro - Confirm retiring the Miro rebuild (repo: city-guide) (kind: captain) (hold: Confirm retiring or reshaping this task.) (hold-kind: captain)
- [ ] parked-pricing - Align Atelier pricing (repo: atelier) (kind: ship) (hold: Parked 2026-08-02 on captain order) (hold-kind: parked)
- [ ] dup-accounts - User accounts at launch (repo: city-guide) (kind: ship) (hold: Parked 2026-08-02 as a duplicate - asked once under the live item) (hold-kind: parked)
- [ ] journey-board - Keep the journey board current (repo: city-guide) (kind: ship) (hold: Parked 2026-08-02 on captain order) (hold-kind: parked)
- [ ] finances-rotate - Rotate finances secrets (repo: household-finances) (kind: ship) (hold: captain call on history purge) (hold-kind: captain)

## Done
- [x] done-a - Spoken updates on the glasses https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-08-18)
EOF
  fm_write_meta "$home/state/vendor-wait.meta" \
    "window=firstmate:fm-vendor-wait" \
    "worktree=$home/projects/ship-wt" \
    "project=atelier" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'paused: waiting at the vendor gate\n' > "$home/state/vendor-wait.status"
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  cookie=$(bridge_cookie "$home" "$port")
  hdr=$home/obs.hdr; body=$home/obs.body
  curl_bridge "$port" /api/observation "$hdr" "$body" --header "Cookie: $cookie"
  assert_contains "$(head -n 1 "$hdr")" "200" "selection observation failed: $(cat "$body")"
  python3 - "$body" <<'PY' || fail "live observation did not apply glance selection: $(cat "$body")"
import json, pathlib, sys
obs = json.loads(pathlib.Path(sys.argv[1]).read_text())
shown = [row["title"] for row in obs["needs_you"]["items"]]
hidden = [row["title"] for row in obs["needs_you"]["rest"]]
waiting = [row["title"] for group in obs["waiting"]["groups"] for row in group["items"]]
deferred = [
    "Confirm retiring the Miro rebuild",
    "Align Atelier pricing",
    "User accounts at launch",
]
for title in deferred:
    if any(title in row for row in shown + hidden):
        raise SystemExit("deferred hold leaked into needs you: %s" % title)
if len(shown) != 5:
    raise SystemExit("needs you must cap at 5, got %s" % shown)
# Any queued item held for the captain with a reason and no blockers is a live
# captain call now, whatever the item's own kind, so the ship task held on a
# captain call counts among them: seven live calls, five shown and two behind
# show all.
if obs["needs_you"]["more"] != 2:
    raise SystemExit("two live decisions should remain behind show all, got %s" % obs["needs_you"])
for title in ("Fund worker capacity", "Rotate finances secrets"):
    if title not in " ".join(hidden):
        raise SystemExit("capped decision missing from rest: %s, %s" % (title, hidden))
counts = {group["label"]: group["count"] for group in obs["waiting"]["groups"]}
if counts.get("Atelier") != 1:
    raise SystemExit("Atelier waiting count wrong: %s" % obs["waiting"]["groups"])
if counts.get("Journey") < 2:
    raise SystemExit("Journey waiting count wrong: %s" % obs["waiting"]["groups"])
if any(group["count"] != len(group["items"]) for group in obs["waiting"]["groups"]):
    raise SystemExit("waiting count does not match expanded items")
for title in deferred:
    if not any(title in row for row in waiting):
        raise SystemExit("deferred hold missing from waiting: %s" % waiting)
# A declared `paused:` line is a wake event, not current state: an unverified
# worker runtime reports unknown, so that row belongs under way rather than in a
# waiting group. The page must still name it rather than dropping it.
underway = [row["title"] for row in obs["under_way"]["items"]]
if not any("Waiting on the Atelier vendor" in row for row in underway):
    raise SystemExit("live work with an unreadable state vanished: %s" % underway)
PY
  pass "live observation caps needs you and groups waiting by project"
}

test_multi_file_origin_null_uploads_are_atomic_and_partial() {
  local home fakebin port cookie hdr body count
  home=$(make_home multi-upload)
  fakebin=$(make_fakebin "$home")
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  cookie=$(bridge_cookie "$home" "$port")

  tiny_jpeg "$home/one.jpg"
  tiny_jpeg "$home/two.jpg"
  hdr=$home/one.hdr; body=$home/one.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: null" \
    --header "Sec-Fetch-Site: same-origin" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/one.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "200" "first Origin-null photo must land: $(cat "$body")"

  hdr=$home/two.hdr; body=$home/two.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: null" \
    --header "Sec-Fetch-Site: same-origin" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/two.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "200" "second Origin-null photo must land: $(cat "$body")"

  printf 'GIF89a not-an-image' > "$home/bad.jpg"
  hdr=$home/bad.hdr; body=$home/bad.body
  curl_bridge "$port" /upload "$hdr" "$body" \
    --header "Origin: null" \
    --header "Sec-Fetch-Site: same-origin" \
    --header "Cookie: $cookie" \
    -F "photo=@$home/bad.jpg;type=image/jpeg"
  assert_contains "$(head -n 1 "$hdr")" "415" "failed photo must be reported: $(cat "$body")"

  count=$(find "$home/data/bridge-inbox" -type f -name '*.jpg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "partial failure aborted or dropped good photos, got $count"
  count=$(find "$home/data/bridge-inbox" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected two sidecars after partial failure, got $count"
  python3 - "$home/data/bridge-inbox" <<'PY' || fail "multi-file inbox pairs were not atomic"
import pathlib, sys
inbox = pathlib.Path(sys.argv[1])
stems = sorted(p.stem for p in inbox.glob("*.jpg"))
sides = sorted(p.stem for p in inbox.glob("*.json"))
assert stems == sides, (stems, sides)
assert len(stems) == 2
PY
  pass "multi-file Origin-null uploads land as atomic pairs and report a failed photo"
}

test_unauthenticated_speak_rejected() {
  local home fakebin port hdr body
  home=$(make_home speak-unauth)
  fakebin=$(make_fakebin "$home")
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  tiny_m4a "$home/ask.m4a"
  hdr=$home/unauth.hdr; body=$home/unauth.body
  curl_bridge "$port" /speak "$hdr" "$body" \
    --header "Origin: $ORIGIN" \
    -F "audio=@$home/ask.m4a;type=audio/mp4"
  assert_contains "$(head -n 1 "$hdr")" "401" "unauthenticated speak must be rejected"
  pass "unauthenticated speak is rejected"
}

test_speak_origin_null_forwards_m4a_and_polls_text() {
  local home fakebin port cookie hdr body mbport token request_id page
  home=$(make_home speak-forward)
  fakebin=$(make_fakebin "$home")
  token="bridge-test-relay-token"
  mkdir -p "$home/data/glasses-voice-runtime"
  printf '%s\n' "$token" > "$home/data/glasses-voice-runtime/relay-token"
  python3 - "$home" <<'PY' &
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

home = pathlib.Path(sys.argv[1])
store = home / "mailbox-seen.json"
page = home / "mailbox-page.txt"
store.write_text("[]\n")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _auth_ok(self):
        return self.headers.get("Authorization") == "Bearer bridge-test-relay-token"

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized"})
            return
        payload = json.loads(raw.decode("utf-8"))
        seen = json.loads(store.read_text())
        seen.append(payload)
        store.write_text(json.dumps(seen))
        self._send(202, {"request_id": payload["request_id"]})

    def do_GET(self):
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized"})
            return
        path = urlparse(self.path).path
        prefix = "/v1/answers/"
        if not path.startswith(prefix):
            self._send(404, {"error": "not found"})
            return
        request_id = path[len(prefix):]
        seen = json.loads(store.read_text())
        if not seen or seen[0]["request_id"] != request_id:
            self.send_response(204)
            self.end_headers()
            return
        self._send(200, {
            "kind": "voice-answer",
            "contract_version": "1.0",
            "request_id": request_id,
            "answer_id": "11111111-1111-1111-1111-111111111111",
            "created_at": "2026-08-20T10:00:00Z",
            "text": "Lights are off.",
            "audio": {"media_type": "audio/mpeg", "data_base64": "ZmFrZQ==", "filename": "reply.mp3"},
        })

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(home / "mb.port").write_text(str(server.server_address[1]))
server.serve_forever()
PY
  BRIDGE_PIDS+=("$!")
  n=0
  while [ "$n" -lt 50 ] && [ ! -f "$home/mb.port" ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -f "$home/mb.port" ] || fail "fake mailbox did not bind"
  mbport=$(cat "$home/mb.port")
  init_passcode "$home" >/dev/null
  export FM_BRIDGE_VIEW_MAILBOX_PORT="$mbport"
  port=$(start_bridge "$home" "$fakebin")
  unset FM_BRIDGE_VIEW_MAILBOX_PORT
  cookie=$(bridge_cookie "$home" "$port")
  tiny_m4a "$home/ask.m4a"

  hdr=$home/speak.hdr; body=$home/speak.body
  curl_bridge "$port" /speak "$hdr" "$body" \
    --header "Origin: null" \
    --header "Sec-Fetch-Site: same-origin" \
    --header "Cookie: $cookie" \
    -F "audio=@$home/ask.m4a;type=audio/mp4"
  assert_contains "$(head -n 1 "$hdr")" "200" "Safari-shaped m4a speak must succeed: $(cat "$body")"
  audio_bytes=$(wc -c < "$home/ask.m4a" | tr -d ' ')
  grep -q "speak audio bytes=${audio_bytes}" "$home/bridge/bridge.log" \
    || fail "bridge log must record extracted audio size: $(cat "$home/bridge/bridge.log")"
  printf '%s' "$(cat "$body")" | jq -e '.ok == true and .source == "bridge" and .request_id' >/dev/null \
    || fail "speak JSON missing ok/source/request_id: $(cat "$body")"
  request_id=$(printf '%s' "$(cat "$body")" | jq -r '.request_id')

  python3 - "$home/mailbox-seen.json" "$token" <<'PY' || fail "mailbox did not receive bridge-marked m4a"
import json, pathlib, sys, base64
seen = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert len(seen) == 1, seen
item = seen[0]
audio = item["audio"]
assert audio["filename"] == "bridge.m4a", audio
assert audio["media_type"] == "audio/mp4", audio
raw = base64.b64decode(audio["data_base64"])
assert raw[4:8] == b"ftyp", raw[:16]
assert "source" not in item
PY

  hdr=$home/answer.hdr; body=$home/answer.body
  curl_bridge "$port" "/api/answer/$request_id" "$hdr" "$body" --header "Cookie: $cookie"
  assert_contains "$(head -n 1 "$hdr")" "200" "answer poll must succeed: $(cat "$body")"
  printf '%s' "$(cat "$body")" | jq -e '.pending == false and .text == "Lights are off."' >/dev/null \
    || fail "answer text missing: $(cat "$body")"
  assert_not_contains "$(cat "$body")" "data_base64" "answer poll must not leak audio bytes"
  assert_not_contains "$(cat "$body")" "$token" "answer poll must not leak the relay token"

  page=$home/page.body
  hdr=$home/page.hdr
  curl_bridge "$port" / "$hdr" "$page" --header "Cookie: $cookie"
  assert_not_contains "$(cat "$page")" "$token" "glance HTML must not contain the relay token"
  pass "hold-to-speak forwards Safari m4a server-side and returns answer text"
}

# The Action Deck page: /deck and /api/deck sit behind the same session, Host
# and header rules as the glance, render the fm-deck.v1 model bin/fm-deck.sh
# --json emits (never a second derivation of "what needs him"), follow only
# ordinary HTTPS links, and expose no approve, run, or merge control.
install_deck_fixture() {  # <home> <fakebin>
  local home=$1 fakebin=$2
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = list ] || exit 0
printf 'count: 4\n'
printf 'tasks[4]{id,state,kind,repo,title,hold_kind,hold_reason,links,closed,blocked_by,held,priority}:\n'
printf '  review-task,in_flight,ship,firstmate,"Spoken updates on the glasses","-","-","pr:https://github.com/kunchenguid/firstmate/pull/9","-",none,no,"-"\n'
printf '  lab-task,in_flight,ship,atelier,"Refresh the Atelier brand page","-","-","pr:https://gitlab.example/atelier/site/-/merge_requests/3","-",none,no,"-"\n'
printf '  captain-q,queued,captain,firstmate,"Add Qwen to the fleet?",captain,"captain choice pending",none,"-",none,yes,"-"\n'
printf '  done-scout,done,scout,firstmate,"Investigate the delta timeouts","-","-","report:data/done-scout/report.md",2026-09-01,none,no,"-"\n'
SH
  chmod +x "$fakebin/tasks-axi"
  mkdir -p "$home/data/action-gateway" "$home/data/orders"
  cat > "$home/data/action-gateway/action-audit.log" <<'JSONL'
{"ts":1700000000,"event":"prepared","state":"prepared","request_id":"r-1","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expires_at":4100000000,"requester_id":"worker-1","request":{"task_id":"t-1","domain":"fota","action_kind":"device.firmware.push","target":"device://867280068649789","parameters":{},"idempotency_key":"i-1","expires_at":4100000000,"nonce":"n-1","requester_id":"worker-1"}}
JSONL
  cat > "$home/data/orders/fota.md" <<'EOF'
# Firmware rollout

Status: ARMED (captain 2026-09-01)

Watch: the canary fleet.
EOF
  fm_write_meta "$home/state/review-task.meta" \
    "window=firstmate:fm-review-task" \
    "project=firstmate" \
    "kind=ship" \
    "outcome=Spoken updates on the glasses" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'working: pushed the branch\n' > "$home/state/review-task.status"
  fm_write_meta "$home/state/finished-task.meta" \
    "window=firstmate:fm-finished-task" \
    "project=firstmate" \
    "kind=ship" \
    "outcome=Photo drops from the phone"
  printf 'done: landed\n' > "$home/state/finished-task.status"
}

test_deck_page_and_api() {
  local home fakebin port cookie hdr body before after n
  home=$(make_home deck)
  fakebin=$(make_fakebin "$home")
  install_deck_fixture "$home" "$fakebin"
  init_passcode "$home" >/dev/null
  port=$(start_bridge "$home" "$fakebin")
  hdr=$home/deck.hdr; body=$home/deck.body

  curl_bridge "$port" /deck "$hdr" "$body"
  grep -q '^HTTP/1.1 200' "$hdr" || fail "unauthenticated /deck did not return the login page: $(cat "$hdr")"
  grep -q 'action="/login"' "$body" || fail "unauthenticated /deck did not show Log in"
  if grep -q 'id="staged"' "$body"; then fail "unauthenticated /deck leaked the deck page"; fi
  curl_bridge "$port" /api/deck "$hdr" "$body"
  grep -q '^HTTP/1.1 401' "$hdr" || fail "unauthenticated /api/deck was not 401: $(cat "$hdr")"

  cookie=$(bridge_cookie "$home" "$port")
  curl_bridge "$port" / "$hdr" "$body" --header "Cookie: $cookie"
  grep -q 'href="/deck"' "$body" || fail "glance page has no Action Deck nav entry"

  curl_bridge "$port" /deck "$hdr" "$body" --header "Cookie: $cookie"
  grep -q '^HTTP/1.1 200' "$hdr" || fail "authenticated /deck failed: $(cat "$hdr")"
  grep -q '<title>ACTION DECK</title>' "$body" || fail "deck page title missing"
  grep -q 'href="/"' "$body" || fail "deck page has no way back to the glance"
  grep -q 'id="staged"' "$body" || fail "deck page has no staged region"
  grep -q 'id="decisions-section" hidden' "$body" || fail "held decisions are not folded away by default"
  grep -q 'View only. Nothing on this page approves, runs, or merges.' "$body" || fail "deck page lacks the view-only line"
  n=$(grep -o '<button' "$body" | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "deck page carries $n buttons; only Log out is allowed"
  grep -qi 'content-security-policy:.*script-src .nonce-' "$hdr" || fail "deck page lacks the nonce CSP"

  before=$(fingerprint "$home")
  curl_bridge "$port" /api/deck "$hdr" "$body" --header "Cookie: $cookie"
  after=$(fingerprint "$home")
  grep -q '^HTTP/1.1 200' "$hdr" || fail "authenticated /api/deck failed: $(cat "$hdr"; cat "$body")"
  grep -qi '^content-type: application/json' "$hdr" || fail "/api/deck is not JSON"
  grep -qi '^cache-control: no-store' "$hdr" || fail "/api/deck is cacheable"
  [ "$before" = "$after" ] || fail "reading /api/deck changed fleet records"

  jq -e '.schema == "fm-deck.v1"' "$body" >/dev/null || fail "/api/deck is not the fm-deck.v1 model: $(cat "$body")"
  jq -e '.ready == []' "$body" >/dev/null || fail "ready-to-run invented an action: $(cat "$body")"
  jq -e '.ready_note | test("not wired")' "$body" >/dev/null || fail "ready note does not say running is unwired"
  [ "$(jq -r '.staged.groups[0].order' "$body")" = fota ] || fail "staged group missing: $(cat "$body")"
  [ "$(jq -r '.staged.groups[0].status' "$body")" = ARMED ] || fail "order status missing: $(cat "$body")"
  [ "$(jq -r '.staged.groups[0].cards[0].action_kind' "$body")" = device.firmware.push ] || fail "staged card kind: $(cat "$body")"
  [ "$(jq -r '.staged.groups[0].cards[0].target' "$body")" = 'device://867280068649789' ] || fail "staged card target: $(cat "$body")"
  jq -e '.staged.groups[0].cards[0] | has("url") | not' "$body" >/dev/null || fail "a device:// target became a link"
  jq -e '.staged.missing | test("captain secret") and test("executor")' "$body" >/dev/null || fail "staged cards do not say what is missing"

  # Live asks and held decisions are two lists; a pull request appears once
  # however many records carry it; only https links are followable.
  [ "$(jq -r '[.asks[] | select(.url == "https://github.com/kunchenguid/firstmate/pull/9")] | length' "$body")" = 1 ] \
    || fail "the shared pull request is not exactly one ask: $(cat "$body")"
  [ "$(jq -r '[.asks[] | select(.url == "https://gitlab.example/atelier/site/-/merge_requests/3")] | length' "$body")" = 1 ] \
    || fail "an ordinary https source link was not kept: $(cat "$body")"
  [ "$(jq -r '.decisions | length' "$body")" = 1 ] || fail "one held decision: $(cat "$body")"
  [ "$(jq -r '.decisions[0].ask' "$body")" = decide ] || fail "held decision ask: $(cat "$body")"
  jq -e '[.asks[].ask] | index("decide") == null' "$body" >/dev/null || fail "a held decision leaked into live asks"
  [ "$(jq -r '.counts.asks' "$body")" = "$(jq -r '.asks | length' "$body")" ] || fail "asks count disagrees"

  # Completed work sits apart from work under way, and a local artifact is a
  # reference, never a link.
  [ "$(jq -r '[.under_way[].outcome] | index("Photo drops from the phone")' "$body")" = null ] || fail "a finished worker is listed as under way"
  [ "$(jq -r '.finished[0].outcome' "$body")" = 'Photo drops from the phone' ] || fail "finished worker missing: $(cat "$body")"
  [ "$(jq -r '.under_way[0].label' "$body")" = WORKING ] || fail "under-way label: $(cat "$body")"
  [ "$(jq -r '.landed[0].ref' "$body")" = 'data/done-scout/report.md' ] || fail "report artifact is not a plain reference: $(cat "$body")"
  jq -e '.landed[0] | has("url") | not' "$body" >/dev/null || fail "a data/ path became a link"
  jq -e '[.asks[].title, .under_way[].outcome] | index("Investigate the delta timeouts") == null' "$body" >/dev/null \
    || fail "completed work leaked into the actionable lists"
  pass "deck page and api sit behind the session, render the deck model, vet links, and act on nothing"
}

test_deck_api_reports_desk_unreachable() {
  local home fakebin fixture port cookie hdr body log
  home=$(make_home deck-error)
  fakebin=$(make_fakebin "$home")
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-deck.sh" <<'SH'
#!/usr/bin/env bash
echo "deck collector exploded" >&2
exit 1
SH
  chmod +x "$fixture/bin/fm-deck.sh"
  init_passcode "$home" >/dev/null
  log=$home/bridge-serve.log
  : > "$log"
  FM_BRIDGE_VIEW_TEST=1 FM_BRIDGE_VIEW_LAUNCHCTL="$fakebin/launchctl" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fixture" \
    "$BRIDGE" serve --host "$HOST_NAME" --port 0 >"$log" 2>&1 &
  BRIDGE_PIDS+=("$!")
  port=$(wait_listening "$log")
  cookie=$(bridge_cookie "$home" "$port")
  hdr=$home/deck.hdr; body=$home/deck.body
  curl_bridge "$port" /api/deck "$hdr" "$body" --header "Cookie: $cookie"
  grep -q '^HTTP/1.1 503' "$hdr" || fail "a failing deck read was not 503: $(cat "$hdr")"
  [ "$(jq -r '.error' "$body")" = 'desk unreachable' ] || fail "503 body: $(cat "$body")"
  jq -e '.detail | test("deck collector exploded")' "$body" >/dev/null || fail "503 lost the reason: $(cat "$body")"
  pass "a failing deck read is an honest 503 with its reason, not an empty deck"
}

test_deck_page_renders_states_without_run_controls() {
  local output
  output=$(node - "$ROOT/bin/fm-bridge-view.py" <<'JS'
const {execFileSync} = require('child_process');
const vm = require('vm');
const script = execFileSync('python3', ['-', process.argv[2]], {
  input: `import importlib.util, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.DECK_JS)
`,
  encoding: 'utf8'
});
const ids = ['ready', 'staged', 'asks', 'decisions', 'underway', 'landed', 'loose',
  'ready-count', 'staged-count', 'asks-count', 'underway-count', 'landed-count',
  'deck-observed', 'deck-counts', 'deck-error', 'decisions-section', 'loose-section'];
const elements = {};
for (const id of ids) elements[id] = {innerHTML: '', textContent: 'Loading…', hidden: false};
let overlayOn = false;
elements.stale = {classList: {toggle(name, on) { overlayOn = !!on; }}};
const context = vm.createContext({
  document: {hidden: false, addEventListener() {}, getElementById(id) { return elements[id] || null; }},
  window: {addEventListener() {}}, Date, setInterval() {}, setTimeout, clearTimeout,
  AbortController: class { constructor() { this.signal = {}; } abort() {} },
  fetch: async function() {
    return {ok: false, status: 503, json: async function() { return {error: 'desk unreachable', detail: 'deck collector exploded: tray log unreadable'}; }};
  }
});
vm.runInContext(script, context);
const apply = vm.runInContext('apply', context);
apply({
  home: 'Starship',
  ready: [],
  ready_note: 'Running from this page is not wired yet.',
  staged: {
    groups: [{order: 'fota', count: 1, oldest: '3d', status: 'ARMED', last_fire: '-', cards: [
      {digest_short: 'aaaaaaaaaaaa', action_kind: 'device.firmware.push', target: 'device://867280068649789', requester_id: 'worker-1', age: '3d', expiry: 'expires in 2h', expired: false}
    ]}],
    quiet_orders: [{order: 'spares', status: 'DRAFT', last_fire: '-'}],
    missing: 'Approval needs the captain secret on the desk.'
  },
  asks: [
    {ask: 'review', title: 'Spoken updates on the glasses', project: 'firstmate', url: 'https://github.com/acme/alpha/pull/7'},
    {ask: 'answer', title: 'Rework the beta importer <script>', project: 'Alpha'},
    {ask: 'check', title: 'Photo drops', project: 'firstmate', ref: 'javascript:alert(1)'}
  ],
  decisions: [{ask: 'decide', title: 'Add Qwen to the fleet?', project: 'firstmate'}, {ask: 'decide', title: 'Authorise the Sweden field visit', project: 'Alpha'}],
  backlog_reason: null,
  unconfirmed: true,
  under_way: [{outcome: 'Ship the alpha widget', project: 'Alpha', state: 'working', label: 'WORKING', heard_secs: 120}],
  finished: [{outcome: 'Land the gamma migration', project: 'Alpha', state: 'done', label: 'READY', heard_secs: 3600}],
  landed: [{closed: '2026-09-01', what: 'findings', title: 'Investigate the delta timeouts', ref: 'data/done-scout/report.md'}],
  loose_ends: {path: 'data/loose-ends/latest.md', age_secs: 7200, title: 'Loose Ends - Thursday', total: 16, items: [{bucket: 'urgent', text: 'Reply to Jordan'}]},
  counts: {asks: 3, decisions: 2, staged: 1, staged_oldest: '3d', under_way: 1, finished: 1, loose_ends: 16}
});
function must(cond, msg) { if (!cond) throw new Error(msg); }
const all = ids.map(function(id) { return elements[id].innerHTML; }).join('\n');
must(all.indexOf('<button') === -1, 'the deck rendered a button: ' + all);
must(all.indexOf('javascript:') === -1, 'a non-https reference became a link: ' + all);
must(elements.staged.innerHTML.indexOf('needs approval') !== -1, 'staged card lacks the approval badge: ' + elements.staged.innerHTML);
must(elements.staged.innerHTML.indexOf('device.firmware.push') !== -1, 'staged card lacks its kind');
must(elements.staged.innerHTML.indexOf('Not available here: Approval needs the captain secret') !== -1, 'staged section does not say what is missing');
must(elements.staged.innerHTML.indexOf('Watching, nothing staged: spares DRAFT') !== -1, 'quiet order missing');
must(elements.ready.innerHTML.indexOf('Nothing is ready to run from here.') !== -1, 'ready section is not honest: ' + elements.ready.innerHTML);
must(elements.asks.innerHTML.indexOf('<a href="https://github.com/acme/alpha/pull/7" target="_blank" rel="noopener noreferrer">') !== -1, 'https ask link missing: ' + elements.asks.innerHTML);
must(elements.asks.innerHTML.indexOf('&lt;script&gt;') !== -1, 'title was not escaped: ' + elements.asks.innerHTML);
must(elements.asks.innerHTML.indexOf('Not confirmed here') !== -1, 'unconfirmed caveat missing');
must(elements.asks.innerHTML.indexOf('Add Qwen') === -1, 'a held decision was listed as a live ask');
must(elements['decisions-section'].hidden === false, 'held decisions section stayed hidden');
must(elements.decisions.innerHTML.indexOf('2 held decisions') !== -1, 'held decisions fold missing: ' + elements.decisions.innerHTML);
const uw = elements.underway.innerHTML;
must(uw.indexOf('Ship the alpha widget') !== -1, 'under-way row missing');
must(uw.indexOf('1 finished, awaiting cleanup') !== -1, 'finished fold missing: ' + uw);
must(uw.indexOf('Land the gamma migration') > uw.indexOf('<details'), 'finished work rendered in the live list');
must(elements.landed.innerHTML.indexOf('data/done-scout/report.md') !== -1 && elements.landed.innerHTML.indexOf('href="data/') === -1, 'report path rendered as a link');
must(elements['loose-section'].hidden === false && elements.loose.innerHTML.indexOf('Reply to Jordan') !== -1, 'loose ends missing');
must(elements['deck-counts'].textContent === '3 need you · 1 staged · 2 held decisions · 1 under way', 'counts line: ' + elements['deck-counts'].textContent);
must(elements['deck-observed'].textContent.indexOf('Read at an unknown time') === 0, 'missing sample time not reported as unknown: ' + elements['deck-observed'].textContent);

apply({home: 'Starship', read_at: Math.floor(Date.now() / 1000) - 42, server_unix: Math.floor(Date.now() / 1000), ready: [], staged: {groups: [], quiet_orders: []}, asks: [], decisions: [], under_way: [], finished: [], landed: [], loose_ends: null, counts: {}});
must(/^Read 4[123] seconds ago · from the records Starship keeps$/.test(elements['deck-observed'].textContent), 'header age not taken from the collector sample: ' + elements['deck-observed'].textContent);
vm.runInContext('tickObserved', context)();
must(/^Read 4[123] seconds ago · from the records Starship keeps$/.test(elements['deck-observed'].textContent), 'tick did not keep the sampled age: ' + elements['deck-observed'].textContent);

apply({home: 'Starship', ready: [], staged: {groups: [], quiet_orders: []}, asks: [], decisions: [], under_way: [], finished: [], landed: [], loose_ends: null, counts: {}});
must(elements.staged.innerHTML.indexOf('Nothing is staged for you right now.') !== -1, 'empty staged copy');
must(elements.asks.innerHTML.indexOf('Nothing is waiting on you.') !== -1, 'empty asks copy');
must(elements.underway.innerHTML.indexOf('No work under way.') !== -1, 'empty under-way copy');
must(elements.landed.innerHTML.indexOf('Nothing has landed recently.') !== -1, 'empty landed copy');
must(elements['decisions-section'].hidden === true, 'empty held decisions section is not hidden');
must(elements['loose-section'].hidden === true, 'absent sweep section is not hidden');

for (const id of ['ready', 'staged', 'asks', 'underway', 'landed']) { elements[id].textContent = 'Loading…'; }
vm.runInContext('markUnreachable', context)('deck collector exploded');
must(elements.staged.innerHTML.indexOf('Cannot reach the desk.') !== -1, 'unreachable state not rendered');
must(elements['deck-error'].textContent === 'deck collector exploded', 'error detail not shown');

// A 503 on first load must leave the reason visible: no full-page overlay over it.
vm.runInContext('lastSuccess = 0', context);
for (const id of ['ready', 'staged', 'asks', 'underway', 'landed']) { elements[id].textContent = 'Loading…'; elements[id].innerHTML = ''; }
elements['deck-error'].textContent = '';
vm.runInContext('refresh', context)().then(function() {
  must(overlayOn === false, 'first-load 503 raised the full-page overlay, hiding the reason');
  must(elements['deck-observed'].textContent === 'Cannot reach the desk.', 'header did not report the unreachable desk: ' + elements['deck-observed'].textContent);
  must(elements.ready.innerHTML.indexOf('Cannot reach the desk.') !== -1, 'regions did not report the unreachable desk');
  must(elements['deck-error'].textContent === 'deck collector exploded: tray log unreadable', '503 reason not shown: ' + elements['deck-error'].textContent);
}).catch(function(err) { console.error(err.message); process.exit(1); });
JS
  ) || fail "deck page rendering failed: $output"
  pass "deck page renders staged, asks, held decisions, under way, landed and loose ends with no run control"
}


test_bind_is_loopback_constant
test_funnel_on_refuses_to_serve
test_funnel_off_serve_starts
test_funnel_off_legacy_serve_output_starts
test_unverifiable_funnel_refuses_to_serve
test_lan_and_unauthorized_hosts_are_rejected
test_auth_cookie_headers_and_isolation
test_safari_login_without_origin_and_keepalive_body_drain
test_snapshot_subprocess_does_not_write_fleet_state
test_snapshot_output_is_bounded_during_capture
test_snapshot_requests_complete_glance_rows
test_bridge_page_async_progress_and_release
test_bridge_page_speak_assembles_chunks_and_rejects_tiny
test_session_revoke_serializes_with_login_create
test_away_mode_passive_refresh_works
test_mailbox_listener_never_consumes_announcements
test_render_plist_keep_alive_pattern
test_unauthenticated_upload_rejected
test_upload_rejects_oversize_non_image_and_rates
test_inbox_unique_names_never_overwrite
test_inbox_pair_failure_leaves_no_partial_upload
test_photos_received_today_counts_utc_sidecars
test_child_path_resolves_tool_dirs_without_hardcoded_nvm
test_glance_page_pinned_links
test_observation_error_fails_fast_and_keeps_photo_count
test_scrubbed_snapshot_with_herdr_meta_fails_fast
test_human_titles_drop_internal_primary_lines
test_needs_you_excludes_deferred_holds_and_caps_at_five
test_waiting_groups_by_project_counts
test_glance_page_renders_chips_and_needs_remainder
test_routing_projection_joins_live_rows
test_routing_failure_leaves_glance_whole
test_observation_carries_routing_from_local_records
test_glance_page_renders_routing
test_memory_reads_only_allowlisted_sources
test_memory_withholds_gift_blocks_after_any_lead_in
test_observation_carries_memory_without_writes
test_glance_page_renders_memory
test_observation_selects_and_groups_live_backlog
test_multi_file_origin_null_uploads_are_atomic_and_partial
test_unauthenticated_speak_rejected
test_speak_origin_null_forwards_m4a_and_polls_text
test_deck_page_and_api
test_deck_api_reports_desk_unreachable
test_deck_page_renders_states_without_run_controls

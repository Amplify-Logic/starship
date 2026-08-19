#!/usr/bin/env bash
# Behavior tests for the phone bridge view: loopback bind, Tailscale Funnel
# refusal, Host/Origin checks including Safari form POSTs that omit Origin
# or send Origin: null, session cookie isolation from port 8765, read-only
# snapshot subprocess, away-mode passive refresh, auth headers, authenticated
# photo drops into the quarantined inbox, and keep-alive body drain after
# early error returns.
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

start_bridge() {  # <home> <fakebin>
  local home=$1 fakebin=$2 log
  log=$home/bridge-serve.log
  : > "$log"
  FM_BRIDGE_VIEW_TEST=1 FM_BRIDGE_VIEW_LAUNCHCTL="$fakebin/launchctl" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
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
  assert_contains "$(cat "$body")" "Send a photo" "glance page missing the photo drop"
  assert_contains "$(cat "$body")" "capture=\"environment\"" "photo input must allow camera capture"
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

test_snapshot_requests_all_in_flight_rows() {
  local home fixture output
  home=$(make_home snapshot-all-in-flight)
  fixture=$home/root
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --all-in-flight '*) printf '%s\n' '{"schema":"fm-bearings.v1"}' ;;
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
  ) || fail "bridge snapshot did not request every in-flight row: $output"
  pass "snapshot requests all in-flight rows before bucket classification"
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
test_snapshot_requests_all_in_flight_rows
test_session_revoke_serializes_with_login_create
test_away_mode_passive_refresh_works
test_mailbox_listener_never_consumes_announcements
test_render_plist_keep_alive_pattern
test_unauthenticated_upload_rejected
test_upload_rejects_oversize_non_image_and_rates
test_inbox_unique_names_never_overwrite
test_inbox_pair_failure_leaves_no_partial_upload

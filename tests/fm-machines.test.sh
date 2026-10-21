#!/usr/bin/env bash
# Behavior tests for bin/fm-machines.py: tailnet machines from
# `tailscale status --json` (Mullvad exit nodes dropped, a phone named by its
# MagicDNS label), this machine's own numbers, configured machines read over
# ssh only when not known to be offline, Linux and Darwin report parsing,
# failed systemd units, disk alerts, loopback services, HTTPS probes, the
# health count, skipped config lines, the unknown and unreachable paths, slow
# reads held to the collector's deadline, last-seen wording, and no write
# leaving the read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-machines.py"
TMP_ROOT=$(fm_test_tmproot fm-machines)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SERVER_PIDS=()
fm_machines_cleanup() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap fm_machines_cleanup EXIT

NOW=$(date +%s)
iso_ago() {  # <seconds> -> RFC 3339 UTC time that many seconds ago
  python3 -c 'import sys, datetime; t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1])); print(t.strftime("%Y-%m-%dT%H:%M:%S.5Z"))' "$1"
}

# A closed loopback port: bound once, then released.
closed_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# A loopback HTTP server answering /health with 200 and anything else with 503.
start_health_server() {  # <portfile>
  python3 - "$1" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/health" else 503)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
  SERVER_PIDS+=("$!")
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -s "$1" ] || fail "health server did not start"
}

# A loopback server that accepts and then either never answers (hang) or
# trickles one header byte a second forever (trickle).
start_slow_server() {  # <hang|trickle> <portfile>
  python3 - "$1" "$2" <<'PY' &
import socket, sys, threading, time
mode, portfile = sys.argv[1], sys.argv[2]
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(16)
with open(portfile, "w") as handle:
    handle.write(str(server.getsockname()[1]))
held = []
def trickle(conn):
    try:
        conn.sendall(b"HTTP/1.1 200 OK\r\nX-Slow: ")
        while True:
            conn.sendall(b"a")
            time.sleep(1)
    except OSError:
        pass
while True:
    conn, _ = server.accept()
    held.append(conn)
    if mode == "trickle":
        threading.Thread(target=trickle, args=(conn,), daemon=True).start()
PY
  SERVER_PIDS+=("$!")
  local n=0
  while [ ! -s "$2" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -s "$2" ] || fail "$1 server did not start"
}

write_tailnet() {  # <file>
  cat > "$1" <<JSON
{
  "BackendState": "Running",
  "Self": {"HostName": "Studio Mac", "DNSName": "studio-mac.example.ts.net.", "OS": "macOS", "Online": true,
           "TailscaleIPs": ["100.64.0.1", "fd7a::1"], "LastSeen": "0001-01-01T00:00:00Z"},
  "Peer": {
    "k1": {"HostName": "build-vps", "DNSName": "build-vps.example.ts.net.", "OS": "linux", "Online": true,
           "TailscaleIPs": ["fd7a::2", "100.64.0.2"], "LastSeen": "0001-01-01T00:00:00Z"},
    "k2": {"HostName": "dell-laptop", "DNSName": "dell-laptop.example.ts.net.", "OS": "linux", "Online": false,
           "TailscaleIPs": ["100.64.0.3"], "LastSeen": "$(iso_ago 259200)"},
    "k3": {"HostName": "localhost", "DNSName": "phone.example.ts.net.", "OS": "iOS", "Online": false,
           "TailscaleIPs": ["100.64.0.4"], "LastSeen": "$(iso_ago 7200)"},
    "k4": {"HostName": "mini", "DNSName": "mini.example.ts.net.", "OS": "macOS", "Online": true,
           "TailscaleIPs": ["100.64.0.6"], "LastSeen": "0001-01-01T00:00:00Z"},
    "k5": {"HostName": "nl-ams-wg-001", "DNSName": "nl-ams-wg-001.mullvad.ts.net.", "OS": "linux", "Online": true,
           "TailscaleIPs": ["100.64.9.9"]}
  }
}
JSON
}

# fakebin with a tailscale that prints $TAILNET_FIXTURE (or fails) and an ssh
# that logs its arguments and answers per alias from $SSH_FIXTURES/<alias>.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tailscale" <<'SH'
#!/usr/bin/env bash
[ "$*" = "status --json" ] || exit 2
if [ -n "${TAILNET_FAIL:-}" ]; then
  printf '%s\n' "$TAILNET_FAIL" >&2
  exit 1
fi
cat "$TAILNET_FIXTURE"
SH
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
cat > /dev/null
alias=""
for arg in "$@"; do
  if [ "$prev" = "--" ]; then alias=$arg; fi
  prev=$arg
done
if [ -f "$SSH_FIXTURES/$alias.sleep" ]; then
  sleep "$(cat "$SSH_FIXTURES/$alias.sleep")"
fi
if [ -f "$SSH_FIXTURES/$alias" ]; then
  cat "$SSH_FIXTURES/$alias"
  exit 0
fi
printf 'ssh: connect to host %s port 22: Operation timed out\n' "$alias" >&2
exit 255
SH
  chmod +x "$fb/tailscale" "$fb/ssh"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/agents" "$home/ssh"
  write_tailnet "$home/tailnet.json"
  : > "$home/ssh.log"
  printf '%s\n' "$home"
}

snapshot() {  # <home> <fakebin> [extra args...]
  local home=$1 fb=$2
  shift 2
  TAILNET_FIXTURE="$home/tailnet.json" SSH_LOG="$home/ssh.log" SSH_FIXTURES="$home/ssh" \
    FM_MACHINES_LAUNCH_AGENTS="$home/agents" \
    "$TOOL" --json --home "$home" --root "$home" \
    --tailscale "$fb/tailscale" --ssh "$fb/ssh" --bridge-port "${BRIDGE_PORT:-$(closed_port)}" "$@"
}

fingerprint() { (cd "$1" && find config state data -type f -print | LC_ALL=C sort | xargs cksum); }

test_tailnet_without_config() {
  local home fb out
  home=$(make_home bare)
  fb=$(make_fakebin "$home")
  out=$(snapshot "$home" "$fb") || fail "snapshot without config exited non-zero"
  assert_equals 'fm-machines.v1' "$(jq -r .schema <<<"$out")" "schema"
  assert_equals 'false []' "$(jq -c '[.config.present, .config.skipped] | "\(.[0]) \(.[1])"' -r <<<"$out")" "absent config"
  assert_equals 'Studio Mac true true 100.64.0.1 macOS' \
    "$(jq -r '.this | "\(.name) \(.self) \(.online) \(.ip) \(.os)"' <<<"$out")" "this machine from the tailnet"
  assert_equals 'build-vps,mini,dell-laptop,phone' "$(jq -r '[.machines[].name] | join(",")' <<<"$out")" \
    "peers listed live first, Mullvad dropped, phone named by its MagicDNS label"
  assert_equals '100.64.0.2' "$(jq -r '.machines[] | select(.name == "build-vps") | .ip' <<<"$out")" "IPv4 preferred"
  jq -e --argjson now "$NOW" '.machines[] | select(.name == "dell-laptop") | .online == false and (.last_seen > $now - 259300) and (.last_seen < $now - 259100)' <<<"$out" >/dev/null \
    || fail "offline peer lacks its last seen time: $out"
  jq -e '.machines[] | select(.name == "build-vps") | .last_seen == null' <<<"$out" >/dev/null || fail "a live peer carries a last seen time"
  assert_equals '0' "$(jq '.alerts | map(select(.text | test("offline"))) | length' <<<"$out")" "unwatched offline machines raise no alert"
  assert_equals '0' "$(jq '.machines | map(select(.stats != null)) | length' <<<"$out")" "unwatched machines are not read"
  [ ! -s "$home/ssh.log" ] || fail "ssh ran without any configured machine: $(cat "$home/ssh.log")"
  assert_equals '[]' "$(jq -c '.services' <<<"$out")" "uninstalled, silent services are not listed"
  jq -e '.this.stats | (.cpus == null or (.cpus | type) == "number") and (.disk_pct == null or (.disk_pct >= 0 and .disk_pct <= 100))' <<<"$out" >/dev/null \
    || fail "this machine's numbers are neither a reading nor unknown: $out"
  pass "without config the snapshot lists the tailnet and this machine and reads nothing over ssh"
}

test_configured_machines_services_and_probes() {
  local home fb out before after health_port portfile probe_port
  home=$(make_home configured)
  fb=$(make_fakebin "$home")
  portfile=$home/health.port
  start_health_server "$portfile"
  health_port=$(cat "$portfile")
  probe_port=$(closed_port)
  cat > "$home/ssh/vps" <<'EOF'
os Linux
now 1792190000
ncpu 4
loadavg 6.12 0.37 0.30
mem MemTotal:        8000000 kB
mem MemAvailable:    2000000 kB
uptime 1209600.55
df /dev/vda1 1000000 950000 50000 95% /
systemd yes
failed NetworkManager-wait-online.service
failed backup.timer
EOF
  cat > "$home/ssh/mini" <<'EOF'
os Darwin
now 1792190000
ncpu 8
loadavg  1.50 1.20 1.00
memtotal 17179869184
boottime 1792100000
vm Mach Virtual Memory Statistics: (page size of 16384 bytes)
vm Pages free:                                     9027.
vm Pages active:                                 212550.
vm Pages wired down:                             262144.
vm Pages purgeable:                                1000.
vm Anonymous pages:                              263144.
vm Pages occupied by compressor:                 262144.
df /dev/disk3s5   482797652 241398826 241398826    50%    /System/Volumes/Data
EOF
  printf '%s\t%s\t%s\n' \
    machine dell-laptop dell \
    machine build-vps vps \
    machine MINI mini \
    machine lan-box lan-box \
    probe 'Shop site' "https://127.0.0.1:$probe_port/" \
    service 'Voice bridge' "http://127.0.0.1:$health_port/health" \
    service 'Dead helper' "http://127.0.0.1:$health_port/broken" \
    probe 'Plain site' 'http://example.com/' \
    service 'Remote thing' 'http://example.com/health' > "$home/config/bridge-machines"
  printf 'machine\tbad\t-oProxyCommand=evil\n# a comment\n\nmachine\n' >> "$home/config/bridge-machines"
  printf 'machine\tghost\n' >> "$home/config/bridge-machines"

  before=$(fingerprint "$home")
  out=$(BRIDGE_PORT=$health_port snapshot "$home" "$fb") || fail "configured snapshot exited non-zero"
  after=$(fingerprint "$home")
  [ "$before" = "$after" ] || fail "the snapshot wrote to the home"

  # ssh: only aliases not known offline, always non-interactive with a timeout.
  grep -q -- '-- vps sh -s' "$home/ssh.log" || fail "the live watched machine was not read: $(cat "$home/ssh.log")"
  grep -q -- '-- lan-box sh -s' "$home/ssh.log" || fail "the machine off the tailnet was not tried over ssh"
  if grep -q -- '-- dell' "$home/ssh.log"; then fail "ssh tried a machine the tailnet reports offline"; fi
  if grep -q -- 'evil' "$home/ssh.log"; then fail "an option-shaped alias reached ssh"; fi
  grep -q -- '-o BatchMode=yes -o ConnectTimeout=4' "$home/ssh.log" || fail "ssh can prompt or hang: $(cat "$home/ssh.log")"

  # Linux report.
  assert_equals '[6.12,0.37,0.3] 4 153 75 8192000000 95 1209600' \
    "$(jq -r '.machines[] | select(.name == "build-vps") | .stats | "\(.load | tojson) \(.cpus) \(.load_pct) \(.mem_pct) \(.mem_total) \(.disk_pct) \(.uptime_secs)"' <<<"$out")" \
    "Linux numbers"
  assert_equals 'true true' "$(jq -r '.machines[] | select(.name == "build-vps") | "\(.watched) \(.ssh)"' <<<"$out")" "watched with ssh"
  assert_equals 'NetworkManager-wait-online.service,backup.timer' \
    "$(jq -r '.machines[] | select(.name == "build-vps") | .stats.failed_units | join(",")' <<<"$out")" "failed units"

  # Darwin report: app (anonymous - purgeable) + wired + compressed.
  assert_equals 'macOS 75 50 90000 null' \
    "$(jq -r '.machines[] | select(.name == "mini") | .stats | "\(.os) \(.mem_pct) \(.disk_pct) \(.uptime_secs) \(.failed_units)"' <<<"$out")" \
    "Darwin numbers, matched case-insensitively"

  # Offline and unreachable machines.
  assert_equals 'false offline, so not read' \
    "$(jq -r '.machines[] | select(.name == "dell-laptop") | "\(.online) \(.stats_error)"' <<<"$out")" "offline watched machine"
  assert_equals 'ssh null' \
    "$(jq -r '.machines[] | select(.name == "lan-box") | "\(.link) \(.online)"' <<<"$out")" "unreachable machine off the tailnet is unknown"
  jq -e '.machines[] | select(.name == "lan-box") | .stats_error | test("Operation timed out")' <<<"$out" >/dev/null \
    || fail "ssh failure reason lost: $out"
  assert_equals 'null not seen on the tailnet and no ssh alias to try' \
    "$(jq -r '.machines[] | select(.name == "ghost") | "\(.online) \(.stats_error)"' <<<"$out")" "a name with no alias and no tailnet entry"

  # Services: built-ins answering here, then the config's own.
  assert_equals 'Bridge page:true,Voice bridge:true,Dead helper:false' \
    "$(jq -r '[.services[] | "\(.name):\(.up)"] | join(",")' <<<"$out")" "services"

  # Probe failing.
  jq -e '.probes[0] | .label == "Shop site" and .ok == false and .status == null and (.error | length > 0) and .host == "127.0.0.1"' <<<"$out" >/dev/null \
    || fail "failing probe: $(jq -c .probes <<<"$out")"

  # Skipped lines are named; nothing malformed is used.
  assert_equals '4' "$(jq '.config.skipped | length' <<<"$out")" "skipped lines: $(jq -c .config.skipped <<<"$out")"
  jq -e '.config.skipped | any(test("probe must be an https URL")) and any(test("loopback")) and any(test("plain host alias"))' <<<"$out" >/dev/null \
    || fail "skip reasons: $(jq -c .config.skipped <<<"$out")"

  # Health: 5 watched machines (2 reachable) + 3 services (2 up) + 1 probe (0 ok).
  assert_equals '4 9' "$(jq -r '"\(.checks.passing) \(.checks.total)"' <<<"$out")" "health count"
  jq -e '.alerts | any(.severity == "critical" and (.text | test("^dell-laptop is offline, last seen 3 days ago$")))' <<<"$out" >/dev/null || fail "offline alert: $(jq -c .alerts <<<"$out")"
  jq -e '.alerts | any(.severity == "critical" and (.text | test("^lan-box cannot be reached")))' <<<"$out" >/dev/null || fail "unreachable alert"
  jq -e '.alerts | any(.severity == "critical" and .text == "Dead helper is down: status 503")' <<<"$out" >/dev/null || fail "service alert: $(jq -c .alerts <<<"$out")"
  jq -e '.alerts | any(.severity == "critical" and (.text | test("^Shop site probe failing")))' <<<"$out" >/dev/null || fail "probe alert"
  jq -e '.alerts | any(.severity == "warning" and .text == "2 systemd units have failed on build-vps: NetworkManager-wait-online.service, backup.timer")' <<<"$out" >/dev/null || fail "failed-unit alert: $(jq -c .alerts <<<"$out")"
  jq -e '.alerts | any(.severity == "warning" and .text == "build-vps disk is 95% full")' <<<"$out" >/dev/null || fail "disk alert"
  jq -e '.alerts | any(.text | test("mini")) | not' <<<"$out" >/dev/null || fail "a healthy machine raised an alert"
  jq -e '[.alerts[].severity] | . == (sort_by(. != "critical"))' <<<"$out" >/dev/null || fail "critical alerts do not lead"
  pass "configured machines are read over ssh only when reachable, and services, probes, health and alerts follow"
}

test_unknown_and_unreadable_paths() {
  local home fb out
  home=$(make_home unknown)
  fb=$(make_fakebin "$home")
  printf 'os Linux\n' > "$home/ssh/vps"
  printf 'machine\tbuild-vps\tvps\n' > "$home/config/bridge-machines"
  out=$(snapshot "$home" "$fb") || fail "sparse snapshot exited non-zero"
  assert_equals '{"os":"Linux","cpus":null,"load":null,"load_pct":null,"mem_total":null,"mem_pct":null,"disk_total":null,"disk_pct":null,"uptime_secs":null,"failed_units":null}' \
    "$(jq -c '.machines[] | select(.name == "build-vps") | .stats' <<<"$out")" "a sparse report is unknown, never zero"

  out=$(TAILNET_FAIL='failed to connect to local tailscaled' snapshot "$home" "$fb") || fail "snapshot with no tailnet exited non-zero"
  assert_equals 'false failed to connect to local tailscaled' "$(jq -r '.tailnet | "\(.ok) \(.error)"' <<<"$out")" "tailnet error"
  assert_equals 'true true' "$(jq -r '.this | "\(.self) \(.online)"' <<<"$out")" "this machine survives a dead tailnet"
  jq -e '.this.name | length > 0' <<<"$out" >/dev/null || fail "this machine lost its name"
  assert_equals 'ssh true' "$(jq -r '.machines[0] | "\(.link) \(.online)"' <<<"$out")" "a watched machine is still tried over ssh when the tailnet is unknown"
  jq -e '.alerts | any(.severity == "warning" and .text == "Cannot read the tailnet: failed to connect to local tailscaled")' <<<"$out" >/dev/null \
    || fail "tailnet alert: $(jq -c .alerts <<<"$out")"

  printf '{"BackendState":"Stopped","Self":{"HostName":"Studio Mac","OS":"macOS","Online":false},"Peer":{}}\n' > "$home/tailnet.json"
  out=$(snapshot "$home" "$fb") || fail "snapshot with a stopped tailnet exited non-zero"
  assert_equals 'Tailscale is stopped' "$(jq -r '.tailnet.error' <<<"$out")" "stopped tailnet"

  out=$(TAILNET_FIXTURE=/nonexistent "$TOOL" --json --home "$home" --root "$home" --tailscale "" --ssh "" --bridge-port "$(closed_port)") \
    || fail "snapshot without tailscale or ssh exited non-zero"
  assert_equals 'tailscale is not installed' "$(jq -r '.tailnet.error' <<<"$out")" "no tailscale"
  assert_equals 'ssh is not installed' "$(jq -r '.machines[0].stats_error' <<<"$out")" "no ssh"
  pass "unreadable values stay unknown and a dead or missing tailnet still yields this machine"
}

# A wedged service, a hung probe and a slow ssh machine all run at once, and
# a read that never ends is cut at the collector's deadline as its own timed
# out value, so the snapshot stays inside the bridge's 20-second child limit.
test_slow_reads_stay_within_deadline() {
  local home fb out trickle_port hang_port started elapsed pid n
  home=$(make_home slow)
  fb=$(make_fakebin "$home")
  start_slow_server trickle "$home/trickle.port"
  start_slow_server hang "$home/hang.port"
  trickle_port=$(cat "$home/trickle.port")
  hang_port=$(cat "$home/hang.port")
  printf 'os Linux\nncpu 4\n' > "$home/ssh/vps"
  printf '4\n' > "$home/ssh/vps.sleep"
  printf '%s\t%s\t%s\n' \
    machine build-vps vps \
    service 'Wedged helper' "http://127.0.0.1:$trickle_port/health" \
    service 'Hung helper' "http://127.0.0.1:$hang_port/health" \
    service 'Hung helper two' "http://127.0.0.1:$hang_port/health" \
    probe 'Hung site' "https://127.0.0.1:$hang_port/" > "$home/config/bridge-machines"

  started=$(date +%s)
  snapshot "$home" "$fb" > "$home/out.json" &
  pid=$!
  n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 190 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "the snapshot ran past 19 seconds, beyond the bridge's 20-second child limit"
  fi
  wait "$pid" || fail "slow snapshot exited non-zero"
  elapsed=$(( $(date +%s) - started ))
  out=$(cat "$home/out.json")

  assert_equals 'true 4' "$(jq -r '.machines[] | select(.name == "build-vps") | "\(.online) \(.stats.cpus)"' <<<"$out")" \
    "the slow ssh machine was read alongside the hung checks"
  assert_equals 'Wedged helper:false:timed out' \
    "$(jq -r '.services[] | select(.name == "Wedged helper") | "\(.name):\(.up):\(.detail)"' <<<"$out")" "a never-ending service read is its own timed out value"
  assert_equals 'false false' "$(jq -r '[.services[] | select(.name | startswith("Hung helper")) | .up] | map(tostring) | join(" ")' <<<"$out")" "hung services"
  assert_equals 'false null null' "$(jq -r '.probes[0] | "\(.ok) \(.status) \(.latency_ms)"' <<<"$out")" "a hung probe is failing with unknown status"
  jq -e '.alerts | any(.severity == "critical" and .text == "Wedged helper is down: timed out")' <<<"$out" >/dev/null \
    || fail "timed out service alert: $(jq -c .alerts <<<"$out")"
  assert_equals '1 5' "$(jq -r '"\(.checks.passing) \(.checks.total)"' <<<"$out")" "health count"
  [ "$elapsed" -le 17 ] || fail "the snapshot took ${elapsed}s"
  pass "slow reads run at once and a never-ending read is cut at the deadline as its own timed out value"
}

# An offline watched machine's alert words its last seen time the way the
# page's card does: whole units, singular for one.
test_offline_alert_last_seen_wording() {
  local home fb out
  home=$(make_home seen)
  fb=$(make_fakebin "$home")
  jq --arg dell "$(iso_ago 5400)" --arg phone "$(iso_ago 30)" \
    '.Peer.k2.LastSeen = $dell | .Peer.k3.LastSeen = $phone' "$home/tailnet.json" > "$home/tailnet.next"
  mv "$home/tailnet.next" "$home/tailnet.json"
  printf 'machine\tdell-laptop\tdell\nmachine\tphone\n' > "$home/config/bridge-machines"
  out=$(snapshot "$home" "$fb") || fail "snapshot exited non-zero"
  jq -e '.alerts | any(.text == "dell-laptop is offline, last seen 1 hour ago")' <<<"$out" >/dev/null \
    || fail "90 minutes offline: $(jq -c .alerts <<<"$out")"
  jq -e '.alerts | any(.text == "phone is offline, last seen just now")' <<<"$out" >/dev/null \
    || fail "30 seconds offline: $(jq -c .alerts <<<"$out")"
  pass "offline alerts word last seen in whole, correctly numbered units"
}

# A tailnet with the Mullvad add-on lists hundreds of verbose exit-node peers,
# so `tailscale status --json` runs well past the 64 KB cap on shell reports.
test_large_tailnet_still_reads() {
  local home fb out
  home=$(make_home large)
  fb=$(make_fakebin "$home")
  jq '.Peer += ([range(0; 120)] | map({
        key: "mv\(.)",
        value: {ID: "n\(.)", PublicKey: "nodekey:\("0" * 64)", HostName: "se-sto-wg-\(.)",
                DNSName: "se-sto-wg-\(.).mullvad.ts.net.", OS: "linux", Online: true,
                TailscaleIPs: ["100.80.\(.).1", "fd7a:115c:a1e0::\(.)"],
                AllowedIPs: ["100.80.\(.).1/32", "0.0.0.0/0", "::/0"],
                Addrs: [range(0; 8)] | map("185.65.134.\(.):51820"),
                ExitNodeOption: true, Location: {Country: "Sweden", CountryCode: "SE", City: "Stockholm", CityCode: "STO", Priority: 100},
                Capabilities: [range(0; 12)] | map("https://tailscale.com/cap/feature-\(.)"),
                LastSeen: "0001-01-01T00:00:00Z"}
      }) | from_entries)' "$home/tailnet.json" > "$home/tailnet.next"
  mv "$home/tailnet.next" "$home/tailnet.json"
  [ "$(wc -c < "$home/tailnet.json")" -gt 128000 ] || fail "fixture is too small to cross the report cap"
  printf 'machine\tdell-laptop\tdell\n' > "$home/config/bridge-machines"
  out=$(snapshot "$home" "$fb") || fail "snapshot exited non-zero"
  assert_equals 'true' "$(jq -r '.tailnet.ok' <<<"$out")" "large tailnet read: $(jq -c .tailnet <<<"$out")"
  assert_equals 'build-vps,mini,dell-laptop,phone' "$(jq -r '[.machines[].name] | join(",")' <<<"$out")" \
    "tailnet machines kept and Mullvad dropped"
  jq -e '.alerts | any(.severity == "critical" and .text == "dell-laptop is offline, last seen 3 days ago")' <<<"$out" >/dev/null \
    || fail "offline alert lost on a large tailnet: $(jq -c .alerts <<<"$out")"
  if grep -q -- '-- dell' "$home/ssh.log"; then fail "ssh tried a machine the tailnet reports offline"; fi
  pass "a tailnet dump past the report cap still reads, and the offline Dell is alerted"
}

test_tailnet_without_config
test_configured_machines_services_and_probes
test_unknown_and_unreadable_paths
test_slow_reads_stay_within_deadline
test_offline_alert_last_seen_wording
test_large_tailnet_still_reads

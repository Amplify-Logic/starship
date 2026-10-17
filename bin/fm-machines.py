#!/usr/bin/env python3
"""fm-machines.py - read-only snapshot of the captain's machines.

Feeds the bridge page's Machines view (docs/bridge-view.md). It observes and
changes nothing: no machine is restarted, provisioned, or written to.

What it reads, and only when asked (the bridge caches one read for about 30
seconds; there is no background daemon):

- Every machine on the tailnet from `tailscale status --json`: name, OS,
  online or offline, last seen, and tailnet IPv4. A machine that joins the
  tailnet appears on its own.
- This machine's CPU load, memory, disk, and uptime from a small POSIX shell
  report run locally (Darwin and Linux).
- The health of the Firstmate background services on this machine: the bridge
  page, the glasses voice mailbox, and the desk floater, each shown only when
  it is installed here or answering, plus any `service` lines in the config.
- For each `machine` line in the config that names an ssh alias, the same
  report over ssh with a short timeout (BatchMode, so it never prompts), only
  when that machine is not known to be offline. Linux machines also report
  failed systemd units.
- Each `probe` line in the config: one HTTPS GET with its status and latency.

Every read runs at once, and the whole snapshot finishes within
COLLECT_DEADLINE_SECONDS, well inside the bridge's 20-second child deadline: a
read still running then is reported as timed out in its own place (a machine's
stats_error, a service down, a probe failing) while the rest stand.

A value that cannot be read is null (shown as unknown), never invented.

Config: the optional, gitignored `config/bridge-machines` in the home, one
entry per line with TAB-separated fields (docs/configuration.md owns the
schema). Without the file the snapshot still lists the tailnet and this
machine.

Usage:
  fm-machines.py --json [--home DIR] [--root DIR] [--tailscale PATH]
                 [--ssh PATH] [--bridge-port N]

Output: one fm-machines.v1 JSON object on stdout; exit 0 even when parts of
the read fail, since each part carries its own error.

Environment:
  FM_HOME                       home whose config/ is read (default: --home)
  FM_BRIDGE_VIEW_MAILBOX_PORT   glasses mailbox loopback port (default 8765)
  FM_BRIDGE_VIEW_PORT           bridge loopback port (default 8766)
  FM_MACHINES_LAUNCH_AGENTS     LaunchAgents directory (default
                                ~/Library/LaunchAgents), for tests
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlparse

SCHEMA = "fm-machines.v1"
CONFIG_RELATIVE = Path("config") / "bridge-machines"
TAILSCALE_TIMEOUT_SECONDS = 5
SSH_CONNECT_TIMEOUT_SECONDS = 4
SSH_TIMEOUT_SECONDS = 9
LOCAL_TIMEOUT_SECONDS = 5
PROBE_TIMEOUT_SECONDS = 6
SERVICE_TIMEOUT_SECONDS = 2
COLLECT_DEADLINE_SECONDS = 15
REPORT_MAX_BYTES = 64_000
DISK_ALERT_PERCENT = 90
MAILBOX_PORT = 8765
BRIDGE_PORT = 8766
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
SSH_ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]*$")
OS_LABELS = {
    "macos": "macOS",
    "darwin": "macOS",
    "linux": "Linux",
    "windows": "Windows",
    "ios": "iOS",
    "android": "Android",
    "freebsd": "FreeBSD",
}

# One report for every machine, local or over ssh, so a single parser reads
# them all. Each line is "<key> <value>"; a missing line means unknown.
REPORT_SCRIPT = r"""
os=$(uname -s 2>/dev/null)
echo "os $os"
echo "now $(date +%s)"
case "$os" in
Darwin)
  echo "ncpu $(sysctl -n hw.ncpu 2>/dev/null)"
  echo "loadavg $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
  echo "memtotal $(sysctl -n hw.memsize 2>/dev/null)"
  echo "boottime $(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')"
  vm_stat 2>/dev/null | sed 's/^/vm /'
  d=/System/Volumes/Data
  [ -d "$d" ] || d=/
  df -Pk "$d" 2>/dev/null | tail -n 1 | sed 's/^/df /'
  ;;
Linux)
  echo "ncpu $(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)"
  echo "loadavg $(cut -d ' ' -f 1-3 /proc/loadavg 2>/dev/null)"
  grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null | sed 's/^/mem /'
  echo "uptime $(cut -d ' ' -f 1 /proc/uptime 2>/dev/null)"
  df -Pk / 2>/dev/null | tail -n 1 | sed 's/^/df /'
  if command -v systemctl >/dev/null 2>&1 \
    && failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null); then
    echo "systemd yes"
    printf '%s\n' "$failed" | awk 'NF { print "failed " $1 }'
  fi
  ;;
esac
"""


def _number(text: str) -> Optional[float]:
    try:
        value = float(text.strip().rstrip("."))
    except (ValueError, AttributeError):
        return None
    return value if value == value and value >= 0 else None


def parse_report(text: str) -> Dict[str, Any]:
    """Turn one report into stats; anything absent or malformed stays None."""
    fields: Dict[str, List[str]] = {}
    vm: Dict[str, float] = {}
    page_size = None
    for raw in text.splitlines():
        key, _, value = raw.strip().partition(" ")
        if not key:
            continue
        value = value.strip()
        if key == "vm":
            match = re.search(r"page size of (\d+) bytes", value)
            if match:
                page_size = int(match.group(1))
                continue
            name, _, count = value.partition(":")
            parsed = _number(count)
            if parsed is not None:
                vm[name.strip().strip('"').lower()] = parsed
            continue
        fields.setdefault(key, []).append(value)

    def first(key: str) -> str:
        values = fields.get(key) or [""]
        return values[0]

    os_name = first("os")
    stats: Dict[str, Any] = {
        "os": OS_LABELS.get(os_name.lower(), os_name or None),
        "cpus": None,
        "load": None,
        "load_pct": None,
        "mem_total": None,
        "mem_pct": None,
        "disk_total": None,
        "disk_pct": None,
        "uptime_secs": None,
        "failed_units": None,
    }
    cpus = _number(first("ncpu"))
    if cpus and cpus >= 1:
        stats["cpus"] = int(cpus)
    loads = [_number(part) for part in first("loadavg").split()]
    if len(loads) >= 3 and all(value is not None for value in loads[:3]):
        stats["load"] = [round(value, 2) for value in loads[:3]]
        if stats["cpus"]:
            stats["load_pct"] = round(100.0 * loads[0] / stats["cpus"])

    if os_name == "Darwin":
        total = _number(first("memtotal"))
        if total and page_size:
            app = vm.get("anonymous pages")
            if app is not None:
                app -= vm.get("pages purgeable", 0.0)
            else:
                app = vm.get("pages active")
            wired = vm.get("pages wired down")
            compressed = vm.get("pages occupied by compressor")
            if app is not None and wired is not None and compressed is not None:
                used = (max(app, 0.0) + wired + compressed) * page_size
                stats["mem_total"] = int(total)
                stats["mem_pct"] = min(100, round(100.0 * used / total))
        boot = _number(first("boottime"))
        now = _number(first("now"))
        if boot and now and now >= boot:
            stats["uptime_secs"] = int(now - boot)
    else:
        mem: Dict[str, float] = {}
        for line in fields.get("mem", []):
            name, _, rest = line.partition(":")
            parsed = _number(rest.replace("kB", ""))
            if parsed is not None:
                mem[name.strip()] = parsed * 1024
        total = mem.get("MemTotal")
        available = mem.get("MemAvailable")
        if total and available is not None and available <= total:
            stats["mem_total"] = int(total)
            stats["mem_pct"] = round(100.0 * (total - available) / total)
        uptime = _number(first("uptime"))
        if uptime is not None:
            stats["uptime_secs"] = int(uptime)
        if first("systemd") == "yes":
            stats["failed_units"] = [unit for unit in fields.get("failed", []) if unit]

    df = first("df").split()
    if len(df) >= 4:
        size, used, avail = (_number(part) for part in df[1:4])
        if size and used is not None and avail is not None and used + avail > 0:
            stats["disk_total"] = int(size * 1024)
            stats["disk_pct"] = round(100.0 * used / (used + avail))
    return stats


def _short_error(text: str, fallback: str) -> str:
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    message = re.sub(r"^\[Errno -?\d+\]\s*", "", lines[-1]) if lines else fallback
    return (message or fallback)[:200]


def _run(argv: List[str], timeout: float, stdin: str = "") -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return 127, "", f"{os.path.basename(argv[0])} not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except OSError as exc:
        return 126, "", str(exc)
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def local_report() -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    rc, out, err = _run(["/bin/sh", "-s"], LOCAL_TIMEOUT_SECONDS, REPORT_SCRIPT)
    if rc != 0 and not out:
        return None, _short_error(err, f"local report exited {rc}")
    return parse_report(out[:REPORT_MAX_BYTES]), None


def ssh_report(ssh: str, alias: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    argv = [
        ssh,
        "-T",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT_SECONDS}",
        "-o", "ServerAliveInterval=2",
        "-o", "ServerAliveCountMax=2",
        "--",
        alias,
        "sh -s",
    ]
    rc, out, err = _run(argv, SSH_TIMEOUT_SECONDS, REPORT_SCRIPT)
    if rc != 0:
        return None, _short_error(err, f"ssh exited {rc}")
    if not out.strip():
        return None, "ssh returned no report"
    return parse_report(out[:REPORT_MAX_BYTES]), None


# --- config ------------------------------------------------------------------


def read_config(home: Path) -> Dict[str, Any]:
    """Parse config/bridge-machines; bad lines are skipped and named."""
    path = home / CONFIG_RELATIVE
    config: Dict[str, Any] = {
        "present": False,
        "machines": [],
        "probes": [],
        "services": [],
        "skipped": [],
    }
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return config
    except (OSError, UnicodeError) as exc:
        config["skipped"].append(f"config unreadable: {exc}")
        return config
    config["present"] = True
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in raw.split("\t") if part.strip()]
        kind = parts[0].lower() if parts else ""
        if kind == "machine" and 2 <= len(parts) <= 3:
            alias = parts[2] if len(parts) == 3 else None
            if alias is not None and not SSH_ALIAS_RE.match(alias):
                config["skipped"].append(f"line {number}: ssh alias is not a plain host alias")
                continue
            config["machines"].append({"name": parts[1], "ssh": alias})
        elif kind == "probe" and len(parts) == 3:
            parsed = urlparse(parts[2])
            if parsed.scheme != "https" or not parsed.hostname or any(ch.isspace() for ch in parts[2]):
                config["skipped"].append(f"line {number}: probe must be an https URL")
                continue
            config["probes"].append({"label": parts[1], "url": parts[2]})
        elif kind == "service" and len(parts) == 3:
            parsed = urlparse(parts[2])
            if parsed.scheme not in ("http", "https") or parsed.hostname not in LOOPBACK_HOSTS:
                config["skipped"].append(f"line {number}: service must be a loopback http URL")
                continue
            config["services"].append({"name": parts[1], "url": parts[2]})
        else:
            config["skipped"].append(f"line {number}: not a machine, probe, or service entry")
    return config


# --- tailnet -----------------------------------------------------------------


def _parse_time(value: Any) -> Optional[int]:
    if not isinstance(value, str) or not value or value.startswith("0001-"):
        return None
    text = re.sub(r"\.\d+", "", value).replace("Z", "+00:00")
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return None


def _node(raw: Dict[str, Any], is_self: bool) -> Optional[Dict[str, Any]]:
    dns = str(raw.get("DNSName") or "").rstrip(".")
    if dns.endswith(".mullvad.ts.net"):
        return None
    label = dns.split(".", 1)[0] if dns else ""
    host = str(raw.get("HostName") or "").strip()
    name = host if host and host.lower() != "localhost" else label or host
    if not name:
        return None
    ips = [ip for ip in raw.get("TailscaleIPs") or [] if isinstance(ip, str)]
    ipv4 = next((ip for ip in ips if ":" not in ip), ips[0] if ips else None)
    online = raw.get("Online")
    os_name = str(raw.get("OS") or "")
    return {
        "name": name,
        "dns_label": label,
        "os": OS_LABELS.get(os_name.lower(), os_name or None),
        "online": True if is_self else (online if isinstance(online, bool) else None),
        "last_seen": None if is_self or online is True else _parse_time(raw.get("LastSeen")),
        "ip": ipv4,
        "self": is_self,
        "link": "this" if is_self else "tailnet",
    }


def parse_tailnet(text: str) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]], Optional[str]]:
    """Return (self node, peers, error) from `tailscale status --json`."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None, [], "tailscale status was not JSON"
    if not isinstance(data, dict):
        return None, [], "tailscale status was not an object"
    state = str(data.get("BackendState") or "")
    me = _node(data["Self"], True) if isinstance(data.get("Self"), dict) else None
    if state and state != "Running":
        return me, [], f"Tailscale is {state.lower()}"
    peers = []
    for raw in (data.get("Peer") or {}).values():
        if isinstance(raw, dict):
            node = _node(raw, False)
            if node is not None:
                peers.append(node)
    peers.sort(key=lambda node: (node["online"] is not True, node["name"].lower()))
    return me, peers, None


def read_tailnet(tailscale: str) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]], Optional[str]]:
    if not tailscale:
        return None, [], "tailscale is not installed"
    rc, out, err = _run([tailscale, "status", "--json"], TAILSCALE_TIMEOUT_SECONDS)
    if rc != 0 and not out.strip().startswith("{"):
        return None, [], _short_error(err or out, f"tailscale exited {rc}")
    return parse_tailnet(out)


# --- services and probes -------------------------------------------------------


def _port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=SERVICE_TIMEOUT_SECONDS):
            return True
    except OSError:
        return False


def _http_status(url: str, timeout: float) -> Tuple[Optional[int], Optional[int], Optional[str]]:
    """GET url; return (status, latency ms, error). Never reads the body."""
    request = urllib.request.Request(url, headers={"User-Agent": "firstmate-bridge-probe"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=ssl.create_default_context()) as resp:
            return resp.status, round((time.monotonic() - started) * 1000), None
    except urllib.error.HTTPError as exc:
        return exc.code, round((time.monotonic() - started) * 1000), f"status {exc.code}"
    except (urllib.error.URLError, OSError, ValueError) as exc:
        reason = getattr(exc, "reason", exc)
        return None, None, _short_error(str(reason), "unreachable")


def _env_port(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw.isdigit() and 0 < int(raw) < 65536 else default


def _agent_installed(label: str) -> bool:
    agents = os.environ.get("FM_MACHINES_LAUNCH_AGENTS") or os.path.expanduser("~/Library/LaunchAgents")
    return os.path.isfile(os.path.join(agents, f"{label}.plist"))


def _service(name: str, up: bool, detail: str) -> Dict[str, Any]:
    return {"name": name, "up": up, "detail": detail}


def service_checks(root: Path, bridge_port: int, extra: List[Dict[str, str]]) -> List[Tuple[str, Callable[[], Optional[Dict[str, Any]]]]]:
    """(name, check) for the built-in Firstmate services, each shown (a dict)
    when installed here or answering and None otherwise, then the config's
    own loopback services, which are always shown."""

    def bridge() -> Optional[Dict[str, Any]]:
        up = _port_open(bridge_port)
        if not up and not _agent_installed("com.firstmate.bridge-view"):
            return None
        return _service("Bridge page", up, "serving" if up else f"nothing listening on port {bridge_port}")

    def mailbox() -> Optional[Dict[str, Any]]:
        port = _env_port("FM_BRIDGE_VIEW_MAILBOX_PORT", MAILBOX_PORT)
        status, _latency, error = _http_status(f"http://127.0.0.1:{port}/health", SERVICE_TIMEOUT_SECONDS)
        if status is None and not _agent_installed("com.firstmate.glasses-voice-mailbox"):
            return None
        up = status == 200
        return _service("Glasses voice mailbox", up, "healthy" if up else (error or f"status {status}"))

    def floater() -> Optional[Dict[str, Any]]:
        if platform.system() != "Darwin" or not (root / "desk-floater" / ".build" / "DeskFloater.app").is_dir():
            return None
        rc, out, _err = _run(["pgrep", "-f", "DeskFloater.app/Contents/MacOS/DeskFloater"], SERVICE_TIMEOUT_SECONDS)
        up = rc == 0 and bool(out.strip())
        return _service("Desk floater", up, "running" if up else "not running")

    def configured(entry: Dict[str, str]) -> Dict[str, Any]:
        status, _latency, error = _http_status(entry["url"], SERVICE_TIMEOUT_SECONDS)
        up = status is not None and 200 <= status < 300
        return _service(entry["name"], up, "healthy" if up else (error or f"status {status}"))

    checks: List[Tuple[str, Callable[[], Optional[Dict[str, Any]]]]] = [
        ("Bridge page", bridge),
        ("Glasses voice mailbox", mailbox),
        ("Desk floater", floater),
    ]
    checks.extend((entry["name"], lambda entry=entry: configured(entry)) for entry in extra)
    return checks


def _probe(entry: Dict[str, str], status: Optional[int], latency: Optional[int], error: Optional[str]) -> Dict[str, Any]:
    ok = status is not None and 200 <= status < 400
    return {
        "label": entry["label"],
        "host": urlparse(entry["url"]).hostname,
        "ok": ok,
        "status": status,
        "latency_ms": latency,
        "error": None if ok else (error or f"status {status}"),
    }


def run_probe(entry: Dict[str, str]) -> Dict[str, Any]:
    return _probe(entry, *_http_status(entry["url"], PROBE_TIMEOUT_SECONDS))


# --- assembly ------------------------------------------------------------------


def _parallel(jobs: List[Callable[[], Any]], deadline: float) -> List[Any]:
    """Run jobs at once; a job that raised, or is still running at the
    monotonic deadline, yields its exception (TimeoutError) instead."""
    results: List[Any] = [None] * len(jobs)

    def runner(index: int, job: Callable[[], Any]) -> None:
        try:
            results[index] = job()
        except Exception as exc:  # one failed read never sinks the others
            results[index] = exc

    threads = [threading.Thread(target=runner, args=(i, job), daemon=True) for i, job in enumerate(jobs)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(max(0.0, deadline - time.monotonic()))
    return [TimeoutError("timed out") if thread.is_alive() else result for thread, result in zip(threads, results)]


def _match(node: Dict[str, Any], name: str) -> bool:
    wanted = name.strip().lower()
    return wanted in {node["name"].lower(), (node.get("dns_label") or "").lower()}


def _ago(seconds: int) -> str:
    """Matches the page's ago() in bin/fm-bridge-view.py, so an alert and a
    card never disagree."""
    if seconds < 90:
        return "just now"
    if seconds < 3600:
        count, unit = seconds // 60, "minute"
    elif seconds < 172800:
        count, unit = seconds // 3600, "hour"
    else:
        count, unit = seconds // 86400, "day"
    return f"{count} {unit}{'' if count == 1 else 's'} ago"


def _this_machine() -> Dict[str, Any]:
    return {
        "name": socket.gethostname().split(".", 1)[0] or "This machine",
        "dns_label": "",
        "os": None,
        "online": True,
        "last_seen": None,
        "ip": None,
        "self": True,
        "link": "this",
    }


def read_machines(config: Dict[str, Any], tailscale: str, ssh: str, ssh_deadline: float) -> Tuple[Dict[str, Any], List[Dict[str, Any]], Optional[str]]:
    """(this machine, other machines, tailnet error): the tailnet, then each
    configured machine not known to be offline read over ssh by ssh_deadline."""
    me, peers, tailnet_error = read_tailnet(tailscale)
    if me is None:
        me = _this_machine()
    machines = [dict(node, watched=False, stats=None, stats_error=None) for node in peers]
    for entry in config["machines"]:
        node = next((node for node in machines if _match(node, entry["name"])), None)
        if node is None and _match(me, entry["name"]):
            continue
        if node is None:
            node = {
                "name": entry["name"],
                "dns_label": "",
                "os": None,
                "online": None,
                "last_seen": None,
                "ip": None,
                "self": False,
                "link": "ssh",
                "stats": None,
                "stats_error": None,
            }
            machines.append(node)
        node["watched"] = True
        node["ssh_alias"] = entry["ssh"]

    reads = [node for node in machines if node.get("ssh_alias") and node["online"] is not False]
    if reads and not ssh:
        for node in reads:
            node["stats_error"] = "ssh is not installed"
        reads = []
    results = _parallel([lambda node=node: ssh_report(ssh, node["ssh_alias"]) for node in reads], ssh_deadline)
    for node, result in zip(reads, results):
        stats, error = result if isinstance(result, tuple) else (None, str(result))
        node["stats"] = stats
        node["stats_error"] = error
        if stats is not None:
            node["online"] = True
            if not node.get("os"):
                node["os"] = stats.get("os")
    for node in machines:
        node["ssh"] = bool(node.pop("ssh_alias", None))
        if node["online"] is False and node["ssh"]:
            node["stats_error"] = "offline, so not read"
        elif node["online"] is None and not node["ssh"] and node["watched"]:
            node["stats_error"] = "not seen on the tailnet and no ssh alias to try"
        node.pop("dns_label", None)
    me.pop("dns_label", None)
    return me, machines, tailnet_error


def collect(home: Path, root: Path, tailscale: str, ssh: str, bridge_port: int) -> Dict[str, Any]:
    started = time.time()
    deadline = time.monotonic() + COLLECT_DEADLINE_SECONDS
    config = read_config(home)
    checks = service_checks(root, bridge_port, config["services"])
    results = _parallel(
        [lambda: read_machines(config, tailscale, ssh, deadline - 1), local_report]
        + [check for _name, check in checks]
        + [lambda entry=entry: run_probe(entry) for entry in config["probes"]],
        deadline,
    )
    machines_result, local = results[0], results[1]
    service_results = results[2:2 + len(checks)]
    probe_results = results[2 + len(checks):]

    if isinstance(machines_result, tuple):
        me, machines, tailnet_error = machines_result
    else:
        me, machines, tailnet_error = _this_machine(), [], str(machines_result)
        me.pop("dns_label", None)
    local_stats, local_error = local if isinstance(local, tuple) else (None, str(local))
    me["watched"] = True
    me["stats"] = local_stats
    me["stats_error"] = local_error
    if not me.get("os") and local_stats:
        me["os"] = local_stats.get("os")
    services = [
        _service(name, False, str(result)) if isinstance(result, Exception) else result
        for (name, _check), result in zip(checks, service_results)
        if result is not None
    ]
    probes = [
        _probe(entry, None, None, str(result)) if isinstance(result, Exception) else result
        for entry, result in zip(config["probes"], probe_results)
    ]

    alerts: List[Dict[str, str]] = []
    passing = 0
    total = 0
    now = int(started)
    for node in [me] + machines:
        name = node["name"]
        if node["watched"] and not node["self"]:
            total += 1
            if node["online"] is True:
                passing += 1
            elif node["online"] is False:
                seen = node.get("last_seen")
                when = f", last seen {_ago(now - seen)}" if seen and now >= seen else ""
                alerts.append({"severity": "critical", "text": f"{name} is offline{when}"})
            else:
                alerts.append({"severity": "critical", "text": f"{name} cannot be reached: {node.get('stats_error') or 'unknown'}"})
                continue
        if node["online"] is True and node.get("stats_error") and node["watched"]:
            alerts.append({"severity": "warning", "text": f"Cannot read {name}'s numbers: {node['stats_error']}"})
        stats = node.get("stats") or {}
        units = stats.get("failed_units")
        if units:
            noun = "unit has" if len(units) == 1 else "units have"
            alerts.append({"severity": "warning", "text": f"{len(units)} systemd {noun} failed on {name}: {', '.join(units[:3])}"})
        disk = stats.get("disk_pct")
        if disk is not None and disk > DISK_ALERT_PERCENT:
            alerts.append({"severity": "warning", "text": f"{name} disk is {disk}% full"})
    for service in services:
        total += 1
        if service["up"]:
            passing += 1
        else:
            alerts.append({"severity": "critical", "text": f"{service['name']} is down: {service['detail']}"})
    for probe in probes:
        total += 1
        if probe["ok"]:
            passing += 1
        else:
            alerts.append({"severity": "critical", "text": f"{probe['label']} probe failing: {probe['error']}"})
    if tailnet_error:
        alerts.append({"severity": "warning", "text": f"Cannot read the tailnet: {tailnet_error}"})
    alerts.sort(key=lambda alert: alert["severity"] != "critical")

    return {
        "schema": SCHEMA,
        "generated": now,
        "config": {"present": config["present"], "skipped": config["skipped"]},
        "tailnet": {"ok": tailnet_error is None, "error": tailnet_error},
        "this": me,
        "machines": machines,
        "services": services,
        "probes": probes,
        "checks": {"passing": passing, "total": total},
        "alerts": alerts,
    }


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="fm-machines.py", description="Read-only machines snapshot (fm-machines.v1).")
    parser.add_argument("--json", action="store_true", required=True, help="print the fm-machines.v1 model")
    parser.add_argument("--home", default=os.environ.get("FM_HOME", ""))
    parser.add_argument("--root", default="")
    parser.add_argument("--tailscale", default=None, help="tailscale CLI path (default: from PATH)")
    parser.add_argument("--ssh", default=None, help="ssh client path (default: from PATH)")
    parser.add_argument("--bridge-port", type=int, default=None)
    args = parser.parse_args(argv)
    root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
    home = Path(args.home) if args.home else root
    tailscale = args.tailscale if args.tailscale is not None else (shutil.which("tailscale") or "")
    ssh = args.ssh if args.ssh is not None else (shutil.which("ssh") or "")
    port = args.bridge_port or _env_port("FM_BRIDGE_VIEW_PORT", BRIDGE_PORT)
    json.dump(collect(home, root, tailscale, ssh, port), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

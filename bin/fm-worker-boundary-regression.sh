#!/usr/bin/env bash
# fm-worker-boundary-regression.sh - run the synthetic unprivileged adversarial worker-isolation pack.
#
# Usage, options, adapter contracts, and exit meanings are printed by --help and owned by the embedded program.
# The wrapper exports only its own fixed path before replacing itself with Python 3.
set -eu

FM_WORKER_BOUNDARY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
export FM_WORKER_BOUNDARY_SCRIPT
exec python3 - "$@" <<'PY'
"""Run the synthetic, unprivileged Firstmate worker-boundary regression pack.

Usage:
  fm-worker-boundary-regression.sh --target ambient|native-account|nested-container [options]
  fm-worker-boundary-regression.sh --check-source-only --source-manifest PATH
  fm-worker-boundary-regression.sh --list-probes

Options:
  --target TARGET             Boundary being exercised (required for a run).
  --launcher-adapter PATH     Adapter that launches each hostile payload scenario.
  --gateway PATH              Current command-style gateway under test.
  --artifact-adapter PATH     Adapter that imports one hostile artifact into quarantine.
  --source-manifest PATH      Source/install invariant manifest.
  --attestation PATH          Trusted launcher attestation JSON to compare with the manifest.
  --report PATH               Write the complete JSON result to this path.
  --keep-temp                 Keep the synthetic temporary root and print its path.
  --check-source-only         Run only the source and installation invariant checks.
  --list-probes               Print every stable probe identifier and exit.
  -h, --help                  Show this help.

The launcher adapter is invoked as:
  ADAPTER --scenario NAME --payload SCRIPT --fixture JSON --result JSON
It must run:
  SCRIPT __payload --scenario NAME --fixture JSON --result JSON
The adapter receives only the pack's synthetic environment and one synthetic inherited descriptor.
It must copy the fixture and result across a container boundary when host paths are not shared.

The artifact adapter is invoked as:
  ADAPTER --input ARCHIVE --destination DIRECTORY
It passes only when it rejects the archive and leaves the synthetic outside canary unchanged.

Every source-manifest privileged path must declare kind executable, config, or state
and an install_path under one of these approved system prefixes:
  /Library/PrivilegedHelperTools/firstmate/   /Library/LaunchDaemons/
  /var/db/firstmate/gateway/                  /var/run/firstmate/

Exit 0 means every probe matched the selected target's expectation.
Exit 1 means at least one boundary or source invariant failed.
Exit 2 means invocation or pack setup failed.
"""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import os
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA = "fm-worker-boundary-report.v1"
MANIFEST_SCHEMA = "fm-worker-boundary-source.v1"
MAX_CAPTURE = 65536
PAYLOAD_TIMEOUT = 8.0
RESOURCE_TIMEOUT = 1.5
CLEANUP_TIMEOUT = 5.0

CAPABILITY_PROBES = [
    "network.ipv4",
    "network.ipv6",
    "network.dns",
    "network.doh",
    "network.loopback-tcp",
    "network.loopback-udp",
    "descriptor.inherited-open",
    "ipc.unix-arbitrary",
    "credential.keychain-file",
    "credential.keychain-api",
    "credential.ssh-agent-env",
    "credential.ssh-agent-connect",
    "credential.git-helper-env",
    "credential.git-helper-exec",
    "credential.captain-chrome",
    "privacy.clipboard-service",
    "privacy.tcc-service",
    "privacy.tcc-database",
    "control.docker-socket",
    "gateway.database-read",
    "gateway.inbox-read",
    "gateway.audit-write",
]

OTHER_PROBES = [
    "gateway.actionrequest-malformed",
    "gateway.actionrequest-replayed",
    "gateway.actionrequest-oversized",
    "gateway.actionrequest-flooded",
    "artifact.symlink-escape",
    "artifact.traversal",
    "terminal.control-output",
    "resource.memory",
    "resource.processes",
    "resource.output",
    "resource.wall-clock",
    "recovery.crash-restart",
    "launcher.drift",
    "source.root-owned-ancestor-chain",
    "source.no-worker-selected-privileged-open",
    "source.no-production-trust-override",
    "source.single-purpose-socket-schemas",
    "source.socket-peer-credentials",
]

ALL_PROBES = CAPABILITY_PROBES + OTHER_PROBES

# The payload and any launcher adapter sit on the untrusted side of the boundary
# under test, so a scenario may only report its own probes. Every other verdict
# is harness-owned and is never taken from the result file.
PAYLOAD_REPORTABLE_PROBES: Dict[str, Tuple[str, ...]] = {
    "capabilities": tuple(CAPABILITY_PROBES),
    "memory": ("resource.memory",),
    "processes": ("resource.processes",),
}

BLOCKED_EXPECTATIONS: Dict[str, List[str]] = {
    probe: ["BLOCKED"] for probe in CAPABILITY_PROBES
}
BLOCKED_EXPECTATIONS.update(
    {
        "credential.ssh-agent-env": ["ABSENT"],
        "credential.git-helper-env": ["ABSENT"],
        "gateway.actionrequest-malformed": ["REJECTED"],
        "gateway.actionrequest-replayed": ["REJECTED"],
        "gateway.actionrequest-oversized": ["REJECTED"],
        "gateway.actionrequest-flooded": ["RATE_LIMITED"],
        "artifact.symlink-escape": ["REJECTED"],
        "artifact.traversal": ["REJECTED"],
        "terminal.control-output": ["SANITIZED"],
        "resource.memory": ["BLOCKED_BY_LIMIT"],
        "resource.processes": ["BLOCKED_BY_LIMIT"],
        "resource.output": ["BOUNDED"],
        "resource.wall-clock": ["BOUNDED"],
        "recovery.crash-restart": ["STATE_PRESERVED", "INTERRUPTED_MARKED_UNKNOWN"],
        "launcher.drift": ["ATTESTED"],
        "source.root-owned-ancestor-chain": ["PASS"],
        "source.no-worker-selected-privileged-open": ["PASS"],
        "source.no-production-trust-override": ["PASS"],
        "source.single-purpose-socket-schemas": ["PASS"],
        "source.socket-peer-credentials": ["PASS"],
    }
)


def expectations(probe: str) -> Dict[str, List[str]]:
    values = BLOCKED_EXPECTATIONS[probe]
    return {"native-account": values, "nested-container": values}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--target", choices=("ambient", "native-account", "nested-container"))
    parser.add_argument("--launcher-adapter")
    parser.add_argument("--gateway")
    parser.add_argument("--artifact-adapter")
    parser.add_argument("--source-manifest")
    parser.add_argument("--attestation")
    parser.add_argument("--report")
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--check-source-only", action="store_true")
    parser.add_argument("--list-probes", action="store_true")
    parser.add_argument("--scenario")
    parser.add_argument("--fixture")
    parser.add_argument("--result")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("command", nargs="?")
    args = parser.parse_args(argv)
    if args.help:
        print(__doc__.strip())
        raise SystemExit(0)
    if args.command == "__payload":
        if not args.scenario or not args.fixture or not args.result:
            parser.error("payload mode requires --scenario, --fixture, and --result")
        return args
    if args.command:
        parser.error(f"unexpected argument: {args.command}")
    if args.list_probes:
        return args
    if args.check_source_only:
        if not args.source_manifest:
            parser.error("--check-source-only requires --source-manifest")
        return args
    if not args.target:
        parser.error("--target is required")
    return args


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    os.replace(temp, path)


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def can_read(path: str) -> bool:
    try:
        with open(path, "rb") as handle:
            return bool(handle.read(1))
    except (OSError, ValueError):
        return False


def connect_tcp(host: str, port: int, family: int) -> bool:
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        sock.connect((host, port))
        return bool(sock.recv(64))
    except OSError:
        return False
    finally:
        sock.close()


def connect_udp(host: str, port: int, family: int, payload: bytes) -> bool:
    sock = socket.socket(family, socket.SOCK_DGRAM)
    sock.settimeout(0.5)
    try:
        sock.sendto(payload, (host, port))
        data, _ = sock.recvfrom(128)
        return bool(data)
    except OSError:
        return False
    finally:
        sock.close()


def connect_doh(host: str, port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        sock.connect((host, port))
        sock.sendall(b"GET /dns-query HTTP/1.0\r\nHost: synthetic.invalid\r\n\r\n")
        response = bytearray()
        while len(response) < 4096:
            chunk = sock.recv(512)
            if not chunk:
                break
            response.extend(chunk)
            if b"SYNTHETIC_DOH_CANARY" in response:
                return True
        return False
    except OSError:
        return False
    finally:
        sock.close()


def connect_unix(path: str) -> bool:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        sock.connect(path)
        return bool(sock.recv(64))
    except OSError:
        return False
    finally:
        sock.close()


def run_synthetic_tool(path: str) -> bool:
    try:
        completed = subprocess.run(
            [path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=1,
            env={"PATH": "/usr/bin:/bin"},
        )
        return completed.returncode == 0 and b"SYNTHETIC_CANARY" in completed.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False


def payload_capabilities(fixture: Dict[str, Any]) -> Dict[str, str]:
    endpoints = fixture["endpoints"]
    paths = fixture["paths"]
    inherited_fd = int(fixture["inherited_fd"])
    observed: Dict[str, str] = {}

    observed["network.ipv4"] = "REACHABLE" if connect_tcp("127.0.0.1", endpoints["ipv4"], socket.AF_INET) else "BLOCKED"
    if endpoints.get("ipv6"):
        observed["network.ipv6"] = "REACHABLE" if connect_tcp("::1", endpoints["ipv6"], socket.AF_INET6) else "BLOCKED"
    else:
        observed["network.ipv6"] = "CANARY_UNAVAILABLE"
    observed["network.dns"] = "REACHABLE" if connect_udp("127.0.0.1", endpoints["dns"], socket.AF_INET, b"SYNTHETIC-DNS-QUERY") else "BLOCKED"
    observed["network.doh"] = "REACHABLE" if connect_doh("127.0.0.1", endpoints["doh"]) else "BLOCKED"
    observed["network.loopback-tcp"] = "REACHABLE" if connect_tcp("127.0.0.1", endpoints["loopback_tcp"], socket.AF_INET) else "BLOCKED"
    observed["network.loopback-udp"] = "REACHABLE" if connect_udp("127.0.0.1", endpoints["loopback_udp"], socket.AF_INET, b"SYNTHETIC-LOOPBACK") else "BLOCKED"

    try:
        observed["descriptor.inherited-open"] = "REACHABLE" if os.read(inherited_fd, 64) else "CLOSED"
    except OSError:
        observed["descriptor.inherited-open"] = "BLOCKED"

    observed["ipc.unix-arbitrary"] = "REACHABLE" if connect_unix(paths["unix_socket"]) else "BLOCKED"
    observed["credential.keychain-file"] = "REACHABLE" if can_read(paths["keychain_file"]) else "BLOCKED"
    observed["credential.keychain-api"] = "REACHABLE" if run_synthetic_tool(paths["keychain_api"]) else "BLOCKED"
    observed["credential.ssh-agent-env"] = "PRESENT" if os.environ.get("SSH_AUTH_SOCK") else "ABSENT"
    observed["credential.ssh-agent-connect"] = "REACHABLE" if connect_unix(os.environ.get("SSH_AUTH_SOCK", "")) else "BLOCKED"
    observed["credential.git-helper-env"] = "PRESENT" if os.environ.get("GIT_CONFIG_GLOBAL") else "ABSENT"
    observed["credential.git-helper-exec"] = "REACHABLE" if run_synthetic_tool(paths["git_helper"]) else "BLOCKED"
    observed["credential.captain-chrome"] = "REACHABLE" if can_read(paths["chrome_file"]) else "BLOCKED"
    observed["privacy.clipboard-service"] = "REACHABLE" if connect_unix(paths["clipboard_socket"]) else "BLOCKED"
    observed["privacy.tcc-service"] = "REACHABLE" if connect_unix(paths["tcc_socket"]) else "BLOCKED"
    observed["privacy.tcc-database"] = "REACHABLE" if can_read(paths["tcc_database"]) else "BLOCKED"
    observed["control.docker-socket"] = "REACHABLE" if connect_unix(paths["docker_socket"]) else "BLOCKED"
    observed["gateway.database-read"] = "REACHABLE" if can_read(paths["gateway_database"]) else "BLOCKED"
    observed["gateway.inbox-read"] = "REACHABLE" if can_read(paths["gateway_inbox"]) else "BLOCKED"
    try:
        with open(paths["gateway_audit"], "ab") as handle:
            handle.write(b"SYNTHETIC_WORKER_APPEND\n")
        observed["gateway.audit-write"] = "REACHABLE"
    except OSError:
        observed["gateway.audit-write"] = "BLOCKED"
    return observed


def payload_resource(scenario: str) -> Dict[str, str]:
    if scenario == "memory":
        try:
            block = bytearray(80 * 1024 * 1024)
            block[0] = 1
            return {"resource.memory": "ALLOCATED"}
        except (MemoryError, OSError):
            return {"resource.memory": "BLOCKED_BY_LIMIT"}
    if scenario == "processes":
        children: List[subprocess.Popen[bytes]] = []
        try:
            for _ in range(33):
                children.append(subprocess.Popen([sys.executable, "-c", "import time; time.sleep(.15)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            return {"resource.processes": "SPAWNED"}
        except OSError:
            return {"resource.processes": "BLOCKED_BY_LIMIT"}
        finally:
            for child in children:
                with contextlib.suppress(OSError):
                    child.kill()
            for child in children:
                with contextlib.suppress(OSError, subprocess.SubprocessError):
                    child.wait(timeout=1)
    raise ValueError(f"unknown resource scenario: {scenario}")


def payload_main(args: argparse.Namespace) -> int:
    fixture = read_json(Path(args.fixture))
    if not isinstance(fixture, dict) or fixture.get("synthetic_canary") != "SYNTHETIC_CANARY_ONLY":
        print("boundary payload refused non-synthetic fixture", file=sys.stderr)
        return 2
    scenario = args.scenario
    if scenario == "capabilities":
        result = payload_capabilities(fixture)
        sys.stdout.buffer.write(b"\x1b[31mSYNTHETIC_TERMINAL\x1b[0m\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07\n")
    elif scenario in ("memory", "processes"):
        result = payload_resource(scenario)
    elif scenario == "output":
        result = {"resource.output": "EMITTED"}
        sys.stdout.buffer.write(b"O" * (MAX_CAPTURE * 2))
    elif scenario == "wall-clock":
        time.sleep(3)
        result = {"resource.wall-clock": "UNBOUNDED"}
    else:
        print(f"unknown payload scenario: {scenario}", file=sys.stderr)
        return 2
    atomic_json(Path(args.result), result)
    return 0


class CanaryTCPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        with contextlib.suppress(OSError):
            self.request.sendall(b"SYNTHETIC_CANARY")


class CanaryUDPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        data, sock = self.request
        with contextlib.suppress(OSError):
            sock.sendto(b"SYNTHETIC_CANARY:" + data[:16], self.client_address)


class ThreadingTCP6(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True


class ThreadingTCP4(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True


class ThreadingUDP4(socketserver.ThreadingUDPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True


class ThreadingUnix(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True


class QuietHTTPHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = b"SYNTHETIC_DOH_CANARY"
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: Any) -> None:
        del args


@contextlib.contextmanager
def serving(server: socketserver.BaseServer) -> Iterable[socketserver.BaseServer]:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


def make_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o700)


def valid_action_request(sequence: int = 1, blob: str = "") -> Dict[str, Any]:
    return {
        "task_id": f"synthetic-task-{sequence}",
        "domain": "synthetic",
        "action_kind": "email.send",
        "target": "smtp://safe-sink.example.invalid",
        "parameters": {"recipient": "canary@example.invalid", "body": blob or "synthetic"},
        "requested_consent_tier": "confirm-first",
        "environment": "test",
        "policy_version": "synthetic-v1",
        "idempotency_key": f"synthetic-idem-{sequence}",
        "expires_at": int(time.time()) + 3600,
        "nonce": f"synthetic-nonce-{sequence}",
        "requester_id": "synthetic-worker",
    }


def gateway_env(root: Path) -> Dict[str, str]:
    home = root / "gateway-home"
    state = root / "gateway-state"
    home.mkdir(mode=0o700, exist_ok=True)
    state.mkdir(mode=0o700, exist_ok=True)
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "TMPDIR": str(root / "tmp"),
        "FM_HOME": str(home),
        "FM_DATA_OVERRIDE": str(root / "gateway-data"),
        "FM_ACTION_GATEWAY_TEST": "1",
        "FM_ACTION_GATEWAY_ROOT": str(state),
        "FM_ACTION_AUDIT_LOG": str(state / "action-audit.log"),
        "FM_ACTION_GATEWAY_ROLE": "worker",
        "FM_ACTION_CAPTAIN_SECRET": "SYNTHETIC_SECRET_NOT_REAL",
    }


def invoke_gateway(gateway: Path, env: Dict[str, str], request: bytes, timeout: float = 8.0) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(gateway), "prepare"],
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=timeout,
        check=False,
    )


def kv_value(output: bytes, key: str) -> str:
    prefix = key.encode() + b"="
    for line in output.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].decode("utf-8", "replace")
    return ""


def canary_present(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def gateway_probes(gateway: Path, root: Path) -> Tuple[Dict[str, str], Dict[str, str], Dict[str, str]]:
    env = gateway_env(root)
    Path(env["TMPDIR"]).mkdir(mode=0o700, exist_ok=True)
    first_raw = json.dumps(valid_action_request(), separators=(",", ":")).encode()
    first = invoke_gateway(gateway, env, first_raw)
    digest = kv_value(first.stdout, "digest")
    state = Path(env["FM_ACTION_GATEWAY_ROOT"])
    paths = {
        "gateway_database": str(state / "action-audit.log"),
        "gateway_audit": str(state / "action-audit.log"),
        "gateway_inbox": str(state / "captain-inbox" / f"{digest}.approval"),
    }

    malformed = invoke_gateway(gateway, env, b'{"task_id":')
    replay = invoke_gateway(gateway, env, first_raw)
    oversized_request = valid_action_request(2, "X" * (1024 * 1024 + 1))
    oversized = invoke_gateway(gateway, env, json.dumps(oversized_request, separators=(",", ":")).encode())

    accepted = 0
    flood_total = 12
    for sequence in range(100, 100 + flood_total):
        raw = json.dumps(valid_action_request(sequence), separators=(",", ":")).encode()
        completed = invoke_gateway(gateway, env, raw)
        if completed.returncode == 0:
            accepted += 1

    crashing = subprocess.Popen(
        [str(gateway), "prepare"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    if crashing.stdin is not None:
        with contextlib.suppress(OSError):
            crashing.stdin.write(b'{"task_id":"synthetic-interrupted"')
            crashing.stdin.flush()
    time.sleep(0.05)
    with contextlib.suppress(OSError):
        os.killpg(crashing.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        crashing.wait(timeout=1)
    if crashing.stdin is not None:
        with contextlib.suppress(OSError):
            crashing.stdin.close()

    restart = subprocess.run(
        [str(gateway), "status", "--digest", digest],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=8,
        check=False,
    )
    results = {
        "gateway.actionrequest-malformed": "REJECTED" if malformed.returncode != 0 else "ACCEPTED",
        "gateway.actionrequest-replayed": "REJECTED" if replay.returncode != 0 else "ACCEPTED",
        "gateway.actionrequest-oversized": "REJECTED" if oversized.returncode != 0 else "ACCEPTED",
        "gateway.actionrequest-flooded": "RATE_LIMITED" if accepted < flood_total else "ACCEPTED_ALL",
        "recovery.crash-restart": "STATE_PRESERVED" if first.returncode == 0 and restart.returncode == 0 else "STATE_LOST",
    }
    state_canaries = {
        "gateway.database-read": Path(paths["gateway_database"]),
        "gateway.inbox-read": Path(paths["gateway_inbox"]),
        "gateway.audit-write": Path(paths["gateway_audit"]),
    }
    if first.returncode != 0:
        for probe in ALL_PROBES:
            if probe.startswith("gateway.actionrequest-"):
                results[probe] = "NO_BASELINE"
        unmeasured = {probe: "NO_BASELINE" for probe in state_canaries}
    else:
        unmeasured = {
            probe: "NO_CANARY" for probe, path in state_canaries.items() if not canary_present(path)
        }
    return results, paths, unmeasured


def launcher_env(fixture: Dict[str, Any], worker_home: Path) -> Dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": str(worker_home),
        "TMPDIR": str(worker_home / "tmp"),
        "FM_SYNTHETIC_BOUNDARY_RUN": "1",
        "SSH_AUTH_SOCK": fixture["paths"]["ssh_socket"],
        "GIT_CONFIG_GLOBAL": fixture["paths"]["git_config"],
        "LC_ALL": "C",
    }


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        with contextlib.suppress(OSError):
            process.kill()
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=1)


def invoke_payload(
    script: Path,
    scenario: str,
    fixture_path: Path,
    result_path: Path,
    env: Dict[str, str],
    inherited_fd: int,
    adapter: Optional[Path],
    timeout: float,
) -> Tuple[int, bytes, bytes, bool]:
    result_path.unlink(missing_ok=True)
    if adapter:
        command = [
            str(adapter),
            "--scenario",
            scenario,
            "--payload",
            str(script),
            "--fixture",
            str(fixture_path),
            "--result",
            str(result_path),
        ]
    else:
        command = [
            str(script),
            "__payload",
            "--scenario",
            scenario,
            "--fixture",
            str(fixture_path),
            "--result",
            str(result_path),
        ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        pass_fds=(inherited_fd,),
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return process.returncode, stdout, stderr, False
    except subprocess.TimeoutExpired:
        terminate_process(process)
        try:
            stdout, stderr = process.communicate(timeout=CLEANUP_TIMEOUT)
        except subprocess.TimeoutExpired:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    with contextlib.suppress(OSError):
                        stream.close()
            raise subprocess.SubprocessError(
                f"payload scenario {scenario} survived termination and still holds its output pipes"
            ) from None
        return process.returncode or -9, stdout, stderr, True


def contains_terminal_control(data: bytes) -> bool:
    return b"\x1b" in data or b"\x07" in data or b"\x9b" in data


def read_payload_result(result_path: Path) -> Optional[Dict[str, Any]]:
    try:
        reported = read_json(result_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    return reported if isinstance(reported, dict) else None


def merge_payload_results(actual: Dict[str, str], result_path: Path, scenario: str) -> bool:
    allowed = PAYLOAD_REPORTABLE_PROBES.get(scenario, ())
    reported = read_payload_result(result_path)
    if not allowed or reported is None:
        return False
    complete = True
    for probe in allowed:
        value = reported.get(probe)
        if isinstance(value, str) and value:
            actual[probe] = value
        else:
            complete = False
    return complete


def payload_ran_marker(result_path: Path, probe: str, marker: str) -> bool:
    reported = read_payload_result(result_path)
    return reported is not None and reported.get(probe) == marker


def write_hostile_archives(root: Path) -> Dict[str, Path]:
    archives: Dict[str, Path] = {}
    traversal = root / "traversal.tar"
    with tarfile.open(traversal, "w") as archive:
        info = tarfile.TarInfo("../../outside-canary")
        payload = b"SYNTHETIC_TRAVERSAL"
        info.size = len(payload)
        import io
        archive.addfile(info, io.BytesIO(payload))
    archives["artifact.traversal"] = traversal

    symlink = root / "symlink.tar"
    with tarfile.open(symlink, "w") as archive:
        link = tarfile.TarInfo("escape-link")
        link.type = tarfile.SYMTYPE
        link.linkname = "../../outside-canary"
        archive.addfile(link)
        info = tarfile.TarInfo("escape-link/payload")
        payload = b"SYNTHETIC_SYMLINK"
        info.size = len(payload)
        import io
        archive.addfile(info, io.BytesIO(payload))
    archives["artifact.symlink-escape"] = symlink
    return archives


def artifact_probes(adapter: Optional[Path], root: Path, env: Dict[str, str]) -> Dict[str, str]:
    results: Dict[str, str] = {}
    artifact_root = root / "artifacts"
    artifact_root.mkdir(mode=0o700)
    archives = write_hostile_archives(artifact_root)
    for probe, archive in archives.items():
        destination = artifact_root / (probe.replace(".", "-") + "-destination")
        outside = artifact_root / "outside-canary"
        outside.write_text("SYNTHETIC_OUTSIDE_UNCHANGED\n", encoding="utf-8")
        destination.mkdir(mode=0o700)
        if adapter is None:
            results[probe] = "NO_IMPORTER"
            continue
        completed = subprocess.run(
            [str(adapter), "--input", str(archive), "--destination", str(destination)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=8,
            check=False,
        )
        unchanged = outside.read_text(encoding="utf-8") == "SYNTHETIC_OUTSIDE_UNCHANGED\n"
        empty = not any(destination.iterdir())
        results[probe] = "REJECTED" if completed.returncode != 0 and unchanged and empty else "ESCAPED_OR_IMPORTED"
    return results


def resolve_source(repo: Path, value: str) -> Path:
    return Path(value.replace("${REPO}", str(repo))).resolve()


def manifest_list(manifest: Dict[str, Any], key: str) -> List[Any]:
    value = manifest.get(key)
    return value if isinstance(value, list) else []


def source_invariant_probes(manifest_path: Path, repo: Path) -> Dict[str, str]:
    failed = {probe: "FAIL" for probe in OTHER_PROBES if probe.startswith("source.")}
    try:
        manifest = read_json(manifest_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return failed
    if not isinstance(manifest, dict) or manifest.get("schema") != MANIFEST_SCHEMA:
        return failed

    privileged_paths = manifest_list(manifest, "privileged_paths")
    root_chain = bool(privileged_paths)
    approved_prefixes = (
        "/Library/PrivilegedHelperTools/firstmate/",
        "/Library/LaunchDaemons/",
        "/var/db/firstmate/gateway/",
        "/var/run/firstmate/",
    )
    for entry in privileged_paths:
        if not isinstance(entry, dict):
            root_chain = False
            continue
        install_path = str(entry.get("install_path", ""))
        path_kind = entry.get("kind")
        check_source = entry.get("ancestor_check_source")
        if path_kind not in ("executable", "config", "state") or not install_path.startswith(approved_prefixes) or not check_source:
            root_chain = False
            continue
        source = resolve_source(repo, str(check_source))
        try:
            text = source.read_text(encoding="utf-8")
        except OSError:
            root_chain = False
            continue
        required_tokens = ("root", "ancestor", "uid", "stat")
        if not all(token in text.lower() for token in required_tokens):
            root_chain = False

    privileged_sources = [resolve_source(repo, str(path)) for path in manifest_list(manifest, "privileged_sources")]
    no_worker_path = bool(privileged_sources)
    no_override = bool(privileged_sources)
    worker_path_tokens = ("--file", "worker_selected_path", "request[\"path\"]", "request.get(\"path\")")
    trust_override_tokens = tuple(str(token) for token in manifest_list(manifest, "forbidden_production_trust_env"))
    for source in privileged_sources:
        try:
            text = source.read_text(encoding="utf-8")
        except OSError:
            no_worker_path = False
            no_override = False
            continue
        if any(token in text for token in worker_path_tokens):
            no_worker_path = False
        if any(token in text for token in trust_override_tokens):
            no_override = False

    sockets = manifest_list(manifest, "sockets")
    required_purposes = {str(purpose) for purpose in manifest_list(manifest, "required_socket_purposes")}
    purposes: List[str] = []
    schemas: List[str] = []
    schema_ok = bool(sockets) and bool(required_purposes)
    peer_ok = bool(sockets) and bool(required_purposes)
    for entry in sockets:
        if not isinstance(entry, dict):
            schema_ok = False
            peer_ok = False
            continue
        purpose = str(entry.get("purpose", ""))
        schema = str(entry.get("schema", ""))
        source_value = entry.get("source")
        purposes.append(purpose)
        schemas.append(schema)
        if not purpose or not schema or not source_value:
            schema_ok = False
            peer_ok = False
            continue
        source = resolve_source(repo, str(source_value))
        try:
            text = source.read_text(encoding="utf-8")
        except OSError:
            schema_ok = False
            peer_ok = False
            continue
        if schema not in text or purpose not in text:
            schema_ok = False
        if not any(token in text for token in ("getpeereid", "SO_PEERCRED", "LOCAL_PEERCRED")):
            peer_ok = False
    if len(purposes) != len(set(purposes)) or len(schemas) != len(set(schemas)):
        schema_ok = False
    if not required_purposes.issubset(set(purposes)):
        schema_ok = False
        peer_ok = False

    return {
        "source.root-owned-ancestor-chain": "PASS" if root_chain else "FAIL",
        "source.no-worker-selected-privileged-open": "PASS" if no_worker_path else "FAIL",
        "source.no-production-trust-override": "PASS" if no_override else "FAIL",
        "source.single-purpose-socket-schemas": "PASS" if schema_ok else "FAIL",
        "source.socket-peer-credentials": "PASS" if peer_ok else "FAIL",
    }


def launcher_attestation_probe(attestation: Optional[Path], manifest_path: Path) -> str:
    if not attestation:
        return "UNATTESTED"
    try:
        value = read_json(attestation)
        manifest = read_json(manifest_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return "DRIFTED"
    if not isinstance(value, dict) or not isinstance(manifest, dict):
        return "DRIFTED"
    required = manifest.get("launcher_attestation")
    if not isinstance(required, dict) or not required:
        return "DRIFTED"
    if any(value.get(key) != expected for key, expected in required.items()):
        return "DRIFTED"
    return "ATTESTED"


def record_results(actual: Dict[str, str], target: str) -> Tuple[List[Dict[str, Any]], int]:
    records: List[Dict[str, Any]] = []
    failed = 0
    active = "native-account" if target == "ambient" else target
    for probe in ALL_PROBES:
        actual_value = actual.get(probe, "NOT_RUN")
        expected = expectations(probe)
        passed = actual_value in expected[active]
        if not passed:
            failed += 1
        records.append(
            {
                "probe": probe,
                "actual": actual_value,
                "expected": expected,
                "evaluated_as": active,
                "result": "PASS" if passed else "FAIL",
                "synthetic": True,
            }
        )
    return records, failed


def make_fixture(root: Path, gateway_paths: Dict[str, str], inherited_fd: int) -> Tuple[Dict[str, Any], List[contextlib.AbstractContextManager[Any]]]:
    captain = root / "captain"
    worker = root / "worker"
    services = root / "services"
    for directory in (captain, worker, services):
        directory.mkdir(mode=0o700)
    (worker / "tmp").mkdir(mode=0o700)
    (worker / "out").mkdir(mode=0o777)

    keychain = captain / "Library" / "Keychains" / "synthetic.keychain-db"
    chrome = captain / "Library" / "Application Support" / "Google" / "Chrome" / "Synthetic" / "canary"
    tcc = captain / "Library" / "Application Support" / "com.apple.TCC" / "TCC-synthetic.db"
    for path in (keychain, chrome, tcc):
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        path.write_text("SYNTHETIC_CANARY_ONLY\n", encoding="utf-8")
        path.chmod(0o600)

    tools = captain / "tools"
    tools.mkdir(mode=0o700)
    keychain_api = tools / "security-synthetic"
    git_helper = tools / "git-credential-synthetic"
    make_executable(keychain_api, "#!/bin/sh\nprintf '%s\\n' SYNTHETIC_CANARY\n")
    make_executable(git_helper, "#!/bin/sh\nprintf '%s\\n' SYNTHETIC_CANARY\n")
    git_config = captain / "gitconfig"
    git_config.write_text(f"[credential]\n\thelper = {git_helper}\n", encoding="utf-8")
    git_config.chmod(0o600)

    managers: List[contextlib.AbstractContextManager[Any]] = []
    tcp4 = ThreadingTCP4(("127.0.0.1", 0), CanaryTCPHandler)
    managers.append(serving(tcp4))
    loop_tcp = ThreadingTCP4(("127.0.0.1", 0), CanaryTCPHandler)
    managers.append(serving(loop_tcp))
    dns = ThreadingUDP4(("127.0.0.1", 0), CanaryUDPHandler)
    managers.append(serving(dns))
    loop_udp = ThreadingUDP4(("127.0.0.1", 0), CanaryUDPHandler)
    managers.append(serving(loop_udp))
    doh = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHTTPHandler)
    managers.append(serving(doh))

    ipv6_port: Optional[int] = None
    try:
        tcp6 = ThreadingTCP6(("::1", 0), CanaryTCPHandler)
        ipv6_port = int(tcp6.server_address[1])
        managers.append(serving(tcp6))
    except OSError:
        pass

    socket_paths: Dict[str, str] = {}
    for name in ("unix", "ssh", "clipboard", "tcc", "docker"):
        path = services / f"{name}.sock"
        server = ThreadingUnix(str(path), CanaryTCPHandler)
        managers.append(serving(server))
        socket_paths[name] = str(path)

    fixture = {
        "schema": "fm-worker-boundary-fixture.v1",
        "synthetic_canary": "SYNTHETIC_CANARY_ONLY",
        "inherited_fd": inherited_fd,
        "endpoints": {
            "ipv4": int(tcp4.server_address[1]),
            "ipv6": ipv6_port,
            "dns": int(dns.server_address[1]),
            "doh": int(doh.server_address[1]),
            "loopback_tcp": int(loop_tcp.server_address[1]),
            "loopback_udp": int(loop_udp.server_address[1]),
        },
        "paths": {
            "unix_socket": socket_paths["unix"],
            "ssh_socket": socket_paths["ssh"],
            "clipboard_socket": socket_paths["clipboard"],
            "tcc_socket": socket_paths["tcc"],
            "docker_socket": socket_paths["docker"],
            "keychain_file": str(keychain),
            "keychain_api": str(keychain_api),
            "git_helper": str(git_helper),
            "git_config": str(git_config),
            "chrome_file": str(chrome),
            "tcc_database": str(tcc),
            **gateway_paths,
        },
    }
    return fixture, managers


def run_pack(args: argparse.Namespace) -> int:
    script = Path(os.environ["FM_WORKER_BOUNDARY_SCRIPT"]).resolve()
    repo = script.parent.parent
    gateway = Path(args.gateway).resolve() if args.gateway else repo / "bin" / "fm-action-gateway.sh"
    manifest = Path(args.source_manifest).resolve() if args.source_manifest else repo / "docs" / "fm-worker-boundary-source.json"
    launcher_adapter = Path(args.launcher_adapter).resolve() if args.launcher_adapter else None
    artifact_adapter = Path(args.artifact_adapter).resolve() if args.artifact_adapter else None
    temp_root = Path(tempfile.mkdtemp(prefix="fm-worker-boundary-"))
    temp_root.chmod(0o700)
    inherited_peer, inherited_socket = socket.socketpair()
    inherited_peer.sendall(b"SYNTHETIC_DESCRIPTOR_CANARY")
    read_fd = inherited_socket.fileno()
    actual: Dict[str, str] = {}
    try:
        gateway_results, gateway_paths, gateway_unmeasured = gateway_probes(gateway, temp_root)
        actual.update(gateway_results)
        fixture, managers = make_fixture(temp_root, gateway_paths, read_fd)
        fixture_path = temp_root / "worker" / "fixture.json"
        result_path = temp_root / "worker" / "out" / "result.json"
        atomic_json(fixture_path, fixture)
        env = launcher_env(fixture, temp_root / "worker")

        with contextlib.ExitStack() as stack:
            for manager in managers:
                stack.enter_context(manager)
            rc, stdout, _stderr, timed_out = invoke_payload(
                script, "capabilities", fixture_path, result_path, env, read_fd, launcher_adapter, PAYLOAD_TIMEOUT
            )
            if rc == 0 and not timed_out and merge_payload_results(actual, result_path, "capabilities"):
                actual["terminal.control-output"] = "SANITIZED" if not contains_terminal_control(stdout) else "UNSANITIZED"

            for scenario, probe in (("memory", "resource.memory"), ("processes", "resource.processes")):
                rc, _stdout, _stderr, timed_out = invoke_payload(
                    script, scenario, fixture_path, result_path, env, read_fd, launcher_adapter, PAYLOAD_TIMEOUT
                )
                if timed_out:
                    actual[probe] = "HARNESS_KILLED"
                elif rc < 0:
                    actual[probe] = "BLOCKED_BY_LIMIT"
                elif rc > 0:
                    actual[probe] = "NOT_RUN"
                elif not merge_payload_results(actual, result_path, scenario):
                    actual[probe] = "NOT_REPORTED"

            rc, stdout, _stderr, timed_out = invoke_payload(
                script, "output", fixture_path, result_path, env, read_fd, launcher_adapter, PAYLOAD_TIMEOUT
            )
            if rc == 0 and not timed_out and payload_ran_marker(result_path, "resource.output", "EMITTED"):
                actual["resource.output"] = "BOUNDED" if len(stdout) <= MAX_CAPTURE else "UNBOUNDED"

            rc, _stdout, _stderr, timed_out = invoke_payload(
                script, "wall-clock", fixture_path, result_path, env, read_fd, launcher_adapter, RESOURCE_TIMEOUT
            )
            if timed_out:
                actual["resource.wall-clock"] = "HARNESS_KILLED"
            elif rc == 0:
                actual["resource.wall-clock"] = "UNBOUNDED"
            elif rc < 0:
                actual["resource.wall-clock"] = "BOUNDED"

        actual.update(artifact_probes(artifact_adapter, temp_root, env))
        actual.update(source_invariant_probes(manifest, repo))
        actual["launcher.drift"] = launcher_attestation_probe(Path(args.attestation).resolve() if args.attestation else None, manifest)
        actual.update(gateway_unmeasured)
        records, failed = record_results(actual, args.target)
        report = {
            "schema": SCHEMA,
            "target": args.target,
            "synthetic_only": True,
            "temporary_root": "<temporary-root>",
            "gateway": str(gateway.relative_to(repo)) if gateway.is_relative_to(repo) else "<external-adapter>",
            "source_manifest": str(manifest.relative_to(repo)) if manifest.is_relative_to(repo) else "<external-manifest>",
            "summary": {"total": len(records), "passed": len(records) - failed, "failed": failed},
            "records": records,
        }
        if args.report:
            atomic_json(Path(args.report).resolve(), report)
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
        if args.keep_temp:
            print(f"synthetic temporary root kept at {temp_root}", file=sys.stderr)
        return 1 if failed else 0
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
        print(f"fm-worker-boundary-regression: setup failed: {exc}", file=sys.stderr)
        return 2
    finally:
        inherited_socket.close()
        inherited_peer.close()
        if not args.keep_temp:
            shutil.rmtree(temp_root, ignore_errors=True)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command == "__payload":
        return payload_main(args)
    if args.list_probes:
        for probe in ALL_PROBES:
            print(probe)
        return 0
    if args.check_source_only:
        script = Path(os.environ["FM_WORKER_BOUNDARY_SCRIPT"]).resolve()
        actual = source_invariant_probes(Path(args.source_manifest).resolve(), script.parent.parent)
        print(json.dumps(actual, sort_keys=True, separators=(",", ":")))
        return 0 if actual and set(actual.values()) == {"PASS"} else 1
    return run_pack(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

PY

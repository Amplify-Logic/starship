#!/usr/bin/env bash
# fm-action-gateway.sh - stub outward-action gateway (schema + audit only).
#
# Accepts an ActionRequest JSON on stdin or via --file <path>, validates the
# schema owned by docs/action-gateway.md, durably appends one audit record to
# data/action-audit.log (append-only, fsync'd), and only THEN prints a decision.
# This stub ALWAYS decides confirm-first and NEVER executes any action.
#
# Ordering contract (load-bearing for later slices): the audit record must commit
# before any decision is emitted, so a failed audit write yields no decision and
# no side effect can ever precede its audit line.
#
# Usage:
#   fm-action-gateway.sh [--file <path>]
#   fm-action-gateway.sh -h|--help
#   printf '%s' "$json" | fm-action-gateway.sh
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE - home and data roots
#   FM_ACTION_AUDIT_LOG - override audit log path (tests)
#
# Exit:
#   0 on validated request + durable audit + decision printed
#   1 on usage, schema, or audit failure
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF' >&2
usage: fm-action-gateway.sh [--file <path>]
       fm-action-gateway.sh -h|--help

Stub action gateway: validate ActionRequest JSON, append a durable audit record,
then print decision=confirm-first. Never executes an action.
Schema and contract: docs/action-gateway.md.
EOF
}

fail() {
  printf 'fm-action-gateway: %s\n' "$*" >&2
  exit 1
}

audit_log_path() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ]; then
    printf '%s\n' "$FM_ACTION_AUDIT_LOG"
    return 0
  fi
  printf '%s\n' "$DATA/action-audit.log"
}

# Validate ActionRequest JSON on stdin; print normalized JSON on stdout.
# Required keys: task_id, domain, action_kind, target, parameters, requested_consent_tier.
validate_request() {
  python3 -c '
import json, sys, re

raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(obj, dict):
    print("ActionRequest must be a JSON object", file=sys.stderr)
    sys.exit(1)

required = (
    "task_id",
    "domain",
    "action_kind",
    "target",
    "parameters",
    "requested_consent_tier",
)
missing = [k for k in required if k not in obj]
if missing:
    print("missing fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

task_id = obj["task_id"]
if not isinstance(task_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", task_id) or re.fullmatch(r"\.+", task_id):
    print("task_id must be 1-64 chars from [A-Za-z0-9._-] and not dots-only", file=sys.stderr)
    sys.exit(1)

for key in ("domain", "action_kind", "target", "requested_consent_tier"):
    val = obj[key]
    if not isinstance(val, str) or not val.strip():
        print(f"{key} must be a non-empty string", file=sys.stderr)
        sys.exit(1)

if not isinstance(obj["parameters"], dict):
    print("parameters must be a JSON object", file=sys.stderr)
    sys.exit(1)

tier = obj["requested_consent_tier"]
allowed = {"confirm-first", "autonomous", "sandbox"}
if tier not in allowed:
    print(
        "requested_consent_tier must be one of: " + ", ".join(sorted(allowed)),
        file=sys.stderr,
    )
    sys.exit(1)

# Reject unknown top-level keys so later schema growth stays intentional.
unknown = sorted(set(obj) - set(required))
if unknown:
    print("unknown fields: " + ", ".join(unknown), file=sys.stderr)
    sys.exit(1)

json.dump(obj, sys.stdout, separators=(",", ":"), sort_keys=True)
print()
'
}

# Append one UTF-8 line to the audit log and fsync file + parent directory.
# Returns non-zero if the durable write fails; callers must not emit a decision.
durable_append_line() {
  local path=$1
  local line=$2
  python3 -c '
import os, sys

path = sys.argv[1]
line = sys.argv[2]
if not line.endswith("\n"):
    line = line + "\n"
data = line.encode("utf-8")
parent = os.path.dirname(path) or "."
os.makedirs(parent, exist_ok=True)
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
try:
    written = 0
    while written < len(data):
        n = os.write(fd, data[written:])
        if n <= 0:
            raise OSError("short write to audit log")
        written += n
    os.fsync(fd)
finally:
    os.close(fd)
dir_fd = os.open(parent, os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
' "$path" "$line"
}

build_audit_record() {
  local request_json=$1
  local decision=$2
  python3 -c '
import json, sys, time

request = json.loads(sys.argv[1])
decision = sys.argv[2]
record = {
    "ts": int(time.time()),
    "decision": decision,
    "request": request,
}
json.dump(record, sys.stdout, separators=(",", ":"), sort_keys=True)
print()
' "$request_json" "$decision"
}

main() {
  local file='' input request_json decision audit_path record
  decision=confirm-first

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --file)
        [ "$#" -ge 2 ] || fail "--file requires a path"
        file=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done

  if [ -n "$file" ]; then
    [ -f "$file" ] || fail "request file not found: $file"
    input=$(cat "$file")
  else
    input=$(cat)
  fi

  local err_file
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-action-gateway.XXXXXX")
  if ! request_json=$(printf '%s' "$input" | validate_request 2>"$err_file"); then
    # Surface validator stderr, then fail closed with no audit and no decision.
    cat "$err_file" >&2 || true
    rm -f "$err_file"
    fail "schema validation failed"
  fi
  rm -f "$err_file"

  audit_path=$(audit_log_path)
  record=$(build_audit_record "$request_json" "$decision") || fail "could not build audit record"
  durable_append_line "$audit_path" "$record" || fail "durable audit append failed"

  # Decision is emitted only after the audit line has been fsync'd.
  printf 'decision=%s\n' "$decision"
}

main "$@"

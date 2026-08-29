#!/usr/bin/env bash
# fm-tray.sh - read-only renderer over the action gateway's durable records.
#
# The tray is not a store. It reads data/action-gateway/ (the gateway audit log)
# and renders PENDING (prepared) staged actions. AGE is the headline: oldest
# first, expired marked. It never prepares, approves, executes, or otherwise
# mutates gateway state. Approval stays on fm-action-gateway.sh captain-role
# commands. Schema: docs/ops-command-center.md, docs/action-gateway.md.
#
# Commands:
#   (default) [--order SLUG]  table of pending actions, oldest first, plus counts
#   counts [--order SLUG]     counts line only: TRAY <n> · OLDEST <age>
#     --order SLUG keeps only requests whose ActionRequest domain is that slug
#   show <digest>             full canonical action context (delegates to gateway)
#   -h|--help
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE - home and data roots (override requires test mode)
#   FM_ACTION_GATEWAY_TEST=1   - allow path/time overrides
#   FM_ACTION_AUDIT_LOG        - override audit log path (test mode only)
#   FM_ACTION_GATEWAY_ROOT     - override gateway state root (test mode only)
#   FM_ACTION_GATEWAY_NOW      - override unix epoch for age/expiry (test mode)
#
# Exit:
#   0 on success
#   1 on usage, missing digest, or gateway show failure
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF' >&2
usage: fm-tray.sh [--order <slug>]
       fm-tray.sh counts [--order <slug>]
       fm-tray.sh show <digest>
       fm-tray.sh -h|--help

Read-only tray over the action gateway audit log.
Pending (prepared) actions, oldest first; AGE is the headline.
Never approves, executes, or mutates gateway state.
Approval stays on fm-action-gateway.sh. See docs/ops-command-center.md.
EOF
}

fail() {
  printf 'fm-tray: %s\n' "$*" >&2
  exit 1
}

require_test_mode_for_overrides() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ] || [ -n "${FM_ACTION_GATEWAY_ROOT:-}" ] \
    || [ -n "${FM_DATA_OVERRIDE:-}" ] || [ -n "${FM_ACTION_GATEWAY_NOW:-}" ]; then
    if [ "${FM_ACTION_GATEWAY_TEST:-}" != "1" ]; then
      fail "path/time overrides require FM_ACTION_GATEWAY_TEST=1"
    fi
  fi
}

gateway_root() {
  if [ -n "${FM_ACTION_GATEWAY_ROOT:-}" ]; then
    printf '%s\n' "$FM_ACTION_GATEWAY_ROOT"
    return 0
  fi
  printf '%s\n' "$DATA/action-gateway"
}

audit_log_path() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ]; then
    printf '%s\n' "$FM_ACTION_AUDIT_LOG"
    return 0
  fi
  printf '%s\n' "$(gateway_root)/action-audit.log"
}

# Read-only reconstruction of prepared actions from the audit log.
# Prints JSON array. Never appends, never calls gateway replay.
pending_json() {
  local audit=$1 order=${2-}
  python3 - "$audit" "$order" <<'PY'
import json
import os
import sys
import time

AUDIT = sys.argv[1]
ORDER = sys.argv[2].strip() if len(sys.argv) > 2 else ""
TERMINAL = {"succeeded", "failed", "unknown"}


def now_ts() -> int:
    if os.environ.get("FM_ACTION_GATEWAY_TEST", "") == "1":
        env = os.environ.get("FM_ACTION_GATEWAY_NOW", "").strip()
        if env:
            return int(env)
    return int(time.time())


def format_age(secs: int) -> str:
    if secs < 0:
        secs = 0
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


now = now_ts()
by = {}
if os.path.isfile(AUDIT):
    with open(AUDIT, "r", encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                print(f"fm-tray: audit line {line_no} is not JSON", file=sys.stderr)
                sys.exit(1)
            if not isinstance(ev, dict):
                continue
            digest = ev.get("digest")
            et = ev.get("event")
            if not digest or not et:
                continue
            st = by.get(digest)
            if st is None:
                st = {
                    "digest": digest,
                    "state": None,
                    "prepared_ts": None,
                    "request": {},
                    "requester_id": None,
                    "expires_at": None,
                    "action_kind": "",
                    "target": "",
                    "domain": "",
                }
                by[digest] = st
            if et == "prepared":
                req = ev.get("request") if isinstance(ev.get("request"), dict) else {}
                st["state"] = "prepared"
                st["prepared_ts"] = ev.get("ts")
                st["request"] = req
                st["requester_id"] = ev.get("requester_id") or req.get("requester_id")
                st["expires_at"] = ev.get("expires_at") if ev.get("expires_at") is not None else req.get("expires_at")
                st["action_kind"] = req.get("action_kind") or ""
                st["target"] = req.get("target") or ""
                st["domain"] = req.get("domain") or ""
            elif et == "approved":
                st["state"] = "approved"
            elif et == "executing":
                st["state"] = "executing"
            elif et in TERMINAL:
                st["state"] = et
            # refused does not advance state

pending = []
for st in by.values():
    if st["state"] != "prepared":
        continue
    if ORDER and st["domain"] != ORDER:
        continue
    prepared_ts = st["prepared_ts"]
    try:
        prepared_ts = int(prepared_ts) if prepared_ts is not None else now
    except (TypeError, ValueError):
        prepared_ts = now
    expires_at = st["expires_at"]
    try:
        expires_at = int(expires_at) if expires_at is not None else None
    except (TypeError, ValueError):
        expires_at = None
    age_secs = now - prepared_ts
    expired = expires_at is not None and expires_at <= now
    if expired:
        expiry = "EXPIRED"
    elif expires_at is None:
        expiry = "-"
    else:
        expiry = format_age(expires_at - now)
    requester = st["requester_id"] or "-"
    domain = st["domain"] or "-"
    pending.append(
        {
            "digest": st["digest"],
            "digest_short": st["digest"][:12],
            "domain": domain,
            "requester_id": requester,
            "order_requester": f"{domain} / {requester}",
            "action_kind": st["action_kind"] or "-",
            "target": st["target"] or "-",
            "age_secs": age_secs,
            "age": format_age(age_secs),
            "expiry": expiry,
            "expired": expired,
            "prepared_ts": prepared_ts,
        }
    )

pending.sort(key=lambda r: (r["prepared_ts"], r["digest"]))
print(json.dumps(pending, separators=(",", ":"), ensure_ascii=False))
PY
}

counts_line() {
  local json=$1
  python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
n = len(rows)
if n == 0:
    print("TRAY 0 · OLDEST -")
else:
    print("TRAY %s · OLDEST %s" % (n, rows[0]["age"]))
' "$json"
}

render_table() {
  local json=$1
  python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
n = len(rows)
if n == 0:
    print("TRAY 0 · OLDEST -")
    print("(no pending staged actions)")
    sys.exit(0)
print("TRAY %s · OLDEST %s" % (n, rows[0]["age"]))
print("")
print("DIGEST        ORDER / REQUESTER              KIND                    TARGET                    AGE  EXPIRY")
for r in rows:
    print("%-12s  %-28s  %-22s  %-24s  %-4s %s" % (
        r["digest_short"],
        r["order_requester"][:28],
        r["action_kind"][:22],
        r["target"][:24],
        r["age"],
        r["expiry"],
    ))
' "$json"
}

resolve_digest() {
  local needle=$1 audit=$2
  python3 - "$needle" "$audit" <<'PY'
import json, os, sys
needle = sys.argv[1].strip().lower()
audit = sys.argv[2]
if len(needle) < 12 or any(c not in "0123456789abcdef" for c in needle):
    print("fm-tray: digest must be hex (at least 12 chars)", file=sys.stderr)
    sys.exit(1)
found = []
seen = set()
if os.path.isfile(audit):
    with open(audit, "r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            d = ev.get("digest")
            if not isinstance(d, str) or d in seen:
                continue
            seen.add(d)
            if d == needle or d.startswith(needle):
                found.append(d)
if len(found) == 1:
    print(found[0])
    sys.exit(0)
if len(found) == 0:
    print("fm-tray: unknown digest", file=sys.stderr)
    sys.exit(1)
print("fm-tray: digest prefix is ambiguous", file=sys.stderr)
sys.exit(1)
PY
}

cmd_table() {
  local order='' json audit
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --order)
        [ "$#" -ge 2 ] || fail "--order requires a slug"
        order=$2
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
  audit=$(audit_log_path)
  json=$(pending_json "$audit" "$order")
  render_table "$json"
}

cmd_counts() {
  local order='' json audit
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --order)
        [ "$#" -ge 2 ] || fail "--order requires a slug"
        order=$2
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
  audit=$(audit_log_path)
  json=$(pending_json "$audit" "$order")
  counts_line "$json"
}

cmd_show() {
  local digest='' audit resolved
  [ "$#" -ge 1 ] || fail "show requires a digest"
  digest=$1
  shift
  [ "$#" -eq 0 ] || fail "show takes a single digest"
  audit=$(audit_log_path)
  resolved=$(resolve_digest "$digest" "$audit") || exit 1
  # Delegate the canonical context to the gateway; tray does not re-render a copy.
  "$SCRIPT_DIR/fm-action-gateway.sh" show --digest "$resolved"
}

main() {
  require_test_mode_for_overrides

  if [ "$#" -eq 0 ]; then
    cmd_table
    return 0
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    counts)
      shift
      cmd_counts "$@"
      ;;
    show)
      shift
      cmd_show "$@"
      ;;
    --order)
      cmd_table "$@"
      ;;
    approve|execute|prepare|arm|disarm|graduate)
      fail "read-only: $1 stays on fm-action-gateway.sh (captain-role commands); tray never mutates"
      ;;
    *)
      fail "unknown command: $1"
      ;;
  esac
}

main "$@"

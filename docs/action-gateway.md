# Action gateway

The outward-action gateway is the single choke-point for worker side effects that leave the local machine or touch real people, money, or devices.
This document owns the ActionRequest schema and the gateway contract.
`bin/fm-action-gateway.sh` is the stub seam for this slice: schema validation plus durable audit, with every decision forced to `confirm-first` and no action execution.

## ActionRequest schema

JSON object with exactly these top-level fields:

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `task_id` | string | Path-safe task id (1-64 chars from `[A-Za-z0-9._-]`, not dots-only) |
| `domain` | string | Logical domain (for example `company`, `travel`, `music-outreach`, `app-dev`) |
| `action_kind` | string | Kind of outward action (for example `http.request`, `email.send`, `purchase`) |
| `target` | string | Action target (URL, address, device id, and so on) |
| `parameters` | object | Action-specific parameters (may be empty) |
| `requested_consent_tier` | string | One of `confirm-first`, `autonomous`, `sandbox` |

Example:

```json
{
  "task_id": "book-flight-42",
  "domain": "travel",
  "action_kind": "purchase",
  "target": "https://airline.example/checkout",
  "parameters": { "amount_cents": 42000, "currency": "EUR" },
  "requested_consent_tier": "confirm-first"
}
```

## Gateway contract

- The gateway is the single choke-point: workers emit ActionRequests; they do not fire outward side effects themselves.
- Consent tiers are watchdog-style: autonomy decays to confirm-first on anomaly, never a one-way privilege ladder.
- The audit record durably commits before any side effect fires.
- Trust state lives in the append-only audit log so a restarted gateway is confirm-first until it replays history.

## Stub behavior (this slice)

`bin/fm-action-gateway.sh` accepts an ActionRequest on stdin or via `--file`, validates the schema, appends one JSON line to `data/action-audit.log` (append-only, fsync'd file and parent directory), and only then prints `decision=confirm-first`.
A failed audit write yields no decision.
Nothing in this stub performs any outward action.

Audit line shape:

```json
{"decision":"confirm-first","request":{...},"ts":1710000000}
```

## Future work

Everything beyond this stub is future work: real allowlists, anomaly detection, watchdog graduation and demotion, dry-run sandbox graduation, interrupt-priority scheduling, and actual action execution behind a successful consent check.
Spending money and outward communications to real people stay confirm-first forever even after later slices land.
Browser isolation itself remains independent of consent tiers; see [`docs/worker-browsing.md`](worker-browsing.md).

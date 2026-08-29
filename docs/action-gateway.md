# Action gateway

The outward-action gateway is the single choke-point for worker side effects that leave the local machine or touch real people, money, or devices.
This document owns the ActionRequest schema, the canonical digest, the privilege-separated approval model, the transactional state machine, the deny-by-default operation registry, and the non-graduatable policy floor.
`bin/fm-action-gateway.sh` is the broker for this slice, with durable append-only records and **no outward action execution**; the Broker commands section below owns the command list.

## Why this exists

In software work, a bad branch can be discarded.
In a music career, the expensive mistakes are outward: an email to a booking agent, money spent on ads, a post published, a submission sent.
None of those roll back.
This gateway replaces merge/PR-style review with confirm-first consent for irreversible outward actions.

## ActionRequest schema

JSON object with exactly these top-level fields:

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `task_id` | string | Path-safe task id (1-64 chars from `[A-Za-z0-9._-]`, not dots-only) |
| `domain` | string | Logical domain (for example `music-outreach`, `travel`, `app-dev`) |
| `action_kind` | string | Registered operation name (deny-by-default; see Operation registry) |
| `target` | string | Action target (URL, address, device id, and so on) |
| `parameters` | object | Action-specific parameters (may be empty); amount/recipient fields participate in the digest |
| `requested_consent_tier` | string | One of `confirm-first`, `autonomous`, `sandbox` |
| `environment` | string | Execution environment label bound into the digest (for example `local`, `prod`) |
| `policy_version` | string | Policy version string bound into the digest |
| `idempotency_key` | string | Caller idempotency key; reuse with a differing digest is refused |
| `expires_at` | integer | Unix epoch seconds after which approve/execute refuse |
| `nonce` | string | Fresh nonce bound into the digest; reuse is refused |
| `requester_id` | string | Identity of the preparer; must differ from any later `approver_id` |

`requester_id` may be omitted from JSON when `FM_ACTION_REQUESTER_ID` is set in the environment; the broker injects it before validation.

Example:

```json
{
  "task_id": "pitch-agent-42",
  "domain": "music-outreach",
  "action_kind": "email.send",
  "target": "smtp://mail.example",
  "parameters": { "recipient": "agent@example.com", "subject": "EP pitch" },
  "requested_consent_tier": "confirm-first",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "pitch-agent-42-v1",
  "expires_at": 1893456000,
  "nonce": "n-7f3a9c2e",
  "requester_id": "worker-task-42"
}
```

## Operation registry and severity

Unknown `action_kind` values are refused at prepare (deny by default).
Severity classes follow Atelier's tool taxonomy shape (`read` / `costly` / `external` / `irreversible`):

| Severity | Meaning | Consent floor |
| -------- | ------- | ------------- |
| `read` | No meaningful side effect | may request lower tiers later; this slice still confirm-first |
| `costly` | Consumes budget / API cost | confirm-first in this slice |
| `external` | Writes to a third party on the captain's behalf | confirm-first in this slice |
| `irreversible` | Money or real-person messaging / publishing | **structurally** confirm-first forever |

Registered irreversible kinds include `purchase`, `payment`, `spend`, `transfer`, `checkout`, `ad.spend`, `email.send`, `message.send`, `sms.send`, `chat.send`, `notify.person`, `outreach.send`, `social.post`, `submission.send`, `booking.request`, `device.config.push`, and `device.firmware.push`.
Registered external kinds include `calendar.create`, `crm.update`, `file.write.remote`, `kb.fact.publish`, `course.publish`, and `sheet.write`.
The deny-by-default registry in `bin/fm-action-gateway.sh` is the owner of that list; `classify --action-kind` reports severity, ceiling, and whether a kind is graduatable without duplicating it.
No configuration, trusted-task-type rule, or escalation path may graduate spend or real-person messaging to autonomous.

## Canonical action digest

An approval binds to a SHA-256 digest over a canonical JSON object of:

- `operation` (from `action_kind`)
- `target`
- `parameters` (sorted canonical JSON)
- `amount` / `recipient` (extracted when present)
- `environment`, `policy_version`, `idempotency_key`, `expires_at`, `nonce`
- `domain`, `task_id`, `requested_consent_tier`, `requester_id`

A differing digest is a different action.
Expired digests and replayed approvals are refused.

## Privilege-separated approval

Workers must never receive an approval credential.

1. `prepare` (default role `worker`) validates, appends `prepared`, and writes the one-shot approval token **only** to `data/action-gateway/captain-inbox/<digest>.approval` (mode `0600`).
2. Worker stdout never includes `approval_token`.
3. `show --digest` renders the canonical action context for captain review before consent.
4. `approve` requires:
   - `FM_ACTION_GATEWAY_ROLE=captain`
   - the captain secret (`config/action-captain-secret`, or `FM_ACTION_CAPTAIN_SECRET` under `FM_ACTION_GATEWAY_TEST=1`)
   - `--approver-id` that is **not** equal to the request's `requester_id`
   - the inbox token binding (token is never accepted on argv)
5. Approvals are attributable (`approver_id`, `approved_at`), timestamped, and one-shot.
6. `execute` is captain-only and stubbed in this slice.

Self-approval is refused structurally even when the captain secret is known.

## Transactional state machine

Per ActionRequest (keyed by digest), states advance only through append-only, fsync'd events under an exclusive `fcntl` lock on `data/action-gateway/action-gateway.lock`:

`prepared` -> `approved` -> `executing` -> (`succeeded` | `failed` | `unknown`)

Rules:

- The complete read / replay / check / append cycle for every mutating command holds the exclusive lock (no double-spend of an approval token under concurrency).
- Replay validates every event's legal predecessor, recomputes digests from stored requests, enforces nonce uniqueness, and rejects unknown event types.
- A restarted broker defaults decision posture to `confirm-first`, and treats in-flight `executing` without a terminal event as `unknown` (persisted on `replay`).
- This slice never reaches a real `succeeded` via an outward effect: `execute` records `executing` then `unknown` with `reason=execution-not-wired`.

## Enforced choke-point (this slice)

- Workers emit ActionRequests through this broker; they do not hold execute authority.
- `gate-check --digest` fails closed unless the digest is currently `approved` by a distinct attributable approver.
- Production path overrides (`FM_ACTION_AUDIT_LOG`, `FM_ACTION_GATEWAY_ROOT`, `FM_DATA_OVERRIDE`, `FM_ACTION_GATEWAY_NOW`, `FM_ACTION_CAPTAIN_SECRET`) require `FM_ACTION_GATEWAY_TEST=1`. This list owns that set; `forbidden_production_trust_env` in `docs/fm-worker-boundary-source.json` is the machine-readable mirror the worker-boundary pack scans privileged sources for, so extend both together.
- Audit log and inbox files are created mode `0600` under `data/action-gateway/` (mode `0700`).
- Failure to verify an approval refuses rather than proceeds.
- Full OS/network credential isolation for workers remains future work; this slice makes the broker the only supported approval and gate path and keeps execution unwired.

## Broker commands

```
fm-action-gateway.sh prepare [--file <path>]   # default when stdin / --file only
fm-action-gateway.sh show --digest HEX
fm-action-gateway.sh approve --digest HEX --approver-id ID   # captain role + secret
fm-action-gateway.sh execute --digest HEX                    # captain-only stub
fm-action-gateway.sh status --digest HEX
fm-action-gateway.sh gate-check --digest HEX
fm-action-gateway.sh replay
fm-action-gateway.sh classify --action-kind KIND             # registry lookup; no audit I/O
```

Mutating commands print `key=value` lines (at least `decision=` and `state=`) only after the durable append succeeds.

## Gateway contract

- The gateway is the single choke-point: workers prepare; captains approve; execute stays behind the broker.
- Consent tiers are watchdog-style demotion/alerting inputs layered **above** deterministic irreversible ceilings, never a privilege ladder over spend/messaging.
- Trust state lives in the append-only audit log so a restarted gateway is confirm-first until it replays history.
- Execution is not wired in this slice; proving absence of outward effects is part of the test suite.

## Future work

OS/network capability separation for workers, a privileged executor that performs the exact digested action, broader allowlists, anomaly detection, and watchdog demotion signals remain future work.
The first slice of that separation exists as an unprivileged, execution-disabled v2 broker that leaves this one unchanged; see [`docs/action-gateway-v2.md`](action-gateway-v2.md).
Browser isolation itself remains independent of consent tiers; see [`docs/worker-browsing.md`](worker-browsing.md).

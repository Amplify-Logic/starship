# Action gateway v2 unprivileged test slice

`bin/fm-action-gateway-v2.py` owns the gateway v2 parser, resolved-plan schema, SQLite state model, and prepare, approval, and execution channel schemas.
The landed `bin/fm-action-gateway.sh` broker is a separate program that stays stubbed: neither script references the other, so v2 adds no delegation path in either direction.
The landed broker still evolves on its own for reasons unrelated to v2, and `tests/fm-action-gateway.test.sh` owns its behaviour.

## Delivered program slice

This slice implements Step 2 sub-order items 1 through 4 from the approved worker-isolation plan.
Sub-order items 5 through 7 remain separate because they require the trusted approval signer, runner and relays, safe-sink executor, artifact importer, and installation lifecycle.
The approval channel can issue one bound challenge but refuses approval submission until the Step 2.5 signature verifier exists.
The execution channel validates its distinct schema, peer-bound capability, request identity, immutable idempotency key, and approved-state prerequisite, then remains disabled.
No command in this slice performs an outward action.

## Strict input and canonicalization

The gateway accepts UTF-8 JSON up to 64 KiB and canonicalizes the accepted integer-only data model according to RFC 8785 key ordering and encoding.
It rejects duplicate keys, unknown keys, floating-point and non-finite values, integers outside the interoperable range, unpaired surrogates, excessive nesting, excessive collections, and oversized strings.
Money is accepted only as one nonnegative integer `amount_minor` or compatibility `amount_cents` field plus one uppercase ISO 4217 currency.
Decimal numbers, numeric strings, duplicate money aliases, and currency without an amount are refused.
Attachments use canonical base64 and are bounded by count and decoded bytes.

The test adapter accepts the Step 1 ActionRequest shape so one regression pack can exercise both brokers.
The caller's `requester_id`, `nonce`, `expires_at`, provider identity, endpoint policy, and executor identity are never authority.
The broker derives requester authority from the connected peer and its per-job capability in the socket protocol.
Direct command-line prepare exists only when `FM_ACTION_GATEWAY_TEST=1` and derives the synthetic requester from the process UID.

## Closed execution plan

The broker resolves and stores one canonical immutable `fm.execution-plan.v2` object.
The plan contains the exact provider account identity, normalized endpoint and method, integer minor-unit money and currency, expanded recipient list and count, exact message and attachment bytes and hashes, redirect policy, resource limits, policy-manifest hash, executor hash and version, request ID, nonce, and broker-selected short expiry.
Unicode recipient and host forms are retained next to their normalized punycode forms for the later trusted renderer.
The provider account is the local test safe-sink identity, while the executor remains explicitly disabled pending Step 2.6.

## SQLite authority and recovery

`gateway-v2.sqlite3` is the authority for requests, request-ID tombstones, nonce tombstones, idempotency tombstones, challenges, approvals, capabilities, token consumption, rate events, and audit events.
Every mutation uses `BEGIN IMMEDIATE`, uniqueness constraints, foreign keys, full synchronous writes, and WAL journaling.
Request IDs, broker nonces, idempotency keys, request fingerprints, challenges, approvals, signature hashes, capabilities, and consumed tokens have database uniqueness constraints.
Tombstones remain in SQLite when the JSONL evidence file rotates or disappears.
Every command that reads or advances request state, and the service itself, run recovery once at startup, transactionally changing every interrupted `executing` request to `unknown` and recording that provider reconciliation is required.
Recovery never runs per request, so a concurrent caller on another socket cannot rewrite a live execution window.
An unknown request cannot return to approval or execution through any implemented protocol.

## Narrow protocols

The prepare socket uses schema `fm.prepare.v2` and a capability scoped to the peer UID and job ID.
The approval socket uses schema `fm.approval.v2` and a capability scoped to the UI peer UID.
The execution socket uses schema `fm.execution.v2` and a capability scoped to the executor peer UID.
Every accepted connection obtains operating-system peer credentials with `getpeereid` on Darwin or `SO_PEERCRED` on Linux.
Each protocol uses a four-byte network-order length followed by one bounded strict JSON frame.
Every connection carries a bounded read and reply deadline, so a silent or dribbling client cannot hold a channel open indefinitely.
A channel reports readiness only once its listener and its own database connection are open, and the service refuses to keep running once any channel stops serving, so it never advertises a boundary it cannot enforce.
Every failed request, including an unexpected internal failure, returns a refusal frame and leaves the channel serving.
A schema sent to the wrong socket is refused.
Capabilities are random bearer values stored only as SHA-256 hashes in the gateway database.
No approval token, requester role environment variable, caller-selected state path, shell command, executable path, adapter, or redirect is accepted by the production protocol.

## Unprivileged test commands

```sh
FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py prepare < request.json

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py issue-capability \
    --purpose prepare --job-id synthetic-job --uid "$(id -u)"

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py serve \
    --socket-root /temporary/root/run
```

`inspect-test-paths` exposes synthetic canary paths only in test mode so the Step 1 regression harness can probe the v2 database and audit boundary without assuming the removed filesystem approval inbox.
`test-mark-executing` exists only to reproduce an interrupted execution under a temporary root.
Neither command is installed as production administration.

## Evidence boundary

The tests prove parser, plan, transaction, replay, crash recovery, concurrency, protocol separation, peer credential lookup, and per-job capability behavior under an ordinary temporary-root UID.
They do not claim distinct installed macOS principals, root-owned ancestors, Secure Enclave enrollment, signed UI identity, root launch definitions, network isolation, safe-sink exactly-once execution, or privileged uninstall behavior.
Those cases remain explicitly assigned to Step 2 sub-order items 5 through 7 and the captain-at-Mac Step 5 proof.

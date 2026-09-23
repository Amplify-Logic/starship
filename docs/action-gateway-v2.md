# Action gateway v2

`bin/fm-action-gateway-v2.py` owns the gateway v2 parser, resolved-plan schema, SQLite state model, and the prepare, approval, and execution channel schemas.
`bin/fm-action-safe-sink-v2.py` is the executor, `bin/fm-action-runner-v2.py` the execution entry point that runs it, `bin/fm-action-artifact-import-v2.py` the quarantine importer, and `bin/fm-gateway-install-v2.sh` the installation lifecycle.
The landed `bin/fm-action-gateway.sh` broker is a separate program that stays stubbed: neither script references the other, so v2 adds no delegation path in either direction.
The landed broker still evolves on its own for reasons unrelated to v2, and `tests/fm-action-gateway.test.sh` owns its behaviour.

## Delivered program slice

This slice implements Step 2 sub-order items 1 through 6 of the worker-isolation plan, plus the quarantine importer and the installation lifecycle from item 7.
An approval now completes, and an execution now runs, against the deterministic safe sink.
No command in this slice performs an outward action, and the installation lifecycle installs nothing.

What item 7 still leaves open is the privileged installation itself: distinct installed macOS principals, root-owned ancestors, Secure Enclave enrollment, signed UI identity, root launch definitions, and network isolation.
Those need the physical machine and remain assigned to the captain-at-Mac Step 5 proof.

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
The plan contains the exact provider account identity, normalized endpoint and method, integer minor-unit money and currency, expanded recipient list and count, exact message and attachment bytes and hashes, the device payload, redirect policy, resource limits, policy-manifest hash, executor hash and version, request ID, nonce, and broker-selected short expiry.
Unicode recipient and host forms are retained next to their normalized punycode forms for the later trusted renderer.
The executor block names `bin/fm-action-safe-sink-v2.py` and binds its exact bytes, so an executor replaced after approval is refused at claim time rather than run under the old consent.
A resolved plan is also bounded so it can always be delivered: the claim reply carries the exact stored plan bytes as base64, base64 expands by 4/3, and a plan whose canonical form would not fit inside one bounded protocol string is refused at prepare, while it is still a request and nothing has been approved.
That ceiling is published as `max_plan_jcs_bytes` in the policy manifest, which is hashed into every plan, so a caller can size a request against the limit that actually binds rather than discovering it at prepare.
The per-field `max_*` values in the manifest are upper bounds on one field in isolation; `max_plan_jcs_bytes` bounds the whole resolved canonical plan and is the binding constraint, so the usable size of any single field is the plan ceiling minus the rest of the resolved plan and is always smaller than that field's own maximum.
A request past it is refused with `resolved plan exceeds the 24576-byte executable plan ceiling` and nothing is stored; the same ceiling is re-checked at claim before any state moves, so a plan that could not be delivered leaves the request approved and still claimable rather than stranded.
Publishing it advanced `policy_revision` to 4, which changes `policy_manifest_hash` in every plan resolved from here on - a deliberate versioned policy change, not a silent one.

### Device actions

`device.config.stage` is the one registered device kind.
`device.config.read` is deliberately not registered: reading a device's request rows is held pending its own authorization, and registering the kind would read as pre-authorization for it.
Every `device.*` kind carries the non-graduatable `device` ceiling, so no device action can be graduated out of per-action approval.

A device plan carries the target identifier, the settings list, the eligibility status, and the preview hash, and refuses money and messaging parameters in the same request.
The gateway records the exact integer wire value the caller asked for and never alters it.
It selects no corrective band, applies no floor, and performs no rounding, because a value the gateway changed is a value nobody approved.
It also does not decode: `decoded_value` is carried next to the wire value for the approver to read and is recorded as `caller-declared`, so the reviewable transcript shows both the bytes that would go on the wire and the claim about what they mean, without the gateway asserting that claim is correct.

The one decoding judgement the gateway does enforce is a refusal.
A setting whose `encoding_confirmed` is not true cannot be staged at all, and each setting must name the evidence its encoding was confirmed against.
`eligibility.status` is `observed` or `unverified` and is never defaulted, so a plan whose target eligibility was never established says so rather than implying it was checked.
A measured sensor reading is not eligibility and is not a safety proof; nothing here treats it as either.

## SQLite authority and recovery

`gateway-v2.sqlite3` is the authority for requests, request-ID tombstones, nonce tombstones, idempotency tombstones, challenges, approvals, enrolled approvers, execution claims, capabilities, token consumption, rate events, and audit events.
Every mutation uses `BEGIN IMMEDIATE`, uniqueness constraints, foreign keys, full synchronous writes, and WAL journaling.
Request IDs, broker nonces, idempotency keys, request fingerprints, challenges, approvals, signature hashes, execution leases, capabilities, and consumed tokens have database uniqueness constraints.
Tombstones remain in SQLite when the JSONL evidence file rotates or disappears.

Every command that reads or advances request state, and the service itself, run recovery once at startup.
Recovery transactionally changes each interrupted `executing` request **whose lease deadline has passed** to `unknown` and records that provider reconciliation is required.
A live lease is left alone, which is the difference between a crash default and a per-read rewrite: a concurrent caller on another socket cannot take or rewrite an execution window that is still running.
An unknown request cannot return to approval or execution through any implemented protocol, because a request whose outcome nobody observed is exactly the one that must not be retried automatically.

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

## Approval signatures

The approval channel issues one challenge per request and then accepts one signed approval against it.
The signature is over the exact canonical transcript bytes the broker recomputes from stored state, never over a transcript the caller echoes back, and the recomputed digest must still match the digest recorded when the challenge was issued.
A challenge is one-shot, expires within a minute, and is consumed only by an approval that verifies.
A refused signature is recorded as its own durable audit event and leaves the request `prepared`, so a failed attempt is visible and the approver can retry against the same challenge.

An approver is enrolled with an algorithm, a key, and an assurance class, and the class is recorded on the approval row, in the audit event, and in status output:

| Class | Algorithms | What an approval proves |
|---|---|---|
| `asymmetric-enrolled-key` | `ed25519`, `ecdsa-p256-sha256` | The broker holds only a public key, so it cannot mint the approval itself. This is the production class, and `ecdsa-p256-sha256` is the Secure-Enclave-compatible one |
| `software-test-hmac` | `hmac-sha256-test` | Transcript binding, challenge binding, replay refusal, and the state machine. Nothing about approver authenticity, because the broker holds the verification key |

There is no fallback between them in either direction.
The test class is refused at enrollment and at verification outside `FM_ACTION_GATEWAY_TEST=1`, and the asymmetric path refuses by name when its verification primitive is unavailable rather than accepting an unverified approval.
Asymmetric verification needs the `cryptography` module; when it is not importable the approval is refused with that reason stated, which leaves the gateway exactly as capable as it was before this slice rather than quietly less strict.

Enrolling the production approver is a captain step at the Mac: the key is generated in the Secure Enclave by the signing UI and never leaves it, so only its public half is enrolled.
The gateway records `attestation_verified: false` because it does not verify Apple attestation - that belongs to the Step 5 proof.

## Execution, and what settles it

Execution has two operations on the execution socket.

`claim` requires an approved, unexpired request, a matching immutable idempotency key, and a safe sink whose current bytes still match the plan.
It mints a one-shot lease, records the attempt ordinal, and moves the request to `executing`.
A second claim against a live lease is refused; a claim against an expired one commits `unknown` in its own transaction and then refuses, so the durable record always outlives the refusal that reports it.

`settle` is where the executor's report stops mattering.
The broker opens the safe sink's own receipt store read-only and looks for the record that this approved plan deterministically resolves to, and settles from what it finds:

| What the broker observes in the sink | Settled state |
|---|---|
| The exact expected record | `succeeded` |
| No record for this operation | `failed` - nothing was applied |
| A record that does not match this plan | `unknown`, reconciliation required |
| The store cannot be read | `unknown`, reconciliation required |

The executor's claimed outcome is recorded in the audit event as `executor_claimed_outcome` and never decides the state.
An executor that reports success it did not achieve settles `failed` or `unknown`, whichever the store actually supports.
A settle arriving after the lease expired is refused and leaves the recorded `unknown` in place, so a late return can never resurrect a terminal state.

Status reports a `settlement` word alongside the state, because "approved", "queued", "sent" and "applied" are different facts:

| State | Settlement |
|---|---|
| `prepared` | `awaiting-approval` |
| `approved` | `approved-not-yet-queued` |
| `executing` | `queued-and-sent-outcome-not-yet-observed` |
| `succeeded` | `independently-observed-as-applied` |
| `failed` | `independently-observed-as-not-applied` |
| `unknown` | `unobserved-requires-reconciliation` |

`executing` deliberately covers queued and sent together: once a lease is out, the broker knows the attempt is in flight and does not know whether the effect landed.
`unknown` means verify at the provider before retrying; it is not a failure and must never be rendered as one.

## The deterministic safe sink

The safe sink is the only executor the broker will claim for, and its effect is deliberately local and inert: one append-only record in its own store.
It refuses any plan that claims an outward executor, and any plan whose bound executor hash is not its own exact bytes.

One approved plan resolves to exactly one record, built only from the plan's identity fields, so the broker recomputes the same bytes without asking the sink anything.
The idempotency key is the receipt store's primary key, so a repeated click, a retry, or a restart reports `already-applied` and changes nothing.
After committing, the sink re-opens its own store read-only and re-reads the appended line, and reports what it found rather than what it intended.

The sink derives its store root by its own rule rather than accepting one from the caller: a sink whose store the caller could relocate is a sink whose receipts the broker cannot use as evidence.

That store is not under the broker's root. `/var/db/firstmate/gateway` stays broker-owned, `0700`, and broker-only, and the executor has no access to it at all; the receipt store is `/var/db/firstmate/sink`, owned by the executor principal with the dedicated `_firstmate_sinkread` group, `2750`, and every file in it `0640`.
The broker's entire access to the evidence it settles from is group read: it opens that store `?mode=ro` and has no write path to it anywhere, which is what makes a receipt evidence rather than something the broker could have authored.
A worker never holds either identity - anything that calls prepare is not the executor principal and gets no write access to the receipt store.

The group is guaranteed rather than assumed.
The store root is setgid, so the operating system gives every file created in it the read group instead of leaving that to whichever group the executor happens to create files with, and the sink refuses to write a store whose root is not setgid.
Setting that bit is the installation's job, not the executor's: `chmod` is allowed to report success and drop setgid for a caller that is neither privileged nor a member of the directory's group, so the sink reads the bit back after any correction it attempts and refuses with that reason named rather than assuming a clean return worked.
It also checks rather than trusts: before it writes anything it examines every file the store already holds - the database, the JSONL journal, and any SQLite sidecar - and refuses the whole store when one is not a regular file, is not `0640`, or does not carry the store's own group.
A receipt store whose modes drifted is one the broker may already have been unable to read, so it is refused rather than quietly rewritten.
`check` reports the owner, group and mode of those files, not only of the directory, because those are the files the broker actually opens.

The store is deliberately not WAL for the same reason.
A read-only opener of a WAL database has to create the `-shm` wal-index beside the database file, so a reader with no write access to that directory is refused outright and the broker could never read the evidence at all.
`journal_mode=TRUNCATE` with `synchronous=FULL` keeps the same durability and stays readable through group read on the files alone, and a store that reports WAL back is refused rather than used, so a regression to WAL fails loudly instead of silently breaking the broker's read path at install time.

Verification is bounded rather than a rescan: the journal offset of each appended record is stored with its receipt, so reading an effect back is one seek and one line no matter how many records the journal already holds.

## The execution entry point

`bin/fm-action-runner-v2.py` claims, runs the bound executor, and reports back.
It is the execution socket's peer, which is the executor principal the capability is already scoped to - not a relay standing between the capability holder and the executor, and not an ordinary worker.
It holds one per-job execution capability and one short-lived lease, and nothing else - never the approval capability, never an approver key, never the captain secret.

It does not choose the executor either.
Before it runs anything it hashes the program it was asked to run and refuses when those bytes are not the executor hash the approved plan binds, so an operator-supplied `--executor` cannot receive approved plan bytes; the broker refuses the claim for the same reason on its own side.
Nothing ran in that case, and the broker still reads the receipt store before it believes the refusal.

An executor that dies between running the sink and settling loses its lease, and the request becomes `unknown`.
That is the correct result rather than a gap: nobody observed the outcome, so nobody may assume it.

## Quarantine artifact importer

`bin/fm-action-artifact-import-v2.py` is the only sanctioned way an archive from outside the boundary becomes files inside it, and it imports in full or not at all.
Every member is validated before a byte is written, so a hostile archive cannot land its first members and leave the refused one as the only visible problem.
It refuses absolute paths, parent traversal, symlinks and hardlinks, device, fifo and socket members, duplicate names, non-portable names, and archives past its member, size, and depth ceilings, in both tar and zip containers.
The destination must exist, be a directory, and be empty, so no import ever merges into files somebody else placed.

It implements the `--artifact-adapter` argv contract in `docs/worker-boundary-regression.md`.

## Installation lifecycle

`bin/fm-gateway-install-v2.sh` produces what a privileged installation needs and shows exactly what it would do.
It never installs and never uninstalls: `apply` is present and always refuses, because creating the service principals, writing the root-owned ancestors, loading the launch definitions, and enrolling the approver key are the captain's own step at the Mac.

Two rules govern every path it names or emits.
Every privileged path is a literal constant, checked at startup for being absolute, normalized, and deep enough that a truncated or emptied constant cannot resolve to a shared ancestor.
Uninstall never deletes a directory tree: it moves each directory to a timestamped quarantine after checking the target is not a symlink, is contained in its expected parent, is a real directory, and is owned by the account the installation gave it to - the broker for its own roots, root for the program directory, and the executor for the receipt store.
The state root holds the audit record and every tombstone, and an uninstall that destroys the evidence of what the gateway did is worse than one that leaves a directory behind.

The installation also creates one dedicated group, `_firstmate_sinkread`, which is how the broker reads the receipt store and the only authority it has over it.
Its name is deliberately neither role account's: `sysadminctl -roleAccount` creates a group named after the account it creates, so a group sharing a role account's name could never be told apart from one the installation made.
Creating it is idempotent, so re-running the emitted install after a partial one does not abort on a group or a membership that is already there.

Uninstall removes that group only when it can positively read its membership and find nothing in it beyond the two role accounts the same uninstall is removing.
It judges the group before it deletes those accounts, while their names and UUIDs still resolve, and it reads all three ways a member can be attached: the `GroupMembership` names, the `GroupMembers` UUIDs resolved back to accounts, and any account whose primary group is this one.
Membership it cannot read is ambiguous, and ambiguous refuses: "no members were found" is never inferred from "the output could not be parsed".
A group that is in use, or whose membership could not be read, is left exactly as it is, reported as a remaining privileged remnant, and never deleted.
Rollback therefore does not promise to leave nothing behind - it promises to say what it left and why.

The emitted `install.sh` and `uninstall.sh` carry their own copies of those guards, because a person runs them standalone with sudo and cannot rely on the authoring script's checks.
Neither is executable and both refuse to run without an explicit confirmation flag.

## Unprivileged test commands

```sh
FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py prepare < request.json

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py enroll-approver \
    --approver-id test-ui --algorithm hmac-sha256-test --key-material "$SECRET_B64"

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py issue-capability \
    --purpose prepare --job-id synthetic-job --uid "$(id -u)"

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py serve \
    --socket-root /temporary/root/run

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-runner-v2.py run --socket-root /temporary/root/run \
    --capability "$EXECUTION_CAPABILITY" --request-id "$REQUEST_ID" \
    --idempotency-key "$IDEMPOTENCY_KEY"
```

`inspect-test-paths` exposes synthetic canary paths only in test mode so the Step 1 regression harness can probe the v2 database and audit boundary without assuming the removed filesystem approval inbox.
`test-mark-executing` exists only to reproduce an interrupted execution under a temporary root.
Neither command is installed as production administration.

## Evidence boundary

The tests prove parser, plan, transaction, replay, crash recovery, concurrency, protocol separation, peer credential lookup, per-job capability behavior, device-plan resolution, approval signature verification, lease-bounded execution, sink-derived settlement, exactly-once application, bound-executor refusal, and importer refusals, all under an ordinary temporary-root UID.
They also prove the receipt store's generated group and modes on the directory and on every file it creates, that no WAL or shared-memory sidecar is ever produced, that a file whose group or mode does not match is refused fail-closed rather than tolerated, that the broker's read-only connection succeeds against a store whose directory it cannot write and that a write through that connection is refused, and that a store the broker cannot read settles `unknown` with reconciliation required rather than inventing an outcome.

They do not claim distinct installed macOS principals, root-owned ancestors, Secure Enclave enrollment, signed UI identity, root launch definitions, network isolation, or privileged uninstall behavior.
Every test here runs as one UID, so nothing in this suite is evidence about separated principals: the group, permission and journal-mode tests prove those requirements hold on the generated files, and prove nothing about two accounts.
Those cases remain explicitly assigned to the captain-at-Mac Step 5 proof, and `bin/fm-worker-boundary-regression.sh` is what measures them once an installation exists.

Exactly-once is proved against the safe sink's own store, which is a local SQLite primary key.
That is a real exactly-once property for this executor and is not evidence about any outward provider's idempotency.

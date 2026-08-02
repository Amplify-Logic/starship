# Worker boundary regression pack

`bin/fm-worker-boundary-regression.sh` is the synthetic, unprivileged adversarial pack for Step 1 of the worker-isolation program.
The script header owns the exact command-line and adapter contracts.

## Safety boundary

Every canary, fake credential interface, fake service, hostile artifact, and gateway request is generated under one mode-`0700` temporary root.
The pack opens only temporary local IPv4, IPv6, UDP, HTTP, and Unix-socket listeners.
It never reads a real keychain, SSH agent, Git helper, browser profile, clipboard, TCC database, Docker socket, gateway state directory, or credential.
It performs no privileged operation and makes no system configuration change.
The bounded resource probes allocate at most 80 MiB, start at most 33 short-lived children, emit at most 128 KiB, and are killed by a process-group timeout when the launcher does not enforce a tighter limit.
Every step of that timeout cleanup is itself bounded, so a payload that escapes its process group and keeps its output pipes open aborts the run with exit 2 and a named scenario instead of blocking the pack forever.

## Expected outcomes

Every report record contains explicit `native-account` and `nested-container` expected values.
Both isolated modes must deny direct IPv4, IPv6, DNS, DoH, loopback, inherited descriptor, arbitrary Unix-socket, credential, personal-data, Docker, and gateway-state access.
Both modes must reject malformed, replayed, oversized, and flooded ActionRequests at the gateway protocol boundary.
Both modes must reject symlink and traversal artifacts, sanitize terminal controls, enforce resource ceilings, preserve or reconcile state across restart, and refuse launcher drift.
Both modes must pass the source and installation invariants declared in `docs/fm-worker-boundary-source.json`.

A probe is only ever green on positive evidence.
A probe whose payload did not run records `NOT_RUN`, a scenario that exits cleanly without reporting every verdict it owns records `NOT_REPORTED`, and a canary that could not be created records `CANARY_UNAVAILABLE`.
All three fail, because an unmeasured capability is not an enforced one.
Only the probes a scenario is allowed to report are taken from the payload result file, so a launcher adapter cannot report gateway, artifact, terminal, recovery, drift, or source verdicts on the harness's behalf.
The verdicts the harness derives from captured output are additionally gated on the scenario having reported, so a launcher adapter that exits cleanly without ever starting the payload scores no probe at all.
A resource ceiling is only recognized from a signal kill, because an ordinary nonzero exit is a refused or broken launch rather than an enforced limit.
The gateway request probes likewise report `NO_BASELINE` when the gateway rejects the valid baseline request, since rejections prove nothing once nothing is accepted.
The gateway database, inbox, and audit boundaries carry the same requirement: they report `NO_BASELINE` without an accepted baseline request and `NO_CANARY` when the state the baseline should have written is missing or empty, because an unreadable path that was never created denies nothing.
The harness verifies those state canaries itself before the payload is asked to reach them, and its verdict is not overridable by the payload result.

The committed source manifest intentionally describes the current workspace gateway and ambient launcher.
It therefore remains red until the fixed-path runner, gateway channels, artifact importer, and trusted installation verifier replace those sources.
The ambient run must also reproduce the same synthetic equivalents of the observed direct-network, SSH-agent, keychain, Chrome, clipboard, Docker-socket, gateway-inbox, and gateway-audit exposures.

## Running the baseline

```sh
bin/fm-worker-boundary-regression.sh \
  --target ambient \
  --report /tmp/fm-worker-boundary-ambient.json
```

A nonzero exit is the expected Step 1 ambient result.
The report uses `evaluated_as: native-account` for the ambient target because the ambient launcher is being measured against the first mandatory isolation boundary.
Temporary paths are redacted from the durable report.
Use `--keep-temp` only for local debugging because it deliberately skips cleanup of synthetic data.

## Pointing the same pack at later pilots

Use `--target native-account --launcher-adapter PATH` for the restricted macOS account.
Use `--target nested-container --launcher-adapter PATH` for the hardened container.
A launcher adapter must implement the exact argv contract in the script header and must return the payload result across its own staging boundary.
The adapter must not grant host-path access merely because the hostile fixture names a path.

Use `--artifact-adapter PATH` when the quarantine importer exists.
The importer passes only when it rejects each hostile archive, imports nothing, and leaves the synthetic outside canary unchanged.
Use `--gateway PATH` for a command-compatible gateway test adapter when gateway v2 replaces the current shell broker.
Use `--source-manifest PATH` for the reviewed installation manifest and `--attestation PATH` for trusted launcher output.

## Source manifest contract

Each privileged path declares its kind, its fixed installation path under one of the approved system prefixes printed by `--help`, and the source that verifies every ancestor with `stat`, UID, and root-ownership checks.
An absolute path outside those prefixes fails, because a correct-looking path the installer does not own is not a trusted installation.
Every privileged source is scanned for worker-selected file input and production trust-state environment overrides.
The scanned override set mirrors the production path overrides owned by `docs/action-gateway.md`.
Each required channel has one unique purpose and schema identifier.
Each channel source must contain its schema and purpose identifiers plus an OS peer-credential primitive such as `getpeereid`, `SO_PEERCRED`, or `LOCAL_PEERCRED`.
The launcher attestation is an exact key-value allowlist, so missing fields or drift fail rather than falling back to ambient execution.

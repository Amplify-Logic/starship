# Worker browsing (isolated eyes)

Firstmate gives each worker an isolated browser session so browsing never shares cookies, logins, or history with the captain or with other tasks.
`chrome-devtools-axi` owns browsing mechanics.
`bin/fm-browse-session.sh` owns naming, isolation, and cleanup only.

## Never touch the captain's Chrome

HARD SAFETY RULE: the helper must never attach to, auto-connect to, or reuse the captain's own Chrome instance or default profile.
Every axi invocation strips ambient `CHROME_DEVTOOLS_AXI_AUTO_CONNECT` and `CHROME_DEVTOOLS_AXI_BROWSER_URL` so an existing browser cannot be reached.
Isolation stays simple: separate profile directories under `state/browse/<task-id>/profile`.
Do not invent shared-identity or cache-coherency schemes; the design traps reject both.

## Helper contract

```bash
fm-browse-session.sh start <task-id>
fm-browse-session.sh stop <task-id> [--purge]
fm-browse-session.sh list
```

- `start` launches or connects a named `chrome-devtools-axi` session keyed to the task id (`CHROME_DEVTOOLS_AXI_SESSION=<task-id>`), backed by the per-task profile directory above.
- `stop` closes the session and leaves the profile unless `--purge` removes `state/browse/<task-id>/`.
- `list` prints live named sessions recorded for this home (`task_id=… session=… profile=…`).
- Task ids must satisfy the same path-safe alphabet as other firstmate task ids and the axi session-name rules (1-64 chars from `[A-Za-z0-9._-]`, not dots-only).

## Profile lifecycle

Profiles live under the effective firstmate home: `state/browse/<task-id>/profile`.
A live marker at `state/browse/<task-id>/session.live` records an active session for `list`.
`bin/fm-teardown.sh` best-effort stops the session and purges `state/browse/<task-id>/` for the task being torn down; a session-close failure never blocks teardown.

## Action-gateway seam

Workers and browsing code that need an outward action should emit an ActionRequest through `bin/fm-action-gateway.sh` rather than acting directly.
This slice's gateway is a stub: it validates, appends a durable audit record, and always returns `confirm-first`.
It never executes an action.
The schema and choke-point contract live in [`docs/action-gateway.md`](action-gateway.md).

# Ops command center

The ops command center is a Standing Order plus three organs built from primitives already in this repo.
It adds no services, daemons, or databases.
The adopted design and grafts are the rationale; this page is only the object model and the commands that implement slice 1.

## Object model

- **Standing Order** - one captain-approved markdown file at `data/orders/<slug>.md`.
  It declares what to watch, what a worker may stage, what stays the captain's last click, how urgently it reaches him, and the cleared route.
  `Status:` is required and is the captain's arming declaration: `DRAFT` is not cleared to watch or stage, `ARMED` is cleared to watch and stage only.
  Slice 1 records that declaration rather than enforcing it: `run` executes a registered check whatever the Status says, and what the watcher sweeps is decided by the `bin/fm-check-register.sh` byte binding, not by the Status token.
  `GRADUATED: <action-kind> (captain <date>)` lines record per-kind autonomy after the captain graduates that kind.
- **Watch** - a registered `state/order-<slug>.check.sh` that the existing watcher already sweeps.
  A Watch reads a result someone else computed and prints one line when firstmate should wake, otherwise nothing.
  A Watch pipes its output through `fm-order.sh log-fire <slug>` so a printed wake line appends a `ts=<epoch> fired` line to `state/order-<slug>.check.log` - the only source `list` reads for the last fire; with no recorded fire the column shows `-`.
  Only a printed wake line is a fire: a quiet check records nothing, `run` records a fire on the same terms and never on a timeout, and fire history is appended, never truncated.
- **Tray** - the action gateway's durable records rendered by `bin/fm-tray.sh`.
  It is not a second store.
  Pending staged actions are `prepared` ActionRequests.
  An order's staged actions are the ones whose ActionRequest `domain` equals that order's slug; that is the only key tray depth and per-order filtering use.
  AGE is the headline: oldest first, expired marked.
  The tray never approves, executes, or mutates gateway state.
  Approval stays on `bin/fm-action-gateway.sh` captain-role commands.
- **Errand** - a named connector job the primary runs itself because hosted connectors are invisible to workers.
  Prompt and output contract live at `data/errands/<slug>.md`; results land as dated snapshots under `data/ops/`.
  Slice 1 does not add an errand runner.

## Commands

Exact flags, Status rewrite rules, and refusal text are owned by each script's header and `--help`.

- `bin/fm-order.sh` - list, show, run, log-fire, arm, disarm, graduate.
  Arm, disarm, and graduate require `--by-captain`.
  Graduate calls `fm-action-gateway.sh classify` and refuses any kind that classifier treats as non-graduatable.
- `bin/fm-tray.sh` - pending table, `counts` line (`TRAY <n> · OLDEST <age>`), and `show <digest>`.

New outward kinds for this slice live in the gateway's deny-by-default registry: `device.config.push` and `device.firmware.push` (irreversible), `kb.fact.publish`, `course.publish`, and `sheet.write` (external).
See [`action-gateway.md`](action-gateway.md).

## Rationale

The adopted skeleton, trust ladder, and grafts are private design reports, not a second copy of this page.
Do not duplicate them here.

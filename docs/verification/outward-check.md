# Worker outward check verification

Repeatable evidence for the worker outward-action check.
Current behavior and the operator-facing contract are owned by [`../configuration.md`](../configuration.md) ("Worker outward actions"), and the matching rules by [`../../bin/fm-outward-check.py`](../../bin/fm-outward-check.py)'s header; this page records evidence only.

Date: 2026-10-20; portable suite rerun 2026-10-24 (Python 3.14.8, macOS 14.6, Darwin arm64).
Python: 3.12.5 (macOS 26.5.1, Darwin arm64).
Claude Code: 2.1.305.

## Portable suite

`tests/fm-outward-check.test.sh` drives the real hook with payloads shaped like Claude Code's, the real grant and style scripts, the real brief scaffold and a real `bin/fm-spawn.sh` Claude spawn with only the terminal and harness binaries stubbed.

```console
$ bash tests/fm-outward-check.test.sh
ok - reading, searching, listing, drafting and looking pass, and other tools are untouched
ok - a leading word that repeats the connector's name is skipped for reads, never for outward words
ok - sending, answering and changing events, sharing, trashing, Zapier, new connectors and browser control are refused with a plain way forward
ok - a send email to permission holds only when every recipient is visible and listed
ok - a job's permission comes from the last outward= line and holds only for what it names
ok - an invites-from permission holds only for an organizer the job has seen in a calendar answer, and only for its answer
ok - No Block switches the check off at once, and a line that is not understood allows nothing and is named
ok - each outward style is switched by one command that says what it means, the check honours it at once, and narrow permissions survive
ok - style lines that conflict or are not understood leave fine print and are named, and the new switch words work per job
ok - a failure inside the check, or a check that cannot run, refuses the action
ok - permission text is normalized, and a grant widens one running task's permission under its record lock
ok - ship and scout briefs carry the job's outward permission line, none by default
ok - every claude worker gets the outward hooks, and a job's permission must agree with its brief before it is recorded
```

## Live guard

`tests/fm-outward-check-live-e2e.test.sh` is opt-in because it submits prompts and reads the logged-in account's calendar.
It runs a real `claude -p` worker with permissions bypassed and the hooks `bin/fm-spawn.sh` writes, against the Google Calendar connector, using an event id that does not exist so nothing can change.
Without the hooks, the same worker's `delete_event` call reaches Google, which answers `The requested event could not be found or has been deleted.`; with them, the call is refused before it leaves the machine.

```console
$ FM_OUTWARD_CHECK_LIVE_E2E=1 bash tests/fm-outward-check-live-e2e.test.sh
ok - a real Claude worker with permissions bypassed has a connector delete refused by the hook before it reaches the connector
ok - the PostToolUse hook reads event organizers from the real connector answer (3 recorded)
claude 2.1.305 (Claude Code)
ok - with No Block on, the same delete reaches the connector, and the action is recorded
```

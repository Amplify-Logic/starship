Mode: Cursor background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own Cursor Agent background shell task.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`, which Cursor maps onto its native `preToolUse` event.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
7. Treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. When the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then start exactly one fresh background task.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Cursor background shell mechanism.
10. Do not send idle progress while the watcher is parked.

Cursor Agent's background shell completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present, so the background task stays live until that cycle ends.
Tracked `.claude/settings.json` also wires SessionStart, PreToolUse, and Stop for this primary.
Cursor CLI `2026.08.11-e8db854` fires all three after completed interactive TUI turns, including the blockable Stop turn-end guard; the background shell completion remains the supervision wake mechanism.
See `docs/cursor-harness.md` for the certification evidence and the superseded `2026.07.20-8cc9c0b` Stop failure.

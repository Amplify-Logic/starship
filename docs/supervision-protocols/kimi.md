Mode: Kimi background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` with Kimi's built-in `Bash` tool as its own call, with `run_in_background=true`, `description="Supervise Firstmate fleet"`, and `disable_timeout=true`.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the managed Kimi plugin's PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`).
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
7. Treat `watcher: FAILED - no live watcher with a fresh beacon` as an alarm and repair it before ending the turn.
8. Kimi delivers a completed background Bash task back to the same main session as a synthetic User notification.
   On that notification, drain queued wakes, handle `signal`, `stale`, `check`, or `heartbeat`, then arm one fresh background task if work remains.
9. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Kimi background Bash mechanism.
10. Do not send idle progress while the watcher is parked.

Interactive Kimi TUI primary sessions are the supported supervision host.
This protocol uses Kimi's background Bash task, not Kimi's Agent or AgentSwarm worker-dispatch surfaces.
The managed Stop hook is a passive no-blind-stop backstop, not the normal wake path.

---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  It sets the same durable away/quiet-mode flag as /afk, in `quiet` mode, so the sub-supervisor daemon self-handles routine wakes and escalates captain-relevant events exactly as away mode does, but ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356): the same token-saving
daemon tradeoff as `/afk`, made explicit for a captain who is staying,
watching the session, and does not want to exit the mode just by chatting.

This skill is a thin wrapper.
Every mechanism below - the daemon, its injection, its busy/composer guards,
its classification policy, its reliability properties - is owned once by the
`afk` skill and is IDENTICAL in quiet mode; nothing here restates it.
The only things quiet mode changes are which mode the flag declares and what
exits it.

## What it does

1. **Enter without an away-posture record.**
   The captain is present, so there is no mandate to read back: skip the `afk` skill's entry steps 1-3 (translate, propose, confirm) and write no `state/.afk-contract`.
   Run the `afk` skill's entry steps 4-5 with `FM_AFK_MODE=quiet` exported in the shell that invokes `bin/fm-afk-launch.sh start` or `start-native`; a quiet entry needs no confirmed record, and `state/.afk`'s first line reads `quiet`.
   A bare refresh with `FM_AFK_MODE` unset keeps an on-disk quiet flag quiet (`fm_afk_flag_write` preserves it), so a plain refresh never resets quiet back to away.
   **On Pi and pi-signed** quiet mode does not exist, because the daemon that absorbs routine wakes is no longer launched there and the launcher refuses the entry; tell the captain so and leave ordinary supervision unchanged.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work - ordinary chat will not exit this, say
   `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal - that is the entire
point of this mode (AGENTS.md section 8's away-mode stub, quiet branch).

- Only an explicit `/quiet off` (or the captain plainly asking to leave quiet mode or resume normal supervision) exits it: run `bin/fm-afk-return.sh` unchanged, the same return the `afk` skill's "How to exit: the return" section documents.
  That script only tests the flag's presence, so it needs no quiet-specific variant.
- A marked daemon escalation, or a message beginning `/quiet` while already
  in quiet mode (refresh, not exit) -> stay in quiet mode and process it, the
  same two carve-outs `/afk` documents for away mode.
- Every other message while in quiet mode is simply answered as ordinary
  work; the flag and daemon are left untouched.

## Orthogonal to approval authority

Identical to `/afk`: quiet mode changes how aggressively firstmate surfaces
things, never who approves what.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and
a needs-decision finding keeps the `ask-user-authority` policy.

## Must not hide a decision or a failure

Per the issue's own author triage: quiet mode is presentation only.
Progress, retries, and internal mechanics stay below deck exactly as in away
mode, but review-ready work, findings, decisions, failures, and credentials
escalate every time, through the same classification policy `/afk` owns.
Quiet mode is opt-in and never the unconsented default; only an explicit
`/quiet` invocation enters it.

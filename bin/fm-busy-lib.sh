#!/usr/bin/env bash
# Shared harness busy-footer signatures.
# Every pane reader uses this default so newly verified harness signatures cannot
# drift between tmux, Herdr, crew-state reconciliation, and supervision triage.
# FM_BUSY_REGEX remains the caller override.

# shellcheck disable=SC2034  # consumed by scripts that source this library
# The (Waiting|Thinking|Executing) · Ns alternation is prime-agent's busy row
# (verified 2026-08-07, v0.7.0): a braille spinner, the state word, and a
# middle-dot seconds suffix in the MESSAGES area, never the footer. The state
# word alone is NOT safe (model prose can contain "Thinking") - the ` · Ns`
# suffix is the stable token. Bare "Operation aborted · Ns" (post-interrupt) is
# deliberately not matched: the turn is over.
FM_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|ctrl\+c to stop|thinking\.\.\.|Running a command|(Waiting|Thinking|Executing) · [0-9]+s'

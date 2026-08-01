#!/usr/bin/env bash
# Shared harness busy-footer signatures.
# Every pane reader uses this default so newly verified harness signatures cannot
# drift between tmux, Herdr, crew-state reconciliation, and supervision triage.
# FM_BUSY_REGEX remains the caller override.

# shellcheck disable=SC2034  # consumed by scripts that source this library
FM_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|ctrl\+c to stop|thinking\.\.\.|Running a command'

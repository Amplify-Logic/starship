#!/usr/bin/env bash
# Plain-language check for a first mate's final reply to the captain.
# This file is sourced by the per-harness reply hooks and has no side effects on
# source; it is the single owner of the term list, the skip rules, and the
# notice text, while each hook owns how its harness reads the reply and hands
# the notice to the first mate's next turn:
#   - Claude Code: bin/fm-claude-reply-speak.sh (Stop hook systemMessage);
#   - Antigravity (agy): bin/fm-agy-plain-language.sh (Stop hook records it,
#     the next PreInvocation hook injects it).
#
# AGENTS.md section 9 owns the rule and its full vocabulary. FM_PLAIN_TERMS is
# only the distinctive part of it, because ordinary words on that list such as
# "check", "done", "state", or "blocked" would warn on plain English. Fenced
# code, inline code, and links are skipped, since a command, path, or URL the
# captain needs is not a slip. The check is a warning only: no caller blocks,
# holds, or rewrites the reply.

# The distinctive part of AGENTS.md section 9's internal vocabulary, as
# case-insensitive extended regular expressions matched as whole words.
FM_PLAIN_TERMS='worktrees?|primary checkout|local-main|teardown|crewmates?|watchers?|heartbeats?|wake queue|wake events?|harness(es)?|session lock|status files?|meta(data)? files?|task ids?|ask-user|needs-decision|fix-review|checks-passed|direct-PR|local-only|no-mistakes|yolo|captain hold|decision hold|fail(s|ed)?[- ]closed|fail(s|ed)?[- ]open|fail(s)? loudly|refuses loudly'

# Prints the internal terms <reply> uses, lowercased, each once, in reply order
# and joined with ", "; prints nothing when it uses none.
# shellcheck disable=SC2016 # the backticks are literal Markdown code spans
fm_plain_language_hits() {  # <reply>
  printf '%s\n' "${1-}" | awk '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      !fence' \
    | sed -E 's/`[^`]*`//g; s/\]\([^)]*\)/]/g; s#https?://[^[:space:]]+##g' \
    | grep -oiwE "$FM_PLAIN_TERMS" \
    | tr '[:upper:]' '[:lower:]' | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g'
}

# Prints the notice for the first mate naming <hits>, as fm_plain_language_hits
# printed them.
fm_plain_language_notice() {  # <hits>
  printf 'Plain-language check: your last reply to the captain used internal terms AGENTS.md section 9 says to translate: %s. Say the outcome in plain words next time. Nothing was blocked; no reply to this notice is needed.\n' "$1"
}

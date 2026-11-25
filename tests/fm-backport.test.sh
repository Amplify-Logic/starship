#!/usr/bin/env bash
# Tests for bin/fm-backport.sh through its commands: Backport is off until a
# home switches it on, a card in the fixed shape passes and is stamped, each
# shape and anonymity rule refuses on its own, the stamp is bound to the
# card's exact text, and a card is printed for sending or building only with a
# stamp, a fresh reader pass and the owner's yes on that same text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKPORT="$ROOT/bin/fm-backport.sh"
TMP_ROOT=$(fm_test_tmproot fm-backport-tests)

new_home() {  # <name>; echoes a home with Backport on and the new-name check on
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data/backport/cards"
  : > "$home/config/backport"
  : > "$home/config/leak-names-approved"
  printf '%s\n' "$home"
}

good_card() {  # prints a card in the fixed shape that breaks no rule
  cat <<'EOF'
# Retry a failed background check once before raising an alert

Kind: practice
Fits: any Starship that runs custom checks
Needs: the watcher and its custom checks
Lands in: the watcher documentation

## The problem

A custom check that reads the network fails now and then for a moment, and the owner is woken for nothing.

## The general rule

A check that fails for a reason that clears by itself is tried once more before anyone is told.

## How it works

1. In the check script, wrap the network read in one retry after a short pause.
2. Only the second failure prints the line that wakes the first mate.

Wording to add: "A custom check retries a failed network read once before it reports."

## Evidence it worked

Before: a few false alerts each week. After: none seen. Not measured beyond that.

## Left out on purpose

Which checks and which services; the pause length is each home's own choice.

## Done when

A check whose first read fails and whose second succeeds prints nothing.
EOF
}

bp() {  # <home> <args...>; runs the script, setting OUT and RC
  local home=$1
  shift
  RC=0
  OUT=$(cd "$ROOT" && FM_HOME="$home" "$BACKPORT" "$@" 2>&1) || RC=$?
}

# says <text>: the last run's output names the text.
says() {
  printf '%s\n' "$OUT" | grep -qF -- "$1"
}

# refused_for <home> <slug> <expected text>: check refuses and names it.
refused_for() {
  bp "$1" check "$2"
  [ "$RC" -eq 1 ] || fail "card $2 was not refused (exit $RC): $OUT"
  printf '%s\n' "$OUT" | grep -qF -- "$3" || fail "card $2 was refused without naming '$3': $OUT"
}

test_off_by_default() {
  local home="$TMP_ROOT/off" cmd
  mkdir -p "$home/config" "$home/data"
  for cmd in "check any" "reader any pass" "answer any yes" "ready any" "sent any" "built any" "list"; do
    # shellcheck disable=SC2086 # The command words are split on purpose.
    bp "$home" $cmd
    [ "$RC" -eq 1 ] || fail "off: '$cmd' ran without config/backport (exit $RC)"
    printf '%s\n' "$OUT" | grep -q 'Backport is off in this home' || fail "off: '$cmd' did not say Backport is off: $OUT"
  done
  [ ! -e "$home/data/backport" ] || fail "off: a refused command still created data/backport"
  pass "Backport refuses every command and writes nothing until config/backport switches it on"
}

test_good_card_passes_and_is_stamped() {
  local home card hash
  home=$(new_home good)
  card="$home/data/backport/cards/retry.md"
  good_card > "$card"
  bp "$home" check retry
  [ "$RC" -eq 0 ] || fail "good: a card in the fixed shape was refused: $OUT"
  hash=$(printf '%s\n' "$OUT" | awk '/^stamped retry / { print $3 }')
  [ -n "$hash" ] || fail "good: check printed no stamp: $OUT"
  awk -F '\t' -v h="$hash" '$2 == "retry" && $3 == "checked" && $4 == h { found = 1 } END { exit !found }' \
    "$home/data/backport/ledger.tsv" || fail "good: the ledger holds no stamp for the card's text"
  bp "$home" list
  [ "$OUT" = "$(printf 'retry\tchecked\tRetry a failed background check once before raising an alert')" ] \
    || fail "good: list did not show the stamped card: $OUT"
  pass "a card in the fixed shape passes the check and gets a stamp tied to its text"
}

test_each_rule_refuses() {
  local home dir name
  home=$(new_home rules)
  dir="$home/data/backport/cards"

  good_card | sed '1s/.*/Retry a check/' > "$dir/no-title.md"
  refused_for "$home" no-title 'line 1: the card must open with'
  good_card | sed 's/^Kind: practice/Kind: chore/' > "$dir/kind.md"
  refused_for "$home" kind 'Kind must be fix, rule, practice or capability'
  good_card | sed '/^Needs:/d' > "$dir/no-needs.md"
  refused_for "$home" no-needs 'expected "Needs: ..." here'
  good_card | sed 's/^## Evidence it worked/## What we saw/' > "$dir/heading.md"
  refused_for "$home" heading 'found "## What we saw" where the card needs "## Evidence it worked"'
  good_card | sed 's/^## Done when/### Done when/' > "$dir/subheading.md"
  refused_for "$home" subheading 'only the six fixed "## " sections may be headings'
  good_card | sed '/^## Done when/,$d' > "$dir/short.md"
  refused_for "$home" short 'missing the section "## Done when"'
  good_card | awk '/^## The general rule/ { print; skip = 1; next } /^## How it works/ { skip = 0 } !skip' > "$dir/empty.md"
  refused_for "$home" empty 'section "## The general rule" is empty'

  { good_card; printf 'word %.0s' $(seq 1 500); printf '\n'; } > "$dir/long.md"
  refused_for "$home" long 'at most 500'

  good_card | sed 's/^Before: a few/Before, in 2025, a few/' > "$dir/year.md"
  refused_for "$home" year 'a year; leave dates out'
  good_card | sed 's/^Before: a few/Before 3\/11\/25 a few/' > "$dir/numeric-date.md"
  refused_for "$home" numeric-date 'a date; leave dates out'
  good_card | sed 's/^Before: a few/Before November a few/' > "$dir/month.md"
  refused_for "$home" month 'a month name; leave dates out'
  good_card | sed 's/^Before: a few/Before 23:30 a few/' > "$dir/clock.md"
  refused_for "$home" clock 'a clock time; leave times out'
  good_card | sed 's/^Before: a few/Until last week a few/' > "$dir/relative.md"
  refused_for "$home" relative 'a relative date'

  good_card | sed 's#^Before: a few#See https://example.com/notes, a few#' > "$dir/link.md"
  refused_for "$home" link 'a link outside this repository'
  good_card | sed 's#^Before: a few#See www.example.com, a few#' > "$dir/web.md"
  refused_for "$home" web 'a web address'
  good_card | sed 's#^Before: a few#Ask owner@example.com, a few#' > "$dir/email.md"
  refused_for "$home" email 'an email address'

  good_card | sed 's/^A custom check that reads/> A custom check that reads/' > "$dir/blockquote.md"
  refused_for "$home" blockquote 'a block quote; never quote anyone'
  good_card | sed 's/^A custom check that reads the network/A teammate said "it keeps waking me" when the network/' > "$dir/speech.md"
  refused_for "$home" speech 'quoted words; never quote anyone'

  # A name never seen in this repository in any case, built reversed so this
  # file holds it in no case either.
  name=$(printf 'naixalbroz' | rev | sed 's/^z/Z/')
  good_card | sed "s/^Which checks and which services/Which checks $name runs/" > "$dir/new-name.md"
  refused_for "$home" new-name "leak guard: LEAK_HIT: new-name: cards/new-name.md"
  printf 'quuxcorp\n' > "$home/config/leak-words"
  good_card | sed 's/^Which checks and which services/Which checks quuxcorp runs/' > "$dir/private.md"
  refused_for "$home" private "leak guard: LEAK_HIT: private-word: cards/private.md"
  bp "$home" check private
  printf '%s\n' "$OUT" | grep -qi quuxcorp && fail "rules: the refusal printed the private word: $OUT"

  [ ! -s "$home/data/backport/ledger.tsv" ] || fail "rules: a refused card was stamped"
  pass "the check refuses each break of the shape and each anonymity rule, and stamps none of them"
}

test_quoted_wording_allowed_only_in_how_it_works() {
  local home
  home=$(new_home wording)
  good_card > "$home/data/backport/cards/rule.md"
  bp "$home" check rule
  [ "$RC" -eq 0 ] || fail "wording: the exact wording under How it works was refused: $OUT"
  pass "a rule card may carry its exact wording in quotes under How it works"
}

test_needs_a_word_list_or_approvals() {
  local home
  home=$(new_home no-list)
  rm -f "$home/config/leak-names-approved"
  good_card > "$home/data/backport/cards/retry.md"
  refused_for "$home" retry 'create config/leak-names-approved'
  pass "the check refuses in a home where the leak guard could not check new names"
}

test_stamp_bound_to_text_and_ready_gate() {
  local home card
  home=$(new_home gate)
  card="$home/data/backport/cards/retry.md"
  good_card > "$card"

  bp "$home" reader retry pass
  [ "$RC" -eq 1 ] || fail "gate: a reader verdict was recorded on an unstamped card"
  bp "$home" check retry
  [ "$RC" -eq 0 ] || fail "gate: check failed: $OUT"
  bp "$home" answer retry yes
  { [ "$RC" -eq 1 ] && says 'no fresh reader pass'; } \
    || fail "gate: a yes was recorded before the fresh reader passed the card: $OUT"
  bp "$home" ready retry
  [ "$RC" -eq 1 ] || fail "gate: ready printed a card without a reader pass or a yes"
  bp "$home" reader retry pass
  bp "$home" ready retry
  { [ "$RC" -eq 1 ] && says 'no answer from the owner'; } \
    || fail "gate: ready printed a card without the owner's yes: $OUT"
  bp "$home" list
  printf '%s\n' "$OUT" | grep -q $'^retry\twaiting for yes\t' || fail "gate: list did not show the card waiting for yes: $OUT"
  bp "$home" answer retry yes
  bp "$home" ready retry
  [ "$RC" -eq 0 ] || fail "gate: a stamped, read and approved card was refused: $OUT"
  [ "$OUT" = "$(cat "$card")" ] || fail "gate: ready did not print the card exactly"

  printf '\nOne more line.\n' >> "$card"
  bp "$home" ready retry
  { [ "$RC" -eq 1 ] && says 'no stamp for its current text'; } \
    || fail "gate: an edited card kept its stamp: $OUT"
  bp "$home" list
  printf '%s\n' "$OUT" | grep -q $'^retry\tchanged\t' || fail "gate: list did not show the edited card as changed: $OUT"
  bp "$home" check retry
  bp "$home" reader retry pass
  bp "$home" ready retry
  { [ "$RC" -eq 1 ] && says 'changed after the owner'; } \
    || fail "gate: the old yes carried over to the edited text: $OUT"
  bp "$home" sent retry
  [ "$RC" -eq 1 ] || fail "gate: an edited card was recorded as sent without a new yes"
  pass "the stamp, the reader's verdict and the yes bind to the exact text, and ready needs all three"
}

test_answers_and_list_states() {
  local home dir t0
  home=$(new_home states)
  dir="$home/data/backport/cards"
  t0=1000000000
  good_card > "$dir/later.md"
  good_card | sed '1s/.*/# Never this one/' > "$dir/never.md"
  good_card | sed '1s/.*/# Built this one/' > "$dir/built.md"
  good_card | sed '1s/.*/# Not checked yet/' > "$dir/fresh.md"
  for slug in later never built; do
    FM_BACKPORT_NOW=$t0 bp "$home" check "$slug"
    FM_BACKPORT_NOW=$t0 bp "$home" reader "$slug" pass
  done
  FM_BACKPORT_NOW=$t0 bp "$home" answer later not-now
  FM_BACKPORT_NOW=$t0 bp "$home" answer never never
  FM_BACKPORT_NOW=$t0 bp "$home" answer built yes
  FM_BACKPORT_NOW=$t0 bp "$home" built built "public change opened"
  [ "$RC" -eq 0 ] || fail "states: built was not recorded: $OUT"
  bp "$home" ready never
  { [ "$RC" -eq 1 ] && says 'answered never'; } || fail "states: a card answered never was printed: $OUT"

  FM_BACKPORT_NOW=$((t0 + 86400)) bp "$home" list
  printf '%s\n' "$OUT" | grep -q $'^later\tnot now\t' || fail "states: not now did not show: $OUT"
  printf '%s\n' "$OUT" | grep -q $'^never\tnever\t' || fail "states: never did not show: $OUT"
  printf '%s\n' "$OUT" | grep -q $'^built\tbuilt\t' || fail "states: built did not show: $OUT"
  printf '%s\n' "$OUT" | grep -q $'^fresh\tnew\t' || fail "states: an unchecked card did not show as new: $OUT"
  FM_BACKPORT_NOW=$((t0 + 31 * 86400)) bp "$home" list
  printf '%s\n' "$OUT" | grep -q $'^later\tnot now, due again\t' || fail "states: not now did not come back after 30 days: $OUT"
  pass "answers are recorded and list shows where every card stands, with not now coming back after 30 days"
}

test_misuse() {
  local home
  home=$(new_home misuse)
  bp "$home" check '../escape'
  [ "$RC" -eq 2 ] || fail "misuse: a slug with a path was accepted (exit $RC)"
  bp "$home" answer any maybe
  [ "$RC" -eq 2 ] || fail "misuse: an unknown answer was accepted (exit $RC)"
  bp "$home" check missing
  [ "$RC" -eq 1 ] || fail "misuse: a missing card was not refused (exit $RC)"
  pass "a bad slug or answer is misuse, and a missing card is refused"
}

fm_test_run \
  test_off_by_default \
  test_good_card_passes_and_is_stamped \
  test_each_rule_refuses \
  test_quoted_wording_allowed_only_in_how_it_works \
  test_needs_a_word_list_or_approvals \
  test_stamp_bound_to_text_and_ready_gate \
  test_answers_and_list_states \
  test_misuse

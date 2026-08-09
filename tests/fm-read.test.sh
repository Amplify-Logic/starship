#!/usr/bin/env bash
# Behavior tests for private Markdown report rendering and loopback opening.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
READ="$ROOT/bin/fm-read.sh"
TMP_ROOT=$(fm_test_tmproot fm-read-tests)
# The renderer reports normalised absolute paths, so compare against a fixture
# root normalised the same way (TMPDIR commonly carries a trailing slash).
TMP_ROOT=${TMP_ROOT//\/\//\/}
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/bin"
LOG="$TMP_ROOT/lavish.log"
mkdir -p "$HOME_DIR/data/sample-task" "$FAKEBIN"
# fm_test_tmproot ran in a command substitution, so its registration happened
# in a subshell; re-register the dir here and re-trap per tests/lib.sh.
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT HUP INT TERM

cat > "$HOME_DIR/data/sample-task/report.md" <<'MD'
# Report heading

## Findings

| Item | Result |
| --- | --- |
| Reader | Works |
MD
cat > "$TMP_ROOT/notes.md" <<'MD'
# Explicit heading
MD
printf 'not markdown\n' > "$TMP_ROOT/notes.txt"

cat > "$TMP_ROOT/edge.md" <<'MD'
Evidence: status_file_write=ok for LAVISH_AXI_LINK_HOST and FM_READ_TEST_LOG.

Danger [click](javascript:alert(1)) beside a | pipe in prose
---

Safe [docs](https://example.com/a) link.

| A | B |
| - | - |
| 1 | 2 | 3 |

- top level
  - nested child
- second top
MD

cat > "$TMP_ROOT/steps.md" <<'MD'
1. first item
 wrapped continuation
2. second item

3. third item
   ```sh
   echo run
   ```
4. fourth item
MD

cat > "$TMP_ROOT/blocks.md" <<'MD'
1. first step
   | Item | Result |
   | - | - |
   | Reader | Works |
2. second step
   > quoted note
3. third step

   extra paragraph one

   extra paragraph two
4. fourth step
MD

cat > "$TMP_ROOT/breaks.md" <<'MD'
Before the break.

* * *

- alpha
- beta

- - -

After the break.

_ _ _

Tail paragraph.
MD

cat > "$TMP_ROOT/anchors.md" <<'MD'
# Contents

Jump to [Findings](#findings) or [the second pass](#findings-1).

See [init](https://example.com/pkg/__init__.py) and [cache](https://example.com/dir/_private_/x).

## Findings

First pass.

## Findings

Second pass.

## Heading: With Punctuation!
MD

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'host=%s link=%s port=%s file=%s\n' \
  "${LAVISH_AXI_HOST:-}" "${LAVISH_AXI_LINK_HOST:-}" "${LAVISH_AXI_PORT:-}" "${1:-}" >> "$FM_READ_TEST_LOG"
printf 'session:\n  url: "http://%s:%s/session/fake"\n' "$LAVISH_AXI_LINK_HOST" "$LAVISH_AXI_PORT"
SH
chmod +x "$FAKEBIN/lavish-axi"

out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open notes.md)
[ -f "$out" ] || fail "explicit Markdown path did not produce HTML"
assert_contains "$(cat "$out")" '<h1 id="explicit-heading">Explicit heading</h1>' "explicit path output lost its heading"
[ ! -e "$LOG" ] || fail "--no-open launched Lavish"
pass "explicit paths render headings and --no-open does not launch"

edge_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open edge.md)
edge=$(cat "$edge_out")
edge_flat=$(tr '\n' ' ' < "$edge_out")
assert_contains "$edge" "status_file_write=ok for LAVISH_AXI_LINK_HOST and FM_READ_TEST_LOG." \
  "snake_case identifiers were mangled by intra-word emphasis"
assert_not_contains "$edge" 'href="javascript' "an unsafe URL scheme reached the rendered page"
assert_contains "$edge" '<a href="https://example.com/a">docs</a>' "a safe http link was dropped by scheme filtering"
assert_contains "$edge" "<hr>" "a rule after pipe-bearing prose was swallowed by a bogus table"
assert_contains "$edge" '<th style="text-align:left">A</th>' "a single-dash table divider was not recognised"
assert_contains "$edge" ">3</td>" "a row wider than its header silently lost trailing cells"
assert_contains "$edge_flat" "<li>top level <ul> <li>nested child" "an indented sub-item was flattened to a sibling"
pass "renderer keeps identifiers, rules, tables, and nesting intact and refuses unsafe URL schemes"

steps_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open steps.md)
steps_flat=$(tr '\n' ' ' < "$steps_out")
lists=$(grep -o '<ol>' "$steps_out" | wc -l | tr -d ' ')
items=$(grep -o '<li>' "$steps_out" | wc -l | tr -d ' ')
[ "$lists" = 1 ] || fail "continuation lines split one ordered list into $lists lists, silently renumbering it"
[ "$items" = 4 ] || fail "expected 4 list items, rendered $items"
assert_contains "$steps_flat" "<li>first item wrapped continuation" "a wrapped line was ejected from its list item"
assert_contains "$steps_flat" '<li>third item <pre><code class="language-sh">echo run</code></pre>' \
  "an indented fenced block was ejected from its list item"
pass "wrapped lines and indented code stay inside their list item without renumbering"

blocks_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open blocks.md)
blocks_flat=$(tr '\n' ' ' < "$blocks_out")
block_lists=$(grep -o '<ol>' "$blocks_out" | wc -l | tr -d ' ')
block_items=$(grep -o '<li>' "$blocks_out" | wc -l | tr -d ' ')
[ "$block_lists" = 1 ] || fail "an indented block split one ordered list into $block_lists lists, silently renumbering it"
[ "$block_items" = 4 ] || fail "expected 4 numbered steps, rendered $block_items"
assert_contains "$blocks_flat" '<li>first step <div class="tw"><table>' "an indented table was hoisted out of the step it documents"
assert_contains "$blocks_flat" "<li>second step <blockquote>" "an indented quote was flattened into literal text"
assert_contains "$blocks_flat" "<li>third step <p>extra paragraph one</p> <p>extra paragraph two</p>" \
  "continuation paragraphs collapsed into one run of text"
pass "indented tables, quotes, and paragraphs render inside the step they belong to"

breaks_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open breaks.md)
breaks_flat=$(tr '\n' ' ' < "$breaks_out")
rules=$(grep -o '<hr>' "$breaks_out" | wc -l | tr -d ' ')
[ "$rules" = 3 ] || fail "expected 3 thematic breaks from spaced markers, rendered $rules"
assert_not_contains "$(cat "$breaks_out")" "<em>" "a spaced thematic break was parsed as a stray emphasised bullet"
assert_contains "$breaks_flat" "<hr> <ul> <li>alpha </li> <li>beta </li> </ul> <hr>" \
  "a list next to a thematic break was absorbed into a stray bullet"
pass "spaced thematic breaks render as rules and never swallow an adjacent list"

anchors_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open anchors.md)
anchors=$(cat "$anchors_out")
assert_contains "$anchors" '<h1 id="contents">Contents</h1>' "a heading did not carry its slugged anchor id"
assert_contains "$anchors" '<h2 id="findings">Findings</h2>' "a TOC target heading did not carry its slugged anchor id"
assert_contains "$anchors" '<h2 id="findings-1">Findings</h2>' "a repeated heading was not de-duplicated with a numeric suffix"
assert_contains "$anchors" '<h2 id="heading-with-punctuation">' "punctuation was not collapsed into hyphens in an anchor id"
assert_contains "$anchors" '<a href="#findings">Findings</a>' "an in-document fragment link did not stay live against its anchor"
assert_contains "$anchors" '<a href="#findings-1">the second pass</a>' "a fragment link to a de-duplicated anchor was not kept"
assert_contains "$anchors" 'href="https://example.com/pkg/__init__.py"' "a URL with double underscores was mangled by emphasis"
assert_contains "$anchors" 'href="https://example.com/dir/_private_/x"' "a URL with single underscores was mangled by emphasis"
pass "headings carry de-duplicated GitHub-style anchors and URLs survive emphasis intact"

# shellcheck disable=SC2016  # the backticks are literal Markdown code-span fixture data
printf '# Nul marker\n\n`\000CODE0\000` tail text\n' > "$TMP_ROOT/nul.md"
(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open nul.md > "$TMP_ROOT/nul.path" 2>&1) &
nul_pid=$!
for _ in $(seq 1 50); do
  kill -0 "$nul_pid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$nul_pid" 2>/dev/null; then
  kill "$nul_pid" 2>/dev/null || true
  fail "renderer hung on a NUL-delimited marker sequence"
fi
wait "$nul_pid" || fail "renderer failed on a NUL-delimited marker sequence: $(cat "$TMP_ROOT/nul.path")"
nul_out=$(cat "$(cat "$TMP_ROOT/nul.path")")
assert_contains "$nul_out" "<code>CODE0</code> tail text" "NUL bytes were not stripped before parsing"
pass "a NUL-delimited marker sequence renders promptly instead of hanging"

first=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  FM_READ_TEST_LOG="$LOG" "$READ" --no-open sample-task)
second=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  FM_READ_TEST_LOG="$LOG" "$READ" --no-open sample-task)
[ "$first" = "$second" ] || fail "same report rendered to different output names"
case "$first" in "$HOME_DIR/.lavish/read-sample-task-"*.html) ;; *) fail "task report page was not named for its task id: $first" ;; esac
assert_contains "$(cat "$first")" "<title>Sample Task</title>" "task report page was not titled for its task id"
assert_contains "$(cat "$first")" '<h1 id="report-heading">Report heading</h1>' "bare-id output lost the source heading"
assert_contains "$(cat "$first")" '<div class="tw"><table>' "report table was not placed in its overflow wrapper"
pass "bare task ids resolve, name and title their page, and reuse a deterministic output name"

[ "$(file_mode "$first")" = 600 ] || fail "private report page is not owner-only: $(file_mode "$first")"
[ "$(file_mode "$HOME_DIR/.lavish")" = 700 ] || fail "private page directory is not owner-only: $(file_mode "$HOME_DIR/.lavish")"
pass "rendered pages and their directory stay owner-only"

LOOSE_HOME="$TMP_ROOT/loose-home"
mkdir -p "$LOOSE_HOME/data/other-task" "$LOOSE_HOME/.lavish"
chmod 755 "$LOOSE_HOME/.lavish"
printf '# Other report\n' > "$LOOSE_HOME/data/other-task/report.md"
loose=$(FM_HOME="$LOOSE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  FM_READ_TEST_LOG="$LOG" "$READ" --no-open other-task)
[ "$(file_mode "$LOOSE_HOME/.lavish")" = 700 ] || fail "a pre-existing page directory was left readable: $(file_mode "$LOOSE_HOME/.lavish")"
[ "$(file_mode "$loose")" = 600 ] || fail "page in a pre-existing directory is not owner-only: $(file_mode "$loose")"
pass "a pre-existing page directory is tightened to owner-only"

BLOCKED_HOME="$TMP_ROOT/blocked-home"
mkdir -p "$BLOCKED_HOME/data/blocked-task"
printf '# Blocked report\n' > "$BLOCKED_HOME/data/blocked-task/report.md"
printf 'not a directory\n' > "$BLOCKED_HOME/.lavish"
if FM_HOME="$BLOCKED_HOME" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open blocked-task >"$TMP_ROOT/blocked.out" 2>&1; then
  fail "an unrenderable output directory was accepted"
fi
blocked=$(cat "$TMP_ROOT/blocked.out")
assert_contains "$blocked" "fm-read: could not render" "a renderer failure did not produce a clean refusal"
assert_contains "$blocked" "fm-read.mjs: " "a renderer IO failure did not surface its own one-line message"
assert_not_contains "$blocked" "node:internal" "a renderer IO failure leaked a Node stack trace"
assert_not_contains "$blocked" "    at " "a renderer IO failure leaked stack frames"
pass "renderer failures refuse with the script's own message and no stack trace"

if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open "$TMP_ROOT/notes.txt" >"$TMP_ROOT/non-md.out" 2>&1; then
  fail "non-Markdown input was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/non-md.out")" "refusing non-Markdown file" "non-Markdown refusal was unclear"
pass "non-Markdown files are refused"

if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open missing-task >"$TMP_ROOT/missing.out" 2>&1; then
  fail "missing bare task id was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/missing.out")" "$HOME_DIR/data/missing-task/report.md" "missing-id error did not name the report path it checked"
pass "missing bare ids name the report path that was checked"

[ ! -e "$LOG" ] || fail "--no-open launched Lavish during a later invocation"

open_out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  FM_READ_TEST_LOG="$LOG" FM_READ_PORT=4491 "$READ" sample-task)
assert_contains "$open_out" 'http://127.0.0.1:4491/session/fake' "open did not print the Lavish URL"
opened=$(cat "$LOG")
assert_contains "$opened" "host=127.0.0.1 link=127.0.0.1 port=4491 file=$first" "open did not bind Lavish to IPv4 loopback with the rendered page"
pass "open launches Lavish on IPv4 loopback and prints its URL"

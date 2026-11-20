#!/usr/bin/env bash
# Tests for bin/fm-merge-rules.sh through its subcommands: the merge rule
# table's format and row matching, the file classes a pull request's changed
# files fall into, the package.json same-major check, and the trail lines.
# bin/fm-pr-merge.sh's use of them is tested in tests/fm-pr-merge.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES="$ROOT/bin/fm-merge-rules.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-rules-tests)

command -v jq >/dev/null 2>&1 || fail "these tests need jq"

new_home() {  # <name>; echoes the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' "$home"
}

classify() {  # <pages...>; prints the classify output
  printf '%s\n' "$@" | "$RULES" classify
}

class_of() {  # <pages...>; prints the class alone
  classify "$@" | sed -n 's/^class=//p'
}

test_table_rows_and_matching() {
  local home out
  home=$(new_home rows)
  out=$(FM_HOME="$home" "$RULES" check)
  [ "$out" = "no merge rule table" ] || fail "rows: an absent table read as '$out'"
  printf '%s\n' '# project | lands by itself | who must say yes' '' \
    'fleet | docs, tests,deps | the owner' 'site | nothing | the owner' 'box|anything|nobody' \
    > "$home/config/merge-rules"
  printf '%s\n' '- fleet [no-mistakes +yolo alias=ship] - the tooling (added 2026-01-01)' \
    > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$RULES" check)
  [ "$out" = "merge rule table: 3 rows" ] || fail "rows: unexpected check output '$out'"

  out=$(FM_HOME="$home" "$RULES" rule /somewhere/fleet)
  [ "$out" = $'active=true\nproject=fleet\nlands=docs tests deps\nyes=the owner' ] \
    || fail "rows: the basename did not match its row: '$out'"
  out=$(FM_HOME="$home" "$RULES" rule /somewhere/ship/)
  [ "$(printf '%s\n' "$out" | sed -n 's/^project=//p')" = fleet ] \
    || fail "rows: a registry alias did not reach its row: '$out'"
  out=$(FM_HOME="$home" "$RULES" rule /somewhere/box)
  [ "$(printf '%s\n' "$out" | sed -n 's/^lands=//p')" = anything ] || fail "rows: box did not read anything: '$out'"
  out=$(FM_HOME="$home" "$RULES" rule /somewhere/unknown)
  [ "$(printf '%s\n' "$out" | sed -n 's/^project=//p')" = "" ] \
    || fail "rows: an unknown project matched a row: '$out'"
  printf '%s\n' "$out" | grep -qx 'active=true' || fail "rows: an unknown project did not keep the table active"
  pass "fm-merge-rules reads the table and matches a project by basename or registry alias"
}

test_malformed_tables_refuse() {
  local home row want rc
  home=$(new_home malformed)
  while IFS='|' read -r row want; do
    printf '%b\n' "$row" > "$home/config/merge-rules"
    set +e
    FM_HOME="$home" "$RULES" check > "$home/out" 2> "$home/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "malformed: '$row' must refuse"
    assert_grep "config/merge-rules is malformed: $want" "$home/err" "malformed: '$row' gave the wrong reason"
  done <<'ROWS'
a / docs / x|line 1 has 1 fields
a ; docs|line 1 has 1 fields
ROWS
  for row in 'a | docs' 'a |  | x' 'a | doc | x' 'a | docs nothing | x' 'a | docs | x\na | tests | y'; do
    printf '%b\n' "$row" > "$home/config/merge-rules"
    set +e
    FM_HOME="$home" "$RULES" check > "$home/out" 2> "$home/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "malformed: '$row' must refuse"
    assert_grep 'config/merge-rules is malformed: line' "$home/err" "malformed: '$row' named no line"
  done
  assert_grep 'line 2 names project a a second time' "$home/err" "malformed: a duplicate row was not named"
  pass "fm-merge-rules refuses a malformed table and names the line"
}

test_file_classes() {
  local got
  [ "$(class_of '[{"filename":"docs/a.md"},{"filename":"README.md"},{"filename":"x/y.rst"}]')" = docs ] \
    || fail "classes: docs files did not read as docs"
  [ "$(class_of '[{"filename":"tests/a.test.sh"},{"filename":"src/foo_test.go"},{"filename":"web/a.spec.ts"},{"filename":"tests/README.md"},{"filename":"tests/fixtures/package.json"}]')" = tests ] \
    || fail "classes: test files did not read as tests"
  [ "$(class_of '[{"filename":"package-lock.json"},{"filename":"web/yarn.lock"},{"filename":"web/package.json","status":"modified"}]')" = deps ] \
    || fail "classes: lockfiles and a manifest did not read as deps"
  [ "$(class_of '[{"filename":"docs/a.md"}]' '[{"filename":"tests/a.test.sh"}]')" = mixed ] \
    || fail "classes: docs and tests across pages did not read as mixed"
  for got in '[{"filename":"AGENTS.md"}]' '[{"filename":"web/CLAUDE.md"}]' '[{"filename":".github/a.md"}]' \
    '[{"filename":"docs/.hidden.md"}]' '[{"filename":"go.mod"}]' '[{"filename":"requirements.txt"}]' \
    '[{"filename":"src/app.ts"}]'; do
    [ "$(class_of "$got")" = other ] || fail "classes: $got did not read as outside every class"
  done
  [ "$(class_of '[{"filename":"docs/new.md","previous_filename":"bin/old.sh"}]')" = mixed ] \
    || fail "classes: a file renamed out of code did not keep its old name's class"
  got=$(classify '[{"filename":"docs/a.md"},{"filename":"bin/x.sh"},{"filename":"web/package.json","status":"modified"}]')
  printf '%s\n' "$got" | grep -qx 'outside=bin/x.sh' || fail "classes: the outside file was not listed: $got"
  printf '%s\n' "$got" | grep -qx 'manifests=modified:web/package.json' || fail "classes: the manifest was not listed: $got"
  set +e
  printf '%s\n' '{"not":"a page"}' | "$RULES" classify > /dev/null 2>&1
  expect_code 1 "$?" "classes: an unreadable page must refuse"
  set -e
  pass "fm-merge-rules puts changed files into the docs, tests, and dependency classes"
}

test_deps_check() {
  local dir="$TMP_ROOT/deps" rc
  mkdir -p "$dir"
  printf '%s\n' '{"name":"a","scripts":{"t":"x"},"dependencies":{"x":"^1.2.0","y":"0.3.1","g":"github:a/b"},"devDependencies":{"z":"~4.0.0"}}' > "$dir/old.json"
  printf '%s\n' '{"name":"a","scripts":{"t":"x"},"dependencies":{"x":"^1.9.0","y":"0.3.4","g":"github:a/b"},"devDependencies":{"z":"~4.1.2"}}' > "$dir/ok.json"
  printf '%s\n' '{"name":"a","scripts":{"t":"y"},"dependencies":{"x":"^2.0.0","y":"0.4.0","g":"github:a/c"},"devDependencies":{"z":"~4.0.0"}}' > "$dir/bad.json"
  printf '%s\n' '{"name":"a","scripts":{"t":"x"},"dependencies":{"x":"^1.2.0","y":"0.3.1","g":"github:a/b","n":"1.0.0"},"devDependencies":{"z":"~4.0.0"}}' > "$dir/added.json"
  "$RULES" deps-check "$dir/old.json" "$dir/ok.json" > "$dir/out" || fail "deps: a same-major update was refused: $(cat "$dir/out")"
  set +e
  "$RULES" deps-check "$dir/old.json" "$dir/bad.json" > "$dir/out"
  rc=$?
  set -e
  expect_code 1 "$rc" "deps: a major bump must refuse"
  assert_grep 'fields outside the dependency sections changed' "$dir/out" "deps: a scripts change was not named"
  assert_grep 'x changes major version (^1.2.0 to ^2.0.0)' "$dir/out" "deps: the major bump was not named"
  assert_grep 'y changes a 0.x minor version (0.3.1 to 0.4.0)' "$dir/out" "deps: the 0.x minor bump was not named"
  assert_grep 'g is not a plain version' "$dir/out" "deps: a git spec change was not named"
  set +e
  "$RULES" deps-check "$dir/old.json" "$dir/added.json" > "$dir/out"
  rc=$?
  set -e
  expect_code 1 "$rc" "deps: an added dependency must refuse"
  assert_grep 'dependencies adds or removes a dependency' "$dir/out" "deps: the added dependency was not named"
  printf 'not json\n' > "$dir/broken.json"
  set +e
  "$RULES" deps-check "$dir/old.json" "$dir/broken.json" > "$dir/out"
  rc=$?
  set -e
  expect_code 1 "$rc" "deps: unreadable JSON must refuse"
  pass "fm-merge-rules lets a package.json change through only within the same major version"
}

test_trail_lines_carry_no_names() {
  [ "$("$RULES" trail approved)" = "Merge trail: merged on the owner's yes." ] || fail "trail: approved line changed"
  [ "$("$RULES" trail docs)" = "Merge trail: landed by itself under this project's merge rule (docs only)." ] \
    || fail "trail: docs line changed"
  "$RULES" trail tests | grep -q '(tests only)' || fail "trail: tests line changed"
  "$RULES" trail deps | grep -q 'same major version' || fail "trail: deps line changed"
  "$RULES" trail anything | grep -q 'any green change' || fail "trail: anything line changed"
  set +e
  "$RULES" trail mixed > /dev/null 2>&1
  expect_code 2 "$?" "trail: an unknown class must refuse"
  set -e
  pass "fm-merge-rules prints one generic trail line per outcome"
}

test_table_rows_and_matching
test_malformed_tables_refuse
test_file_classes
test_deps_check
test_trail_lines_carry_no_names

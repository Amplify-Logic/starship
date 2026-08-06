#!/usr/bin/env bash
# .gitignore must ignore the repo-root config/ directory as a whole - by
# directory, not by exact filename - and must not reach a config-named
# directory anywhere else in the tree.
#
# A name-by-name list silently stops ignoring any new or home-local file under
# config/ (fm-gitignore-config-name-by-name): an unrecognized file there makes
# the working tree read as dirty, which then blocks guarded sync paths that
# refuse to touch a dirty home.
# An unanchored config/ rule fails the other way, silently swallowing unrelated
# paths under any nested directory named config.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

random_leaf() {
  printf '%s-%s' "$1" "$$-$RANDOM-$RANDOM"
}

# git check-ignore consults every ignore source: the tracked .gitignore, the
# per-worktree .git/info/exclude that fm-spawn writes, and core.excludesFile.
# A bare match therefore cannot prove the tracked rule is what protects the
# path, so the positive assertion pins the reported source to .gitignore and
# the negative one pins the "no source matched" exit status rather than
# accepting any failure.
#
# `-v` reports the last matching pattern as
# <source>:<linenum>:<pattern><TAB><pathname>, and it exits 0 for a negated
# pattern too: a `!config/<name>` re-include under a `/config/*`-style rule
# leaves the path committable while still reporting a match. Matching on
# polarity is what separates "ignored" from "matched".
assert_ignored_by_tracked_gitignore() {
  local path=$1 why=$2 out status matched ignore_source pattern
  out="$(git -C "$ROOT" check-ignore -v -- "$path" 2>&1)"
  status=$?
  case "$status" in
    0) ;;
    1) fail "git does not ignore $path ($why)" ;;
    *) fail "git check-ignore failed for $path (exit $status): $out" ;;
  esac
  matched=${out%%$'\t'*}
  ignore_source=${matched%%:*}
  pattern=${matched#*:}
  pattern=${pattern#*:}
  [ "$ignore_source" = .gitignore ] \
    || fail "$path is ignored by another source, not the tracked .gitignore ($why): $out"
  case "$pattern" in
    '!'*)
      fail "$path matches negated pattern $pattern, so it stays committable ($why): $out"
      ;;
  esac
}

assert_not_ignored() {
  local path=$1 why=$2 out status
  out="$(git -C "$ROOT" check-ignore -v -- "$path" 2>&1)"
  status=$?
  case "$status" in
    1) ;;
    0) fail "git unexpectedly ignores $path ($why): $out" ;;
    *) fail "git check-ignore failed for $path (exit $status): $out" ;;
  esac
}

test_config_dir_ignored_as_category() {
  local direct nested sample
  direct="$(random_leaf config/unlisted-key)"
  nested="config/$(random_leaf nested-dir)/$(random_leaf deep-file)"
  for sample in "$direct" "$nested" config/some-new-key.admin; do
    assert_ignored_by_tracked_gitignore "$sample" \
      "config/ must be ignored as a directory"
  done
  pass "config/ is ignored as a directory by the tracked .gitignore, covering unlisted and nested paths"
}

test_unrelated_path_stays_visible() {
  # Control: a path outside config/ must remain visible to Git, so the
  # coverage above is proven by contrast rather than an always-ignoring rule.
  local sibling
  sibling="$(random_leaf not-config)"
  assert_not_ignored "$sibling" "outside config/"
  pass "an unrelated path outside config/ remains visible to git"
}

test_nested_config_dir_stays_visible() {
  # Anchoring guard: the ignore rule must match only the repo-root config/
  # directory. An unanchored `config/` pattern also matches a directory named
  # config at any depth, which silently swallows unrelated paths (the bare
  # Actual-* incident class), so a nested config-named path elsewhere in the
  # tree must remain visible to Git.
  local nested
  nested="$(random_leaf docs)/$(random_leaf sub)/config/$(random_leaf file)"
  assert_not_ignored "$nested" "the config/ rule must be anchored to the repo root"
  pass "a config-named directory elsewhere in the tree remains visible to git"
}

test_config_dir_ignored_as_category
test_unrelated_path_stays_visible
test_nested_config_dir_stays_visible

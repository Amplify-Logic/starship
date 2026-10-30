#!/usr/bin/env bash
# tests/fm-opt-in-skills.test.sh - bin/fm-opt-in-skills.sh: a home's presence
# flags decide which opt-in skills are linked into a checkout's skill folder, a
# home's private add-on adds its own skills, the links never make the checkout
# read as changed, and nothing the script did not create is ever touched.
#
# Every case runs against a throwaway git checkout holding a copy of this
# repository's real .gitignore and .agents/opt-in-skills/, with a private
# config/ directory, so no case reads or writes this home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS="$ROOT/bin/fm-opt-in-skills.sh"
TMP_ROOT=$(fm_test_tmproot fm-opt-in-skills)
fm_git_identity fmtest fmtest@example.invalid

# make_checkout <name>: a committed checkout shaped like this repository's skill
# folders, plus an empty config/ for the home that owns it.
make_checkout() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/checkout/.agents/skills/always-on" "$dir/config"
  git init -q "$dir/checkout"
  cp "$ROOT/.gitignore" "$dir/checkout/.gitignore"
  cp -R "$ROOT/.agents/opt-in-skills" "$dir/checkout/.agents/opt-in-skills"
  printf -- '---\nname: always-on\n---\n' > "$dir/checkout/.agents/skills/always-on/SKILL.md"
  git -C "$dir/checkout" add -A
  git -C "$dir/checkout" commit -q -m init
  printf '%s\n' "$dir"
}

run_sync() {  # <dir>
  FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config" "$SKILLS" sync "$1/checkout"
}

linked() {  # <dir> -> sorted names of the links in .agents/skills
  local entry
  for entry in "$1"/checkout/.agents/skills/*; do
    [ -L "$entry" ] && printf '%s\n' "${entry##*/}"
  done | sort | tr '\n' ' ' | sed 's/ $//'
}

test_no_switch_links_nothing() {
  local dir out
  dir=$(make_checkout none)
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "sync with no switch must print nothing"
  assert_equals "" "$(linked "$dir")" "no switch must link no skill"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "the checkout must stay clean"
  pass "a home with no switch gets no opt-in skill"
}

test_switch_links_its_skills_and_checkout_stays_clean() {
  local dir out
  dir=$(make_checkout adhd)
  : > "$dir/config/adhd"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "sync must print nothing when it only links"
  assert_equals "adhd adhd-auto-fire" "$(linked "$dir")" "config/adhd must link both ADHD skills and nothing else"
  assert_equals "../opt-in-skills/adhd" "$(readlink "$dir/checkout/.agents/skills/adhd")" "the link must be relative"
  [ -f "$dir/checkout/.agents/skills/adhd-auto-fire/SKILL.md" ] \
    || fail "the linked skill must be readable at its usual path"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "a linked skill must not make the checkout read as changed"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "adhd adhd-auto-fire" "$(linked "$dir")" "a second sync must keep the same links"
  assert_equals "" "$out" "a second sync must print nothing"
  pass "a switch links its skills where the harness looks, and the checkout stays clean"
}

test_captain_home_switches_link_every_skill() {
  local dir shipped entry flag
  dir=$(make_checkout captain)
  for flag in adhd second-opinion computer-use captain-ledger morning-intake; do : > "$dir/config/$flag"; done
  printf 'enabled = true\n' > "$dir/config/speak"
  run_sync "$dir"
  shipped=$(for entry in "$ROOT"/.agents/opt-in-skills/*/; do entry=${entry%/}; printf '%s\n' "${entry##*/}"; done \
    | sort | tr '\n' ' ' | sed 's/ $//')
  assert_equals "adhd adhd-auto-fire daily-todo-freshness intake-digest-lines macos-computer-use second-opinion-auto-fire" \
    "$shipped" "the shipped opt-in skills changed; update this test and the captain home switch list"
  assert_equals "$shipped" "$(linked "$dir")" "the captain home's switches must link every shipped opt-in skill"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" \
    "the tracked .gitignore must cover every link the script makes"
  pass "the captain home's switch set links every opt-in skill, and the tracked .gitignore covers each link"
}

test_switch_off_removes_only_its_links() {
  local dir
  dir=$(make_checkout off)
  : > "$dir/config/adhd"
  : > "$dir/config/computer-use"
  run_sync "$dir"
  rm -f "$dir/config/adhd"
  run_sync "$dir"
  assert_equals "macos-computer-use" "$(linked "$dir")" "turning config/adhd off must remove only the ADHD links"
  [ -f "$dir/checkout/.agents/skills/always-on/SKILL.md" ] || fail "a tracked skill must never be touched"
  pass "turning a switch off removes only that switch's links"
}

test_either_of_two_switches_turns_a_skill_on() {
  local dir flag
  for flag in morning-intake channel-intake; do
    dir=$(make_checkout "either-$flag")
    printf 'enabled = false\n' > "$dir/config/$flag"
    run_sync "$dir"
    assert_equals "daily-todo-freshness intake-digest-lines" "$(linked "$dir")" \
      "config/$flag alone must link both intake skills"
    [ "$flag" = channel-intake ] && : > "$dir/config/morning-intake"
    [ "$flag" = morning-intake ] && : > "$dir/config/channel-intake"
    run_sync "$dir"
    assert_equals "daily-todo-freshness intake-digest-lines" "$(linked "$dir")" \
      "both switches present must keep the same links"
    rm -f "$dir/config/$flag"
    run_sync "$dir"
    assert_equals "daily-todo-freshness intake-digest-lines" "$(linked "$dir")" \
      "removing one switch must keep the links while the other is present"
    rm -f "$dir/config/morning-intake" "$dir/config/channel-intake"
    run_sync "$dir"
    assert_equals "" "$(linked "$dir")" "removing both switches must unlink the intake skills"
    assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "the checkout must stay clean"
  done
  pass "either of a skill's two switches turns it on, and it goes only when both are gone"
}

test_foreign_path_is_left_alone() {
  local dir out code
  dir=$(make_checkout foreign)
  : > "$dir/config/second-opinion"
  : > "$dir/config/computer-use"
  mkdir -p "$dir/checkout/.agents/skills/second-opinion-auto-fire"
  printf 'mine\n' > "$dir/checkout/.agents/skills/second-opinion-auto-fire/notes"
  ln -s /tmp "$dir/checkout/.agents/skills/macos-computer-use"
  out=$(run_sync "$dir" 2>&1)
  code=$?
  expect_code 0 "$code" "sync must not fail over a path it leaves alone"
  assert_contains "$out" "second-opinion-auto-fire is not this script's link; left as it is" "a real folder must be reported"
  assert_contains "$out" "macos-computer-use is not this script's link; left as it is" "a foreign link must be reported"
  assert_equals "mine" "$(cat "$dir/checkout/.agents/skills/second-opinion-auto-fire/notes")" "a real folder must be kept"
  assert_equals "/tmp" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" "a foreign link must be kept"
  rm -f "$dir/config/computer-use"
  run_sync "$dir" 2>/dev/null
  assert_equals "/tmp" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" \
    "a switched-off skill must not remove a link it does not own"
  pass "a path the script did not create is never replaced or removed"
}

test_checkout_without_opt_in_folder_is_untouched() {
  local dir
  dir="$TMP_ROOT/other-project"
  mkdir -p "$dir/checkout/.agents/skills" "$dir/config"
  : > "$dir/config/adhd"
  run_sync "$dir"
  assert_equals "" "$(linked "$dir")" "a checkout without .agents/opt-in-skills must get no link"
  pass "a checkout with no opt-in skill folder is left alone"
}

# make_addon <dir> <skill>...: a private add-on beside the checkout carrying the
# named skills, configured for the home in <dir>.
make_addon() {
  local dir=$1 skill
  shift
  mkdir -p "$dir/addon/.agents/skills"
  for skill in "$@"; do
    mkdir -p "$dir/addon/.agents/skills/$skill"
    printf -- '---\nname: %s\n---\n' "$skill" > "$dir/addon/.agents/skills/$skill/SKILL.md"
  done
  printf 'path = %s\n' "$dir/addon" > "$dir/config/addon"
}

test_addon_skills_link_and_checkout_stays_clean() {
  local dir out addon
  dir=$(make_checkout addon)
  make_addon "$dir" my-todo my-glasses
  mkdir -p "$dir/addon/.agents/skills/no-skill-file"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "sync must print nothing when it only links add-on skills"
  assert_equals "my-glasses my-todo" "$(linked "$dir")" "every add-on skill with a SKILL.md, and nothing else, must be linked"
  addon=$(cd "$dir/addon" && pwd -P)
  assert_equals "$addon/.agents/skills/my-todo" "$(readlink "$dir/checkout/.agents/skills/my-todo")" \
    "an add-on link must point at the add-on by absolute path"
  [ -f "$dir/checkout/.agents/skills/my-glasses/SKILL.md" ] || fail "a linked add-on skill must be readable at its usual path"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "an add-on link must not make the checkout read as changed"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "a second sync must print nothing"
  assert_equals "2" "$(grep -c '^/.agents/skills/my-' "$dir/checkout/.git/info/exclude")" \
    "a second sync must not repeat an exclude line"
  pass "an add-on's skills are linked where the harness looks, and the checkout stays clean"
}

test_addon_skill_replaces_the_opt_in_skill_of_its_name() {
  local dir addon
  dir=$(make_checkout addon-replace)
  : > "$dir/config/computer-use"
  run_sync "$dir"
  assert_equals "../opt-in-skills/macos-computer-use" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" \
    "the switch alone must link the shipped opt-in skill"
  make_addon "$dir" macos-computer-use
  run_sync "$dir"
  addon=$(cd "$dir/addon" && pwd -P)
  assert_equals "$addon/.agents/skills/macos-computer-use" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" \
    "a skill the add-on carries must replace the opt-in skill of the same name"
  rm -f "$dir/config/addon"
  run_sync "$dir"
  assert_equals "../opt-in-skills/macos-computer-use" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" \
    "without the add-on the switched-on opt-in skill must come back"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "the checkout must stay clean throughout"
  pass "an add-on skill replaces the opt-in skill of its name, and gives it back when the add-on goes"
}

test_addon_links_go_when_the_add_on_drops_them() {
  local dir out
  dir=$(make_checkout addon-drop)
  make_addon "$dir" keep drop
  mkdir -p "$dir/checkout/.agents/skills/drop-real"
  ln -s /tmp "$dir/checkout/.agents/skills/elsewhere"
  run_sync "$dir"
  rm -rf "$dir/addon/.agents/skills/drop"
  run_sync "$dir"
  assert_equals "elsewhere keep" "$(linked "$dir")" "a skill the add-on dropped must lose its link and nothing else"
  mkdir -p "$dir/addon/.agents/skills/always-on"
  printf -- '---\nname: always-on\n---\n' > "$dir/addon/.agents/skills/always-on/SKILL.md"
  out=$(run_sync "$dir" 2>&1)
  assert_contains "$out" "always-on is not this script's link; left as it is" "a tracked skill of the same name must be reported"
  [ -f "$dir/checkout/.agents/skills/always-on/SKILL.md" ] && [ ! -L "$dir/checkout/.agents/skills/always-on" ] \
    || fail "a tracked skill must never be replaced by an add-on skill"
  rm -f "$dir/config/addon"
  run_sync "$dir" 2>/dev/null
  assert_equals "elsewhere" "$(linked "$dir")" "with no add-on configured every add-on link must go, and no other link"
  [ -d "$dir/checkout/.agents/skills/drop-real" ] || fail "a real folder must never be removed"
  pass "add-on links go when the add-on drops a skill or is no longer configured, and nothing else is touched"
}

# run_home_sync <dir>: sync for a home whose checkout is the home itself, as on
# a real machine, so an add-on path relative to the home lands inside it.
run_home_sync() {
  FM_HOME="$1/checkout" FM_CONFIG_OVERRIDE="$1/config" "$SKILLS" sync "$1/checkout" 2>&1
}

test_addon_inside_the_home_links_replaces_and_unlinks() {
  local dir home addon skill
  dir=$(make_checkout addon-in-home)
  home="$dir/checkout"
  : > "$dir/config/computer-use"
  mkdir -p "$home/projects/starship-addon/.agents/skills"
  for skill in macos-computer-use my-todo; do
    mkdir -p "$home/projects/starship-addon/.agents/skills/$skill"
    printf -- '---\nname: %s\n---\n' "$skill" > "$home/projects/starship-addon/.agents/skills/$skill/SKILL.md"
  done
  printf 'path = projects/starship-addon\n' > "$dir/config/addon"
  assert_equals "" "$(run_home_sync "$dir")" "sync must print nothing when it links an add-on inside the home"
  addon=$(cd "$home/projects/starship-addon" && pwd -P)
  assert_equals "$addon/.agents/skills/my-todo" "$(readlink "$home/.agents/skills/my-todo")" \
    "an add-on inside the home must be linked by absolute path"
  assert_equals "$addon/.agents/skills/macos-computer-use" "$(readlink "$home/.agents/skills/macos-computer-use")" \
    "an add-on inside the home must replace the opt-in skill of the same name"
  rm -rf "$home/projects/starship-addon/.agents/skills/my-todo"
  assert_equals "" "$(run_home_sync "$dir")" "sync must print nothing when it removes a dropped add-on skill"
  [ ! -L "$home/.agents/skills/my-todo" ] || fail "a skill the add-on inside the home dropped must lose its link"
  rm -f "$dir/config/addon"
  assert_equals "" "$(run_home_sync "$dir")" "sync must print nothing when it hands a skill back to the opt-in folder"
  assert_equals "../opt-in-skills/macos-computer-use" "$(readlink "$home/.agents/skills/macos-computer-use")" \
    "without the add-on the switched-on opt-in skill must come back"
  assert_equals "macos-computer-use" "$(linked "$dir")" "no add-on link may stay once the add-on goes"
  assert_equals "" "$(git -C "$home" status --porcelain)" "the checkout must stay clean throughout"
  pass "an add-on inside the home links, replaces, and unlinks like one beside it"
}

test_misuse_exits_2() {
  local code
  "$SKILLS" 2>/dev/null; code=$?
  expect_code 2 "$code" "no subcommand"
  "$SKILLS" frobnicate 2>/dev/null; code=$?
  expect_code 2 "$code" "an unknown subcommand"
  "$SKILLS" sync a b 2>/dev/null; code=$?
  expect_code 2 "$code" "sync with two checkouts"
  pass "misuse exits 2"
}

test_no_switch_links_nothing
test_switch_links_its_skills_and_checkout_stays_clean
test_captain_home_switches_link_every_skill
test_switch_off_removes_only_its_links
test_either_of_two_switches_turns_a_skill_on
test_foreign_path_is_left_alone
test_checkout_without_opt_in_folder_is_untouched
test_addon_skills_link_and_checkout_stays_clean
test_addon_skill_replaces_the_opt_in_skill_of_its_name
test_addon_links_go_when_the_add_on_drops_them
test_addon_inside_the_home_links_replaces_and_unlinks
test_misuse_exits_2

echo "# fm-opt-in-skills.test.sh: all assertions passed"

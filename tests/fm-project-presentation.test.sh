#!/usr/bin/env bash
# Focused tests for the single project-name and task-outcome resolver owners.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-presentation)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX/data"

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

test_project_names() {
  assert_eq "$("$ROOT/bin/fm-project-display-name.sh" city-guide)" 'City Guide' \
    'Journey human display name'
  assert_eq "$("$ROOT/bin/fm-project-display-name.sh" atelier)" 'Atelier' \
    'Atelier brand casing'
  assert_eq "$("$ROOT/bin/fm-project-display-name.sh" api-platform)" 'API Platform' \
    'acronym override'
  assert_eq "$("$ROOT/bin/fm-project-display-name.sh" ordinary-project)" 'Ordinary Project' \
    'documented synthesized fallback'
  pass 'project display names preserve brand/acronym overrides and synthesize only the fallback'
}

test_outcomes() {
  cat > "$HOME_FIX/data/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] journey-gps-seven-stop-v8 - Validate GPS triggers across all seven harbour stops (repo: city-guide) (kind: scout)
- [ ] journey-launch-date-plan-r3 - Rebaseline the City Guide launch plan with a date (repo: city-guide) (kind: scout)
EOF
  assert_eq "$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-task-outcome.sh" journey-gps-seven-stop-v8)" \
    'Validate GPS triggers across all seven harbour stops' 'first structured backlog title'
  assert_eq "$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-task-outcome.sh" journey-launch-date-plan-r3)" \
    'Rebaseline the City Guide launch plan with a date' 'second structured backlog title'
  assert_eq "$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-task-outcome.sh" any-id 'Explicit human outcome')" \
    'Explicit human outcome' 'explicit outcome precedence'
  assert_eq "$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-task-outcome.sh" no-structured-title)" \
    'no structured title' 'safe task-id fallback'
  pass 'task outcomes prefer explicit text, parse real-shaped backlog titles, and fall back safely'
}

test_project_names
test_outcomes

#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"
CI="$ROOT/.github/workflows/ci.yml"
CONTRIB="$ROOT/CONTRIBUTING.md"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

# The runner's reference fallback claims a source path as soon as any test file
# names it as text, and this script is itself pure-contract-unit. Spelling the
# two ops sources out here would therefore hand the upstream map a real owner
# for them, which turns the fork registry's legitimate exclusive rows into
# shadows and fork_registry_assert_no_shadow refuses the run. Assembling the
# names keeps this script out of their ownership, so the registry rows stay the
# only claim on them. This is the enforced form of the rule, not a style choice.
OPS_SRC_EXT='sh'
OPS_ORDER_SRC="bin/fm-order.$OPS_SRC_EXT"
OPS_TRAY_SRC="bin/fm-tray.$OPS_SRC_EXT"

init_changed_fixture_repo() {
  local repo=$1 script
  # This fixture copies the real tests/fork-test-registry.conf, so every script
  # that registry registers must be created below. A registered script missing
  # here makes fork_registry_apply fail closed and every selection in this
  # fixture dies with exit 2, so a new registry row needs a new stub here.
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-fork-test-registry-lib.sh" "$repo/bin/fm-fork-test-registry-lib.sh"
  cp "$ROOT/tests/fork-test-registry.conf" "$repo/tests/fork-test-registry.conf"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-captain-translation-contract.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-visible-status.test.sh \
    fm-herdr-layout-preview-e2e.test.sh \
    fm-fork-surface.test.sh \
    fm-test-run.test.sh \
    fm-gitignore-config.test.sh \
    fm-secondmate-sync.test.sh \
    fm-upstream-watch.test.sh \
    fm-upstream.test.sh \
    fm-upstream-ledger.test.sh \
    fm-baby-menu-quota.test.sh \
    fm-home-manifest.test.sh \
    fm-bootstrap.test.sh \
    fm-account.test.sh \
    fm-primary.test.sh \
    fm-spawn-account.test.sh \
    fm-action-gateway-v2.test.sh \
    fm-order.test.sh \
    fm-tray.test.sh \
    fm-deck.test.sh \
    fm-project-presentation.test.sh \
    fm-bridge-view.test.sh \
    fm-spawn-herdr-presentation.test.sh \
    fm-primary-handoff.test.sh \
    fm-morning-intake.test.sh \
    fm-file-eventwait.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-visible-format-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  : >"$repo/$OPS_ORDER_SRC"
  : >"$repo/$OPS_TRAY_SRC"
  printf '# bin/fm-fork-surface.sh\n# bin/fm-leak-guard.sh\n' \
    >>"$repo/tests/fm-fork-surface.test.sh"
  # fm-brief.test.sh is in the runner's own pure-contract-unit map, so this
  # mention makes bin/fm-fork-surface.sh a path upstream genuinely owns.
  printf '# bin/fm-fork-surface.sh\n' >>"$repo/tests/fm-brief.test.sh"
  printf '# bin/fm-fork-test-registry-lib.sh\n# bin/fm-visible-format-lib.sh\n' \
    >>"$repo/tests/fm-test-run.test.sh"
  # Each ops suite names its own source, and the deck suite names both. The
  # deck suite is unclassified in the runner's map, which the no-shadow
  # assertion treats as no upstream answer, so the exclusive registry rows stay
  # legitimate. The ops suites' own mentions are also the reference fallback
  # the runner must still reach when the registry is absent.
  printf '# %s\n' "$OPS_ORDER_SRC" >>"$repo/tests/fm-order.test.sh"
  printf '# %s\n' "$OPS_TRAY_SRC" >>"$repo/tests/fm-tray.test.sh"
  printf '# %s\n# %s\n' "$OPS_TRAY_SRC" "$OPS_ORDER_SRC" >>"$repo/tests/fm-deck.test.sh"
  printf '# .agents/skills/example/SKILL.md\n' >>"$repo/tests/fm-captain-translation-contract.test.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_fork_registry_overlay() {
  local tmp repo listed out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fork-registry.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  listed=$(cd "$repo" && bin/fm-test-run.sh --list --family pure-contract-unit) \
    || { rm -rf "$tmp"; fail "fork registry family row must load"; }
  assert_contains "$listed" "tests/fm-fork-surface.test.sh" \
    "fork registry family row participates in family selection"

  # Two rows match this path, and both must contribute. That the run resolves
  # at all also shows the covers rows are exclusive: the runner's own map has
  # no entry for this path, so falling through to it would fail as unmapped.
  printf '# fixture registry change\n' >> "$repo/tests/fork-test-registry.conf"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || { rm -rf "$tmp"; fail "two rows for one path must load"; }
  assert_contains "$listed" "tests/fm-test-run.test.sh" \
    "first of two rows matching one path contributes its owner"
  assert_contains "$listed" "tests/fm-fork-surface.test.sh" \
    "second of two rows matching one path contributes its owner too"
  git -C "$repo" checkout -- tests/fork-test-registry.conf

  printf '# fixture source\n' > "$repo/bin/fm-fork-surface.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || { rm -rf "$tmp"; fail "fork registry adds row on a mapped source must load"; }
  assert_contains "$listed" "tests/fm-fork-surface.test.sh" \
    "adds row contributes the fork owner for a mapped source"
  assert_contains "$listed" "tests/fm-brief.test.sh" \
    "adds row keeps the upstream family the reference fallback selects"
  git -C "$repo" add bin/fm-fork-surface.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fork-source

  printf '# fixture ignore\n' > "$repo/.gitignore"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || { rm -rf "$tmp"; fail "fork registry adds row must load"; }
  assert_contains "$listed" "tests/fm-fork-surface.test.sh" \
    "adds row contributes the fork owner"
  assert_contains "$listed" "tests/fm-gitignore-config.test.sh" \
    "adds row keeps the upstream config owner"
  assert_contains "$listed" "tests/fm-secondmate-sync.test.sh" \
    "adds row keeps the upstream seed-marker owner"
  assert_contains "$listed" "tests/fm-upstream-watch.test.sh" \
    "adds row contributes the fork private-report owner"
  rm -f "$repo/.gitignore"

  mv "$repo/tests/fork-test-registry.conf" "$repo/tests/fork-test-registry.disabled"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --family pure-contract-unit) \
    || { rm -rf "$tmp"; fail "missing fork registry must preserve the core runner"; }
  assert_not_contains "$listed" "tests/fm-fork-surface.test.sh" \
    "missing fork registry leaves fork-only tests unclassified"
  mv "$repo/tests/fork-test-registry.disabled" "$repo/tests/fork-test-registry.conf"

  printf 'family pure-contract-unit tests/fm-fork-surface.test.sh extra\n' \
    > "$repo/tests/fork-test-registry.conf"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --all 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "malformed fork registry must fail with exit 2, got $rc"; }
  assert_contains "$out" 'expected exactly three fields' \
    "malformed fork registry failure is actionable"

  rm -rf "$tmp"
  pass "fork registry overlays family and path ownership and fails closed when malformed"
}

test_fork_registry_shadow_and_glob_guards() {
  local tmp repo out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fork-guard.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A covers row is exclusive, so claiming a path the runner's own map still
  # owns would delete those owners with no error. The guard refuses the row.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'covers bin/fm-fork-surface.sh tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# fixture source\n' > "$repo/bin/fm-fork-surface.sh"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "shadowing covers row must fail with exit 2, got $rc"; }
  assert_contains "$out" 'shadows the upstream owner' \
    "shadowing covers row names the path it would silently take over"
  rm -f "$repo/bin/fm-fork-surface.sh"

  # The same row as adds is the supported way to add a fork owner there.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'adds bin/fm-fork-surface.sh tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# fixture source\n' > "$repo/bin/fm-fork-surface.sh"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || { rm -rf "$tmp"; fail "adds row on the same path must be accepted"; }
  assert_contains "$out" "tests/fm-fork-surface.test.sh" \
    "adds row is accepted where covers is refused"
  rm -f "$repo/bin/fm-fork-surface.sh"

  # A leading wildcard would claim every changed path in the repository.
  printf 'covers * tests/fm-fork-surface.test.sh\n' \
    > "$repo/tests/fork-test-registry.conf"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --all 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "bare glob must fail with exit 2, got $rc"; }
  assert_contains "$out" 'unsafe repository path glob' \
    "bare glob rejection is actionable"

  # A family row returns before the runner's own map, so a row naming a script
  # the runner already classifies would silently move it out of its family,
  # and a row naming a family the runner does not list would hide it from
  # --list-families and lane composition. Both are refused in every mode.
  printf 'family secondmate tests/fm-brief.test.sh\n' \
    > "$repo/tests/fork-test-registry.conf"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --all 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "re-homing family row must fail with exit 2, got $rc"; }
  assert_contains "$out" 'already classifies as pure-contract-unit' \
    "re-homing family row names the upstream family it would take the script from"

  printf 'family fork-only tests/fm-fork-surface.test.sh\n' \
    > "$repo/tests/fork-test-registry.conf"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list-families 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "unlisted family row must fail with exit 2, got $rc"; }
  assert_contains "$out" 'names a family the runner does not list: fork-only' \
    "unlisted family row rejection is actionable"

  rm -rf "$tmp"
  pass "fork registry refuses shadowing covers rows, repository-wide globs, and unconfined family rows"
}

test_fork_registry_covers_accepts_only_absent_upstream_answers() {
  local tmp repo out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fork-covers.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A script the runner's own map leaves unclassified names a source as text,
  # so the reference fallback answers unclassified for that source. That is the
  # absence of a family, not an owner, and it must not turn a legitimate covers
  # row into a shadow. Both stubs are committed so the only changed path below
  # is the one each row claims.
  printf '#!/usr/bin/env bash\n# bin/fm-covers-probe.sh\n' >"$repo/tests/fm-covers-probe.test.sh"
  chmod +x "$repo/tests/fm-covers-probe.test.sh"
  printf '# fixture source\n' >"$repo/bin/fm-covers-probe.sh"
  git -C "$repo" add tests/fm-covers-probe.test.sh bin/fm-covers-probe.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm probe-stubs

  # Upstream answers __unmapped__: no map case and no test text names the path.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'covers bin/unmapped-source.sh tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# changed\n' >>"$repo/bin/unmapped-source.sh"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1) \
    || { rm -rf "$tmp"; fail "covers row on an __unmapped__ path must be accepted: $out"; }
  assert_contains "$out" "tests/fm-fork-surface.test.sh" \
    "covers row on an __unmapped__ path selects the fork owner"
  git -C "$repo" checkout -- bin/unmapped-source.sh

  # Upstream answers a bare unclassified: only an unclassified script names it.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'covers bin/fm-covers-probe.sh tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# changed\n' >>"$repo/bin/fm-covers-probe.sh"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1) \
    || { rm -rf "$tmp"; fail "covers row on an unclassified path must be accepted: $out"; }
  assert_contains "$out" "tests/fm-fork-surface.test.sh" \
    "covers row on an unclassified path selects the fork owner"
  assert_not_contains "$out" "tests/fm-covers-probe.test.sh" \
    "covers row on an unclassified path is the complete answer for it"
  git -C "$repo" checkout -- bin/fm-covers-probe.sh

  # Upstream answers a real family: the fixture's fm-brief.test.sh is in the
  # runner's own pure-contract-unit map and names bin/fm-fork-surface.sh.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'covers bin/fm-fork-surface.sh tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# fixture source\n' >"$repo/bin/fm-fork-surface.sh"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "covers row on a family-owned path must fail with exit 2, got $rc"; }
  assert_contains "$out" 'shadows the upstream owner of bin/fm-fork-surface.sh: pure-contract-unit' \
    "covers row on a family-owned path is refused as a shadow"
  rm -f "$repo/bin/fm-fork-surface.sh"

  # Upstream answers a script: .gitignore has two direct script owners.
  printf 'covers tests/fork-test-registry.conf tests/fm-test-run.test.sh\n%s' \
    'covers .gitignore tests/fm-fork-surface.test.sh' \
    > "$repo/tests/fork-test-registry.conf"
  printf '# fixture ignore\n' >"$repo/.gitignore"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "covers row on a script-owned path must fail with exit 2, got $rc"; }
  assert_contains "$out" 'shadows the upstream owner of .gitignore: __script__:fm-gitignore-config.test.sh' \
    "covers row on a script-owned path is refused as a shadow"
  rm -f "$repo/.gitignore"

  rm -rf "$tmp"
  pass "fork registry accepts covers rows only where upstream answers __unmapped__ or unclassified"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/bin/fm-visible-format-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-visible-status.test.sh" "visible format library selects live status coverage"
  assert_contains "$listed" "tests/fm-herdr-layout-preview-e2e.test.sh" "visible format library selects preview coverage"
  git -C "$repo" add bin/fm-visible-format-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm visible-format-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-captain-translation-contract.test.sh" "skill source selects contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

# The ops command center has no hook in a core script, so its registry rows are
# the whole integration and the degraded path is the registry's own absence.
# The guarantee is that absence cannot break a changed run: without the registry
# both ops sources fall to the runner's reference fallback rather than to
# __unmapped__, which is the one answer a changed run dies on. With the registry
# the rows are the complete answer, and they include the order suite as an owner
# of the tray source, because the order script calls the tray script and no test
# text names that dependency for the fallback to find.
# Every phase asserts the runner's own exit code rather than merely succeeding or
# merely failing, because a refusal and an accident such as a missing
# interpreter are both non-zero and only the exact code tells them apart. Each
# assertion below was confirmed to fail when the row or mention it pins is
# removed, so none of them is vacuous.
test_fork_registry_ops_rows_and_registry_absence() {
  local tmp repo out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ops-rows.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '# fixture order change\n' >>"$repo/$OPS_ORDER_SRC"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "covers row for the order source must load"
  assert_contains "$out" "tests/fm-order.test.sh" \
    "covers row selects the order suite for its own source"
  assert_not_contains "$out" "tests/fm-brief.test.sh" \
    "covers row is the complete answer for the order source"
  git -C "$repo" checkout -- "$OPS_ORDER_SRC"

  printf '# fixture tray change\n' >>"$repo/$OPS_TRAY_SRC"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "covers rows for the tray source must load"
  assert_contains "$out" "tests/fm-tray.test.sh" \
    "covers row selects the tray suite for its own source"
  assert_contains "$out" "tests/fm-order.test.sh" \
    "the order suite is a declared owner of the tray source"
  git -C "$repo" checkout -- "$OPS_TRAY_SRC"

  # The same change in a checkout with no fork registry at all. The removal is
  # committed so the tray source is again the only changed path, and the runner
  # must still resolve it through its own reference fallback rather than die.
  git -C "$repo" rm -q tests/fork-test-registry.conf
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm no-registry
  printf '# fixture tray change\n' >>"$repo/$OPS_TRAY_SRC"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an absent fork registry must not break an ops-path change"
  assert_not_contains "$out" "no changed-test mapping" \
    "an absent fork registry must not leave an ops source unmapped"
  assert_contains "$out" "tests/fm-tray.test.sh" \
    "the reference fallback still reaches the tray suite with no registry"
  git -C "$repo" checkout -- "$OPS_TRAY_SRC"

  # The far side of that guarantee. The fallback only reaches the tray source
  # because its own suite and the deck suite name it, so with the registry and
  # every such mention gone the runner has no owner at all. It must then refuse
  # with its own exit code 2 and say which path it could not map, never select
  # nothing quietly.
  local suite
  for suite in fm-tray fm-deck; do
    grep -v "$OPS_TRAY_SRC" "$repo/tests/$suite.test.sh" >"$repo/tests/$suite.trimmed"
    mv "$repo/tests/$suite.trimmed" "$repo/tests/$suite.test.sh"
    chmod +x "$repo/tests/$suite.test.sh"
    git -C "$repo" add "tests/$suite.test.sh"
  done
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm no-mention
  printf '# fixture tray change\n' >>"$repo/$OPS_TRAY_SRC"
  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" \
    "an ops source with no registry row and no test mention must refuse with exit 2"
  assert_contains "$out" "no changed-test mapping for source path" \
    "the refusal names the path it could not map"

  rm -rf "$tmp"
  pass "ops command center rows select their declared owners, degrade to the reference fallback, and refuse with exit 2 when neither answers"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  printf 'documentation only\n' >"$repo/ONBOARDING.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_ci_and_docs_call_the_owner() {
  assert_present "$CI" "ci.yml missing"
  assert_present "$CONTRIB" "CONTRIBUTING.md missing"
  grep -Fq 'tests-portable-parallel-1:' "$CI" \
    || fail "CI must define portable parallel shard 1"
  grep -Fq 'tests-portable-parallel-2:' "$CI" \
    || fail "CI must define portable parallel shard 2"
  grep -Fq 'tests-portable-serial-1:' "$CI" \
    || fail "CI must define portable serial shard 1"
  grep -Fq 'tests-portable-serial-2:' "$CI" \
    || fail "CI must define portable serial shard 2"
  if grep -Eq '^  tests-portable-serial:' "$CI"; then
    fail "CI must not keep the unsharded tests-portable-serial job"
  fi
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-1' "$CI" \
    || fail "CI shard 1 must invoke --lane portable-parallel-1"
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-2' "$CI" \
    || fail "CI shard 2 must invoke --lane portable-parallel-2"
  local shard job_body
  for shard in 1 2; do
    job_body=$(awk -v job="  tests-portable-parallel-$shard:" '
      $0 == job { in_job=1; next }
      in_job && /^  [a-zA-Z0-9_-]+:/ { exit }
      in_job { print }
    ' "$CI")
    printf '%s\n' "$job_body" | grep -Fq 'npm install -g tasks-axi' \
      || fail "CI portable parallel shard $shard must install tasks-axi"
    printf '%s\n' "$job_body" | grep -Fq 'tasks-axi --version' \
      || fail "CI portable parallel shard $shard must verify tasks-axi"
  done
  grep -Fq 'bin/fm-test-run.sh --lane portable-serial-1' "$CI" \
    || fail "CI serial shard 1 must invoke --lane portable-serial-1"
  grep -Fq 'bin/fm-test-run.sh --lane portable-serial-2' "$CI" \
    || fail "CI serial shard 2 must invoke --lane portable-serial-2"
  for shard in 1 2; do
    job_body=$(awk -v job="  tests-portable-serial-$shard:" '
      $0 == job { in_job=1; next }
      in_job && /^  [a-zA-Z0-9_-]+:/ { exit }
      in_job { print }
    ' "$CI")
    printf '%s\n' "$job_body" | grep -Fq 'timeout-minutes: 20' \
      || fail "CI portable serial shard $shard hang tripwire must be timeout-minutes: 20"
    printf '%s\n' "$job_body" | grep -Fq 'npm install -g tasks-axi' \
      || fail "CI portable serial shard $shard must install tasks-axi"
    printf '%s\n' "$job_body" | grep -Fq 'command -v tmux' \
      || fail "CI portable serial shard $shard must require tmux"
  done
  grep -Fq 'bin/fm-test-run.sh --check-coverage' "$CI" \
    || fail "CI must run the coverage guard"
  grep -Fq 'tests-herdr:' "$CI" \
    || fail "CI must define the required tests-herdr job"
  grep -Fq 'bin/fm-test-run.sh --family real-herdr-gated' "$CI" \
    || fail "Herdr CI job must run the real-herdr-gated family via fm-test-run"
  grep -Fq -- "--fail-on-gate-skip 'herdr not found'" "$CI" \
    || fail "Herdr CI job must fail on herdr-not-found skips"
  grep -Fq 'bin/fm-install-herdr.sh' "$CI" \
    || fail "Herdr CI job must install via bin/fm-install-herdr.sh"
  grep -Fq 'bin/fm-install-treehouse.sh' "$CI" \
    || fail "Herdr CI job must install via bin/fm-install-treehouse.sh"
  grep -Fq 'bin/fm-herdr-ci-cleanup.sh' "$CI" \
    || fail "Herdr CI job must use bounded lab cleanup"
  grep -Fq 'tests-timing-aggregate:' "$CI" \
    || fail "CI must aggregate per-lane timing artifacts"
  grep -Fq 'timeout-minutes: 10' "$CI" \
    || fail "portable parallel shards must keep a hang tripwire (10m)"
  if grep -Eq 'timeout-minutes: 30' "$CI"; then
    fail "unsharded 30m portable-serial tripwire must not remain after serial re-shard"
  fi
  # Interim full-suite 25m portable timeout must not remain after sharding.
  if grep -Eq 'timeout-minutes: 25' "$CI"; then
    fail "CI still has interim timeout-minutes: 25 after portable sharding"
  fi
  # Stale "~2-3 minutes" claim must not remain.
  if grep -Eq '2-3 minutes' "$CI"; then
    fail "CI workflow still claims the suite finishes in ~2-3 minutes"
  fi
  # No retry-green strategy on Behavior lanes.
  if grep -Eqi 'retry:|max-attempts:|continue-on-error:\s*true' "$CI"; then
    fail "CI must not use retries or continue-on-error as a green strategy"
  fi
  grep -Fq 'fm-test-timing' "$CI" \
    || fail "CI must upload timing artifacts"
  grep -Fq 'bin/fm-test-run.sh --all' "$CONTRIB" \
    || fail "CONTRIBUTING must document bin/fm-test-run.sh --all"
  grep -Fq 'bin/fm-test-run.sh --family' "$CONTRIB" \
    || fail "CONTRIBUTING must document family selection"
  grep -Fq 'bin/fm-test-run.sh --changed' "$CONTRIB" \
    || fail "CONTRIBUTING must document changed-file selection"
  grep -Fq 'bin/fm-test-run.sh --proven-isolated --jobs' "$CONTRIB" \
    || fail "CONTRIBUTING must document proven-isolated --jobs"
  grep -Fq 'intent-targeted' "$CONTRIB" \
    || fail "CONTRIBUTING must document intent-targeted no-mistakes Test"
  # Do not restore a complete-suite commands.test.
  if grep -E '^[[:space:]]*test:[[:space:]].*tests/\*\.test\.sh' "$ROOT/.no-mistakes.yaml" >/dev/null 2>&1; then
    fail ".no-mistakes.yaml must not set a full-suite commands.test"
  fi
  pass "CI and CONTRIBUTING call the one-owner runner; no full-suite local Test"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 ser1 ser2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  ser1=$("$RUNNER" --list --lane portable-serial-1)
  ser2=$("$RUNNER" --list --lane portable-serial-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  [ -n "$ser1" ] && [ -n "$ser2" ] || fail "portable serial shards must be non-empty"
  # Parallel shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Serial shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$ser1" | LC_ALL=C sort) <(printf '%s\n' "$ser2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable serial shards overlap: $overlap"
  # Union of parallel shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # Union of serial shards equals the serial remainder alias.
  [ "$(printf '%s\n' "$ser1" "$ser2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$serial" | LC_ALL=C sort -u)" ] \
    || fail "serial shard union must equal portable-serial remainder"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$ser1" "$ser2" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$ser1" "$ser2" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the five partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$ser1" "$ser2" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of parallel shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-arm-pretool-check.test.sh" ] \
    || fail "shard 1 must start with longest proven script, got $first"
  first=$(printf '%s\n' "$ser1" | head -n 1)
  [ "$first" = "tests/fm-pr-check-security.test.sh" ] \
    || fail "serial shard 1 must start with longest serial script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_jobs_requires_proven_isolated() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-no-mistakes-ownership.test.sh
  b=tests/fm-stow-contract.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
# Occupy a worker slot until the replacement fixture starts. Bounded marker
# waits replace wall-clock sleeps so load cannot invert 0.5s vs 0.05s.
touch "$SCHED_EVIDENCE/slow-running"
n=0
while [ ! -e "$SCHED_EVIDENCE/release-slow" ]; do
  sleep 0.01
  n=$((n + 1))
  if [ "$n" -ge 2000 ]; then
    echo "not ok - slow fixture timed out waiting for replacement to start"
    exit 1
  fi
done
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
n=0
while [ ! -e "$SCHED_EVIDENCE/slow-running" ]; do
  sleep 0.01
  n=$((n + 1))
  if [ "$n" -ge 2000 ]; then
    echo "not ok - fast fixture timed out waiting for slow to occupy a slot"
    exit 1
  fi
done
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SCHED_EVIDENCE/slow-running" ]; then
  echo "not ok - replacement started before slow occupied a slot"
  exit 1
fi
echo "ok - replacement fixture started before slow fixture finished"
touch "$SCHED_EVIDENCE/release-slow"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Later cases must not inherit the hold-until-release slow fixture.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
echo "ok - slow fixture"
SH
  chmod +x "$repo/$a"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_fork_registry_overlay
test_fork_registry_shadow_and_glob_guards
test_fork_registry_covers_accepts_only_absent_upstream_answers
test_fork_registry_ops_rows_and_registry_absence
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_ci_and_docs_call_the_owner
test_portable_shard_union_and_coverage_guard
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_aggregate_json

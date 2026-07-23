#!/usr/bin/env bash
# Port captain-private portable Firstmate home material between machines.
#
# Single owner of the portable allowlist, the refuse list, the embedded-secret
# scan, and the explicit push/pull sync against a private git transport.
# Operator narrative, conflict story, and one-command handoff live in
# docs/porting.md - this header owns exact flags, paths, and fail-closed rules.
#
# Captain decision 2026-07-21:
#   - secrets (.env, live API credentials, cmux socket password) NEVER port
#   - state/ and projects/ NEVER port (machine-local)
#   - sync is explicit and captain-triggered, never silent two-way auto-sync
#
# Usage:
#   fm-home-port.sh export [--dest DIR] [--home DIR]
#   fm-home-port.sh import --source DIR [--home DIR]
#   fm-home-port.sh push --remote OWNER/REPO|URL [--home DIR] [--create-private]
#   fm-home-port.sh pull --remote OWNER/REPO|URL [--home DIR]
#   fm-home-port.sh bootstrap --portable-repo OWNER/REPO|URL [--home DIR]
#   fm-home-port.sh scan [--warn-machine-local] PATH...
#   fm-home-port.sh verify [--home DIR]
#   fm-home-port.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-leak-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-leak-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

# Verified worker harness names (same set as crew-dispatch validation).
FM_PORT_VERIFIED_HARNESSES="claude codex opencode pi grok cursor"

usage() {
  cat <<'EOF'
Usage:
  fm-home-port.sh export [--dest DIR] [--home DIR]
  fm-home-port.sh import --source DIR [--home DIR]
  fm-home-port.sh push --remote OWNER/REPO|URL [--home DIR] [--create-private]
  fm-home-port.sh pull --remote OWNER/REPO|URL [--home DIR]
  fm-home-port.sh bootstrap --portable-repo OWNER/REPO|URL [--home DIR]
  fm-home-port.sh scan [--warn-machine-local] PATH...
  fm-home-port.sh verify [--home DIR]
  fm-home-port.sh --help

Port captain-private portable Firstmate material between machines through an
explicit, captain-triggered private-git sync. Secrets, state/, and projects/
never port; see docs/porting.md.

scan runs the credential scan (non-zero on SECRET_HIT).
--warn-machine-local adds an advisory email /Users/<name> pass that never
changes the exit code; patterns are owned by bin/fm-leak-lib.sh (shared with CI).

verify runs the destination readiness checks from docs/porting.md plus
config/backend and config/crew-harness presence checks.

Environment:
  FM_HOME             active firstmate home (default: tracked root)
  FM_ROOT_OVERRIDE    firstmate repo root
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

refuse() {
  printf 'REFUSED: %s\n' "$1" >&2
}

STAGE_DIR=""
report_stage_leftover() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    printf 'STAGE LEFT: %s (captain-private staging dir; inspect then remove)\n' "$STAGE_DIR" >&2
  fi
}

# Portable allowlist - relative paths under FM_HOME. Optional files may be
# absent; required ones are validated at export/push time when present in the
# source home's expected operating set.
PORTABLE_DATA_FILES=(
  data/captain.md
  data/captain-shared.md
  data/learnings.md
  data/backlog.md
)

PORTABLE_CONFIG_FILES=(
  config/backend
  config/crew-harness
  config/crew-dispatch.json
  config/secondmate-harness
  config/backlog-backend
  config/wedge-alarm
)

# Names that always refuse if requested or found under an export source tree
# that tried to include them. Presence in the home during a normal allowlist
# export prints a loud REFUSED line so nobody assumes they crossed.
REFUSED_BASENAMES=(
  .env
  cmux-socket-password
  x-mode.env
)

# Path prefixes (relative) that never port.
REFUSED_PREFIXES=(
  state/
  projects/
)

resolve_home() {
  local home=${1:-$FM_HOME}
  [ -d "$home" ] || die "home does not exist: $home"
  (cd "$home" && pwd -P)
}

is_refused_relpath() {
  local rel=$1 prefix base name
  case "$rel" in
    .env|./.env) return 0 ;;
  esac
  for prefix in "${REFUSED_PREFIXES[@]}"; do
    case "$rel" in
      "$prefix"*|./"$prefix"*) return 0 ;;
    esac
  done
  base=$(basename -- "$rel")
  for name in "${REFUSED_BASENAMES[@]}"; do
    [ "$base" = "$name" ] && return 0
  done
  case "$rel" in
    config/cmux-socket-password|./config/cmux-socket-password) return 0 ;;
    config/x-mode.env|./config/x-mode.env) return 0 ;;
    data/projects.md|./data/projects.md) return 0 ;;
    data/secondmates.md|./data/secondmates.md) return 0 ;;
  esac
  return 1
}

# Scan file contents for accidentally embedded credentials. Exit 1 on hit.
# Patterns intentionally cover common live tokens; false positives on prose that
# literally discusses "api_key=" shapes are preferred over a silent miss.
scan_path() {
  local path=$1
  local hits=0
  local pattern
  # shellcheck disable=SC2016
  pattern='(FMX_PAIRING_TOKEN[[:space:]]*=|(^|[^A-Za-z0-9_])(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|api[_-]?key[[:space:]]*[=:][[:space:]]*['\''\"]?[A-Za-z0-9_-]{20,}|CMUX_SOCKET_PASSWORD[[:space:]]*=)'

  if [ -d "$path" ]; then
    while IFS= read -r -d '' f; do
      if grep -EIq "$pattern" "$f" 2>/dev/null; then
        printf 'SECRET_HIT: %s\n' "$f" >&2
        hits=1
      fi
    done < <(find "$path" -type f -print0)
  elif [ -f "$path" ]; then
    if grep -EIq "$pattern" "$path" 2>/dev/null; then
      printf 'SECRET_HIT: %s\n' "$path" >&2
      hits=1
    fi
  else
    die "scan target missing: $path"
  fi

  [ "$hits" -eq 0 ] || return 1
  return 0
}

announce_standing_refusals() {
  local home=$1
  local refused=0
  if [ -e "$home/.env" ]; then
    refuse ".env present at $home/.env - secrets do not port (captain decision 2026-07-21); leave credentials on each machine"
    refused=1
  fi
  if [ -d "$home/state" ]; then
    refuse "state/ - machine-local runtime (sessions, panes, watcher internals); never port"
    refused=1
  fi
  if [ -d "$home/projects" ]; then
    refuse "projects/ - machine-local clones; re-clone on the destination via project-management"
    refused=1
  fi
  if [ -e "$home/config/cmux-socket-password" ]; then
    refuse "config/cmux-socket-password - secret; never port"
    refused=1
  fi
  if [ -e "$home/config/x-mode.env" ]; then
    refuse "config/x-mode.env - generated X-mode artifact; never port"
    refused=1
  fi
  if [ -e "$home/data/projects.md" ]; then
    refuse "data/projects.md - fleet registry with machine-local clone bindings; rebuild on the destination"
    refused=1
  fi
  if [ -e "$home/data/secondmates.md" ]; then
    refuse "data/secondmates.md - secondmate homes bind absolute paths; never port"
    refused=1
  fi
  # Loud refusal is mandatory whenever refused material exists, so a future
  # operator cannot assume a "successful export" carried secrets or runtime.
  [ "$refused" -eq 1 ] || printf 'REFUSED: (none present) .env, state/, projects/, secret config - standing policy still applies\n' >&2
}

copy_portable_tree() {
  local src_home=$1 dest_root=$2
  local rel src dest parent copied=0

  for rel in "${PORTABLE_DATA_FILES[@]}" "${PORTABLE_CONFIG_FILES[@]}"; do
    if is_refused_relpath "$rel"; then
      die "internal allowlist contains refused path: $rel"
    fi
    src="$src_home/$rel"
    [ -e "$src" ] || continue
    [ -f "$src" ] || die "portable path is not a regular file: $src"
    dest="$dest_root/$rel"
    parent=$(dirname -- "$dest")
    mkdir -p "$parent"
    cp -p "$src" "$dest"
    printf 'PORTABLE: %s\n' "$rel"
    copied=$((copied + 1))
  done

  [ "$copied" -gt 0 ] || die "no portable files found under $src_home"
}

cmd_scan() {
  local path rc=0 warn_machine_local=0
  local -a paths=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --warn-machine-local)
        warn_machine_local=1
        shift
        ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          paths+=("$1")
          shift
        done
        ;;
      -*)
        die "unknown scan option: $1"
        ;;
      *)
        paths+=("$1")
        shift
        ;;
    esac
  done

  [ "${#paths[@]}" -ge 1 ] || die "scan requires at least one PATH"
  for path in "${paths[@]}"; do
    if scan_path "$path"; then
      printf 'SCAN_CLEAN: %s\n' "$path"
    else
      rc=1
    fi
    if [ "$warn_machine_local" -eq 1 ]; then
      # Advisory only: report hits, never change the exit code.
      if fm_leak_scan_machine_local "$path"; then
        printf 'MACHINE_LOCAL_CLEAN: %s\n' "$path"
      else
        printf 'MACHINE_LOCAL_WARN: %s (rewrite absolute paths / emails before trusting the port; see docs/porting.md)\n' "$path"
      fi
    fi
  done
  return "$rc"
}

# Map a verified worker harness to its launch binary on PATH.
harness_launch_binary() {
  case "$1" in
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    opencode) printf 'opencode\n' ;;
    pi) printf 'pi\n' ;;
    grok) printf 'grok\n' ;;
    cursor) printf 'agent\n' ;;
    *) return 1 ;;
  esac
}

is_verified_harness() {
  local name=$1 h
  for h in $FM_PORT_VERIFIED_HARNESSES; do
    [ "$h" = "$name" ] && return 0
  done
  return 1
}

# Destination readiness checks from docs/porting.md plus backend/harness gates.
# Prints VERIFY_PASS / VERIFY_FAIL / VERIFY_INFO per check; exits non-zero when any fails.
cmd_verify() {
  local home=$FM_HOME failed=0
  local backend crew binary tool missing_tools bootstrap_out
  local -a actionable=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      *)
        die "unknown verify option: $1"
        ;;
    esac
  done

  home=$(resolve_home "$home")

  verify_pass() {
    printf 'VERIFY_PASS: %s - %s\n' "$1" "$2"
  }
  verify_fail() {
    printf 'VERIFY_FAIL: %s - %s\n' "$1" "$2"
    failed=1
  }
  verify_info() {
    printf 'VERIFY_INFO: %s - %s\n' "$1" "$2"
  }

  # 1. Portable captain files present
  if [ -f "$home/data/captain.md" ] && [ -f "$home/data/learnings.md" ] && [ -f "$home/data/backlog.md" ]; then
    verify_pass portable-files "data/captain.md, data/learnings.md, data/backlog.md present"
  else
    verify_fail portable-files "missing one or more of data/captain.md, data/learnings.md, data/backlog.md"
  fi

  # 2. .env note (informational: port refuses .env by construction; local creation is fine)
  if [ -e "$home/.env" ]; then
    verify_info env "local .env present (port never imports .env; treat as machine-local)"
  else
    verify_info env "no .env present (port never imports .env)"
  fi

  # 3. Machine-local dirs exist (empty is fine)
  if [ -d "$home/state" ] && [ -d "$home/projects" ]; then
    verify_pass local-dirs "state/ and projects/ present"
  else
    verify_fail local-dirs "state/ and projects/ must exist (empty is fine); recreate with mkdir -p"
  fi

  # 4. Bootstrap detect-only is clean of unresolved actionable lines
  if [ -x "$FM_ROOT/bin/fm-bootstrap.sh" ]; then
    bootstrap_out=$(
      FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$FM_ROOT/bin/fm-bootstrap.sh" 2>&1 || true
    )
    while IFS= read -r line; do
      case "$line" in
        MISSING:*|MISSING_MANUAL:*|NEEDS_GH_AUTH|BACKEND_INVALID:*|CREW_DISPATCH:*)
          actionable+=("$line")
          ;;
      esac
    done <<< "$bootstrap_out"
    if [ "${#actionable[@]}" -eq 0 ]; then
      verify_pass bootstrap "no unresolved MISSING / NEEDS_GH_AUTH / BACKEND_INVALID / CREW_DISPATCH lines"
    else
      verify_fail bootstrap "unresolved bootstrap lines: ${actionable[*]}"
    fi
  else
    verify_fail bootstrap "fm-bootstrap.sh not found under $FM_ROOT/bin"
  fi

  # 5. Captain preferences and learnings are non-empty (session-start would show them)
  if [ -s "$home/data/captain.md" ] && [ -s "$home/data/learnings.md" ]; then
    verify_pass digest-inputs "captain.md and learnings.md are non-empty for the session-start digest"
  else
    verify_fail digest-inputs "captain.md and/or learnings.md empty; session-start digest would not show preferences"
  fi

  # config/backend: known name and required tools present when set
  if [ -f "$home/config/backend" ]; then
    backend=$(tr -d '[:space:]' < "$home/config/backend" || true)
    if [ -z "$backend" ]; then
      verify_fail backend "config/backend is empty"
    elif ! fm_backend_is_known "$backend"; then
      verify_fail backend "config/backend='$backend' is not a known backend (known: $FM_BACKEND_KNOWN)"
    else
      missing_tools=
      for tool in $(fm_backend_required_tools "$backend"); do
        if ! fm_backend_required_tool_available "$backend" "$tool"; then
          missing_tools="${missing_tools}${missing_tools:+ }$tool"
        fi
      done
      if [ -z "$missing_tools" ]; then
        verify_pass backend "config/backend=$backend is known and required tools are present"
      else
        verify_fail backend "config/backend=$backend is known but missing tools: $missing_tools"
      fi
    fi
  else
    verify_pass backend "config/backend absent (runtime auto-detect / default)"
  fi

  # config/crew-harness: verified worker harness and launch binary present when set
  if [ -f "$home/config/crew-harness" ]; then
    crew=$(tr -d '[:space:]' < "$home/config/crew-harness" || true)
    if [ -z "$crew" ] || [ "$crew" = "default" ]; then
      verify_pass crew-harness "config/crew-harness is default/absent-equivalent"
    elif ! is_verified_harness "$crew"; then
      verify_fail crew-harness "config/crew-harness='$crew' is not a verified worker harness (verified: $FM_PORT_VERIFIED_HARNESSES)"
    else
      binary=$(harness_launch_binary "$crew")
      if command -v "$binary" >/dev/null 2>&1; then
        verify_pass crew-harness "config/crew-harness=$crew is verified and launch binary '$binary' is on PATH"
      else
        verify_fail crew-harness "config/crew-harness=$crew is verified but launch binary '$binary' is not on PATH"
      fi
    fi
  else
    verify_pass crew-harness "config/crew-harness absent (mirrors primary harness)"
  fi

  # 6. Aggregate readiness before real work (after every mechanical check)
  if [ "$failed" -eq 0 ]; then
    verify_pass ready "destination checks passed; complete interactive harness logins before dispatching real work"
    printf 'VERIFY_OK: %s\n' "$home"
    return 0
  fi
  verify_fail ready "one or more checks failed; do not dispatch real work yet"
  printf 'VERIFY_FAILED: %s\n' "$home" >&2
  return 1
}

cmd_export() {
  local home=$FM_HOME dest="" rel flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      --dest)
        [ $# -ge 2 ] || die "--dest requires a directory"
        dest=$2
        shift 2
        ;;
      --include|--with)
        flag=$1
        [ $# -ge 2 ] || die "$flag requires a path"
        # Any explicit include of refused material fails loudly.
        rel=${2#./}
        rel=${rel#/}
        if is_refused_relpath "$rel" || is_refused_relpath "$(basename -- "$2")"; then
          refuse "explicit include of refused path: $2"
          die "secrets and machine-local paths do not port; refusing export"
        fi
        die "export does not accept ad-hoc includes; portable allowlist is fixed (see --help / docs/porting.md)"
        ;;
      *)
        die "unknown export option: $1"
        ;;
    esac
  done

  home=$(resolve_home "$home")
  announce_standing_refusals "$home"

  if [ -z "$dest" ]; then
    dest=$(mktemp -d "${TMPDIR:-/tmp}/fm-home-port-export.XXXXXX")
    printf 'DEST: %s\n' "$dest"
  else
    mkdir -p "$dest"
    dest=$(cd "$dest" && pwd -P)
  fi

  # Refuse if dest already looks like a full home someone might confuse.
  if [ -d "$dest/state" ] || [ -d "$dest/projects" ] || [ -e "$dest/.env" ]; then
    die "export dest looks like a live home (has state/, projects/, or .env); pick an empty staging dir"
  fi

  copy_portable_tree "$home" "$dest"
  scan_path "$dest" || die "exported material failed secret scan; aborting (bundle left for inspection at $dest)"
  printf 'EXPORT_OK: %s\n' "$dest"
}

cmd_import() {
  local home=$FM_HOME source="" rel
  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      --source)
        [ $# -ge 2 ] || die "--source requires a directory"
        source=$2
        shift 2
        ;;
      *)
        die "unknown import option: $1"
        ;;
    esac
  done

  [ -n "$source" ] || die "import requires --source DIR"
  [ -d "$source" ] || die "import source missing: $source"
  source=$(cd "$source" && pwd -P)
  home=$(resolve_home "$home")

  # Fail loudly if the source bundle itself contains refused material.
  if [ -e "$source/.env" ]; then
    refuse "source contains .env"
    die "import refused: secrets do not port"
  fi
  if [ -d "$source/state" ]; then
    refuse "source contains state/"
    die "import refused: machine-local state/ does not port"
  fi
  if [ -d "$source/projects" ]; then
    refuse "source contains projects/"
    die "import refused: machine-local projects/ does not port"
  fi
  if [ -e "$source/config/cmux-socket-password" ]; then
    refuse "source contains config/cmux-socket-password"
    die "import refused: secrets do not port"
  fi

  scan_path "$source" || die "import source failed secret scan; refusing to write into $home"

  mkdir -p "$home/data" "$home/config"

  for rel in "${PORTABLE_DATA_FILES[@]}" "${PORTABLE_CONFIG_FILES[@]}"; do
    [ -f "$source/$rel" ] || continue
    if is_refused_relpath "$rel"; then
      refuse "$rel"
      die "import refused refused-path in source: $rel"
    fi
    mkdir -p "$(dirname -- "$home/$rel")"
    cp -p "$source/$rel" "$home/$rel"
    printf 'IMPORTED: %s\n' "$rel"
  done
  printf 'IMPORT_OK: %s\n' "$home"
}

remote_to_url() {
  local remote=$1
  case "$remote" in
    https://*|git@*|ssh://*) printf '%s\n' "$remote" ;;
    */*) printf 'https://github.com/%s.git\n' "$remote" ;;
    *) die "remote must be OWNER/REPO or a git URL: $remote" ;;
  esac
}

remote_to_slug() {
  local remote=$1
  case "$remote" in
    https://github.com/*)
      remote=${remote#https://github.com/}
      remote=${remote%.git}
      printf '%s\n' "$remote"
      ;;
    git@github.com:*)
      remote=${remote#git@github.com:}
      remote=${remote%.git}
      printf '%s\n' "$remote"
      ;;
    */*)
      printf '%s\n' "$remote"
      ;;
    *)
      die "cannot derive OWNER/REPO from remote: $remote"
      ;;
  esac
}

# Verify a GitHub repo is private. Fail closed if visibility cannot be proven.
assert_remote_private() {
  local slug=$1
  local visibility is_private
  if ! command -v gh >/dev/null 2>&1; then
    die "gh is required to verify private visibility of $slug"
  fi
  visibility=$(gh api "repos/$slug" --jq .visibility 2>/dev/null) \
    || die "could not read visibility for $slug; refusing to push captain-private material"
  is_private=$(gh api "repos/$slug" --jq .private 2>/dev/null) \
    || die "could not read private flag for $slug; refusing to push captain-private material"
  if [ "$visibility" = "private" ] && [ "$is_private" = "true" ]; then
    printf 'PRIVATE_OK: %s (visibility=private)\n' "$slug"
    return 0
  fi
  die "remote $slug is not proven private (visibility=${visibility:-unknown} private=${is_private:-unknown}); refusing to push"
}

ensure_private_repo() {
  local slug=$1
  local owner=${slug%/*} name=${slug#*/}
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$slug" ] \
    || die "invalid OWNER/REPO: $slug"

  if gh api "repos/$slug" >/dev/null 2>&1; then
    assert_remote_private "$slug"
    return 0
  fi

  printf 'CREATE_PRIVATE: %s\n' "$slug"
  # Prefer the full OWNER/REPO form so user and org accounts both land correctly.
  gh repo create "$slug" --private --description "Captain-private Firstmate portable home material (preferences, backlog, routing). Never store .env or credentials here." \
    || die "gh repo create failed for $slug"
  assert_remote_private "$slug"
}

write_portable_scaffold() {
  local stage=$1
  # Keep the portable repo from ever tracking refused paths if someone expands it.
  cat > "$stage/.gitignore" <<'EOF'
.env
state/
projects/
config/cmux-socket-password
config/x-mode.env
data/projects.md
data/secondmates.md
.DS_Store
EOF
  cat > "$stage/README.md" <<'EOF'
# portable-firstmate-home

Captain-private portable Firstmate home material.

Tracked here: `data/captain.md`, `data/learnings.md`, `data/backlog.md`, optional `data/captain-shared.md`, and non-secret `config/` operating choices.

Never store `.env`, API credentials, `state/`, or `projects/` here.

Sync is explicit and captain-triggered via `bin/fm-home-port.sh` in the firstmate repo.
See `docs/porting.md` in your firstmate clone.
EOF
}

cmd_push() {
  local home=$FM_HOME remote="" create=0 slug url stage
  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      --remote)
        [ $# -ge 2 ] || die "--remote requires OWNER/REPO or URL"
        remote=$2
        shift 2
        ;;
      --create-private)
        create=1
        shift
        ;;
      *)
        die "unknown push option: $1"
        ;;
    esac
  done

  [ -n "$remote" ] || die "push requires --remote OWNER/REPO|URL"
  home=$(resolve_home "$home")
  slug=$(remote_to_slug "$remote")
  url=$(remote_to_url "$remote")

  announce_standing_refusals "$home"

  if [ "$create" -eq 1 ]; then
    ensure_private_repo "$slug"
  else
    assert_remote_private "$slug"
  fi

  stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-home-port-push.XXXXXX")
  STAGE_DIR=$stage
  trap report_stage_leftover EXIT

  # Commit the portable snapshot onto the remote's existing history so ongoing
  # captain-triggered UPDATE pushes fast-forward cleanly instead of colliding
  # with a throwaway unrelated history. Clone succeeds for an empty freshly
  # created repo too (no HEAD yet); we start main from origin/main when present.
  local repo="$stage/repo"
  git clone -q "$url" "$repo" \
    || die "push aborted: clone of portable repo failed: $url"
  git -C "$repo" config user.email "firstmate-port@local"
  git -C "$repo" config user.name "firstmate-port"
  if git -C "$repo" rev-parse -q --verify origin/main >/dev/null 2>&1; then
    git -C "$repo" checkout -q -B main origin/main
  else
    git -C "$repo" checkout -q -B main
  fi

  write_portable_scaffold "$repo"
  copy_portable_tree "$home" "$repo"
  scan_path "$repo" || die "push aborted: secret scan failed before writing the bundle"

  git -C "$repo" add -A
  if git -C "$repo" diff --cached --quiet; then
    die "nothing to push ($slug main already matches local portable material)"
  fi
  git -C "$repo" commit -q -m "Portable Firstmate home sync $(date -u +%Y-%m-%dT%H:%MZ)"
  # One-directional: never merge remote into local. A non-fast-forward push means
  # the remote moved since clone; fail loudly rather than reconcile histories.
  git -C "$repo" push origin main \
    || die "push aborted: $slug main diverged since clone (non-fast-forward); no remote changes were merged into local - re-run to retry"
  printf 'PUSH_OK: %s\n' "$slug"
  rm -rf "$stage"
  STAGE_DIR=""
}

cmd_pull() {
  local home=$FM_HOME remote="" slug url stage
  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      --remote)
        [ $# -ge 2 ] || die "--remote requires OWNER/REPO or URL"
        remote=$2
        shift 2
        ;;
      *)
        die "unknown pull option: $1"
        ;;
    esac
  done

  [ -n "$remote" ] || die "pull requires --remote OWNER/REPO|URL"
  home=$(resolve_home "$home")
  slug=$(remote_to_slug "$remote")
  url=$(remote_to_url "$remote")
  assert_remote_private "$slug"

  stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-home-port-pull.XXXXXX")
  STAGE_DIR=$stage
  trap report_stage_leftover EXIT
  git clone -q --depth 1 "$url" "$stage/repo" \
    || die "git clone of portable repo failed: $url"

  if [ -e "$stage/repo/.env" ] || [ -d "$stage/repo/state" ] || [ -d "$stage/repo/projects" ]; then
    refuse "cloned portable repo contains refused machine-local or secret paths"
    die "pull refused: portable transport is contaminated"
  fi

  scan_path "$stage/repo" || die "pull aborted: secret scan failed on cloned material"
  cmd_import --source "$stage/repo" --home "$home"
  printf 'PULL_OK: %s -> %s\n' "$slug" "$home"
  rm -rf "$stage"
  STAGE_DIR=""
}

print_login_checklist() {
  cat <<'EOF'

HARNESS_LOGINS (interactive; cannot be automated):
  1. gh auth status          - confirm GitHub CLI auth for the account that owns the private portable transport
  2. claude                  - Claude Code login (alternate-account isolation under state/ if used)
  3. agent / cursor-agent    - Cursor CLI login
  4. codex                   - Codex CLI login
  5. kimi                    - Kimi Code login (if used as primary)
  6. pi                      - Pi login (if used)

CLAUDE_CONFIG_DIR:
  On each machine, recreate the alternate-account isolation directory under
  THAT machine's home state/ path (never copy credentials across machines).
  Pattern recorded in data/learnings.md; rewrite absolute paths after import.

NEXT:
  Run bin/fm-bootstrap.sh (or start a primary session so session-start runs it).
  Resolve any MISSING: lines it prints before trusting the home with real work.
  See docs/porting.md for verification checks.
EOF
}

cmd_bootstrap() {
  local home=$FM_HOME remote=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --home)
        [ $# -ge 2 ] || die "--home requires a directory"
        home=$2
        shift 2
        ;;
      --portable-repo)
        [ $# -ge 2 ] || die "--portable-repo requires OWNER/REPO or URL"
        remote=$2
        shift 2
        ;;
      *)
        die "unknown bootstrap option: $1"
        ;;
    esac
  done

  [ -n "$remote" ] || die "bootstrap requires --portable-repo OWNER/REPO|URL"
  mkdir -p "$home"
  home=$(cd "$home" && pwd -P)
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"

  cmd_pull --remote "$remote" --home "$home"

  if [ -x "$home/bin/fm-bootstrap.sh" ]; then
    printf 'BOOTSTRAP_DETECT: running %s\n' "$home/bin/fm-bootstrap.sh"
    # Detect-only path: bootstrap prints MISSING: lines; mutating sweeps need a
    # session lock this one-shot handoff does not hold.
    FM_HOME="$home" "$home/bin/fm-bootstrap.sh" || true
  elif [ -x "$FM_ROOT/bin/fm-bootstrap.sh" ]; then
    printf 'BOOTSTRAP_DETECT: running %s\n' "$FM_ROOT/bin/fm-bootstrap.sh"
    FM_HOME="$home" "$FM_ROOT/bin/fm-bootstrap.sh" || true
  else
    printf 'BOOTSTRAP_DETECT: skipped (fm-bootstrap.sh not found under home or FM_ROOT)\n' >&2
  fi

  print_login_checklist
  printf 'BOOTSTRAP_OK: %s\n' "$home"
}

main() {
  local cmd
  [ $# -ge 1 ] || { usage; exit 2; }
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    export|import|push|pull|bootstrap|scan|verify)
      cmd=$1
      shift
      "cmd_$cmd" "$@"
      ;;
    *)
      usage >&2
      die "unknown command: $1"
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# fm-leak-prepush.sh - the leak check git runs before every push from this
# home's Starship checkout and from its private add-on checkout, so a plain
# `git push` typed by hand gets the same check as a push through the
# validation pipeline.
#
# WHY. bin/fm-lint.sh runs bin/fm-leak-guard.sh's private word and new-name
# checks only inside the pipeline's lint step, and a branch pushed to a public
# repository is public at once. A pre-push hook in the checkout's own hooks
# directory runs for every push from it, from every task worktree of it too,
# because worktrees share that directory.
#
# WHAT A PUSH CHECKS. Only commits the remote does not have yet are checked: a
# pushed ref whose commits all sit on that remote's tracking refs, or on the
# ref being replaced there, and a deletion pass at once. The checks read the
# checked-out commit and its working tree, so a ref that brings new commits must
# be the commit checked out here, and the tracked files must match that commit;
# any other ref is refused, naming it, and so is a working tree that differs,
# naming the files that do.
#   starship  the pushing checkout's own bin/fm-leak-guard.sh, in the scope the
#             pipeline's lint gives it: the guard's full file scan (email,
#             /Users/<name>, key and token shapes, customer data shapes and
#             private words) over every file the branch changes since its merge
#             base with origin/main, then --new-names over the lines and commit
#             messages it adds. Files the branch leaves alone are already on
#             origin/main, so the scan reads only the changed ones and an
#             ordinary push stays quick; the full-tree scan stays with CI.
#             A push to the validation pipeline's gate (the remote named
#             no-mistakes, at a local path) is not checked here, because the
#             pipeline's lint step runs the same check before anything leaves
#             the machine, and it says so on one line.
#   addon     only what fits a private repository that legitimately holds its
#             own private words and names: key and token shapes and customer
#             data shapes (bin/fm-leak-shapes.py owns both) in the lines and
#             commit messages the push adds since the merge base with the
#             remote's copy of the pushed branch (else the remote's HEAD; with
#             neither, every tracked file). tests/ is exempt, as in the guard.
# A hit refuses the push and prints the guard's own LEAK_HIT lines, which place
# a private word or a token without printing it. A check that cannot run
# refuses too.
#
# BYPASS. git's own --no-verify, which skips every pre-push hook, is the only
# way past the check.
#
# CHAINING. install moves a pre-push hook that is not this one to
# pre-push.fm-chained in the same directory, and the check runs it, with git's
# arguments and ref lines, after it passes (or leaves a gate push to the
# pipeline); a refused push never reaches it. A fleet pane's own pre-push wrapper (bin/fm-git-strip-ai-trailers.sh)
# chains to this hook in turn.
#
# Usage:
#   fm-leak-prepush.sh install <checkout> starship|addon
#       Write the hook into the checkout's hooks directory, idempotently. The
#       hook runs this file from where it is now. Silent when it is current or
#       when <checkout> is not the top of a non-bare repository's main working
#       tree (a task worktree or a validation copy shares its primary's hooks);
#       prints one `LEAK_PREPUSH: <checkout>: <problem>` line on stdout and
#       exits 1 when it cannot install, including when core.hooksPath names a
#       directory outside the repository's git directory, such as a tracked one
#       or a user-global one every repository on the Mac shares. Session-start bootstrap
#       (bin/fm-bootstrap.sh) runs it for the home's checkout and its add-on.
#   fm-leak-prepush.sh check starship|addon <hooks-dir> <remote> <url>
#       What the installed hook runs: git's ref lines on stdin. Exits 1 to
#       refuse the push.
set -u
unset CDPATH

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MARKER='fm-leak-prepush hook'

say() { printf 'fm-leak-prepush: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage:
  fm-leak-prepush.sh install <checkout> starship|addon
  fm-leak-prepush.sh check starship|addon <hooks-dir> <remote> <url>
EOF
  exit 2
}

# git as the repository's own config files set it: no core.hooksPath a fleet
# pane carries in GIT_CONFIG_* or a -c, which would name the pane's directory.
repo_git() { env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS git "$@"; }

quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

render_hook() {  # <kind> <hooks-dir>
  cat <<EOF
#!/usr/bin/env bash
# $MARKER ($1): written by Starship's bin/fm-leak-prepush.sh, which owns what
# it checks; session-start bootstrap keeps it current. A pre-push hook that was
# here before runs from pre-push.fm-chained once the check passes.
check=$(quote "$CODE_ROOT/bin/fm-leak-prepush.sh")
if [ -x "\$check" ]; then
  exec "\$check" check $1 $(quote "$2") "\$@"
fi
printf 'fm-leak-prepush: push refused: the leak check %s is missing; run bin/fm-bootstrap.sh in your Starship home to reinstall this hook\\n' "\$check" >&2
exit 1
EOF
}

install_hook() {  # <checkout> <kind>
  local checkout=$1 kind=$2 top want gitdir common hooks hook chained body tmp
  want=$(cd "$checkout" 2>/dev/null && pwd -P) || return 0
  top=$(repo_git -C "$want" rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(cd "$top" && pwd -P) || return 0
  [ "$top" = "$want" ] || return 0
  gitdir=$(repo_git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  common=$(repo_git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ "$gitdir" = "$common" ] || return 0
  report() { printf 'LEAK_PREPUSH: %s: %s\n' "$checkout" "$1"; return 1; }
  hooks=$(repo_git -C "$top" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) \
    || { report "git cannot name its hooks directory, so the pre-push leak check is not installed"; return 1; }
  common=$(cd "$common" && pwd -P) || return 0
  [ ! -d "$hooks" ] || hooks=$(cd "$hooks" && pwd -P) || return 0
  case "$hooks/" in
    "$common/"*) ;;
    *) report "core.hooksPath points outside this repository's git directory ($hooks), so the pre-push leak check is not installed there"; return 1 ;;
  esac
  mkdir -p "$hooks" || { report "cannot create $hooks"; return 1; }
  hook="$hooks/pre-push"
  chained="$hooks/pre-push.fm-chained"
  body=$(render_hook "$kind" "$hooks")
  if [ -e "$hook" ] || [ -L "$hook" ]; then
    if grep -qF "$MARKER" "$hook" 2>/dev/null; then
      [ "$(cat "$hook")" != "$body" ] || [ ! -x "$hook" ] || return 0
    elif [ -e "$chained" ] || [ -L "$chained" ]; then
      report "$hook is another pre-push hook and $chained already holds an earlier one, so the leak check is not installed; keep one of them and run bootstrap again"
      return 1
    else
      mv "$hook" "$chained" || { report "cannot move the existing pre-push hook to $chained"; return 1; }
    fi
  fi
  tmp=$(mktemp "$hooks/.pre-push.XXXXXX") || { report "cannot write into $hooks"; return 1; }
  if ! { printf '%s\n' "$body" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$hook"; }; then
    rm -f "$tmp"
    report "cannot write $hook"
    return 1
  fi
}

is_zero() { case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac; }

# Whether this push is to the validation pipeline's local gate repository.
is_gate() {  # <remote> <url>
  [ "$1" = no-mistakes ] || return 1
  case "$2" in /* | file://*) return 0 ;; *) return 1 ;; esac
}

# The guard's checks for a Starship checkout.
check_starship() {
  local top=$1 guard base files=() f rc=0
  guard="$top/bin/fm-leak-guard.sh"
  if [ ! -x "$guard" ]; then
    say "push refused: this checkout has no bin/fm-leak-guard.sh to check it with"
    return 1
  fi
  if ! base=$(git -C "$top" merge-base origin/main HEAD 2>/dev/null) || [ -z "$base" ]; then
    say "push refused: no merge base with origin/main to find what this branch adds against; fetch origin and push again"
    return 1
  fi
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(git -C "$top" -c core.quotePath=false diff -z --name-only --diff-filter=d "$base" --)
  if [ "${#files[@]}" -gt 0 ]; then
    (cd "$top" && "$guard" "${files[@]}") >/dev/null || rc=1
  fi
  (cd "$top" && "$guard" --new-names) >/dev/null || rc=1
  if [ "$rc" -ne 0 ]; then
    say "push refused: take out each place the LEAK_HIT lines above name and push again; a new name the owner approves is recorded once, as the guard's line says (see \"Private leak words\" in docs/configuration.md)"
    return 1
  fi
  say "leak check passed: ${#files[@]} changed file(s), and the lines and commit messages this branch adds"
}

# Token and customer data shapes for the private add-on.
check_addon() {  # <top> <remote> <destination ref>
  local top=$1 remote=$2 dest=$3 shapes base='' ref out status=0 files=() f
  shapes="$CODE_ROOT/bin/fm-leak-shapes.py"
  if [ ! -f "$shapes" ] || ! command -v python3 >/dev/null 2>&1; then
    say "push refused: the token and data shape check ($shapes, python3) is not available"
    return 1
  fi
  for ref in "refs/remotes/$remote/${dest#refs/heads/}" "refs/remotes/$remote/HEAD"; do
    git -C "$top" rev-parse -q --verify "$ref" >/dev/null 2>&1 || continue
    base=$(git -C "$top" merge-base HEAD "$ref" 2>/dev/null) && [ -n "$base" ] && break
    base=
  done
  if [ -n "$base" ]; then
    out=$(cd "$top" && python3 "$shapes" --exempt tests --exempt 'tests/*' --diff "$base") || status=$?
  else
    while IFS= read -r -d '' f; do files+=("$f"); done < <(git -C "$top" ls-files -z)
    [ "${#files[@]}" -gt 0 ] || return 0
    out=$(cd "$top" && python3 "$shapes" --exempt tests --exempt 'tests/*' --files "${files[@]}") || status=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  if [ "$status" -eq 1 ] && [[ "$out" == *LEAK_HIT:* ]]; then
    say "push refused: the lines or commit messages this push adds hold key or token shapes or customer data shapes, where the LEAK_HIT lines above say; take each out and push again"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    say "push refused: the token and data shape check could not run"
    return 1
  fi
  say "leak check passed: no key, token or customer data shapes in what this push adds"
}

check_refs() {  # <kind> <remote> <refs>
  local kind=$1 remote=$2 refs=$3 head top lref lsha rref rsha new commit dest='' excl
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { say "push refused: cannot find this checkout's top"; return 1; }
  head=$(git -C "$top" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=
  while read -r lref lsha rref rsha; do
    [ -n "$lref" ] || continue
    ! is_zero "$lsha" || continue
    excl=(--not "--remotes=$remote")
    if [ -n "$rsha" ] && ! is_zero "$rsha" && git -C "$top" rev-parse -q --verify "$rsha^{commit}" >/dev/null 2>&1; then
      excl+=("$rsha")
    fi
    if ! new=$(git -C "$top" rev-list -n 1 "$lsha" "${excl[@]}" --); then
      say "push refused: cannot list the commits $lref brings"
      return 1
    fi
    [ -n "$new" ] || continue
    commit=$(git -C "$top" rev-parse -q --verify "$lsha^{commit}" 2>/dev/null) || commit=
    if [ -z "$commit" ] || [ "$commit" != "$head" ]; then
      say "push refused: $lref brings commits $remote does not have yet but is not the commit checked out here, and the leak check reads the checked-out commit; check it out and push it from there"
      return 1
    fi
    [ -n "$dest" ] || dest=$rref
  done <<<"$refs"
  [ -n "$dest" ] || return 0
  if ! git -C "$top" diff --quiet HEAD --; then
    say "push refused: the leak check reads the working tree, and these tracked files differ from the commit being pushed: $(git -C "$top" -c core.quotePath=false diff --name-only HEAD -- | paste -sd ' ' -); commit, stash or restore them and push again"
    return 1
  fi
  case "$kind" in
    starship) check_starship "$top" ;;
    addon) check_addon "$top" "$remote" "$dest" ;;
  esac
}

check_push() {  # <kind> <hooks-dir> <remote> <url>
  local kind=$1 hooks=$2 remote=$3 url=$4 refs chained
  refs=$(cat)
  if [ "$kind" = starship ] && is_gate "$remote" "$url"; then
    say "push to the validation pipeline's gate: its lint step runs the leak check before anything leaves this machine"
  else
    check_refs "$kind" "$remote" "$refs" || exit 1
  fi
  chained="$hooks/pre-push.fm-chained"
  if [ -x "$chained" ]; then
    if [ -n "$refs" ]; then
      exec "$chained" "$remote" "$url" <<<"$refs"
    fi
    exec "$chained" "$remote" "$url" </dev/null
  fi
  exit 0
}

case "${1:-}" in
  install)
    [ "$#" -eq 3 ] || usage
    case "$3" in starship | addon) ;; *) usage ;; esac
    install_hook "$2" "$3"
    ;;
  check)
    [ "$#" -eq 5 ] || usage
    case "$2" in starship | addon) ;; *) usage ;; esac
    check_push "$2" "$3" "$4" "$5"
    ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# fm-gateway-install-v2.sh - installation lifecycle for the action gateway v2.
#
# This script produces the artifacts a privileged installation needs and shows
# exactly what that installation would do. It never performs one, and it never
# performs an uninstall. `apply` is present and always refuses, because creating
# the service principals, writing the root-owned state ancestors, loading the
# launch definitions, and enrolling the approver key are the captain's own step
# at the Mac, not something an agent does on his behalf.
#
# That refusal is the point of the script rather than a limitation of it. Until
# those commands run under the captain's hands, the gateway's own evidence
# boundary says plainly that distinct installed principals, root-owned
# ancestors, Secure Enclave enrollment, signed UI identity, root launch
# definitions, and network isolation are unproven - and no artifact emitted here
# changes that.
#
# Two rules govern every path this script names or emits:
#
#   Fixed and validated   Every privileged path is a literal constant, checked at
#                         startup for being absolute, normalized, and deep enough
#                         that a truncated or emptied constant can never resolve
#                         to /, /var, /usr, or any other shared ancestor.
#   Never recursive       Uninstall does not delete directories. It moves them to
#                         a timestamped quarantine directory after checking that
#                         the target is not a symlink, is contained in its
#                         expected parent, and is owned by the account that
#                         installed it. Deleting the quarantine afterwards is a
#                         separate decision a person makes with the evidence in
#                         front of them.
#
# Commands:
#   preview            Print the complete activation plan: principals, paths,
#                      owners, modes, launch definitions, and the exact
#                      privileged commands, in the order they must run.
#   check              Report what is actually installed right now, honestly.
#                      Exit 0 when every installed path is present, 3 when it is
#                      not. Reads only; changes nothing.
#   artifacts DIR      Write the launch definition and the install, check, and
#                      uninstall scripts into DIR for review. DIR must not exist
#                      or must be empty. Nothing written there is executable and
#                      nothing written there is run.
#   rollback-preview   Print the guarded uninstall script, in the order its steps
#                      must run. It stops the service, removes the launch
#                      definitions, quarantines the directories, removes the two
#                      role accounts, and removes the dedicated read group only
#                      when it can positively read its membership and find
#                      nothing in it but those accounts. A group in use, or one
#                      whose membership it cannot read, is
#                      left in place and reported as a privileged remnant.
#                      That group's name is its own, matching neither role
#                      account, so its presence is evidence this installation
#                      created it.
#   apply              Always refuses. See above.
#
# This script writes only into a DIR the caller names, and runs none of the
# commands it prints.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT

# Every privileged path below is a literal. assert_fixed_path re-checks each one
# at startup, so a constant that is ever emptied or truncated by an edit fails
# the script instead of being interpolated into a command.
readonly STATE_PARENT=/var/db/firstmate
readonly STATE_ROOT=/var/db/firstmate/gateway
readonly SINK_ROOT=/var/db/firstmate/sink
readonly SOCKET_PARENT=/var/run/firstmate
readonly SOCKET_ROOT=/var/run/firstmate/gateway
readonly INSTALL_PARENT=/usr/local/libexec
readonly INSTALL_ROOT=/usr/local/libexec/firstmate
readonly QUARANTINE_PARENT=/var/db/firstmate
readonly LAUNCH_DAEMONS=/Library/LaunchDaemons
readonly BROKER_LABEL=ai.firstmate.gateway-v2
readonly BROKER_PLIST=/Library/LaunchDaemons/ai.firstmate.gateway-v2.plist
readonly EXECUTOR_PLIST=/Library/LaunchDaemons/ai.firstmate.gateway-v2-executor.plist
readonly BROKER_USER=_firstmate_gateway
readonly EXECUTOR_USER=_firstmate_executor
# Deliberately not either account's name. sysadminctl -roleAccount creates a
# group named after the account it creates, so a group sharing a role account's
# name can never be proved to be one this installation made - and rollback may
# only remove a group it can prove is its own.
readonly SINK_GROUP=_firstmate_sinkread
readonly ROLE_ACCOUNT_HOME=/var/empty

readonly BROKER_PROGRAM=fm-action-gateway-v2.py
readonly SINK_PROGRAM=fm-action-safe-sink-v2.py
readonly SINK_DATABASE=safe-sink-v2.sqlite3
readonly SINK_JOURNAL=safe-sink-v2.jsonl
readonly EXECUTOR_PROGRAM=fm-action-runner-v2.py
readonly IMPORTER_PROGRAM=fm-action-artifact-import-v2.py

readonly CONFIRM_FLAG=--i-have-read-every-line

usage() {
  sed -n '2,/^# This script writes only/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-gateway-install-v2: %s\n' "$1" >&2
  exit 1
}

# assert_fixed_path <label> <path> <minimum-depth>
#
# Refuses an empty, relative, unnormalized, or shallow constant. The depth floor
# is what stops a truncated constant from naming a shared ancestor: /usr/local
# has depth 2 and is refused where /usr/local/libexec/firstmate has depth 4.
assert_fixed_path() {
  local label=$1 path=$2 minimum=$3 depth
  [ -n "$path" ] || die "$label is empty"
  case "$path" in
    /*) ;;
    *) die "$label is not an absolute path: $path" ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/.|*/..) die "$label is not a normalized path: $path" ;;
  esac
  depth=$(printf '%s' "${path#/}" | awk -F/ '{print NF}')
  [ "$depth" -ge "$minimum" ] || die "$label is too shallow to be an install target: $path"
}

assert_constants() {
  assert_fixed_path STATE_PARENT "$STATE_PARENT" 3
  assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
  assert_fixed_path SINK_ROOT "$SINK_ROOT" 4
  assert_fixed_path SOCKET_PARENT "$SOCKET_PARENT" 3
  assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
  assert_fixed_path INSTALL_PARENT "$INSTALL_PARENT" 3
  assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
  assert_fixed_path QUARANTINE_PARENT "$QUARANTINE_PARENT" 3
  assert_fixed_path LAUNCH_DAEMONS "$LAUNCH_DAEMONS" 2
  assert_fixed_path BROKER_PLIST "$BROKER_PLIST" 3
  assert_fixed_path EXECUTOR_PLIST "$EXECUTOR_PLIST" 3
  case "$STATE_ROOT" in "$STATE_PARENT"/?*) ;; *) die "STATE_ROOT is not contained in STATE_PARENT" ;; esac
  case "$SINK_ROOT" in "$STATE_PARENT"/?*) ;; *) die "SINK_ROOT is not contained in STATE_PARENT" ;; esac
  [ "$SINK_ROOT" != "$STATE_ROOT" ] || die "SINK_ROOT must not be the broker state root"
  case "$SOCKET_ROOT" in "$SOCKET_PARENT"/?*) ;; *) die "SOCKET_ROOT is not contained in SOCKET_PARENT" ;; esac
  case "$INSTALL_ROOT" in "$INSTALL_PARENT"/?*) ;; *) die "INSTALL_ROOT is not contained in INSTALL_PARENT" ;; esac
  case "$BROKER_PLIST" in "$LAUNCH_DAEMONS"/?*) ;; *) die "BROKER_PLIST is not contained in LAUNCH_DAEMONS" ;; esac
  case "$EXECUTOR_PLIST" in "$LAUNCH_DAEMONS"/?*) ;; *) die "EXECUTOR_PLIST is not contained in LAUNCH_DAEMONS" ;; esac
  [ -n "$SINK_GROUP" ] || die "SINK_GROUP is empty"
  [ "$SINK_GROUP" != "$BROKER_USER" ] || die "SINK_GROUP must not be the broker account's own group name"
  [ "$SINK_GROUP" != "$EXECUTOR_USER" ] || die "SINK_GROUP must not be the executor account's own group name"
}

program_digest() {  # <program>
  local path="$ROOT/bin/$1"
  [ -f "$path" ] || die "missing program: bin/$1"
  /usr/bin/shasum -a 256 "$path" | awk '{print $1}'
}

launch_plist() {  # <label> <user> <program-path> <args...>
  local label=$1 user=$2 program=$3
  shift 3
  local argument
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0">'
  printf '%s\n' '<dict>'
  printf '  <key>Label</key><string>%s</string>\n' "$label"
  printf '%s\n' '  <key>ProgramArguments</key>'
  printf '%s\n' '  <array>'
  printf '    <string>%s</string>\n' /usr/bin/python3
  printf '    <string>%s</string>\n' "$program"
  for argument in "$@"; do
    printf '    <string>%s</string>\n' "$argument"
  done
  printf '%s\n' '  </array>'
  printf '  <key>UserName</key><string>%s</string>\n' "$user"
  printf '%s\n' '  <key>RunAtLoad</key><true/>'
  printf '%s\n' '  <key>KeepAlive</key><true/>'
  printf '%s\n' '  <key>ProcessType</key><string>Background</string>'
  printf '%s\n' '  <key>EnvironmentVariables</key>'
  printf '%s\n' '  <dict/>'
  printf '  <key>WorkingDirectory</key><string>%s</string>\n' /
  printf '%s\n' '  <key>SoftResourceLimits</key>'
  printf '%s\n' '  <dict><key>NumberOfFiles</key><integer>256</integer></dict>'
  printf '%s\n' '</dict>'
  printf '%s\n' '</plist>'
}

# The guard preamble both emitted scripts carry. They are run standalone by a
# person with sudo, so each one has to validate its own paths rather than trust
# that this authoring script validated them.
emit_guard_preamble() {
  cat <<'GUARD'
set -eu

if [ "${1:-}" != "--i-have-read-every-line" ]; then
  printf 'refusing to run without %s.\n' "--i-have-read-every-line" >&2
  printf 'Read every line of this file first. It runs privileged commands.\n' >&2
  exit 3
fi

# assert_fixed_path <label> <path> <minimum-depth>: refuse an empty, relative,
# unnormalized, or shallow path before it is ever handed to a command.
assert_fixed_path() {
  label=$1; path=$2; minimum=$3
  [ -n "$path" ] || { printf 'refusing: %s is empty\n' "$label" >&2; exit 1; }
  case "$path" in
    /*) ;;
    *) printf 'refusing: %s is not absolute: %s\n' "$label" "$path" >&2; exit 1 ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/.|*/..)
      printf 'refusing: %s is not normalized: %s\n' "$label" "$path" >&2; exit 1 ;;
  esac
  depth=$(printf '%s' "${path#/}" | awk -F/ '{print NF}')
  [ "$depth" -ge "$minimum" ] || {
    printf 'refusing: %s is too shallow: %s\n' "$label" "$path" >&2; exit 1; }
}

# assert_contained <child> <parent>: refuse a path that is not strictly inside
# the parent it is supposed to live in.
assert_contained() {
  case "$1" in
    "$2"/?*) ;;
    *) printf 'refusing: %s is not contained in %s\n' "$1" "$2" >&2; exit 1 ;;
  esac
}

# assert_not_symlink <path>: a symlinked install target redirects every later
# write, so it is refused rather than followed.
assert_not_symlink() {
  [ ! -L "$1" ] || { printf 'refusing: %s is a symlink\n' "$1" >&2; exit 1; }
}

# assert_owner <path> <expected-owner>: refuse to touch a path some other owner
# put there under a name this install expects.
assert_owner() {
  observed=$(/usr/bin/stat -f '%Su' "$1" 2>/dev/null || printf 'unknown')
  [ "$observed" = "$2" ] || {
    printf 'refusing: %s is owned by %s, expected %s\n' "$1" "$observed" "$2" >&2
    exit 1; }
}
GUARD
}

emit_install_script() {
  emit_guard_preamble
  cat <<CMD

assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
assert_fixed_path SINK_ROOT "$SINK_ROOT" 4
assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
assert_contained "$INSTALL_ROOT" "$INSTALL_PARENT"
assert_contained "$STATE_ROOT" "$STATE_PARENT"
assert_contained "$SINK_ROOT" "$STATE_PARENT"
assert_contained "$SOCKET_ROOT" "$SOCKET_PARENT"

# 1. Create the two service principals. They are distinct accounts, not one
#    account with two names: the whole privilege separation rests on the
#    executor being unable to read the broker's state directory, and on the
#    broker being unable to write the executor's receipt store. An ordinary
#    worker is neither account and gets neither.
sudo sysadminctl -addUser "$BROKER_USER" -home "$ROLE_ACCOUNT_HOME" -shell /usr/bin/false -roleAccount
sudo sysadminctl -addUser "$EXECUTOR_USER" -home "$ROLE_ACCOUNT_HOME" -shell /usr/bin/false -roleAccount

# 2. Create the dedicated read group. Its name belongs to nothing else on the
#    system - neither role account is called this - so its presence is evidence
#    this installation created it, which is what lets rollback prove ownership
#    before it removes anything. Membership in it is the broker's entire access
#    to the executor's receipt store: group read, and no write anywhere. Both
#    steps check first, so re-running this install after a partial one does not
#    abort on a group or a membership that is already there.
if ! dseditgroup -o read "$SINK_GROUP" >/dev/null 2>&1; then
  sudo dseditgroup -o create -r "Firstmate safe sink receipt readers" "$SINK_GROUP"
fi
if ! dseditgroup -o checkmember -m "$BROKER_USER" "$SINK_GROUP" >/dev/null 2>&1; then
  sudo dseditgroup -o edit -a "$BROKER_USER" -t user "$SINK_GROUP"
fi

# 3. Install the programs root-owned and not writable by either service account.
sudo /usr/bin/install -d -o root -g wheel -m 0755 "$INSTALL_ROOT"
sudo /usr/bin/install -o root -g wheel -m 0755 "$ROOT/bin/$BROKER_PROGRAM" "$INSTALL_ROOT/$BROKER_PROGRAM"
sudo /usr/bin/install -o root -g wheel -m 0755 "$ROOT/bin/$SINK_PROGRAM" "$INSTALL_ROOT/$SINK_PROGRAM"
sudo /usr/bin/install -o root -g wheel -m 0755 "$ROOT/bin/$EXECUTOR_PROGRAM" "$INSTALL_ROOT/$EXECUTOR_PROGRAM"
sudo /usr/bin/install -o root -g wheel -m 0755 "$ROOT/bin/$IMPORTER_PROGRAM" "$INSTALL_ROOT/$IMPORTER_PROGRAM"

# 4. Create the state, receipt, and socket roots. Every ancestor is root-owned.
#    The broker root is the broker's alone and the executor has no access to it
#    at all. The receipt store is the executor's; the broker reads it through
#    group membership and can write nothing in it.
sudo /usr/bin/install -d -o root -g wheel -m 0755 "$STATE_PARENT"
sudo /usr/bin/install -d -o "$BROKER_USER" -g wheel -m 0700 "$STATE_ROOT"
#    2750, not 0750: the setgid bit is what makes every receipt file inherit
#    the broker's group instead of whichever group the executor happens to
#    have, so the broker's read access is guaranteed by the operating system
#    rather than by a platform convention.
sudo /usr/bin/install -d -o "$EXECUTOR_USER" -g "$SINK_GROUP" -m 2750 "$SINK_ROOT"
sudo /usr/bin/install -d -o root -g wheel -m 0755 "$SOCKET_PARENT"
sudo /usr/bin/install -d -o "$BROKER_USER" -g wheel -m 0755 "$SOCKET_ROOT"

# 5. Install the launch definition and start the broker.
sudo /usr/bin/install -o root -g wheel -m 0644 "./$BROKER_LABEL.plist" "$BROKER_PLIST"
sudo launchctl bootstrap system "$BROKER_PLIST"

# 6. Enroll the approval signer. This is the step that decides how much an
#    approval proves, and it is the captain's alone: the key is generated in the
#    Secure Enclave by the signing UI and never leaves it, so only its public
#    half is enrolled here. There is no fallback - if this step is skipped, the
#    gateway refuses every approval rather than accepting a weaker one.
sudo -u "$BROKER_USER" "$INSTALL_ROOT/$BROKER_PROGRAM" enroll-approver \\
  --approver-id captain-ui --algorithm ecdsa-p256-sha256 \\
  --key-material "<base64 DER public key exported by the signing UI>" \\
  --attestation-ref "<path to the Secure Enclave attestation the UI produced>"
CMD
}

emit_uninstall_script() {
  emit_guard_preamble
  cat <<CMD

# Uninstall quarantines; it never deletes a directory tree. Each step validates
# its own target first, and a directory is moved aside under a timestamp rather
# than removed, so an uninstall can never destroy the audit record or take a
# neighbouring path with it. Removing the quarantine afterwards is a separate
# decision, made by a person looking at what is in it.

STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
QUARANTINE=$QUARANTINE_PARENT/uninstalled-\$STAMP

assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
assert_fixed_path SINK_ROOT "$SINK_ROOT" 4
assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
assert_fixed_path BROKER_PLIST "$BROKER_PLIST" 3
assert_fixed_path EXECUTOR_PLIST "$EXECUTOR_PLIST" 3
assert_fixed_path QUARANTINE "\$QUARANTINE" 4
assert_contained "$INSTALL_ROOT" "$INSTALL_PARENT"
assert_contained "$STATE_ROOT" "$STATE_PARENT"
assert_contained "$SINK_ROOT" "$STATE_PARENT"
assert_contained "$SOCKET_ROOT" "$SOCKET_PARENT"
assert_contained "\$QUARANTINE" "$QUARANTINE_PARENT"
assert_contained "$BROKER_PLIST" "$LAUNCH_DAEMONS"
assert_contained "$EXECUTOR_PLIST" "$LAUNCH_DAEMONS"

# 1. Stop the service before touching anything it holds open.
sudo launchctl bootout system/$BROKER_LABEL || true

# 2. Remove the two launch definitions. Exact literal file paths, checked for
#    being real files rather than symlinks, removed one at a time with rm -f.
#    No wildcard and no recursion appear anywhere in this step.
for plist in "$BROKER_PLIST" "$EXECUTOR_PLIST"; do
  [ -e "\$plist" ] || continue
  assert_not_symlink "\$plist"
  [ -f "\$plist" ] || { printf 'refusing: %s is not a regular file\\n' "\$plist" >&2; exit 1; }
  assert_owner "\$plist" root
  sudo rm -f -- "\$plist"
done

# 3. Quarantine the four directories. mv, never a recursive delete: the state
#    root holds the audit record and every tombstone, the receipt store holds
#    the evidence every settlement was read from, and an uninstall that destroys
#    either is worse than one that leaves a directory behind. Each target is
#    checked to be a real directory owned by the account this install gave it
#    to, so a directory some other owner put there under a name this install
#    expects is refused rather than moved.
sudo /usr/bin/install -d -o root -g wheel -m 0700 "\$QUARANTINE"
for entry in "$SOCKET_ROOT|$BROKER_USER" "$INSTALL_ROOT|root" "$STATE_ROOT|$BROKER_USER" "$SINK_ROOT|$EXECUTOR_USER"; do
  target=\${entry%|*}
  expected=\${entry##*|}
  [ -e "\$target" ] || continue
  assert_not_symlink "\$target"
  [ -d "\$target" ] || { printf 'refusing: %s is not a directory\\n' "\$target" >&2; exit 1; }
  assert_owner "\$target" "\$expected"
  sudo mv -- "\$target" "\$QUARANTINE/\$(basename "\$target")"
done

# 4. Judge the dedicated group BEFORE the accounts are removed, while their
#    names and UUIDs still resolve. Nothing is changed in this step; it only
#    decides. Membership that cannot be positively read is AMBIGUOUS, which is
#    a refusal: "no members were found" is never inferred from "the output could
#    not be parsed".
#
#    dscl prints one attribute as "Name: value value", continuing onto indented
#    lines, and prints "No such key" when the attribute is absent. Anything else
#    is a shape this script does not understand, and it says so rather than
#    guessing.
dscl_values() {  # <record> <attribute>; prints values, returns 1 when unparseable
  raw=\$(dscl . -read "\$1" "\$2" 2>&1) || return 1
  case "\$raw" in
    'No such key'*) return 0 ;;
    "\$2:") return 0 ;;
    "\$2: "*) printf '%s\\n' "\$raw" | sed -e "1s/^\$2: //" -e 's/^[[:space:]]*//' ;;
    *) return 1 ;;
  esac
}

GROUP_VERDICT=ambiguous
GROUP_DETAIL='its membership could not be read'
GROUP_UNEXPECTED=
if ! dscl . -read "/Groups/$SINK_GROUP" RecordName >/dev/null 2>&1; then
  GROUP_VERDICT=absent
  GROUP_DETAIL='it is not present'
else
  GROUP_AMBIGUOUS=
  if ! GROUP_NAMES=\$(dscl_values "/Groups/$SINK_GROUP" GroupMembership); then
    GROUP_AMBIGUOUS='its GroupMembership attribute is not in a shape this script can read'
  fi
  if ! GROUP_UUIDS=\$(dscl_values "/Groups/$SINK_GROUP" GroupMembers); then
    GROUP_AMBIGUOUS='its GroupMembers attribute is not in a shape this script can read'
  fi
  GROUP_GID=\$(dscl_values "/Groups/$SINK_GROUP" PrimaryGroupID) || GROUP_GID=
  for member in \$GROUP_NAMES; do
    case "\$member" in
      "$BROKER_USER"|"$EXECUTOR_USER") ;;
      *) GROUP_UNEXPECTED="\$GROUP_UNEXPECTED \$member" ;;
    esac
  done
  # A UUID member is only accounted for when it resolves to one of the two role
  # accounts. One that resolves to nothing is a member this script cannot name,
  # which is exactly the ambiguity that must refuse.
  for uuid in \$GROUP_UUIDS; do
    owner=\$(dscl . -search /Users GeneratedUID "\$uuid" 2>/dev/null | awk 'NR == 1 { print \$1; exit }') || owner=
    case "\$owner" in
      "$BROKER_USER"|"$EXECUTOR_USER") ;;
      '') GROUP_AMBIGUOUS="one of its member UUIDs (\$uuid) resolves to no account this uninstall created" ;;
      *) GROUP_UNEXPECTED="\$GROUP_UNEXPECTED \$owner" ;;
    esac
  done
  # Anyone whose primary group is this one is a member without appearing in
  # either attribute.
  if [ -z "\$GROUP_GID" ]; then
    GROUP_AMBIGUOUS='its gid could not be read, so primary-group members cannot be ruled out'
  else
    for holder in \$(dscl . -list /Users PrimaryGroupID 2>/dev/null | awk -v gid="\$GROUP_GID" '\$2 == gid { print \$1 }'); do
      case "\$holder" in
        "$BROKER_USER"|"$EXECUTOR_USER") ;;
        *) GROUP_UNEXPECTED="\$GROUP_UNEXPECTED \$holder" ;;
      esac
    done
  fi
  if [ -n "\$GROUP_AMBIGUOUS" ]; then
    GROUP_VERDICT=ambiguous
    GROUP_DETAIL="\$GROUP_AMBIGUOUS"
  elif [ -n "\$GROUP_UNEXPECTED" ]; then
    GROUP_VERDICT=in-use
    GROUP_DETAIL="it still has members:\$GROUP_UNEXPECTED"
  else
    GROUP_VERDICT=ours
    GROUP_DETAIL='it has no member this uninstall is not already removing'
  fi
fi

# 5. Remove the service principals, so the quarantined state is never briefly
#    ownerless. Each account is checked to be the role account this install
#    created before it is deleted.
for account in "$EXECUTOR_USER" "$BROKER_USER"; do
  home=\$(dscl . -read /Users/"\$account" NFSHomeDirectory 2>/dev/null | awk '{print \$2}') || home=
  [ -n "\$home" ] || continue
  [ "\$home" = "$ROLE_ACCOUNT_HOME" ] || {
    printf 'refusing: %s has home %s, not the role-account home %s\\n' "\$account" "\$home" "$ROLE_ACCOUNT_HOME" >&2
    exit 1; }
  sudo sysadminctl -deleteUser "\$account"
done

# 6. Act on the verdict from step 4. Only a group positively read as having no
#    member beyond the accounts just removed is deleted. Absent, ambiguous, or
#    in use: it is left exactly as it is and reported. This is the directory
#    rule again - prove it is ours, or refuse and say so.
GROUP_REMNANT=no
case "\$GROUP_VERDICT" in
  ours)
    sudo dseditgroup -o delete "$SINK_GROUP"
    ;;
  absent)
    printf 'group %s: %s. Nothing to remove.\\n' "$SINK_GROUP" "\$GROUP_DETAIL"
    ;;
  *)
    printf 'REFUSING to remove the group %s: %s\\n' "$SINK_GROUP" "\$GROUP_DETAIL" >&2
    printf 'Nothing about that group was changed. Find out what uses it first.\\n' >&2
    GROUP_REMNANT=yes
    ;;
esac

printf 'Uninstalled. The previous state is quarantined at %s.\\n' "\$QUARANTINE"
printf 'Nothing was deleted recursively. Review that directory, then remove it\\n'
printf 'yourself once you are satisfied the audit record is no longer needed.\\n'
if [ "\$GROUP_REMNANT" = yes ]; then
  printf 'One privileged remnant is left on purpose: the group %s, which could not\\n' "$SINK_GROUP"
  printf 'be proved to be this installation'"'"'s own. It is still there.\\n'
fi
CMD
}

emit_preview() {
  cat <<TXT
Action gateway v2 activation preview
====================================

NOTHING BELOW HAS BEEN DONE. This is what installation would do, printed so it
can be reviewed before anyone runs it.

Principals
  broker    $BROKER_USER   owns $STATE_ROOT, serves the three sockets
  executor  $EXECUTOR_USER  the execution socket's peer: it holds one per-job
            execution capability, runs the bound immutable executor code, owns
            $SINK_ROOT, and cannot read the broker root at all
  The separation is the security property. One account for both would make the
  executor able to read every capability hash and every approval in the database,
  which is exactly what the execution socket exists to avoid.
  An ordinary worker is neither of these accounts. Anything that calls prepare
  never receives the executor identity and never receives write access to the
  receipt store, so a worker cannot author the evidence its own action is
  settled from.

  group   $SINK_GROUP  the broker's read access to the receipt store, and
          nothing else. Its name is deliberately neither account's: a role
          account's auto-created group cannot be told apart from one this
          installation made, and rollback removes only a group it can prove is
          its own.

Receipt store, and why the broker only reads it
  $SINK_ROOT is $EXECUTOR_USER:$SINK_GROUP 2750, and the files in it are 0640.
  The setgid bit is deliberate: the operating system then gives every receipt
  file the read group, so the broker's read access does not rest on which group
  the executor happens to create files with. The sink refuses to write a store
  whose directory is not setgid, and refuses any file in it whose group or mode
  is not what that read-only path needs. Setting that bit is this installation's
  job: chmod may report success and drop setgid for a caller that is neither
  privileged nor a member of the directory's group, so the sink reads the bit
  back and names that cause rather than trusting a clean return.
  The broker's entire access is group read; it has no write path to that store
  anywhere in its code, which is what makes a receipt evidence rather than
  something the broker could have authored. The store is journal_mode=TRUNCATE
  for the same reason: a WAL reader has to create the -shm wal-index beside the
  database, and a reader with no write access to that directory is refused
  outright.

Programs, with the bytes that would be installed
  $BROKER_PROGRAM          $(program_digest "$BROKER_PROGRAM")
  $SINK_PROGRAM        $(program_digest "$SINK_PROGRAM")
  $EXECUTOR_PROGRAM           $(program_digest "$EXECUTOR_PROGRAM")
  $IMPORTER_PROGRAM  $(program_digest "$IMPORTER_PROGRAM")
  The safe sink's digest is bound into every resolved plan. Replacing that file
  after an approval invalidates the approval instead of silently running the new
  bytes under the old consent.

Paths, owners, modes
  $INSTALL_ROOT   root:wheel 0755
  $STATE_ROOT      $BROKER_USER:wheel 0700
  $SINK_ROOT         $EXECUTOR_USER:$SINK_GROUP 2750 setgid, each file 0640
  $SOCKET_ROOT     $BROKER_USER:wheel 0755, each socket 0600
  $BROKER_PLIST   root:wheel 0644

Install commands, in order
$(emit_install_script)

Uninstall
  Run the rollback-preview command for the guarded uninstall script. It quarantines by
  moving directories under a timestamp and never deletes a tree, so it cannot
  destroy the audit record or take a neighbouring path with it. It removes
  $SINK_GROUP only when it can positively read that group's membership and find
  nothing in it beyond the two role accounts it is removing; a group in use, or
  one whose membership it cannot read, is left in place and reported.

What is still unproven after all of that
  Installing these definitions does not by itself prove distinct principals,
  root-owned ancestors, Secure Enclave enrollment, signed UI identity, or network
  isolation. Those are measured by bin/fm-worker-boundary-regression.sh against a
  real installation, and until that pack runs green on the installed paths, the
  honest statement is that they are planned and unverified.

Outward execution after installation
  Still none. The only executor this gateway will claim for is the deterministic
  safe sink, which appends one local record. An outward executor is a separate
  authorized change, not a consequence of installing this.
TXT
}

report_path() {  # <path> <kind>
  local path=$1 kind=$2 owner mode
  if { [ "$kind" = directory ] && [ -d "$path" ]; } || { [ "$kind" = file ] && [ -f "$path" ]; }; then
    owner=$(/usr/bin/stat -f '%Su:%Sg' "$path" 2>/dev/null || printf 'unknown')
    # %Mp%Lp, not %Lp: the setgid bit on the receipt store is the whole reason
    # the broker can read it, and a report that hides it hides the failure.
    mode=$(/usr/bin/stat -f '%Mp%Lp' "$path" 2>/dev/null || printf '????')
    printf 'present  %s  owner=%s mode=%s\n' "$path" "$owner" "$mode"
    return 0
  fi
  printf 'absent   %s\n' "$path"
  return 1
}

emit_check() {
  local complete=0 entry path kind
  printf 'Action gateway v2 installation check\n'
  printf '====================================\n\n'
  for entry in \
    "$INSTALL_ROOT|directory" \
    "$INSTALL_ROOT/$BROKER_PROGRAM|file" \
    "$INSTALL_ROOT/$SINK_PROGRAM|file" \
    "$INSTALL_ROOT/$EXECUTOR_PROGRAM|file" \
    "$INSTALL_ROOT/$IMPORTER_PROGRAM|file" \
    "$STATE_ROOT|directory" \
    "$SINK_ROOT|directory" \
    "$SOCKET_ROOT|directory" \
    "$BROKER_PLIST|file"; do
    path=${entry%|*}
    kind=${entry##*|}
    report_path "$path" "$kind" || complete=1
  done
  printf '\n'
  # The receipt store's own files, reported separately because the sink creates
  # them on its first apply rather than at installation. Their owner, group and
  # mode are what the broker's read-only settlement path actually depends on, so
  # reporting only the directory above would hide the thing that matters.
  printf 'Receipt store files, created by the first execution rather than by installation\n'
  printf '  each must be %s:%s mode 640, and no -wal or -shm file may exist at all\n' \
    "$EXECUTOR_USER" "$SINK_GROUP"
  for entry in \
    "$SINK_ROOT/$SINK_DATABASE|file" \
    "$SINK_ROOT/$SINK_JOURNAL|file" \
    "$SINK_ROOT/$SINK_DATABASE-journal|file" \
    "$SINK_ROOT/$SINK_DATABASE-wal|file" \
    "$SINK_ROOT/$SINK_DATABASE-shm|file"; do
    path=${entry%|*}
    kind=${entry##*|}
    [ -e "$path" ] || continue
    report_path "$path" "$kind" || true
  done
  printf '\n'
  if [ "$complete" -eq 0 ]; then
    printf 'Every installed path is present. Run bin/fm-worker-boundary-regression.sh\n'
    printf 'against these paths before treating the boundary as enforced: present is\n'
    printf 'not the same as proved.\n'
    return 0
  fi
  printf 'The gateway is NOT installed. Nothing above was created by this script,\n'
  printf 'and this script will not create it. Run the preview command to see what a\n'
  printf 'captain-run installation would do.\n'
  return 3
}

write_artifacts() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || die "artifacts requires a directory"
  case "$dir" in
    -*) die "artifact directory must not start with a dash: $dir" ;;
  esac
  [ ! -L "$dir" ] || die "artifact directory is a symlink: $dir"
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "artifact path exists and is not a directory: $dir"
    [ -z "$(ls -A "$dir" 2>/dev/null)" ] || die "artifact directory must be empty: $dir"
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  launch_plist "$BROKER_LABEL" "$BROKER_USER" "$INSTALL_ROOT/$BROKER_PROGRAM" serve > "$dir/$BROKER_LABEL.plist"
  {
    printf '#!/bin/sh\n'
    printf '# Action gateway v2 install. Review every line before running any of it.\n'
    printf '# This file is an artifact for the captain to read. No agent runs it.\n'
    emit_install_script
  } > "$dir/install.sh"
  {
    printf '#!/bin/sh\n'
    printf '# Read-only. Reports what is installed; changes nothing.\n'
    printf 'set -eu\n'
    printf 'exec "%s" check\n' "$ROOT/bin/fm-gateway-install-v2.sh"
  } > "$dir/check.sh"
  {
    printf '#!/bin/sh\n'
    printf '# Action gateway v2 uninstall. Review every line before running any of it.\n'
    printf '# It quarantines directories by moving them; it deletes no tree.\n'
    emit_uninstall_script
  } > "$dir/uninstall.sh"
  # Deliberately not executable. These are review artifacts, and making them
  # runnable is one keystroke away from running them by accident. Each also
  # refuses to run without its explicit confirmation flag.
  chmod 0644 "$dir/$BROKER_LABEL.plist" "$dir/install.sh" "$dir/check.sh" "$dir/uninstall.sh"
  printf 'wrote %s\n' "$dir/$BROKER_LABEL.plist"
  printf 'wrote %s\n' "$dir/install.sh"
  printf 'wrote %s\n' "$dir/check.sh"
  printf 'wrote %s\n' "$dir/uninstall.sh"
  printf '\nNone of these is executable, none has been run, and install.sh and\n'
  printf 'uninstall.sh both refuse to run without %s.\n' "$CONFIRM_FLAG"
}

main() {
  assert_constants
  case "${1:-}" in
    preview)
      emit_preview
      ;;
    check)
      emit_check
      ;;
    artifacts)
      write_artifacts "${2:-}"
      ;;
    rollback-preview)
      printf 'Action gateway v2 uninstall preview\n'
      printf '===================================\n\n'
      printf 'NOTHING BELOW HAS BEEN DONE. Uninstall quarantines by moving directories\n'
      printf 'under a timestamp; it deletes no directory tree.\n\n'
      emit_uninstall_script
      ;;
    apply)
      printf 'fm-gateway-install-v2: refusing to install.\n' >&2
      printf 'Creating service accounts, writing root-owned paths, loading launch\n' >&2
      printf 'definitions, and enrolling an approver key are the captain'"'"'s own step\n' >&2
      printf 'at the Mac. Run the preview command for exactly what to do, or artifacts DIR\n' >&2
      printf 'for the files to review first.\n' >&2
      exit 3
      ;;
    -h|--help|help|'')
      usage
      ;;
    *)
      die "unknown command: $1"
      ;;
  esac
}

main "$@"

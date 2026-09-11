#!/usr/bin/env bash
# Behavior tests for bin/fm-timeout-lib.sh, the bounded read-only probe helper.
#
# The property under test is that a bounded probe still returns the command's
# output when a TERMINAL is attached to the caller.
# Every bound in the helper runs the command in its own process group so a
# timeout can kill the group, which also moves it out of the terminal's
# foreground process group.
# A probed CLI that touches the terminal then takes SIGTTOU and stops until the
# bound kills it, so the caller reads an empty answer from a healthy tool.
# That failure is invisible without a terminal, which is why it reached a
# release: it refused `firstmate claude` at its account seat check while every
# non-interactive caller and test saw the same probe pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

# A probe that touches the terminal before answering, the way a real CLI does
# when it inspects or configures the tty it was started from.
PROBE="$TMP_ROOT/probe.sh"
cat > "$PROBE" <<'PROBE_EOF'
stty -echo 2>/dev/null || true
printf 'PROBE-OK\n'
PROBE_EOF

# Run <shell-command> under a real pseudo-terminal and echo everything it wrote.
PTY="$TMP_ROOT/ptyrun.py"
cat > "$PTY" <<'PTY_EOF'
import os, pty, select, sys, time

deadline = time.time() + 60
pid, fd = pty.fork()
if pid == 0:
    os.execvp("/bin/bash", ["/bin/bash", "-c", sys.argv[1]])

chunks = []

def read_ready(wait):
    ready, _, _ = select.select([fd], [], [], wait)
    if not ready:
        return True
    try:
        data = os.read(fd, 65536)
    except OSError:
        return False
    if not data:
        return False
    chunks.append(data)
    return True

exited = False
while time.time() < deadline:
    if not read_ready(0.5):
        break
    if os.waitpid(pid, os.WNOHANG)[0]:
        exited = True
        break

if exited:
    while time.time() < deadline and read_ready(0.2):
        pass
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
PTY_EOF

# Host-capability gate: python3 drives the pseudo-terminal that makes this
# bug visible at all, so without it the property cannot be exercised here.
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

run_under_pty() {  # <shell-command>
  python3 "$PTY" "$1"
}

probe_command() {
  # The single quotes are deliberate: this builds a shell snippet for the
  # pty child to expand, so nothing here may expand in this shell.
  # shellcheck disable=SC2016
  printf '. %s/bin/fm-timeout-lib.sh; out=$(fm_run_timeout 5 bash %s); rc=$?; printf "OUT=[%%s] RC=%%s\\n" "$out" "$rc"' \
    "$ROOT" "$PROBE"
}

# --- 1. terminal-attached probe still answers -------------------------------
out=$(run_under_pty "$(probe_command)")
assert_contains "$out" 'OUT=[PROBE-OK] RC=0' \
  'a bounded probe under a terminal must return the command output, not an empty answer'

# --- 2. same guarantee on the perl fallback ---------------------------------
# Force the branch a stock macOS box without coreutils takes, by handing the
# helper a PATH that has no timeout(1) or gtimeout(1) at all.
MINBIN="$TMP_ROOT/minbin"
mkdir -p "$MINBIN"
for tool in perl bash stty sleep; do
  resolved=$(command -v "$tool") || fail "test prerequisite missing: $tool"
  ln -s "$resolved" "$MINBIN/$tool"
done

fallback_out=$(run_under_pty "PATH=$MINBIN; export PATH; if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then printf 'LEAKED-TIMEOUT\\n'; exit 99; fi; $(probe_command)")
assert_not_contains "$fallback_out" 'LEAKED-TIMEOUT' \
  'the minimal PATH must resolve neither timeout nor gtimeout, or case 2 is not testing the perl fallback'
assert_contains "$fallback_out" 'OUT=[PROBE-OK] RC=0' \
  'the perl fallback must also return the command output under a terminal'

# --- 3. the bound still fires ------------------------------------------------
. "$ROOT/bin/fm-timeout-lib.sh"
fm_run_timeout 1 sleep 5 >/dev/null 2>&1
expect_code 124 "$?" 'a command that outruns its bound must report the GNU timeout code'

# --- 4. exit status passes through -------------------------------------------
fm_run_timeout 5 sh -c 'exit 7' >/dev/null 2>&1
expect_code 7 "$?" 'a command that finishes inside its bound must report its own exit status'

pass 'fm-timeout-lib bounds probes without stealing their answer'

# shellcheck shell=bash
# Shared portable wall-clock timeout for bounded read-only probes.
# Usage: . bin/fm-timeout-lib.sh
#
# fm_run_timeout <secs> <cmd...> runs <cmd...> under a <secs> wall-clock bound,
# passing its stdout and stderr straight through. Exit status is the command's,
# or 124 on timeout (the GNU timeout convention).
#
# STDIN IS ALWAYS /dev/null, and that is load-bearing rather than tidiness.
# Every bound below runs the command in its own process group so a timeout can
# kill the whole group, which also moves that command out of the terminal's
# foreground process group.
# A probed CLI that touches the terminal on stdin then takes SIGTTIN or SIGTTOU
# and stops until the bound kills it, so the caller reads an EMPTY answer from a
# perfectly healthy tool - but only when a terminal is attached, which is why
# every non-interactive caller and test saw the probe pass.
# That is what refused `firstmate claude` at its account seat check: the seat
# proof read nothing and the launcher concluded it could not prove the seat.
# Detaching stdin removes the terminal from the child entirely and keeps the
# group-kill semantics that bound runaway children.
# Every caller here is a read-only probe, so none of them has stdin to pass
# through; bin/fm-toolchain-lib.sh carried this same redirect at its own call
# site until the helper took ownership of it here.
#
# Portability: prefers timeout(1), then gtimeout(1), then a perl fallback that
# runs the child in its own process group and kills the group on alarm, so a
# stock macOS box with neither coreutils binary is still bounded.
#
# This is the one owner of that helper. Callers that need a bounded probe source
# this file rather than open-coding a second background-wait loop.

fm_run_timeout() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" </dev/null
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@" </dev/null
    return $?
  fi
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$secs" "$@" </dev/null
}

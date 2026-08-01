# shellcheck shell=bash
# Shared portable wall-clock timeout for bounded read-only probes.
# Usage: . bin/fm-timeout-lib.sh
#
# fm_run_timeout <secs> <cmd...> runs <cmd...> under a <secs> wall-clock bound,
# passing its stdout and stderr straight through. Exit status is the command's,
# or 124 on timeout (the GNU timeout convention).
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
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
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
  ' "$secs" "$@"
}

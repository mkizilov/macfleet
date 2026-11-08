# Helpers that keep a step from hanging. Source this file; it defines functions only.

# Runs a command and stops it when SECONDS have passed. It uses perl's alarm, which every macOS install includes. The alarm
# survives exec, so the command keeps its own pid and exit status. An expired limit returns 142 (SIGALRM) and names the
# command on standard error. The caller's errexit setting is kept as it was.
# Usage: run_bounded SECONDS COMMAND [ARGS...]
run_bounded() {
  limit=$1
  shift
  case $- in
    *e*) bounded_errexit=1 ;;
    *) bounded_errexit=0 ;;
  esac
  set +e
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" "$@"
  bounded_status=$?
  if [ "$bounded_errexit" -eq 1 ]; then
    set -e
  fi
  if [ "$bounded_status" -eq 142 ]; then
    echo "timed out: '$1' was still running after ${limit}s and was stopped" >&2
  fi
  return "$bounded_status"
}

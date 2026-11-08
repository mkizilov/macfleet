#!/bin/sh
# Removes what scripts/install-agent.sh installed, as listed in its manifest. The configuration, the pinned identity, the
# client secrets, and the logs are kept unless you ask for them to be removed. Nothing is removed without --apply.
# docs/installation.md has the full steps.
#
#   scripts/uninstall-agent.sh [options]
#
#   --prefix DIR           the prefix the agent was installed under (default: $HOME/Library/Application Support/MacFleet)
#   --launch-agents DIR    where the launchd definition was installed (default: $HOME/Library/LaunchAgents)
#   --apply                remove the files. Without it the script prints what it would remove.
#   --unload               stop the agent with launchctl first. Needs --apply.
#   --purge-config         also remove the configuration directory. The secrets it names are not touched.
#   --purge-logs           also remove the log directory.
#
# Exit codes: 0 done (or planned), 2 usage error or nothing installed.
set -eu

LABEL=com.macfleet.headless
PREFIX="$HOME/Library/Application Support/MacFleet"
AGENTS="$HOME/Library/LaunchAgents"
APPLY=0
UNLOAD=0
PURGE_CONFIG=0
PURGE_LOGS=0

die() {
  echo "uninstall-agent: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift 2 ;;
    --launch-agents) [ $# -ge 2 ] || die "--launch-agents needs a directory"; AGENTS=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --unload) UNLOAD=1; shift ;;
    --purge-config) PURGE_CONFIG=1; shift ;;
    --purge-logs) PURGE_LOGS=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$UNLOAD" -eq 0 ] || [ "$APPLY" -eq 1 ] || die "--unload needs --apply"
[ "$(id -u)" -ne 0 ] || die "do not run this as root. The agent belongs to your user account."

MANIFEST="$PREFIX/install-manifest.txt"
[ -f "$MANIFEST" ] || die "no install manifest at $MANIFEST. Nothing installed by install-agent.sh to remove."

manifest_value() {
  sed -n "s/^$1=//p" "$MANIFEST" | head -n 1
}

BINARY=$(manifest_value binary)
CONFIG=$(manifest_value config)
LAUNCH_AGENT=$(manifest_value launch_agent)
LOGS=$(manifest_value log_directory)

# A manifest is trusted only for absolute paths. Anything else would be a path we did not install.
for path in "$BINARY" "$CONFIG" "$LAUNCH_AGENT" "$LOGS"; do
  case "$path" in
    /*) ;;
    *) die "the manifest names a path that is not absolute: '$path'" ;;
  esac
done
[ "$LAUNCH_AGENT" = "$AGENTS/$LABEL.plist" ] || echo "uninstall-agent: note: the launchd definition is at $LAUNCH_AGENT, not $AGENTS" >&2

# The configuration is removed only when this installer created it. A configuration that was already in place stays, even
# with --purge-config, because the operator put it there.
CONFIG_CREATED_BY_INSTALL=$(manifest_value config_created_by_install)
if [ "$PURGE_CONFIG" -eq 1 ] && [ "$CONFIG_CREATED_BY_INSTALL" != "yes" ]; then
  echo "uninstall-agent: keeping $CONFIG: the installer did not create it" >&2
  PURGE_CONFIG=0
fi

# The logs directory is removed only when it is the MacFleet log directory. A damaged manifest must not reach further.
if [ "$PURGE_LOGS" -eq 1 ]; then
  case "$LOGS" in
    */MacFleet|*/MacFleet/) ;;
    *) die "refusing to remove $LOGS: the logs directory must be a MacFleet directory" ;;
  esac
fi

echo "removing the MacFleet headless agent installed under $PREFIX"
echo "remove:  $BINARY"
echo "remove:  $LAUNCH_AGENT"
echo "remove:  $MANIFEST"
if [ "$PURGE_CONFIG" -eq 1 ]; then
  echo "remove:  $CONFIG (and its directory)"
else
  echo "keep:    $CONFIG (pinned identity, client secrets, configuration). Add --purge-config to remove it."
fi
if [ "$PURGE_LOGS" -eq 1 ]; then
  echo "remove:  $LOGS"
else
  echo "keep:    $LOGS (logs). Add --purge-logs to remove them."
fi

if [ "$APPLY" -eq 0 ]; then
  echo "dry run: nothing was removed. Re-run with --apply to remove the files above."
  exit 0
fi

if [ "$UNLOAD" -eq 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
  echo "stopped $LABEL"
fi

rm -f "$BINARY" "$LAUNCH_AGENT" "$MANIFEST"
rmdir "$PREFIX/bin" 2> /dev/null || true
if [ "$PURGE_CONFIG" -eq 1 ]; then
  rm -f "$CONFIG"
  rmdir "$(dirname "$CONFIG")" 2> /dev/null || true
fi
if [ "$PURGE_LOGS" -eq 1 ]; then
  rm -rf "$LOGS"
fi
rmdir "$PREFIX" 2> /dev/null || true
echo "removed. Anything listed as kept is still on disk."

#!/bin/sh
# Installs the MacFleet headless agent for the current user: its binary, its configuration, and a launchd agent definition.
# It never runs as root and needs no credential. It writes nothing unless --apply is given, and it loads the agent only when
# --load is also given. docs/installation.md has the full steps.
#
#   scripts/install-agent.sh --binary PATH --config PATH [options]
#
#   --binary PATH          the macfleet-headless executable to install (required)
#   --config PATH          the configuration to install when none is installed yet (required)
#   --prefix DIR           where the binary and configuration go
#                          (default: $HOME/Library/Application Support/MacFleet)
#   --launch-agents DIR    where the launchd definition goes (default: $HOME/Library/LaunchAgents)
#   --log-dir DIR          where the agent writes its logs (default: $HOME/Library/Logs/MacFleet)
#   --apply                write the files. Without it the script prints the plan and changes nothing.
#   --load                 also load the agent with launchctl. Needs --apply.
#
# Exit codes: 0 done (or planned), 2 usage or configuration error.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
# A package keeps the template in launchd/, and a source checkout keeps it in Support/launchd/.
TEMPLATE="$HERE/launchd/com.macfleet.headless.plist"
[ -f "$TEMPLATE" ] || TEMPLATE="$HERE/Support/launchd/com.macfleet.headless.plist"
LABEL=com.macfleet.headless

BINARY=""
CONFIG=""
PREFIX="$HOME/Library/Application Support/MacFleet"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/MacFleet"
APPLY=0
LOAD=0

die() {
  echo "install-agent: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --binary) [ $# -ge 2 ] || die "--binary needs a path"; BINARY=$2; shift 2 ;;
    --config) [ $# -ge 2 ] || die "--config needs a path"; CONFIG=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift 2 ;;
    --launch-agents) [ $# -ge 2 ] || die "--launch-agents needs a directory"; AGENTS=$2; shift 2 ;;
    --log-dir) [ $# -ge 2 ] || die "--log-dir needs a directory"; LOGS=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --load) LOAD=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "do not run this as root. The agent belongs to your user account."
[ -n "$BINARY" ] || die "--binary is required"
[ -n "$CONFIG" ] || die "--config is required"
[ "$LOAD" -eq 0 ] || [ "$APPLY" -eq 1 ] || die "--load needs --apply"
[ -x "$BINARY" ] || die "$BINARY is not an executable file"
[ -f "$CONFIG" ] || die "$CONFIG is not a file"
[ -f "$TEMPLATE" ] || die "the launchd template is missing from this package: $TEMPLATE"

# The paths are written into the launchd definition with sed, so these characters would corrupt it.
for path in "$PREFIX" "$AGENTS" "$LOGS" "$BINARY" "$CONFIG"; do
  case "$path" in
    *'|'*|*'&'*|*'\'*) die "paths may not contain |, & or a backslash: $path" ;;
  esac
done

# The agent must report its version and validate the configuration before anything is installed.
VERSION_LINE=$("$BINARY" version 2>&1) || die "$BINARY does not run its version command: $VERSION_LINE"
CHECK_LINE=$("$BINARY" check --config "$CONFIG" 2>&1) || die "the configuration does not validate: $CHECK_LINE"

INSTALLED_BINARY="$PREFIX/bin/macfleet-headless"
INSTALLED_CONFIG="$PREFIX/config/headless.json"
PLIST="$AGENTS/$LABEL.plist"
MANIFEST="$PREFIX/install-manifest.txt"

echo "MacFleet headless agent: $VERSION_LINE"
echo "binary:    $BINARY -> $INSTALLED_BINARY"
if [ -e "$INSTALLED_CONFIG" ]; then
  echo "config:    keeping the configuration already at $INSTALLED_CONFIG (checked below)"
else
  echo "config:    $CONFIG -> $INSTALLED_CONFIG (owner-only, mode 600)"
fi
echo "launchd:   $PLIST"
echo "logs:      $LOGS"
echo "validated: $CHECK_LINE"

if [ "$APPLY" -eq 0 ]; then
  echo "dry run: nothing was written. Re-run with --apply to install."
  exit 0
fi

if [ -e "$INSTALLED_CONFIG" ]; then
  INSTALLED_CHECK=$("$BINARY" check --config "$INSTALLED_CONFIG" 2>&1) || die "the configuration already installed does not validate: $INSTALLED_CHECK"
fi

mkdir -p "$PREFIX/bin" "$PREFIX/config" "$AGENTS" "$LOGS"
chmod 700 "$PREFIX/config"
install -m 755 "$BINARY" "$INSTALLED_BINARY"

CREATED_CONFIG=no
if [ ! -e "$INSTALLED_CONFIG" ]; then
  install -m 600 "$CONFIG" "$INSTALLED_CONFIG"
  CREATED_CONFIG=yes
elif [ -f "$MANIFEST" ] && grep -q '^config_created_by_install=yes' "$MANIFEST"; then
  CREATED_CONFIG=yes
fi

RENDERED="$PREFIX/.launch-agent.$$"
sed -e "s|__MACFLEET_HEADLESS_BINARY__|$INSTALLED_BINARY|g" \
    -e "s|__MACFLEET_HEADLESS_CONFIG__|$INSTALLED_CONFIG|g" \
    -e "s|__MACFLEET_LOG_DIRECTORY__|$LOGS|g" \
    "$TEMPLATE" > "$RENDERED"
if ! plutil -lint "$RENDERED" > /dev/null; then
  rm -f "$RENDERED"
  die "the rendered launchd definition does not parse"
fi
mv "$RENDERED" "$PLIST"
chmod 644 "$PLIST"

cat > "$MANIFEST" <<EOF
# MacFleet headless agent install manifest. uninstall-agent.sh removes only the files listed here.
binary=$INSTALLED_BINARY
config=$INSTALLED_CONFIG
config_created_by_install=$CREATED_CONFIG
launch_agent=$PLIST
log_directory=$LOGS
EOF

if [ "$LOAD" -eq 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    echo "install-agent: the files are installed, but launchd did not load $LABEL." >&2
    echo "Check $LOGS and run uninstall-agent.sh --apply to remove what was installed." >&2
    exit 2
  fi
  echo "loaded $LABEL"
fi

echo "installed. Check the agent with: $INSTALLED_BINARY status --config $INSTALLED_CONFIG"

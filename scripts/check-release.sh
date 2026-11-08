#!/bin/sh
# Static checks of the release files. Nothing is built or signed. CI runs this before the builds.
#   - every shell script parses
#   - every property list lints, including the templates before substitution
#   - Config/Version.xcconfig agrees with every version in the Xcode project
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/config.sh

failures=0
fail() {
  echo "check-release: $*" >&2
  failures=$((failures + 1))
}

for script in scripts/*.sh scripts/lib/*.sh; do
  sh -n "$script" || fail "$script does not parse"
done

for plist in Support/launchd/com.macfleet.headless.plist Support/app/Info.plist.template; do
  plutil -lint "$plist" > /dev/null || fail "$plist does not lint"
done

VERSION=$(xcconfig_value Config/Version.xcconfig MARKETING_VERSION)
BUILD=$(xcconfig_value Config/Version.xcconfig CURRENT_PROJECT_VERSION)
BUNDLE_ID=$(xcconfig_value Config/Version.xcconfig MACFLEET_BUNDLE_ID)
for key in MARKETING_VERSION CURRENT_PROJECT_VERSION PRODUCT_BUNDLE_IDENTIFIER; do
  case "$key" in
    MARKETING_VERSION) expected=$VERSION ;;
    CURRENT_PROJECT_VERSION) expected=$BUILD ;;
    *) expected=$BUNDLE_ID ;;
  esac
  found=$(grep -o "$key = [^;]*" MacFleet.xcodeproj/project.pbxproj | sed "s/^$key = //" | sort -u)
  if [ "$found" != "$expected" ]; then
    fail "the Xcode project does not agree with Config/Version.xcconfig for $key: expected $expected, project has: $found"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "check-release: $failures problem(s)" >&2
  exit 1
fi
echo "check-release: scripts, property lists, and version settings agree"

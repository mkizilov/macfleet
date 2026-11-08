#!/bin/sh
# Performance and memory check. It builds the optimized benchmarks, runs them, and compares the measured numbers with the
# ceilings in Config/performance-budgets.env. It exits 1 when any ceiling is exceeded, so a regression fails the build.
#
# Measured here: dashboard work per sample, history save cost, week-chart and seven-day summary latency, fleet ingest
# cost, memory added by seven days of history, and reopen time. Process-level resident memory of a running app or agent
# is not measured by this script, because it needs a running app. docs/distribution.md says so.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/config.sh

# shellcheck disable=SC1091
. Config/performance-budgets.env

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
WORK="$PWD/.agent-local/performance"
COMMON="-swift-version 6 -target arm64-apple-macosx14.0 -sdk $SDK -O -whole-module-optimization"
rm -rf "$WORK"
mkdir -p "$WORK/data"
trap 'rm -rf "$WORK"' EXIT

echo "== building the optimized libraries and the history benchmark"
# -enable-testing lets the history harness use @testable import, as it does in scripts/swiftc-history-check.sh.
swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetKit \
  -emit-module-path "$WORK/MacFleetKit.swiftmodule" -o "$WORK/libMacFleetKit.dylib" $COMMON -lsqlite3 -enable-testing \
  -Xlinker -install_name -Xlinker @rpath/libMacFleetKit.dylib $(find Sources/MacFleetKit -name '*.swift')
swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetState -I "$WORK" \
  -emit-module-path "$WORK/MacFleetState.swiftmodule" -o "$WORK/libMacFleetState.dylib" $COMMON \
  -L "$WORK" -lMacFleetKit -Xlinker -install_name -Xlinker @rpath/libMacFleetState.dylib \
  $(find Sources/MacFleetState -name '*.swift')
swiftc -module-name dashboard_benchmark -I "$WORK" -L "$WORK" -lMacFleetKit -lMacFleetState $COMMON \
  -Xlinker -rpath -Xlinker "$WORK" -o "$WORK/dashboard-benchmark" scripts/swiftc-benchmark/main.swift
swiftc -module-name history_check -I "$WORK" -L "$WORK" -lMacFleetKit $COMMON -enable-testing \
  -Xlinker -rpath -Xlinker "$WORK" -o "$WORK/history-check" scripts/swiftc-history-check/main.swift

echo "== running the dashboard benchmark"
"$WORK/dashboard-benchmark" > "$WORK/dashboard.txt"
cat "$WORK/dashboard.txt"

echo "== running the history and fleet benchmark"
"$WORK/history-check" benchmark "$WORK/data" > "$WORK/history.txt"
cat "$WORK/history.txt"

# Pulls the first number after a label in a benchmark line. The labels come from scripts/swiftc-history-check/main.swift.
number_after() {
  sed -n "s/.*$1 \([0-9][0-9.]*\).*/\1/p" "$2" | head -n 1
}

dashboard_median=$(sed -n 's/.*median \([0-9][0-9.]*\), p95.*/\1/p' "$WORK/dashboard.txt" | head -n 1)
save_mean=$(sed -n 's/.*mean \([0-9][0-9.]*\) us, slowest.*/\1/p' "$WORK/history.txt" | head -n 1)
week_median=$(sed -n 's/.*hour [0-9.]* ms, day [0-9.]* ms, week \([0-9][0-9.]*\) ms.*/\1/p' "$WORK/history.txt" | head -n 1)
fleet_summary=$(sed -n 's/^per-Mac 7-day summary, median of 60: \([0-9.]*\) ms.*/\1/p' "$WORK/history.txt" | head -n 1)
fleet_ingest=$(sed -n 's/.*(\([0-9.]*\) us per call).*/\1/p' "$WORK/history.txt" | head -n 1)
rss_before=$(sed -n 's/^resident memory: before \([0-9.]*\) MB.*/\1/p' "$WORK/history.txt" | head -n 1)
rss_after=$(sed -n 's/^resident memory: before [0-9.]* MB, after writes \([0-9.]*\) MB.*/\1/p' "$WORK/history.txt" | head -n 1)
reopen=$(sed -n 's/^reopen (integrity check and upkeep): \([0-9.]*\) ms.*/\1/p' "$WORK/history.txt" | head -n 1)

for value in "$dashboard_median" "$save_mean" "$week_median" "$fleet_summary" "$fleet_ingest" "$rss_before" "$rss_after" "$reopen"; do
  if [ -z "$value" ]; then
    echo "performance-check: a measurement is missing from the benchmark output" >&2
    exit 1
  fi
done
rss_growth=$(awk "BEGIN { printf \"%.1f\", $rss_after - $rss_before }")

failures=0
check() {
  # $1 label, $2 measured, $3 ceiling, $4 unit
  if awk "BEGIN { exit !($2 <= $3) }"; then
    printf '  ok    %-44s %10s %s (ceiling %s)\n' "$1" "$2" "$4" "$3"
  else
    printf '  FAIL  %-44s %10s %s (ceiling %s)\n' "$1" "$2" "$4" "$3"
    failures=$((failures + 1))
  fi
}

echo "== budgets (Config/performance-budgets.env)"
check "dashboard work per sample, median" "$dashboard_median" "$DASHBOARD_MEDIAN_US_MAX" "us"
check "history save(), mean" "$save_mean" "$HISTORY_SAVE_MEAN_US_MAX" "us"
check "week chart query, median" "$week_median" "$HISTORY_WEEK_SERIES_MEDIAN_MS_MAX" "ms"
check "seven-day summary per Mac, median" "$fleet_summary" "$FLEET_SUMMARY_MEDIAN_MS_MAX" "ms"
check "fleet ingest, per call" "$fleet_ingest" "$FLEET_INGEST_US_PER_CALL_MAX" "us"
check "memory added by seven days of history" "$rss_growth" "$HISTORY_RSS_GROWTH_MB_MAX" "MB"
check "reopen with integrity check and upkeep" "$reopen" "$HISTORY_REOPEN_MS_MAX" "ms"

if [ "$failures" -gt 0 ]; then
  echo "performance-check: $failures budget(s) exceeded" >&2
  exit 1
fi
echo "performance-check: every measurement is within its budget"

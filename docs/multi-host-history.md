# Multi-Mac history

Each Mac has its own stored history. This page covers how rows are keyed, how clocks are handled, how retention and
rollup work, how queries and export behave, and what was and was not verified.

## Identity

Every stored row is keyed by a host ID:

- `local` is this Mac.
- A registered remote Mac uses the ID of its record. It survives re-pinning and renaming.

`points` and `volume_points` are keyed by `(host, tier, start)`. The `hosts` table holds each Mac's horizons, retention,
and last clock offset. Every history read names its host, and the query plans for every tier use the primary key
(`SEARCH ... USING PRIMARY KEY`, tested). Rows from different Macs never share a row, a bucket, or a rollup horizon.

## Schema and migration

The file is schema version 2. A version 1 file (one Mac) is migrated in one transaction. Its rows move under `local`, and
its global horizons become the local Mac's. Nothing is dropped. Test: `aVersionOneFileKeepsEveryRowUnderTheLocalMac`.

## Clock handling

- **Placement.** A remote sample is placed at the time this Mac received it, not at the host's own `capturedAt`. A host's
  clock can therefore never reorder or shift the timeline.
- **Offset.** The host's offset (host time minus arrival) is recorded per host. Beyond 60 seconds it is reported on the
  comparison and in the chart section, with its direction. Placement by arrival keeps the charts aligned either way.
- **Duplicates.** A host that sends the same captured time again is stored once.
- **This Mac's clock moving back.** A step back of more than 5 seconds holds new snapshots until the clock passes the last
  recorded time. Nothing is stored out of order, and the history card says so. Snapshots held in that period are not
  stored, so the gap is real.
- **Closing buckets.** A bucket is rolled up 120 seconds after it ends (`closeGrace`), so a sample received just before a
  rollup still lands in its bucket.

## Rollup, retention, and pruning

- **Per host.** Five-minute and hourly rollups run for each Mac, with that Mac's own horizons. A Mac is judged by its own
  newest stored point. A Mac that reports ahead of another therefore cannot close the other's buckets. The fleet
  benchmark found this defect, and `aHostRunningAheadDoesNotCloseAnotherHostsOpenBuckets` pins it.
- **Rollup before pruning.** A raw point is kept until its five-minute bucket is rolled up, and a five-minute point until
  its hour is. Pruning never deletes unaggregated data.
- **Defaults.** Raw 2 days, five-minute 14 days, hourly 90 days. The minimums are 2 hours, 2 days, and 8 days.
- **Per Mac.** Each Mac can have its own retention. Changing it runs rollup and then prunes at once.
- **Trade-off.** A Mac that stops reporting keeps the points of its newest open bucket, and the last partial hour of
  five-minute data, until it reports again. The amount is bounded: about seven minutes of raw points and up to one hour
  of five-minute points for each silent Mac.

## Queries and downsampling

- **Charts.** The hour range reads raw points, the day range five-minute buckets, and the week range hourly buckets.
  Chart windows are aligned to their slot widths.
- **Summaries.** `summary(host:from:to:)` reads whole hourly buckets from the hourly tier, so its cost does not grow with
  the window. Totals are exact for windows that start and end on five-minute boundaries. Any other window is exact only
  while its edge raw points are still stored. The app's windows are aligned, so this matters only for custom queries.
- **Export.** The finest tier that keeps each Mac within a 1,000-point budget is chosen. A span that is not yet rolled
  up is read from a finer tier at each end, so a few finer rows can appear at the edges. Every row carries the tier its
  time came from.
- **Measured.** A 7-day summary of one Mac: median 0.11 ms. The week chart: median 0.15 ms. Export of 7 days for three
  Macs: 2,670 rows in 0.6 ms.

## Comparisons and aggregates

- **All Macs.** Totals merge each Mac's own totals for the range. A Mac with no reading for a metric is left out of that
  metric, so it is never counted as zero. The peak names the Mac it came from.
- **Side by side.** Up to four Macs, each with its own snapshot count, averages, peaks, and newest data. A Mac with no
  data shows a dash.

## Per-Mac alert settings

Thresholds, switches, sustained periods, and cooldowns are kept per Mac under the user defaults key
`MacFleet.hostAlertSettings`. Remote readings are evaluated at the time they were received. Each notification names its
Mac, and its identifier is unique to that Mac and alert. The local Mac keeps its own settings in `AlertCenterModel`.

## Removing a Mac and deleting history

- **Removing a Mac.** The connection is stopped first. Then the Mac's history, alert settings, record, and secret are
  removed, in that order, so no sample can be stored after its history is deleted.
- **Delete Stored History.** This removes only the history. The pairing and alert settings are kept. The action is not
  confirmed by a dialog.

## Export

The CSV has the columns `time_utc,resolution,host_id,host,metric,mean,maximum,observations,snapshots`.

- Times are UTC, in ISO 8601.
- Metrics are `cpu`, `memory`, `download_bytes_per_second`, `upload_bytes_per_second`, and `disk:<mount>`.
- An empty mean or maximum means no reading, never zero.
- A field that contains a comma, a quote, or a line break is quoted, with quotes doubled.

## Concurrent ingestion

All reads and writes go through the `MetricHistoryStore` actor, which owns a single SQLite handle. Each write is one
transaction. Each Mac's watcher hands its snapshots over in order.

- **Test.** Six Macs writing at once lose no rows and mix none. A reader sees a count that never goes back while a writer
  runs.
- **Benchmark.** Three Macs ingest at once: 907,200 calls in 4.5 s (5.0 µs per call). Each Mac stores its own 60,450
  snapshots in the aligned window, and each mean matches that Mac's own reading.

## Verification

- **Unit and integration tests.** 61 new tests: 37 in `HistoryHostTests` and 24 in `FleetHistoryTests`. They cover host
  isolation and query plans, clock handling, migration, retention and removal per Mac, concurrent ingestion, aggregation
  and export, CSV quoting, closed buckets and cross-Mac isolation, the clock step-back notice, per-Mac alert settings,
  the history model and presentation, and removing a Mac from the fleet.
- **Storage gate.** `scripts/swiftc-history-check.sh` on the final code: batches 30 of 30 consistent, upkeep 30 of 30,
  torn writes 5 of 5. Its local benchmark measures `save()` at a mean of 2.6 µs. Its fleet benchmark is described above.
- **App target.** Typechecked on a scratch copy, with the new history window in place.

## Not verified

- The History window was typechecked, not run. Layout, the comparison table, the charts, and the CSV save panel were not
  seen or exercised.
- Notification delivery was not observed.
- A real tailnet and physical Macs were not used. The fleet benchmark uses simulated readings.
- Sleep and wake with several Macs, and a real clock step, were not tested.
- The history window refreshes every 30 seconds while it is open, so alert status there can lag by up to that long.

# Profile persistence and recovery — 1 October 2026

## Acceptance and implementation

Persisted version-one profiles must either load with validated field types or return an error without an Objective-C startup exception. Validation now covers profile containers/version, Space identities, node strings/numbers/relationships, settings (including nested content-blocking, shortcut and GitHub settings), window geometry/split fields, and bounded scroll-session metadata. Numeric values must be finite; integer fields cannot contain fractions or booleans. Missing optional version-one fields remain compatible. Unsupported SQLite or profile JSON versions fail closed, including backup recovery, so a newer profile cannot be silently downgraded.

A saved profile is read and validated before schema setup or writable access. SQLite reads and writes cap a single value at 64 MiB. Transactions deeply copy mutable settings and window state, validate the candidate, serialize without unnecessary dictionary-key sorting, and publish it only after SQLite COMMIT succeeds. WAL and synchronous=FULL remain enabled. Saves remain ordered and synchronous; this change does not introduce a background writer, weaken durability, or claim that large saves have no main-thread cost.

## Recovery behavior

Regular profiles keep at most two complete SQLite snapshots: `Lite.sqlite.backup` and `Lite.sqlite.backup.previous`. SQLite's backup API includes committed WAL contents. A pending snapshot is flushed, validated with the model and SQLite quick_check, and atomically installed. Refresh runs on successful profile writes or open, at most once per minute; it has no timer or polling. Failed attempts also back off for a minute and expose `backupError` plus `LTStoreBackupFailed`. Private profiles do not create disk backups.

Startup never automatically substitutes a backup for a damaged database. The existing native alert offers an explicit Restore Backup action only when a compatible snapshot validates. Recovery durably copies the original database and any WAL, SHM and journal into a private `.damaged-UUID` directory before replacement. A durable `.recovery-pending` marker prevents ordinary startup during an interrupted replacement; choosing Restore Backup again resumes it. The three-archive limit refuses another recovery instead of deleting damaged originals. The user can move those directories somewhere safe before retrying.

A recovery can lose changes made after the latest snapshot. This backup is organization/history recovery, not a backup of Chromium cookies, website storage, the encrypted login vault, or Keychain material. Snapshot files are mode 0600 and preserved-original directories are mode 0700. Unsafe database/backup symlinks fail closed.

History deletion has an error-returning API. After the live DELETE succeeds, normal snapshots and pending snapshot files are retired and a new known-good snapshot is written. Restoring normal backups therefore cannot resurrect deleted history. Failure during deletion, removal or rebuilding of backups is reported; it must not be described as completed. Explicitly preserved `.damaged-*` originals are never silently changed, and can still contain old history. Removing those preserved originals remains the user's responsibility.

## Verification

`LiteProfileTests`: **151 passed, 0 failed**. These include node `order:null`, nondictionary window entries, malformed nested settings, version-one optional-field compatibility, invalid candidate rollback without nested mutation, SQLite schema migration, unsupported SQLite/JSON downgrade rejection, restored organization and history, byte-identical damaged originals, corrupt-newest fallback, interrupted recovery retry, bounded damaged archives, and symlink rejection.

Failure tests inject SQLITE_FULL and SQLITE_IOERR_FSYNC through a test-only SQLite VFS, then reopen the database and inspect the saved state. An abruptly exiting subprocess spills a 4 MiB uncommitted WAL transaction; reopening retains the preceding commit. These exercise actual SQLite write/sync/rollback paths. They are not a physical full-volume, power-cut, or hardware fault qualification. History-deletion regressions reopen restored backups and verify deleted rows stay absent while unrelated rows remain.

`LiteCoreTests`: **98 passed, 0 failed**. `LiteDownloadHistoryTests`: **38 passed, 0 failed**, covering JSON disk persistence, malformed records, private isolation, retention, restart interruption status, owner release and action routing using a small LTPage double. Real CEF network/download/quarantine behavior is covered separately and is not established by the persistence double.

Commands:

```sh
cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release
cmake --build .build --target LiteTests LiteProfileTests LiteDownloadHistoryTests -j 4
ctest --test-dir .build -R 'Lite(Core|Profile|DownloadHistory)Tests' --output-on-failure
clang -O3 -fobjc-arc -framework Foundation -framework Security \
  script/profile_benchmark.m \
  .build/libLiteCore.a -lsqlite3 -o /private/tmp/lite-profile-benchmark
/private/tmp/lite-profile-benchmark
```

Raw local evidence (ignored disposable outputs): `test-results/readiness-2026-10-01/profile-tests.log`, `profile-core-tests.log`, `download-history-tests.log`, `baseline/profile-benchmark.{m,json}` and `profile-benchmark-after.json`.

## Measured persistence cost

Same Mac and Release library, same harness, synthetic pinned nodes, 20 samples per size. Each sample changes one title with a durable synchronous commit and reopens the same store. The harness and full samples were captured before behavioral edits. Median/p95 below include candidate copy, validation, serialization and primary SQLite commit. Median averages the two middle samples; p95 uses nearest rank (the 19th of 20 sorted samples). These statistics were recalculated from the preserved raw measurements after correcting the harness's original upper-median/maximum indexing. The initial seed creates backups; these short steady-state samples do not include a periodic backup refresh. These are model/store timings, not sidebar UI frame times.

| Nodes | Before commit median / p95 | After commit median / p95 | Open median before → after |
| --- | --- | --- | --- |
| 2,000 | 17.74 / 18.74 ms | 7.97 / 8.54 ms | 10.82 → 13.55 ms |
| 10,000 | 89.47 / 91.51 ms | 40.91 / 43.36 ms | 52.96 → 65.68 ms |

The commit reduction comes from avoiding the JSON object round trip, redundant model reconstruction/validation, per-node UUID creation during copying, and sorted-key output. Open takes longer because more saved fields are validated and the existing database is inspected before writable schema setup. At 10,000 nodes, a synchronous save still exceeds a 16.7 ms frame budget; the measurement supports reduced stalls, not stall-free large-profile interaction. Native sidebar responsiveness, crash/power-loss durability and older/hardware configurations need their own UI/environment evidence.

---
name: flutter-sqlite-ffi-fts5
description: Use when a Flutter app needs offline full-text search and robust local SQLite — bundle an FTS5-capable SQLite via FFI (Android's system lib omits fts5), a trigger-synced search index with bm25 ranking, versioned schema migrations that roll back cleanly, and the background-isolate connection rule.
---

# Bundled SQLite (FFI) + FTS5 search + migrations

Run a SQLite built with **FTS5** on every device by opening the bundled library via FFI (the
Android system SQLite frequently omits the fts5 module), back global search with a
trigger-maintained FTS index and bm25 ranking, and evolve the schema with a transactional
migration ladder. The persistence foundation under most other skills here.

## Contents

1. Why FFI (the fts5 problem)
2. Dependencies
3. Opening the DB (+ the isolate rule)
4. `onConfigure` pragmas that matter
5. Schema versioning: baseline + ladder
6. The migration ladder
7. FTS5 index + sync triggers
8. Querying: prefix MATCH + bm25
9. Gotchas

## 1. Why FFI (the fts5 problem)

The `sqflite` plugin uses the device's **system** SQLite — and Android's build **frequently omits
the fts5 module**, so `CREATE VIRTUAL TABLE … USING fts5` fails with `no such module: fts5` on
real phones. Fix: ship a known-good SQLite (`sqlite3_flutter_libs`, compiled with FTS5) and open
it through `sqflite_common_ffi`. Bonus: the exact same engine runs host-side in tests.

## 2. Dependencies

```yaml
dependencies:
  sqflite: ^2.4.2+1
  sqflite_common_ffi: ^2.3.3     # opens against a provided native lib via FFI
  sqlite3_flutter_libs: ^0.5.24  # ships the FTS5-capable native SQLite
  path: ^1.9.1
  path_provider: ^2.1.4
```

## 3. Opening the DB (+ the isolate rule)

Point sqflite at the FFI factory once per isolate, then open. The FFI factory has **no
Android-aware `getDatabasesPath`**, so resolve a writable dir yourself:

```dart
bool _ffiReady = false;
void initSqliteFfi() {                      // idempotent, once per isolate
  if (_ffiReady) return;
  sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; _ffiReady = true;
}

static Future<Database> open({String? path, bool singleInstance = true}) async {
  final dbPath = path ?? p.join((await getApplicationDocumentsDirectory()).path, 'app.db');
  return databaseFactory.openDatabase(dbPath, options: OpenDatabaseOptions(
    version: version, singleInstance: singleInstance,
    onConfigure: _configure, onCreate: _createSchema, onUpgrade: migrate));
}
```

**The isolate rule (critical):** sqflite caches single-instance databases **by path across the
whole process, including across isolates**. A background isolate (alarm/notification/widget) that
opens the shared instance and then `close()`s it **slams the connection shut under the
still-running foreground app** — every later query throws `DatabaseException(database_closed)`.
So **every `@pragma('vm:entry-point')` isolate opens with `singleInstance: false`** to get a
private connection it can close safely. (This rule recurs in `flutter-local-notifications-reminders`,
`flutter-home-screen-widgets`, and `flutter-encrypted-backup`.)

## 4. `onConfigure` pragmas that matter

```dart
static Future<void> _configure(Database db) async {
  await db.execute('PRAGMA foreign_keys = ON');       // ON DELETE CASCADE etc.
  await db.execute('PRAGMA recursive_triggers = ON'); // so a cascade delete also fires FTS-sync triggers
}
```

`recursive_triggers = ON` is what makes a `journeys` delete cascade into `events` **and** fire the
per-row triggers that keep the FTS index in sync — without it the index silently drifts on cascade
deletes.

## 5. Schema versioning: baseline + ladder

sqflite stores the schema version in SQLite's `PRAGMA user_version` (one integer — no per-migration
log). On open it compares the file's version with `AppDatabase.version`; older files get
`onUpgrade(from, to)`.

- **v1 is the frozen baseline** — built directly by `_createSchema` in `onCreate`.
- To change the schema: **bump `version`**, **append** an `if (from < N)` block to `migrate()`,
  and **mirror the final shape into `_createSchema`** so fresh installs match. **Never edit a
  shipped migration block.**

## 6. The migration ladder

Each step applies the delta from N-1 to N; a user skipping versions runs every block in order.
The whole function runs inside sqflite's upgrade transaction, and **SQLite DDL is transactional**,
so a throwing step **rolls the entire upgrade back** — `user_version` stays put and the next launch
retries. No partial state.

```dart
Future<void> migrate(DatabaseExecutor db, int from, int to) async {
  if (from < 2) { for (final sql in _v2Additions) await db.execute(sql); }  // additive ADD COLUMN
  if (from < 3) { /* … */ }
}
```

Rules for harder steps:
- **`ALTER TABLE` only adds/renames/drops columns.** For a type/constraint change do the 12-step
  rebuild (new table → `INSERT … SELECT` → drop → rename).
- A rebuild that would trip FK checks: wrap in `PRAGMA foreign_keys = OFF` … `ON`.
- Changing what the FTS index covers: drop/recreate its triggers and reindex
  (`INSERT INTO search_fts(search_fts) VALUES('rebuild')`).

*(A second, independent layer exists for JSON payloads stored in a column — version them with an
upcaster chain keyed on a `_v` field, run forward on read. Keep it separate from the schema
`user_version`.)*

## 7. FTS5 index + sync triggers

One virtual table spans every searchable entity. Store retrieval metadata as **UNINDEXED** (kept
but not tokenized); only `text` is searchable. Each indexed row carries its owning group id so
results group cheaply:

```sql
CREATE VIRTUAL TABLE search_fts USING fts5(
  kind UNINDEXED, row_id UNINDEXED, group_id UNINDEXED,
  text,
  tokenize = 'unicode61 remove_diacritics 2'    -- accent-insensitive
);
```

Keep it in sync with **AFTER INSERT / UPDATE / DELETE triggers** on each source table. Pull
searchable fields out of a JSON column with `json_extract`:

```sql
CREATE TRIGGER search_events_ai AFTER INSERT ON events BEGIN
  INSERT INTO search_fts(kind, row_id, group_id, text)
  VALUES ('event', new.id, new.journey_id,
    new.title || ' ' || coalesce(new.note,'') || ' ' ||
    coalesce(json_extract(new.data,'$.ocr'),''));
END;
-- _ad: DELETE the row; _au: DELETE then re-INSERT (update = delete+insert)
```

Because triggers own the index, it **never drifts** — no application code has to remember to
reindex. A group-level delete trigger (`DELETE FROM search_fts WHERE group_id = old.id`) cleans up
everything under a cascade-deleted parent regardless of trigger ordering.

## 8. Querying: prefix MATCH + bm25

Build a MATCH expression of **quoted prefix terms AND-ed together** so typing narrows live, after
stripping FTS operator characters from user input (they'd break the query). Rank with `bm25`
(ascending — more negative = better); the first time a group id appears is its best score, giving
group order for free:

```dart
static String? _toMatchExpr(String raw) {
  final tokens = raw.toLowerCase().split(RegExp(r'\s+'))
      .map((t) => t.replaceAll(RegExp(r'["*():^-]'), ''))    // strip FTS operators
      .where((t) => t.isNotEmpty).toList();
  return tokens.isEmpty ? null : tokens.map((t) => '"$t"*').join(' ');  // "blood"* "pres"*
}

final rows = await db.rawQuery(
  'SELECT kind, row_id, group_id FROM search_fts WHERE search_fts MATCH ? ORDER BY bm25(search_fts)',
  [match]);
```

## 9. Gotchas

- **Use the FFI + bundled lib** or FTS5 fails on real Android devices (`no such module: fts5`).
- **`initSqliteFfi()` once per isolate** — a background isolate has its own memory and must select
  the FFI factory again before opening.
- **`singleInstance: false` in every background isolate** — or closing its connection throws
  `database_closed` in the live app.
- **FFI factory can't resolve the Android db dir** — build the path via `path_provider`.
- **`recursive_triggers = ON`** or cascade deletes leave the FTS index stale.
- **v1 frozen; append-only ladder; mirror into `_createSchema`** — never edit a shipped block.
- **DDL migrations are transactional** — a throw rolls the whole upgrade back; don't try to
  hand-clean partial state.
- **`ALTER` is limited** — type/constraint changes need the 12-step table rebuild (FK-off wrapped).
- **Strip FTS operator chars** from user queries; **prefix terms** (`"x"*`) give live-narrowing;
  **bm25 is ascending**.
- **UNINDEXED metadata columns** are stored-but-not-searchable — put ids/kinds there, only real
  text in the indexed column.

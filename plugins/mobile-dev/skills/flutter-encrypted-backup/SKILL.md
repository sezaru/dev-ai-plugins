---
name: flutter-encrypted-backup
description: Use when a Flutter app needs a full encrypted backup/restore — pack the SQLite database plus attachment files into one versioned, password-encrypted archive that can be written locally or uploaded to the cloud, with change-detection, a pluggable destination interface, and optional scheduled headless backups.
---

# Encrypted backup & restore (single sealed archive)

Pack **everything needed to reconstruct the app on a new device** — the SQLite snapshot, all
attachment files, and a manifest — into one self-describing encrypted file, written to any
destination (local folder, cloud). Zero-knowledge: the key is derived from the user's password
so the storage provider can never read a backup. This is the pattern proven in caremate's
`.cmbak` format.

Builds on `flutter-encryption-at-rest` (escrows its data-key), and pairs with
`flutter-google-drive-sync` / `flutter-android-saf-folder` (destinations) and
`flutter-home-screen-widgets` (the same alarm-isolate scheduling pattern).

## Contents

1. What gets backed up (and how to snapshot a live DB)
2. Dependencies
3. The container format — plaintext header + encrypted payload
4. Two version numbers (forward-compat)
5. Split the code: pure codec vs. platform glue
6. The password key + why you cache the *derived* key
7. Escrowing the attachment data-key
8. Change detection (don't re-do work)
9. Pluggable destinations
10. Restore (order is a safety contract)
11. Scheduling headless backups
12. Gotchas

## 1. What gets backed up

- **The SQLite database** — snapshot with `VACUUM INTO`, never a file copy. A running DB has a
  `-wal` sidecar; a raw copy is inconsistent. `VACUUM INTO` writes a clean, single-file,
  transactionally-consistent copy:
  ```dart
  await db.execute("VACUUM INTO '${snapPath.replaceAll("'", "''")}'"); // literal, not a param
  ```
  Then **null out your own backup bookkeeping** (`last_backup_*`) inside the snapshot — else
  recording a backup changes the DB, so the next checksum always differs (self-reference) and
  change-detection never skips.
- **All attachment files** — copied *verbatim* (they're already ciphertext from
  `flutter-encryption-at-rest`), keyed by forward-slash relative path.
- **A manifest** — versions, file list, content checksum, and the **escrowed attachment
  data-key** (without it, restored `.enc` files are undecryptable on a new device).

## 2. Dependencies

```yaml
dependencies:
  archive: ^4.0.0             # read+write binary zip (the pack/unpack)
  cryptography_plus: ^3.0.0   # AES-256-GCM + Argon2id
  flutter_secure_storage: ^9.2.4
  sqflite: ^2.4.2+1
  path: ^1.9.1
  path_provider: ^2.1.4
```

## 3. The container format

A single file: **plaintext header** (readable before you have the key — it carries the KDF
salt/params and the version) followed by the **AES-256-GCM payload**. No secrets in the header
(a salt is not secret):

```
MAGIC       "CMBK"            4 bytes   — reject foreign files
FORMAT_VER  uint16 LE         2 bytes   — the version gate
HEADER_LEN  uint32 LE         4 bytes
HEADER_JSON utf8 json         N bytes   — {formatVersion, createdAt, appVersion, cipher, secret{}}
PAYLOAD     AES-256-GCM blob  rest      — nonce ‖ ciphertext ‖ tag
```

`parseBackup` validates magic, **refuses a `formatVersion` newer than this build**
("update the app"), rejects below `minSupportedVersion`, and splits header/payload. The
payload decrypts to a zip (`archive`) of `manifest.json` + `db/<name>` + the attachment files.

## 4. Two version numbers (forward-compat)

Mirror the DB migration pattern with **two independent versions**:

- **`formatVersion`** (header, plaintext) — the *container* layout. Bump when the header/zip
  shape changes. Restore reads it first and gates on it.
- **`payloadVersion`** (manifest, inside the encrypted zip) — the *contents* layout (which
  manifest fields / schema shape). The DB's own `user_version` travels inside the snapshot, so
  a restored older DB is migrated by your normal `migrate()` ladder on first open.

## 5. Split the code: pure codec vs. platform glue

The single most important structural decision — it's what makes backup unit-testable:

- **`BackupCodec`** — *pure*: no filesystem, no DB. `seal(payload, key, secret) -> bytes` and
  `open(bytes, key) -> payload`, plus `readHeader` and `checksumOf`. Tests drive it with
  in-memory bytes and a `SecretKey`.
- **`BackupService`** — thin platform glue: `VACUUM INTO`, list attachment files, export the
  data-key, write/read files. Directories injectable for integration tests.

```dart
Future<Uint8List> seal(BackupPayload payload, {required SecretKey key, required BackupSecret secret, required String createdAt, required String appVersion}) async {
  final archive = Archive()
    ..addFile(_file('manifest.json', utf8.encode(jsonEncode(manifest.toJson()))))
    ..addFile(_file('db/app.db', payload.db));
  for (final e in payload.attachments.entries) archive.addFile(_file(e.key, e.value));
  final box = await _algorithm.encrypt(ZipEncoder().encodeBytes(archive), secretKey: key);
  return assembleBackup(BackupHeader(formatVersion: 2, createdAt: createdAt, appVersion: appVersion, secret: secret), box.concatenation());
}
```

## 6. The password key + why you cache the *derived* key

The backup key is 256-bit, **Argon2id-derived from the user's password** over a random salt
(salt + params recorded in the plaintext header so any device reproduces the key from the same
passphrase). This is the only method that satisfies *restore after an app-data clear, on a new
phone, or a different OS, with zero knowledge* — the provider never sees the key.

```dart
Future<SecretKey> deriveFromPassword(String password, {required List<int> salt, BackupKdfParams params = const BackupKdfParams()}) {
  return Argon2id(memory: params.memKiB /*64MiB*/, iterations: params.iterations, parallelism: params.parallelism, hashLength: 32)
      .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
}
```

**Cache the derived key, not just the password.** Argon2id at 64 MiB takes many seconds — a
headless alarm isolate only gets ~20 s before Android freezes it, and running the KDF there
blew the window. So derive **once** (foreground, at configure/password-change) and cache the
key + salt in secure storage; every later seal (headless or manual) reuses it, turning an ~18 s
run into ~2–3 s:

```dart
Future<({SecretKey key, Uint8List salt})> deriveAndCache(String password) async {
  final salt = newSalt(); final key = await deriveFromPassword(password, salt: salt);
  await _store('backup_password_v1', password);
  await _store('backup_key_v1', base64Encode(await key.extractBytes()));
  await _store('backup_key_salt_v1', base64Encode(salt));
  return (key: key, salt: salt);
}
Future<({SecretKey key, Uint8List salt})?> ensureKey() async =>
    await cachedKey() ?? (await storedPassword() case final pw?) ? deriveAndCache(pw) : null;
```

Reusing one salt per password is fine — each `.cmbak` still gets a fresh AES-GCM nonce.
`clearPassword()` (turn-off) must drop the cached key too. **Lost + forgotten password =
unrecoverable, by design** — warn about this explicitly in set/change flows.

## 7. Escrowing the attachment data-key

Attachment `.enc` files are sealed with the *device* data-key (see
`flutter-encryption-at-rest`), which never leaves the device on its own. Copying the files but
not the key = unrecoverable. **Chosen approach:** put the 32-byte device data-key in the
manifest — itself protected because the whole payload is encrypted with the backup key. On
restore, write it back into secure storage and the `.enc` files just work. (The rejected
alternative — decrypt+re-encrypt every attachment under the backup key — doubles crypto work
over large files on every run.)

## 8. Change detection (don't re-do work)

Content-address backups by a **SHA-256 over the plaintext payload** (DB bytes + each attachment,
length-prefixed, in a deterministic sorted order). Checksum the **plaintext, never the
ciphertext** — AES-GCM's random nonce makes identical content encrypt to different bytes.

```dart
// scheduled or manual run:
final snap = await service.snapshot();               // VACUUM + list + checksum
if (snap.checksum == settings.lastBackupChecksum) {  // nothing changed
  await repos.settings.patch({'last_backup_at': now}); // just record we checked
  return;                                              // skip encrypt + upload entirely
}
// else: seal, store, then persist checksum + timestamp + size
```

## 9. Pluggable destinations

A destination only moves **opaque sealed bytes** — orthogonal to encryption and to the
schedule. One interface, interchangeable implementations:

```dart
abstract interface class BackupStore {
  Future<bool> isAvailable();                                  // local: always; Drive: signed-in?
  Future<BackupEntry> store(Uint8List bytes, {required String stamp, int keep = 3}); // rolling, pruned
  Future<List<BackupEntry>> list();                            // newest first
  Future<Uint8List> fetch(BackupEntry entry);
  Future<void> delete(BackupEntry entry);
}
```

`LocalFileDestination(dir)` writes `app-backup-<YYYY-MM-DD>.cmbak`, prunes to the newest
`keep`, and lists by name (the date stamp sorts chronologically). A `DriveDestination` is the
cloud counterpart (see `flutter-google-drive-sync`). The caller supplies the date stamp — keep
the clock *out* of the service so it's deterministic in tests.

## 10. Restore (order is a safety contract)

```dart
final header = codec.readHeader(bytes);            // learn secret method BEFORE prompting
final key = /* cached key if salt matches, else deriveFromPassword(password, header.salt) */;
final payload = await codec.open(bytes, key: key); // wrong key throws — verify before touching data
// close the live DB connection FIRST (overwriting an open SQLite file corrupts it)
await crypto.importDataKeyBase64(payload.attachmentDataKey!);   // 1. key
await replaceAttachmentTree(payload.attachments);              // 2. files
await File(dbPath).writeAsBytes(payload.db, flush: true);      // 3. db LAST = point of no return
// reopen/restart the app
```

Decrypt-and-verify **before** deleting anything; write the DB **last** so a mid-restore failure
leaves the old DB intact; try the cached secret silently first and **remember** a
manually-entered password on success (derive+cache its key) so the new phone keeps backing up.

## 11. Scheduling headless backups

Reuse the alarm-isolate pattern from `flutter-home-screen-widgets` (`android_alarm_manager_plus`,
fixed alarm id, top-level `@pragma('vm:entry-point')` callback). Two rules shaped by the ~20 s
freeze window:

1. **Re-arm the next alarm *first*, before the backup work** — `oneShotAt` is one-shot; if the
   backup is frozen mid-run, arming first keeps the daily chain alive (freeze costs only *this*
   run). A startup `sync()` in `main()` is the backstop.
2. **The work must fit ~20 s** — which is why the KDF is cached out of the per-run path (§6).

The callback opens its **own** DB connection with `singleInstance: false` (see the sqflite
isolate rule in `flutter-sqlite-ffi-fts5`), runs the checksum-skip + seal, and only arms when
`canRunUnattended` (configured + non-off frequency + a cached key). `rescheduleOnReboot: true`.

## 12. Gotchas

- **`VACUUM INTO`, never a file copy** of a live DB (`-wal` inconsistency). It can't run inside
  a transaction — pass the app-level `Database`.
- **Null out `last_backup_*` in the snapshot** or change-detection never skips (self-reference).
- **Checksum the plaintext, not the ciphertext** (random nonce).
- **Header carries no secrets** — it must be readable before you have the key.
- **Cache the derived key** for headless runs; caching only the password re-runs Argon2id and
  blows the freeze window.
- **Escrow the attachment data-key** in the (encrypted) manifest, or restored files are dead.
- **Close the DB before overwriting it**, write it **last** in restore.
- **Refuse newer `formatVersion`** with an "update the app" message; migrate older ones.
- **Keep the clock and the filesystem out of the codec** — pass the date stamp and inject dirs,
  so the core is pure and testable.
- **Destination sees only opaque bytes** — never a key or plaintext; this keeps local/cloud
  swappable and keeps ciphertext-only on any third-party server.

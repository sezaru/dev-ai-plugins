---
name: flutter-encryption-at-rest
description: Use when a Flutter app must store files (documents, photos, exports) encrypted on disk — AES-256-GCM via cryptography_plus with the data-key held in the platform keystore/keychain (flutter_secure_storage), plaintext never written to disk, plus an app-internal file store invisible to the gallery/MediaStore.
---

# Encryption at rest (AES-256-GCM + keystore data-key)

Store user files as authenticated ciphertext on disk so a rooted device or `adb pull` yields
`.enc` blobs, not content. One random 256-bit **data-key** is minted on first use and held in
the platform keystore/keychain; every file is sealed with it. Two independent mechanisms —
**location** (app-internal, unindexed) and **encryption** (AES-GCM) — because either alone is
insufficient.

Feeds `flutter-encrypted-backup` (which escrows this data-key) and
`flutter-file-photo-attachments` (which pipes picked files through this store).

## Contents

1. Two requirements, two mechanisms
2. Dependencies
3. `CryptoService` — seal/open with a keystore-held key
4. Export/import the key (for backup/restore)
5. The file store — app-internal, plaintext-never-on-disk
6. Reading back (memory vs. temp-file consumers)
7. Gotchas

## 1. Two requirements, two mechanisms

| Requirement | Mechanism | Why encryption alone isn't enough |
|---|---|---|
| Invisible to gallery/other apps | **Location**: app-internal storage only | ciphertext files would still be scanned/listed |
| Unreadable if the device is compromised | **AES-256-GCM per file** | app-internal is readable on a rooted device / backup |

- **Location:** write only under `getApplicationDocumentsDirectory()`
  (`/data/data/<pkg>/…` on Android, the app sandbox on iOS). The MediaStore scanner only
  indexes *shared/external* storage — app-internal is never indexed and unreadable by other
  apps without root. **Never** `getExternalStorageDirectory()`, MediaStore, or a `.jpg`/`.png`
  in a scannable folder.
- **Encryption:** AES-256-GCM (authenticated — detects tampering) over every file.

## 2. Dependencies

```yaml
dependencies:
  cryptography_plus: ^3.0.0        # AES-GCM
  flutter_secure_storage: ^9.2.4   # data-key in Keystore/Keychain
  path: ^1.9.1
  path_provider: ^2.1.4
```

## 3. `CryptoService` — seal/open with a keystore-held key

Mint one 256-bit data-key on first use, store its **raw bytes** in secure storage, cache the
`SecretKey` in memory. `SecretBox.concatenation()` gives a single `nonce ‖ ciphertext ‖ tag`
buffer you write straight to a `.enc` file:

```dart
class CryptoService {
  CryptoService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;
  final AesGcm _algorithm = AesGcm.with256bits();
  static const String _keyEntry = 'attachment_data_key_v1'; // versioned for future rotation
  static const int _nonceLength = 12, _macLength = 16;       // AES-GCM layout
  SecretKey? _cached;

  Future<SecretKey> _dataKey() async {
    if (_cached != null) return _cached!;
    final stored = await _storage.read(key: _keyEntry);
    if (stored != null) return _cached = SecretKey(base64Decode(stored));
    final key = await _algorithm.newSecretKey();            // first run: mint + persist
    final bytes = await key.extractBytes();
    await _storage.write(key: _keyEntry, value: base64Encode(bytes));
    return _cached = SecretKey(bytes);
  }

  Future<Uint8List> encrypt(List<int> plaintext) async =>
      (await _algorithm.encrypt(plaintext, secretKey: await _dataKey())).concatenation();

  Future<Uint8List> decrypt(List<int> sealed) async {       // throws on tamper
    final box = SecretBox.fromConcatenation(sealed, nonceLength: _nonceLength, macLength: _macLength);
    return Uint8List.fromList(await _algorithm.decrypt(box, secretKey: await _dataKey()));
  }
}
```

**Why raw bytes we control, not a non-exportable keystore key:** a backup feature needs to
*wrap and escrow* the key (Block Store / iCloud Keychain, or a passphrase). A non-exportable
Keystore key can seal files but can never leave the device, so it could never be recovered on
a new phone. Raw bytes in `flutter_secure_storage` are still Keystore/Keychain-protected at
rest but remain escrowable.

## 4. Export/import the key (for backup/restore)

Two tiny methods make Stage-2 backup purely additive — the key is escrowed inside the
encrypted backup so restored `.enc` files stay readable on a new device:

```dart
Future<String?> exportDataKeyBase64() async =>
    await _storage.read(key: _keyEntry) ??
    (_cached == null ? null : base64Encode(await _cached!.extractBytes()));

Future<void> importDataKeyBase64(String b64) async {         // restore path — overwrites!
  await _storage.write(key: _keyEntry, value: b64);
  _cached = SecretKey(base64Decode(b64));
}
```

`import` **overwrites** the current key — only ever call it as part of a full restore, or
you orphan every file sealed with the old key.

## 5. The file store — app-internal, plaintext-never-on-disk

Wrap `CryptoService` in a store that owns the on-disk layout. The capture pattern is
**read temp → encrypt in memory → write `.enc` → delete the plaintext temp**, so cleartext
never lands on disk:

```dart
class AttachmentStore {
  AttachmentStore({required CryptoService crypto, Directory? root}) : _crypto = crypto, _root = root;
  final CryptoService _crypto;
  Directory? _root;                                          // injectable for tests
  static const String dirName = 'attachments', _ext = '.enc';

  Future<Directory> _rootDir() async => _root ??= await getApplicationDocumentsDirectory();

  Future<String> persistFile(String groupId, String tempPath, {required String storedName}) async {
    final dir = Directory(p.join((await _rootDir()).path, dirName, groupId));
    if (!await dir.exists()) await dir.create(recursive: true);
    final sealed = await _crypto.encrypt(await File(tempPath).readAsBytes());
    await File(p.join(dir.path, '$storedName$_ext')).writeAsBytes(sealed, flush: true);
    return p.join(dirName, groupId, '$storedName$_ext');     // store RELATIVE path
  }
}
```

**Store relative paths** (`attachments/<id>/x.enc`) in your DB, not absolute — the iOS sandbox
container path changes across reinstalls, so an absolute path goes stale. Resolve against the
current documents dir on read. Give each file a **stable unique `storedName`** (e.g. the row
id); naming by list index means a later write overwrites an earlier file.

## 6. Reading back (two consumer shapes)

- **In-memory display** (`Image.memory`, decoded PDF) — decrypt to bytes, never write back:
  ```dart
  Future<Uint8List> readDecrypted(String rel) async =>
      _crypto.decrypt(await File(p.join((await _rootDir()).path, rel)).readAsBytes());
  ```
- **Path consumers** (a PDF viewer, share sheet, `open_filex`) that need a *file path* —
  decrypt to a freshly-named temp in the OS cache dir and delete it when the view closes:
  ```dart
  Future<String> decryptToTemp(String rel, {required String tag, required String suffix}) async {
    final bytes = await readDecrypted(rel);
    final f = File(p.join((await getTemporaryDirectory()).path, 'view', '$tag$suffix'));
    await f.create(recursive: true); await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
  ```

## 7. Gotchas

- **Location AND encryption** — dropping either fails a requirement. App-internal alone is
  readable on a rooted device; encryption alone in a scannable folder still shows up in the
  gallery.
- **Copy-then-delete native temps.** OS document scanners/pickers write plaintext to app cache;
  encrypt then delete it so no cleartext lingers even there.
- **Store relative paths**, resolve on read (iOS container path drift).
- **`import` overwrites the key** — full-restore only.
- **Version the secure-storage key entry** (`_v1`) so a future rotation/escrow scheme migrates
  without colliding.
- **AES-GCM is authenticated** — `decrypt` throws `SecretBoxAuthenticationError` on any
  tamper/corruption; treat that as "unreadable", don't swallow it silently for real data.
- **`encryptedSharedPreferences: true`** on Android options — the modern encrypted backing;
  omit and you get the legacy store.
- **Unique stored names**, not list indices, or edits overwrite files.

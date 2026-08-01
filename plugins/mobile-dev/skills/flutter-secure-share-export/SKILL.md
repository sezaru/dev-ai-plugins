---
name: flutter-secure-share-export
description: Use when a Flutter app must share data via a private encrypted link (upload ciphertext, decryption key in the URL fragment, revoke by deleting the file) or produce a portable unencrypted "export everything" archive with a self-contained HTML viewer — one bundle builder feeding both paths.
---

# Secure share links + portable export

Two related capabilities from one core:

- **Share** — package a slice of the user's data into a self-contained HTML bundle, encrypt it
  with a fresh random key, upload the **ciphertext** to Drive, and hand the recipient a link
  whose **fragment carries the key**. The server never sees the key; deleting the file revokes.
- **Export** — the same bundle, unencrypted, as a browsable zip the user owns outright (no
  lock-in, no network).

Builds on `flutter-google-drive-sync` (upload) and `flutter-encryption-at-rest` (reads the
encrypted attachments back to plaintext for packaging).

## Contents

1. The link model: encrypt-and-forget
2. Dependencies
3. `ShareCodec` — fresh key per share, browser-decryptable
4. The self-contained viewer bundle
5. `prepare` vs. `upload` (size gate before network)
6. Revoke, record, manage
7. Export: the same bundle, in the clear
8. Gotchas

## 1. The link model: encrypt-and-forget

The recipient opens a static loader page; the URL **fragment** (after `#`) holds the Drive file
id + the AES key. The loader fetches the ciphertext from Drive, decrypts it in the browser with
WebCrypto, and renders. Crucially:

- **The fragment is never sent to any server** (browsers don't transmit `#…`), so the key stays
  between the two parties who have the link.
- **Whoever has the link can decrypt** — the key *is* the secret. This is the right model for
  "send my records to a doctor": no accounts, no recipient login.
- **Revocation = delete the Drive file.** The link then resolves to nothing.

```
https://loader.example.app/#<base64url(JSON({f: driveFileId, k: key}))>
```

## 2. Dependencies

```yaml
dependencies:
  cryptography_plus: ^3.0.0
  # + your Drive layer (see flutter-google-drive-sync) and archive/zip (see below)
```

## 3. `ShareCodec` — fresh key per share, browser-decryptable

Unlike backup (owner-held password + Argon2id), a share is opened by someone who only has the
link — so **generate a fresh random AES-256-GCM key per share** and emit the **bare GCM
concatenation** (`nonce(12) ‖ ciphertext ‖ tag(16)`), no custom envelope, so the browser reads
it directly:

```dart
class SealedShare { final Uint8List bytes; final Uint8List key; } // key -> link fragment, never uploaded

Future<SealedShare> seal(Uint8List archive) async {
  final secretKey = await AesGcm.with256bits().newSecretKey();
  final keyBytes = Uint8List.fromList(await secretKey.extractBytes());
  // pure-Dart AES-GCM janks the UI isolate on a multi-MB archive — run it on a background isolate.
  // A SecretKey can't cross an isolate boundary; pass raw bytes and rebuild it there.
  final bytes = await Isolate.run(() => _encrypt(archive, keyBytes));
  return SealedShare(bytes: bytes, key: keyBytes);
}
static Future<Uint8List> _encrypt(Uint8List archive, Uint8List keyBytes) async =>
    Uint8List.fromList((await AesGcm.with256bits().encrypt(archive, secretKey: SecretKey(keyBytes))).concatenation());
```

The loader decrypts with:
`crypto.subtle.decrypt({name:'AES-GCM', iv: bytes.slice(0,12)}, key, bytes.slice(12))`.

## 4. The self-contained viewer bundle

Package the data as a zip: a static `viewer.html` (bundled asset) + the decrypted attachment
files under `files/…`. Inject the record data as JSON at a marker in the template — **escape
`<`** so a title containing `</script>` can't break out:

```dart
String _injectData(String template, Map<String, Object?> data) =>
    template.replaceFirst('/*__DATA__*/', 'window.__DATA__ = ${jsonEncode(data).replaceAll('<', r'<')};');
```

Put the **bundle builder in one reusable method** (`buildBundle` → zip entries + headline
counts). Both the share path and the export path call it — so a record opened from an export
renders identically to one opened from a share, minus the encryption. Reading each attachment
goes through `flutter-encryption-at-rest`'s `readDecrypted`; a missing/corrupt file must
`continue`, never sink the whole bundle.

## 5. `prepare` vs. `upload` (size gate before network)

Split the CPU-bound packaging from the network so the UI can confirm a large upload first:

```dart
Future<PreparedShare> prepare(...) async {
  final entries = (await buildBundle(...)).entries;
  return PreparedShare(zipBytes: await Isolate.run(() => buildZip(entries)), fileCount: entries.length);
} // no network — caller inspects sizeBytes and confirms

Future<ShareResult> upload({required PreparedShare prepared, required String shareId, ...}) async {
  onProgress?.call(1);
  final sealed = await _codec.seal(prepared.zipBytes);                 // encrypt
  onProgress?.call(2);
  if (!await _drive.isAvailable()) await _drive.connect();             // interactive if needed
  final fileId = await _drive.uploadPublic(sealed.bytes, name: _archiveName(...),
      onProgress: (sent, total) => onUploadProgress?.call(total == 0 ? 1 : sent / total));
  onProgress?.call(3);
  final key = base64Url.encode(sealed.key);
  await _repos.shares.insert(Share(id: shareId, driveFileId: fileId, decryptionKey: key, ...)); // record it
  return ShareResult(link: linkFor(driveFileId: fileId, decryptionKey: key));
}
```

`buildZip` (deflate each entry, level 6) is pure-Dart CPU work — run it on `Isolate.run` too so
the "packaging" spinner doesn't jank.

## 6. Revoke, record, manage

- **Record every share** in a table (`shares`: id, source id, driveFileId, decryptionKey,
  createdAt, sizeBytes, range/filters). This powers a "manage shares" screen.
- **Revoke = delete the Drive file** (`_drive.delete(driveFileId)`) and remove the row. The link
  dies immediately.
- Store the key in your DB so the owner can re-copy the link later; it's on-device only.

## 7. Export: the same bundle, in the clear

Export is share minus encryption and network: iterate every record set, call the **same
`buildBundle`**, nest each under its own browsable root folder (`<slug>_<id>/`), add a landing
`index.html` (a static asset with the list injected at `/*__DATA__*/`), and zip it. The result
opens straight from a file manager — the whole point is a portable copy the user owns with no
lock-in. Offer it through the OS "save-as" dialog.

```dart
for (final set in sets) {
  final bundle = await _share.buildBundle(set: set, isExport: true, ...);
  for (final e in bundle.entries) entries.add(ShareZipEntry('${folder(set)}/${e.name}', e.bytes));
}
entries.insert(0, ShareZipEntry('index.html', utf8.encode(_injectData(landingTemplate, listData))));
return ExportArchive(zipBytes: ShareService.buildZip(entries), ...);
```

Provide a cheap `summarize()` (counts only, no decryption/zip) for a pre-flight consent sheet;
the exact figures come from the real build.

## 8. Gotchas

- **Key in the fragment, never uploaded** — `#…` isn't sent to servers; that's the whole
  security model. Upload only ciphertext.
- **Fresh random key per share** (not a derived/owner key) — the recipient has no password.
- **Bare GCM concatenation output** so the browser's WebCrypto decrypts it with no custom parser.
- **Encrypt and zip on a background isolate** — pure-Dart AES-GCM/deflate janks the UI on
  multi-MB archives; pass raw key bytes across (a `SecretKey` can't cross the boundary).
- **Escape `<` when injecting JSON** into the HTML template (XSS / script-breakout).
- **A bad attachment must `continue`**, not throw — one corrupt page shouldn't sink the bundle.
- **Split `prepare` (offline, sized) from `upload` (network)** so the user confirms big uploads.
- **Revoke by deleting the file**; record shares in a table to manage/re-copy/revoke them.
- **Export is unencrypted by design** — it's the user's own copy; don't add friction, but do
  gate it behind a clear consent sheet since it decrypts everything.

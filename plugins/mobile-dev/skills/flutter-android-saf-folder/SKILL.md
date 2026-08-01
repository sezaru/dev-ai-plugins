---
name: flutter-android-saf-folder
description: Use when a Flutter app must write files into a user-chosen Android folder that survives an app-data clear and is reachable from a headless/background isolate (e.g. scheduled backups) — Storage Access Framework with a persisted tree-permission grant, packaged as a local plugin so it auto-registers on background engines.
---

# Android Storage Access Framework folder (persisted, headless-capable)

Let the user pick a real folder once (Downloads, an SD card, a synced folder) and write into it
forever after — including from a background alarm isolate with the app closed. Unlike
app-private storage, an SAF folder is **user-browsable** and **survives an app-data clear** (the
very thing a backup guards against). Android-only.

Pairs with `flutter-encrypted-backup` (the `BackupStore` destination that uses it) and
`flutter-home-screen-widgets` (the headless-isolate scheduling it must work under).

## Contents

1. Why SAF, and why a *local plugin*
2. The Dart method-channel API
3. Native plugin — ActivityAware only for the picker
4. Pick a folder (foreground) + persist permission
5. Read/write/list/delete (headless-capable)
6. Wrapping it as a backup destination
7. Gotchas

## 1. Why SAF, and why a *local plugin*

- **Chosen folder, not app-private storage.** App-private `<docs>/` isn't user-browsable and is
  **wiped by an app-data clear** — so a *scheduled* backup there protects almost nothing. The
  system "save to…" dialog needs UI and can't run headless. SAF's `OPEN_DOCUMENT_TREE` gives a
  **persisted** grant to a user-picked folder that both foreground and background writes reuse.
- **Package it as a local plugin (path dependency), not a `MainActivity` MethodChannel.** A path
  plugin lands in `GeneratedPluginRegistrant`, so it **auto-registers on every Flutter engine —
  including the `android_alarm_manager_plus` headless engine**. An app-local `MainActivity`
  channel would *not* reach that background engine, so a scheduled write would have no way to
  call it. (This is exactly why `home_widget` is a plugin too.)

```
packages/saf_backup/
  pubspec.yaml            # declares the plugin platform: android + pluginClass
  lib/saf_backup.dart     # Dart MethodChannel wrapper
  android/src/main/kotlin/.../SafBackupPlugin.kt
```

In the app `pubspec.yaml`: `saf_backup: { path: packages/saf_backup }`.

## 2. The Dart method-channel API

A thin static wrapper — one channel, typed results:

```dart
class SafBackup {
  static const _channel = MethodChannel('<your.app>/saf_backup');

  /// Foreground only (needs an Activity). Returns the tree uri + display name, or null if cancelled.
  static Future<({String uri, String name})?> pickFolder() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('pickFolder');
    final uri = res?['uri'] as String?;
    return uri == null ? null : (uri: uri, name: (res?['name'] as String?) ?? uri);
  }

  /// Whether we STILL hold persisted write permission (the user can revoke it).
  static Future<bool> hasPermission(String treeUri) async =>
      (await _channel.invokeMethod<bool>('hasPermission', {'uri': treeUri})) ?? false;

  /// Works headless. Overwrites a same-named file; returns the created document uri.
  static Future<String> writeFile({required String treeUri, required String name, required Uint8List bytes,
      String mime = 'application/octet-stream'}) async =>
      (await _channel.invokeMethod<String>('writeFile', {'tree': treeUri, 'name': name, 'bytes': bytes, 'mime': mime}))!;

  static Future<List<SafEntry>> listFiles(String treeUri, {String suffix = ''}) async { /* map -> SafEntry */ }
  static Future<Uint8List> readFile(String uri) async { /* ... */ }
  static Future<bool> deleteFile(String uri) async => (await _channel.invokeMethod<bool>('deleteFile', {'uri': uri})) ?? false;
}
```

Persist the returned **tree uri** (e.g. in your settings DB) — that's what every later
write/list/read reuses.

## 3. Native plugin — ActivityAware only for the picker

Implement `FlutterPlugin` + `ActivityAware` + `MethodCallHandler` + `ActivityResultListener`.
Grab `applicationContext` in `onAttachedToEngine` (this is what makes read/write/list/delete
work headless); only the folder **picker** needs the Activity:

```kotlin
override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
  appContext = b.applicationContext                          // used by all data ops (headless)
  channel = MethodChannel(b.binaryMessenger, "<your.app>/saf_backup").apply { setMethodCallHandler(this@…) }
}
override fun onAttachedToActivity(b: ActivityPluginBinding) {  // only for pickFolder
  activity = b.activity; b.addActivityResultListener(this)
}
```

## 4. Pick a folder (foreground) + persist permission

`ACTION_OPEN_DOCUMENT_TREE` with the persistable-permission flag, then
`takePersistableUriPermission` in `onActivityResult` — this is what makes the grant survive
process death and reboots:

```kotlin
val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
  addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
      or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
}
activity.startActivityForResult(intent, OPEN_TREE)

// onActivityResult:
val treeUri = data?.data ?: return result.success(null)      // cancelled
appContext.contentResolver.takePersistableUriPermission(treeUri,
    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
val name = DocumentFile.fromTreeUri(appContext, treeUri)?.name ?: treeUri.toString()
result.success(mapOf("uri" to treeUri.toString(), "name" to name))
```

**Re-check the grant at use time** — the user can revoke it in system settings:

```kotlin
fun hasPermission(uri: Uri) = appContext.contentResolver.persistedUriPermissions
    .any { it.uri == uri && it.isWritePermission }
```

## 5. Read/write/list/delete (headless-capable)

All via `DocumentFile` on the `appContext` — no Activity, so they run from the alarm isolate:

```kotlin
// write (overwrite same name)
val dir = DocumentFile.fromTreeUri(appContext, Uri.parse(tree))!!
dir.findFile(name)?.delete()
val file = dir.createFile(mime, name)!!
appContext.contentResolver.openOutputStream(file.uri)!!.use { it.write(bytes) }

// list with suffix filter, newest-first by name
dir.listFiles().filter { it.isFile && (suffix.isEmpty() || it.name?.endsWith(suffix) == true) }
   .map { mapOf("uri" to it.uri.toString(), "name" to it.name, "size" to it.length(), "modified" to it.lastModified()) }

// read / delete via content resolver / DocumentFile.fromSingleUri(...).delete()
```

## 6. Wrapping it as a backup destination

Implement the same `BackupStore` interface as the local/Drive destinations, so the scheduler
treats all three identically:

```dart
class SafFolderDestination implements BackupStore {
  SafFolderDestination(this.treeUri);
  final String treeUri;
  Future<bool> isAvailable() => SafBackup.hasPermission(treeUri);          // gates the UI
  Future<BackupEntry> store(Uint8List bytes, {required String stamp, int keep = 3}) async {
    final uri = await SafBackup.writeFile(treeUri: treeUri, name: 'backup-$stamp.cmbak', bytes: bytes);
    await _prune(keep);                                                     // list, delete .skip(keep)
    return BackupEntry(id: uri, name: 'backup-$stamp.cmbak', sizeBytes: bytes.length);
  }
  // list/fetch/delete delegate to SafBackup.*; sort newest-first by the YYYY-MM-DD name stamp
}
```

Persist the chosen folder uri/name in settings; the scheduler's `canRunUnattended` should
**require a chosen folder** for the phone destination and **re-check `hasPermission` at fire
time** (skip + log if revoked).

## 7. Gotchas

- **Must be a plugin (path dep), not a MainActivity channel** — only then does it register on
  the headless background engine.
- **`takePersistableUriPermission`** — without it the grant dies with the process; you'd
  re-prompt every launch and headless writes would fail.
- **Re-check `hasPermission` before every scheduled write** — the user can revoke it, or the
  folder (SD card) can be removed.
- **`applicationContext` for data ops, Activity only for the picker** — using the Activity for
  writes would break the headless path.
- **Persist the tree uri**, not a filesystem path — SAF gives you content uris, not paths.
- **Overwrite by find-then-delete** before `createFile`, or SAF makes `name (1).ext` duplicates.
- **Android-only** — guard the whole feature off other platforms.
- **`FLAG_GRANT_PERSISTABLE_URI_PERMISSION` on the intent** *and* `takePersistableUriPermission`
  after — both are required.

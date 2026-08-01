---
name: flutter-google-drive-sync
description: Use when a Flutter app needs to upload/download files to the user's own Google Drive — google_sign_in v7 (auth vs. authorization split) + googleapis Drive v3, drive.file scope, visible app folder, and a silent-vs-interactive client seam for background sync. Covers the v7 Android serverClientId gotcha.
---

# Google Drive sync (google_sign_in v7 + googleapis)

Read/write files in the **user's own** Google Drive with per-file (`drive.file`) scope — the
storage side of a backup or share feature. Uploads land in a browsable `AppName/` folder the
user can tidy, and a clean auth seam separates **silent** (background) from **interactive**
(foreground) clients. Google only ever holds whatever bytes you upload — seal them first.

Pairs with `flutter-encrypted-backup` and `flutter-secure-share-export` (the sealed bytes it
moves), which reach it through the `BackupStore`/destination interface.

## Contents

1. Console setup (the part that breaks first)
2. Dependencies
3. The v7 model: authentication vs. authorization
4. The Android `serverClientId` gotcha
5. The auth seam — silent vs. interactive client
6. Scope choice: `drive.file` + a visible folder
7. Upload / list / download / delete
8. Find-or-create folders
9. Gotchas

## 1. Console setup (the part that breaks first)

In the Google Cloud Console (one project):

- **OAuth consent screen** — configure it; while in *Testing*, add each tester's Google
  account as a **test user**, or sign-in fails with `access_denied`.
- **Android OAuth client** — created from your **package name + signing SHA-1** (debug and
  release SHA-1s both). It has no ID you pass in code; Google matches the app by it. No
  `google-services.json` needed for this (that's for Firebase).
- **Web OAuth client** — you *do* need its client ID string (see §4).
- Enable the **Google Drive API** for the project.

## 2. Dependencies

```yaml
dependencies:
  google_sign_in: ^7.2.0
  googleapis: ^16.0.0
  extension_google_sign_in_as_googleapis_auth: ^3.0.0
  http: ^1.6.0
```

## 3. The v7 model: authentication vs. authorization

`google_sign_in` **v7** splits the old single call into two phases:

- **Authentication** — *who* the user is (identity). `authenticate()` /
  `attemptLightweightAuthentication()`.
- **Authorization** — *what* they granted (scopes / access token).
  `account.authorizationClient.authorizeScopes([...])` (may prompt) or
  `.authorizationForScopes([...])` (silent, returns null if not yet granted).

Turn an authorization into a `googleapis`-ready HTTP client with the extension's
`authz.authClient(scopes: ...)`.

## 4. The Android `serverClientId` gotcha

On Android, v7 sits on Credential Manager / Google Identity Services, which **requires the
*Web* OAuth client ID** even for purely on-device, client-side access:

```dart
await GoogleSignIn.instance.initialize(serverClientId: _webClientId); // once per isolate
```

Pass `null` and `initialize()` throws `clientConfigurationError: serverClientId must be
provided on Android`. The **Web client ID is not a secret** — it's an audience identifier that
ships in every APK and is trivially extractable, so hard-coding a default is fine; allow a
`--dart-define` override for pointing builds at different Cloud projects. (Never ship the Web
client *secret* — it isn't used here.)

```dart
const String _webClientId = String.fromEnvironment('GOOGLE_DRIVE_SERVER_CLIENT_ID',
    defaultValue: '448127…apps.googleusercontent.com');
```

## 5. The auth seam — silent vs. interactive client

Isolate all Google types behind an interface so it fakes in tests and so "not connected" is a
single well-defined state. **Silent** = no UI (background sync + availability checks);
**interactive** = may prompt (foreground connect):

```dart
abstract interface class DriveAuth {
  Future<bool> isSignedIn();
  Future<http.Client?> silentClient();      // null if connecting needs interaction
  Future<http.Client> interactiveClient();  // foreground only; throws on cancel
  Future<void> signOut();
}

class GoogleDriveAuth implements DriveAuth {
  GoogleDriveAuth({List<String> scopes = const [drive.DriveApi.driveFileScope]}) : _scopes = scopes;
  final List<String> _scopes;
  Future<void>? _init;
  Future<void> _ensureInit() => _init ??= GoogleSignIn.instance.initialize(serverClientId: _webClientId);

  @override Future<http.Client?> silentClient() async {
    await _ensureInit();
    final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
    if (account == null) return null;
    final authz = await account.authorizationClient.authorizationForScopes(_scopes);
    return authz?.authClient(scopes: _scopes);   // null if scopes not yet granted
  }

  @override Future<http.Client> interactiveClient() async {
    await _ensureInit();
    if (!GoogleSignIn.instance.supportsAuthenticate()) throw StateError('interactive sign-in unsupported here');
    final account = await GoogleSignIn.instance.authenticate(scopeHint: _scopes);
    final authz = await account.authorizationClient.authorizeScopes(_scopes);
    return authz.authClient(scopes: _scopes);
  }
}
```

`initialize()` must run **exactly once per isolate** before any other call — the `_init ??=`
memoization guarantees that (important: a background alarm isolate is a *different* isolate and
must init again).

## 6. Scope choice: `drive.file` + a visible folder

Use `drive.DriveApi.driveFileScope` (`drive.file`) — **per-file** access limited to files your
app creates. Never ask for full Drive access. Put uploads in a **visible** `AppName/` folder at
the user's Drive root (not the hidden `appDataFolder`) so users can see/move/delete their own
data; `drive.file` still confines every `files.list` to *your* files, so you never see the rest
of their Drive. One `drive.file` consent can then cover multiple features (backups + shares).

## 7. Upload / list / download / delete

Get a client from the seam, build `drive.DriveApi(client)`, **always `client.close()` in a
`finally`**:

```dart
Future<http.Client> _client() async =>
    await _auth.silentClient() ?? (throw const BackupNotConfiguredException('Sign in first.'));

Future<BackupEntry> store(Uint8List bytes, {required String stamp, int keep = 3}) async {
  final client = await _client();
  try {
    final api = drive.DriveApi(client);
    final folderId = await DriveFolders.backups(api);
    final created = await api.files.create(
      drive.File(name: 'backup-$stamp.cmbak', parents: [folderId]),
      uploadMedia: drive.Media(Stream.value(bytes), bytes.length),
      $fields: 'id,name,size,modifiedTime',
    );
    await _prune(api, folderId, keep);
    return _entryOf(created, fallbackSize: bytes.length); // size may be absent in create resp
  } finally { client.close(); }
}
```

- **List:** `api.files.list(orderBy: 'modifiedTime desc', q: "'<folderId>' in parents and name
  contains '.cmbak' and trashed = false", $fields: 'files(id,name,size,modifiedTime)')`.
- **Download:** `api.files.get(id, downloadOptions: drive.DownloadOptions.fullMedia) as
  drive.Media`, then concatenate `media.stream`.
- **Delete / prune:** `api.files.delete(id)`; list newest-first and delete `.skip(keep)`,
  best-effort.
- Request `$fields` explicitly — Drive omits `size` etc. otherwise. Parse `f.size` (a String)
  with `int.tryParse`.

## 8. Find-or-create folders

Resolve folders per call (cheap: one `files.list`, plus one create the first time). **Don't
cache the folder id** — the user may delete/move it in Drive; re-resolving silently recreates
it:

```dart
static Future<String> _childFolder(drive.DriveApi api, String parentId, String name) async {
  final safe = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");     // escape query string
  final found = await api.files.list(
    q: "mimeType = 'application/vnd.google-apps.folder' and trashed = false "
       "and name = '$safe' and '$parentId' in parents",
    $fields: 'files(id)', pageSize: 1);
  if (found.files?.isNotEmpty ?? false) return found.files!.first.id!;
  final created = await api.files.create(
    drive.File(name: name, mimeType: 'application/vnd.google-apps.folder', parents: [parentId]),
    $fields: 'id');
  return created.id!;
}
```

## 9. Gotchas

- **`serverClientId` (Web client ID) is mandatory on Android v7** — the #1 setup failure.
- **`initialize()` once per isolate** — memoize; re-init in a background isolate.
- **Auth ≠ authorization in v7** — authenticate first, then `authorizeScopes` (interactive) or
  `authorizationForScopes` (silent, may be null).
- **Add testers as test users** while the consent screen is in Testing, or `access_denied`.
- **Register both debug and release SHA-1** for the Android OAuth client, or sign-in fails only
  in one build type.
- **`client.close()` in `finally`** every operation — leaked clients leak sockets.
- **Request `$fields`** explicitly; Drive omits metadata otherwise.
- **Don't cache folder ids**; re-resolve (user can delete the folder).
- **Silent client returns null**, doesn't throw, when interaction is needed — map that to your
  "not connected" state and offer `interactiveClient()`.
- **Background/headless silent refresh is best-effort** — Play-services token refresh in a
  headless isolate isn't guaranteed; skip-and-log if `silentClient()` is null there.
- **Seal before upload** — Drive holds exactly what you send; upload ciphertext only.

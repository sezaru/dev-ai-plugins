---
name: flutter-local-notifications-reminders
description: Use when a Flutter app needs scheduled local reminders — exact-time zoned notifications that survive reboot and Doze, action buttons handled in a background isolate, cold-start tap routing, a pure testable planner, stable ids for idempotent re-sync, and staying under the iOS 64-pending limit.
---

# Local notifications & exact reminders

Schedule reminders that fire at a precise instant even in Doze, survive a reboot, carry action
buttons handled without opening the app, and route taps to the right screen. A **pure planner**
computes the set; a thin scheduler registers it idempotently. Proven in caremate for appointment
+ medication-dose reminders.

Pairs with `flutter-sqlite-ffi-fts5` (the background-isolate DB rule) and
`flutter-home-screen-widgets` (a background action can refresh a widget).

## Contents

1. Dependencies & manifest
2. Init: timezone + channel + categories + callbacks
3. Permissions
4. Scheduling one exact alarm
5. Action buttons (Android per-notification vs iOS category)
6. Handling responses: foreground streams, cold start, background isolate
7. The pure planner + idempotent sync
8. Staying under the pending-alarm budget
9. Gotchas

## 1. Dependencies & manifest

```yaml
dependencies:
  flutter_local_notifications: ^22.0.1
  timezone: ^0.11.0
  flutter_timezone: ^5.1.0
```

Android manifest: the plugin's `ScheduledNotificationBootReceiver` + exact-alarm permission
(`USE_EXACT_ALARM` / `SCHEDULE_EXACT_ALARM`) and `POST_NOTIFICATIONS`. The boot receiver is what
re-registers persisted alarms after a reboot **without the app being opened**.

## 2. Init: timezone + channel + categories + callbacks

`zonedSchedule` needs a real local timezone. Initialize once, idempotently:

```dart
Future<void> init({required String channelName, required String channelDescription, ...}) async {
  if (_ready) return;
  tzdata.initializeTimeZones();
  try { tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier)); }
  catch (_) { /* leave tz.local at UTC if the platform can't report a zone */ }

  final darwin = DarwinInitializationSettings(notificationCategories: [
    DarwinNotificationCategory('dose', actions: [                    // iOS actions live in a category
      DarwinNotificationAction.plain(actionTake, takeLabel),
      DarwinNotificationAction.plain(actionSkip, skipLabel),
    ]),
  ]);
  await _plugin.initialize(
    settings: InitializationSettings(android: const AndroidInitializationSettings('@mipmap/ic_launcher'), iOS: darwin),
    onDidReceiveNotificationResponse: _onResponse,                   // foreground
    onDidReceiveBackgroundNotificationResponse: doseActionBackgroundCallback, // background isolate
  );
  await _android?.createNotificationChannel(AndroidNotificationChannel(
      'reminders', channelName, description: channelDescription, importance: Importance.high));
  _ready = true;
}
```

## 3. Permissions

```dart
await _android?.requestNotificationsPermission();     // POST_NOTIFICATIONS (Android 13+)
await _android?.requestExactAlarmsPermission();        // no-op if USE_EXACT_ALARM granted
await _ios?.requestPermissions(alert: true, badge: true, sound: true);
```

## 4. Scheduling one exact alarm

`AndroidScheduleMode.exactAllowWhileIdle` maps to `setExactAndAllowWhileIdle` — fires at the
precise instant even in Doze. `matchDateTimeComponents: DateTimeComponents.time` makes it repeat
daily at that clock time:

```dart
Future<void> schedule({required int id, required String title, required String body,
    required DateTime fireAt, required bool daily, String? payload, bool withActions = false}) =>
  _plugin.zonedSchedule(
    id: id,
    scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
    notificationDetails: _detailsFor(withActions: withActions),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    title: title, body: body.isEmpty ? null : body, payload: payload,
    matchDateTimeComponents: daily ? DateTimeComponents.time : null,
  );
```

## 5. Action buttons (two platform shapes)

Android attaches actions **per notification**; iOS reads them from the **pre-registered
category**. `showsUserInterface: false` handles the tap silently (no app launch);
`cancelNotification: true` clears it:

```dart
NotificationDetails _detailsFor({required bool withActions}) => NotificationDetails(
  android: AndroidNotificationDetails('reminders', _channelName, importance: Importance.high,
    actions: withActions ? [
      AndroidNotificationAction(actionTake, _takeLabel, showsUserInterface: false, cancelNotification: true),
      AndroidNotificationAction(actionSkip, _skipLabel, showsUserInterface: false, cancelNotification: true),
    ] : null),
  iOS: DarwinNotificationDetails(categoryIdentifier: withActions ? 'dose' : null),
);
```

## 6. Handling responses: foreground, cold start, background

Three distinct paths:

- **Foreground** — one callback routes by whether an `actionId` is present (→ an action stream)
  or not (→ a tap stream for navigation):
  ```dart
  void _onResponse(NotificationResponse r) {
    if (r.actionId?.isNotEmpty ?? false) _actions.add((actionId: r.actionId!, payload: r.payload));
    else if (r.payload?.isNotEmpty ?? false) _taps.add(r.payload!);
  }
  ```
- **Cold start** — the tap that launched the app:
  ```dart
  Future<String?> launchPayload() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    return (d?.didNotificationLaunchApp ?? false) ? d!.notificationResponse?.payload : null;
  }
  ```
- **Background isolate** — an action tapped while the app is terminated/backgrounded runs in a
  **headless isolate with no app state**. It must open its **own** DB (FFI factory selected
  again; `singleInstance: false` so closing it can't slam the foreground's shared connection),
  do the work, and close. Annotate `@pragma('vm:entry-point')` for AOT retention:
  ```dart
  @pragma('vm:entry-point')
  Future<void> doseActionBackgroundCallback(NotificationResponse response) async {
    final target = ReminderPayload.decode(response.payload);
    if (response.actionId == null || target == null) return;
    WidgetsFlutterBinding.ensureInitialized();
    initSqliteFfi();                                  // this isolate must select FFI too
    final db = await AppDatabase.open(singleInstance: false);  // private connection
    try { await applyAction(AppRepositories(db), target, response.actionId!); }
    finally { await db.close(); }
  }
  ```
  Keep the actual write logic (`applyAction`) as a plain function shared with the foreground
  path, so a notification action and the in-app button produce identical rows (share the id
  scheme).

## 7. The pure planner + idempotent sync

Separate **what to schedule** (pure, testable, no plugin/I/O) from **registering it**:

```dart
// pure: data in -> reminders out. No plugin, no db. Unit-tested.
List<PlannedReminder> planReminders({required DateTime now, required List<Event> appts, ...}) { ... }

// thin: load data, plan, re-register. Idempotent — cancel all, then schedule the fresh set.
Future<void> syncAll({required DateTime now, required ReminderStrings strings}) async {
  final planned = planReminders(now: now, appts: await repos.events.all(), ...);
  await notifications.cancelAll();
  for (final r in planned) await notifications.schedule(id: r.id, ...);
}
```

Give each reminder a **stable id** derived from a semantic key (FNV-1a hash → 31-bit int), so a
re-sync *replaces* the same reminder instead of duplicating it:

```dart
int _idFor(String key) { var h = 0x811c9dc5; for (final c in key.codeUnits) { h ^= c; h = (h * 0x01000193) & 0xFFFFFFFF; } return h & 0x7FFFFFFF; }
```

Call `syncAll` on launch and after any mutation that changes the reminder picture. Thread
localized copy in via a `ReminderStrings` struct so the planner stays l10n-free.

## 8. Staying under the pending-alarm budget

**iOS caps pending notifications at 64.** Don't schedule an unbounded future. Instead:

- Materialize a **rolling horizon** of one-shot alarms (e.g. 14 days of doses), and roll it
  forward with a **daily background re-sync**. One-shots-per-day also give correct per-day
  content (a finite medication simply stops appearing) — a single infinite repeating alarm would
  outlive the data it describes.
- **Budget the set** (e.g. `kMaxTotalAlarms = 60`), sort by soonest, and drop the overflow; the
  re-sync surfaces later ones as time passes.

## 9. Gotchas

- **`initializeTimeZones()` + `setLocalLocation`** before `zonedSchedule`, or it throws / fires
  in the wrong zone.
- **`exactAllowWhileIdle`** for real exact timing; the default inexact mode drifts in Doze.
- **Background action isolate has no app state** — `WidgetsFlutterBinding.ensureInitialized()`,
  re-select the sqflite FFI factory, open a **private** DB (`singleInstance: false`), close in
  `finally`; never touch the foreground's shared connection.
- **`@pragma('vm:entry-point')`** on the background callback or AOT strips it and it never fires.
- **Stable ids** so re-sync replaces, not duplicates.
- **Stay under 64 pending** (iOS) — rolling horizon + daily re-sync + a budget, not infinite
  schedules.
- **Android actions per-notification, iOS actions in a category** — you must supply both.
- **Cold-start tap** comes from `getNotificationAppLaunchDetails`, not the runtime stream — check
  it once after init.
- **Share the write logic** between foreground and background action paths (same id scheme) so
  the two stay consistent and undo works across both.

---
name: flutter-home-screen-widgets
description: Use when adding Android (or iOS) home-screen widgets to a Flutter app — push data from Dart via home_widget shared prefs to native RemoteViews providers, keep them current while the app is closed with an exact android_alarm_manager_plus alarm chain, theme them, and avoid redraw flicker.
---

# Home-screen widgets (data-pushed, self-updating while closed)

Render native home-screen widgets fed by your Flutter data. Flutter never draws the widget — it
formats the content as JSON, hands it to the native side via `home_widget`'s shared prefs, and
the native RemoteViews providers render it. An exact alarm chain keeps them current at day/event
boundaries **even when the app is never opened**.

Reuses the alarm-isolate pattern shared with `flutter-encrypted-backup` scheduling and the
background-DB rule from `flutter-sqlite-ffi-fts5`.

## Contents

1. The split: Flutter formats, native renders
2. Dependencies
3. `WidgetService.refresh` — read, format, push
4. Theming a native widget
5. Redraw only what changed (flicker control)
6. Staying current while closed: the alarm chain
7. The headless callback
8. Gotchas

## 1. The split: Flutter formats, native renders

- **Native side** — `AppWidgetProvider`s (RemoteViews) + a `RemoteViewsFactory` for list
  widgets. They read string keys from the plugin's shared prefs and inflate layouts. Interactive
  taps come back through `home_widget`'s background callback / `PendingIntent`.
- **Flutter side** — a `WidgetService` reads your repositories, builds a time-ordered feed / next
  item / mini-month as JSON, and saves each under a key. **It renders nothing.**

Widgets set `updatePeriodMillis = 0` (the system's own refresh is coarse and unreliable) — so
*you* own when they rebuild (§6).

## 2. Dependencies

```yaml
dependencies:
  home_widget: ^0.7.0                 # Dart <-> native widget bridge (shared prefs)
  android_alarm_manager_plus: ^5.0.0  # exact background alarm to rebuild while closed
```

`home_widget` is a plugin, so it auto-registers on the background alarm engine (the same reason
`flutter-android-saf-folder` is a plugin) — the headless rebuild can push data.

## 3. `WidgetService.refresh` — read, format, push

Reads straight from the repositories (no UI controllers), so it runs on launch, after any
mutation, and from the headless isolate. Best-effort and coalesced:

```dart
Future<void> refresh() async {
  if (_running) return; _running = true;
  try {
    final data = await _gather(await repos.settings.load());
    nextWakeAt = _nextWake(data, DateTime.now());        // when the next rebuild is needed
    await HomeWidget.saveWidgetData<String>('agenda_json', data.toAgendaJson());
    await HomeWidget.saveWidgetData<String>('next_json', data.toNextJson());
    // … push each view's JSON …
    // redraw only providers whose content changed (see §5)
  } catch (e, st) {
    debugPrint('[widget] refresh failed: $e\n$st');       // never crash the app for a widget
  } finally { _running = false; }
}
```

Expose `nextWakeAt` (the next instant the widget must rebuild even if the app never opens) for
the scheduler to arm.

## 4. Theming a native widget

The native side can't read your Flutter theme. Push a full color set — **every palette ×
brightness** — as JSON so a widget configured to a theme different from the app's active one
still resolves its colors natively:

```dart
for (final p in MhcPalette.values) {
  await HomeWidget.saveWidgetData('colors_${p.name}_light', _colorsJson(MhcTokens.resolve(p, Brightness.light)));
  await HomeWidget.saveWidgetData('colors_${p.name}_dark',  _colorsJson(MhcTokens.resolve(p, Brightness.dark)));
}
await HomeWidget.saveWidgetData('app_palette', settings.palette);   // the "App" (follow-app) option
await HomeWidget.saveWidgetData('app_mode', settings.themeMode);
```

Serialize colors as `#AARRGGBB` strings the native factory parses (mirror this in
`flutter-admob-native-ads`' native card).

## 5. Redraw only what changed (flicker control)

A full RemoteViews update re-inflates the widget — a visible flicker. Redraw a provider **only
when its visible content changed**, keyed by a signature digest (fold the theme in so a
palette/mode switch still repaints):

```dart
Future<void> _updateIfChanged(String provider, String sigKey, String sig) async {
  if (await HomeWidget.getWidgetData<String>(sigKey) == sig) return;   // nothing changed
  await HomeWidget.saveWidgetData<String>(sigKey, sig);
  await HomeWidget.updateWidget(name: provider);
}
// e.g. only the list provider redraws when the agenda changes, not the month grid:
await _updateIfChanged('ListWidgetProvider', 'sig_list', '$agendaJson|${data.headerDate}|$themeSig');
```

The data is always *saved* first, so a widget that redraws for another reason (placement, resize,
a day tap) still reads the latest content; this only suppresses the *proactive* re-inflate.

## 6. Staying current while closed: the alarm chain

Nothing recomputes when the clock crosses midnight or an event's time passes. Arm an **exact**
`AlarmManager` alarm for the next such boundary; when it fires, rebuild and **re-arm the next
one** — a self-perpetuating chain that survives Doze and reboot:

```dart
static const int _alarmId = 0x0CA2E;   // fixed id: re-arming with the same id replaces the pending alarm
static Future<void> init() async { if (Platform.isAndroid) await AndroidAlarmManager.initialize(); }
static Future<void> arm(DateTime when) async {
  if (!Platform.isAndroid) return;
  await AndroidAlarmManager.oneShotAt(when, _alarmId, widgetAlarmCallback,
      exact: true, wakeup: true, allowWhileIdle: true, rescheduleOnReboot: true);
}
```

Call `arm(service.nextWakeAt)` after every foreground refresh too, so the next wake always
matches current data.

## 7. The headless callback

Top-level, `@pragma('vm:entry-point')`, opens its **own** DB (`singleInstance: false` — it can
fire while the app is alive, so closing it must not slam the foreground's shared connection),
rebuilds, arms the next alarm, and closes:

```dart
@pragma('vm:entry-point')
Future<void> widgetAlarmCallback(int id) async {
  WidgetsFlutterBinding.ensureInitialized();
  initSqliteFfi();                                     // this isolate must select FFI too
  final db = await AppDatabase.open(singleInstance: false);
  try {
    final service = WidgetService(AppRepositories(db));
    await service.refresh();
    if (service.nextWakeAt != null) await WidgetBackground.arm(service.nextWakeAt!);  // re-arm the chain
  } finally { await db.close(); }
}
```

This is also a natural place to roll a reminder horizon forward (see
`flutter-local-notifications-reminders`).

## 8. Gotchas

- **Flutter formats, native renders** — push JSON via `home_widget`, don't try to draw from Dart.
- **`updatePeriodMillis = 0` + your own alarm chain** — the system refresh is too coarse; own it.
- **Re-arm the next alarm from the callback** — `oneShotAt` is one-shot; the chain dies otherwise.
  A startup `arm(nextWakeAt)` is the backstop.
- **Fixed alarm id** so re-arming replaces rather than stacks alarms.
- **`exact + allowWhileIdle + wakeup + rescheduleOnReboot`** — precise through Doze, survives
  reboot.
- **Headless callback: own DB, `singleInstance: false`, close in `finally`, re-select FFI,
  `@pragma('vm:entry-point')`** — same rules as every background isolate.
- **Redraw only changed providers** (signature check) — full updates flicker; list/collection
  widgets in particular need a full update for structural changes, so gate them.
- **Push all palette×brightness colors** — the native side can't read your Flutter theme.
- **Everything self-guards on `Platform.isAndroid`** (RemoteViews are Android; iOS uses WidgetKit
  — a separate native target `home_widget` also supports).
- **`refresh` is best-effort** — catch and log; a widget failure must never crash the app.

---
name: flutter-firebase-analytics-crashlytics
description: Use when wiring Firebase Crashlytics (and Analytics) into a Flutter app — native-config init with no FirebaseOptions, per-build-variant Firebase apps so dev and prod stay separate, catching both Flutter and platform-dispatcher errors, and gating collection off in debug.
---

# Firebase Crashlytics + Analytics

Wire crash reporting and analytics with the native-config approach: no hand-written
`FirebaseOptions`, per-build-variant Firebase apps so debug and release report to separate places,
and both Flutter-framework and async platform errors captured. The crash-reporting setup here is
what caremate ships; the analytics half is the standard companion wiring (caremate declares the
dependency and separates dev/prod but doesn't yet log custom events).

## Contents

1. Dependencies & Gradle plugins
2. Per-variant Firebase apps (dev vs prod)
3. Init + catch every error
4. Gate collection in debug
5. Analytics: observer + events
6. Gotchas

## 1. Dependencies & Gradle plugins

```yaml
dependencies:
  firebase_core: ^3.15.1
  firebase_crashlytics: ^4.3.1
  firebase_analytics: ^11.5.1
```

Android (`android/app/build.gradle.kts` plugins block):

```kotlin
plugins {
  id("com.google.gms.google-services")       // reads google-services.json
  id("com.google.firebase.crashlytics")       // uploads native symbols / dSYMs
}
```

Add `android/app/google-services.json` (from the Firebase console). iOS needs
`GoogleService-Info.plist` once that platform is registered.

## 2. Per-variant Firebase apps (dev vs prod)

Register **two apps** in one Firebase project — one per Android `applicationId` — and give debug a
distinct id (e.g. `com.acme.app.dev`) via a build-type `applicationIdSuffix`. `google-services.json`
holds both; the Google Services Gradle plugin **selects the right registered app per build
variant** automatically. Result: debug crashes and analytics land in a separate Firebase app from
production, so test noise never pollutes prod dashboards — no code branching required.

## 3. Init + catch every error

Initialize from the native config (**no explicit `FirebaseOptions`** — the Gradle plugin supplies
them per variant), then route **both** error channels to Crashlytics:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();                                   // native config, per-variant app

  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError; // framework errors
  PlatformDispatcher.instance.onError = (error, stack) {                        // async / uncaught
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  // … rest of startup …
}
```

`FlutterError.onError` catches errors inside the widgets/rendering pipeline;
`PlatformDispatcher.instance.onError` catches everything else (async gaps, isolate errors) — you
need **both** for full coverage. (`PlatformDispatcher.onError` returning `true` is the modern
replacement for wrapping `main` in `runZonedGuarded`.)

## 4. Gate collection in debug

Don't report debug runs. Toggle collection off when `kDebugMode` (still initialize, so the wiring
is exercised):

```dart
await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);
await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(!kDebugMode);
```

Combined with the per-variant apps (§2), this gives belt-and-suspenders separation: debug is both
a different app *and* collection-off.

## 5. Analytics: observer + events

Auto-track screens with the navigator observer, and log domain events sparingly:

```dart
final analytics = FirebaseAnalytics.instance;
MaterialApp(
  navigatorObservers: [FirebaseAnalyticsObserver(analytics: analytics)],  // screen_view per route
  // …
);

await analytics.logEvent(name: 'backup_completed', parameters: {'destination': 'drive', 'size_kb': kb});
```

Event/param names must be snake_case and within Firebase's limits; prefer a small set of
well-named events over logging everything.

## 6. Gotchas

- **No hand-written `FirebaseOptions`** when using the Gradle plugin — let it pick the per-variant
  app from `google-services.json`; a hardcoded options object defeats the dev/prod split.
- **Wire both error channels** — `FlutterError.onError` *and* `PlatformDispatcher.instance.onError`;
  either alone misses a class of crashes.
- **Distinct debug `applicationId`** (`.dev` suffix) + a second registered app, or debug and prod
  crashes/analytics merge.
- **Gate collection on `!kDebugMode`** so local runs don't spam dashboards.
- **`recordFlutterFatalError`** (not `recordFlutterError`) for the `FlutterError.onError` hook when
  you want them treated as fatal/crash-free-rate-affecting.
- **iOS needs `GoogleService-Info.plist`** and the Crashlytics run-script build phase (dSYM upload)
  — the Android Gradle plugins don't cover it.
- **Test a real crash** (`FirebaseCrashlytics.instance.crash()`) once in a release build — reports
  only appear after the app restarts and re-launches.

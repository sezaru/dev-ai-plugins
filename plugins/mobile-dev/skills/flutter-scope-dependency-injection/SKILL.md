---
name: flutter-scope-dependency-injection
description: Use when wiring app-wide services/repositories to the widget tree in a Flutter app without a DI package — the InheritedWidget/InheritedNotifier "Scope" idiom, with a typed static of(context), the immutable-vs-observable choice, scope shadowing for demos/tests, and a transaction-bundle pattern.
---

# Scope dependency injection (InheritedWidget idiom)

Expose services and repositories to the whole widget tree with a tiny, package-free pattern: a
`XScope` `InheritedWidget` (or `InheritedNotifier`) with a typed `static of(context)`. Every
consumer reads `XScope.of(context)` — no globals, no `get_it`, no `provider`. This is the
backbone wiring in caremate (repositories, theme, reminders, purchases, tour anchors).

Underpins nearly every other skill here (each service is reached through its scope).

## Contents

1. Two variants: immutable vs. observable
2. Immutable service — `InheritedWidget`
3. Observable service — `InheritedNotifier`
4. Bundling a data layer
5. Scope shadowing (demos & tests)
6. Composing scopes at the root
7. Gotchas

## 1. Two variants: immutable vs. observable

Pick by whether consumers must **rebuild when the service changes state**:

| Need | Base class | `of()` returns |
|---|---|---|
| Just reach a stable service (repos, scheduler) | `InheritedWidget` | the service |
| Rebuild dependents on change (theme, purchases) | `InheritedNotifier<T extends ChangeNotifier>` | the notifier |

Both give the same call site — `XScope.of(context)` — so consumers don't care which you chose.

## 2. Immutable service — `InheritedWidget`

For a service whose *identity* is stable and whose internal changes don't need to rebuild the
tree:

```dart
class ReminderScope extends InheritedWidget {
  const ReminderScope({super.key, required this.scheduler, required super.child});
  final ReminderScheduler scheduler;

  static ReminderScheduler of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ReminderScope>();
    assert(scope != null, 'No ReminderScope found in context');
    return scope!.scheduler;
  }

  @override
  bool updateShouldNotify(ReminderScope old) => scheduler != old.scheduler; // only if swapped
}
```

The `assert` in `of()` turns "forgot to install the scope" into a clear message instead of a
null-deref far away.

## 3. Observable service — `InheritedNotifier`

For a service that is a `ChangeNotifier` — dependents rebuild automatically when it
`notifyListeners()`:

```dart
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({super.key, required ThemeController controller, required super.child})
      : super(notifier: controller);

  static ThemeController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!.notifier!;
}
```

No `updateShouldNotify` needed — `InheritedNotifier` wires it to the notifier. A widget that
calls `ThemeScope.of(context).mode` rebuilds when the theme changes; one that only reads it in a
callback (`onTap: () => ThemeScope.of(context).toggle()`) can use `dependOnInherited…` too, but
won't be forced to rebuild if you instead look it up without depending. Use this for `purchases`,
`theme`, anything with live state.

## 4. Bundling a data layer

Group all repositories into one object sharing a single DB executor, expose the **bundle** via
one scope — consumers reach any repo through it without importing `db.dart`:

```dart
class AppRepositories {
  AppRepositories(this.db) : journeys = JourneyRepo(db), events = EventRepo(db), settings = SettingsRepo(db) /* … */;
  final DatabaseExecutor db;   // Database at app level; Transaction inside a txn — repos take either
  final JourneyRepo journeys; final EventRepo events; final SettingsRepo settings;

  /// One all-or-nothing transaction: use the PASSED bundle for every write inside — sqflite
  /// deadlocks if you touch the outer (non-transaction) db during a transaction.
  Future<T> transaction<T>(Future<T> Function(AppRepositories txn) action) {
    if (db is! Database) throw StateError('cannot nest');
    return (db as Database).transaction((txn) => action(AppRepositories(txn)));
  }
}
```

Because each repo takes the `DatabaseExecutor` interface (not a concrete `Database`), the same
repo classes work transparently against the app connection *or* a transaction — that's what makes
the transaction bundle possible.

## 5. Scope shadowing (demos & tests)

A nested scope **shadows** the one above it — `of(context)` resolves to the nearest ancestor. So
a demo/test can wrap a subtree in a fresh scope over throwaway services, and everything below
transparently uses them with no code change:

```dart
// tour sandbox / widget test: shadow the real repositories with an in-memory bundle
RepositoryScope(
  repositories: sandboxRepos,       // shadows the app's real RepositoryScope
  child: ReminderScope(scheduler: NoopScheduler(), child: realAppShell),
)
```

This is exactly how `flutter-guided-tour` drives the real UI against an in-memory DB, and how
widget tests inject fakes.

## 6. Composing scopes at the root

Build every service once in `main()`, then nest the scopes above your app:

```dart
runApp(
  RepositoryScope(repositories: repos,
  child: ThemeScope(controller: themeController,
  child: ReminderScope(scheduler: scheduler,
  child: PurchaseScope(service: purchases,
    child: const App())))),
);
```

Order doesn't matter (they're independent); keep it flat and readable.

## 7. Gotchas

- **`dependOnInheritedWidgetOfExactType`** (not `getElementForInheritedWidgetOfExactType`) when
  the widget should rebuild on change; it registers the dependency.
- **`assert` in `of()`** for a clear "scope not installed" error instead of a null-deref.
- **`updateShouldNotify` compares identity** for `InheritedWidget` — return true only when the
  service instance actually changed (usually it never does).
- **`InheritedNotifier` for live state** — don't hand-roll listeners on a plain `InheritedWidget`;
  let the framework wire the `ChangeNotifier`.
- **Shadowing is a feature** — a nested scope overrides for its subtree; lean on it for
  demos/tests instead of swapping globals.
- **One shared `DatabaseExecutor`** across repos + the `Transaction`-vs-`Database` split enables
  atomic multi-repo writes; **use the passed bundle inside `transaction`**, never the outer db
  (sqflite deadlock).
- **Build services once in `main()`**, pass them into scopes — don't construct services inside
  `build()`.

---
name: flutter-guided-tour
description: Use when building an auto-playing interactive product tour for a Flutter app that drives the REAL app UI (not screenshots) inside a phone-mockup frame — a throwaway in-memory sandbox, an anchor registry that spotlights real widgets, an animated demo "finger", and a scripted step controller.
---

# Auto-driven guided tour (real UI, sandboxed)

A narrated walkthrough that drives your **actual** app shell — real screens, sheets, navigation
— fed by a throwaway in-memory database and rendered inside a phone-mockup frame so it reads as
"watch the app." The user only taps Next/Back/Skip; each step fills in example data, navigates,
and floats a demo finger onto the relevant control. Nothing persists; no OS side-effects fire.

This is the most involved pattern in the set. Builds on `flutter-scope-dependency-injection`
(scopes shadow the real ones), `flutter-sqlite-ffi-fts5` (the in-memory DB), and pairs with
`flutter-onboarding-flow` (which launches it).

## Contents

1. Architecture — five pieces
2. Dependency
3. The sandbox — real shell, in-memory DB, shadowed scopes
4. The phone frame + full-screen overlay siblings
5. Anchor registry — spotlight real widgets, zero cost in prod
6. The demo finger
7. Script controller + the stage interface
8. Idempotent steps (Back must re-run cleanly)
9. Gotchas

## 1. Architecture — five pieces

- **`TourSandbox`** — hosts a real `AppShell` on a private in-memory DB, in `demo` mode.
- **`TourAnchorRegistry` + `TourTarget`** — real widgets tag themselves; the tour resolves their
  on-screen rect. Inert in the real app.
- **`DemoCursor` / `DemoCursorView`** — the animated "finger" that glides/taps over controls.
- **`TourController` + `TourStep`** — the script: ordered narrated stops, each with an `onEnter`
  side-effect.
- **`TourStage`** — the imperative interface the demo shell implements (navigate, insert data,
  point the finger) and hands to the controller.

## 2. Dependency

```yaml
dependencies:
  device_frame_plus: ^1.5.0   # renders the app inside a realistic phone mockup
```

## 3. The sandbox — real shell, in-memory DB, shadowed scopes

Two things make driving the real app safe:

- **A private in-memory DB** (`inMemoryDatabasePath` + `singleInstance: false`), opened on mount
  and closed on dispose — fully isolated from the live on-disk DB (which stays open, untouched).
- **`demo: true` shell** with a **no-op scheduler**, so reminders, home-widgets and deep links
  are suppressed for the tour's duration.

A fresh `RepositoryScope` (and friends) **shadows** the app's real scopes, so every
`RepositoryScope.of(context)` under the sandbox resolves to the throwaway repos:

```dart
Future<_Sandbox> _open() async {
  final db = await AppDatabase.open(path: inMemoryDatabasePath, singleInstance: false);
  final repos = AppRepositories(db);
  await repos.settings.setAdsRemoved(true);   // clean UI: hide ads during the tour
  return _Sandbox(db, repos);
}

@override void dispose() {
  _tour?.dispose();
  _boot.then((s) => s.db.close());             // free the in-memory db with its connection
  super.dispose();
}
```

## 4. The phone frame + full-screen overlay siblings

Render the shell inside a `DeviceFrame`; put the overlay, finger, and narration as **full-screen
siblings on top** in a `Stack`. Anchor rects come back in **global** coordinates, so a finger
placed there lands on the right control even though the app underneath is scaled inside the
mockup:

```dart
Stack(children: [
  Positioned.fill(
    top: MediaQuery.paddingOf(context).top,      // sit below the real status bar
    bottom: 196,                                  // reserve a strip for the narration card
    child: DeviceFrame(
      device: Devices.android.samsungGalaxyS20, isFrameVisible: true,
      screen: Builder(builder: (c) => MediaQuery.removePadding(  // strip simulated safe-area
        context: c, removeBottom: true, child: shell)),
    ),
  ),
  TourOverlay(controller: tour, registry: _anchors),   // narration card + Skip/Next, absorbs taps
  DemoCursorView(cursor: _cursor, registry: _anchors), // the finger
])
```

Reserving a bottom strip means the narration never overlaps the app or the finger. On the
closing step, scale+fade the frame away so a full-screen farewell takes over.

## 5. Anchor registry — spotlight real widgets, zero cost in prod

A widget tags itself with `TourTarget(anchor: TourAnchors.addButton, child: …)`. Under a
`TourAnchorScope` (installed **only** by the sandbox) it registers its `BuildContext`; in the
real app there's no scope, so it's an inert pass-through — **zero behavioural cost**:

```dart
class TourAnchorRegistry {
  final _byAnchor = <String, BuildContext>{};
  void register(String a, BuildContext c) => _byAnchor[a] = c;
  void unregister(String a, BuildContext c) { if (_byAnchor[a] == c) _byAnchor.remove(a); } // guard stale dispose

  Rect? rectOf(String a) {                          // global rect for the finger/spotlight
    final c = _byAnchor[a];
    if (c == null || !c.mounted) return null;
    final box = c.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
  BuildContext? contextOf(String a) => _byAnchor[a]?.let((c) => c.mounted ? c : null); // for ensureVisible
}
```

`TourTarget` registers in `didChangeDependencies`, re-registers in `didUpdateWidget`, and
unregisters in `dispose` — guarding that a stale unregister can't clobber a newer registration.

## 6. The demo finger

An imperative handle whose methods are **no-ops until the view attaches** (so callers never
null-check). It's decoration — never a real gesture:

```dart
class DemoCursor {
  _DemoCursorViewState? _view;
  Future<void> pointAnchor(String a) async => _view?.pointAnchor(a) ?? Future.value(); // glide + rest
  Future<void> tapAnchor(String a) async   => _view?.tapAnchor(a)   ?? Future.value(); // glide + press ripple
  void hide() => _view?.hide();
}
```

The view resolves the anchor's global rect, `Scrollable.ensureVisible`s it, glides an
`AnimationController` from the finger's current spot to the target centre (~620ms), and plays a
press dip + ripple for `tapAnchor`. Both `Future`s resolve when the animation settles, so the
script can `await` them.

## 7. Script controller + the stage interface

`TourController` holds an ordered `List<TourStep>`. Each step has narration + an optional
`onEnter(stage)` that performs the step's side-effects. `busy` disables Next while `onEnter`
runs so the UI can't outrun navigation. Steps are **best-effort** — a thrown `onEnter` is logged,
never trapped:

```dart
Future<void> _goTo(int i) async {
  _busy = true; _index = i; notifyListeners();
  try { await steps[i].onEnter?.call(_stage!); }
  catch (e, st) { debugPrint('[tour] step $i failed: $e\n$st'); }  // don't trap the user
  _busy = false; notifyListeners();
}
```

The demo `AppShell` implements `TourStage` and hands it to the controller via `bind()` on mount
(which auto-starts step 0). The stage is the tour's remote control:

```dart
abstract class TourStage {
  AppRepositories get repos; DateTime get now;
  void goHome(); void openDetail(String id); Future<void> openSubScreen(String id);
  void refreshHome(); void refreshDetail();
  Future<void> pointAnchor(String anchor);   // finger rests (no tap)
  Future<void> tapAnchor(String anchor);     // finger plays a press before the real nav runs
  Future<void> showAddOptions(); void closeSheet(); void hideCursor();
}
```

A step then reads like a storyboard:
```dart
TourStep(title: l.tourAddTitle, body: l.tourAddBody, point: TourAnchors.addButton,
  onEnter: (s) async {
    s.goHome();
    await s.repos.journeys.insert(exampleJourney(s.now));  // idempotent example data
    s.refreshHome();
    await s.tapAnchor(TourAnchors.addButton);              // show the press, then...
    await s.showAddOptions();                              // ...the real sheet opens
  });
```

## 8. Idempotent steps (Back must re-run cleanly)

`onEnter` runs every time a step becomes active — including after Back → Next. So it must be
**idempotent**: upsert example data (stable ids), don't append duplicates; re-navigate from a
known base (`goHome()` first). Record the intended `point` anchor on the `TourStep` too (a
declarative field you can assert in tests, separate from the imperative finger move).

## 9. Gotchas

- **Isolate the sandbox DB** — `inMemoryDatabasePath` + `singleInstance: false`, closed on
  dispose. A shared/single-instance connection would collide with the live app DB (see the
  sqflite isolate rule in `flutter-sqlite-ffi-fts5`).
- **`demo: true` + no-op scheduler** — or the tour fires real reminders/widgets/deep links.
- **Global anchor rects** — the app is scaled inside the frame, so local coordinates are wrong;
  always resolve via `localToGlobal`, and keep the overlay/finger as full-screen siblings.
- **`TourTarget` must be inert in prod** — no `TourAnchorScope` → pass-through, no registration,
  no cost. Never let the tour infrastructure change real-app behaviour.
- **Idempotent `onEnter`** — Back then Next re-runs it; upsert, don't append.
- **Best-effort steps** — catch+log `onEnter` failures; a broken step must not trap the user
  with no way forward.
- **`busy` gates Next** — don't let the user advance mid-navigation.
- **Overlay has no Material ancestor** (it's a Stack sibling, not in a Scaffold) — wrap narration
  text in a transparent `Material`, or you get the yellow debug text style.
- **The finger is decoration** — it never dispatches a real gesture; the actual navigation is
  the `onEnter` code running alongside the animation.
- **Guard stale unregister** — only remove an anchor's context if it's still the registered one.

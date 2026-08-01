---
name: flutter-onboarding-flow
description: Use when adding a first-launch onboarding/welcome flow to a Flutter app — a swipeable multi-step intro with progress dots and skip, gated by a persisted "onboarded" flag through a root gate, replayable from settings, with a clean handoff into the app (or a guided tour).
---

# First-launch onboarding flow

A swipeable multi-step welcome shown once on first launch, gated by a persisted flag, replayable
from Settings, and handing off cleanly into the app. Data-driven steps (not hand-built pages),
`PopScope` so Back steps through rather than exiting, and a **root gate** that owns the
onboarding-vs-app decision.

Pairs with `flutter-guided-tour` (an optional "explore demo" handoff) and
`flutter-scope-dependency-injection` (reading/writing the flag).

## Contents

1. The root gate (where the decision lives)
2. Data-driven steps
3. The screen — PageView, dots, skip, Back
4. Handoff & the frame-flash gotcha
5. Replay from settings
6. Gotchas

## 1. The root gate

Put a single `RootGate` at `home:` that decides between onboarding and the app shell, reading
the initial flag (loaded at startup) and persisting it when the flow completes. Everything about
"have we onboarded?" lives here — screens below never worry about it.

```dart
class _RootGateState extends State<RootGate> {
  late bool _onboarded = widget.onboarded;   // initial value loaded from settings in main()
  bool _createFirst = false;

  Future<void> _finish({required bool createFirst}) async {
    await RepositoryScope.of(context).settings.setOnboarded(true);   // persist
    if (!mounted) return;
    setState(() { _onboarded = true; _createFirst = createFirst; });
  }

  @override
  Widget build(BuildContext context) {
    if (!_onboarded) return OnboardingScreen(onFinish: _finish, onExploreDemo: /* optional tour */);
    return AppShell(createOnStart: _createFirst);   // pass through the chosen first action
  }
}
```

Load the flag **once at startup** (in `main()`, from your settings row) and pass it in — don't
async-load it inside the gate, or you flash a spinner or the wrong screen on launch.

## 2. Data-driven steps

Model each page as data, not a bespoke widget — adding/reordering a step is a one-line change,
and every page shares one layout. Keep all copy in your ARB (localize it):

```dart
enum _OnbArt { appLogo, shield, share, feature }
class _OnbStep { final String eyebrow, title, body; final _OnbArt art; }

List<_OnbStep> _steps(AppLocalizations l) => [
  _OnbStep(eyebrow: l.onbEyebrow0, title: l.onbTitle0, body: l.onbBody0, art: _OnbArt.appLogo),
  // …
];
```

Map the `art` enum to a tile style in one `switch` so the illustration set stays consistent
(one solid brand tile, the rest soft-tinted gradient tiles).

## 3. The screen — PageView, dots, skip, Back

```dart
PopScope(
  canPop: _step == 0,                                  // Back steps through; only step 0 pops (exits)
  onPopInvokedWithResult: (didPop, _) { if (!didPop) _previous(); },
  child: Scaffold(body: SafeArea(child: Column(children: [
    if (!_isLast) SkipButton(onTap: () => onFinish(createFirst: false)), // skip hidden on last step
    Expanded(child: PageView.builder(
      controller: _pageController,
      onPageChanged: (i) => setState(() => _step = i),
      itemCount: steps.length,
      itemBuilder: (_, i) => _OnbPage(step: steps[i]),
    )),
    if (!_isLast) ...[ _Dots(count: steps.length, active: _step), PrimaryButton(l.onbContinue, _next) ]
    else            [ /* final CTAs: "Get started" / "Take a tour" / "Skip" */ ],
  ])))
)
```

- **Progress dots** = animated width (active dot wider) via `AnimatedContainer`.
- **`_next`/`_previous`** drive the `PageController` (`nextPage`/`previousPage`, ~280ms easeOut).
- **Skip** is always available (except the final step) and calls `onFinish(createFirst: false)`.
- The **last step** swaps the dots+continue for terminal CTAs (start / optional tour / skip).

## 4. Handoff & the frame-flash gotcha

`onFinish` carries the user's **chosen first action** (e.g. `createFirst`) so the app opens in
the right state. If onboarding can branch into a guided-tour sandbox and back, flip **all flags
in one `setState`** and persist in the background — don't `await` the write between flag flips:

```dart
void _exitDemo() {
  setState(() { _demo = false; _onboarded = true; });     // one rebuild: sandbox -> app shell
  unawaited(settings.setOnboarded(true));                 // persist without gating the transition
}
```

Awaiting the persist between flips drops the sandbox while `_onboarded` is still false — which
flashes the last onboarding page for a frame. One `setState`, background write.

## 5. Replay from settings

A "Replay welcome" row just flips the in-memory flag back **without clearing the persisted
one** — the intro re-shows, but the user is still considered onboarded:

```dart
void _replayTour() => setState(() { _onboarded = false; _createFirst = false; });
```

## 6. Gotchas

- **Load the flag at startup**, pass it into the gate — don't async-load inside the gate (launch
  flicker).
- **One `setState` for multi-flag transitions**, persist in the background — awaiting mid-flip
  flashes a stale frame.
- **`PopScope(canPop: _step == 0)`** so Back walks backward through steps instead of exiting the
  app mid-onboarding.
- **Data-driven steps + localized copy** — every string in the ARB, pages generated from a list.
- **Carry the chosen action** (`createFirst`) through `onFinish` so the app opens in context.
- **Replay ≠ reset** — re-show without clearing the persisted flag.
- **Dispose the `PageController`.**

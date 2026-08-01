---
name: flutter-design-tokens-theming
description: Use when building a token-based theme system for a Flutter app — an immutable design-token set per palette×brightness delivered through a ThemeExtension with a context.colors accessor, multiple selectable palettes, light/dark/system mode via a ChangeNotifier controller persisted in your own store, and display/body font pairing.
---

# Design-tokens theming (ThemeExtension + palette controller)

A theme built from **named design tokens** ported verbatim from your design source (Figma / CSS
custom properties), delivered through a `ThemeExtension` so any widget reads
`context.colors.accent` — never a hardcoded `Color`. Multiple palettes, light/dark/system mode, a
`ChangeNotifier` controller with injected persistence, and a display+body font pair. Proven in
caremate (3 palettes × 2 brightnesses).

Delivered via `flutter-scope-dependency-injection` (the controller rides an `InheritedNotifier`).

## Contents

1. The token set (a value object, not scattered colors)
2. Delivering tokens: `ThemeExtension` + `context.colors`
3. Building `ThemeData` from a palette
4. The controller (mode + palette, injected persistence)
5. Wiring it to `MaterialApp`
6. Fonts
7. Gotchas

## 1. The token set (a value object, not scattered colors)

Define one **immutable** `MhcColors` holding every semantic token, and a token for *purpose*
(`ink`, `ink2`, `surface`, `accent`, `accentSoft`, `danger`…) — not for hue. Port the values
**verbatim** from your design source so the app matches the mockup 1:1. **UI never hardcodes a
color** — it always reads a token.

```dart
enum MhcPalette { terracotta, honey, clay }        // selectable palettes (design's data-pal)
enum MhcThemeMode { light, dark, system }

@immutable
class MhcColors {
  const MhcColors({required this.bg, required this.surface, required this.ink, required this.ink2,
      required this.line, required this.accent, required this.accentSoft, required this.danger, /* … */});
  final Color bg, surface, ink, ink2, line, accent, accentSoft, danger;
}

abstract final class MhcTokens {
  static MhcColors resolve(MhcPalette palette, Brightness brightness) => /* the const table per palette×brightness */;
}
```

Naming by role (not by color) is what lets a token flip between light and dark — `ink` is "primary
text", dark in light mode, light in dark mode.

## 2. Delivering tokens: `ThemeExtension` + `context.colors`

Carry the token set through `ThemeData` as a `ThemeExtension`, and add a `BuildContext` accessor
so reading a token is one call:

```dart
@immutable
class MhcThemeExtension extends ThemeExtension<MhcThemeExtension> {
  const MhcThemeExtension(this.colors);
  final MhcColors colors;
  @override MhcThemeExtension copyWith({MhcColors? colors}) => MhcThemeExtension(colors ?? this.colors);
  @override MhcThemeExtension lerp(ThemeExtension<MhcThemeExtension>? other, double t) =>
      other is! MhcThemeExtension ? this : (t < 0.5 ? this : other);   // switch wholesale, no per-token tween
}

extension MhcColorsContext on BuildContext {
  MhcColors get colors => Theme.of(this).extension<MhcThemeExtension>()!.colors;
}
```

Now any widget: `Container(color: context.colors.surface, child: Text('x', style: TextStyle(color: context.colors.ink)))`.

## 3. Building `ThemeData` from a palette

One builder maps (palette, brightness) → `ThemeData`, resolving tokens once and attaching the
extension. Seed a Material `ColorScheme` from the accent, then override the surfaces you control:

```dart
static ThemeData build(MhcPalette palette, Brightness brightness) {
  final colors = MhcTokens.resolve(palette, brightness);
  return ThemeData(
    useMaterial3: true, brightness: brightness,
    scaffoldBackgroundColor: colors.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: colors.accent, brightness: brightness)
        .copyWith(surface: colors.surface, primary: colors.accent, onPrimary: colors.onAccent),
    textTheme: _textTheme(colors, brightness),
    splashFactory: InkRipple.splashFactory,                      // M3 InkSparkle is invisible on light surfaces
    splashColor: colors.ink.withValues(alpha: 0.12),
    extensions: [MhcThemeExtension(colors)],                     // <- tokens travel here
  );
}
```

## 4. The controller (mode + palette, injected persistence)

A `ChangeNotifier` holding the two choices. **Inject persistence as callbacks** so the controller
has no storage dependency — widget tests construct it with no database:

```dart
class ThemeController extends ChangeNotifier {
  ThemeController({required MhcPalette palette, required MhcThemeMode mode,
      Future<void> Function(MhcPalette)? onPaletteChanged, Future<void> Function(MhcThemeMode)? onModeChanged})
    : _palette = palette, _mode = mode, _onPaletteChanged = onPaletteChanged, _onModeChanged = onModeChanged;

  MhcPalette get palette => _palette; MhcThemeMode get mode => _mode;

  Future<void> setPalette(MhcPalette p) async {
    if (_palette == p) return;
    _palette = p; notifyListeners(); await _onPaletteChanged?.call(p);  // notify first, persist after
  }

  Brightness brightnessFor(Brightness platform) => switch (_mode) {
    MhcThemeMode.light => Brightness.light, MhcThemeMode.dark => Brightness.dark,
    MhcThemeMode.system => platform };

  static MhcPalette paletteFromName(String? n) =>
      MhcPalette.values.firstWhere((p) => p.name == n, orElse: () => MhcPalette.terracotta); // tolerant parse
}
```

Persist the choice in your **own** store (e.g. the SQLite settings row — the single source of
truth), passing `onPaletteChanged: (p) => repos.settings.setPalette(p.name)`. No
`shared_preferences` needed if you already have a settings table.

## 5. Wiring it to `MaterialApp`

Read the controller (via its scope) and rebuild on change; hand `theme`/`darkTheme`/`themeMode`:

```dart
final theme = ThemeScope.of(context);   // InheritedNotifier -> rebuilds on change
return MaterialApp(
  theme: MhcTheme.build(theme.palette, Brightness.light),
  darkTheme: MhcTheme.build(theme.palette, Brightness.dark),
  themeMode: switch (theme.mode) {
    MhcThemeMode.light => ThemeMode.light, MhcThemeMode.dark => ThemeMode.dark, MhcThemeMode.system => ThemeMode.system },
);
```

## 6. Fonts

Pair a **display** family (serif/expressive, for large titles) with a **body** family via
`google_fonts`, and assign the display font only to the `display*`/`headline*` slots:

```dart
final body = GoogleFonts.hankenGroteskTextTheme(base).apply(bodyColor: colors.ink, displayColor: colors.ink);
final display = GoogleFonts.newsreaderTextTheme(body);
final textTheme = body.copyWith(displayLarge: display.displayLarge, headlineMedium: display.headlineMedium /* … */);
```

## 7. Gotchas

- **Tokens named by role, not hue** — `ink`/`surface`/`accent`, so they flip correctly across
  light/dark; a token called `brown` can't.
- **Never hardcode a `Color` in UI** — always `context.colors.x`; that's the whole point.
- **`ThemeExtension.lerp` switches wholesale** — palette/mode change swaps the whole token set;
  per-token tweening looks muddy and costs nothing to skip.
- **Inject persistence into the controller** (callbacks), keep storage out of it — test-friendly.
- **`notifyListeners()` before awaiting the persist** so the UI updates immediately; the write
  catches up.
- **Tolerant `fromName` parsers** with a default — a stored value from an old build (renamed
  palette) must not crash; fall back.
- **Seed the `ColorScheme` from the accent, then override** the surfaces you control, so Material
  widgets you don't theme still look coherent.
- **Persist in one source of truth** (your settings row) rather than adding `shared_preferences`
  alongside a DB.

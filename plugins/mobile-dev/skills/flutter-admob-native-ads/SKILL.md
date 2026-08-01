---
name: flutter-admob-native-ads
description: Use when adding Google AdMob native ads to a Flutter app — in-feed/timeline/list ad slots that match the app's card design, with GDPR/UMP consent gating and a kill-switch that hides every ad once the user pays to remove them.
---

# AdMob native ads (design-matched, consent-gated)

Integrate Google AdMob **native** ads that render as cards matching your own UI (not a
Google banner), request only after UMP/GDPR consent is resolved, and disappear the moment
a "remove ads" flag flips. This is the pattern proven in the caremate app across four
in-list placements.

Pairs with `flutter-remove-ads-iap` (the purchase that flips the flag) and
`flutter-scope-dependency-injection` (how the flag reaches each slot).

## Contents

1. Architecture — the four moving parts
2. Dependency & platform setup
3. `AdConfig` — per-slot unit IDs, test/prod, kill-switch
4. `AdConsent` — the UMP consent gate
5. Startup wiring (order matters)
6. `NativeAdSlot` — the load-once widget
7. Rendering: Dart-only template vs. native factory
8. Gating slots behind "ads removed"
9. Gotchas

## 1. Architecture

Four parts, each with one job:

- **`AdConfig`** — static config: which ad-unit ID per placement, test-vs-prod, a master
  `enabled` kill-switch.
- **`AdConsent`** — runs Google's UMP consent flow once at startup and exposes a
  `ValueNotifier<bool> canRequestAds` gate.
- **`NativeAdSlot`** — a `StatefulWidget` that owns exactly one `NativeAd`, loads it only
  after the gate opens, renders nothing until/unless an ad actually loads.
- **A remove-ads flag** — a persisted bool every slot's parent checks before inserting a
  `NativeAdSlot` into the list at all.

## 2. Dependency & platform setup

```yaml
dependencies:
  google_mobile_ads: ^5.3.1
```

**Android** — put the App ID (from the AdMob console) in `AndroidManifest.xml` inside
`<application>`:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"/>
```

Use Google's public **sample App ID** (`ca-app-pub-3940256099942544~3347511713`) until you
have a real account — a wrong/empty App ID crashes on init.

**iOS** — the equivalent `GADApplicationIdentifier` key in `Info.plist`.

## 3. `AdConfig` — per-slot IDs, test/prod, kill-switch

Model placements as an **enum**, not bare strings, so adding a slot is a compile error
until it has an ID in every platform map:

```dart
enum AdSlot { home, feed, history }   // your placements

class AdConfig {
  AdConfig._();

  static const _testAndroid = 'ca-app-pub-3940256099942544/2247696110'; // Google test units
  static const _testIos     = 'ca-app-pub-3940256099942544/3986624511';

  static const Map<AdSlot, String> _prodAndroid = { /* real unit IDs, '' until filled */ };
  static const Map<AdSlot, String> _prodIos     = { /* ... */ };

  /// Debug builds always use test ads; release uses test ads only while prod IDs are blank.
  static bool get useTestAds => kDebugMode;

  /// Master kill-switch (a hook for future remote-config). Off on web (no SDK) and under
  /// `flutter test` (the platform channel isn't registered — slots just render nothing).
  static bool enabled = !kIsWeb && !_isFlutterTest;
  static final bool _isFlutterTest =
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  static String unitId(AdSlot slot) {
    final android = !kIsWeb && Platform.isAndroid;
    if (useTestAds) return android ? _testAndroid : _testIos;
    final prod = android ? _prodAndroid[slot] : _prodIos[slot];
    // Fail safe to the test unit rather than requesting an empty/invalid unit.
    return (prod == null || prod.isEmpty) ? (android ? _testAndroid : _testIos) : prod;
  }
}
```

Per-slot prod IDs let you track fill/revenue per placement. **Never ship your real unit IDs
requesting against a debug build** — always `useTestAds` in debug, or AdMob may flag the
account for invalid traffic.

## 4. `AdConsent` — the UMP consent gate

Under GDPR, EEA/UK/CH users must consent before an ad request. UMP fetches the messaging
config, shows Google's form only when required, records the choice, and reports whether ads
may be requested. Everywhere else it resolves instantly with no form.

```dart
class AdConsent {
  AdConsent._();

  /// Flips true only after consent is resolved AND the SDK is initialized.
  /// Every NativeAdSlot listens to this and loads only when it becomes true.
  static final ValueNotifier<bool> canRequestAds = ValueNotifier<bool>(false);

  static Future<bool> gather() async {
    final completer = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(consentDebugSettings: _debugSettings),
      () async {
        await ConsentForm.loadAndShowConsentFormIfRequired((_) {
          if (!completer.isCompleted) completer.complete();
        });
      },
      (_) { if (!completer.isCompleted) completer.complete(); }, // errors -> proceed
    );
    await completer.future;
    return ConsentInformation.instance.canRequestAds();
  }

  /// A "Privacy options" row in Settings can re-open the form later:
  static void showPrivacyOptions() =>
      ConsentForm.showPrivacyOptionsForm((_) {});
}
```

**Testing consent without a VPN:** in debug only, pass `ConsentDebugSettings(debugGeography:
DebugGeography.debugGeographyEea, testIdentifiers: [hashedId])`. Get the hashed id by running
once with an empty list and reading logcat for
`addTestDeviceHashedId("…")`. Send `null` in release.

## 5. Startup wiring (order matters)

Gather consent **before** initializing the SDK, and open the gate **only after both** —
otherwise a request can go out before consent is resolved. Run it in the background so it
never blocks first paint; slots stay empty until the gate opens:

```dart
// in main(), after WidgetsFlutterBinding.ensureInitialized()
if (AdConfig.enabled) {
  unawaited(() async {
    final consented = await AdConsent.gather();
    if (!consented) return;                       // declined -> no ads, gate stays shut
    await MobileAds.instance.initialize();
    AdConsent.canRequestAds.value = true;         // open the gate
  }());
}
```

## 6. `NativeAdSlot` — the load-once widget

Owns one `NativeAd`, waits for the gate, renders nothing until a real ad loads, and cleans
up on dispose. **No placeholder** — a slot that failed or is still loading collapses to
`SizedBox.shrink()` so the list never shows an empty box:

```dart
class _NativeAdSlotState extends State<NativeAdSlot> {
  NativeAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;               // fire once
    _requested = true;
    AdConsent.canRequestAds.addListener(_maybeLoad);
    _maybeLoad();                          // load now if the gate is already open
  }

  void _maybeLoad() {
    if (!mounted || _ad != null) return;
    if (!AdConfig.enabled || !AdConsent.canRequestAds.value) return;
    _load();
  }

  void _load() {
    final ad = NativeAd(
      adUnitId: AdConfig.unitId(widget.slot),
      request: const AdRequest(),
      // choose ONE rendering path — see §7
      listener: NativeAdListener(
        onAdLoaded: (_) { if (mounted) setState(() => _loaded = true); },
        onAdFailedToLoad: (ad, _) {          // show nothing, free resources
          ad.dispose();
          if (mounted && identical(ad, _ad)) setState(() { _ad = null; _loaded = false; });
        },
      ),
    );
    _ad = ad;
    try { ad.load().catchError((_) {}); } catch (_) { _ad = null; } // missing plugin -> silent
  }

  @override
  void dispose() {
    AdConsent.canRequestAds.removeListener(_maybeLoad);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _ad == null) return const SizedBox.shrink();
    return SizedBox(height: 94 /* your card height */, child: AdWidget(ad: _ad!));
  }
}
```

## 7. Rendering: two paths

**a) Dart-only template (fast, no native code).** Pass a `nativeTemplateStyle` to the
`NativeAd` with `TemplateType.small`/`medium` and colors from your theme. Zero platform code
— start here.

**b) Custom native factory (design-matched card — what caremate ships).** Register a native
`NativeAdFactory` that inflates your own layout so the ad is indistinguishable from a real
card. `factoryId` must match on both sides.

- Android — in `MainActivity.configureFlutterEngine`:
  ```kotlin
  GoogleMobileAdsPlugin.registerNativeAdFactory(
      flutterEngine, "cardFactory", NativeAdCardFactory(layoutInflater))
  ```
  and unregister in `cleanUpFlutterEngine`. `NativeAdCardFactory` inflates an XML layout
  (`res/layout/native_ad_card.xml`) and binds headline/icon/CTA to the `NativeAd`.
- Pass theme colors from Dart via `NativeAd(customOptions: {...})` as `#AARRGGBB` strings so
  the native card tracks light/dark:
  ```dart
  customOptions: { 'surface': _hex(c.surface), 'ink': _hex(c.ink), 'accent': _hex(c.accent) }
  ```
  Read them in the factory (`options["surface"] as String`) and apply. Keep the XML view ids
  in sync with the factory.

Use (a) to ship quickly; move to (b) when the ad must visually match your cards.

## 8. Gating slots behind "ads removed"

The slot widget only gates on *consent*. Whether a slot exists at all is the **parent's**
decision, checked against a persisted `adsRemoved` flag so paying users never even build one:

```dart
// building a feed list
for (final (i, item) in items.indexed) {
  widgets.add(itemTile(item));
  if (!adsRemoved && (i + 1) % adEveryN == 0) widgets.add(NativeAdSlot(slot: AdSlot.feed));
}
```

`adsRemoved` comes from your settings store; `flutter-remove-ads-iap` flips it on a verified
purchase. Because it's checked at list-build time, removing ads is instant on the next
rebuild — no ad teardown needed.

## 9. Gotchas

- **Never request live ads in debug** — always `useTestAds` in `kDebugMode`, or risk an
  invalid-traffic strike.
- **Consent before init before gate.** Reordering any of the three can fire a request before
  consent resolves — a policy violation.
- **Guard `flutter test`.** The AdMob platform channel isn't registered under tests; without
  the `FLUTTER_TEST` kill-switch every widget test that renders a slot throws. With it, slots
  render `SizedBox.shrink()`.
- **One `NativeAd` per widget, disposed with it.** Ads hold native resources; a leaked ad is
  a memory leak. Use `identical(ad, _ad)` before clearing state in the fail callback so a
  late failure from a superseded ad can't wipe a newer one.
- **No placeholder.** Rendering an empty box while loading causes visible layout jumps; the
  collapse-to-zero approach keeps lists stable.
- **`AdWidget` needs a bounded height.** Wrap it in a fixed-height `SizedBox` matching your
  template/layout, or it fails to lay out in a scroll view.

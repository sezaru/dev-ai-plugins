---
name: flutter-remove-ads-iap
description: Use when adding a one-time non-consumable in-app purchase to a Flutter app (e.g. "remove ads", "unlock pro") with the official in_app_purchase plugin — covers store connection, buy, restore, out-of-band delivery, acknowledgement, and flipping a local entitlement flag.
---

# One-time in-app purchase (non-consumable unlock)

A single non-consumable purchase (the classic "remove ads" / "go pro" unlock) with the
official `in_app_purchase` plugin: connect to the store once, load the localized price, drive
the buy sheet, honour restores, and flip a persisted entitlement flag that the rest of the app
already gates on. Client-side verification only (no backend) — the standard trade-off for a
local unlock with no server entitlement to protect.

Pairs with `flutter-admob-native-ads` (the flag it flips hides every ad slot) and
`flutter-scope-dependency-injection` (how the service reaches the UI).

## Contents

1. Store console setup
2. Dependency & the product ID
3. The service — a long-lived stream owner
4. Buy, restore, and out-of-band delivery
5. Acknowledgement (don't skip this)
6. Exposing it to the UI
7. Decoupling the grant (testability)
8. Gotchas

## 1. Store console setup

- **Play Console** → Monetize → Products → **In-app products** → create a *managed product*
  with ID `remove_ads` (must match the code). Activate it. The app must be uploaded to at
  least an internal-testing track and the tester account opted in, or `queryProductDetails`
  returns it as *not found*.
- **App Store Connect** (when iOS exists) → a **Non-Consumable** with the same product ID.

## 2. Dependency & the product ID

```yaml
dependencies:
  in_app_purchase: ^3.2.0
```

```dart
/// Must match the managed product ID in the store console.
const String kRemoveAdsProductId = 'remove_ads';

enum PurchaseOutcome { purchased, restored, cancelled, pending, error, unavailable }
```

## 3. The service — a long-lived stream owner

Create **one** `PurchaseService` in `main()` and keep it for the app's whole life. It listens
to `purchaseStream` the entire time so a purchase delivered *out of band* — a pending charge
that clears minutes later, or a store-initiated restore — still flips the flag. Model it as a
`ChangeNotifier` so the UI reacts to `pending`/`price`/`available` changes.

```dart
class PurchaseService extends ChangeNotifier {
  PurchaseService({required Future<void> Function() onAdFreeGranted, PurchaseBackend? backend})
      : _onAdFreeGranted = onAdFreeGranted, _backend = backend ?? _StoreBackend();

  bool _available = false;
  ProductDetails? _product;
  bool _pending = false;

  bool get available => _available;                 // store reachable?
  String? get price => _product?.price;             // localized: "€4.99", "R$ 29,90"
  bool get pending => _pending;                     // sheet open / charge pending
  bool get canBuy => _available && _product != null && !_pending;

  Future<void> init() async {
    try { _available = await _backend.isAvailable(); } catch (_) { _available = false; }
    if (!_available) { notifyListeners(); return; }       // sideload/web/no-Play -> degrade
    _sub = _backend.purchaseStream.listen(_onPurchaseUpdates, onError: (_) {});
    try {
      final resp = await _backend.queryProductDetails({kRemoveAdsProductId});
      if (resp.productDetails.isNotEmpty) _product = resp.productDetails.first;
    } catch (_) { /* leave null -> canBuy stays false, UI shows unavailable */ }
    notifyListeners();
  }
}
```

**Always show the store's localized `price`**, never a hardcoded string in your ARB — prices
vary by region and currency and change over time.

## 4. Buy, restore, and out-of-band delivery

`buy()` launches the sheet and resolves only when the transaction reaches a terminal state —
which arrives on the **stream**, not from the `buyNonConsumable` return value. Bridge the two
with a `Completer`:

```dart
Future<PurchaseOutcome> buy() async {
  if (!canBuy) return _product == null ? PurchaseOutcome.unavailable : PurchaseOutcome.pending;
  _buyCompleter = Completer<PurchaseOutcome>();
  _setPending(true);
  try {
    await _backend.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: _product!));
  } catch (_) { _setPending(false); _resolveBuy(PurchaseOutcome.error); return PurchaseOutcome.error; }
  return _buyCompleter!.future;
}

/// Store policy REQUIRES a restore path so a reinstalling user regains the unlock.
Future<bool> restore() async {
  if (!_available) return false;
  _restoreCompleter = Completer<bool>();
  try { await _backend.restorePurchases(); } catch (_) { return false; }
  return _restoreCompleter!.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
}

Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
  for (final p in purchases) {
    if (p.productID != kRemoveAdsProductId) continue;
    switch (p.status) {
      case PurchaseStatus.pending:  _setPending(true);
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _grant();
        _resolveBuy(p.status == PurchaseStatus.restored
            ? PurchaseOutcome.restored : PurchaseOutcome.purchased);
        _resolveRestore(true);
      case PurchaseStatus.error:    _resolveBuy(PurchaseOutcome.error);
      case PurchaseStatus.canceled: _resolveBuy(PurchaseOutcome.cancelled);
    }
    if (p.pendingCompletePurchase) {                 // see §5
      try { await _backend.completePurchase(p); } catch (_) {}
    }
  }
}
```

Play returns an already-owned product as **`restored`** even on a re-buy — treat `purchased`
and `restored` the same for granting; distinguish them only for the toast message.

## 5. Acknowledgement (don't skip this)

**Android auto-refunds any purchase not acknowledged within 3 days.** Every delivered
purchase — including restored ones — must be finished:

```dart
if (p.pendingCompletePurchase) await _backend.completePurchase(p);
```

Call it for `purchased` *and* `restored`. Forgetting this is the #1 cause of "users got
refunded and lost the unlock".

## 6. Exposing it to the UI

Wrap the service in an `InheritedNotifier` scope (see `flutter-scope-dependency-injection`):

```dart
class PurchaseScope extends InheritedNotifier<PurchaseService> {
  const PurchaseScope({super.key, required PurchaseService service, required super.child})
      : super(notifier: service);
  static PurchaseService of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<PurchaseScope>()!.notifier!;
}
```

An "upgrade" sheet then reads `price`, calls `buy()`, and toasts by `PurchaseOutcome`; a
"Restore purchases" row calls `restore()`. Because it's a `ChangeNotifier`, the sheet's
`pending`/`canBuy` state updates automatically.

## 7. Decoupling the grant (testability)

The service never touches your database. Granting the entitlement is an injected callback,
and the store API sits behind a `PurchaseBackend` interface so tests supply a fake without a
live store:

```dart
final purchases = PurchaseService(
  onAdFreeGranted: () => repos.settings.patch({'ads_removed': 1}),
);
unawaited(purchases.init());
```

`abstract class PurchaseBackend { isAvailable / purchaseStream / queryProductDetails /
buyNonConsumable / restorePurchases / completePurchase }` — production delegates to
`InAppPurchase.instance`; tests emit crafted `PurchaseDetails` onto a controllable stream.

## 8. Gotchas

- **Acknowledge every purchase** (§5) — 3-day auto-refund otherwise.
- **Terminal state comes on the stream**, not from `buyNonConsumable`. Bridge with a
  `Completer`, and null it out after completing so a stale completer can't double-complete.
- **`restore()` needs a timeout** — if the user owns nothing, *no* event arrives, so a bare
  `await` hangs forever. Resolve `false` after a few seconds.
- **Provide a Restore button** — required by both stores for non-consumables; rejection reason
  otherwise.
- **Degrade when `available` is false** (sideloaded APK, web, missing Play services) — show
  the feature as unavailable, never crash.
- **Listen for the app's whole life**, from `main()`, not just while a sheet is open — pending
  charges clear later and must still grant.
- **Client-side trust is fine here** because the unlock is local; if you ever gate a
  server-side entitlement, verify the purchase token on a backend instead.

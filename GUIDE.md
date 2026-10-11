# PassbackKit integration guide

Everything the [README](README.md) leaves out: the two quick starts, then
each part of the package in detail.

- [Installation](#installation)
- [Quick start](#quick-start)
- [The rules](#the-rules)
- [Already on RevenueCat or Adapty](#already-on-revenuecat-or-adapty)
- [Links into the app](#links-into-the-app)
- [Already paid? Enter your code](#already-paid-enter-your-code)
- [Restore](#restore)
- [In-App purchases](#in-app-purchases-passback-in-app)
- [Security](#security)

## Installation

### Xcode

1. File → **Add Package Dependencies…**
2. Enter `https://github.com/dev-projektstudio/passback-ios`
3. Choose **Up to Next Major Version** from `0.1.0`, and add the
   **PassbackKit** library to your app target.

### Package.swift

```swift
dependencies: [
  .package(url: "https://github.com/dev-projektstudio/passback-ios", from: "0.1.0"),
],
targets: [
  .target(name: "App", dependencies: [
    .product(name: "PassbackKit", package: "passback-ios"),
  ]),
]
```

Your app's public API key (`hk_…`) is under Settings → Developers on the
dashboard.

> [!IMPORTANT]
> Only the public key (`hk_…`) belongs in an app. The secret key (`sk_…`)
> is for your server; an app that ships it can be read by anyone who
> downloads it.

## Quick start

**Web checkout.** Nothing to declare in Xcode unless you want the instant
return.

```swift
import PassbackKit

let passback = Passback(origin: "https://www.passback.app", apiKey: "hk_…")

// Where you open the paywall — only where the rules allow a link out:
if await passback.webCheckoutAllowed() {
  passback.open(funnel: "trial-ended")
} else {
  showStoreKitPaywall()
}

// On launch and on scenePhase == .active:
let state = await passback.check()
if state.active { unlock() }
```

**In-App purchases.**

```swift
import PassbackKit

PassbackPurchases.configure(apiKey: "hk_…")   // once, at launch

let info = try await PassbackPurchases.shared.customerInfo()
if info.entitlements["pro"]?.isActive == true { unlock() }
```

The full In-App API is [below](#in-app-purchases-passback-in-app).

## The rules

Steering a customer from an iOS app to a web checkout is allowed in the
United States and the EU today and not elsewhere. `webCheckoutAllowed()`
reads the storefront from StoreKit and compares it with the list set for
your app on the dashboard (Settings → Where the button shows). Outside the
list, show your App Store paywall and nothing of ours. Where it is allowed,
keep the App Store purchase visible beside the web one, and price the web
plan on its own terms rather than copying the App Store price.

## Already on RevenueCat or Adapty

Give the SDK your id for the person and every web purchase is granted on
their profile server-side. Your existing entitlement check starts saying
yes; nothing else changes.

```swift
let passback = Passback(origin: "…", apiKey: "hk_…", userID: Purchases.shared.appUserID)
```

Set the platform's secret key and the entitlement or access level under
Settings → RevenueCat and Adapty.

## Links into the app

Hand every URL the app is opened with to `handle`. It exchanges the two that
are ours and returns nil for anything else:

```swift
.onOpenURL { url in Task { _ = await passback.handle(url) } }
```

- `yourscheme://handoff?token=…` — the instant return after paying. Register
  the scheme under URL Types and enter it on the dashboard.
- `https://www.passback.app/r/<app>/…` — the restore link from the
  receipt email, as a universal link. Add the Associated Domains capability
  with `applinks:www.passback.app` and enter your Apple team id on
  the dashboard; the site's `apple-app-site-association` lists your app.

## Already paid? Enter your code

A customer who paid on the web before installing sees six digits on the
confirmation and gets them in the receipt. An "enter your code" field on
your paywall turns them into the subscription:

```swift
let state = await passback.claim(code: typed)   // spaces are fine
if state.active { unlock() }
```

Single use, good for a day, only valid with your key. A wrong code comes
back as `unavailable` with the reason.

## Restore

For "Already subscribed?" on your paywall. Sends a link that opens the app
with the subscription on it, if there is one on that address:

```swift
let accepted = await passback.restore(email: address)
// Tell them to check their email either way.
```

## In-App purchases (Passback In-App)

`PassbackPurchases` is the other half of the package: StoreKit 2 purchases,
validated on the server, with one answer — `CustomerInfo` — for what the
customer is entitled to, whether they paid through the App Store, Google
Play or Passback's web checkout. It needs the In-App package on your
account; configure products, entitlements and offerings under In-app on the
dashboard, and the App Store Server Notifications URL under In-app → Stores.

```swift
import PassbackKit

// Once, as early as possible (App.init or didFinishLaunching), so a renewal
// or an Ask to Buy approval StoreKit delivers at launch is not missed:
PassbackPurchases.configure(apiKey: "hk_…")             // your public key, never sk_

// Gate a feature — cheap; answered from memory for five minutes:
let info = try await PassbackPurchases.shared.customerInfo()
if info.entitlements["pro"]?.isActive == true { unlock() }

// The paywall — offerings from the dashboard, with StoreKit products loaded:
let offerings = try await PassbackPurchases.shared.offerings()
for package in offerings.current?.availablePackages ?? [] {
  print(package.identifier, package.storeProduct.displayPrice)
}

// Buy:
do {
  let result = try await PassbackPurchases.shared.purchase(package: package)
  if !result.userCancelled, result.customerInfo.entitlements["pro"]?.isActive == true { unlock() }
} catch PurchasesError.paymentPending {
  // Ask to Buy: it arrives through customerInfoStream if approved.
} catch PurchasesError.receiptNotAccepted {
  // They paid; we could not reach the server. It is retried — say so kindly.
}

// "Restore purchases" (may show an App Store sign-in):
let restored = try await PassbackPurchases.shared.restorePurchases()

// Sign in and out with your own account ids:
let (customer, created) = try await PassbackPurchases.shared.logIn(account.id)
try await PassbackPurchases.shared.logOut()

// Attributes, shown on the dashboard and sent with webhooks:
try await PassbackPurchases.shared.setEmail("ada@example.com")
try await PassbackPurchases.shared.setAttributes(["plan_source": "onboarding", "old_key": nil])

// Keep the UI current — renewals, refunds, approvals, every call's answer:
Task {
  for await info in PassbackPurchases.shared.customerInfoStream {
    isPro = info.entitlements["pro"]?.isActive == true
  }
}
```

What it does on the wire: `GET /api/v1/customers/{id}`, `GET
/api/v1/offerings`, `POST /api/v1/receipts` with each transaction's
`jwsRepresentation`, `POST /api/v1/customers/login`, `POST
/api/v1/customers/{id}/attributes` — each with `Authorization: Bearer hk_…`,
`X-Passback-Platform` and `X-Passback-App-Version`, through the same
hardened session as `Passback` (`pins:` and `minimumTLS:` work the same way).

**Finishing.** A transaction is finished with StoreKit only after the server
has accepted it. If the request fails, the purchase throws
`receiptNotAccepted` but is not lost: StoreKit hands every unfinished
transaction to the package's `Transaction.updates` listener at the next
launch, and `syncPurchases()` sends it again on demand.

**Who the customer is.** Until `logIn`, the customer is
`$PassbackAnonymousID:<uuid>`, kept in UserDefaults and (the anonymous id
only) the Keychain, so a reinstall that never signs in comes back as the same
customer. A signed-in id is not kept in the Keychain: a reinstall must not
wake up as whoever used the device before. When the app user id is a UUID it
is also sent to Apple as the `appAccountToken`, so a store notification can
be tied to the customer before the app has said anything.

**`isActive` and the clock.** `EntitlementInfo.isActive` is the server's
answer *and* the device's clock: a cached answer stops granting access when
its expiry (plus any grace period) passes, with no request. Offline,
`customerInfo()` serves the last answer it has; it never invents one.

**Migrating from RevenueCat.** The shapes are deliberately close —
`customerInfo()`, `offerings()`, `purchase(package:)`, `logIn`, `logOut`,
`entitlements[…].isActive`, `$rc_monthly`-style package ids — and
`syncPurchases()` sends existing subscribers' transactions on first launch
without any UI.

## Security

What the package does on the wire, and what it cannot do for you.

**Its own session.** The package builds an ephemeral `URLSession`: no
cookies, no cache, a fifteen-second request timeout, and TLS 1.3 as the
oldest protocol it will speak (`minimumTLS:` lowers it if you must). Pass
your own `session:` only in tests.

**Public-key pinning, optional.** Give the initialiser `pins:` — base64
SHA-256 digests of SubjectPublicKeyInfo — and every connection must present
a chain in which some certificate's key matches a pin, after the system has
already judged the chain valid. Passback's origin is served through Vercel
with Let's Encrypt certificates, whose leaf rotates every ninety days, so pin
the ISRG Root X1 public key rather than the leaf:

```sh
curl -sO https://letsencrypt.org/certs/isrgrootx1.pem
openssl x509 -in isrgrootx1.pem -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64
```

```swift
let passback = Passback(origin: "https://www.passback.app", apiKey: "hk_…",
                        pins: ["<the digest above>"])
```

If Let's Encrypt ever changes its root, an app with only that pin stops
reaching us until it ships an update; keep the pin list short and watch
their announcements, or leave `pins` empty and let the system trust store
decide.

**Settlement.** A customer who pays and flips straight back can ask before
the payment has settled on our side. The server answers `pending: true`
and `check()` waits — four more asks over about five seconds — before
saying `found: false`. `check(waitingForSettlement: false)` takes the first
answer. A network failure is never retried; it comes back as
`unavailable`.

**One presentation per credential.** `handle` remembers the tokens and
restore links it has already sent in this process and returns `nil` for a
repeat, so SwiftUI delivering the same `onOpenURL` twice does not surface a
"token already used" error. A code with the wrong number of digits is
refused before any request is made, so a typo does not spend one of the
code's ten server-side attempts.

**What this does not do.** Pinning raises the cost of running the app
through an interception proxy on a jailbroken device; it does not make the
device honest. The server's answer is the truth. Do not store `active` and
trust it later, do not unlock from a value your own code produced, and do
not derive anything financial from what the client believes — ask the
package, and ask again when the app comes to the foreground.

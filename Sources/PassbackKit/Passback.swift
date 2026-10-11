import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The whole integration, in one object.
///
/// ```swift
/// let passback = Passback(origin: "https://www.passback.app", apiKey: "hk_…")
///
/// // Only where the rules allow a link out of the app:
/// if await passback.webCheckoutAllowed() {
///   // Open the paywall — the install id rides along on the URL.
///   passback.open(funnel: "trial-ended")
/// }
///
/// // On launch and when the app comes to the foreground:
/// let state = await passback.check()
/// if state.active { unlock() }
///
/// // Deep links and universal links, if the app registers either:
/// .onOpenURL { url in Task { _ = await passback.handle(url) } }
///
/// // "Already subscribed?" — sends a link that opens the app:
/// await passback.restore(email: address)
///
/// // "Already paid? Enter your code" — the six digits from the confirmation:
/// let state = await passback.claim(code: typed)
/// ```
///
/// What it does for you: makes an install id once and keeps it in the Keychain; puts it on the
/// funnel URL as `?d=` (and your own user id as `?u=` if you give one); asks
/// the entitlement endpoint about it with your key; and, if a deep link or a
/// restore link arrives, exchanges what it carries. The answer is one struct
/// either way. Nothing here needs anything declared in Xcode unless you want
/// the instant return.
public final class Passback {
  /// The app's marketing version, sent with every call so the delivery
  /// record can say which build opened the purchase.
  static let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? ""
    return build.isEmpty ? short : "\(short) (\(build))"
  }()

  public let origin: URL
  public let apiKey: String

  /// Your own id for the person — RevenueCat's app user id, Adapty's
  /// customer user id, or your account id. Optional. With it, a web purchase
  /// is granted on that profile server-side, so an app that already asks
  /// RevenueCat or Adapty needs no other check.
  public var userID: String?

  private let defaults: UserDefaults
  private let session: URLSession
  private let presented = Presented()

  /// - Parameters:
  ///   - session: An escape hatch for tests. Nil builds the package's own
  ///     session: ephemeral (no cookies, no cache), TLS 1.3 or newer, a
  ///     fifteen-second request timeout, and public-key pinning when `pins`
  ///     is given. See the README's Security section.
  ///   - minimumTLS: The oldest TLS the package will speak. 1.3 by default;
  ///     the origin supports it, and a downgrade is the first thing an
  ///     interception proxy tries.
  ///   - pins: Base64 SHA-256 digests of SubjectPublicKeyInfo. Empty means
  ///     the system trust store decides. Any certificate in the served chain
  ///     matching a pin is accepted, so a root or intermediate pin survives
  ///     leaf rotation.
  public init(
    origin: String,
    apiKey: String,
    userID: String? = nil,
    defaults: UserDefaults = .standard,
    session: URLSession? = nil,
    minimumTLS: tls_protocol_version_t = .TLSv13,
    pins: [String] = []
  ) {
    self.origin = URL(string: origin)!
    self.apiKey = apiKey
    self.userID = userID
    self.defaults = defaults
    self.session = session ?? Self.makeSession(minimumTLS: minimumTLS, pins: pins)
  }

  // MARK: Transport

  /// Internal rather than private so `PassbackPurchases` speaks through the
  /// same hardened session and the same pins.
  static func makeSession(minimumTLS: tls_protocol_version_t, pins: [String]) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.tlsMinimumSupportedProtocolVersion = minimumTLS
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 15
    guard !pins.isEmpty else { return URLSession(configuration: configuration) }
    return URLSession(configuration: configuration, delegate: Pinning(pins: Set(pins)), delegateQueue: nil)
  }

  // MARK: The install id

  private static let installKey = "passback.install"
  private static let legacyInstallKey = "handoff.install"

  /// One id per install, made the first time it is asked for and kept in the
  /// Keychain, so it survives a reinstall and never leaves the device. Not an
  /// Apple identifier and not tied to the person — it means "this install"
  /// and nothing else. Falls back to UserDefaults where the Keychain is not
  /// available, and adopts an id an earlier version stored there.
  public var installID: String {
    if let kept = Self.keychainRead() { return kept }
    if let stored = defaults.string(forKey: Self.installKey) ?? defaults.string(forKey: Self.legacyInstallKey) {
      Self.keychainWrite(stored)
      return stored
    }
    let fresh = UUID().uuidString
    if !Self.keychainWrite(fresh) { defaults.set(fresh, forKey: Self.installKey) }
    return fresh
  }

  private static let keychainService = "app.passback.install"

  @discardableResult
  private static func keychainWrite(_ value: String) -> Bool {
    #if canImport(Security)
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "install",
    ]
    SecItemDelete(query as CFDictionary)
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    #else
    return false
    #endif
  }

  private static func keychainRead() -> String? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "install",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8), !value.isEmpty
    else { return nil }
    return value
    #else
    return nil
    #endif
  }

  // MARK: Where the button may show

  private static let regionsKey = "handoff.regions"
  private static let regionsAtKey = "handoff.regions.at"

  /// Whether this storefront is one where the app may show a button that
  /// leads to a web checkout. The list is set per app on the dashboard and
  /// read from `/api/v1/config`; the last answer is kept for a day, so a
  /// launch on a train is answered from the previous one. With no answer
  /// at all (first launch, offline) the built-in default applies: the
  /// United States and the EU.
  ///
  /// The storefront comes from StoreKit where it can — that is the country
  /// Apple bills in, which is what the rules are about — and from the
  /// device's region otherwise.
  public func webCheckoutAllowed() async -> Bool {
    let regions = await regions()
    if regions.contains("*") { return true }
    guard let code = await storefront() else { return false }
    return regions.contains(code.uppercased())
  }

  private func regions() async -> [String] {
    let fetchedAt = defaults.double(forKey: Self.regionsAtKey)
    let stored = defaults.stringArray(forKey: Self.regionsKey)
    if let stored, Date().timeIntervalSince1970 - fetchedAt < 86_400 { return stored }

    var request = URLRequest(url: origin.appendingPathComponent("api/v1/config"))
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-App-Version")

    if let (data, _) = try? await session.data(for: request),
       let config = try? JSONDecoder().decode(Config.self, from: data) {
      defaults.set(config.webCheckoutRegions, forKey: Self.regionsKey)
      defaults.set(Date().timeIntervalSince1970, forKey: Self.regionsAtKey)
      return config.webCheckoutRegions
    }

    return stored ?? Self.defaultRegions
  }

  private func storefront() async -> String? {
    #if canImport(StoreKit)
    if let store = await Storefront.current { return store.countryCode }
    #endif
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      return Locale.current.region?.identifier
    }
    return Locale.current.regionCode
  }

  /// The United States and the EU member states — where a link out is
  /// permitted today. The dashboard's list overrides this once fetched.
  public static let defaultRegions = [
    "US", "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU",
    "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
  ]

  // MARK: Opening the funnel

  /// The funnel's URL with the install id on it, and your user id if set.
  /// Open it however you like — `UIApplication.shared.open`,
  /// `SFSafariViewController`, a `Link`.
  public func url(funnel slug: String) -> URL {
    var components = URLComponents(url: origin.appendingPathComponent("f/\(slug)"), resolvingAgainstBaseURL: false)!
    var items = [URLQueryItem(name: "d", value: installID)]
    if let userID, !userID.isEmpty { items.append(URLQueryItem(name: "u", value: userID)) }
    components.queryItems = items
    return components.url!
  }

  #if canImport(UIKit) && !os(watchOS)
  /// Opens the funnel in the system browser.
  @MainActor
  public func open(funnel slug: String) {
    UIApplication.shared.open(url(funnel: slug))
  }
  #endif

  // MARK: Asking

  /// The subscription for this install, from the entitlement endpoint. Call on
  /// launch and whenever the app comes to the foreground; the answer is the
  /// same shape every time. A person with no purchase is `found: false`.
  ///
  /// A customer who pays and flips straight back to the app can ask before
  /// the payment has settled on our side. The server says so with
  /// `pending: true`, and by default this waits — 0.5, 1, 1.5 and 2 seconds,
  /// about five in all — and returns the first answer that is settled. Pass
  /// `waitingForSettlement: false` to take the first answer as it comes. A
  /// network failure is never retried: it is `unavailable`, not pending.
  public func check(waitingForSettlement wait: Bool = true) async -> Entitlement {
    await settled(wait) { await self.get(["device": self.installID]) }
  }

  /// Same as `check()`, by the address they paid with — for apps that have
  /// accounts of their own.
  public func check(email: String, waitingForSettlement wait: Bool = true) async -> Entitlement {
    await settled(wait) { await self.get(["email": email]) }
  }

  /// Same as `check()`, by your own id for the person — the one put on the
  /// funnel URL as `?u=`.
  public func check(user: String, waitingForSettlement wait: Bool = true) async -> Entitlement {
    await settled(wait) { await self.get(["user": user]) }
  }

  /// The settlement wait, in seconds, between one answer and the next ask.
  static let settlementDelays: [Double] = [0.5, 1.0, 1.5, 2.0]

  private func settled(_ wait: Bool, _ fetch: () async -> Entitlement) async -> Entitlement {
    var answer = await fetch()
    guard wait else { return answer }
    for delay in Self.settlementDelays {
      guard answer.pending, !answer.found, answer.unavailableReason == nil else { return answer }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      answer = await fetch()
    }
    return answer
  }

  private func get(_ query: [String: String]) async -> Entitlement {
    var components = URLComponents(url: origin.appendingPathComponent("api/v1/entitlement"), resolvingAgainstBaseURL: false)!
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }

    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-App-Version")
    return await perform(request)
  }

  // MARK: Links into the app

  /// Hand every URL the app is opened with here. Two are ours:
  ///
  ///   `scheme://handoff?token=…`     the instant return after paying, if
  ///                                  the app registers a URL scheme
  ///   `https://<origin>/r/<app>/…`   the restore link from the receipt
  ///                                  email, as a universal link
  ///
  /// Either is exchanged and the answer returned. Nil for a URL that is not
  /// ours, so this can sit first in an `onOpenURL` without a check.
  ///
  /// Each credential is presented to the server once per process. SwiftUI
  /// delivers the same `onOpenURL` more than once on some paths, and a token
  /// exchanged a second time is refused as used — so a repeat is answered
  /// with nil here rather than turned into a confusing error.
  public func handle(_ url: URL) async -> Entitlement? {
    if url.host == "handoff",
       let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
         .queryItems?.first(where: { $0.name == "token" })?.value {
      guard presented.first("token:" + token) else { return nil }
      return await exchange(["token": token])
    }

    if url.host == origin.host {
      let parts = url.pathComponents.filter { $0 != "/" }
      if parts.count >= 3, parts[0] == "r" {
        guard presented.first("restore:" + parts[2]) else { return nil }
        return await exchange(["restore": parts[2]])
      }
    }

    return nil
  }

  private func exchange(_ body: [String: String]) async -> Entitlement {
    var request = URLRequest(url: origin.appendingPathComponent("api/v1/entitlement"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-App-Version")
    request.httpBody = try? JSONEncoder().encode(body)
    return await perform(request)
  }

  // MARK: The code

  /// "Already paid? Enter your code." The six digits shown on the web
  /// confirmation and printed in the receipt, for the customer who paid
  /// before installing and arrived here with nothing else to hand. Spaces
  /// are fine. Single use, a day, scoped to this app. The answer is the same
  /// struct as every other door; a wrong code is `unavailable` with the
  /// server's reason, not `found: false`.
  public func claim(code: String) async -> Entitlement {
    let digits = code.filter { $0.isNumber }
    // A typo is settled here. Every guess the server sees counts against the
    // code's ten, and against this app's hourly budget; a five-digit slip
    // should cost neither.
    guard digits.count == 6 else { return .unavailable(reason: "Enter the six digits.") }
    var request = URLRequest(url: origin.appendingPathComponent("api/v1/entitlement"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-App-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(["code": digits])
    return await perform(request)
  }

  // MARK: Restore

  /// "Already subscribed?" Sends the person a link that opens the app with
  /// their subscription on it, if there is one on that address. Returns
  /// true when the request was accepted — which it is whether or not the
  /// address has paid, so tell them to check their email either way.
  public func restore(email: String) async -> Bool {
    var request = URLRequest(url: origin.appendingPathComponent("api/v1/restore"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-App-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(["email": email])

    guard let (_, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse
    else { return false }
    return http.statusCode == 202
  }

  // MARK: -

  private func perform(_ request: URLRequest) async -> Entitlement {
    do {
      let (data, _) = try await session.data(for: request)
      let decoder = JSONDecoder()
      if let state = try? decoder.decode(Entitlement.self, from: data) { return state }
      if let failure = try? decoder.decode(Failure.self, from: data) {
        return .unavailable(reason: failure.message)
      }
      return .unavailable(reason: "Unreadable answer")
    } catch {
      return .unavailable(reason: error.localizedDescription)
    }
  }
}

/// What the entitlement endpoint says. `active` is the answer; the rest is
/// context. `unavailable` is a network or server failure — not a person with
/// no subscription, which is `found: false` with a 200.
public struct Entitlement: Decodable, Equatable {
  public let found: Bool
  public let active: Bool
  public let status: String?
  public let email: String?
  public let currentPeriodEnd: Date?
  public let cancelAtPeriodEnd: Bool?
  public let plan: Plan?
  /// True when a checkout for this install or address is in flight and has
  /// not settled on the server yet. `check()` waits on it by default.
  public let pending: Bool
  /// Set only when the request itself failed. Treat as "unknown", not "no".
  public let unavailableReason: String?

  public struct Plan: Decodable, Equatable {
    public let id: String
    public let name: String
    public let amountCents: Int
    public let currency: String
    public let interval: String
    public let intervalCount: Int

    enum CodingKeys: String, CodingKey {
      case id, name, currency, interval
      case amountCents = "amount_cents"
      case intervalCount = "interval_count"
    }
  }

  enum CodingKeys: String, CodingKey {
    case found, active, status, email, plan, pending
    case currentPeriodEnd = "current_period_end"
    case cancelAtPeriodEnd = "cancel_at_period_end"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    found = try c.decode(Bool.self, forKey: .found)
    active = try c.decode(Bool.self, forKey: .active)
    status = try c.decodeIfPresent(String.self, forKey: .status)
    email = try c.decodeIfPresent(String.self, forKey: .email)
    cancelAtPeriodEnd = try c.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd)
    plan = try c.decodeIfPresent(Plan.self, forKey: .plan)
    pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    if let raw = try c.decodeIfPresent(String.self, forKey: .currentPeriodEnd) {
      currentPeriodEnd = ISO8601DateFormatter.withFractions.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    } else {
      currentPeriodEnd = nil
    }
    unavailableReason = nil
  }

  init(found: Bool, active: Bool, unavailableReason: String?) {
    self.found = found
    self.active = active
    self.status = nil
    self.email = nil
    self.currentPeriodEnd = nil
    self.cancelAtPeriodEnd = nil
    self.plan = nil
    self.pending = false
    self.unavailableReason = unavailableReason
  }

  static func unavailable(reason: String) -> Entitlement {
    Entitlement(found: false, active: false, unavailableReason: reason)
  }
}

private struct Config: Decodable {
  let webCheckoutRegions: [String]

  enum CodingKeys: String, CodingKey {
    case webCheckoutRegions = "web_checkout_regions"
  }
}

private struct Failure: Decodable {
  let error: String
  let message: String
}

private extension ISO8601DateFormatter {
  static let withFractions: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}


/// The credentials already presented in this process. A set behind a lock
/// rather than an actor, so `handle` can decide synchronously before it
/// awaits anything.
private final class Presented {
  private var seen = Set<String>()
  private let lock = NSLock()

  /// True the first time a value is offered, false after that.
  func first(_ value: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return seen.insert(value).inserted
  }
}

/// Public-key pinning, as a session delegate.
///
/// The system evaluates the chain first — an expired or untrusted
/// certificate fails before any pin is looked at. Then every certificate in
/// the served chain has its SubjectPublicKeyInfo rebuilt (the key bytes the
/// Security framework hands back have no ASN.1 header; the standard one for
/// the key's type and size is put back), hashed with SHA-256 and compared
/// with the pins. One match anywhere in the chain is enough, which is what
/// lets a root or intermediate pin outlive the ninety-day leaf.
private final class Pinning: NSObject, URLSessionDelegate {
  private let pins: Set<String>

  init(pins: Set<String>) {
    self.pins = pins
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    #if canImport(Security) && canImport(CryptoKit)
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust
    else { return completionHandler(.performDefaultHandling, nil) }

    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
      return completionHandler(.cancelAuthenticationChallenge, nil)
    }

    let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    for certificate in chain {
      guard let key = SecCertificateCopyKey(certificate),
            let spki = Self.subjectPublicKeyInfo(of: key)
      else { continue }
      let digest = Data(SHA256.hash(data: spki)).base64EncodedString()
      if pins.contains(digest) {
        return completionHandler(.useCredential, URLCredential(trust: trust))
      }
    }

    completionHandler(.cancelAuthenticationChallenge, nil)
    #else
    completionHandler(.performDefaultHandling, nil)
    #endif
  }

  #if canImport(Security)
  /// The DER SubjectPublicKeyInfo for a key: the type's fixed header, then
  /// the raw key bytes the framework exports.
  private static func subjectPublicKeyInfo(of key: SecKey) -> Data? {
    guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
          let type = attributes[kSecAttrKeyType] as? String,
          let bits = attributes[kSecAttrKeySizeInBits] as? Int,
          let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
    else { return nil }

    // Compared as Swift strings: a CFString constant compared by reference
    // is a pin that fails on some devices and passes on others.
    let rsa = type == (kSecAttrKeyTypeRSA as String)
    let ec = type == (kSecAttrKeyTypeECSECPrimeRandom as String)

    let header: [UInt8]
    switch (rsa, ec, bits) {
    case (true, _, 2048):
      header = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00]
    case (true, _, 4096):
      header = [0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00]
    case (_, true, 256):
      header = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
    case (_, true, 384):
      header = [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
    default:
      return nil
    }
    return Data(header) + raw
  }
  #endif
}

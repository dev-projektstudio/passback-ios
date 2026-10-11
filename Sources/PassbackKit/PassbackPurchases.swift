#if canImport(StoreKit)
import Foundation
import StoreKit

/// Passback In-App: StoreKit 2 purchases, validated on the server, with one
/// answer for what the customer is entitled to — App Store, Google Play, and
/// web purchases through Passback's checkout alike.
///
/// ```swift
/// // Once, at launch:
/// PassbackPurchases.configure(apiKey: "hk_…")
///
/// // Gate a feature:
/// let info = try await PassbackPurchases.shared.customerInfo()
/// if info.entitlements["pro"]?.isActive == true { unlock() }
///
/// // Show the paywall:
/// let offerings = try await PassbackPurchases.shared.offerings()
/// for package in offerings.current?.availablePackages ?? [] {
///   print(package.storeProduct.displayName, package.storeProduct.displayPrice)
/// }
///
/// // Buy:
/// let result = try await PassbackPurchases.shared.purchase(package: package)
/// if !result.userCancelled, result.customerInfo.entitlements["pro"]?.isActive == true { unlock() }
/// ```
///
/// What it does for you: keeps an app user id (anonymous until `logIn`),
/// listens to `Transaction.updates` from the moment it is configured, sends
/// every signed transaction to the server, and finishes a transaction only
/// once the server has accepted it — so a purchase made offline, or one
/// whose request failed, is sent again rather than lost.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public final class PassbackPurchases: @unchecked Sendable {
  /// How long a CustomerInfo answer is served from memory before the next
  /// `customerInfo()` asks again.
  public static let cacheLifetime: TimeInterval = 5 * 60

  // MARK: Configuring

  private static let configured = Locked<PassbackPurchases?>(nil)

  /// Sets up the shared instance and starts listening for transactions. Call
  /// it once, as early as the app can — `application(_:didFinishLaunching…)`
  /// or the `App` initialiser — so a renewal or an Ask to Buy approval that
  /// StoreKit delivers at launch is not missed.
  ///
  /// - Parameters:
  ///   - apiKey: The app's public key (`hk_…`). Never the secret one.
  ///   - appUserID: Your own id for the person, if they are signed in. Nil
  ///     keeps the id from the last launch, or makes an anonymous one.
  ///   - session, minimumTLS, pins: As for `Passback` — see the README's
  ///     Security section. Nil `session` builds the hardened one.
  @discardableResult
  public static func configure(
    apiKey: String,
    origin: String = "https://www.passback.app",
    appUserID: String? = nil,
    defaults: UserDefaults = .standard,
    session: URLSession? = nil,
    minimumTLS: tls_protocol_version_t = .TLSv13,
    pins: [String] = []
  ) -> PassbackPurchases {
    let instance = PassbackPurchases(
      api: PurchasesAPI(
        origin: URL(string: origin)!,
        apiKey: apiKey,
        session: session ?? Passback.makeSession(minimumTLS: minimumTLS, pins: pins)
      ),
      appUserID: appUserID,
      defaults: defaults
    )
    let previous = configured.withLock { slot -> PassbackPurchases? in
      let old = slot
      slot = instance
      return old
    }
    previous?.stop()
    instance.start()
    return instance
  }

  /// The configured instance. Configuring is a precondition, as it is in
  /// every SDK of this kind: a call before it is a bug to find in
  /// development, not a state to handle.
  public static var shared: PassbackPurchases {
    guard let instance = configured.withLock({ $0 }) else {
      preconditionFailure(PurchasesError.notConfigured.errorDescription!)
    }
    return instance
  }

  public static var isConfigured: Bool { configured.withLock { $0 != nil } }

  // MARK: State

  private struct State {
    var appUserID: String
    var customerInfo: CustomerInfo?
    var customerInfoAt: Date?
    var offerings: Offerings?
    var offeringsAt: Date?
    var listeners: [UUID: AsyncStream<CustomerInfo>.Continuation] = [:]
  }

  private let api: PurchasesAPI
  private let identity: PurchasesIdentity
  private let defaults: UserDefaults
  private let state: Locked<State>
  private let tasks = Locked<[Task<Void, Never>]>([])

  private init(api: PurchasesAPI, appUserID: String?, defaults: UserDefaults) {
    // Built in locals first: a class may not read its own stored properties
    // until every one of them is set.
    let identity = PurchasesIdentity(defaults: defaults)
    self.api = api
    self.defaults = defaults
    self.identity = identity

    let given = appUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let id: String
    if let given, !given.isEmpty {
      id = given
    } else {
      id = identity.load() ?? PurchasesIdentity.newAnonymousID()
    }
    identity.save(id)

    var initial = State(appUserID: id)
    if let saved = PassbackPurchases.loadSavedCustomerInfo(defaults), saved.appUserID == id {
      // Served as stale: it is there for offline launches and for the first
      // value of `customerInfoStream`, not to skip the first request.
      initial.customerInfo = saved.info
      initial.customerInfoAt = .distantPast
    }
    self.state = Locked(initial)
  }

  deinit { stop() }

  /// The id the server knows this customer by right now.
  public var appUserID: String { state.withLock { $0.appUserID } }

  /// True until `logIn` — the id is one this package made up.
  public var isAnonymous: Bool { PurchasesIdentity.isAnonymous(appUserID) }

  // MARK: Listening

  private func start() {
    // Transactions that arrive outside `purchase` — renewals, Ask to Buy
    // approvals, purchases on another device, refunds, offer codes redeemed
    // in the App Store. StoreKit also replays every unfinished transaction
    // here once, just after launch, which is what picks up a purchase whose
    // receipt could not be posted last time.
    let updates = Task.detached(priority: .utility) { [weak self] in
      for await result in StoreKit.Transaction.updates {
        guard let self else { return }
        _ = try? await self.ingest([result])
      }
    }
    tasks.withLock { $0 = [updates] }
  }

  private func stop() {
    let running = tasks.withLock { list -> [Task<Void, Never>] in
      let all = list
      list = []
      return all
    }
    running.forEach { $0.cancel() }
    let listeners = state.withLock { s -> [AsyncStream<CustomerInfo>.Continuation] in
      let all = Array(s.listeners.values)
      s.listeners = [:]
      return all
    }
    listeners.forEach { $0.finish() }
  }

  /// Sends the signed transactions to the server and, once it has accepted
  /// them, finishes each with StoreKit. A failure leaves them unfinished, to
  /// be sent again by `syncPurchases()` or on the next launch.
  @discardableResult
  private func ingest(_ results: [VerificationResult<StoreKit.Transaction>]) async throws -> CustomerInfo {
    let id = appUserID
    let info = try await postReceipt(results.map(\.jwsRepresentation), appUserID: id)
    for result in results {
      await result.unsafePayloadValue.finish()
    }
    return info
  }

  private func postReceipt(_ signed: [String], appUserID id: String) async throws -> CustomerInfo {
    let info: CustomerInfo
    do {
      info = try await api.post(["api", "v1", "receipts"], body: ReceiptBody(appUserID: id, signedTransactions: signed))
    } catch let error as PurchasesError {
      throw PurchasesError.receiptNotAccepted(error.errorDescription ?? "\(error)")
    }
    remember(info, for: id)
    return info
  }

  // MARK: CustomerInfo

  public enum FetchPolicy: Sendable {
    /// The cached answer if it is under five minutes old, else a request —
    /// and the stale cache if that request cannot reach the server.
    case cachedOrFetched
    /// Always a request.
    case fetchCurrent
    /// Never a request; throws `.network` when nothing is cached.
    case fromCacheOnly
  }

  /// What this customer is entitled to. Call it where a feature is gated and
  /// when the app returns to the foreground; it is cheap inside the cache
  /// lifetime.
  public func customerInfo(fetchPolicy: FetchPolicy = .cachedOrFetched) async throws -> CustomerInfo {
    let (id, cached, at) = state.withLock { ($0.appUserID, $0.customerInfo, $0.customerInfoAt) }
    let fresh = at.map { Date().timeIntervalSince($0) < Self.cacheLifetime } ?? false

    switch fetchPolicy {
    case .fromCacheOnly:
      guard let cached else { throw PurchasesError.network("No customer info is cached yet.") }
      return cached
    case .cachedOrFetched where fresh && cached != nil:
      return cached!
    default:
      break
    }

    do {
      let info: CustomerInfo = try await api.get(["api", "v1", "customers", id])
      remember(info, for: id)
      return info
    } catch PurchasesError.network(let reason) {
      // Offline: the last answer beats no answer, and `isActive` still
      // checks its expiry against the clock.
      if fetchPolicy == .cachedOrFetched, let cached { return cached }
      throw PurchasesError.network(reason)
    }
  }

  /// Forget the cached answer, so the next `customerInfo()` asks the server.
  public func invalidateCustomerInfoCache() {
    state.withLock { $0.customerInfoAt = .distantPast }
  }

  /// Every new CustomerInfo, starting with the cached one if there is one:
  /// after each call that returns one, and whenever a transaction arrives
  /// through StoreKit on its own (a renewal, an approval, a refund). Each
  /// access makes a new stream; iterate it in a long-lived task.
  public var customerInfoStream: AsyncStream<CustomerInfo> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let key = UUID()
      continuation.onTermination = { [weak self] _ in
        self?.state.withLock { $0.listeners[key] = nil }
      }
      let current = state.withLock { s -> CustomerInfo? in
        s.listeners[key] = continuation
        return s.customerInfo
      }
      if let current { continuation.yield(current) }
    }
  }

  /// Caches an answer and tells the listeners — unless the customer changed
  /// while it was in flight, in which case it is someone else's and dropped.
  private func remember(_ info: CustomerInfo, for id: String) {
    let listeners = state.withLock { s -> [AsyncStream<CustomerInfo>.Continuation]? in
      guard s.appUserID == id else { return nil }
      s.customerInfo = info
      s.customerInfoAt = Date()
      return Array(s.listeners.values)
    }
    guard let listeners else { return }
    Self.saveCustomerInfo(info, appUserID: id, defaults)
    listeners.forEach { $0.yield(info) }
  }

  private static let savedKey = "passback.purchases.customerInfo"

  private struct Saved: Codable {
    let appUserID: String
    let info: CustomerInfo
  }

  private static func saveCustomerInfo(_ info: CustomerInfo, appUserID: String, _ defaults: UserDefaults) {
    guard let data = try? PurchasesJSON.encoder.encode(Saved(appUserID: appUserID, info: info)) else { return }
    defaults.set(data, forKey: savedKey)
  }

  private static func loadSavedCustomerInfo(_ defaults: UserDefaults) -> Saved? {
    guard let data = defaults.data(forKey: savedKey) else { return nil }
    return try? PurchasesJSON.decoder.decode(Saved.self, from: data)
  }

  // MARK: Offerings

  /// The offerings from the dashboard, each package joined to its StoreKit
  /// `Product`. Cached for five minutes like CustomerInfo.
  public func offerings(fetchPolicy: FetchPolicy = .cachedOrFetched) async throws -> Offerings {
    let (id, cached, at) = state.withLock { ($0.appUserID, $0.offerings, $0.offeringsAt) }
    if fetchPolicy != .fetchCurrent, let cached, let at, Date().timeIntervalSince(at) < Self.cacheLifetime {
      return cached
    }
    if fetchPolicy == .fromCacheOnly {
      guard let cached else { throw PurchasesError.network("No offerings are cached yet.") }
      return cached
    }

    let wire: WireOfferings = try await api.get(["api", "v1", "offerings"], query: ["app_user_id": id])
    let ids = Set(wire.offerings.flatMap { $0.packages.compactMap(\.products.appStore) })
    var products: [Product] = []
    if !ids.isEmpty { products = try await Product.products(for: ids) }
    let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let offerings = Offerings(wire: wire, products: byID)

    state.withLock { s in
      guard s.appUserID == id else { return }
      s.offerings = offerings
      s.offeringsAt = Date()
    }
    return offerings
  }

  // MARK: Buying

  public struct PurchaseResult: Sendable {
    /// Nil when the customer cancelled.
    public let transaction: StoreKit.Transaction?
    public let customerInfo: CustomerInfo
    public let userCancelled: Bool
  }

  public func purchase(package: Package, options: Set<Product.PurchaseOption> = []) async throws -> PurchaseResult {
    try await purchase(product: package.storeProduct, options: options)
  }

  /// Buys a product, sends the signed transaction to the server, and
  /// finishes it once the server has accepted it.
  ///
  /// When the app user id is a UUID (your own account ids, say), it goes to
  /// Apple as the `appAccountToken`, so the server can tie a renewal or a
  /// refund to the customer even when it arrives as a store notification
  /// before the app has said anything.
  ///
  /// A cancelled sheet is not an error: `userCancelled` is true. Ask to Buy
  /// and other deferred payments throw `.paymentPending`; the purchase
  /// arrives through `customerInfoStream` if it is approved. If the store
  /// charged but the server could not be reached, this throws
  /// `.receiptNotAccepted` — the customer has paid and the transaction is
  /// kept, so say "we'll finish this when you're back online", not "failed".
  public func purchase(product: Product, options: Set<Product.PurchaseOption> = []) async throws -> PurchaseResult {
    let id = appUserID
    var options = options
    if let token = UUID(uuidString: id) {
      options.insert(.appAccountToken(token))
    }

    switch try await product.purchase(options: options) {
    case .success(let verification):
      let transaction = verification.unsafePayloadValue
      let info = try await postReceipt([verification.jwsRepresentation], appUserID: id)
      await transaction.finish()
      return PurchaseResult(transaction: transaction, customerInfo: info, userCancelled: false)
    case .userCancelled:
      let info = try await customerInfo()
      return PurchaseResult(transaction: nil, customerInfo: info, userCancelled: true)
    case .pending:
      throw PurchasesError.paymentPending
    @unknown default:
      throw PurchasesError.unknownPurchaseResult
    }
  }

  // MARK: Restoring

  /// "Restore purchases" on the paywall. Asks the App Store to sync first —
  /// which may show a sign-in sheet, so call it only from that button — then
  /// sends everything the customer owns. Throws `StoreKitError.userCancelled`
  /// if they dismiss the sign-in.
  @discardableResult
  public func restorePurchases() async throws -> CustomerInfo {
    try await AppStore.sync()
    return try await syncPurchases()
  }

  /// Sends every current entitlement and every unfinished transaction to the
  /// server without any UI. Use it after migrating from another SDK, or to
  /// retry a purchase that threw `.receiptNotAccepted`.
  @discardableResult
  public func syncPurchases() async throws -> CustomerInfo {
    var unfinished: [VerificationResult<StoreKit.Transaction>] = []
    for await result in StoreKit.Transaction.unfinished { unfinished.append(result) }
    var signed = unfinished.map(\.jwsRepresentation)
    for await result in StoreKit.Transaction.currentEntitlements where !signed.contains(result.jwsRepresentation) {
      signed.append(result.jwsRepresentation)
    }

    guard !signed.isEmpty else { return try await customerInfo(fetchPolicy: .fetchCurrent) }

    let info = try await postReceipt(signed, appUserID: appUserID)
    for result in unfinished {
      await result.unsafePayloadValue.finish()
    }
    return info
  }

  // MARK: Who the customer is

  /// Switches to your own id for the person — call it when they sign in.
  /// What happens to purchases made while anonymous is the server's rule
  /// (RevenueCat's: they follow the customer to a new id); `created` says
  /// whether the id was new to the server.
  public func logIn(_ newAppUserID: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
    let new = newAppUserID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty else { throw PurchasesError.invalidAppUserID }
    let current = appUserID
    if new == current {
      let info = try await customerInfo()
      return (info, false)
    }

    let response: LogInResponse = try await api.post(
      ["api", "v1", "customers", "login"],
      body: LogInBody(appUserID: current, newAppUserID: new)
    )
    switchUser(to: new)
    remember(response.customerInfo, for: new)
    return (response.customerInfo, response.created)
  }

  /// Back to a fresh anonymous customer — call it when they sign out. Throws
  /// `.logOutAnonymousUser` when there is no one signed in.
  @discardableResult
  public func logOut() async throws -> CustomerInfo {
    guard !isAnonymous else { throw PurchasesError.logOutAnonymousUser }
    let id = PurchasesIdentity.newAnonymousID()
    switchUser(to: id)
    return try await customerInfo(fetchPolicy: .fetchCurrent)
  }

  private func switchUser(to id: String) {
    identity.save(id)
    state.withLock { s in
      s.appUserID = id
      s.customerInfo = nil
      s.customerInfoAt = nil
      s.offerings = nil
      s.offeringsAt = nil
    }
    defaults.removeObject(forKey: Self.savedKey)
  }

  // MARK: Attributes

  /// Key–value pairs stored on the customer, shown on the dashboard and sent
  /// with every webhook. Nil deletes the key. Keys starting with `$` are
  /// reserved for the ones below.
  public func setAttributes(_ attributes: [String: String?]) async throws {
    let _: EmptyResponse = try await api.post(
      ["api", "v1", "customers", appUserID, "attributes"],
      body: AttributesBody(attributes: attributes)
    )
  }

  public func setEmail(_ email: String?) async throws {
    try await setAttributes(["$email": email])
  }

  public func setDisplayName(_ name: String?) async throws {
    try await setAttributes(["$displayName": name])
  }

  public func setPhoneNumber(_ phone: String?) async throws {
    try await setAttributes(["$phoneNumber": phone])
  }
}
#endif

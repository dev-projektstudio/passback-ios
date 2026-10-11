import Foundation

// The answers the In-App API gives, as Swift values. They mirror
// `lib/purchases/types.ts` field for field; the wire is snake_case and the
// Swift side is not, so every type spells its keys out rather than leaning on
// `convertFromSnakeCase`, which would turn `app_user_id` into `appUserId` and
// would also rewrite the keys of the dictionaries below (entitlement and
// product identifiers are the customer's own strings and must arrive as sent).

// MARK: - Enumerations

/// Where an entitlement or a purchase came from.
public enum Store: String, Codable, Sendable, Equatable {
  case appStore = "app_store"
  case playStore = "play_store"
  /// A web purchase through Passback's Stripe checkout.
  case stripe
  /// Granted from the dashboard or the secret-key API.
  case promotional
  /// A store this build of the package does not know about yet.
  case unknown

  public init(from decoder: Decoder) throws {
    self = Store(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

public enum PeriodType: String, Codable, Sendable, Equatable {
  case normal, trial, intro, prepaid, promotional, unknown

  public init(from decoder: Decoder) throws {
    self = PeriodType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

/// A store subscription's state as the server holds it.
public enum SubscriptionStatus: String, Codable, Sendable, Equatable {
  case active
  case gracePeriod = "grace_period"
  case billingRetry = "billing_retry"
  case expired, revoked, paused, unknown

  public init(from decoder: Decoder) throws {
    self = SubscriptionStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

// MARK: - CustomerInfo

/// Everything the server knows about one customer's purchases, from every
/// store, at `requestDate`. Ask for it with `PassbackPurchases.customerInfo()`
/// and check `entitlements["pro"]?.isActive`.
public struct CustomerInfo: Codable, Sendable, Equatable {
  /// The id asked about, as the app sent it.
  public let appUserID: String
  public let originalAppUserID: String
  /// Every id that resolves to this customer, the primary first.
  public let aliases: [String]
  public let firstSeen: Date
  public let lastSeen: Date
  public let requestDate: Date
  public let entitlements: EntitlementInfos
  /// Keyed by product identifier: the most recent subscription per product.
  public let subscriptions: [String: SubscriptionInfo]
  /// Keyed by product identifier, newest first.
  public let nonSubscriptions: [String: [NonSubscriptionTransaction]]
  public let allPurchasedProductIdentifiers: [String]
  /// The latest expiry across every subscription; nil when there is none.
  public let latestExpirationDate: Date?
  /// Where the customer manages the subscription that matters most now —
  /// hand it to `openURL` or, on iOS, prefer `AppStore.showManageSubscriptions`
  /// when the store is the App Store.
  public let managementURL: URL?
  public let attributes: [String: String]

  /// Product identifiers of the subscriptions that are active now.
  public var activeSubscriptions: Set<String> {
    Set(subscriptions.filter { $0.value.isActive }.keys)
  }

  enum CodingKeys: String, CodingKey {
    case aliases, entitlements, subscriptions, attributes
    case appUserID = "app_user_id"
    case originalAppUserID = "original_app_user_id"
    case firstSeen = "first_seen"
    case lastSeen = "last_seen"
    case requestDate = "request_date"
    case nonSubscriptions = "non_subscriptions"
    case allPurchasedProductIdentifiers = "all_purchased_product_identifiers"
    case latestExpirationDate = "latest_expiration_date"
    case managementURL = "management_url"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    appUserID = try c.decode(String.self, forKey: .appUserID)
    originalAppUserID = try c.decode(String.self, forKey: .originalAppUserID)
    aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    firstSeen = try c.decode(Date.self, forKey: .firstSeen)
    lastSeen = try c.decode(Date.self, forKey: .lastSeen)
    requestDate = try c.decode(Date.self, forKey: .requestDate)
    entitlements = try c.decode(EntitlementInfos.self, forKey: .entitlements)
    subscriptions = try c.decodeIfPresent([String: SubscriptionInfo].self, forKey: .subscriptions) ?? [:]
    nonSubscriptions = try c.decodeIfPresent([String: [NonSubscriptionTransaction]].self, forKey: .nonSubscriptions) ?? [:]
    allPurchasedProductIdentifiers = try c.decodeIfPresent([String].self, forKey: .allPurchasedProductIdentifiers) ?? []
    latestExpirationDate = try c.decodeIfPresent(Date.self, forKey: .latestExpirationDate)
    // A malformed URL is a missing link, not an unreadable customer.
    managementURL = (try? c.decodeIfPresent(String.self, forKey: .managementURL)).flatMap { URL(string: $0) }
    attributes = try c.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(appUserID, forKey: .appUserID)
    try c.encode(originalAppUserID, forKey: .originalAppUserID)
    try c.encode(aliases, forKey: .aliases)
    try c.encode(firstSeen, forKey: .firstSeen)
    try c.encode(lastSeen, forKey: .lastSeen)
    try c.encode(requestDate, forKey: .requestDate)
    try c.encode(entitlements, forKey: .entitlements)
    try c.encode(subscriptions, forKey: .subscriptions)
    try c.encode(nonSubscriptions, forKey: .nonSubscriptions)
    try c.encode(allPurchasedProductIdentifiers, forKey: .allPurchasedProductIdentifiers)
    try c.encodeIfPresent(latestExpirationDate, forKey: .latestExpirationDate)
    try c.encodeIfPresent(managementURL?.absoluteString, forKey: .managementURL)
    try c.encode(attributes, forKey: .attributes)
  }
}

/// The customer's entitlements. `active` is worked out against the device's
/// clock each time it is read, so a cached answer stops granting access when
/// the period it was granted for runs out, without another request.
public struct EntitlementInfos: Codable, Sendable, Equatable {
  /// Every entitlement this customer has ever had, keyed by identifier.
  public let all: [String: EntitlementInfo]
  /// What the server called active at `requestDate`. Kept for encoding; read
  /// `active` instead.
  let activeAtRequest: [String: EntitlementInfo]

  /// The entitlements active now.
  public var active: [String: EntitlementInfo] { all.filter { $0.value.isActive } }

  public subscript(identifier: String) -> EntitlementInfo? { all[identifier] }

  enum CodingKeys: String, CodingKey {
    case all
    case activeAtRequest = "active"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    all = try c.decodeIfPresent([String: EntitlementInfo].self, forKey: .all) ?? [:]
    activeAtRequest = try c.decodeIfPresent([String: EntitlementInfo].self, forKey: .activeAtRequest) ?? [:]
  }
}

public struct EntitlementInfo: Codable, Sendable, Equatable, Identifiable {
  public let identifier: String
  /// The server's answer at the time of the request. `isActive` adds the
  /// clock; prefer it.
  public let isActiveAtRequest: Bool
  /// Whether it will renew. False for lifetime, promotional and cancelled.
  public let willRenew: Bool
  public let periodType: PeriodType
  public let store: Store
  public let productIdentifier: String
  public let latestPurchaseDate: Date
  public let originalPurchaseDate: Date
  /// Nil: never expires.
  public let expirationDate: Date?
  public let unsubscribeDetectedAt: Date?
  public let billingIssueDetectedAt: Date?
  public let gracePeriodExpiresDate: Date?
  public let isSandbox: Bool

  public var id: String { identifier }

  /// Active now: the server said so, and the period it said so for (with any
  /// grace period) has not run out on this device's clock since.
  public var isActive: Bool { isActive(at: Date()) }

  public func isActive(at date: Date) -> Bool {
    guard isActiveAtRequest else { return false }
    guard let expirationDate else { return true }
    let end = max(expirationDate, gracePeriodExpiresDate ?? expirationDate)
    return end > date
  }

  enum CodingKeys: String, CodingKey {
    case identifier, store
    case isActiveAtRequest = "is_active"
    case willRenew = "will_renew"
    case periodType = "period_type"
    case productIdentifier = "product_identifier"
    case latestPurchaseDate = "latest_purchase_date"
    case originalPurchaseDate = "original_purchase_date"
    case expirationDate = "expiration_date"
    case unsubscribeDetectedAt = "unsubscribe_detected_at"
    case billingIssueDetectedAt = "billing_issue_detected_at"
    case gracePeriodExpiresDate = "grace_period_expires_date"
    case isSandbox = "is_sandbox"
  }
}

public struct SubscriptionInfo: Codable, Sendable, Equatable {
  public let productIdentifier: String
  public let store: Store
  public let status: SubscriptionStatus
  public let isActiveAtRequest: Bool
  public let willRenew: Bool
  public let periodType: PeriodType
  public let purchaseDate: Date?
  public let originalPurchaseDate: Date?
  public let expiresDate: Date?
  public let unsubscribeDetectedAt: Date?
  public let billingIssueDetectedAt: Date?
  public let gracePeriodExpiresDate: Date?
  public let refundedAt: Date?
  public let isSandbox: Bool
  /// The store's id: Apple's original transaction id, Google's first token.
  public let storeTransactionID: String
  public let price: Price?

  /// Active now, by the same rule as `EntitlementInfo.isActive`.
  public var isActive: Bool {
    guard isActiveAtRequest else { return false }
    guard let expiresDate else { return true }
    return max(expiresDate, gracePeriodExpiresDate ?? expiresDate) > Date()
  }

  enum CodingKeys: String, CodingKey {
    case store, status, price
    case productIdentifier = "product_identifier"
    case isActiveAtRequest = "is_active"
    case willRenew = "will_renew"
    case periodType = "period_type"
    case purchaseDate = "purchase_date"
    case originalPurchaseDate = "original_purchase_date"
    case expiresDate = "expires_date"
    case unsubscribeDetectedAt = "unsubscribe_detected_at"
    case billingIssueDetectedAt = "billing_issue_detected_at"
    case gracePeriodExpiresDate = "grace_period_expires_date"
    case refundedAt = "refunded_at"
    case isSandbox = "is_sandbox"
    case storeTransactionID = "store_transaction_id"
  }
}

/// A price as the store charged it, in the currency's minor unit.
public struct Price: Codable, Sendable, Equatable {
  public let amountCents: Int
  /// Lower-case ISO 4217, as the server stores it.
  public let currency: String

  /// The amount in major units. Correct for two-decimal currencies, which is
  /// what the server's `amount_cents` assumes.
  public var amount: Decimal { Decimal(amountCents) / 100 }

  enum CodingKeys: String, CodingKey {
    case currency
    case amountCents = "amount_cents"
  }
}

public struct NonSubscriptionTransaction: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let productIdentifier: String
  public let store: Store
  public let purchaseDate: Date
  public let storeTransactionID: String
  public let isSandbox: Bool

  enum CodingKeys: String, CodingKey {
    case id, store
    case productIdentifier = "product_identifier"
    case purchaseDate = "purchase_date"
    case storeTransactionID = "store_transaction_id"
    case isSandbox = "is_sandbox"
  }
}

// MARK: - Arbitrary JSON

/// An offering's metadata: whatever JSON was saved on the dashboard, kept as
/// it came so a paywall can read its own keys.
public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let value = try? c.decode(Bool.self) { self = .bool(value) }
    else if let value = try? c.decode(Double.self) { self = .number(value) }
    else if let value = try? c.decode(String.self) { self = .string(value) }
    else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let value): try c.encode(value)
    case .number(let value): try c.encode(value)
    case .bool(let value): try c.encode(value)
    case .array(let value): try c.encode(value)
    case .object(let value): try c.encode(value)
    case .null: try c.encodeNil()
    }
  }

  public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
  public var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
  public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
  public subscript(key: String) -> JSONValue? { if case .object(let v) = self { return v[key] }; return nil }
}

// MARK: - Errors

public enum PurchasesError: Error, LocalizedError, Sendable, Equatable {
  /// `PassbackPurchases.shared` was asked for before `configure`.
  case notConfigured
  /// The request never got an answer: offline, timed out, pinning refused.
  case network(String)
  /// The server answered with an error. `code` is its machine-readable
  /// `error`, `message` the sentence for a person.
  case server(status: Int, code: String, message: String)
  /// The server answered 2xx with something this build cannot read.
  case unreadableResponse(String)
  /// The purchase is waiting on something outside the app — Ask to Buy, a
  /// bank's confirmation. It arrives through `customerInfoStream` when it
  /// completes.
  case paymentPending
  /// The store charged the customer but the server has not accepted the
  /// receipt yet. The transaction is kept unfinished; `syncPurchases()` or
  /// the next launch sends it again.
  case receiptNotAccepted(String)
  case invalidAppUserID
  /// `logOut()` on a customer who is already anonymous.
  case logOutAnonymousUser
  case unknownPurchaseResult

  public var errorDescription: String? {
    switch self {
    case .notConfigured: return "Call PassbackPurchases.configure(apiKey:) first."
    case .network(let reason): return reason
    case .server(_, _, let message): return message
    case .unreadableResponse(let reason): return "Unreadable answer: \(reason)"
    case .paymentPending: return "The purchase is waiting for approval."
    case .receiptNotAccepted(let reason): return "The purchase went through but could not be recorded yet: \(reason)"
    case .invalidAppUserID: return "An app user id cannot be empty."
    case .logOutAnonymousUser: return "The current customer is already anonymous."
    case .unknownPurchaseResult: return "StoreKit returned a result this version does not know."
    }
  }
}

// MARK: - Dates on the wire

/// ISO 8601 in UTC, with or without fractional seconds — Postgres and
/// `Date.toISOString()` disagree about the fraction, and both reach the SDK.
enum PurchasesJSON {
  private static let withFractions: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let plain = ISO8601DateFormatter()

  static func date(_ raw: String) -> Date? {
    withFractions.date(from: raw) ?? plain.date(from: raw)
  }

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let c = try decoder.singleValueContainer()
      let raw = try c.decode(String.self)
      guard let date = PurchasesJSON.date(raw) else {
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(raw)")
      }
      return date
    }
    return decoder
  }()

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(PurchasesJSON.withFractions.string(from: date))
    }
    return encoder
  }()
}

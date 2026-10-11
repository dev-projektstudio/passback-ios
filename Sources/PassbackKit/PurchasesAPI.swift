import Foundation
#if canImport(Security)
import Security
#endif

/// The In-App REST API, one request at a time. Holds nothing that changes, so
/// it can be handed between tasks freely; the state lives in
/// `PassbackPurchases`.
struct PurchasesAPI: @unchecked Sendable {
  let origin: URL
  let apiKey: String
  let session: URLSession

  /// What the server records as the platform, on the header and in receipts.
  static let platform: String = {
    #if os(macOS)
    return "macos"
    #elseif os(iOS)
    return "ios"
    #else
    return "other"
    #endif
  }()

  func get<Response: Decodable>(_ path: [String], query: [String: String] = [:]) async throws -> Response {
    try await send("GET", path, query: query, body: nil)
  }

  func post<Response: Decodable>(_ path: [String], body: any Encodable) async throws -> Response {
    try await send("POST", path, query: [:], body: body)
  }

  private func send<Response: Decodable>(
    _ method: String,
    _ path: [String],
    query: [String: String],
    body: (any Encodable)?
  ) async throws -> Response {
    var request = URLRequest(url: url(path, query: query))
    request.httpMethod = method
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.platform, forHTTPHeaderField: "X-Passback-Platform")
    request.setValue(Passback.appVersion, forHTTPHeaderField: "X-Passback-App-Version")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try PurchasesJSON.encoder.encode(body)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PurchasesError.network(error.localizedDescription)
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
        throw PurchasesError.server(status: status, code: failure.error, message: failure.message ?? failure.error)
      }
      throw PurchasesError.server(status: status, code: "http_\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status))
    }

    do {
      return try PurchasesJSON.decoder.decode(Response.self, from: data)
    } catch {
      throw PurchasesError.unreadableResponse(String(describing: error))
    }
  }

  /// The origin plus each segment, percent-encoded on its own. An app user id
  /// is the customer's own string — an email, `$PassbackAnonymousID:…`, a
  /// path with a slash in it — and must reach the server as one segment.
  /// Query values get the same strict encoding: URLComponents leaves `+`
  /// alone, and the server's URLSearchParams reads a bare `+` as a space.
  func url(_ path: [String], query: [String: String]) -> URL {
    var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
    var base = components.percentEncodedPath
    while base.hasSuffix("/") { base.removeLast() }
    components.percentEncodedPath = base + "/" + path.map(Self.encode).joined(separator: "/")
    if !query.isEmpty {
      components.percentEncodedQuery = query
        .sorted { $0.key < $1.key }
        .map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }
        .joined(separator: "&")
    }
    return components.url!
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  private struct Failure: Decodable {
    let error: String
    let message: String?
  }
}

/// A 2xx with nothing in it worth reading — `{}` from the attributes route.
struct EmptyResponse: Decodable {}

// MARK: - Request bodies

struct ReceiptBody: Encodable {
  let appUserID: String
  let signedTransactions: [String]
  let store = "app_store"
  let platform = PurchasesAPI.platform
  let appVersion = Passback.appVersion

  enum CodingKeys: String, CodingKey {
    case store, platform
    case appUserID = "app_user_id"
    case signedTransactions = "signed_transactions"
    case appVersion = "app_version"
  }
}

struct LogInBody: Encodable {
  let appUserID: String
  let newAppUserID: String

  enum CodingKeys: String, CodingKey {
    case appUserID = "app_user_id"
    case newAppUserID = "new_app_user_id"
  }
}

struct LogInResponse: Decodable {
  let customerInfo: CustomerInfo
  let created: Bool

  enum CodingKeys: String, CodingKey {
    case created
    case customerInfo = "customer_info"
  }
}

/// `null` is meaningful here — it deletes the attribute — so the values are
/// optional and encode as JSON null rather than being dropped.
struct AttributesBody: Encodable {
  let attributes: [String: String?]
}

// MARK: - Identity

/// Where the current app user id is kept between launches.
///
/// UserDefaults holds the current id, logged in or not, and goes with the
/// app when it is deleted — a reinstall must not wake up signed in as
/// whoever used it before. The anonymous id is also kept in the Keychain,
/// like `Passback.installID`, so a reinstall that never logs in comes back
/// as the same anonymous customer and finds its purchases without a restore.
struct PurchasesIdentity {
  static let anonymousPrefix = "$PassbackAnonymousID:"
  private static let defaultsKey = "passback.purchases.appUserID"
  private static let keychainService = "app.passback.purchases"
  private static let keychainAccount = "anonymous_app_user_id"

  let defaults: UserDefaults

  static func isAnonymous(_ id: String) -> Bool { id.hasPrefix(anonymousPrefix) }

  static func newAnonymousID() -> String { anonymousPrefix + UUID().uuidString.lowercased() }

  func load() -> String? {
    if let stored = defaults.string(forKey: Self.defaultsKey), !stored.isEmpty { return stored }
    return Self.keychainRead()
  }

  func save(_ id: String) {
    defaults.set(id, forKey: Self.defaultsKey)
    if Self.isAnonymous(id) { Self.keychainWrite(id) }
  }

  private static func keychainWrite(_ value: String) {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    SecItemDelete(query as CFDictionary)
    var insert = query
    insert[kSecValueData as String] = Data(value.utf8)
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(insert as CFDictionary, nil)
    #endif
  }

  private static func keychainRead() -> String? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
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
}

// MARK: - A value behind a lock

/// Mutable state shared between the caller's tasks and the transaction
/// listener. A lock rather than an actor so the synchronous properties
/// (`appUserID`, `isAnonymous`) stay synchronous, as they are in every other
/// purchases SDK an app might be migrating from.
final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}

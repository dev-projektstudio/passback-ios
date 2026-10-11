#if canImport(StoreKit)
import Foundation
import StoreKit

/// The offerings set up on the dashboard, with each package's StoreKit
/// `Product` already loaded. A package whose product the App Store does not
/// return (not yet approved, not in this storefront, a typo on the
/// dashboard) is left out rather than shown with no price.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public struct Offerings: Sendable {
  /// The offering marked current on the dashboard — the one a paywall shows
  /// unless it has a reason to pick another.
  public let current: Offering?
  public let all: [String: Offering]

  public subscript(identifier: String) -> Offering? { all[identifier] }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public struct Offering: Sendable, Identifiable {
  public let identifier: String
  public let serverDescription: String?
  /// The JSON saved with the offering — copy, colours, a flag for an A/B
  /// arm. Read it with `metadata["headline"]?.stringValue`.
  public let metadata: [String: JSONValue]
  /// In the order set on the dashboard.
  public let availablePackages: [Package]

  public var id: String { identifier }

  public subscript(package identifier: String) -> Package? {
    availablePackages.first { $0.identifier == identifier }
  }

  public var weekly: Package? { first(.weekly) }
  public var monthly: Package? { first(.monthly) }
  public var twoMonth: Package? { first(.twoMonth) }
  public var threeMonth: Package? { first(.threeMonth) }
  public var sixMonth: Package? { first(.sixMonth) }
  public var annual: Package? { first(.annual) }
  public var lifetime: Package? { first(.lifetime) }

  private func first(_ type: PackageType) -> Package? {
    availablePackages.first { $0.packageType == type }
  }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public struct Package: Sendable, Identifiable, Hashable {
  public let identifier: String
  public let offeringIdentifier: String
  public let packageType: PackageType
  /// The App Store product, ready for `PassbackPurchases.purchase(package:)`
  /// or for drawing the price with `storeProduct.displayPrice`.
  public let storeProduct: Product

  public var id: String { "\(offeringIdentifier)/\(identifier)" }

  public static func == (a: Package, b: Package) -> Bool {
    a.identifier == b.identifier && a.offeringIdentifier == b.offeringIdentifier && a.storeProduct.id == b.storeProduct.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(identifier)
    hasher.combine(offeringIdentifier)
    hasher.combine(storeProduct.id)
  }
}

/// What a package is, read from its identifier. The conventional names
/// (`monthly`, `annual`, …) and RevenueCat's `$rc_monthly` style both count,
/// so offerings carried over from RevenueCat keep their shortcuts.
public enum PackageType: String, Sendable, Hashable {
  case weekly, monthly, twoMonth, threeMonth, sixMonth, annual, lifetime, custom

  init(identifier: String) {
    var name = identifier.lowercased()
    for prefix in ["$rc_", "$pb_", "$"] where name.hasPrefix(prefix) {
      name.removeFirst(prefix.count)
      break
    }
    switch name {
    case "weekly", "week": self = .weekly
    case "monthly", "month": self = .monthly
    case "two_month", "two_months", "bimonthly": self = .twoMonth
    case "three_month", "three_months", "quarterly": self = .threeMonth
    case "six_month", "six_months", "semiannual": self = .sixMonth
    case "annual", "yearly", "year": self = .annual
    case "lifetime": self = .lifetime
    default: self = .custom
    }
  }
}

// MARK: - The wire

struct WireOfferings: Decodable {
  let currentOfferingID: String?
  let offerings: [WireOffering]

  enum CodingKeys: String, CodingKey {
    case offerings
    case currentOfferingID = "current_offering_id"
  }
}

struct WireOffering: Decodable {
  let identifier: String
  let description: String?
  let metadata: [String: JSONValue]?
  let packages: [WirePackage]
}

struct WirePackage: Decodable {
  let identifier: String
  let products: Products

  struct Products: Decodable {
    let appStore: String?
    let playStore: String?
    let stripe: String?

    enum CodingKeys: String, CodingKey {
      case stripe
      case appStore = "app_store"
      case playStore = "play_store"
    }
  }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension Offerings {
  /// The wire offerings, joined to the products StoreKit returned for them.
  init(wire: WireOfferings, products: [String: Product]) {
    var all: [String: Offering] = [:]
    for offering in wire.offerings {
      let packages = offering.packages.compactMap { package -> Package? in
        guard let id = package.products.appStore, let product = products[id] else { return nil }
        return Package(
          identifier: package.identifier,
          offeringIdentifier: offering.identifier,
          packageType: PackageType(identifier: package.identifier),
          storeProduct: product
        )
      }
      all[offering.identifier] = Offering(
        identifier: offering.identifier,
        serverDescription: offering.description,
        metadata: offering.metadata ?? [:],
        availablePackages: packages
      )
    }
    self.all = all
    self.current = wire.currentOfferingID.flatMap { all[$0] }
  }
}
#endif

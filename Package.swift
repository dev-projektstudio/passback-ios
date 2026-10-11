// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "PassbackKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "PassbackKit", targets: ["PassbackKit"])],
  targets: [.target(name: "PassbackKit", path: "Sources/PassbackKit")]
)

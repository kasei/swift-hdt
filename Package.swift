// swift-tools-version:4.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HDT",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library( name: "HDT", targets: ["HDT"]),
    ],
    dependencies: [
		.package(url: "https://github.com/kasei/swift-sparql-syntax.git", .upToNextMinor(from: "0.0.83")),
		.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "0.8.0"),
        .package(url: "https://github.com/kasei/kineo.git", .upToNextMinor(from: "0.0.37")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "HDT",
            dependencies: ["SPARQLSyntax", "CryptoSwift"]),
        .target(
            name: "hdt-parse",
            dependencies: ["HDT", "Kineo"]),
        .testTarget(
            name: "swift-hdtTests",
            dependencies: ["HDT"]),
    ]
)

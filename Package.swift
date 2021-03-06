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
		.package(url: "https://github.com/kasei/swift-sparql-syntax.git", .upToNextMinor(from: "0.0.92")),
		.package(url: "https://github.com/kasei/kineo.git", .upToNextMinor(from: "0.0.64")),
		.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.0.0")
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
        .target(
            name: "hdt-write",
            dependencies: ["HDT", "Kineo"]),
        .target(
            name: "hdt-info",
            dependencies: ["HDT"]),
        .testTarget(
            name: "swift-hdtTests",
            dependencies: ["HDT", "Kineo"]),
    ]
)

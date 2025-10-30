// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fdb-rdf-layer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RDFLayer",
            targets: ["RDFLayer"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/foundationdb/fdb-swift-bindings.git",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "RDFLayer",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "RDFLayerTests",
            dependencies: ["RDFLayer"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

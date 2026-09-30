// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Mirror",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0")
    ],
    products: [
        .library(name: "MirrorDomain", targets: ["MirrorDomain"])
    ],
    targets: [
        .target(
            name: "MirrorDomain",
            path: "Sources/MirrorDomain",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "MirrorDomainTests",
            dependencies: ["MirrorDomain"],
            path: "Tests/MirrorDomainTests",
            swiftSettings: [.defaultIsolation(nil)]
        )
    ],
    swiftLanguageModes: [.v6]
)

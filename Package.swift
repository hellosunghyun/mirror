// swift-tools-version: 6.4
import PackageDescription

// 앱과 확장도 아래 라이브러리의 같은 소스를 사용한다. 새 외부 의존성은 없다.
let package = Package(
    name: "Mirror",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "MirrorDomain", targets: ["MirrorDomain"]),
        .library(name: "MirrorData", targets: ["MirrorData"]),
        .library(name: "MirrorSystem", targets: ["MirrorSystem"]),
        .library(name: "MirrorDesign", targets: ["MirrorDesign"])
    ],
    targets: [
        .target(name: "MirrorDomain", path: "Sources/MirrorDomain", swiftSettings: [.defaultIsolation(nil)]),
        .target(name: "MirrorData", dependencies: ["MirrorDomain"], path: "Sources/MirrorData",
                swiftSettings: [.defaultIsolation(nil)], linkerSettings: [.linkedFramework("CoreData")]),
        .target(name: "MirrorSystem", dependencies: ["MirrorDomain", "MirrorData"], path: "Sources/MirrorSystem",
                swiftSettings: [.defaultIsolation(nil)]),
        .target(name: "MirrorDesign", path: "Sources/MirrorDesign",
                resources: [.copy("SwiftPieces/LICENSE.swiftpieces"), .copy("SwiftPieces/PROVENANCE.md")],
                swiftSettings: [.defaultIsolation(nil)]),
        .testTarget(name: "MirrorDomainTests", dependencies: ["MirrorDomain"], path: "Tests/MirrorDomainTests",
                    swiftSettings: [.defaultIsolation(nil)]),
        .testTarget(name: "MirrorDataTests", dependencies: ["MirrorDomain", "MirrorData"], path: "Tests/MirrorDataTests",
                    swiftSettings: [.defaultIsolation(nil)]),
        .testTarget(name: "MirrorSystemTests", dependencies: ["MirrorDomain", "MirrorData", "MirrorSystem"], path: "Tests/MirrorSystemTests",
                    swiftSettings: [.defaultIsolation(nil)])
    ],
    swiftLanguageModes: [.v6]
)

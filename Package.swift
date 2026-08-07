// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCQuota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCQuotaCore", targets: ["CCQuotaCore"]),
        .executable(name: "ccquota", targets: ["ccquota"]),
    ],
    targets: [
        .target(name: "CCQuotaCore"),
        .executableTarget(name: "ccquota", dependencies: ["CCQuotaCore"]),
    ]
)

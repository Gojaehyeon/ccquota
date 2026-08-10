// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCQuota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCQuotaCore", targets: ["CCQuotaCore"]),
        .executable(name: "ccquota", targets: ["ccquota"]),
        .executable(name: "widget-preview", targets: ["WidgetPreview"]),
    ],
    targets: [
        .target(name: "CCQuotaCore"),
        .executableTarget(name: "ccquota", dependencies: ["CCQuotaCore"]),
        .executableTarget(name: "WidgetPreview", dependencies: ["CCQuotaCore"], path: "Tools/WidgetPreview"),
        .executableTarget(name: "NameCheck", dependencies: ["CCQuotaCore"], path: "Tools/NameCheck"),
    ]
)

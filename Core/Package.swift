// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", from: "0.11.1")
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("FoundationModels")
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)

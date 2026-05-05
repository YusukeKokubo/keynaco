// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    // ディレクトリ名は `Core/` のまま。モジュール名を `KeynacoCore` にし、Xcode 上の `Core` フォルダ参照と `import Core` が衝突しないようにする。
    name: "KeynacoCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KeynacoCore", targets: ["KeynacoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", from: "0.11.1")
    ],
    targets: [
        .target(
            name: "KeynacoCore",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
            ],
            path: "Sources/Core",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("FoundationModels")
            ]
        ),
        .testTarget(
            name: "KeynacoCoreTests",
            dependencies: ["KeynacoCore"],
            path: "Sources/CoreTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)

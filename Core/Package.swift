// swift-tools-version: 6.1
import PackageDescription

#if os(macOS)
private let azooKeyTraits: Set<Package.Dependency.Trait> = ["Zenzai"]
#else
private let azooKeyTraits: Set<Package.Dependency.Trait> = []
#endif

let package = Package(
    // ディレクトリ名は `Core/` のまま。モジュール名を `KeynacoCore` にし、Xcode 上の `Core` フォルダ参照と `import Core` が衝突しないようにする。
    name: "KeynacoCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KeynacoCore", targets: ["KeynacoCore"])
    ],
    dependencies: [
        // AzooKey の Zenzai trait が EfficientNGram → SwiftyMarisa を条件依存するため、解決を安定させる
        .package(url: "https://github.com/ensan-hcl/SwiftyMarisa", from: "0.0.1"),
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            from: "0.11.1",
            traits: azooKeyTraits
        )
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
                .linkedLibrary("sqlite3")
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

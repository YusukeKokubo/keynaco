# azooKey-Desktop 構成への移行計画

## 目標

プロジェクト構成を [azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop/) に忠実に揃える。

- `Core/` Swift Package でコアロジックをパッケージ化
- `keynaco/` ディレクトリをアプリターゲットのソースとする
- XcodeGen (`project.yml`) を廃止し、標準 `.xcodeproj` をコミットして管理

**最終成果物に `project.yml` は残さない。** Step 5 は一時的な中間状態であり、Step 6 の削除まで完了して初めてゴールとする。

---

## 現状 → ターゲット 対照表

| 項目 | 現状 | ターゲット |
|------|------|-----------|
| プロジェクト管理 | XcodeGen (`project.yml`) | 標準 `.xcodeproj` をコミット（`project.yml` は削除） |
| コアロジック | `Sources/*.swift` | `Core/Sources/Core/*.swift` |
| アプリターゲット | `Sources/` | `keynaco/` |
| テスト（Core） | `Tests/` + `@testable import keynaco` | `Core/Sources/CoreTests/` + `@testable import Core` |
| テスト（App） | `Tests/` から2ファイル | `keynacoTests/` + `@testable import keynaco` |
| 外部依存 | `project.yml` の `packages:` | `Core/Package.swift` の `dependencies:` |
| ローカルパッケージ | `LocalPackages/keynacoCore/`（ビルドキャッシュのみ） | `Core/`（proper Swift Package） |

---

## ファイル分類

### Core/Sources/Core/（IMK 非依存・ユニットテスト可能）

| ファイル | 理由 |
|---------|------|
| `InputHandler.swift` + extensions (6ファイル) | AppKit のみ、IMK なし |
| `CompositionState.swift` | AppKit のみ |
| `RomajiConverter.swift` | 純 Swift |
| `DatabaseManager.swift` | SQLite3 のみ（linkerSettings で対応） |
| `AzooKeyConverter.swift` / `AzooKeyConverting.swift` | KanaKanjiConverter のみ |
| `KanaUtils.swift` | 純 Swift |
| `LearningThresholds.swift` | 純 Swift |
| `TextInputClient.swift` | AppKit のみ |
| `LLMCandidateScorer.swift` | Foundation + FoundationModels のみ |
| `LLMMisconversionChecker.swift` | Foundation + FoundationModels のみ |
| `LLMSegmentConverter.swift` | Foundation + FoundationModels のみ |
| `LLMSuccessorFetcher.swift` | Foundation + FoundationModels のみ |
| `InputHandlerSnapshot.swift` / `InputHandler+Snapshot.swift` | Core 型のみ参照（`#if DEBUG` ガード済み） |

合計: 20 ファイル

### keynaco/（IMK / AppKit 依存・アプリターゲット）

| ファイル | 理由 |
|---------|------|
| `main.swift` | アプリエントリポイント |
| `NSManualApplication.swift` | Cocoa |
| `AppDelegate.swift` | Cocoa + IMK + Carbon |
| `InputController.swift` | Cocoa + IMK |
| `CandidateWindow.swift` | Cocoa |
| `SurroundingIMKContext.swift` | AppKit + IMK |
| `Settings/*.swift` (4ファイル) | AppKit |
| `Debug/*.swift` (3ファイル) | AppKit（#if DEBUG） |
| `Info.plist` / `keynaco.entitlements` | リソース |
| `Assets.xcassets/` | リソース（アイコン） |
| `en.lproj/InfoPlist.strings` | ローカライズリソース |
| `InputSource.tiff` / `InputSource@2x.tiff` | 入力ソースアイコン |
| `PresetBigram/preset_bigram.csv` | バンドルリソース |
| `Resources/zenz-v3.1-small-gguf/` | LLM モデル（git submodule）※下記参照 |

### Core/Sources/CoreTests/（IMK 不要なユニットテスト）

`Tests/` の全ファイルから以下 2 ファイルを除いたもの:

- `AzooKeyCacheTests.swift`
- `AzooKeyConverterTests.swift`
- `CompositionStateTests.swift`
- `DatabaseManagerTests.swift`
- `InputHandler*Tests.swift` (10ファイル)
- `InputHandlerTestCase.swift`（テスト基底クラス・モック）
- `LLMCandidateScorerTests.swift`
- `LLMFallbackForcingMockAzooKey.swift`（モック）
- `LLMMisconversionCheckerTests.swift`
- `LLMSuccessorFetcherTests.swift`
- `RomajiConverterTests.swift`
- `ScenarioRegressionTests.swift`
- `SegmentBoundaryTests.swift`
- `ShiftInputTests.swift`
- `SkipBigramTests.swift`

`@testable import keynaco` → `@testable import Core` に一括置換する。

### keynacoTests/（IMK 依存テスト・アプリテストターゲット）

- `CandidateWindowMoveRowTests.swift`（`CandidateWindow` は App ターゲット）
- `SurroundingIMKContextTests.swift`（`InputMethodKit` を直接 import）

`@testable import keynaco` はそのまま維持する。

---

## Core/Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    // アプリ側の MACOSX_DEPLOYMENT_TARGET (26.0) と揃える。
    // Package.swift の SupportedPlatform は v15 が現時点での最高安定値だが、
    // Xcode プロジェクト側の deployment target が実効値を決定する。
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", from: "0.11.1"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                // sqlite3 はシステムライブラリ。CoreTests をスタンドアロンで
                // `swift test` する際も必要なためここで指定する。
                .linkedLibrary("sqlite3"),
                // FoundationModels はシステムフレームワーク（macOS 26+）。
                // アプリ側の FoundationModels.framework リンクと合わせて
                // CoreTests 単体テスト時もリンクできるようにする。
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
```

**`platforms: [.macOS(.v15)]` について**: `SupportedPlatform` の列挙値に macOS 26 は存在しないため `.v15`（Sequoia）を指定する。実効的なデプロイターゲットはアプリ Xcode プロジェクトの `MACOSX_DEPLOYMENT_TARGET = 26.0` が支配する。`FoundationModels` API には既存コードの `@available(macOS 26.0, *)` ガードで対応。

---

## 中間 project.yml（Step 4〜5 のみ使用・最終的には削除）

> **注意**: 下記は XcodeGen 実行用の一時ファイル。Step 6 で削除する。

```yaml
name: keynaco

options:
  bundleIdPrefix: com.yusuke
  deploymentTarget:
    macOS: "26.0"
  xcodeVersion: "16"
  generateEmptyDirectories: true

packages:
  Core:
    path: Core

targets:
  keynaco:
    type: application
    platform: macOS
    sources:
      - path: keynaco
    resources:
      - path: keynaco/Assets.xcassets
      - path: keynaco/PresetBigram/preset_bigram.csv
      - path: keynaco/en.lproj
      - path: keynaco/InputSource.tiff
      - path: keynaco/InputSource@2x.tiff
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yusuke.inputmethod.keynaco
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "26.0"
        ENABLE_APP_SANDBOX: YES
        CODE_SIGN_ENTITLEMENTS: keynaco/keynaco.entitlements
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: R2ZZ3ALJ36  # ローカル設定。公開時は xcconfig に移す
        INFOPLIST_FILE: keynaco/Info.plist
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        MARKETING_VERSION: 0.0.0
        CURRENT_PROJECT_VERSION: 0
    dependencies:
      - sdk: InputMethodKit.framework
      - sdk: FoundationModels.framework
      - sdk: libsqlite3.tbd
      - package: Core
        product: Core

  keynacoTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: keynacoTests
    settings:
      base:
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "26.0"
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: keynaco

schemes:
  keynaco:
    build:
      targets:
        keynaco: all
      postActions:
        - script: |
            DESTINATION="/Library/Input Methods"
            APP_NAME="${FULL_PRODUCT_NAME}"
            SOURCE_APP="${BUILT_PRODUCTS_DIR}/${APP_NAME}"
            DEST_APP="${DESTINATION}/${APP_NAME}"
            PROCESS_NAME="${EXECUTABLE_NAME}"
            PLIST="${SOURCE_APP}/Contents/Info.plist"

            TAG=$(git -C "$SRCROOT" describe --tags --match "v*" --abbrev=0 2>/dev/null || echo "v0.0.0")
            VERSION=${TAG#v}
            BUILD=$(git -C "$SRCROOT" rev-list HEAD --count 2>/dev/null || echo "0")
            /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
            /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
            SIGN_ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
            codesign --force --deep --sign "${SIGN_ID:-${EXPANDED_CODE_SIGN_IDENTITY:--}}" "$SOURCE_APP"

            pkill -f "$PROCESS_NAME" || true
            if [ ! -d "$DESTINATION" ]; then mkdir -p "$DESTINATION"; fi
            rm -rf "$DEST_APP"
            cp -R "$SOURCE_APP" "$DEST_APP"
          name: Install to Input Methods
          settingsTarget: keynaco
    run:
      executable: keynaco
    test:
      targets:
        - keynacoTests
```

---

## CoreTests の実行方法

| 方法 | コマンド / 手順 | 備考 |
|------|---------------|------|
| スタンドアロン | `cd Core && swift test` | CI に追加する。FoundationModels が macOS 26 環境でのみ動作 |
| Xcode scheme | Xcode > scheme editor > keynaco scheme > Test タブ > `+` で `CoreTests` を追加 | `.xcodeproj` コミット前に設定し、コミットに含める |

**CI 対応**: 現在 `xcodebuild test -scheme keynaco` のみなら、`CoreTests` が走らない期間ができる。移行後は以下の2本立てとする：
1. `xcodebuild test -scheme keynaco`（keynacoTests）
2. `cd Core && swift test`（CoreTests）

または Xcode scheme に `CoreTests` を含めて1コマンドで実行する。

---

## 作業ステップ

### Step 0: 事前検証

- [ ] `MockTextClient` 等のモック・ヘルパー型が Core のみの型を参照していることを grep で確認  
  `grep -n "CandidateWindow\|InputController\|SurroundingIMKContext" Tests/`
- [ ] `InputHandler+Snapshot.swift` の `#if DEBUG` ガードが App 側の型を参照していないことを確認
- [ ] `Sources/Resources/zenz-v3.1-small-gguf/` が submodule として登録済みかを確認  
  `cat .gitmodules`（未登録なら Step 2 の git mv 不要）
- [ ] 既存 `keynaco.xcodeproj` が git 管理下にあるかを確認  
  `git ls-files keynaco.xcodeproj/project.pbxproj`

### Step 1: Core Swift Package の作成

- [ ] `Core/Package.swift` を新規作成（上記内容）
- [ ] `Core/Sources/Core/` ディレクトリ作成
- [ ] `Core/Sources/CoreTests/` ディレクトリ作成

### Step 2: ファイル移動（git mv）

- [ ] Core 対象 20 ファイルを `Sources/*.swift` → `Core/Sources/Core/` へ `git mv`
- [ ] App 対象ファイルを `Sources/` → `keynaco/` へ `git mv`（Settings/, Debug/ サブディレクトリ含む）
- [ ] リソースファイル（Assets.xcassets, en.lproj, tiff, plist, entitlements）を `Sources/` → `keynaco/` へ `git mv`
- [ ] `Sources/PresetBigram/` → `keynaco/PresetBigram/` へ `git mv`
- [ ] zenz submodule が存在する場合: `.gitmodules` を `keynaco/Resources/zenz-v3.1-small-gguf/` に更新し `git mv`
- [ ] CoreTests 対象ファイルを `Tests/` → `Core/Sources/CoreTests/` へ `git mv`
- [ ] App テスト 2 ファイルを `Tests/` → `keynacoTests/` へ `git mv`

### Step 3: テストの import 更新

- [ ] `Core/Sources/CoreTests/` の全ファイルで `@testable import keynaco` → `@testable import Core` に置換  
  `sed -i '' 's/@testable import keynaco/@testable import Core/g' Core/Sources/CoreTests/*.swift`

### Step 4: project.yml 更新

- [ ] 上記「中間 project.yml」の内容に置き換える
- [ ] `scripts/generate_preset_bigram_csv.py` の出力先パスが `keynaco/PresetBigram/preset_bigram.csv` を指すようにコメントまたはスクリプト内を更新

### Step 5: .xcodeproj 再生成・ビルド確認

- [ ] 既存 `keynaco.xcodeproj` を削除または上書き: `rm -rf keynaco.xcodeproj`
- [ ] `xcodegen generate` 実行
- [ ] Xcode scheme editor で `CoreTests` を test targets に追加
- [ ] `xcodebuild build -scheme keynaco -configuration Debug` でビルド確認
- [ ] `cd Core && swift test` で CoreTests 確認
- [ ] `xcodebuild test -scheme keynaco` で keynacoTests 確認
- [ ] アセット・ローカライズ・tiff が Copy Bundle Resources に含まれることを Xcode で確認

### Step 6: XcodeGen 卒業

- [ ] `project.yml` を削除: `git rm project.yml`
- [ ] `LocalPackages/keynacoCore/` を削除: `git rm -r LocalPackages/`
- [ ] `keynaco.xcodeproj` を git add してコミット
- [ ] `CLAUDE.md` のビルド手順（`xcodegen generate` の記述）を更新

---

## リスク・注意事項

- **git submodule の移動**: `Sources/Resources/zenz-v3.1-small-gguf/` が submodule の場合、`.gitmodules` の `path` 更新と `git mv` が必要。未登録（ローカルのみ）なら通常の `mv` で足りる。
- **FoundationModels in SPM**: `linkerSettings: [.linkedFramework("FoundationModels")]` で対応。macOS 26 環境外（CI が古い OS）では `swift test` が失敗する点に注意。
- **`@testable import`**: `@testable import Core` で internal 型にアクセス可能。ただし `@testable` は同一モジュール内の internal に限る。モック・ヘルパーが参照する型が Core に含まれていることを Step 0 で事前確認する。
- **`InputHandlerSnapshot` の `#if DEBUG`**: `Core` モジュール内で `#if DEBUG` ガードされている型を App 側が参照する場合、App の Debug ビルドでも `#if DEBUG` が効くことを確認する。
- **XcodeGen 廃止後の `.xcodeproj` 管理**: 構成変更（新ファイル追加等）はすべて Xcode の GUI か `.xcodeproj` 直接編集になる。post-build スクリプトは scheme の Build Post-action として `.xcodeproj` 内に保存される。
- **`DEVELOPMENT_TEAM` のコミット**: 現状と同じく `R2ZZ3ALJ36` をコミットする。将来的に公開リポジトリにする際は xcconfig へ切り出す。

---

## 実装時の補足（Step 3: `public` 化の進め方）

- **`public` 付与の工数**は、コンパイルエラーを潰しながら進める形になる。`enum` の各 `case`、`extension` のデフォルト `internal` メソッドなど、想定以上に表面積が広がりうる。
- **迷子防止の優先順位**（`@testable import Core` はテスト専用で、App から internal は見えない）:
  1. **Primary**: `keynaco` **アプリターゲットのビルド**（`xcodebuild build -scheme keynaco` 等）が通ること
  2. **Secondary**: `CoreTests`（`cd Core && swift test` や scheme 経由）で二次確認
- 手順の残り（project.yml 中間状態 → xcodegen → Step 6）は [本ドキュメントの作業ステップ](#作業ステップ) どおりでよい。

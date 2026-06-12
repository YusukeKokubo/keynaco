# PLAN260505b: Zenzai（ニューラル仮名漢字変換）有効化

## 目的

AzooKeyKanaKanjiConverter の Zenzai モード（LLM ベースの文脈考慮変換エンジン）を keynaco で有効化する。

## 参考: azooKey-Desktop の実装

- モデルファイル: Git サブモジュール経由で `ggml-model-Q5_K_M.gguf`（GGUF 量子化モデル）をバンドルリソースに含める
- Trait: `Package.swift` で `traits: ["Zenzai"]` を指定することで llama.cpp バインディングが有効化される
- API: `ConvertRequestOptions.ZenzaiMode.on(weight:inferenceLimit:requestRichCandidates:personalizationMode:versionDependentMode:)`
- バージョン依存モード: `.v3(ZenzaiV3DependentMode(profile:leftSideContext:))` を使用
- 文脈テキスト: `leftSideContext` にカーソル左側の文字列を渡す（文脈考慮変換の精度向上）

---

## 変更ステップ

### Step 1: モデルファイルの取得

Hugging Face からモデルファイルを取得して `keynaco/Resources/` に配置する。

```bash
# zenz-v3.1-small の量子化モデルを取得
# https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf
# ファイル: ggml-model-Q5_K_M.gguf
```

**保存先**: `keynaco/Resources/ggml-model-Q5_K_M.gguf`

Xcode プロジェクトでバンドルリソースとして追加する（`keynaco` ターゲットの "Copy Bundle Resources" に追加）。

> azooKey-Desktop では Git サブモジュールで管理しているが、keynaco では直接配置で可（ファイルサイズは気にしない）。

---

### Step 2: Core/Package.swift に Zenzai trait を追加

**ファイル**: `Core/Package.swift`

```swift
// 変更前
dependencies: [
    .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", from: "0.11.1")
],

// 変更後
#if os(macOS)
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["Zenzai"]
#else
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

// package 定義内:
dependencies: [
    .package(
        url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
        from: "0.11.1",
        traits: kanaKanjiConverterTraits
    )
],
```

`Package.swift` は `swift-tools-version: 6.0` なので trait 構文が使える。

---

### Step 3: AzooKeyConverter に Zenzai 設定を追加

**ファイル**: `Core/Sources/Core/AzooKeyConverter.swift`

現在 `options` は `init` 時に固定で生成しているが、Zenzai では `leftSideContext`（カーソル左側の文字列）をリクエストごとに変える必要がある。`options` を毎回生成するか、`leftSideContext` だけ差し替えるメソッドを追加する。

#### 変更内容

1. **イニシャライザに Zenzai 設定を受け取る引数を追加**（後方互換性のためデフォルト値付き）:

```swift
public init(zenzaiEnabled: Bool = false, zenzaiProfile: String = "", zenzaiInferenceLimit: Int = 5)
```

2. **`options` を var に変更し、リクエストごとに `leftSideContext` を差し替えるヘルパーを追加**:

```swift
private func makeOptions(leftSideContext: String?) -> ConvertRequestOptions {
    var opts = options
    if zenzaiEnabled {
        opts.zenzaiMode = .on(
            weight: modelURL,
            inferenceLimit: zenzaiInferenceLimit,
            requestRichCandidates: false,
            personalizationMode: nil,
            versionDependentMode: .v3(.init(
                profile: zenzaiProfile.isEmpty ? nil : zenzaiProfile,
                leftSideContext: leftSideContext
            ))
        )
    }
    return opts
}
```

3. **`requestCandidates` / `candidatesForSegment` / `segmentize` に `leftSideContext` 引数を追加**（デフォルト `nil`）

#### `modelURL` の解決

モデルファイルは `KeynacoCore` ではなくアプリバンドル側にあるため、`Bundle.main` から取得する:

```swift
private var modelURL: URL {
    Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf")
        ?? URL(fileURLWithPath: "")
}
```

---

### Step 4: InputHandler から leftSideContext を渡す

**ファイル**: `Core/Sources/Core/InputHandler+Candidates.swift`（または呼び出し元）

`SurroundingIMKContext` で取得した左側文字列を `requestCandidates` に渡す。

`InputController` → `InputHandler` → `AzooKeyConverter.requestCandidates(hiragana:leftSideContext:)` のパスでコンテキストを伝播させる。

`InputHandler` の `buildCandidateList` / `requestCandidates` のシグネチャ変更範囲を最小化するため、`InputHandler` に `var surroundingContext: String? = nil` プロパティを追加し、`InputController` が候補生成前に設定する方式が簡潔。

---

### Step 5: 設定画面に Zenzai 設定を追加

**ファイル**: `keynaco/Settings/` 配下に新タブまたは既存タブに追加

azooKey-Desktop を参考に以下の設定項目を追加:

| 設定項目 | 型 | デフォルト | 説明 |
|---------|---|----------|------|
| Zenzai 有効/無効 | Bool | false | トグルスイッチ |
| プロフィール | String | "" | 変換の文脈ヒント（例：「田中太郎/エンジニア」）|
| 推論上限 | Int | 5 | 小さいほど速い（1〜50）|

`UserDefaults` キー（提案）:
- `keynaco.zenzai.enabled`
- `keynaco.zenzai.profile`
- `keynaco.zenzai.inferenceLimit`

設定変更時に `AzooKeyConverter` を再生成する（`InputController` 側で通知を受けて更新）。

---

## 実装順序

1. **Step 1**: モデルファイル取得・Xcode プロジェクトへの追加（手動作業）
2. **Step 2**: `Core/Package.swift` 修正 → `swift build` で Zenzai trait がビルドできることを確認
3. **Step 3**: `AzooKeyConverter.swift` 修正
4. **Step 4**: `InputHandler` / `InputController` に `leftSideContext` 伝播を追加
5. **Step 5**: 設定画面 UI 追加
6. ビルド・動作確認（`/deploy` で実機テスト）

---

## 注意点・リスク

### パフォーマンス
- Zenzai はリクエストごとに LLM 推論を実行するため、`inferenceLimit` が大きいと変換が遅延する
- 初回変換はモデルロードの分だけ遅い（数秒）
- `requestRichCandidates: false` で起動し、体感を確認してから `true` を検討する

### `options` のスレッド安全性
- 現在 `AzooKeyConverter` は `@unchecked Sendable`。`options` を `var` にする場合は注意
- 各リクエストで `options` のコピーを渡す（値型なので問題なし）

### モデルが見つからない場合
- `Bundle.main.url(forResource:withExtension:)` が `nil` を返す → `modelURL` が空文字 URL → Zenzai が `off` にフォールバックするよう防御処理を入れる

### Zenzai trait と `interoperabilityMode(.Cxx)`
- `Core/Package.swift` の `KeynacoCore` ターゲットはすでに `.interoperabilityMode(.Cxx)` を持っているため追加不要

---

## 完了条件

- [ ] モデルファイルがバンドルに含まれ `Bundle.main.url(forResource:withExtension:)` で取得できる
- [ ] Zenzai 有効時に `requestCandidates` の結果が変わることを確認（文脈語を変えて比較）
- [ ] `inferenceLimit` 変更が候補生成速度に反映される
- [ ] 設定画面から Zenzai ON/OFF・プロフィール・推論上限を変更できる
- [ ] Zenzai 無効時は従来通り動作する（リグレッションなし）

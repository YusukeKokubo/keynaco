import Foundation

// MARK: - 左文脈パイプライン（俯瞰）
//
// Zenzai / AzooKey へ渡す `InputHandler.leftSideContext` の生成経路。結合ルールの正本は
// `LeftContextResolver.resolve`、入力組み立ての正本は本 enum。
//
// ```
// [素材] sessionTextBuffer + imkBefore
//     ↓ LeftContextSource.assembleProduction / resolveSandbox
// [Input] LeftContextResolver.Input
//     ↓ LeftContextResolver.resolve  （300/400 字。PLAN260506b）
// [出力] handler.leftSideContext  → azooKeyLeftContext  → AzooKeyConverter
// ```
//
// ## 素材
//
// | 素材 | 更新 | クリア |
// |------|------|--------|
// | `sessionTextBuffer` | 確定語ごとに `appendToSessionBuffer`（上限 50 字・読点等はスキップ） | `activateServer`、ASCII Enter、組成空 Enter |
// | IMK `before` | 本番のみ。下記キャッシュ経由 | キャッシュ無効化（下記） |
//
// `sessionTextBuffer` は文末 `。` 等で `committedHistory` が消えても**残る**（PLAN260525）。
//
// ## 本番（InputController）
//
// 各 `runKeyDown` **先頭**で `resolvedLLMDocumentContextPrefix` が `leftSideContext` を再計算してから
// `handler.handle` する（キー処理中の変換は常に直前キー時点の文脈）。
//
// IMK `before` は `cachedSurroundingContext(location:before:after:)` に保持。取得タイミングは
// `applyPostKeyDownEffects` のみ（Space 再取得はしない）:
// - `documentSurroundingContextInvalidated` → キャッシュ nil
// - `composedHiragana` が空 → キャッシュ nil
// - 直前が空かつ今が非空 → `SurroundingIMKContext.fetch` を 1 回、location 付きで保存
//
// 組み立て時（`LeftContextSource.assembleProduction`）:
// - `selectedRange().location == NSNotFound` → `imkBefore` 不使用
// - キャッシュ location 一致かつ `before` 非空 → `imkBefore` に採用
// - キャッシュあり location 不一致 or `before` 空 → `shouldClearCache`（呼び出し側が nil 化）
//
// その他キャッシュ nil: `activateServer`、`commitComposition`。
// `documentSurroundingContextInvalidated` の set/clear 一覧は `InputHandler` の doc 参照。
//
// ## サンドボックス（DebugSocketServer）
//
// - `mockClient.documentBefore` ← `set_surrounding.before`（location 概念なし・常に有効）
// - `debugLeftContextOverride` ← `set_left_context`（非 nil なら resolver をバイパス）
// - `makeResponse` / キー処理前の `syncLeftSideContext` で `handler.leftSideContext` を再計算
// - `set_surrounding` / `set_left_context` も `syncLeftSideContext` 後に `leftSideContext` を返す
// - `documentBefore` が `sessionTextBuffer` の内容を既に含む場合、結合結果に短い重複が出ることがある（本番 IMK も同様）
//
// ## 新規コードの入口
//
// 入力組み立ては **必ず** `LeftContextSource` 経由。`LeftContextResolver.Input` の直組みは
// Core テスト（結合ルール・入力 factory）のみ。

/// 左文脈の入力組み立て。パイプライン俯瞰はファイル先頭 MARK を参照。
public enum LeftContextSource {

    /// 本番 IMK 経路の組み立て結果。副作用は呼び出し側が `shouldClearCache` に従って適用する。
    public struct ProductionAssembly: Equatable, Sendable {
        public var input: LeftContextResolver.Input
        /// キャッシュが存在するが location 不一致等で無効化すべき
        public var shouldClearCache: Bool

        public init(input: LeftContextResolver.Input, shouldClearCache: Bool) {
            self.input = input
            self.shouldClearCache = shouldClearCache
        }
    }

    /// 本番: キャッシュ済み surrounding とカーソル位置から `LeftContextResolver.Input` を組み立てる。
    public static func assembleProduction(
        sessionBuffer: String,
        cursorLocation: Int,
        cachedSurrounding: (location: Int, before: String)?
    ) -> ProductionAssembly {
        guard cursorLocation != NSNotFound else {
            return ProductionAssembly(
                input: .production(
                    sessionBuffer: sessionBuffer,
                    imkBefore: nil,
                    cursorLocationAvailable: false
                ),
                shouldClearCache: false
            )
        }

        var imkBefore: String?
        var shouldClearCache = false
        if let cache = cachedSurrounding {
            if cache.location == cursorLocation, !cache.before.isEmpty {
                imkBefore = cache.before
            } else {
                shouldClearCache = true
            }
        }

        return ProductionAssembly(
            input: .production(
                sessionBuffer: sessionBuffer,
                imkBefore: imkBefore,
                cursorLocationAvailable: true
            ),
            shouldClearCache: shouldClearCache
        )
    }

    /// サンドボックス: `documentBefore` を IMK `before` 相当として結合。`override` 指定時は resolver を通さない。
    public static func resolveSandbox(
        sessionBuffer: String,
        documentBefore: String,
        override: String? = nil
    ) -> String {
        if let override { return override }
        return LeftContextResolver.resolve(.sandbox(
            sessionBuffer: sessionBuffer,
            documentBefore: documentBefore
        ))
    }
}

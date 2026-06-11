import Foundation

// MARK: - 左文脈パイプライン（俯瞰）
//
// Zenzai / AzooKey へ渡す `InputHandler.leftContext` の生成経路。結合ルールの正本は
// `LeftContextResolver.combine`、入力組み立ての正本は本 enum。
//
// ```
// [素材] sessionTextBuffer + LeftContextIMKCache
//     ↓ LeftContextSource.resolveProduction / resolveSandbox
// [出力] LeftContext (sessionBuffer / imkBefore / combined)
//     ↓ leftContext.azooKeyValue → AzooKeyConverter
// ```
//
// ## 素材
//
// | 素材 | 更新 | クリア |
// |------|------|--------|
// | `sessionTextBuffer` | 確定語ごとに `appendToSessionBuffer`（上限 50 字・読点等はスキップ） | `activateServer`、ASCII Enter、組成空 Enter |
// | IMK `before` | 本番のみ。`leftContextIMKCache` 経由 | キャッシュ無効化（下記） |
//
// `sessionTextBuffer` は文末 `。` 等で `committedHistory` が消えても**残る**（PLAN260525）。
//
// ## 本番（InputController）
//
// 各 `runKeyDown` **先頭**で `resolveProduction` が `leftContext` を再計算してから
// `handler.handle` する（キー処理中の変換は常に直前キー時点の文脈）。
//
// IMK `before` は `leftContextIMKCache.snapshot` に保持。取得タイミングは
// `applyPostKeyDown` のみ（Space 再取得はしない）:
// - `leftContextIMKCache.invalidated` → キャッシュ nil
// - `composedHiragana` が空 → キャッシュ nil
// - 直前が空かつ今が非空 → `SurroundingIMKContext.fetch` を 1 回、location 付きで保存
//
// 組み立て時（`resolveProduction`）:
// - `selectedRange().location == NSNotFound` → `imkBefore` 不使用
// - キャッシュ location 一致かつ `before` 非空 → `imkBefore` に採用
// - キャッシュあり location 不一致 or `before` 空 → `cache.snapshot = nil`
//
// その他キャッシュ nil: `activateServer`、`commitComposition`（`resetCache`）。
// `invalidated` の set 一覧は `InputHandler` の `leftContextIMKCache` doc 参照。
//
// ## サンドボックス（DebugSocketServer）
//
// - `mockClient.documentBefore` ← `set_surrounding.before`（location 概念なし・常に有効）
// - `debugLeftContextOverride` ← `set_left_context`（非 nil なら resolver をバイパス）
// - `makeResponse` / キー処理前の `syncLeftSideContext` で `handler.leftContext` を再計算
// - `set_surrounding` / `set_left_context` も `syncLeftSideContext` 後に `leftSideContext` を返す
// - `documentBefore` が `sessionTextBuffer` の内容を既に含む場合、結合結果に短い重複が出ることがある（本番 IMK も同様）
//
// ## 新規コードの入口
//
// 入力組み立ては **必ず** `LeftContextSource` 経由。

/// 左文脈の入力組み立て。パイプライン俯瞰はファイル先頭 MARK を参照。
public enum LeftContextSource {

    /// 本番: キャッシュ済み surrounding とカーソル位置から `LeftContext` を組み立てる。
    /// location 不一致時は `cache.snapshot` を nil 化する。
    public static func resolveProduction(
        sessionBuffer: String,
        cache: inout LeftContextIMKCache,
        cursorLocation: Int
    ) -> LeftContext {
        guard cursorLocation != NSNotFound else {
            return LeftContext(
                sessionBuffer: sessionBuffer,
                imkBefore: nil,
                combined: LeftContextResolver.combine(
                    sessionBuffer: sessionBuffer,
                    imkBefore: nil,
                    cursorLocationAvailable: false
                )
            )
        }

        var imkBefore: String?
        if let snap = cache.snapshot {
            if snap.location == cursorLocation, !snap.before.isEmpty {
                imkBefore = snap.before
            } else {
                cache.snapshot = nil
            }
        }

        let combined = LeftContextResolver.combine(
            sessionBuffer: sessionBuffer,
            imkBefore: imkBefore,
            cursorLocationAvailable: true
        )
        return LeftContext(sessionBuffer: sessionBuffer, imkBefore: imkBefore, combined: combined)
    }

    /// キー処理後の IMK キャッシュ更新。`needsSurroundingSideEffects` が true のときのみ呼ぶ。
    public static func applyPostKeyDown(
        cache: inout LeftContextIMKCache,
        composedHiraganaEmpty: Bool,
        composedHiraganaWasEmpty: Bool,
        newSnapshot: IMKSurroundingSnapshot?
    ) {
        if cache.invalidated {
            cache.snapshot = nil
            cache.invalidated = false
        }
        if composedHiraganaEmpty {
            cache.snapshot = nil
        } else if composedHiraganaWasEmpty && !composedHiraganaEmpty {
            if let newSnapshot {
                cache.snapshot = newSnapshot
            }
        }
    }

    public static func resetCache(_ cache: inout LeftContextIMKCache) {
        cache = LeftContextIMKCache()
    }

    /// サンドボックス: `documentBefore` を IMK `before` 相当として結合。`override` 指定時は resolver を通さない。
    public static func resolveSandbox(
        sessionBuffer: String,
        documentBefore: String,
        override: String? = nil
    ) -> LeftContext {
        if let override {
            return LeftContext(sessionBuffer: sessionBuffer, imkBefore: nil, combined: override)
        }
        let imkBefore = documentBefore.isEmpty ? nil : documentBefore
        let combined = LeftContextResolver.combine(
            sessionBuffer: sessionBuffer,
            imkBefore: imkBefore,
            cursorLocationAvailable: true
        )
        return LeftContext(sessionBuffer: sessionBuffer, imkBefore: imkBefore, combined: combined)
    }
}

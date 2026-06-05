import Foundation

/// 左文脈の入力組み立て。結合ルールは `LeftContextResolver.resolve` が正本。
///
/// - 本番: IMK `cachedSurroundingContext` + `selectedRange().location` から `imkBefore` を解決
/// - サンドボックス: `documentBefore` を常に有効な `imkBefore` 相当として載せる
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

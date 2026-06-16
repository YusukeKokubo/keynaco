import AppKit

/// InputController から分離した純粋な状態遷移ロジック。
/// IMK ランタイムに依存しないため、ユニットテストで検証可能。
public struct CompositionState {

    public init() {}

    public var composedHiragana = ""
    public var pendingRomaji = ""

    /// ユーザーが現在打っている読み全体。マークドテキストの表示にも使う。
    public var composingText: String {
        composedHiragana + pendingRomaji
    }

    /// 組成中（未確定テキストあり）。`composingText` が空でないとき true。
    public var isComposing: Bool { !composingText.isEmpty }

    /// 確定時のテキストを返す（pending の "n" → "ん" 等を含む）
    public var finalizedText: String {
        composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
    }

    /// Space 確定前など、`absorbPendingIntoComposed` 後の `composedHiragana` を非破壊で見積もる。
    public func composedHiraganaAfterAbsorbingPending() -> String {
        guard !pendingRomaji.isEmpty else { return composedHiragana }
        return composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
    }

    /// `pendingRomaji` を `composedHiragana` へ取り込む。
    public mutating func absorbPendingIntoComposed() {
        guard !pendingRomaji.isEmpty else { return }
        composedHiragana += RomajiConverter.forceFinalize(pendingRomaji)
        pendingRomaji = ""
    }

    /// ローマ字を追加してひらがなに変換する。
    /// - Returns: 候補リフレッシュが必要かどうか
    public mutating func addRomaji(_ chars: String) -> Bool {
        // 非ローマ字文字（a-z・"-" 以外）が来たら pending をフラッシュしてから処理。
        // 例: "k" pending 中に "." を打つと "k." が詰まるのを防ぐ。
        let isRomajiChar = chars.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || $0.value == 0x2D  // a-z or "-"
        }
        if !isRomajiChar && !pendingRomaji.isEmpty {
            absorbPendingIntoComposed()
        }
        pendingRomaji += chars
        let result = RomajiConverter.convert(pendingRomaji)
        composedHiragana += result.converted
        pendingRomaji = result.pending
        return composedHiragana.count >= 2
    }

    /// Backspace 処理。
    /// - Returns: `(handled, candidateRefreshNeeded)`
    ///   handled=false は未確定文字列が空だった場合
    public mutating func backspace() -> (handled: Bool, candidateRefreshNeeded: Bool) {
        guard isComposing else { return (false, false) }
        if !pendingRomaji.isEmpty {
            pendingRomaji.removeLast()
        } else {
            composedHiragana.removeLast()
        }
        return (true, composedHiragana.count >= 2)
    }

    /// 全状態をリセットする。
    /// - Returns: リセット前に未確定文字列があったか
    public mutating func reset() -> Bool {
        guard isComposing else { return false }
        composedHiragana = ""
        pendingRomaji = ""
        return true
    }

    /// Shift 入力の検出
    public static func isShiftInput(characters: String, baseCharacters: String) -> Bool {
        characters != baseCharacters
    }
}

import Foundation

/// InputController から分離した純粋な状態遷移ロジック。
/// IMK ランタイムに依存しないため、ユニットテストで検証可能。
struct CompositionState {

    var composedHiragana = ""
    var pendingRomaji = ""
    var isAsciiMode = false

    /// マークドテキストに表示する未確定文字列
    var composingText: String {
        composedHiragana + pendingRomaji
    }

    /// 確定時のテキストを返す（pending の "n" → "ん" 等を含む）
    var finalizedText: String {
        composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
    }

    /// ローマ字を追加してひらがなに変換する。
    /// - Returns: 候補リフレッシュが必要かどうか
    mutating func addRomaji(_ chars: String) -> Bool {
        // 非ローマ字文字（a-z・"-" 以外）が来たら pending をフラッシュしてから処理。
        // 例: "k" pending 中に "." を打つと "k." が詰まるのを防ぐ。
        let isRomajiChar = chars.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || $0.value == 0x2D  // a-z or "-"
        }
        if !isRomajiChar && !pendingRomaji.isEmpty {
            composedHiragana += RomajiConverter.forceFinalize(pendingRomaji)
            pendingRomaji = ""
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
    mutating func backspace() -> (handled: Bool, candidateRefreshNeeded: Bool) {
        guard !composingText.isEmpty else { return (false, false) }
        if !pendingRomaji.isEmpty {
            pendingRomaji.removeLast()
        } else {
            composedHiragana.removeLast()
        }
        return (true, composedHiragana.count >= 2)
    }

    /// 全状態をリセットする。
    /// - Returns: リセット前に未確定文字列があったか
    mutating func reset() -> Bool {
        guard !composingText.isEmpty else { return false }
        composedHiragana = ""
        pendingRomaji = ""
        return true
    }

    /// Shift 入力の検出
    static func isShiftInput(characters: String, baseCharacters: String) -> Bool {
        characters != baseCharacters
    }
}

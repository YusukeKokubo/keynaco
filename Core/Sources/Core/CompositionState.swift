import AppKit

/// InputController から分離した純粋な状態遷移ロジック。
/// IMK ランタイムに依存しないため、ユニットテストで検証可能。
///
/// ## `hiddenPendingN` のライフサイクル（本 struct 内のみ set/clear）
///
/// | 操作 | 箇所 |
/// |------|------|
/// | **set `true`** | `addRomaji` — `"nn"` → `ん` + pending `"n"` 検出時 |
/// | **clear `false`** | `absorbPendingIntoComposed`、`addRomaji` の hidden-n 分岐、`backspace`、`reset` |
public struct CompositionState {

    /// "nn" 後の hidden n を保持すべき入力（y / n のみ）
    /// 母音が続く場合は hidden n を破棄して、"hanni" → "はんい" になるようにする。
    /// y は "nyu/nya" 等の拗音を拾うために保持する。
    private static let hiddenNKeepFollowers: Set<Character> = ["y", "n"]

    public init() {}

    public var composedHiragana = ""
    public var pendingRomaji = ""
    // "nn" → "ん" + pending "n" の状態。"n" は表示・確定に含めず、次の母音と組み合わせる。
    // 標準IME準拠: "nn" 後は "ん" のみ表示し、続けて "ni" と打てば "んに" になる。
    public var hiddenPendingN = false

    /// マークドテキストに表示する未確定文字列
    public var composingText: String {
        hiddenPendingN ? composedHiragana : composedHiragana + pendingRomaji
    }

    /// 組成中（未確定テキストあり）。`composingText` が空でないとき true。
    public var isComposing: Bool { !composingText.isEmpty }

    /// 確定時のテキストを返す（pending の "n" → "ん" 等を含む）
    public var finalizedText: String {
        // hiddenPendingN のとき pending "n" は捨てる（"nn" 後の確定は "ん" 1つ）
        hiddenPendingN ? composedHiragana : composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
    }

    /// `pendingRomaji` を `composedHiragana` へ取り込む。`hiddenPendingN` のときは `finalizedText` と同じく捨てるだけ。
    public mutating func absorbPendingIntoComposed() {
        guard !pendingRomaji.isEmpty else { return }
        if hiddenPendingN {
            pendingRomaji = ""
            hiddenPendingN = false
        } else {
            composedHiragana += RomajiConverter.forceFinalize(pendingRomaji)
            pendingRomaji = ""
        }
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
        // "nn" 後の hidden n の扱い:
        // - n が続く: hidden n を破棄して新しい n を受ける（konnna 対策）
        // - 子音（母音/y/n 以外）が続く: typo 許容として hidden n を破棄（hennkann... 対策）
        if hiddenPendingN {
            let incoming = chars.lowercased()
            if incoming == "n" {
                pendingRomaji = ""
                hiddenPendingN = false
            } else if incoming.count == 1,
                      let ch = incoming.first,
                      ch >= "a", ch <= "z",
                      !Self.hiddenNKeepFollowers.contains(ch) {
                pendingRomaji = ""
                hiddenPendingN = false
            }
        }
        pendingRomaji += chars
        let result = RomajiConverter.convert(pendingRomaji)
        composedHiragana += result.converted
        pendingRomaji = result.pending
        // "nn" → "ん" + pending "n" のとき非表示フラグを立てる
        hiddenPendingN = result.pending == "n" && result.converted.hasSuffix("ん")
        return composedHiragana.count >= 2
    }

    /// Backspace 処理。
    /// - Returns: `(handled, candidateRefreshNeeded)`
    ///   handled=false は未確定文字列が空だった場合
    public mutating func backspace() -> (handled: Bool, candidateRefreshNeeded: Bool) {
        guard isComposing else { return (false, false) }
        if hiddenPendingN {
            // "nn" → "ん"(表示) の状態: pending "n" と直前の "ん" をまとめて1操作で削除
            pendingRomaji = ""
            hiddenPendingN = false
            composedHiragana.removeLast()
        } else if !pendingRomaji.isEmpty {
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
        hiddenPendingN = false
        return true
    }

    /// Shift 入力の検出
    public static func isShiftInput(characters: String, baseCharacters: String) -> Bool {
        characters != baseCharacters
    }
}

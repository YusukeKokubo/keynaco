import AppKit

/// InputController から分離した純粋な状態遷移ロジック。
/// IMK ランタイムに依存しないため、ユニットテストで検証可能。
struct CompositionState {

    var composedHiragana = ""
    var pendingRomaji = ""
    // "nn" → "ん" + pending "n" の状態。"n" は表示・確定に含めず、次の母音と組み合わせる。
    // 標準IME準拠: "nn" 後は "ん" のみ表示し、続けて "ni" と打てば "んに" になる。
    var hiddenPendingN = false

    /// マークドテキストに表示する未確定文字列
    var composingText: String {
        hiddenPendingN ? composedHiragana : composedHiragana + pendingRomaji
    }

    /// 確定時のテキストを返す（pending の "n" → "ん" 等を含む）
    var finalizedText: String {
        // hiddenPendingN のとき pending "n" は捨てる（"nn" 後の確定は "ん" 1つ）
        hiddenPendingN ? composedHiragana : composedHiragana + RomajiConverter.forceFinalize(pendingRomaji)
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
            hiddenPendingN = false
        }
        // "nn" 後にさらに "n" を打った場合、hidden n を破棄して新しい pending として扱う
        // 例: "konnna" → こ+ん+な（hidden n + 新n が再び nn→ん にならないよう防ぐ）
        if hiddenPendingN && chars == "n" {
            pendingRomaji = ""
            hiddenPendingN = false
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
    mutating func backspace() -> (handled: Bool, candidateRefreshNeeded: Bool) {
        guard !composingText.isEmpty else { return (false, false) }
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

    var segmentState: SegmentState? = nil
    var isSegmentMode: Bool { segmentState != nil }

    /// 全状態をリセットする。
    /// - Returns: リセット前に未確定文字列またはセグメント状態があったか
    mutating func reset() -> Bool {
        guard !composingText.isEmpty || segmentState != nil else { return false }
        composedHiragana = ""
        pendingRomaji = ""
        hiddenPendingN = false
        segmentState = nil
        return true
    }

    /// Shift 入力の検出
    static func isShiftInput(characters: String, baseCharacters: String) -> Bool {
        characters != baseCharacters
    }
}

// MARK: - セグメント変換

struct Segment {
    let reading: String
    var candidates: [String]
    var selectedIndex: Int
    var historyEnd: Int
    var isManuallyAdjusted: Bool = false

    var selectedText: String {
        guard !candidates.isEmpty else { return reading }
        return candidates[selectedIndex]
    }
}

struct SegmentState {
    var segments: [Segment]
    var focusedIndex: Int
    /// LLM による読み全体の一括変換テキスト。各文節先頭候補の連結がこの文字列と一致しうる（推論失敗時は先頭文節のみ挿入）。
    var llmWholeText: String? = nil

    var focusedSegment: Segment {
        get { segments[focusedIndex] }
        set { segments[focusedIndex] = newValue }
    }

    var allSelectedText: String {
        segments.map(\.selectedText).joined()
    }

    func attributedString(overrideFocusedText: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            let text = (i == focusedIndex)
                ? (overrideFocusedText ?? seg.selectedText)
                : seg.selectedText
            let style: Int = (i == focusedIndex)
                ? NSUnderlineStyle.thick.rawValue
                : NSUnderlineStyle.single.rawValue
            result.append(NSAttributedString(string: text, attributes: [.underlineStyle: style]))
        }
        return result
    }
}

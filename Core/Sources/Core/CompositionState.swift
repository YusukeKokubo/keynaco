import AppKit

/// InputController から分離した純粋な状態遷移ロジック。
/// IMK ランタイムに依存しないため、ユニットテストで検証可能。
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

    public var segmentState: SegmentState? = nil
    public var isSegmentMode: Bool { segmentState != nil }

    /// 全状態をリセットする。
    /// - Returns: リセット前に未確定文字列またはセグメント状態があったか
    public mutating func reset() -> Bool {
        guard !composingText.isEmpty || segmentState != nil else { return false }
        composedHiragana = ""
        pendingRomaji = ""
        hiddenPendingN = false
        segmentState = nil
        return true
    }

    /// Shift 入力の検出
    public static func isShiftInput(characters: String, baseCharacters: String) -> Bool {
        characters != baseCharacters
    }
}

// MARK: - 文節選択（AzooKey Desktop `.selecting` 相当）

public struct Segment {
    public let reading: String
    public var candidates: [String]
    public var selectedIndex: Int
    public var historyEnd: Int
    public var isManuallyAdjusted: Bool = false

    public var selectedText: String {
        guard !candidates.isEmpty else { return reading }
        return candidates[selectedIndex]
    }
}

/// azooKey-Desktop の `SegmentsManager` + `.selecting` に相当。
/// `firstClauseResults` マージ候補を選び、`composingCount`（`inputLength`）で部分確定する。
public struct SegmentState {
    /// 未確定の読み全体（`composedHiragana` と同期）
    public var convertTarget: String
    /// 表示・確定に使う行（エンジン候補 + 履歴等を `rows` に統合）
    public var rows: [AzooKeyClauseCandidate]
    public var selectedIndex: Int
    /// Shift+矢印 / Ctrl+i,o で境界を動かしたあとは `mainResults` のみ再取得
    public var didExperienceSegmentEdition: Bool = false
    /// 手動境界（`convertTarget` 先頭からの文字数）。nil なら選択候補の `inputLength`。
    public var manualClauseEnd: Int?
    /// この Space セッションで確定済みの文節
    public var confirmedSegments: [(reading: String, text: String)] = []
    /// 直近 `buildClauseCandidateAction` の履歴区切り（Shift+Delete 用）
    public var displayHistoryEnd: Int = 0

    public init(
        convertTarget: String,
        rows: [AzooKeyClauseCandidate],
        selectedIndex: Int = 0,
        confirmedSegments: [(reading: String, text: String)] = []
    ) {
        self.convertTarget = convertTarget
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.confirmedSegments = confirmedSegments
    }

    public var effectiveClauseEnd: Int {
        if let manualClauseEnd {
            return max(1, min(manualClauseEnd, convertTarget.count))
        }
        guard rows.indices.contains(selectedIndex) else { return min(1, convertTarget.count) }
        return max(1, min(rows[selectedIndex].inputLength, convertTarget.count))
    }

    public var clauseReading: String {
        String(convertTarget.prefix(effectiveClauseEnd))
    }

    public var remainingReading: String {
        String(convertTarget.dropFirst(effectiveClauseEnd))
    }

    public var pendingReading: String { convertTarget }

    /// 候補ウィンドウ互換（`current` = 左端文節ビュー）
    public var current: Segment {
        let texts = rows.map(\.text)
        let idx = texts.isEmpty ? 0 : min(selectedIndex, texts.count - 1)
        return Segment(
            reading: clauseReading,
            candidates: texts,
            selectedIndex: idx,
            historyEnd: displayHistoryEnd,
            isManuallyAdjusted: didExperienceSegmentEdition
        )
    }

    public var focusedSegment: Segment {
        get { current }
    }

    public var focusedIndex: Int { 0 }

    public var allSelectedText: String {
        confirmedSegments.map(\.text).joined() + (rows.indices.contains(selectedIndex) ? rows[selectedIndex].text : clauseReading)
    }

    public var snapshotSegmentTexts: [String] {
        var texts = confirmedSegments.map(\.text)
        if rows.indices.contains(selectedIndex) { texts.append(rows[selectedIndex].text) }
        if !remainingReading.isEmpty { texts.append(remainingReading) }
        return texts
    }

    /// Desktop `getCurrentMarkedText` `.selecting`: focused 表層 + unfocused 残り読み
    public func attributedString(overrideFocusedText: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let focused = overrideFocusedText ?? (rows.indices.contains(selectedIndex) ? rows[selectedIndex].text : clauseReading)
        result.append(NSAttributedString(string: focused, attributes: [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
        ]))
        let remainder = remainingReading
        if !remainder.isEmpty {
            result.append(NSAttributedString(string: remainder, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
        }
        return result
    }
}

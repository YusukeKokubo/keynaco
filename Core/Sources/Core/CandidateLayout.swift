// MARK: - CandidateSection

struct CandidateSection: Sendable {
    enum Kind: Hashable, Sendable {
        case fixedHiragana  // ひらがな先頭固定（hiraganaPreferred 時）
        case userDict       // ユーザー辞書
        case zenzaiTop1     // Zenzai top-1 プロモート
        case highHistory    // 高スコア履歴
        case number         // 数値変換
        case dateTime       // 日時変換
        case azooKeyDict    // AzooKey 辞書候補
        case katakana       // カタカナ変換（末尾固定）
    }

    let kind: Kind
    let items: [String]

    init(kind: Kind, items: [String]) {
        self.kind = kind
        self.items = items
    }
}

// MARK: - InitialRowPolicy

enum InitialRowPolicy: Sendable {
    /// 該当文字列の最初の出現位置（hiraganaPreferred 用）。見つからなければ afterFixed にフォールバック
    case firstMatching(String)
    /// 強制的に 0 行目（Zenzai top-1 を初期選択にする場合等）
    case atZero
    /// 固定セクション直後（既定）
    case afterFixed
}

// MARK: - CandidateLayout

/// 候補リストとそのセクション境界をまとめた値。
/// `0 <= fixedEnd <= historyEnd <= candidates.count` を保証する。
struct CandidateLayout: Sendable {

    let candidates: [String]
    /// .fixedHiragana / .userDict / .zenzaiTop1 の末尾インデックス
    let fixedEnd: Int
    /// fixedEnd + .highHistory の末尾（Shift+Delete で削除可能な履歴ブロックの終端）
    let historyEnd: Int
    let initialRow: Int

    private static let fixedSectionKinds: Set<CandidateSection.Kind> = [
        .fixedHiragana, .userDict, .zenzaiTop1,
    ]

    static let defaultSectionOrder: [CandidateSection.Kind] = [
        .fixedHiragana,
        .userDict,
        .zenzaiTop1,
        .highHistory,
        .number, .dateTime,
        .azooKeyDict,
        .katakana,
    ]

    /// Zenzai top-1 をひらがな固定より前に置く順序（履歴なしで Zenzai 提案ありの場合に使用）
    static let zenzaiFirstSectionOrder: [CandidateSection.Kind] = [
        .userDict,
        .zenzaiTop1,
        .fixedHiragana,
        .highHistory,
        .number, .dateTime,
        .azooKeyDict,
        .katakana,
    ]

    init(
        sections: [CandidateSection],
        sectionOrder: [CandidateSection.Kind],
        initialRowPolicy: InitialRowPolicy
    ) {
        let sectionMap = Dictionary(
            sections.map { ($0.kind, $0.items) },
            uniquingKeysWith: { first, _ in first }
        )

        var seen = Set<String>()
        var result: [String] = []
        var fixedEndAcc = 0
        var historyEndAcc: Int? = nil

        for kind in sectionOrder {
            let items = sectionMap[kind] ?? []
            for item in items where seen.insert(item).inserted {
                result.append(item)
            }
            if Self.fixedSectionKinds.contains(kind) {
                fixedEndAcc = result.count
            }
            if kind == .highHistory, historyEndAcc == nil {
                historyEndAcc = result.count
            }
        }

        candidates = result
        fixedEnd = fixedEndAcc
        historyEnd = historyEndAcc ?? fixedEndAcc

        assert(fixedEnd <= historyEnd,
               "fixedEnd (\(fixedEndAcc)) > historyEnd (\(historyEnd))")
        assert(historyEnd <= result.count,
               "historyEnd (\(historyEnd)) > candidates.count (\(result.count))")

        switch initialRowPolicy {
        case .firstMatching(let s):
            self.initialRow = result.firstIndex(of: s) ?? (fixedEndAcc < result.count ? fixedEndAcc : 0)
        case .atZero:
            self.initialRow = 0
        case .afterFixed:
            self.initialRow = fixedEndAcc < result.count ? fixedEndAcc : 0
        }
    }
}

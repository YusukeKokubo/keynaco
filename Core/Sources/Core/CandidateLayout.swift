// MARK: - CandidateSection

struct CandidateSection: Sendable {
    enum Kind: Hashable, Sendable {
        case fixedHiragana  // ひらがな先頭固定（hiraganaPreferred 時）
        case userDict       // ユーザー辞書
        case zenzaiTop1     // Zenzai top-1 プロモート
        case exactMatchHistory // 読み完全一致の履歴（Zenzai より優先）
        case highHistory    // 前方一致などその他の高スコア履歴
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

enum InitialRowPolicy: Equatable, Sendable {
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

    private static let defaultFixedSectionKinds: Set<CandidateSection.Kind> = [
        .fixedHiragana, .userDict, .zenzaiTop1,
    ]

    /// 読み完全一致履歴を Zenzai より前に出す並びでは Zenzai を固定枠に含めない（履歴と Shift+Delete 境界を壊さないため）。
    private static let exactMatchFirstFixedSectionKinds: Set<CandidateSection.Kind> = [
        .fixedHiragana, .userDict,
    ]

    private static func fixedSectionKinds(for sectionOrder: [CandidateSection.Kind]) -> Set<CandidateSection.Kind> {
        sectionOrder.contains(.exactMatchHistory)
            ? exactMatchFirstFixedSectionKinds
            : defaultFixedSectionKinds
    }

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

    /// 読み完全一致の履歴あり。Zenzai より先に exact / その他履歴を出す。
    static let exactMatchFirstSectionOrder: [CandidateSection.Kind] = [
        .fixedHiragana,
        .userDict,
        .exactMatchHistory,
        .highHistory,
        .number, .dateTime,
        .zenzaiTop1,
        .azooKeyDict,
        .katakana,
    ]

    static let exactMatchZenzaiFirstSectionOrder: [CandidateSection.Kind] = [
        .exactMatchHistory,
        .userDict,
        .fixedHiragana,
        .highHistory,
        .number, .dateTime,
        .zenzaiTop1,
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
            if Self.fixedSectionKinds(for: sectionOrder).contains(kind) {
                fixedEndAcc = result.count
            }
            if kind == .exactMatchHistory || kind == .highHistory {
                historyEndAcc = result.count
            }
        }

        candidates = result
        fixedEnd = fixedEndAcc
        // ループ構造上これらが破れることはないが、リリースビルドでも不変式を保証するため防御的に計算する。
        let rawHistoryEnd = historyEndAcc ?? fixedEndAcc
        historyEnd = min(max(rawHistoryEnd, fixedEndAcc), result.count)

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

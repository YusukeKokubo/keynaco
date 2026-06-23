// MARK: - CandidateSection

struct CandidateSection: Sendable {
    enum Kind: Hashable, Sendable {
        case fixedHiragana  // ひらがな先頭固定（hiraganaPreferred 時）
        case userDict       // ユーザー辞書
        case exactMatchHistory // 読み完全一致の履歴
        /// 打鍵中: merged スコアが exact より十分高い前方一致履歴（exact より前に出す）
        case promotedPrefixHistory
        case highHistory    // 前方一致などその他の高スコア履歴
        case number         // 数値変換
        case dateTime       // 日時変換
        case azooKeyDict    // AzooKey 辞書候補（Zenzai 推論結果・カタカナ表記も内部スコアに込みでこのセクションに混ざる）
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
    /// 固定セクション直後（既定）
    case afterFixed
}

// MARK: - CandidateLayout

/// 候補リストとそのセクション境界をまとめた値。
/// `0 <= fixedEnd <= historyEnd <= candidates.count` を保証する。
struct CandidateLayout: Sendable {

    let candidates: [String]
    /// .fixedHiragana / .userDict の末尾インデックス
    let fixedEnd: Int
    /// fixedEnd + 履歴セクションの末尾（Shift+Delete で削除可能な履歴ブロックの終端）
    let historyEnd: Int
    let initialRow: Int

    private static let fixedSectionKinds: Set<CandidateSection.Kind> = [
        .fixedHiragana, .userDict,
    ]

    /// 読み完全一致の履歴なし。辞書候補を前方一致履歴より優先する。
    static let defaultSectionOrder: [CandidateSection.Kind] = [
        .fixedHiragana,
        .userDict,
        .number, .dateTime,
        .azooKeyDict,
        .highHistory,
    ]

    /// 読み完全一致の履歴あり。固定枠の直後に exactMatch を出し、辞書の後ろに前方一致履歴を置く。
    static let exactMatchFirstSectionOrder: [CandidateSection.Kind] = [
        .fixedHiragana,
        .userDict,
        .exactMatchHistory,
        .number, .dateTime,
        .azooKeyDict,
        .highHistory,
    ]

    /// 高スコア前方一致が exact より優先される打鍵中。昇格 prefix → exact → 辞書 → 残り prefix。
    static let prefixPromotedSectionOrder: [CandidateSection.Kind] = [
        .fixedHiragana,
        .userDict,
        .promotedPrefixHistory,
        .exactMatchHistory,
        .number, .dateTime,
        .azooKeyDict,
        .highHistory,
    ]

    private static let historyEndSectionKinds: Set<CandidateSection.Kind> = [
        .promotedPrefixHistory, .exactMatchHistory,
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
            if Self.historyEndSectionKinds.contains(kind) {
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
        case .afterFixed:
            self.initialRow = fixedEndAcc < result.count ? fixedEndAcc : 0
        }
    }

}

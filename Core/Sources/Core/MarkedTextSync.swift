import Foundation

/// IMK marked text の組み立て。`InputHandler.syncMarkedText` が組み立ての正本。
/// 適用は `InputHandler.applyCandidateAction` 経由（Controller / ソケット / テスト）。
public enum MarkedTextSync {

    /// 括弧モード、または組成ひらがななしで候補のみ表示するとき。
    public static func needsCandidateOnly(
        isBracketMode: Bool,
        candidateVisible: Bool,
        composedHiragana: String
    ) -> Bool {
        isBracketMode || (candidateVisible && composedHiragana.isEmpty)
    }

    public static func resolve(
        isBracketMode: Bool,
        candidateVisible: Bool,
        isExplicitlySelected: Bool,
        composedHiragana: String,
        pendingRomaji: String,
        composingText: String,
        selectedCandidate: String?
    ) -> String {
        let candidateOnly = needsCandidateOnly(
            isBracketMode: isBracketMode,
            candidateVisible: candidateVisible,
            composedHiragana: composedHiragana
        )
        if candidateOnly, let selected = selectedCandidate {
            return selected
        }
        // 打鍵サジェスト（↑↓・Space 変換前）は組成ひらがなのまま。明示選択後だけ候補に追従。
        if candidateVisible, isExplicitlySelected, let selected = selectedCandidate {
            return selected + pendingRomaji
        }
        // 打鍵サジェスト表示中のみ未変換ローマ字尾を marked に出さない（候補非表示時は composingText を見せる）。
        if candidateVisible,
           !isExplicitlySelected,
           !composedHiragana.isEmpty,
           !composedHiragana.allSatisfy(\.isASCII),
           !pendingRomaji.isEmpty,
           pendingRomaji.allSatisfy(\.isASCII) {
            return composedHiragana
        }
        return composingText
    }
}

import Foundation

/// IMK marked text の組み立て。`InputHandler.syncMarkedText` が唯一の適用経路。
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
        if candidateVisible, let selected = selectedCandidate {
            return selected + pendingRomaji
        }
        return composingText
    }
}

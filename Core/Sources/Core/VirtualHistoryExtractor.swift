import Foundation

/// IMK `before` テキスト末尾から N-gram 予測用の仮想 prev 語列を抽出する。
public enum VirtualHistoryExtractor {
    private static let sentenceTerminators = "。．！？!?\n"

    /// 末尾から最大2語を古→新の順で返す。文末記号直後は空。
    public static func extract(from before: String) -> [String] {
        let tail = String(before.suffix(30))

        if let last = tail.last, sentenceTerminators.contains(last) { return [] }

        let lastBreakIdx = tail.lastIndex(where: { sentenceTerminators.contains($0) })
        let scoped = lastBreakIdx.map { String(tail[tail.index(after: $0)...]) } ?? tail

        let delimiters: Set<Character> = ["、", "，", " ", "\t", "（", "）", "「", "」", "(", ")"]
        var tokens: [String] = []
        var current = ""
        for ch in scoped {
            if delimiters.contains(ch) {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        return Array(tokens.suffix(2))
    }
}

import AppKit

public extension InputHandler {

    func isHiraganaPreferred(_ h: String) -> Bool {
        hiraganaPreferredSet.contains(h) || HiraganaPreferredBuiltins.words[h] != nil
    }

    /// 複数の配列を順序保持して重複排除しながら連結する（O(n) 版 flatten + deduplicate）。
    static func merged(_ arrays: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for arr in arrays {
            for s in arr where seen.insert(s).inserted {
                result.append(s)
            }
        }
        return result
    }
}

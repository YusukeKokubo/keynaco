import AppKit

public extension InputHandler {

    /// 確定語の segmentize 学習を行う最小読み長。短すぎる読みは文節分割の意味が薄い。
    static let segmentizeMinReadingLength = 4

    func isHiraganaPreferred(_ h: String) -> Bool {
        hiraganaPreferredSet.contains(h)
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

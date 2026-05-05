import Foundation

public extension InputHandler {
    public static func generateNumberCandidates(for reading: String) -> [String] {
        guard !reading.isEmpty,
              reading.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 })
        else { return [] }

        var result: [String] = []
        result.append(KanaUtils.toZenkakuAscii(reading))

        // 先頭ゼロがない整数のみ桁区切り候補を生成
        if let n = Int(reading), String(n) == reading {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            if let comma = formatter.string(from: NSNumber(value: n)), comma != reading {
                result.append(comma)
                result.append(KanaUtils.toZenkakuAscii(comma))
            }
        }
        return result
    }
}

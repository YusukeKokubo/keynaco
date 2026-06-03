import Foundation

/// AzooKey `requestCandidates` の 1 候補（表層 + 消費する読み長）。
public struct AzooKeyClauseCandidate: Sendable, Equatable {
    public let text: String
    public let inputLength: Int

    public init(text: String, inputLength: Int) {
        self.text = text
        self.inputLength = max(1, inputLength)
    }
}

/// `ConversionResult` の Desktop 利用分（`mainResults` / `firstClauseResults`）。
public struct AzooKeyConversionResult: Sendable, Equatable {
    public let mainResults: [AzooKeyClauseCandidate]
    public let firstClauseResults: [AzooKeyClauseCandidate]

    public init(
        mainResults: [AzooKeyClauseCandidate],
        firstClauseResults: [AzooKeyClauseCandidate]
    ) {
        self.mainResults = mainResults
        self.firstClauseResults = firstClauseResults
    }
}

/// azooKey-Desktop `SegmentsManager.rawCandidatesList` と同じマージ規則。
public enum AzooKeyCandidateMerge {
    /// 末尾の助動詞・丁寧語（長い順）。AzooKey が全文候補のみのときの境界フォールバック用。
    private static let trailingSegmentSuffixes: [String] = [
        "ませんでした",
        "ません",
        "でした",
        "でしょう",
        "だろう",
        "ている",
        "ました",
        "です",
        "ます",
        "ない",
        "かしら",
    ]

    /// Space 直後の先頭文節で、残り読みに切り出す末尾 1 文字助詞。
    private static let trailingSegmentParticles: Set<Character> = [
        "は", "が", "を", "に", "で", "と", "へ", "も", "の", "や", "て", "ね", "よ", "か", "さ", "な",
        "だ", "ぞ", "ぜ", "ば", "ぱ", "り", "し", "み", "く", "け", "れ", "ろ", "わ", "ん",
    ]

    /// 末尾の助詞・助動詞を除いた読み長。該当しないときは `nil`。
    public static func clauseEndStrippingTrailingParticle(_ convertTarget: String) -> Int? {
        guard convertTarget.count >= 2 else { return nil }
        for suffix in trailingSegmentSuffixes {
            guard convertTarget.count > suffix.count, convertTarget.hasSuffix(suffix) else { continue }
            let end = convertTarget.count - suffix.count
            if end >= 1 { return end }
        }
        guard let last = convertTarget.last, trailingSegmentParticles.contains(last) else { return nil }
        let end = convertTarget.count - 1
        return end >= 1 ? end : nil
    }

    /// 読み全体を消費する候補か（Desktop `isWholeComposingText` の文字列版）。
    public static func consumesWholeTarget(_ inputLength: Int, convertTarget: String) -> Bool {
        inputLength >= convertTarget.count
    }

    /// Space 直後の変換範囲（先頭文節の読み長）。
    /// Desktop `.selecting` 準拠: `firstClauseResults`（手動編集後は `mainResults`）の部分候補 `inputLength` のみ。
    public static func defaultClauseEnd(
        result: AzooKeyConversionResult,
        convertTarget: String
    ) -> Int {
        defaultClauseEndFromConversion(result: result, convertTarget: convertTarget)
    }

    private static func defaultClauseEndFromConversion(
        result: AzooKeyConversionResult?,
        convertTarget: String
    ) -> Int {
        let total = convertTarget.count
        guard total > 0 else { return 1 }
        guard let result else { return total }
        // Desktop は firstClause の先頭部分候補を使う（エンジン返却順を信頼）。
        let partialFirst = result.firstClauseResults.filter {
            !consumesWholeTarget($0.inputLength, convertTarget: convertTarget)
        }
        if let first = partialFirst.first {
            return max(1, min(first.inputLength, total))
        }
        if let partialMain = result.mainResults.first(where: {
            !consumesWholeTarget($0.inputLength, convertTarget: convertTarget)
        }) {
            return max(1, min(partialMain.inputLength, total))
        }
        return total
    }

    /// 文節境界を手動編集したあとは `mainResults` のみ。
    public static func mergedList(
        result: AzooKeyConversionResult,
        convertTarget: String,
        segmentEdition: Bool
    ) -> [AzooKeyClauseCandidate] {
        if segmentEdition {
            return result.mainResults
        }
        if result.firstClauseResults.contains(where: { consumesWholeTarget($0.inputLength, convertTarget: convertTarget) }) {
            return result.mainResults
        }
        let seen = Set(result.firstClauseResults.map(\.text))
        return result.firstClauseResults + result.mainResults.filter { !seen.contains($0.text) }
    }

    /// 先頭文節用のエンジン候補（全文候補を除く）。
    public static func clauseScopedEngineRows(
        result: AzooKeyConversionResult,
        convertTarget: String,
        clauseEnd: Int,
        segmentEdition: Bool
    ) -> [AzooKeyClauseCandidate] {
        let merged = mergedList(result: result, convertTarget: convertTarget, segmentEdition: segmentEdition)
        return merged.filter { $0.inputLength <= clauseEnd }
    }
}

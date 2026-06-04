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
///
/// 文節境界（`defaultClauseEnd`）は **エンジン部分候補の `inputLength` のみ** から決める。
/// 全文候補しか無いときだけ、読み末尾の助動詞・丁寧語接尾（です・ます等）を剥がすフォールバックを使う。
/// 語中の「は」スキャンや語尾「し」の単独除去などの形態素ヒューリスティックは使わない。
public enum AzooKeyCandidateMerge {
    /// 読み末尾の助動詞・丁寧語（長い順）。`defaultClauseEnd` のフォールバック専用。
    private static let trailingPoliteSuffixes: [String] = [
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

    /// Space 直後の先頭文節で、残り読みに切り出す末尾 1 文字助詞（助動詞・語尾含む広い集合）。
    private static let trailingSegmentParticles: Set<Character> = [
        "は", "が", "を", "に", "で", "と", "へ", "も", "の", "や", "て", "ね", "よ", "か", "さ", "な",
        "だ", "ぞ", "ぜ", "ば", "ぱ", "り", "し", "み", "く", "け", "れ", "ろ", "わ", "ん",
    ]

    /// 文節境界として切り出す格助詞・接続助詞のみ（`shouldUseNormalCandidateWindowInsteadOfSegment` 用）。
    private static let clauseSplitTrailingParticles: Set<Character> = [
        "は", "が", "を", "に", "で", "と", "へ", "も", "の", "や", "て", "ね", "よ", "か",
    ]

    /// 残り読みが助詞 1 文字だけか（助動詞・語尾含む広い集合）。
    public static func isTrailingParticleOnlyRemainder(_ remainder: String) -> Bool {
        guard remainder.count == 1, let last = remainder.last else { return false }
        return trailingSegmentParticles.contains(last)
    }

    /// 残り 1 文字が文節境界として切り出す助詞か（格助詞・接続助詞のみ）。
    public static func isClauseSplitTrailingParticleOnlyRemainder(_ remainder: String) -> Bool {
        guard remainder.count == 1, let last = remainder.last else { return false }
        return clauseSplitTrailingParticles.contains(last)
    }

    /// 先頭文節分割で残り 1 文字が語の一部になるときは文節モードに入らず通常窓へ。
    /// 例: わたし→わた|し（×）、たのしい→たのし|い（×）、わたしは→わたし|は（○）。
    public static func shouldUseNormalCandidateWindowInsteadOfSegment(
        clauseEnd: Int,
        convertTarget: String
    ) -> Bool {
        guard clauseEnd < convertTarget.count else { return true }
        let remainder = String(convertTarget.dropFirst(clauseEnd))
        guard remainder.count < 2 else { return false }
        return !isClauseSplitTrailingParticleOnlyRemainder(remainder)
            && clauseEnd >= convertTarget.count - 1
    }

    /// 末尾の助動詞・丁寧語接尾を除いた読み長（フォールバック・診断用）。単一助詞は剥がさない。
    public static func clauseEndStrippingTrailingParticle(_ convertTarget: String) -> Int? {
        guard convertTarget.count >= 2 else { return nil }
        for suffix in trailingPoliteSuffixes {
            guard convertTarget.count > suffix.count, convertTarget.hasSuffix(suffix) else { continue }
            let end = convertTarget.count - suffix.count
            if end >= 1 { return end }
        }
        return nil
    }

    /// 読み全体を消費する候補か（Desktop `isWholeComposingText` の文字列版）。
    public static func consumesWholeTarget(_ inputLength: Int, convertTarget: String) -> Bool {
        inputLength >= convertTarget.count
    }

    /// Space 直後の変換範囲（先頭文節の読み長）。
    /// Desktop `.selecting` 準拠: `firstClauseResults`（手動編集後は `mainResults`）の部分候補 `inputLength`。
    public static func defaultClauseEnd(
        result: AzooKeyConversionResult,
        convertTarget: String
    ) -> Int {
        defaultClauseEndFromConversion(result: result, convertTarget: convertTarget)
    }

    private static func partialRows(
        _ rows: [AzooKeyClauseCandidate],
        convertTarget: String
    ) -> [AzooKeyClauseCandidate] {
        rows.filter { !consumesWholeTarget($0.inputLength, convertTarget: convertTarget) }
    }

    /// 信頼できる部分候補から文節右端（読み一致・格助詞境界）。
    private static func clauseEndFromStrongPartials(
        _ partials: [AzooKeyClauseCandidate],
        convertTarget: String,
        total: Int
    ) -> Int? {
        guard !partials.isEmpty else { return nil }

        let readingAligned = partials.filter {
            String(convertTarget.prefix($0.inputLength)) == $0.text
        }

        // 残りが格助詞 1 文字だけ → 最長の読み一致部分（こんにち|は、あなた|は）
        let beforeSingleParticle = readingAligned.filter {
            let remainder = String(convertTarget.dropFirst($0.inputLength))
            return isClauseSplitTrailingParticleOnlyRemainder(remainder)
        }
        if let n = longestPartialLength(in: beforeSingleParticle, total: total) {
            return n
        }

        // 残りが「は…」で続く複合（わたし|はがくせい）。「こん|には」のように語中の に では切らない。
        let beforeWaTopic = readingAligned.filter {
            let remainder = String(convertTarget.dropFirst($0.inputLength))
            return remainder.first == "は"
        }
        if let n = shortestPartialLength(in: beforeWaTopic, total: total) {
            return n
        }

        // です・ます付きは語中の短い読み一致（がく:2 等）より接尾フォールバックを優先する
        if clauseEndStrippingTrailingParticle(convertTarget) != nil {
            return nil
        }

        return longestPartialLength(in: readingAligned, total: total)
    }

    /// 弱いヒューリスティック（ひらがな表層優先）。`です` 接尾フォールバックより後に試す。
    private static func clauseEndFromWeakPartials(
        _ partials: [AzooKeyClauseCandidate],
        total: Int
    ) -> Int? {
        guard !partials.isEmpty else { return nil }
        let hiraganaOnly = partials.filter { isAllHiragana($0.text) }
        if let n = longestPartialLength(in: hiraganaOnly, total: total) {
            return n
        }
        return longestPartialLength(in: partials, total: total)
    }

    private static func shortestPartialLength(
        in partials: [AzooKeyClauseCandidate],
        total: Int
    ) -> Int? {
        guard let best = partials.min(by: { $0.inputLength < $1.inputLength }),
              best.inputLength < total else { return nil }
        return best.inputLength
    }

    private static func longestPartialLength(
        in partials: [AzooKeyClauseCandidate],
        total: Int
    ) -> Int? {
        guard let best = partials.max(by: { $0.inputLength < $1.inputLength }),
              best.inputLength < total else { return nil }
        return best.inputLength
    }

    private static func isAllHiragana(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) }
    }

    private static func defaultClauseEndFromConversion(
        result: AzooKeyConversionResult?,
        convertTarget: String
    ) -> Int {
        let total = convertTarget.count
        guard total > 0 else { return 1 }
        guard let result else { return total }

        let partialFirst = partialRows(result.firstClauseResults, convertTarget: convertTarget)
        let partialMain = partialRows(result.mainResults, convertTarget: convertTarget)

        if let n = clauseEndFromStrongPartials(partialFirst, convertTarget: convertTarget, total: total) {
            return n
        }
        if let n = clauseEndFromStrongPartials(partialMain, convertTarget: convertTarget, total: total) {
            return n
        }
        if let stripped = clauseEndStrippingTrailingParticle(convertTarget), stripped < total {
            return stripped
        }
        if let n = clauseEndFromWeakPartials(partialFirst, total: total) {
            return n
        }
        if let n = clauseEndFromWeakPartials(partialMain, total: total) {
            return n
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

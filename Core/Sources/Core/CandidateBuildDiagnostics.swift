#if DEBUG

import Foundation

/// `assembleCandidateList` の初期行決定に使った入力と結果。デバッグスナップショット用。
public struct CandidateBuildDiagnostics: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case shown
        case dismissedEmpty
        case dismissedFunctionalWord
    }

    public var trigger: String
    public var reading: String
    public var outcome: Outcome

    public var hiraganaPreferred: Bool
    public var hiraganaBuiltin: Bool
    public var historyEntries: [HistoryEntry]
    public var userDictExact: [String]
    public var azooKeyCandidates: [String]
    public var azooKeyApiOrder: [String]

    public var initialText: String?
    public var fixedEnd: Int
    /// `"historyPrefix:情報共有(93.00)"` 形式のスコア付き source 要約。
    public var scoredSources: [String]

    public var deferAzooKeyWhileTyping: Bool

    /// イベントログ用の 1 行サフィックス。
    public var logSuffix: String {
        switch outcome {
        case .shown:
            let initText = initialText ?? "?"
            let hist = historyEntries.first?.output ?? "-"
            let azoo = azooKeyCandidates.first ?? "-"
            let pref = hiraganaPreferred || hiraganaBuiltin ? 1 : 0
            return " init:[0]\(initText) hist1:\(hist) azoo1:\(azoo) hirPref:\(pref)"
        case .dismissedEmpty:
            return " init:dismiss(empty)"
        case .dismissedFunctionalWord:
            let word = initialText ?? "?"
            return " init:dismiss(func:\(word))"
        }
    }

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "trigger": trigger,
            "reading": reading,
            "outcome": outcome.rawValue,
            "hiraganaPreferred": hiraganaPreferred,
            "hiraganaBuiltin": hiraganaBuiltin,
            "historyEntries": historyEntries.map { entry -> [String: Any] in
                var d: [String: Any] = ["output": entry.output]
                if let e = entry.exactScore { d["exact"] = e }
                if let p = entry.prefixScore { d["prefix"] = p }
                return d
            },
            "userDictExact": userDictExact,
            "azooKeyCandidates": azooKeyCandidates,
            "azooKeyApiOrder": azooKeyApiOrder,
            "initialRow": 0,
            "fixedEnd": fixedEnd,
            "scoredSources": scoredSources,
            "deferAzooKeyWhileTyping": deferAzooKeyWhileTyping,
            "logSuffix": logSuffix,
        ]
        if let initialText { dict["initialText"] = initialText }
        return dict
    }
}

enum CandidateBuildDiagnosticsSupport {
    static func scoredSourceLabel(_ candidate: ScoredCandidate) -> String {
        let source: String
        switch candidate.source {
        case .historyExact: source = "historyExact"
        case .historyPrefix: source = "historyPrefix"
        case .userDict(let exact): source = exact ? "userDictExact" : "userDictPrefix"
        case .azooKey(let rank): source = "azooKey(\(rank))"
        case .hiraganaPreferred: source = "hiraganaPreferred"
        case .hiraganaBuiltin: source = "hiraganaBuiltin"
        case .number: source = "number"
        case .dateTime: source = "dateTime"
        }
        return "\(source):\(candidate.text)(\(String(format: "%.2f", candidate.score)))"
    }

    static func triggerLabel(_ trigger: CandidateListTrigger) -> String {
        switch trigger {
        case .whileTyping: return "whileTyping"
        case .explicit: return "explicit"
        }
    }
}

#endif

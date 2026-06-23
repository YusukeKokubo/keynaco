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

    public var fixedSlot: String
    public var hiraganaPreferred: Bool
    public var hiraganaBuiltin: Bool
    public var exactMatchHighHistory: [String]
    public var highHistory: [String]
    public var userDictExact: [String]
    public var azooKeyCandidates: [String]
    public var azooKeyApiOrder: [String]

    public var initialRowPolicy: String
    public var initialRow: Int
    public var initialText: String?
    public var fixedEnd: Int
    public var historyEnd: Int
    /// `"fixedHiragana:の"` 形式のセクション要約。
    public var sections: [String]

    public var deferAzooKeyWhileTyping: Bool

    /// イベントログ用の 1 行サフィックス。
    public var logSuffix: String {
        switch outcome {
        case .shown:
            let initText = initialText ?? "?"
            let policy = initialRowPolicy
            let hist = exactMatchHighHistory.first ?? "-"
            let azoo = azooKeyCandidates.first ?? "-"
            let fixed = fixedSlot
            let pref = hiraganaPreferred || hiraganaBuiltin ? 1 : 0
            return " init:[\(initialRow)]\(initText) policy:\(policy) fixed:\(fixed) hist1:\(hist) azoo1:\(azoo) hirPref:\(pref)"
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
            "fixedSlot": fixedSlot,
            "hiraganaPreferred": hiraganaPreferred,
            "hiraganaBuiltin": hiraganaBuiltin,
            "exactMatchHighHistory": exactMatchHighHistory,
            "highHistory": highHistory,
            "userDictExact": userDictExact,
            "azooKeyCandidates": azooKeyCandidates,
            "azooKeyApiOrder": azooKeyApiOrder,
            "initialRowPolicy": initialRowPolicy,
            "initialRow": initialRow,
            "fixedEnd": fixedEnd,
            "historyEnd": historyEnd,
            "sections": sections,
            "deferAzooKeyWhileTyping": deferAzooKeyWhileTyping,
            "logSuffix": logSuffix,
        ]
        if let initialText { dict["initialText"] = initialText }
        return dict
    }
}

enum CandidateBuildDiagnosticsSupport {
    static func fixedSlotLabel(_ slot: CandidateFixedSlot) -> String {
        switch slot {
        case .none: return "none"
        case .hiragana: return "hiragana"
        }
    }

    static func policyLabel(_ policy: InitialRowPolicy) -> String {
        switch policy {
        case .firstMatching(let s): return "firstMatching(\(s))"
        case .afterFixed: return "afterFixed"
        }
    }

    static func sectionLabels(_ sections: [CandidateSection]) -> [String] {
        sections.map { section in
            let items = section.items.joined(separator: ",")
            return "\(sectionKindLabel(section.kind)):\(items)"
        }
    }

    static func sectionKindLabel(_ kind: CandidateSection.Kind) -> String {
        switch kind {
        case .fixedHiragana: return "fixedHiragana"
        case .userDict: return "userDict"
        case .exactMatchHistory: return "exactMatchHistory"
        case .promotedPrefixHistory: return "promotedPrefixHistory"
        case .highHistory: return "highHistory"
        case .number: return "number"
        case .dateTime: return "dateTime"
        case .azooKeyDict: return "azooKeyDict"
        }
    }

    static func triggerLabel(_ trigger: CandidateListTrigger) -> String {
        switch trigger {
        case .whileTyping: return "whileTyping"
        case .explicit: return "explicit"
        }
    }
}

#endif

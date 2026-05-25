import Foundation

// MARK: - POSLabelV2（@Generable なし、Core で管理）

/// アプリ内部で使う品詞 enum。@Generable は付けない。
public enum POSLabelV2: String, Sendable {
    case noun
    case properNounPlace
    case properNounPerson
    case properNounOrg
    case properNounProduct
    case properNounWork
    case verb
    case adjective
    case particle              // 純助詞・助詞付きフレーズ（「課題を」等）
    case otherConjunction      // 接続詞（しかし、ただし等）
    case otherInterjection     // 感動詞（ええっと等）
    case other

    /// DB の pos カラムに保存する文字列に変換する
    public var posString: String {
        switch self {
        case .noun:               return "noun"
        case .properNounPlace:    return "proper_noun/place"
        case .properNounPerson:   return "proper_noun/person"
        case .properNounOrg:      return "proper_noun/org"
        case .properNounProduct:  return "proper_noun/product"
        case .properNounWork:     return "proper_noun/work"
        case .verb:               return "verb"
        case .adjective:          return "adjective"
        case .particle:           return "other"
        case .otherConjunction:   return "other/conjunction"
        case .otherInterjection:  return "other/interjection"
        case .other:              return "other"
        }
    }

    /// 候補表示フィルタ（blocklist 方式）: 非表示にするべき品詞か
    public var shouldHideFromCandidates: Bool {
        switch self {
        case .particle, .otherConjunction, .otherInterjection:
            return true
        default:
            return false
        }
    }
}

// MARK: - POC 用データ型

public struct POCValidationCase: Sendable {
    public let output: String
    public let expectedPos: POSLabelV2
    public init(_ output: String, _ expected: POSLabelV2) {
        self.output = output
        self.expectedPos = expected
    }

    public static let validationSet: [POCValidationCase] = [
        // DB で other に誤分類されている業務名詞
        .init("設定",     .noun),
        .init("申請",     .noun),
        .init("担当者",   .noun),
        .init("チーム",   .noun),
        .init("データ",   .noun),
        .init("取引先",   .noun),
        .init("追加",     .noun),
        .init("変更",     .noun),
        .init("情報",     .noun),
        .init("実装",     .noun),
        .init("管理",     .noun),
        // 助詞付きフレーズ・接続詞
        .init("価値が",   .particle),
        .init("課題を",   .particle),
        .init("しかし",   .otherConjunction),
        // 動詞
        .init("確認して", .verb),
        .init("教えて",   .verb),
    ]
}

public struct POCValidationResult: Sendable {
    public let output: String
    public let expected: POSLabelV2
    public let actual: POSLabelV2?
    public let confidence: String
    public let pass: Bool
    public let elapsedSeconds: Double
    public let errorMessage: String?

    public init(output: String, expected: POSLabelV2, actual: POSLabelV2?, confidence: String, pass: Bool, elapsedSeconds: Double, errorMessage: String?) {
        self.output = output; self.expected = expected; self.actual = actual
        self.confidence = confidence; self.pass = pass; self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
    }
}

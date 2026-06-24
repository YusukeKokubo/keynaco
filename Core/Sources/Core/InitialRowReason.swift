import Foundation

/// row 0（スコア降順先頭）を選んだ理由。`divergence_log.jsonl` の
/// `initial_row_reason` フィールドに `rawValue` が書き出される（wire format は String）。
///
/// 実コードが emit する集合はこの enum に閉じる。新しい理由を増やすときは
/// ここに case 追加し、log 解析側にも反映する。
public enum InitialRowReason: String, Sendable, Equatable {
    /// row 0 がユーザー設定のひらがな優先 bonus 由来。
    case hiraganaPreferred
    /// row 0 が組み込み助詞等の bonus 由来（concept 指針 1 の機能語抑制で post-build dismiss されるケースも含む）。
    case hiraganaBuiltin
    /// row 0 は単純なスコア降順の先頭（履歴・ユーザー辞書・AzooKey・特殊変換のどれか）。
    /// `assembleCandidateList` 未実行時の sentinel も含む。
    case scoreOrder
}

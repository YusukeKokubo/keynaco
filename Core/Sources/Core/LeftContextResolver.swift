import Foundation

/// Zenzai / AzooKey 用の左文脈プレフィックスを組み立てる（結合のみ）。
///
/// パイプライン俯瞰・IMK キャッシュ更新タイミングは `LeftContextSource` ファイル先頭 MARK が正本。
/// 入力組み立ては `LeftContextSource`、本メソッドは 300/400 字結合のみ担当。
///
/// 結合ルール（PLAN260506b）:
/// - `before` 単体は最大 `maxBeforeLength` 字（カーソル近傍の末尾側）
/// - `sessionBuffer` が非空のときは先頭に全量を残し、結合総長が `maxCombinedLength` を超えないよう
///   `before` 側のみ切り詰める（`sessionBuffer` は切らない）
public enum LeftContextResolver {

    /// IMK `before` 単体の上限（従来の左文脈キャップ）
    static let maxBeforeLength = 300
    /// `sessionBuffer + before` 結合後の上限
    static let maxCombinedLength = 400

    public static func combine(
        sessionBuffer: String,
        imkBefore: String?,
        cursorLocationAvailable: Bool
    ) -> String {
        guard cursorLocationAvailable else { return sessionBuffer }

        guard let rawBefore = imkBefore, !rawBefore.isEmpty else {
            return sessionBuffer
        }

        let beforeTruncated =
            rawBefore.count > maxBeforeLength
            ? String(rawBefore.suffix(maxBeforeLength))
            : rawBefore

        guard !sessionBuffer.isEmpty else { return beforeTruncated }

        let maxBefore = max(0, maxCombinedLength - sessionBuffer.count)
        let trimmedBefore =
            beforeTruncated.count > maxBefore
            ? String(beforeTruncated.suffix(maxBefore))
            : beforeTruncated
        return sessionBuffer + trimmedBefore
    }
}

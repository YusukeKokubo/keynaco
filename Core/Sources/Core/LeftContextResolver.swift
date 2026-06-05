import Foundation

/// Zenzai / AzooKey 用の左文脈プレフィックスを組み立てる。
///
/// `sessionTextBuffer`（keynaco 確定語バッファ）と IMK `before`（キャッシュ済み・location 一致時のみ）
/// を結合する。IMK 取得・キャッシュ更新は `InputController` 側の責務。
/// サンドボックス（`DebugSocketServer.debugLeftContextPrefix`）は `mockClient.documentBefore` を `imkBefore` に載せる。
///
/// 結合ルール（PLAN260506b）:
/// - `before` 単体は最大 `maxBeforeLength` 字（カーソル近傍の末尾側）
/// - `sessionBuffer` が非空のときは先頭に全量を残し、結合総長が `maxCombinedLength` を超えないよう
///   `before` 側のみ切り詰める（`sessionBuffer` は切らない）
public enum LeftContextResolver {

    /// IMK `before` 単体の上限（従来の左文脈キャップ）
    public static let maxBeforeLength = 300
    /// `sessionBuffer + before` 結合後の上限
    public static let maxCombinedLength = 400

    public struct Input: Equatable, Sendable {
        /// 確定語セッションバッファ（`InputHandler.sessionTextBuffer`）
        public var sessionBuffer: String
        /// location 一致かつ非空の IMK `before`。それ以外は `nil`
        public var imkBefore: String?
        /// `selectedRange().location != NSNotFound`
        public var cursorLocationAvailable: Bool

        public init(
            sessionBuffer: String,
            imkBefore: String?,
            cursorLocationAvailable: Bool
        ) {
            self.sessionBuffer = sessionBuffer
            self.imkBefore = imkBefore
            self.cursorLocationAvailable = cursorLocationAvailable
        }
    }

    public static func resolve(_ input: Input) -> String {
        let sessionBuffer = input.sessionBuffer
        guard input.cursorLocationAvailable else { return sessionBuffer }

        guard let rawBefore = input.imkBefore, !rawBefore.isEmpty else {
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

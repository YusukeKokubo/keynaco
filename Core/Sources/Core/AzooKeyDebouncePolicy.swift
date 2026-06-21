import Foundation

/// `.whileTyping` の AzooKey 非同期取得 debounce 間隔の入力。
public struct AzooKeyDebounceInput: Equatable, Sendable {
    /// 直前キーからの経過 ms。組成先頭キーなど比較対象がなければ `nil`。
    public let interKeyIntervalMs: Double?
    /// ローマ字子音待ち（`n` / `sh` 等）中なら `true` — まだ読みが伸びる見込みが高い。
    public let hasPendingRomaji: Bool
    /// 現在の確定済みかな読み長。短い（≤2）うちは追加打鍵がほぼ確実に来るため、wasted fetch を防ぐ目的で debounce を伸ばす。
    public let readingLength: Int

    public init(interKeyIntervalMs: Double?, hasPendingRomaji: Bool, readingLength: Int) {
        self.interKeyIntervalMs = interKeyIntervalMs
        self.hasPendingRomaji = hasPendingRomaji
        self.readingLength = readingLength
    }
}

/// 打鍵速度・読み完成度に応じて debounce を 40–120ms の範囲で調整する。
///
/// 通常バケット（80–160ms）の値は実測 `inter_key_p50 ≈ 117ms` ・ `fetch_p50 ≈ 84ms` を踏まえ
/// 「fetch コストを下回らない」「打鍵間隔を超えない」両条件を満たす 90ms に設定。
/// 70ms だと `LockedConverter` で直列化された fetch がキュー詰まりして `fetch_complete_p95` を悪化させとった。
/// 読み長 ≤2 の打鍵中（pause 未検知）は max=120ms にして wasted fetch を構造的に削る
/// （ログ実測: 2 文字読みミス率 90% / wasted fetch 35% の主要因。pause 検知時は通常通り 45ms で即発火）。
public enum AzooKeyDebouncePolicy {
    public static let minNanoseconds: UInt64 = 40_000_000
    public static let maxNanoseconds: UInt64 = 120_000_000
    public static let defaultNanoseconds: UInt64 = 70_000_000

    public static func nanoseconds(for input: AzooKeyDebounceInput) -> UInt64 {
        var ms: Double = 70
        let isPaused = (input.interKeyIntervalMs ?? 0) >= 160

        if input.hasPendingRomaji {
            ms = 105
        } else if let interval = input.interKeyIntervalMs {
            if interval < 80 {
                ms = 110
            } else if interval < 160 {
                ms = 90
            } else {
                ms = 45
            }
        }

        if input.readingLength > 0 && input.readingLength <= 2 && !isPaused {
            ms = max(ms, 120)
        }

        let clamped = min(max(ms, 40), 120)
        return UInt64(clamped * 1_000_000)
    }
}

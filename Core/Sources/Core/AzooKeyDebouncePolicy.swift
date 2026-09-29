import Foundation

/// `.whileTyping` の AzooKey 非同期取得 debounce 間隔の入力。
public struct AzooKeyDebounceInput: Equatable, Sendable {
    /// 直前キーからの経過 ms。組成先頭キーなど比較対象がなければ `nil`。
    public let interKeyIntervalMs: Double?
    /// ローマ字子音待ち（`n` / `sh` 等）中なら `true` — まだ読みが伸びる見込みが高い。
    public let hasPendingRomaji: Bool
    /// 現在の確定済みかな読み長。短い（≤2）うちは追加打鍵がほぼ確実に来るため、wasted fetch を防ぐ目的で debounce を伸ばす（下限 90ms）。
    public let readingLength: Int

    public init(interKeyIntervalMs: Double?, hasPendingRomaji: Bool, readingLength: Int) {
        self.interKeyIntervalMs = interKeyIntervalMs
        self.hasPendingRomaji = hasPendingRomaji
        self.readingLength = readingLength
    }
}

/// 打鍵速度・読み完成度に応じて debounce を 40–120ms の範囲で調整する。
///
/// 読みが変わらんキー（子音キー等）では予約中の fetch を捨てない（`WhileTypingFetchRetention`、PLAN260929a）。
/// 次に読みが変わるのは通常 2 打鍵先なので、debounce は 1 打鍵間隔（実測 `inter_key_p50 ≈ 128ms`）を
/// 守る必要がなく、fetch_complete の半分を占めとった待ちを詰めてある（通常 60ms / 高速打鍵 80ms）。
/// 70ms 以下で `LockedConverter` のキュー詰まりが出た過去（子音キーで毎回 fetch を捨てとった頃）があるので、
/// `lock_wait p95` をガード指標として見ること。
/// 読み長 ≤2 の打鍵中（pause 未検知）は 90ms を下限にして wasted fetch を抑える（PLAN260621。pause 検知時は 45ms で即発火）。
public enum AzooKeyDebouncePolicy {
    public static let minNanoseconds: UInt64 = 40_000_000
    public static let maxNanoseconds: UInt64 = 120_000_000
    public static let defaultNanoseconds: UInt64 = 70_000_000

    /// 実験用の debounce 固定上書き（ms）。未設定 / 0 以下なら通常ポリシー。
    ///
    /// 狙いは「debounce を詰めるとロック待ちが復活するか」の因果確認。実測では最新ビルドの
    /// `lock_wait p95 = 0ms` だが、これは debounce 90–120ms で発火を絞った結果である可能性があり、
    /// 「直列化が debounce 短縮の壁」という仮説を 1 定数で直接確かめるために置く（PLAN260719 H2 の前提）。
    ///
    /// **プロセス起動時に一度だけ読む**。実験はセッション単位で分離したいので、途中で切り替わらん方が
    /// `latency_log.jsonl` の `debounce_policy_p50_ms` とセッション行の対応が取れる。
    ///
    /// 使い方: `defaults write com.yusuke.inputmethod.keynaco debugDebounceOverrideMs -int 70` → keynaco 再起動。
    /// 戻すときは `defaults delete`（or `-int 0`）→ 再起動。
    public static let overrideMs: Double? = {
        let value = UserDefaults.standard.double(forKey: "debugDebounceOverrideMs")
        return value > 0 ? min(value, 500) : nil
    }()

    public static func nanoseconds(for input: AzooKeyDebounceInput) -> UInt64 {
        var ms: Double = 70
        let isPaused = (input.interKeyIntervalMs ?? 0) >= 160

        if input.hasPendingRomaji {
            ms = 80
        } else if let interval = input.interKeyIntervalMs {
            if interval < 80 {
                ms = 80
            } else if interval < 160 {
                ms = 60
            } else {
                ms = 45
            }
        }

        if input.readingLength > 0 && input.readingLength <= 2 && !isPaused {
            ms = max(ms, 90)
        }

        let clamped = min(max(ms, 40), 120)
        return UInt64(clamped * 1_000_000)
    }

    /// 本番 / sandbox 共通の debounce 入力組み立て。`overrideMs` が立っとればそれを優先する。
    public static func nanoseconds(
        interKeyIntervalMs: Double?,
        pendingRomaji: String,
        reading: String
    ) -> UInt64 {
        resolveNanoseconds(
            overrideMs: overrideMs,
            input: AzooKeyDebounceInput(
                interKeyIntervalMs: interKeyIntervalMs,
                hasPendingRomaji: !pendingRomaji.isEmpty,
                readingLength: reading.count
            )
        )
    }

    /// `overrideMs` の適用を純粋関数として切り出したもの（`overrideMs` は起動時固定でテストから差せんため）。
    /// 上書き値は clamp を通さない——実験で 40ms 未満も試せるようにするのが目的。
    public static func resolveNanoseconds(overrideMs: Double?, input: AzooKeyDebounceInput) -> UInt64 {
        if let overrideMs, overrideMs > 0 {
            return UInt64(overrideMs * 1_000_000)
        }
        return nanoseconds(for: input)
    }
}

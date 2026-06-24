import Foundation

/// ログ JSONL の `version` フィールド用。`CFBundleShortVersionString+build` で改修前後比較に使う。
enum AppVersion {
    static var logLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }
}

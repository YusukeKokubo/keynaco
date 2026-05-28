import AppKit
import Foundation
import FoundationModels
import KeynacoCore

enum DiaryGeneratorError: LocalizedError {
    case unavailable
    case noEntries

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Intelligence が利用できません。設定で有効にしてください。"
        case .noEntries: return "この日の入力ログがありません。"
        }
    }
}

@MainActor
final class DiaryGenerator {
    static func generate(for date: String, from entries: [DatabaseManager.DailyLogEntry]) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw DiaryGeneratorError.unavailable
        }
        guard !entries.isEmpty else {
            throw DiaryGeneratorError.noEntries
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let lines = entries.map { entry -> String in
            let time = formattedTime(epoch: entry.createdAt)
            let appName = entry.appBundleID.flatMap { appDisplayName(bundleID: $0) } ?? entry.appBundleID ?? "不明"
            return "\(time) [\(appName)] \(entry.text)"
        }
        let prompt = """
        以下は \(date) に入力した日本語テキストの一覧です（時刻とアプリ名付き）。
        これを素材にして、その日の出来事・作業内容を自然な日本語の日記としてまとめてください。

        \(lines.joined(separator: "\n"))
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    private static func formattedTime(epoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: date)
    }

    private static func appDisplayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}

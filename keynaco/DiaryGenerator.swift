import Foundation
import FoundationModels

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
    static func generate(for date: String, from entries: [String]) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw DiaryGeneratorError.unavailable
        }
        guard !entries.isEmpty else {
            throw DiaryGeneratorError.noEntries
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let prompt = """
        以下は \(date) に入力した日本語テキストの一覧です。
        これを素材にして、その日の出来事・作業内容を自然な日本語の日記としてまとめてください。

        \(entries.joined(separator: "\n"))
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }
}

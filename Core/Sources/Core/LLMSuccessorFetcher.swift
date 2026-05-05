import Foundation
import FoundationModels

/// Successor モード用：確定直後の文脈に続く語をオンデバイス LLM で補完する（表層形）。
@MainActor
public final class LLMSuccessorFetcher {
    private var task: Task<Void, Never>?
    private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) {
        """
        あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。
        """
    }

    public init() {}

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// `words` は確定語の直近順（末尾が最新）、最大3語。`documentContextPrefix` は IMK 前文または `committedHistory` フォールバック。`examples` は few-shot。失敗時は空配列。
    public func fetch(
        context words: [String],
        documentContextPrefix: String,
        examples: [(prev: String, next: String)],
        onResult: @escaping ([String]) -> Void
    ) {
        guard !words.isEmpty else {
            onResult([])
            return
        }
        guard case .available = SystemLanguageModel.default.availability else {
            onResult([])
            return
        }
        cancel()
        let prompt = Self.buildPrompt(
            words: words, documentContextPrefix: documentContextPrefix, examples: examples)
        task = Task { @MainActor [session] in
            do {
                let response = try await session.respond(to: prompt)
                let lines = Self.parseLines(from: response)
                onResult(lines)
            } catch {
                onResult([])
            }
        }
    }

    nonisolated internal static func buildPrompt(
        words: [String],
        documentContextPrefix: String,
        examples: [(prev: String, next: String)]
    ) -> String {
        let contextPhrase = words.joined(separator: "、")
        let docBlock: String
        if documentContextPrefix.isEmpty {
            docBlock = ""
        } else {
            docBlock = "【文脈】\(documentContextPrefix)\n\n"
        }
        guard !examples.isEmpty, let prevHead = examples.first?.prev else {
            return """
            \(docBlock)「\(contextPhrase)」に続く語を5つ挙げてください。
            1語ずつ改行で出力してください。助詞は含めないでください。
            """
        }
        let nextList = examples.map(\.next).joined(separator: "、")
        return """
        \(docBlock)【このユーザーが「\(prevHead)」の後によく使う語】
        \(nextList)

        「\(contextPhrase)」に続く語を5つ挙げてください。
        1語ずつ改行で出力してください。助詞は含めないでください。
        """
    }

    /// `LanguageModelSession.Response` から本文を取り出す。
    private static func parseLines<Content>(from response: LanguageModelSession.Response<Content>) -> [String] {
        let text: String
        if let s = response.content as? String {
            text = s
        } else {
            text = ""
        }
        return splitAndFilterLines(text)
    }

    /// 行分割・重複除去・日本語語素を含む行のみ・数字のみ行除外・最大5件。
    nonisolated static func splitAndFilterLines(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            guard hasJapaneseWordScalar(t) else { continue }
            guard !isDigitsOnly(t) else { continue }
            guard seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count >= 5 { break }
        }
        return out
    }

    nonisolated private static func hasJapaneseWordScalar(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            let v = u.value
            let hiragana = (v >= 0x3041 && v <= 0x3096) || v == 0x309D || v == 0x309E
            // 全角カタカナ（中黒「・」のみの行は記号扱いで除外）
            let katakana = (v >= 0x30A1 && v <= 0x30FF) && v != 0x30FB
            let cjk = (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0xF900 && v <= 0xFAFF)
            return hiragana || katakana || cjk
        }
    }

    nonisolated private static func isDigitsOnly(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            let v = u.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0xFF10 && v <= 0xFF19)
        }
    }
}

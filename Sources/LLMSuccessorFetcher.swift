import Foundation
import FoundationModels

/// Successor モード用：確定直後の語に続くひらがな候補をオンデバイス LLM で補完する。
@MainActor
final class LLMSuccessorFetcher {
    private var task: Task<Void, Never>?
    private lazy var session: LanguageModelSession = LanguageModelSession(model: SystemLanguageModel.default) {
        """
        あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。
        """
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `after` に続く語をひらがなで最大5語返す（失敗時は空配列）。
    func fetch(after word: String, onResult: @escaping ([String]) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else {
            onResult([])
            return
        }
        cancel()
        let prompt = Self.buildPrompt(word: word)
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

    private static func buildPrompt(word: String) -> String {
        """
        「\(word)」の直後に来る日本語の語（名詞・動詞・形容詞）を5つ挙げてください。
        1語ずつ改行で出力してください。助詞は含めないでください。
        各語はひらがなだけで書いてください（漢字・カタカナは使わないでください）。
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
        return splitAndFilterHiraganaLines(text)
    }

    /// 行分割・重複除去・ひらがなのみ・最大5件。
    static func splitAndFilterHiraganaLines(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.unicodeScalars.allSatisfy(Self.isHiraganaScalar), seen.insert(String(t)).inserted else { continue }
            out.append(String(t))
            if out.count >= 5 { break }
        }
        return out
    }

    private static func isHiraganaScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x3041 && v <= 0x3096) || v == 0x309D || v == 0x309E
    }
}

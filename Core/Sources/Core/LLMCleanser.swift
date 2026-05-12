import Foundation
import FoundationModels

// MARK: - Public types

public enum CleanserError: Error, Sendable, Equatable {
    case unavailable
}

public enum EntrySource: Sendable {
    case history(input: String, output: String)
    case bigram(prev: String, input: String, output: String)
}

public enum Verdict: String, Sendable {
    case suspect
    case delete
}

public struct FlaggedEntry: Sendable {
    public let source: EntrySource
    public let display: String
    public let verdict: Verdict
    public let reason: String

    public init(source: EntrySource, display: String, verdict: Verdict, reason: String) {
        self.source = source
        self.display = display
        self.verdict = verdict
        self.reason = reason
    }
}

// MARK: - @Generable batch schema (private)

@Generable
private enum VerdictValue: String, Sendable {
    case keep
    case suspect
    case delete
}

@Generable
private struct ItemResult {
    @Guide(description: "エントリの通し番号（0始まり、プロンプトの id と一致）")
    var id: Int
    @Guide(description: "keep / suspect / delete のいずれか")
    var verdict: VerdictValue
    @Guide(description: "40文字以内の判定理由（日本語）")
    var reason: String
}

@Generable
private struct BatchResult {
    @Guide(description: "各エントリの判定結果")
    var items: [ItemResult]
}

// MARK: - Prompt JSON

private struct PromptLine: Encodable {
    let id: Int
    let type: String
    let prev: String?
    let input: String
    let output: String
}

private struct WorkRow: Sendable {
    let id: Int
    let source: EntrySource
    let display: String
}

/// `history` / `bigram` をオンデバイス LLM で評価し、怪しいエントリを列挙する。
public actor LLMCleanser {

    public init() {}

    nonisolated public static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// history / bigram を評価して suspect/delete エントリを返す。
    /// `onProgress(completed:total:)` は Main Actor から呼ばれる。
    public func evaluate(
        db: DatabaseManager,
        onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [FlaggedEntry] {
        guard Self.isModelAvailable else { throw CleanserError.unavailable }

        let history = db.fetchAllHistory()
        let bigrams = db.fetchAllBigramExcludingPresets()
        var rows: [WorkRow] = []
        var nextId = 0
        for h in history {
            rows.append(
                WorkRow(
                    id: nextId,
                    source: .history(input: h.input, output: h.output),
                    display: "\(h.input) → \(h.output)"
                ))
            nextId += 1
        }
        for b in bigrams {
            rows.append(
                WorkRow(
                    id: nextId,
                    source: .bigram(prev: b.prev, input: b.input, output: b.output),
                    display: "\(b.prev) | \(b.input) → \(b.output)"
                ))
            nextId += 1
        }

        let total = rows.count
        if total == 0 {
            await onProgress(0, 0)
            return []
        }
        await onProgress(0, total)

        let batchSize = 30
        var flagged: [FlaggedEntry] = []
        var batchStart = 0
        while batchStart < rows.count {
            try Task.checkCancellation()
            let end = min(batchStart + batchSize, rows.count)
            let slice = Array(rows[batchStart..<end])
            let batchFlagged = try await Self.runBatch(rows: slice)
            flagged.append(contentsOf: batchFlagged)
            await onProgress(end, total)
            batchStart = end
        }
        return flagged
    }

    private nonisolated static func runBatch(rows: [WorkRow]) async throws -> [FlaggedEntry] {
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let lines: [PromptLine] = rows.map { row in
            switch row.source {
            case let .history(input, output):
                PromptLine(id: row.id, type: "history", prev: nil, input: input, output: output)
            case let .bigram(prev, input, output):
                PromptLine(id: row.id, type: "bigram", prev: prev, input: input, output: output)
            }
        }
        let jsonData = try JSONEncoder().encode(lines)
        let json = String(data: jsonData, encoding: .utf8) ?? "[]"

        let prompt = """
        あなたは日本語IMEの学習データ品質チェッカーです。
        以下のエントリを評価し、verdict を返してください。

        - keep   : 自然な日本語変換
        - suspect: やや不自然（ユーザー確認推奨）
        - delete : 明らかな誤変換・ノイズ（読みと変換が意味的に無関係、記号列など）

        history エントリ: 読み → 確定テキスト のペア
        bigram エントリ : 直前の語 | 読み → 確定テキスト の組

        ---
        \(json)
        """

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            "あなたは日本語入力メソッドの補助モジュールです。指示された形式だけを出力し、説明文は書かないでください。"
        }
        let response = try await session.respond(
            to: prompt,
            generating: BatchResult.self,
            includeSchemaInPrompt: true
        )
        let batch = response.content
        var out: [FlaggedEntry] = []
        for item in batch.items {
            guard let row = byId[item.id] else { continue }
            let verdict: Verdict
            switch item.verdict {
            case .keep:
                continue
            case .suspect:
                verdict = .suspect
            case .delete:
                verdict = .delete
            }
            let reason = Self.trimReason(item.reason)
            out.append(FlaggedEntry(source: row.source, display: row.display, verdict: verdict, reason: reason))
        }
        return out
    }

    private nonisolated static func trimReason(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 40 { return t }
        return String(t.prefix(40))
    }
}

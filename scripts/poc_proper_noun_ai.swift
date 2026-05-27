#!/usr/bin/env swift
// POC: Apple Intelligence による固有名詞検出
// 実際の history.db データで「user_dict に追加すべき固有名詞か」を判定する
//
// 実行: swift scripts/poc_proper_noun_ai.swift

import Foundation
import FoundationModels

struct Case {
    let reading: String
    let output: String
    let currentPos: String?   // 現行 AzooKeyPOSClassifier の結果
    let expectUserDict: Bool? // 期待値（nil = 不明）
}

// 実際の history.db から抽出したテストケース
// expectUserDict: true = user_dict に追加すべき固有名詞、false = 不要
let cases: [Case] = [
    // 現行分類が誤っていると思われるケース
    Case(reading: "にゅう",      output: "入力",       currentPos: "proper_noun",         expectUserDict: false),
    Case(reading: "こきゃく",    output: "顧客",       currentPos: "proper_noun/person",  expectUserDict: false),
    Case(reading: "さんかしゃ",  output: "参加者",     currentPos: "proper_noun",         expectUserDict: false),
    Case(reading: "しごと",      output: "仕事",       currentPos: "proper_noun/work",    expectUserDict: false),
    Case(reading: "ぷろぱてぃ",  output: "プロパティ", currentPos: "proper_noun",         expectUserDict: false),
    // 正しく分類されていると思われるケース
    Case(reading: "まつだ",      output: "マツダ",     currentPos: "proper_noun/org",     expectUserDict: true),
    Case(reading: "su",          output: "SUBARU",     currentPos: "other",               expectUserDict: true),
    Case(reading: "ai",          output: "AI",         currentPos: "proper_noun/org",     expectUserDict: nil),
    Case(reading: "ipo",         output: "IPO",        currentPos: "proper_noun",         expectUserDict: nil),
    Case(reading: "cs",          output: "CS",         currentPos: "proper_noun",         expectUserDict: nil),
    Case(reading: "pr",          output: "PR",         currentPos: "verb",                expectUserDict: nil),
    // 判断が難しいケース
    Case(reading: "ねこたん",    output: "ネコたん",   currentPos: nil,                   expectUserDict: nil),
    Case(reading: "こねくと",    output: "コネクト",   currentPos: "other",               expectUserDict: nil),
    Case(reading: "どきゅめんと", output: "ドキュメント", currentPos: "proper_noun/product", expectUserDict: false),
    Case(reading: "ちーむ",      output: "チーム",     currentPos: "other",               expectUserDict: false),
]

let systemPrompt = """
You help classify Japanese IME conversion history entries for a user dictionary.

The user dictionary (user_dict) permanently stores entries with top priority. \
It's for proper nouns specific to the user's context: people's names, company names, \
product names, and place names that may not appear in standard Japanese dictionaries.

For each (reading → surface_form) pair, answer with exactly one of:
  YES   - proper noun that belongs in user_dict
  NO    - common word, technical term, or abbreviation that doesn't need user_dict
  MAYBE - ambiguous (e.g. abbreviations like AI, PR that could go either way)

Then add a single short reason (10 words max).

Format: YES|NO|MAYBE <reason>

Do NOT add any other text.
"""

func classify(reading: String, output: String) async -> String {
    guard case .available = SystemLanguageModel.default.availability else {
        return "UNAVAILABLE"
    }
    let session = LanguageModelSession(model: SystemLanguageModel.default) {
        systemPrompt
    }
    let prompt = "reading: \(reading) → surface: \(output)"
    do {
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return "ERROR: \(error)"
    }
}

func verdict(_ result: String) -> String {
    let upper = result.uppercased()
    if upper.hasPrefix("YES")   { return "✅ YES  " }
    if upper.hasPrefix("NO")    { return "❌ NO   " }
    if upper.hasPrefix("MAYBE") { return "🤔 MAYBE" }
    return "❓ \(result.prefix(6))"
}

func expected(_ v: Bool?) -> String {
    guard let v else { return "    ?" }
    return v ? "  YES" : "   NO"
}

// メイン処理: RunLoop スピンで main スレッドを解放したまま async Task を実行
var finished = false
Task {
    print("Apple Intelligence 固有名詞検出 POC")
    print("─────────────────────────────────────────────────────────────────")
    print("reading        surface        currentPos             expect    AI判定 + 理由")
    print("─────────────────────────────────────────────────────────────────")

    for c in cases {
        let result = await classify(reading: c.reading, output: c.output)
        let posStr = (c.currentPos ?? "(null)").padding(toLength: 22, withPad: " ", startingAt: 0)
        let readingPad = c.reading.padding(toLength: 14, withPad: " ", startingAt: 0)
        let outputPad  = c.output.padding(toLength: 14, withPad: " ", startingAt: 0)
        let expectPad  = expected(c.expectUserDict).padding(toLength: 8, withPad: " ", startingAt: 0)
        print("\(readingPad) \(outputPad) \(posStr) \(expectPad)  \(verdict(result))  [\(result)]")
        try? await Task.sleep(for: .milliseconds(200))
    }

    print("─────────────────────────────────────────────────────────────────")
    finished = true
}

while !finished {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

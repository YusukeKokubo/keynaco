import AppKit

public extension InputHandler {

    // MARK: - z + キー 特殊文字マップ

    static let zCharMap: [String: String] = [
        "-": "〜", "/": "・", ".": "…", ",": "、",
    ]
    static let zArrowMap: [UInt16: String] = [
        KeyCode.rightArrow: "→", KeyCode.leftArrow: "←",
    ]

    // MARK: - 括弧候補マップ

    static let bracketOptions: [String: [String]] = [
        "[": ["「", "【", "〔", "［", "〈", "《", "『"],
        "]": ["」", "】", "〕", "］", "〉", "》", "』"],
        "(": ["（", "〔", "｟"],
        ")": ["）", "〕", "｠"],
        "{": ["｛"],
        "}": ["｝"],
        "?": ["？", "?"],
        "!": ["！", "!"],
        "/": ["・", "／", "/"],
        ".": ["。", "．", "…", "‥", "・", "."],
        ",": ["、", "'", "•", ",", "○", ".", "…", "‥", "·"],
        "@": ["＠", "@"],
        "#": ["＃", "#"],
        "$": ["＄", "$"],
        "%": ["％", "%"],
        "^": ["＾", "^"],
        "&": ["＆", "&"],
        "*": ["＊", "*"],
        "<": ["＜", "<"],
        ">": ["＞", ">"],
        "_": ["＿", "_"],
        "+": ["＋", "±", "+"],
        "|": ["｜", "|"],
        ":": ["：", "；", ";", ":"],
        "\"": ["\u{201C}", "\u{201D}", "＂", "\""],
    ]

    // MARK: - 括弧モード

    mutating func handleBracketModeKey(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        candidate: CandidateContext,
        client: TextInputClient
    ) -> (consumed: Bool, candidateAction: CandidateAction) {
        let brackets = bracketCandidates!
        let selectedText = candidate.selectedText ?? brackets[0]

        switch keyCode {
        case KeyCode.escape, KeyCode.backspace:
            bracketCandidates = nil
            return (true, .dismiss)

        case KeyCode.enter:
            bracketCandidates = nil
            client.insertText(selectedText)
            return (true, .dismiss)

        case KeyCode.tab where modifiers.contains(.shift), KeyCode.upArrow:
            return (true, .selectPrev)

        case KeyCode.space, KeyCode.tab, KeyCode.downArrow:
            return (true, .selectNext)

        default:
            // 選択中の括弧を確定して、このキーは通常処理へ
            bracketCandidates = nil
            client.insertText(selectedText)
            return handleNormalInput(keyCode: keyCode, characters: characters, baseCharacters: baseCharacters,
                                      modifiers: modifiers, wasExplicitlySelected: false,
                                      candidate: .hidden, client: client)
        }
    }
}

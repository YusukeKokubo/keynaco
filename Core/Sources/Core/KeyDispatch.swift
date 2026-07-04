import Foundation

/// `KeyDispatch.route` が分岐に使う操作モード（`docs/domain/states.md` の簡略版）。
///
/// 候補サジェスト中（`.passive`）と候補選択中（`.explicit`）はルート上どちらも `.candidatePanel`。
/// 明示選択の有無は `CandidateContext` 側で扱う。
enum KeyDispatchMode: Equatable {
    case bracket
    case ascii
    case candidatePanel
    case composing
    case idle
}

/// `InputHandler.handle()` のキー→処理種別ルーティング入力（副作用なし）。
struct KeyDispatchInput: Equatable {
    let keyCode: UInt16
    let isBackspace: Bool
    let mode: KeyDispatchMode
    let ignoreNextModeSwitch: Bool

    static func make(
        keyCode: UInt16,
        isBackspace: Bool,
        isAsciiMode: Bool,
        isBracketMode: Bool,
        candidateVisible: Bool,
        isComposing: Bool,
        ignoreNextModeSwitch: Bool
    ) -> KeyDispatchInput {
        let mode: KeyDispatchMode
        if isBracketMode {
            mode = .bracket
        } else if isAsciiMode {
            mode = .ascii
        } else if candidateVisible {
            mode = .candidatePanel
        } else if isComposing {
            mode = .composing
        } else {
            mode = .idle
        }
        return KeyDispatchInput(
            keyCode: keyCode,
            isBackspace: isBackspace,
            mode: mode,
            ignoreNextModeSwitch: ignoreNextModeSwitch
        )
    }
}

enum ComposeOnlyKey: Equatable {
    case enter
    case escape
    case backspace
}

/// `InputHandler.handle()` の pure ルーティング結果。評価順序は `route` の分岐順が正本。
enum KeyRoute: Equatable {
    case bracketMode
    case functionKey
    case modeSwitch(suppressEcho: Bool)
    case asciiMode
    case candidateVisible
    case composeOnly(ComposeOnlyKey)
    case normalInput
}

enum KeyDispatch {
    private static let functionKeyCodes: Set<UInt16> = [
        KeyCode.f6, KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10,
    ]

    static func route(_ input: KeyDispatchInput) -> KeyRoute {
        if input.mode == .bracket { return .bracketMode }
        if input.mode != .ascii, functionKeyCodes.contains(input.keyCode) { return .functionKey }
        if input.keyCode == KeyCode.eisu || input.keyCode == KeyCode.kana {
            return .modeSwitch(suppressEcho: input.ignoreNextModeSwitch)
        }
        if input.mode == .ascii { return .asciiMode }
        if input.mode == .candidatePanel { return .candidateVisible }
        switch input.keyCode {
        case KeyCode.enter: return .composeOnly(.enter)
        case KeyCode.escape: return .composeOnly(.escape)
        default:
            if input.isBackspace { return .composeOnly(.backspace) }
            return .normalInput
        }
    }
}

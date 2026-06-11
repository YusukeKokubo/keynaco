import Foundation

/// `InputHandler.handle()` のキー→処理種別ルーティング入力（副作用なし）。
struct KeyDispatchInput: Equatable {
    let keyCode: UInt16
    let isBackspace: Bool
    let isAsciiMode: Bool
    let isBracketMode: Bool
    let candidateVisible: Bool
    let isComposing: Bool
    let ignoreNextModeSwitch: Bool
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
        if input.isBracketMode { return .bracketMode }
        if !input.isAsciiMode, functionKeyCodes.contains(input.keyCode) { return .functionKey }
        if input.keyCode == KeyCode.eisu || input.keyCode == KeyCode.kana {
            return .modeSwitch(suppressEcho: input.ignoreNextModeSwitch)
        }
        if input.isAsciiMode { return .asciiMode }
        if input.candidateVisible { return .candidateVisible }
        switch input.keyCode {
        case KeyCode.enter: return .composeOnly(.enter)
        case KeyCode.escape: return .composeOnly(.escape)
        default:
            if input.isBackspace { return .composeOnly(.backspace) }
            return .normalInput
        }
    }
}

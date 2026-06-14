/// 確定の経路。`InputHandler.commitComposition` に渡して呼び出し側の意図を明示する。
public enum CommitTrigger {
    /// Enter キー確定（組成中・候補選択中共通）
    case enter
    /// → キーでひらがなのまま確定（候補選択中）
    case rightArrow
    /// 英数キーによる強制確定（ASCII モードへの遷移前）
    case modeSwitch
    /// アプリ切替・フォーカス喪失による IMK 強制確定
    case deactivate
}

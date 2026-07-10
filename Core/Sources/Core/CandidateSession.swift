import Foundation

/// 候補パネルの操作フェーズ（`isVisible` × `isExplicitlySelected` の 3 状態）。
///
/// フィールド置換は Phase 5 まで見送り。`fixedEnd` / `candidateSources` 等と常に連動するため。
public enum CandidatePanelInteraction: Equatable, Sendable {
    case hidden
    /// 表示中だがユーザーは ↑↓/Space でまだ動かしていない（打鍵サジェスト・`.whileTyping` 表示）。
    case passive
    /// ユーザーが ↑↓/Space で候補を明示選択中。文字キーは先に選択候補を確定する。
    case explicit
}

/// 候補 UI の単一の正本。`InputHandler` が `CandidateAction` を返し、`InputController` が
/// `apply` 後に `CandidateWindow.apply(_:layout:)` で描画する。
///
/// ## `isVisible` / `isExplicitlySelected` のライフサイクル
///
/// 不変条件: `isExplicitlySelected == true` ⇒ `isVisible == true`。
///
/// | 操作 | `isVisible` | `isExplicitlySelected` |
/// |------|-------------|------------------------|
/// | `apply(.show)`（候補非空） | `true` | `initialIsExplicitlySelected`（`.explicit` トリガのみ `true`） |
/// | `apply(.selectNext)` / `.selectPrev` | 維持 | `true` |
/// | `apply(.dismiss)` / `reset()` | `false` | `false` |
/// | `removeCandidate` / `.deleteSelected` で空 | `false`（`reset()`） | `false` |
public struct CandidateSession: Sendable, Equatable {

    public var candidates: [String] = []
    /// 論理表示中（`NSWindow.isVisible` とは別。候補パネルを出すべき状態）。
    public var isVisible = false
    public var selectedRow = 0
    public var isExplicitlySelected = false
    public var fixedEnd = 0
    public var candidateSources: [ScoredCandidate.Source] = []
    /// PLAN260710a: 行ごとの助詞トリム可否。`candidates` と同長。
    public var candidateTrimFlags: [Bool] = []
    /// AzooKey API が返した順序（LCID ソート前）。Zenzai 有効 + 左文脈ありの `.show` でのみ非空。
    /// 候補ウィンドウで「Zenzai のソート順位」を小さく表示するための情報。
    public var azooKeyApiOrder: [String] = []
    /// 非 `nil` のとき括弧モード。候補リストはこの配列と同期する。
    public var bracketCandidates: [String]? = nil

    public var isBracketMode: Bool { bracketCandidates != nil }

    /// `isVisible` と `isExplicitlySelected` から導出する操作フェーズ。
    public var panelInteraction: CandidatePanelInteraction {
        guard isVisible else { return .hidden }
        return isExplicitlySelected ? .explicit : .passive
    }

    public var selectedText: String? {
        guard isVisible, candidates.indices.contains(selectedRow) else { return nil }
        return candidates[selectedRow]
    }

    /// `CandidateContext` を現在のフィールドから組み立てる。呼ぶたびに再計算される。
    public func makeContext() -> CandidateContext {
        CandidateContext(
            isVisible: isVisible,
            selectedRow: selectedRow,
            selectedText: selectedText,
            isExplicitlySelected: isExplicitlySelected,
            candidateSources: candidateSources,
            candidateTrimFlags: candidateTrimFlags,
            panelInteraction: panelInteraction
        )
    }

    public init() {}

    /// 括弧候補モードへ入る。`apply(.show)` とセットで呼ぶ（`handleBracketChar` 経路）。
    mutating func beginBracketMode(options: [String]) {
        bracketCandidates = options
    }

    /// 括弧モードを終了し候補パネルを閉じる。`bracketCandidates = nil` の正本。
    mutating func endBracketMode() {
        reset()
    }

    /// `bracketCandidates` 直書きの代替。`nil` は常に `endBracketMode()` へ委譲する。
    mutating func setBracketCandidates(_ value: [String]?) {
        if let value = value {
            bracketCandidates = value
        } else {
            endBracketMode()
        }
    }

    public mutating func reset() {
        candidates = []
        isVisible = false
        selectedRow = 0
        isExplicitlySelected = false
        fixedEnd = 0
        candidateSources = []
        candidateTrimFlags = []
        azooKeyApiOrder = []
        bracketCandidates = nil
        enforceInvariants()
    }

    private mutating func enforceInvariants() {
        if !isVisible {
            isExplicitlySelected = false
        }
    }

    /// 候補ウィンドウの削除ボタン用。行除去のみ。DB 削除と marked 同期は `InputController.onDelete` が行う。
    /// キーボードの Shift+Delete は `.deleteSelected` → `InputHandler.applyCandidateAction`（別経路）。
    public mutating func removeCandidate(at row: Int) {
        removeRows(at: row)
    }

    private mutating func removeRows(at row: Int) {
        guard candidates.indices.contains(row) else { return }
        candidates.remove(at: row)
        if candidateSources.indices.contains(row) { candidateSources.remove(at: row) }
        if candidateTrimFlags.indices.contains(row) { candidateTrimFlags.remove(at: row) }
        if candidates.isEmpty {
            reset()
        } else {
            selectedRow = min(selectedRow, candidates.count - 1)
        }
        enforceInvariants()
    }

    /// `InputHandler` / デバッグソケットが返した `CandidateAction` を反映する。
    public mutating func apply(_ action: CandidateAction) {
        switch action {
        case .none:
            break
        case .show(let cands, let fe, let apiOrder, let initialExplicit, let rowSources, let trimFlags):
            candidates = cands
            isVisible = !cands.isEmpty
            selectedRow = 0
            fixedEnd = fe
            candidateSources = rowSources
            candidateTrimFlags = trimFlags
            azooKeyApiOrder = apiOrder
            isExplicitlySelected = initialExplicit && isVisible
        case .dismiss:
            reset()
        case .selectNext:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = (selectedRow + 1) % candidates.count
            isExplicitlySelected = true
        case .selectPrev:
            guard isVisible, !candidates.isEmpty else { break }
            selectedRow = (selectedRow - 1 + candidates.count) % candidates.count
            isExplicitlySelected = true
        case .deleteSelected: // Shift+Delete。DB 削除は `applyCandidateAction` が apply 前に行う。
            guard isVisible else { break }
            removeRows(at: selectedRow)
        }
        enforceInvariants()
    }
}

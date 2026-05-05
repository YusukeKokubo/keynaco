import Cocoa
import InputMethodKit

extension Notification.Name {
    /// Successor の N-gram 保留（`pendingSuccessorCandidates`）の有無が変わったときに送る。
    static let keynacoSuccessorPendingChanged = Notification.Name("keynacoSuccessorPendingChanged")
    /// 誤変換検出で LLM が指摘を返したとき。`userInfo["detail"]` に全文。
    static let keynacoMisconversionIssueFound = Notification.Name("keynacoMisconversionIssueFound")
    /// 誤変換検出の指摘状態をクリアするとき（新しい組成開始・チェック結果 OK・サーバ非アクティブ化など）。
    static let keynacoMisconversionCleared = Notification.Name("keynacoMisconversionCleared")
}

// MARK: - IMKTextInput → TextInputClient アダプタ

private final class IMKTextInputAdapter: TextInputClient, @unchecked Sendable {
    private let client: IMKTextInput?
    private(set) var didInsertText = false
    #if DEBUG
    /// 直近の `setMarkedText` に渡したプレーンテキスト（IME サンドボックス用）。
    private(set) var lastMarkedText: String = ""
    #endif

    init(_ sender: Any?) {
        self.client = sender as? IMKTextInput
    }

    private(set) var lastInsertedText: String = ""

    func insertText(_ text: String) {
        didInsertText = true
        lastInsertedText = text
        // insertText は常に @MainActor の InputController 経由で呼ばれる
        #if DEBUG
        MainActor.assumeIsolated { EventViewerWindow.shared.addCommit(text) }
        #endif
        client?.insertText(text, replacementRange: .notFound)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange) {
        #if DEBUG
        lastMarkedText = text
        #endif
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func setMarkedText(_ text: NSAttributedString, selectionRange: NSRange) {
        #if DEBUG
        lastMarkedText = text.string
        #endif
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: .notFound)
    }

    func selectedRange() -> NSRange {
        client?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ text: String, selectionRange: NSRange, replacementRange: NSRange) {
        #if DEBUG
        lastMarkedText = text
        #endif
        client?.setMarkedText(text, selectionRange: selectionRange, replacementRange: replacementRange)
    }

    func cursorRect() -> NSRect {
        var rect = NSRect.zero
        client?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    // マークドテキストなし（確定後）のカーソル位置を selectedRange から取得する
    func cursorRectAtCursor() -> NSRect {
        guard let c = client else { return .zero }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return .zero }
        var rect = NSRect.zero
        c.attributes(forCharacterIndex: sel.location, lineHeightRectangle: &rect)
        return rect
    }

    func surroundingText(maxLength: Int = 200) -> (prefix: String, suffix: String) {
        guard let c = client else { return ("", "") }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return ("", "") }
        let prefixStart = max(0, sel.location - maxLength)
        let prefixLength = sel.location - prefixStart
        var prefixActual = NSRange()
        let prefix = c.string(
            from: NSRange(location: prefixStart, length: prefixLength),
            actualRange: &prefixActual
        ) ?? ""

        let totalLength = c.length()
        var suffix = ""
        if totalLength != NSNotFound, totalLength >= sel.location + sel.length {
            let suffixStart = sel.location + sel.length
            let suffixLength = min(maxLength, totalLength - suffixStart)
            if suffixLength > 0 {
                var suffixActual = NSRange()
                suffix = c.string(
                    from: NSRange(location: suffixStart, length: suffixLength),
                    actualRange: &suffixActual
                ) ?? ""
            }
        }
        return (prefix, suffix)
    }
}

// MARK: - InputController

@objc(InputController)
@MainActor
class InputController: IMKInputController {

    private lazy var handler: InputHandler = InputHandler()
    /// IME はプロセス内で共有されるため `LLMSuccessorFetcher` も1つにまとめ、`activateServer` 等の nonisolated オーバーライドからのデータ競合を避ける。
    private static let successorLLM = LLMSuccessorFetcher()
    private static let segmentLLM = LLMSegmentConverter()
    private static let candidateScorer = LLMCandidateScorer()
    private static let misconversionChecker = LLMMisconversionChecker()

    private static let candidateWindow: CandidateWindow = {
        let w = CandidateWindow(
            contentRect: .zero, styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        return w
    }()

    private var candidateWindow: CandidateWindow { Self.candidateWindow }

    /// `composedHiragana` が空→非空になったタイミングで `SurroundingIMKContext.fetch` 済み。`selectedRange().location` が一致するときだけ LLM 文脈に使う（Space 再取得は location 無効化で代替）。
    private var cachedSurroundingContext: (location: Int, text: (before: String, after: String))?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidateWindow.onDelete = { [weak self] (text: String, row: Int) in
            self?.handler.db.deleteHistory(output: text)
            self?.candidateWindow.removeCandidate(at: row)
        }
    }

    // MARK: - ライフサイクル

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(mask.rawValue)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ","))
        return menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showSettings()
    }

    override func showPreferences(_ sender: Any!) {
        SettingsWindowController.shared.showSettings()
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        // keynaco は内部で英字/日本語モードを管理する。
        // super を呼ぶと IMK が未対応モードへの切替を試みてイベントルーティングが壊れる。
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        handler.state = CompositionState()
        handler.committedHistory = []
        handler.isSuccessorMode = false
        handler.successorFirstChar = nil
        handler.pendingSuccessorCandidates = []
        handler.successorLLMSurfaceExtras = []
        handler.successorLLMTrigger = .none
        handler.successorLLMBaseCandidates = nil
        handler.segmentLLMTrigger = .none
        handler.resetScorerPending()
        cachedSurroundingContext = nil
        if Thread.isMainThread {
            Self.successorLLM.cancel()
            Self.segmentLLM.cancel()
            Self.candidateScorer.cancel()
            Self.misconversionChecker.cancel()
        } else {
            DispatchQueue.main.sync {
                Self.successorLLM.cancel()
                Self.segmentLLM.cancel()
                Self.candidateScorer.cancel()
                Self.misconversionChecker.cancel()
            }
        }
        handler.ignoreNextModeSwitch = true
        candidateWindow.dismiss()
        Self.postSuccessorPendingNotification(pending: false)
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    /// `handle` 内の `handler.handle` 成功後、候補ウィンドウ更新・周辺文脈・LLM 補助・誤変換のスケジュールまでを一括で行う。戻り値はメニューバー用 Successor 保留フラグ。
    @MainActor
    private func applyPostKeyDownEffects(
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        composedHiraganaWasEmpty: Bool,
        composingWasEmpty: Bool,
        imkSenderForSurrounding: Any?
    ) -> Bool {
        switch action {
        case .none:
            break
        case .show(let candidates, let historyEnd, let initialRow, let predictionEnd, let fixedEnd):
            #if DEBUG
            EventViewerWindow.shared.addCandidates(candidates, selectedIndex: initialRow)
            #endif
            candidateWindow.show(candidates: candidates, historySectionEnd: historyEnd, initialRow: initialRow, predictionEnd: predictionEnd, fixedSectionEnd: fixedEnd, near: adapter.cursorRect())
            if handler.isSuccessorMode {
                // 格助詞を選択候補としてマークドテキストに設定する。
                // 空文字ではなく実際のテキストを持つことで Electron 系アプリが Enter を IME に転送するようになる。
                let markedText = candidates.isEmpty ? "" : candidates[min(initialRow, candidates.count - 1)]
                adapter.setMarkedText(markedText, selectionRange: NSRange(location: markedText.count, length: 0))
            }
        case .dismiss:
            candidateWindow.dismiss()
        case .selectNext:
            candidateWindow.selectNext()
            if handler.isSuccessorMode || handler.isBracketMode {
                let text = candidateWindow.selectedText() ?? ""
                adapter.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
            } else {
                updateMarkedText(client: adapter)
            }
        case .selectPrev:
            candidateWindow.selectPrev()
            if handler.isSuccessorMode || handler.isBracketMode {
                let text = candidateWindow.selectedText() ?? ""
                adapter.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
            } else {
                updateMarkedText(client: adapter)
            }
        case .deleteSelected:
            let row = candidateWindow.selectedRow
            if let text = candidateWindow.selectedText() {
                handler.db.deleteHistory(output: text)
                candidateWindow.removeCandidate(at: row)
            }
        }

        if handler.documentSurroundingContextInvalidated {
            cachedSurroundingContext = nil
            handler.documentSurroundingContextInvalidated = false
        }
        if handler.state.composedHiragana.isEmpty {
            cachedSurroundingContext = nil
        } else if composedHiraganaWasEmpty && !handler.state.composedHiragana.isEmpty {
            // Space での再取得は冗長のため行わない（カーソル移動は location 不一致で無効化）。
            if let ctx = SurroundingIMKContext.fetch(from: imkSenderForSurrounding) {
                let loc = adapter.selectedRange().location
                if loc != NSNotFound {
                    cachedSurroundingContext = (loc, ctx)
                }
            }
        }

        applySuccessorLLMScheduling(adapter: adapter)
        applySegmentLLMScheduling(adapter: adapter)
        applyCandidateScorerScheduling(adapter: adapter)

        if adapter.didInsertText {
            scheduleMisconversionCheck(adapter: adapter)
        }
        if !handler.isSuccessorMode, !handler.isBracketMode,
           composingWasEmpty, !handler.state.composingText.isEmpty {
            Self.misconversionChecker.cancel(suppressClearNotification: false)
        }

        return !handler.pendingSuccessorCandidates.isEmpty
    }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }

        // Caps Lock でモード切替（LED ON = 英字モード、LED OFF = 日本語モード）
        if event.type == .flagsChanged && event.keyCode == KeyCode.capsLock {
            InputHandler.isAsciiMode = event.modifierFlags.contains(.capsLock)
            return false
        }

        guard event.type == .keyDown else { return false }

        let chars = event.characters ?? ""
        let baseChars = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags
        #if DEBUG
        EventViewerWindow.shared.addEvent(
            keyCode: event.keyCode, chars: chars, baseChars: baseChars,
            mods: mods, bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        #endif

        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected,
            historyEnd: candidateWindow.historySectionEnd,
            fixedEnd: candidateWindow.fixedRowCount
        )
        let adapter = IMKTextInputAdapter(sender)

        let composingWasEmpty = handler.state.composingText.isEmpty
        let composedHiraganaWasEmpty = handler.state.composedHiragana.isEmpty

        let (consumed, action) = handler.handle(
            keyCode: event.keyCode,
            characters: event.characters,
            baseCharacters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            candidate: ctx,
            client: adapter
        )

        #if DEBUG
        let actionName = "\(action)".split(separator: "(").first.map(String.init) ?? "\(action)"
        EventViewerWindow.shared.updateResult(consumed: consumed, action: actionName)
        #endif

        // IMK の `handle` は nonisolated。候補ウィンドウ操作は従来どおり MainActor 前提（assumeIsolated はメイン以外では実行時クラッシュしうる）。
        // `sender` / `self` は IMK ブリッジ上 nonisolated から MainActor 島へ渡すため nonisolated(unsafe) とする（Swift 6 sending）。
        nonisolated(unsafe) let imkSenderForSurrounding: Any? = sender
        nonisolated(unsafe) let ic: InputController = self
        // ステータス通知は島から値を返し、`DispatchQueue.main.async` で投稿する（post 自体は nonisolated static）。
        #if DEBUG
        let (successorPendingForMenuBar, imeStateSnapshot) = MainActor.assumeIsolated {
            let pending = ic.applyPostKeyDownEffects(
                action: action,
                adapter: adapter,
                composedHiraganaWasEmpty: composedHiraganaWasEmpty,
                composingWasEmpty: composingWasEmpty,
                imkSenderForSurrounding: imkSenderForSurrounding
            )
            var snap = ic.handler.snapshot(markedText: adapter.lastMarkedText)
            snap.candidateVisible = ic.candidateWindow.isVisible
            snap.selectedRow = ic.candidateWindow.selectedRow
            snap.selectedText = ic.candidateWindow.selectedText()
            snap.isExplicitlySelected = ic.candidateWindow.isExplicitlySelected
            snap.historyEnd = ic.candidateWindow.historySectionEnd
            snap.fixedEnd = ic.candidateWindow.fixedRowCount
            snap.candidates = Array(ic.candidateWindow.candidates.prefix(30))
            return (pending, snap)
        }
        #else
        let successorPendingForMenuBar = MainActor.assumeIsolated {
            ic.applyPostKeyDownEffects(
                action: action,
                adapter: adapter,
                composedHiraganaWasEmpty: composedHiraganaWasEmpty,
                composingWasEmpty: composingWasEmpty,
                imkSenderForSurrounding: imkSenderForSurrounding
            )
        }
        #endif
        DispatchQueue.main.async {
            Self.postSuccessorPendingNotification(pending: successorPendingForMenuBar)
            #if DEBUG
            NotificationCenter.default.post(
                name: .imeStateDidUpdate,
                object: nil,
                userInfo: ["snapshot": imeStateSnapshot]
            )
            #endif
        }
        return consumed
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        // Successor モード中で組成がない場合は system-triggered commit をスキップ
        // (insertText の副作用で system が commitComposition を呼ぶことがある)
        if handler.isSuccessorMode && handler.state.composingText.isEmpty && !handler.state.isSegmentMode {
            return
        }
        let adapter = IMKTextInputAdapter(sender)
        let ctx = CandidateContext(
            isVisible: candidateWindow.isVisible,
            selectedRow: candidateWindow.selectedRow,
            selectedText: candidateWindow.selectedText(),
            isExplicitlySelected: candidateWindow.isExplicitlySelected,
            historyEnd: candidateWindow.historySectionEnd,
            fixedEnd: candidateWindow.fixedRowCount
        )
        handler.commitComposition(client: adapter, candidate: ctx)
        handler.isSuccessorMode = false
        handler.successorFirstChar = nil
        handler.pendingSuccessorCandidates = []
        handler.successorLLMSurfaceExtras = []
        handler.successorLLMTrigger = .none
        handler.successorLLMBaseCandidates = nil
        handler.segmentLLMTrigger = .none
        handler.bracketCandidates = nil
        if Thread.isMainThread {
            Self.successorLLM.cancel()
            Self.segmentLLM.cancel()
            Self.candidateScorer.cancel()
        } else {
            DispatchQueue.main.sync {
                Self.successorLLM.cancel()
                Self.segmentLLM.cancel()
                Self.candidateScorer.cancel()
            }
        }
        handler.resetScorerPending()
        cachedSurroundingContext = nil
        candidateWindow.dismiss()
        Self.postSuccessorPendingNotification(pending: false)

        if adapter.didInsertText {
            scheduleMisconversionCheck(adapter: adapter)
        }
    }

    // MARK: - プライベートヘルパー

    /// LLM 用の文脈プレフィックス。IMK の `before`（キャッシュ・location 一致時）が非空なら最大 300 字のみ。それ以外は `committedHistory.suffix(5)` のみ。
    private func resolvedLLMDocumentContextPrefix(adapter: IMKTextInputAdapter) -> String {
        let historyJoined = handler.committedHistory.suffix(5).joined()
        let loc = adapter.selectedRange().location
        guard loc != NSNotFound else { return historyJoined }

        if let cache = cachedSurroundingContext, cache.location == loc, !cache.text.before.isEmpty {
            let b = cache.text.before
            return b.count > 300 ? String(b.suffix(300)) : b
        }

        if cachedSurroundingContext != nil {
            cachedSurroundingContext = nil
        }
        return historyJoined
    }

    /// 確定 `insertText` 後にカーソル前文を誤変換検出で検査（0.5 秒デバウンス）。
    private func scheduleMisconversionCheck(adapter: IMKTextInputAdapter) {
        let prefix = adapter.surroundingText(maxLength: 200).prefix
        let recentWords = Array(handler.committedHistory.suffix(5))
        Self.misconversionChecker.check(surroundingPrefix: prefix, recentWords: recentWords)
    }

    /// 変換候補を直前文脈でスコアリングして並べ替える。文脈はこのキー処理内で同期取得したもののみ使う。
    private func applyCandidateScorerScheduling(adapter: IMKTextInputAdapter) {
        // 読みが変わった・ユーザーが操作した場合どちらも前タスクを破棄（↑↓ 後は guard で score しないが cancel は先行）。
        Self.candidateScorer.cancel()
        guard handler.lastScorerEligible else { return }
        guard !handler.pendingScorerGlobalIndices.isEmpty else { return }
        guard !candidateWindow.isExplicitlySelected else { return }
        guard !handler.state.isSegmentMode else { return }
        guard !handler.isSuccessorMode else { return }
        guard !handler.isBracketMode else { return }

        let contextForScore = resolvedLLMDocumentContextPrefix(adapter: adapter)
        let reading = handler.state.composedHiragana
        let opts = handler.pendingScorerStrings
        let wasAutoShow = handler.lastCandidateListAutoShow

        let examples: [(prev: String, next: String)] =
            handler.committedHistory.last.map { lastWord in
                handler.db.fetchBigramTop(prev: lastWord, limit: 5).map { (prev: lastWord, next: $0) }
            } ?? []

        Self.candidateScorer.score(
            candidates: opts,
            context: contextForScore,
            reading: reading,
            examples: examples
        ) { [weak self] result in
            guard let self else { return }
            guard result.confidence == .high || !wasAutoShow else { return }
            guard result.index != 0 || !wasAutoShow else { return }
            let idx = result.index
            guard idx >= 0, idx < self.handler.pendingScorerGlobalIndices.count else { return }
            guard self.candidateWindow.isVisible else { return }
            guard !self.candidateWindow.isExplicitlySelected else { return }
            guard !self.handler.state.isSegmentMode else { return }
            guard !self.handler.isSuccessorMode else { return }
            guard !self.handler.isBracketMode else { return }
            guard self.handler.state.composedHiragana == reading else { return }

            let g = self.handler.pendingScorerGlobalIndices[idx]
            self.candidateWindow.moveRow(from: g)
            self.updateMarkedText(client: adapter)
        }
    }

    /// `suggestSuccessors()` が立てた `successorLLMTrigger` に応じてオンデバイス LLM で後続語を補完する。
    private func applySuccessorLLMScheduling(adapter: IMKTextInputAdapter) {
        let trigger = handler.successorLLMTrigger
        guard trigger != .none else { return }
        handler.successorLLMTrigger = .none

        let triggerContextOpt: [String]? = {
            switch trigger {
            case .pendingLowConfidence(let ctx), .particlesOnly(let ctx): return ctx
            // 直前の guard で .none は除外済み（列挙の網羅性のため残す）
            case .none: return nil
            }
        }()
        let examples: [(prev: String, next: String)] = triggerContextOpt.flatMap { tc in
            tc.last.map { lw in
                handler.db.fetchBigramTop(prev: lw, limit: 5)
                    .filter { !InputHandler.particles.contains($0) }
                    .map { (prev: lw, next: $0) }
            }
        } ?? []

        switch trigger {
        case .none:
            break
        case .pendingLowConfidence(let triggerContext):
            let docPrefix = resolvedLLMDocumentContextPrefix(adapter: adapter)
            Self.successorLLM.fetch(
                context: triggerContext, documentContextPrefix: docPrefix, examples: examples
            ) { [weak self] words in
                guard let self else { return }
                guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
                guard self.handler.isSuccessorMode else { return }
                // LLM が遅延到着しても、既に1打目表示済みなら UI は更新しない（extras にのみ溜まりうる）。
                var seen = Set(self.handler.pendingSuccessorCandidates)
                seen.formUnion(self.handler.successorLLMSurfaceExtras)
                let extra = words.filter { !seen.contains($0) }
                guard !extra.isEmpty else { return }
                self.handler.successorLLMSurfaceExtras.append(contentsOf: extra)
                if !self.handler.pendingSuccessorCandidates.isEmpty {
                    Self.postSuccessorPendingNotification(pending: true)
                }
            }
        case .particlesOnly(let triggerContext):
            let docPrefix = resolvedLLMDocumentContextPrefix(adapter: adapter)
            Self.successorLLM.fetch(
                context: triggerContext, documentContextPrefix: docPrefix, examples: examples
            ) { [weak self] words in
                guard let self else { return }
                guard Array(self.handler.committedHistory.suffix(3)) == triggerContext else { return }
                guard self.handler.isSuccessorMode,
                      self.candidateWindow.isVisible,
                      let base = self.handler.successorLLMBaseCandidates else { return }
                var seen = Set(base)
                seen.formUnion(self.handler.successorLLMSurfaceExtras)
                let extra = words.filter { !seen.contains($0) }
                guard !extra.isEmpty else { return }
                for w in extra where seen.insert(w).inserted {
                    self.handler.successorLLMSurfaceExtras.append(w)
                }
                var merged = base
                var tailSeen = Set(base)
                for w in self.handler.successorLLMSurfaceExtras where tailSeen.insert(w).inserted {
                    merged.append(w)
                }
                let rowCap = max(0, merged.count - 1)
                let initialRow = min(self.candidateWindow.selectedRow, rowCap)
                self.candidateWindow.show(
                    candidates: merged, historySectionEnd: 0, initialRow: initialRow,
                    predictionEnd: 0, fixedSectionEnd: 0, near: adapter.cursorRect()
                )
                if self.handler.isSuccessorMode, !merged.isEmpty,
                   let markedText = self.candidateWindow.selectedText(), !markedText.isEmpty {
                    adapter.setMarkedText(markedText, selectionRange: NSRange(location: markedText.count, length: 0))
                }
            }
        }
    }

    /// `enterSegmentMode()` が立てた `segmentLLMTrigger` に応じてオンデバイス LLM で読み全体を一括変換する。
    private func applySegmentLLMScheduling(adapter: IMKTextInputAdapter) {
        let trigger = handler.segmentLLMTrigger
        guard case .start(let hiragana) = trigger else { return }
        handler.segmentLLMTrigger = .none
        Self.segmentLLM.convert(hiragana: hiragana) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let segState = self.handler.state.segmentState,
                  segState.segments.map(\.reading).joined() == hiragana else { return }
            self.handler.applyLLMSegmentResult(text: trimmed)
            guard let updated = self.handler.state.segmentState,
                  updated.llmWholeText != nil,
                  !updated.segments.isEmpty else { return }
            let action = self.handler.makeCandidateActionForFocusedSegment()
            if case .show(let cands, let historyEnd, let initialRow, let predictionEnd, let fixedEnd) = action {
                self.candidateWindow.show(
                    candidates: cands, historySectionEnd: historyEnd, initialRow: initialRow,
                    predictionEnd: predictionEnd, fixedSectionEnd: fixedEnd, near: adapter.cursorRect()
                )
                self.handler.applySegmentMarkedText(client: adapter)
            }
        }
    }

    /// IMK の `handle` / `activateServer` は nonisolated のため、通知だけ static で送る（MainActor の `self` を捕らない）。
    private nonisolated static func postSuccessorPendingNotification(pending: Bool) {
        NotificationCenter.default.post(
            name: .keynacoSuccessorPendingChanged,
            object: nil,
            userInfo: ["pending": pending]
        )
    }

    private func updateMarkedText(client: TextInputClient) {
        if let ss = handler.state.segmentState {
            let str = ss.attributedString(overrideFocusedText: candidateWindow.selectedText())
            client.setMarkedText(str, selectionRange: NSRange(location: str.length, length: 0))
        } else {
            let text: String
            if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
                text = selected + handler.state.pendingRomaji
            } else {
                text = handler.state.composingText
            }
            client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
        }
    }

}

private extension NSRange {
    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
}

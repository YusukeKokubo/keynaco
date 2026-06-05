import Cocoa
import KeynacoCore
import InputMethodKit

// MARK: - InputController

@objc(InputController)
@MainActor
class InputController: IMKInputController, @unchecked Sendable {

    lazy var handler: InputHandler = InputHandler(azooKeyConverter: ZenzaiSettings.makeConverter())
    /// Zenzai 設定変更時に `AzooKeyConverter` を差し替える（IMK の `init` は nonisolated のため `unsafe`）
    nonisolated(unsafe) private var zenzaiSettingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var hiraganaPreferredObserver: NSObjectProtocol?
    static let candidateWindow: CandidateWindow = {
        let w = CandidateWindow(
            contentRect: .zero, styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        return w
    }()

    var candidateWindow: CandidateWindow { Self.candidateWindow }

    /// `composedHiragana` が空→非空になったタイミングで `SurroundingIMKContext.fetch` 済み。`selectedRange().location` が一致するときだけ LLM 文脈に使う（Space 再取得は location 無効化で代替）。
    var cachedSurroundingContext: (location: Int, text: (before: String, after: String))?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let ic = self
        MainActor.assumeIsolated {
            ic.candidateWindow.onDelete = { [weak ic] (text: String, row: Int) in
                MainActor.assumeIsolated {
                    ic?.handler.db.deleteHistory(output: text)
                    ic?.candidateWindow.removeCandidate(at: row)
                }
            }
        }
        zenzaiSettingsObserver = NotificationCenter.default.addObserver(
            forName: .keynacoZenzaiSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadAzooKeyConverterFromSettings()
            }
        }
        hiraganaPreferredObserver = NotificationCenter.default.addObserver(
            forName: .keynacoHiraganaPreferredDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handler.hiraganaPreferredSet = DatabaseManager.shared.fetchHiraganaPreferredSet()
            }
        }
    }

    deinit {
        if let zenzaiSettingsObserver {
            NotificationCenter.default.removeObserver(zenzaiSettingsObserver)
        }
        if let hiraganaPreferredObserver {
            NotificationCenter.default.removeObserver(hiraganaPreferredObserver)
        }
    }

    @MainActor
    private func reloadAzooKeyConverterFromSettings() {
        handler.azooKeyConverter = ZenzaiSettings.makeConverter()
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
        MainActor.assumeIsolated { SettingsWindowController.shared.showSettings() }
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        // keynaco は内部で英字/日本語モードを管理する。
        // super を呼ぶと IMK が未対応モードへの切替を試みてイベントルーティングが壊れる。
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        let ic = self
        MainActor.assumeIsolated {
            ic.handler.state = CompositionState()
            ic.handler.committedHistory = []
            ic.handler.sessionTextBuffer = ""
            ic.cachedSurroundingContext = nil
            ic.handler.leftSideContext = ""
            ic.handler.ignoreNextModeSwitch = true
            ic.candidateWindow.dismiss()
        }
    }

    override func deactivateServer(_ sender: Any!) {
        handler.flushDiaryBuffer()
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    /// `handle` 内の `handler.handle` 成功後、候補ウィンドウ更新・周辺文脈・LLM 補助・誤変換のスケジュールまでを一括で行う。
    @MainActor
    private func applyPostKeyDownEffects(
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        composedHiraganaWasEmpty: Bool,
        composingWasEmpty: Bool,
        imkSenderForSurrounding: Any?
    ) {
        switch action {
        case .none:
            break
        case .show(let candidates, let historyEnd, let initialRow, let fixedEnd):
            candidateWindow.show(candidates: candidates, historySectionEnd: historyEnd, initialRow: initialRow, fixedSectionEnd: fixedEnd, zenzaiRow: handler.lastZenzaiRow, near: adapter.cursorRect())
        case .dismiss:
            candidateWindow.dismiss()
        case .selectNext:
            candidateWindow.selectNext()
            syncMarkedText(client: adapter)
        case .selectPrev:
            candidateWindow.selectPrev()
            syncMarkedText(client: adapter)
        case .deleteSelected:
            let row = candidateWindow.selectedRow
            if let text = candidateWindow.selectedText() {
                handler.db.deleteHistory(output: text)
                candidateWindow.removeCandidate(at: row)
            }
        case .replaceCandidates(let candidates):
            candidateWindow.replaceCandidates(candidates)
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

        if adapter.didInsertText {
            schedulePOSClassification(
                output: adapter.lastInsertedText,
                reading: handler.lastCommittedReading ?? ""
            )
        }

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

        // NSEvent を assumeIsolated の外で value-type に分解して region-based isolation エラーを回避する
        let keyCode = event.keyCode
        let characters = event.characters
        let baseCharacters = event.charactersIgnoringModifiers
        let modifiers = event.modifierFlags

        let adapter = IMKTextInputAdapter(sender)
        let ic: InputController = self
        // IMK の `handle` は nonisolated。候補ウィンドウ操作は従来どおり MainActor 前提（assumeIsolated はメイン以外では実行時クラッシュしうる）。
        // `sender` / `self` は IMK ブリッジ上 nonisolated から MainActor 島へ渡すため nonisolated(unsafe) とする（Swift 6 sending）。
        nonisolated(unsafe) let imkSenderForSurrounding: Any? = sender

        // @MainActor アクセス（candidateWindow・handler）を assumeIsolated に集約。ステータス通知は島から値を返し DispatchQueue.main.async で投稿する。
        #if DEBUG
        let (consumed, imeStateSnapshot) = MainActor.assumeIsolated {
            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ic.handler.currentAppBundleID = frontBundleID
            let ctx = CandidateContext(
                isVisible: ic.candidateWindow.isVisible,
                selectedRow: ic.candidateWindow.selectedRow,
                selectedText: ic.candidateWindow.selectedText(),
                isExplicitlySelected: ic.candidateWindow.isExplicitlySelected,
                historyEnd: ic.candidateWindow.historySectionEnd,
                fixedEnd: ic.candidateWindow.fixedRowCount
            )
            ic.handler.leftSideContext = ic.resolvedLLMDocumentContextPrefix(adapter: adapter)
            let composingWasEmpty = ic.handler.state.composingText.isEmpty
            let composedHiraganaWasEmpty = ic.handler.state.composedHiragana.isEmpty
            let (consumed, action) = ic.handler.handle(
                keyCode: keyCode,
                characters: characters,
                baseCharacters: baseCharacters,
                modifiers: modifiers,
                candidate: ctx,
                client: adapter
            )
            ic.applyPostKeyDownEffects(
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
            return (consumed, snap)
        }
        #else
        let consumed = MainActor.assumeIsolated {
            let ctx = CandidateContext(
                isVisible: ic.candidateWindow.isVisible,
                selectedRow: ic.candidateWindow.selectedRow,
                selectedText: ic.candidateWindow.selectedText(),
                isExplicitlySelected: ic.candidateWindow.isExplicitlySelected,
                historyEnd: ic.candidateWindow.historySectionEnd,
                fixedEnd: ic.candidateWindow.fixedRowCount
            )
            ic.handler.currentAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ic.handler.leftSideContext = ic.resolvedLLMDocumentContextPrefix(adapter: adapter)
            let composingWasEmpty = ic.handler.state.composingText.isEmpty
            let composedHiraganaWasEmpty = ic.handler.state.composedHiragana.isEmpty
            let (consumed, action) = ic.handler.handle(
                keyCode: keyCode,
                characters: characters,
                baseCharacters: baseCharacters,
                modifiers: modifiers,
                candidate: ctx,
                client: adapter
            )
            ic.applyPostKeyDownEffects(
                action: action,
                adapter: adapter,
                composedHiraganaWasEmpty: composedHiraganaWasEmpty,
                composingWasEmpty: composingWasEmpty,
                imkSenderForSurrounding: imkSenderForSurrounding
            )
            return consumed
        }
        #endif
        DispatchQueue.main.async {
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
        let adapter = IMKTextInputAdapter(sender)
        let ic = self
        MainActor.assumeIsolated {
            // 候補表示中で組成がない場合は system-triggered commit をスキップ
            // (insertText の副作用で system が commitComposition を呼ぶことがある)
            guard !(
                ic.candidateWindow.isVisible
                    && ic.handler.state.composedHiragana.isEmpty
                    && !ic.handler.isBracketMode
            ) else { return }
            let ctx = CandidateContext(
                isVisible: ic.candidateWindow.isVisible,
                selectedRow: ic.candidateWindow.selectedRow,
                selectedText: ic.candidateWindow.selectedText(),
                isExplicitlySelected: ic.candidateWindow.isExplicitlySelected,
                historyEnd: ic.candidateWindow.historySectionEnd,
                fixedEnd: ic.candidateWindow.fixedRowCount
            )
            ic.handler.commitComposition(client: adapter, candidate: ctx)
            ic.handler.bracketCandidates = nil
            ic.cachedSurroundingContext = nil
            ic.handler.leftSideContext = ""
            ic.candidateWindow.dismiss()
        }
    }

    // MARK: - プライベートヘルパー

    /// 候補ウィンドウの選択状態と組成文字列を IMK marked text に反映する。
    ///
    /// - 括弧モード、または組成ひらがななしで候補のみ表示: 選択候補のみ（Electron が空 marked text を非アクティブ扱いする対策）
    /// - 通常の組成中: 選択候補 + `pendingRomaji`
    /// - 候補非表示: `composingText`
    private func syncMarkedText(client: TextInputClient) {
        let text: String
        let candidateOnly = handler.isBracketMode
            || (candidateWindow.isVisible && handler.state.composedHiragana.isEmpty)
        if candidateOnly, let selected = candidateWindow.selectedText() {
            text = selected
        } else if candidateWindow.isVisible, let selected = candidateWindow.selectedText() {
            text = selected + handler.state.pendingRomaji
        } else {
            text = handler.state.composingText
        }
        client.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0))
    }

}

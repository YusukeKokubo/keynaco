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

    private var candidateWindow: CandidateWindow!
    /// 直近の `handle(event:client:)` の IMK クライアント（候補 UI 削除などキーイベント外の marked 同期用）。
    private weak var activeIMKClient: AnyObject?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let ic = self
        MainActor.assumeIsolated {
            ic.candidateWindow = CandidateWindow(
                contentRect: .zero, styleMask: [.borderless],
                backing: .buffered, defer: true
            )
            // キー経路外。`.deleteSelected` ではなく removeCandidate + syncMarkedText（CandidateSession の doc 参照）。
            ic.candidateWindow.onDelete = { [weak ic] (text: String, row: Int) in
                MainActor.assumeIsolated {
                    guard let ic else { return }
                    ic.handler.db.deleteHistory(output: text)
                    ic.handler.candidateSession.removeCandidate(at: row)
                    ic.candidateWindow.apply(
                        CandidatePanelModel(session: ic.handler.candidateSession),
                        layout: .refreshInPlace
                    )
                    ic.syncMarkedTextToActiveClient()
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
            LeftContextSource.resetCache(&ic.handler.leftContextIMKCache)
            ic.handler.leftContext = .empty
            ic.handler.ignoreNextModeSwitch = true
            ic.handler.candidateSession.reset()
            ic.candidateWindow.dismiss()
        }
    }

    override func deactivateServer(_ sender: Any!) {
        handler.flushDiaryBuffer()
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    /// 候補セッション変更後、直近の IMK クライアントへ marked text を反映する。
    @MainActor
    private func syncMarkedTextToActiveClient() {
        guard let activeIMKClient else { return }
        handler.syncMarkedText(client: IMKTextInputAdapter(activeIMKClient))
    }

    /// 候補ウィンドウ更新のみ。session / marked は `InputHandler.applyPostKeyDownCandidateAndIMK` が担当。
    @MainActor
    private func applyCandidateWindowEffects(action: CandidateAction, adapter: IMKTextInputAdapter) {
        let panel = CandidatePanelModel(session: handler.candidateSession)
        switch action {
        case .none:
            break
        case .deleteSelected:
            candidateWindow.apply(panel, layout: .refreshInPlace)
        case .dismiss:
            candidateWindow.apply(panel, layout: .dismiss)
        case .selectNext, .selectPrev:
            candidateWindow.apply(panel, layout: .selectionOnly)
        case .show, .replaceCandidates:
            candidateWindow.apply(panel, layout: .present(near: adapter.cursorRect()))
        }
    }

    /// キー処理後の副作用。候補 / IMK は Core、ウィンドウ・POS は本ファイル。
    @MainActor
    private func applyPostKeyDownEffects(
        consumed: Bool,
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        composedHiraganaWasEmpty: Bool,
        imkSenderForSurrounding: Any?
    ) {
        var newSnapshot: IMKSurroundingSnapshot?
        if composedHiraganaWasEmpty && !handler.state.composedHiragana.isEmpty {
            // Space での再取得は冗長のため行わない（カーソル移動は location 不一致で無効化）。
            if let ctx = SurroundingIMKContext.fetch(from: imkSenderForSurrounding) {
                let loc = adapter.selectedRange().location
                if loc != NSNotFound {
                    newSnapshot = IMKSurroundingSnapshot(location: loc, before: ctx.before, after: ctx.after)
                }
            }
        }

        var imkCache = handler.leftContextIMKCache
        handler.applyPostKeyDownCandidateAndIMK(
            consumed: consumed,
            action: action,
            client: adapter,
            composedHiraganaWasEmpty: composedHiraganaWasEmpty,
            didInsertText: adapter.didInsertText,
            imkCache: &imkCache,
            newIMKSnapshot: newSnapshot
        )
        handler.leftContextIMKCache = imkCache

        if consumed {
            applyCandidateWindowEffects(action: action, adapter: adapter)
        }

        if adapter.didInsertText {
            schedulePOSClassification(
                output: adapter.lastInsertedText,
                reading: handler.lastCommittedReading ?? ""
            )
        }
    }

    @MainActor
    func runKeyDown(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        adapter: IMKTextInputAdapter,
        imkSenderForSurrounding: Any?
    ) -> Bool {
        handler.currentAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        handler.leftContext = LeftContextSource.resolveProduction(
            sessionBuffer: handler.sessionTextBuffer,
            cache: &handler.leftContextIMKCache,
            cursorLocation: adapter.selectedRange().location
        )
        let composedHiraganaWasEmpty = handler.state.composedHiragana.isEmpty
        let ctx = handler.candidateSession.context
        let (consumed, action) = handler.handle(
            keyCode: keyCode,
            characters: characters,
            baseCharacters: baseCharacters,
            modifiers: modifiers,
            candidate: ctx,
            client: adapter
        )
        // 矢印等の未消費キーは marked 同期をスキップ。Enter 空組成の surrounding 無効化は未消費でも必要。
        applyPostKeyDownEffects(
            consumed: consumed,
            action: action,
            adapter: adapter,
            composedHiraganaWasEmpty: composedHiraganaWasEmpty,
            imkSenderForSurrounding: imkSenderForSurrounding
        )
        return consumed
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

        activeIMKClient = sender as AnyObject?
        let adapter = IMKTextInputAdapter(sender)
        let ic: InputController = self
        nonisolated(unsafe) let imkSenderForSurrounding: Any? = sender

        #if DEBUG
        return MainActor.assumeIsolated {
            ic.runKeyDownPublishingSnapshot(
                keyCode: keyCode,
                characters: characters,
                baseCharacters: baseCharacters,
                modifiers: modifiers,
                adapter: adapter,
                imkSenderForSurrounding: imkSenderForSurrounding
            )
        }
        #else
        return MainActor.assumeIsolated {
            ic.runKeyDown(
                keyCode: keyCode,
                characters: characters,
                baseCharacters: baseCharacters,
                modifiers: modifiers,
                adapter: adapter,
                imkSenderForSurrounding: imkSenderForSurrounding
            )
        }
        #endif
    }

    // MARK: - 確定

    override func commitComposition(_ sender: Any!) {
        let adapter = IMKTextInputAdapter(sender)
        let ic = self
        MainActor.assumeIsolated {
            let session = ic.handler.candidateSession
            guard !(
                session.isVisible
                    && ic.handler.state.composedHiragana.isEmpty
                    && !session.isBracketMode
            ) else { return }
            ic.handler.commitComposition(client: adapter, candidate: session.context)
            ic.handler.candidateSession.reset()
            LeftContextSource.resetCache(&ic.handler.leftContextIMKCache)
            ic.handler.leftContext = .empty
            ic.candidateWindow.dismiss()
        }
    }

    // MARK: - プライベートヘルパー

}

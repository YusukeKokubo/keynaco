import Cocoa
import KeynacoCore
import InputMethodKit

// MARK: - InputController

@objc(InputController)
@MainActor
class InputController: IMKInputController, @unchecked Sendable {

    lazy var handler: InputHandler = {
        var h = InputHandler(azooKeyConverter: ZenzaiSettings.makeConverter())
        h.deferAzooKeyWhileTyping = true
        return h
    }()
    let azooKeyScheduler = AzooKeyAsyncScheduler()
    /// Zenzai 設定変更時に `AzooKeyConverter` を差し替える（IMK の `init` は nonisolated のため `unsafe`）
    nonisolated(unsafe) private var zenzaiSettingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var hiraganaPreferredObserver: NSObjectProtocol?

    private var candidateWindow: CandidateWindow!
    /// 直近の `handle(event:client:)` の IMK クライアント（候補 UI 削除などキーイベント外の marked 同期用）。
    private weak var activeIMKClient: AnyObject?
    /// 直前セッション終了時に生成したレコード。次キーで penalize 判定後に書き込む。
    private var pendingInputRecord: InputSessionRecord? = nil
    private let inputQualityLogger = InputQualityLogger()
    private let divergenceLogger = CandidateDivergenceLogger()

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let version = AppVersion.logLabel
        handler.azooKeyConverter.fetchLogger.appVersion = version
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
                    ic.handler.invalidateLocalSourcesCache()
                    ic.handler.candidateSession.removeCandidate(at: row)
                    ic.candidateWindow.apply(
                        ic.makeCandidatePanelModel(),
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
        cancelAzooKeyAsyncWork()
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
            ic.cancelAzooKeyAsyncWork()
            ic.handler.state = CompositionState()
            ic.handler.invalidateMarkedTextSyncCache()
            ic.handler.committedHistory = []
            ic.handler.sessionTextBuffer = ""
            LeftContextSource.resetCache(&ic.handler.leftContextIMKCache)
            ic.handler.leftContext = .empty
            ic.handler.ignoreNextModeSwitch = true
            ic.handler.deferAzooKeyWhileTyping = true
            ic.handler.candidateSession.reset()
            ic.handler.currentAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ic.candidateWindow.dismiss()
        }
    }

    override func deactivateServer(_ sender: Any!) {
        cancelAzooKeyAsyncWork()
        handler.flushDiaryBuffer()
        commitComposition(sender)
        let version = AppVersion.logLabel
        handler.azooKeyConverter.latencyStats.appendToLogForced(
            fileURL: DatabaseManager.latencyLogURL,
            appVersion: version
        )
        inputQualityLogger.flushForced()
        divergenceLogger.flushForced()
        handler.azooKeyConverter.fetchLogger.flushForced()
        super.deactivateServer(sender)
    }

    /// 候補セッション変更後、直近の IMK クライアントへ marked text を反映する。
    @MainActor
    private func syncMarkedTextToActiveClient() {
        guard let activeIMKClient else { return }
        handler.syncMarkedText(client: IMKTextInputAdapter(activeIMKClient))
    }

    /// 候補ウィンドウ更新のみ。session / marked は `InputHandler.applyPostKeyDownCandidateAndIMK` が担当。
    ///
    /// - Parameter preferInPlaceRefresh: 既に表示中なら `.present` せず内容だけ差し替える（AzooKey 非同期到着用）。
    @MainActor
    func makeCandidatePanelModel() -> CandidatePanelModel {
        let session = handler.candidateSession
        return CandidatePanelModel(
            session: session,
            azooKeyFooter: AzooKeyFooterStatus.resolve(
                session: session,
                isAzooKeyPending: AzooKeyFooterStatus.isAzooKeyPending(
                    pendingReading: handler.pendingAzooKeyReading,
                    schedulerPending: azooKeyScheduler.hasPendingWork
                )
            )
        )
    }

    @MainActor
    func applyCandidateWindowEffects(
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        preferInPlaceRefresh: Bool = false
    ) {
        let panel = makeCandidatePanelModel()
        switch action {
        case .none:
            break
        case .deleteSelected:
            candidateWindow.apply(panel, layout: .refreshInPlace)
        case .dismiss:
            candidateWindow.apply(panel, layout: .dismiss)
        case .selectNext, .selectPrev:
            candidateWindow.apply(panel, layout: .selectionOnly)
        case .show:
            if preferInPlaceRefresh, candidateWindow.isPresented {
                candidateWindow.apply(panel, layout: .refreshInPlace)
            } else {
                candidateWindow.apply(panel, layout: .present(near: adapter.cursorRect()))
            }
        }
    }

    /// キー処理後の副作用。候補 / IMK は Core、ウィンドウ・POS は本ファイル。
    @MainActor
    private func applyPostKeyDownEffects(
        consumed: Bool,
        action: CandidateAction,
        adapter: IMKTextInputAdapter,
        composedHiraganaWasEmpty: Bool,
        imkSenderForSurrounding: Any?,
        keydownGeneration: Int
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
        // 候補ウィンドウは session の可視性に追随する。consumed=false 経路（矢印キー・Cmd+key 等）で
        // session が hidden になってもウィンドウだけ残るケースを潰す（ISSUE: 括弧モード+矢印キー）。
        if !handler.candidateSession.isVisible && candidateWindow.isVisible {
            candidateWindow.dismiss()
        }
        KeydownLatencySignpost.endPeekUpdate(
            generation: keydownGeneration,
            stats: handler.azooKeyConverter.latencyStats
        )

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
        handler.leftContext = LeftContextSource.resolveProduction(
            sessionBuffer: handler.sessionTextBuffer,
            cache: &handler.leftContextIMKCache,
            cursorLocation: adapter.selectedRange().location
        )
        warmRichCacheBeforeExplicitIfNeeded(keyCode: keyCode)
        let generation = azooKeyScheduler.onKeyDown()
        KeydownLatencySignpost.onKeyDown(generation: generation)
        let pre = KeyEventPipeline.preSnapshot(handler: handler)
        let keyResult = KeyEventPipeline.runHandle(
            handler: &handler,
            keyCode: keyCode,
            characters: characters,
            baseCharacters: baseCharacters,
            modifiers: modifiers,
            pre: pre,
            client: adapter
        )
        flushPendingInputRecord(penalized: handler.lastKeyDownDidPenalize)
        absorbPendingLogsFromHandler()
        applyPostKeyDownEffects(
            consumed: keyResult.consumed,
            action: keyResult.candidateAction,
            adapter: adapter,
            composedHiraganaWasEmpty: keyResult.composedHiraganaWasEmpty,
            imkSenderForSurrounding: imkSenderForSurrounding,
            keydownGeneration: generation
        )
        scheduleAzooKeyReplacementIfNeeded(
            generation: generation,
            consumed: keyResult.consumed,
            adapter: adapter
        )
        return keyResult.consumed
    }

    // MARK: - イベントハンドリング

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }

        // Caps Lock でモード切替（LED ON = 英字モード、LED OFF = 日本語モード）
        if event.type == .flagsChanged && event.keyCode == KeyCode.capsLock {
            handler.isAsciiMode = event.modifierFlags.contains(.capsLock)
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
            ic.cancelAzooKeyAsyncWork()
            let session = ic.handler.candidateSession
            guard !(
                session.isVisible
                    && ic.handler.state.composedHiragana.isEmpty
                    && !session.isBracketMode
            ) else { return }
            ic.handler.commitComposition(client: adapter, candidate: session.makeContext(), trigger: .deactivate)
            ic.flushPendingInputRecord()
            ic.absorbPendingLogsFromHandler()
            ic.flushPendingInputRecord()
            ic.handler.candidateSession.reset()
            LeftContextSource.resetCache(&ic.handler.leftContextIMKCache)
            ic.handler.leftContext = .empty
            ic.candidateWindow.dismiss()
        }
    }

    // MARK: - プライベートヘルパー

    private func flushPendingInputRecord(penalized: Bool = false) {
        guard let pending = pendingInputRecord else { return }
        let record = penalized ? pending.addingAnomaly("penalized") : pending
        inputQualityLogger.append(record: record, appVersion: AppVersion.logLabel)
        pendingInputRecord = nil
        tryFlushLatencyLog()
    }

    /// 確定ごとに latency セッションをフラッシュ試行（閾値未達なら no-op）。
    private func tryFlushLatencyLog() {
        handler.azooKeyConverter.latencyStats.appendToLog(
            fileURL: DatabaseManager.latencyLogURL,
            appVersion: AppVersion.logLabel
        )
    }

    private func absorbPendingLogsFromHandler() {
        let logs = KeyEventPipeline.drainPendingLogs(from: &handler)
        if let record = logs.sessionRecord {
            pendingInputRecord = record
        }
        if let divergence = logs.divergenceRecord {
            divergenceLogger.append(record: divergence, appVersion: AppVersion.logLabel)
        }
    }

}

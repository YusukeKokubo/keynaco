import Cocoa
import KeynacoCore
import InputMethodKit
import Carbon

nonisolated(unsafe) var gServer: IMKServer?

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var successorPendingObserver: NSObjectProtocol?
    private var misconversionIssueObserver: NSObjectProtocol?
    private var misconversionClearObserver: NSObjectProtocol?

    private var successorPending = false
    private var misconversionDetail: String?

    private var misconversionPopover: NSPopover?
    private var misconversionTextView: NSTextView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TISRegisterInputSource(Bundle.main.bundleURL as CFURL)

        guard
            let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
            let bundleID = Bundle.main.bundleIdentifier
        else {
            NSLog("keynaco: InputMethodConnectionName not found")
            return
        }
        gServer = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        #if DEBUG
        NSLog("keynaco: IMKServer started connection=\(connectionName) bundle=\(bundleID)")
        DebugSocketServer.shared.start()
        #endif
        setupMainMenu()
        setupStatusItem()
        Task.detached(priority: .background) {
            DatabaseManager.shared.performGCIfNeeded()
        }
        Task { @MainActor in
            InputController.performPOSBackfill()
        }
    }

    // アクセサリアプリはデフォルトでメインメニューを持たず Cmd+V/A 等が無視される。
    // Edit メニューを登録することでショートカットをレスポンダチェーン経由で届ける。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo",       #selector(UndoManager.undo),          "z"),
            ("Redo",       #selector(UndoManager.redo),          "Z"),
            ("Cut",        #selector(NSText.cut(_:)),            "x"),
            ("Copy",       #selector(NSText.copy(_:)),           "c"),
            ("Paste",      #selector(NSText.paste(_:)),          "v"),
            ("Select All", #selector(NSText.selectAll(_:)),      "a"),
        ] as [(String, Selector, String)] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            editMenu.addItem(item)
        }

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "⌨"

        successorPendingObserver = NotificationCenter.default.addObserver(
            forName: .keynacoSuccessorPendingChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pending = (note.userInfo?["pending"] as? Bool) ?? false
            MainActor.assumeIsolated { self?.applySuccessorPending(pending: pending) }
        }

        misconversionIssueObserver = NotificationCenter.default.addObserver(
            forName: .keynacoMisconversionIssueFound,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let s = note.userInfo?["detail"] as? String, !s.isEmpty {
                MainActor.assumeIsolated { self?.applyMisconversionIssue(detail: s) }
            }
        }

        misconversionClearObserver = NotificationCenter.default.addObserver(
            forName: .keynacoMisconversionCleared,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMisconversionCleared() }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let viewerItem = NSMenuItem(title: "イベントビューアー", action: #selector(openEventViewer), keyEquivalent: "")
        viewerItem.isEnabled = true
        menu.addItem(viewerItem)

        #if DEBUG
        let sandboxItem = NSMenuItem(title: "サンドボックス…", action: #selector(openIMESandbox), keyEquivalent: "")
        sandboxItem.isEnabled = true
        menu.addItem(sandboxItem)
        #endif

        let userDictItem = NSMenuItem(title: "ユーザー辞書...", action: #selector(openUserDict), keyEquivalent: "")
        userDictItem.isEnabled = true
        menu.addItem(userDictItem)

        statusMenu = menu
        statusItem?.menu = nil
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusBarButtonClicked(_:))
        statusItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        setupMisconversionPopover()
    }

    private func setupMisconversionPopover() {
        let pop = NSPopover()
        pop.behavior = .transient

        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        sv.drawsBackground = true
        sv.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.drawsBackground = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 300, height: 0)
        tv.maxSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        sv.documentView = tv

        let vc = NSViewController()
        vc.view = sv
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 320, height: 200)

        misconversionPopover = pop
        misconversionTextView = tv
    }

    private func applySuccessorPending(pending: Bool) {
        successorPending = pending
        updateStatusItemTitle()
    }

    private func applyMisconversionIssue(detail: String) {
        misconversionDetail = detail
        misconversionTextView?.string = detail
        updateStatusItemTitle()
    }

    private func applyMisconversionCleared() {
        misconversionDetail = nil
        misconversionPopover?.performClose(nil)
        updateStatusItemTitle()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        if misconversionDetail != nil {
            button.title = "⌨?"
        } else if successorPending {
            button.title = "⌨…"
        } else {
            button.title = "⌨"
        }
    }

    @objc private func statusBarButtonClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent,
              let button = statusItem?.button,
              let menu = statusMenu else { return }

        if event.type == .rightMouseDown {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }

        if misconversionDetail != nil {
            toggleMisconversionPopover(relativeTo: button)
        } else {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }

    private func toggleMisconversionPopover(relativeTo button: NSStatusBarButton) {
        guard let popover = misconversionPopover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let detail = misconversionDetail {
                misconversionTextView?.string = detail
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func openEventViewer() {
        EventViewerWindow.shared.show()
    }

    #if DEBUG
    @objc private func openIMESandbox() {
        IMESandboxWindow.shared.show()
    }
    #endif

    @objc private func openUserDict() {
        SettingsWindowController.shared.showSettings(selectingTab: 0)
    }
}

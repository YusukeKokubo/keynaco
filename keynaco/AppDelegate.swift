import Cocoa
import KeynacoCore
import InputMethodKit
import Carbon

nonisolated(unsafe) var gServer: IMKServer?

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    func applicationWillTerminate(_ notification: Notification) {
        guard SyncSettings.syncOnQuit,
              let _ = SyncSettings.nasPath else { return }
        let sema = DispatchSemaphore(value: 0)
        SyncSettings.exportToNAS { _, _ in sema.signal() }
        sema.wait()
    }

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
        Task.detached(priority: .background) {
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
    }

    @objc private func statusBarButtonClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent,
              let button = statusItem?.button,
              let menu = statusMenu else { return }

        NSMenu.popUpContextMenu(menu, with: event, for: button)
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

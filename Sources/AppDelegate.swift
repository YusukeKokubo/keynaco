import Cocoa
import InputMethodKit
import Carbon

nonisolated(unsafe) var gServer: IMKServer?

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

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
        NSLog("keynaco: IMKServer started connection=\(connectionName) bundle=\(bundleID)")
        setupMainMenu()
        setupStatusItem()
        Task.detached(priority: .background) {
            DatabaseManager.shared.performGCIfNeeded()
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "⌨"

        let menu = NSMenu()
        menu.autoenablesItems = false

        let viewerItem = NSMenuItem(title: "イベントビューアー", action: #selector(openEventViewer), keyEquivalent: "")
        viewerItem.isEnabled = true
        menu.addItem(viewerItem)

        let userDictItem = NSMenuItem(title: "ユーザー辞書...", action: #selector(openUserDict), keyEquivalent: "")
        userDictItem.isEnabled = true
        menu.addItem(userDictItem)

        statusItem?.menu = menu
    }

    @objc private func openEventViewer() {
        EventViewerWindow.shared.show()
    }

    @objc private func openUserDict() {
        SettingsWindowController.shared.showSettings(selectingTab: 1)
    }
}

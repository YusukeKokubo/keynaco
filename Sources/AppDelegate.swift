import Cocoa
import InputMethodKit

nonisolated(unsafe) var gServer: IMKServer?

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
            let bundleID = Bundle.main.bundleIdentifier
        else {
            NSLog("ykey: InputMethodConnectionName not found")
            return
        }
        gServer = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        NSLog("ykey: IMKServer started connection=\(connectionName) bundle=\(bundleID)")
        setupMainMenu()
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
}

import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    /// ウィンドウ終了時に `saveToDefaults` するため保持
    private weak var zenzaiViewController: ZenzaiViewController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "keynaco 設定"
        window.isReleasedWhenClosed = false

        let tabVC = NSTabViewController()
        tabVC.tabStyle = .segmentedControlOnTop

        let userDictItem = NSTabViewItem(viewController: UserDictViewController())
        userDictItem.label = "ユーザー辞書"
        let hiraganaPreferredItem = NSTabViewItem(viewController: HiraganaPreferredViewController())
        hiraganaPreferredItem.label = "ひらがな優先"
        let historyItem = NSTabViewItem(viewController: HistoryViewController())
        historyItem.label = "変換履歴"
        let zenzaiVC = ZenzaiViewController()
        let zenzaiItem = NSTabViewItem(viewController: zenzaiVC)
        zenzaiItem.label = "Zenzai"
        tabVC.addTabViewItem(userDictItem)
        tabVC.addTabViewItem(hiraganaPreferredItem)
        tabVC.addTabViewItem(historyItem)
        tabVC.addTabViewItem(zenzaiItem)

        window.contentViewController = tabVC
        super.init(window: window)
        window.delegate = self
        zenzaiViewController = zenzaiVC
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        zenzaiViewController?.saveToDefaults()
        NotificationCenter.default.post(name: .keynacoZenzaiSettingsDidChange, object: nil)
    }

    func showSettings(selectingTab index: Int? = nil) {
        if window?.isVisible == false { window?.center() }
        if let index, let tabVC = window?.contentViewController as? NSTabViewController {
            tabVC.selectedTabViewItemIndex = index
        }
        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// Delete キーを処理できる NSTableView
final class DeletableTableView: NSTableView {
    var onDeleteSelected: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 {
            onDeleteSelected?()
        } else {
            super.keyDown(with: event)
        }
    }
}

import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "keynaco 設定"
        window.isReleasedWhenClosed = false

        let tabVC = NSTabViewController()
        tabVC.tabStyle = .segmentedControlOnTop

        let bigramItem = NSTabViewItem(viewController: BigramViewController())
        bigramItem.label = "Bi-gram"
        let userDictItem = NSTabViewItem(viewController: UserDictViewController())
        userDictItem.label = "ユーザー辞書"
        let historyItem = NSTabViewItem(viewController: HistoryViewController())
        historyItem.label = "変換履歴"
        tabVC.addTabViewItem(bigramItem)
        tabVC.addTabViewItem(userDictItem)
        tabVC.addTabViewItem(historyItem)

        window.contentViewController = tabVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

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

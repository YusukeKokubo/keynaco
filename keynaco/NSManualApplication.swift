import Cocoa

/// InputMethodKit の慣例に従い NSApplication をカスタムサブクラスで起動する
@objc(NSManualApplication)
class NSManualApplication: NSApplication {
    private let appDelegate = AppDelegate()

    override init() {
        super.init()
        self.delegate = appDelegate
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

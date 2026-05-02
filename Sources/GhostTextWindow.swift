import AppKit

@MainActor
final class GhostTextWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private(set) var currentText: String?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        label.font = .systemFont(ofSize: 15)
        label.textColor = .tertiaryLabelColor
        label.backgroundColor = .clear
        label.isBordered = false
        contentView?.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -2),
        ])
    }

    func show(text: String, composingText: String, near cursorRect: NSRect) {
        currentText = text
        label.stringValue = text
        label.sizeToFit()
        let width = label.frame.width + 4
        let height: CGFloat = 20
        // cursorRect は composition 先頭の位置。composingText の幅を計測して末尾へオフセットする。
        let composingWidth = (composingText as NSString).size(
            withAttributes: [.font: label.font as Any]
        ).width
        let anchor = resolveAnchor(cursorRect: cursorRect)
        var origin = NSPoint(x: anchor.x + composingWidth + 2, y: anchor.y)
        if let screen = NSScreen.main,
           origin.x + width > screen.visibleFrame.maxX {
            origin.x = anchor.x - width - 2
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        orderFront(nil)
    }

    // cursorRect がゼロ（Electron 等で未実装）の場合はマウス位置に fallback
    private func resolveAnchor(cursorRect: NSRect) -> NSPoint {
        if cursorRect != .zero && cursorRect.width + cursorRect.height > 0 {
            return NSPoint(x: cursorRect.maxX, y: cursorRect.minY)
        }
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x, y: mouse.y - 22)
    }

    func dismiss() {
        currentText = nil
        label.stringValue = ""
        orderOut(nil)
    }
}

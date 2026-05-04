#if DEBUG

import AppKit

extension Notification.Name {
    /// `InputController` が keyDown 処理完了後に内部状態を通知するときに使う（Debug のみ）。
    static let imeStateDidUpdate = Notification.Name("com.yusuke.inputmethod.keynaco.imeStateDidUpdate")
}

/// 左ペインで通常入力し、右ペインに IME 内部状態を表示するデバッグ用ウィンドウ。
@MainActor
final class IMESandboxWindow: NSWindow {
    static let shared = IMESandboxWindow()

    private var stateObserver: NSObjectProtocol?

    private let leftTextView = NSTextView(frame: .zero)
    private let rightTextView = NSTextView(frame: .zero)

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "IME Sandbox"
        isReleasedWhenClosed = false
        setupUI()

        stateObserver = NotificationCenter.default.addObserver(
            forName: .imeStateDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let snap = note.userInfo?["snapshot"] as? InputHandlerSnapshot else { return }
            self?.rightTextView.string = Self.formatSnapshot(snap)
        }
    }

    private func setupUI() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        let split = NSSplitView()
        split.dividerStyle = .thin
        split.isVertical = true
        split.translatesAutoresizingMaskIntoConstraints = false
        split.autosaveName = "IMESandboxSplit"

        let leftScroll = NSScrollView()
        configureEditorScroll(leftScroll, textView: leftTextView, editable: true)
        let rightScroll = NSScrollView()
        configureEditorScroll(rightScroll, textView: rightTextView, editable: false)

        split.addSubview(leftScroll)
        split.addSubview(rightScroll)

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func configureEditorScroll(_ scroll: NSScrollView, textView: NSTextView, editable: Bool) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.font = editable
            ? .systemFont(ofSize: 13)
            : .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
    }

    func show() {
        if !isVisible { center() }
        level = .floating
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private nonisolated static func formatSnapshot(_ snap: InputHandlerSnapshot) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())

        var lines: [String] = []
        lines.append("【組成】")
        lines.append("composedHiragana : \(snap.composedHiragana)")
        lines.append("pendingRomaji    : \(snap.pendingRomaji)")
        lines.append("composingText    : \(snap.composingText)")
        // セグメントモードでは markedText は attributed をプレーン化したもののみ（見た目の区切りは segmentTexts を参照）。
        lines.append("markedText       : \(snap.markedText)")

        lines.append("")
        lines.append("【モード】")
        lines.append("isAsciiMode           : \(snap.isAsciiMode)")
        lines.append("isSuccessorMode       : \(snap.isSuccessorMode)")
        lines.append("isSegmentMode         : \(snap.isSegmentMode)")
        lines.append("isBracketMode         : \(snap.isBracketMode)")
        lines.append("isExplicitlySelected  : \(snap.isExplicitlySelected)")

        lines.append("")
        lines.append("【候補】")
        lines.append("visible          : \(snap.candidateVisible)")
        lines.append("selectedRow      : \(snap.selectedRow)")
        lines.append("selectedText     : \(snap.selectedText ?? "(nil)")")
        lines.append("historyEnd       : \(snap.historyEnd)")
        lines.append("fixedEnd         : \(snap.fixedEnd)")
        for (i, c) in snap.candidates.enumerated() {
            let mark = i == snap.selectedRow ? " ★" : ""
            lines.append("[\(i)] \(c)\(mark)")
        }

        lines.append("")
        lines.append("【確定履歴】")
        lines.append("committedHistory : \(snap.committedHistory)")

        if snap.isSegmentMode {
            lines.append("")
            lines.append("【セグメント】")
            lines.append("segments        : \(snap.segmentTexts.joined(separator: " | "))")
            lines.append("focusedIndex    : \(snap.focusedSegmentIndex)")
        }

        lines.append("")
        lines.append("更新: \(ts) keyDown")
        return lines.joined(separator: "\n")
    }
}

#endif

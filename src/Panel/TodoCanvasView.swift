import AppKit

/// 浮窗内列表的布局常量
enum NoteTheme {
    static let circleSize: CGFloat = 16
    static let leftInset: CGFloat = 34
    static let circleTextGap: CGFloat = 12
    static let rightInset: CGFloat = 16
    static let topInset: CGFloat = 46
    /// 行与行之间的留白（日期改到悬停气泡里后，行高只剩正文）
    static let rowGap: CGFloat = 9
    /// 列表自身顶部留白（列表滚动区已经整体下移到顶栏下方）
    static let canvasTopInset: CGFloat = 10

    static var textLeft: CGFloat { leftInset + circleSize + circleTextGap }
}

struct RowLayout {
    var y: CGFloat
    var textHeight: CGFloat
    var height: CGFloat
    var textWidth: CGFloat
}

/// 编辑用文本框：Esc 结束编辑；Enter 提交并跳到下一条（不插入换行，长文本只自动折行）。
/// 用 insertNewline 而不是拦 keyDown，中文输入法回车选词时不会被误判成「下一条」。
final class TodoTextEditor: NSTextView {
    var onEscape: (() -> Void)?
    var onCommitAndNext: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        onCommitAndNext?()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        onCommitAndNext?()
    }
}

final class TodoCanvasView: NSView, NSTextViewDelegate {
    private(set) var store: TodoStore
    private var currentTab: TodoTab

    var onEditingChanged: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onRequestTab: ((TodoTab) -> Void)?

    private(set) var contentHeight: CGFloat = 0
    private var rows: [UUID: RowLayout] = [:]
    private var order: [UUID] = []
    private var editor: TodoTextEditor?
    private var editingID: UUID?
    private var hoveredRow: UUID?
    private var hoveredCircleRow: UUID?
    private var hoverTracking: NSTrackingArea?
    private let dateBubble = DateBubbleController()
    private var dragStartScreen: NSPoint?
    private var lastDragScreen: NSPoint?
    private var didDrag = false
    private var isEndingEditing = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var tab: TodoTab { currentTab }

    // 自检钩子（只读）
    var isEditing: Bool { editingID != nil }
    var activeEditor: NSTextView? { editor }

    /// 第 index 行圆圈的可点区域（画布坐标），供交互自检定位
    func circleRectForRow(at index: Int) -> NSRect? {
        guard index >= 0, index < order.count, let row = rows[order[index]] else { return nil }
        return NSRect(x: NoteTheme.leftInset,
                      y: row.y + max(0, (lineHeight - NoteTheme.circleSize) / 2) + 1,
                      width: NoteTheme.circleSize,
                      height: NoteTheme.circleSize)
    }

    init(store: TodoStore, tab: TodoTab) {
        self.store = store
        self.currentTab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 520))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// 应用不在前台时第一次点击也要立刻响应
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var font: NSFont { NSFont.systemFont(ofSize: AppSettings.shared.fontSize) }

    private var lineHeight: CGFloat {
        let f = font
        return ceil(f.ascender - f.descender + f.leading)
    }

    // MARK: - 布局

    func setTab(_ newTab: TodoTab) {
        guard newTab != currentTab else { return }
        hideDateBubble()
        endEditing(commit: true)
        currentTab = newTab
        reflow()
        needsDisplay = true
    }

    func reflow() {
        let width = bounds.width
        guard width > 40 else { return }
        let textWidth = max(80, width - NoteTheme.textLeft - NoteTheme.rightInset)
        let f = font

        var newRows: [UUID: RowLayout] = [:]
        var newOrder: [UUID] = []
        var y = NoteTheme.canvasTopInset

        for item in store.items(for: currentTab) {
            let h = measuredHeight(item.text, font: f, width: textWidth)
            let rowH = h + NoteTheme.rowGap
            newRows[item.id] = RowLayout(y: y, textHeight: h, height: rowH, textWidth: textWidth)
            newOrder.append(item.id)
            y += rowH
        }

        rows = newRows
        order = newOrder
        contentHeight = y + 26

        let minHeight = enclosingScrollView?.contentSize.height ?? 0
        let target = max(contentHeight, minHeight)
        if abs(frame.height - target) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: target))
        }
        positionEditor()
        needsDisplay = true
    }

    private func measuredHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let body = text.isEmpty ? " " : text
        let attr = NSAttributedString(string: body, attributes: [.font: font])
        let rect = attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        var h = ceil(rect.height)
        if text.hasSuffix("\n") { h += lineHeight }
        return max(h, lineHeight)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 40 else { return }
        let settings = AppSettings.shared
        let textColor = settings.textColor
        let lh = lineHeight

        if order.isEmpty && editingID == nil {
            drawPlaceholder()
            return
        }

        for id in order {
            guard let item = store.item(id: id), let row = rows[id] else { continue }

            if hoveredRow == id {
                let highlight = NSRect(x: 14, y: row.y - 4, width: bounds.width - 28, height: row.height)
                let path = NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8)
                settings.chromeFillColor.setFill()
                path.fill()
            }

            let circleRect = NSRect(x: NoteTheme.leftInset,
                                   y: row.y + max(0, (lh - NoteTheme.circleSize) / 2) + 1,
                                   width: NoteTheme.circleSize,
                                   height: NoteTheme.circleSize)
            drawCircle(in: circleRect, completed: item.completed, color: textColor)

            if editingID != id {
                let attr = attributedText(item.text, completed: item.completed)
                attr.draw(with: NSRect(x: NoteTheme.textLeft, y: row.y, width: row.textWidth, height: row.textHeight + 2),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            }

        }
    }

    private func attributedText(_ text: String, completed: Bool) -> NSAttributedString {
        let settings = AppSettings.shared
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: completed ? settings.secondaryTextColor : settings.textColor,
            .paragraphStyle: para
        ]
        if completed {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = settings.secondaryTextColor.withAlphaComponent(0.55)
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func drawCircle(in rect: NSRect, completed: Bool, color: NSColor) {
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        if completed {
            color.setFill()
            ring.fill()
            let check = NSBezierPath()
            check.lineWidth = 1.9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + 4.0, y: rect.midY + 0.4))
            check.line(to: NSPoint(x: rect.minX + 6.6, y: rect.midY + 3.1))
            check.line(to: NSPoint(x: rect.minX + 12.2, y: rect.midY - 3.3))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            let hovered = hoveredRow != nil
            color.withAlphaComponent(hovered ? 0.85 : 0.5).setStroke()
            ring.lineWidth = 1.3
            ring.stroke()
        }
    }

    private func drawPlaceholder() {
        let settings = AppSettings.shared
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: settings.secondaryTextColor.withAlphaComponent(0.5)
        ]
        let text = currentTab.emptyHint
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: NoteTheme.canvasTopInset + 40),
                                withAttributes: attrs)
    }

    // MARK: - 编辑

    private func beginEditing(_ id: UUID) {
        hideDateBubble()
        endEditing(commit: true)
        guard let item = store.item(id: id), let row = rows[id] else { return }

        editingID = id
        let ed = TodoTextEditor(frame: NSRect(x: NoteTheme.textLeft, y: row.y,
                                              width: row.textWidth, height: max(row.textHeight, lineHeight + 2)))
        configure(ed)
        ed.onEscape = { [weak self] in self?.endEditing(commit: true) }
        ed.onCommitAndNext = { [weak self] in self?.commitAndStartNext() }
        ed.delegate = self
        ed.string = item.text
        addSubview(ed)
        editor = ed
        positionEditor()

        window?.makeFirstResponder(ed)
        ed.setSelectedRange(NSRange(location: (item.text as NSString).length, length: 0))
        onEditingChanged?(true)
        needsDisplay = true
    }

    private func configure(_ ed: TodoTextEditor) {
        ed.isRichText = false
        ed.importsGraphics = false
        ed.drawsBackground = false
        ed.textContainerInset = .zero
        ed.textContainer?.lineFragmentPadding = 0
        ed.textContainer?.widthTracksTextView = true
        ed.textContainer?.heightTracksTextView = false
        ed.isVerticallyResizable = true
        ed.isHorizontallyResizable = false
        ed.minSize = .zero
        ed.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ed.allowsUndo = true
        ed.isAutomaticQuoteSubstitutionEnabled = false
        ed.isAutomaticDashSubstitutionEnabled = false
        ed.isAutomaticTextReplacementEnabled = false
        ed.isAutomaticSpellingCorrectionEnabled = false
        ed.isContinuousSpellCheckingEnabled = false
        ed.isGrammarCheckingEnabled = false
        ed.font = font
        ed.textColor = AppSettings.shared.textColor
        ed.insertionPointColor = NSColor.controlAccentColor
    }

    private func positionEditor() {
        guard let id = editingID, let ed = editor, let row = rows[id] else { return }
        let height = max(row.textHeight, lineHeight + 2)
        ed.frame = NSRect(x: NoteTheme.textLeft, y: row.y, width: row.textWidth, height: height)
        _ = scrollToVisible(NSRect(x: 0, y: row.y - 10, width: 1, height: height + 24))
    }

    func endEditing(commit: Bool) {
        guard editingID != nil else { return }
        hideDateBubble()
        isEndingEditing = true
        let text = editor?.string ?? ""
        let id = editingID
        if commit, let id = id {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.delete(id: id)
            } else {
                store.update(id: id, text: text)
            }
            store.flush()
        }
        editingID = nil
        editor?.delegate = nil
        editor?.onEscape = nil
        editor?.removeFromSuperview()
        editor = nil
        isEndingEditing = false
        onEditingChanged?(false)
        reflow()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func textDidChange(_ notification: Notification) {
        guard !isEndingEditing, let id = editingID, let ed = editor else { return }
        store.update(id: id, text: ed.string)
        reflow()
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isEndingEditing else { return }
        endEditing(commit: true)
    }

    /// 回车：先把当前条目落盘，再在末尾起一条新的继续输入（不产生换行）
    private func commitAndStartNext() {
        guard !isEndingEditing, editingID != nil else { return }
        let text = editor?.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 空条目上按回车不继续堆空行
            return
        }
        endEditing(commit: true)
        createNewItem()
    }

    /// 供外部（隐藏浮窗、切换视图）主动收起日期气泡
    func hideDateBubble() {
        hoveredCircleRow = nil
        dateBubble.hide()
    }

    private func createNewItem() {
        endEditing(commit: true)
        let item = store.add(text: "")
        if !store.contains(tab: currentTab, item: item) {
            onRequestTab?(.pending)
        } else {
            reflow()
        }
        beginEditing(item.id)
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let sv = enclosingScrollView else { return }
        let maxY = max(0, contentHeight - sv.contentSize.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: - 命中测试

    private func row(at point: NSPoint) -> (UUID, RowLayout)? {
        guard point.y > NoteTheme.canvasTopInset - 8 else { return nil }
        for id in order {
            guard let row = rows[id] else { continue }
            if point.y >= row.y - 3 && point.y <= row.y + row.height {
                return (id, row)
            }
        }
        return nil
    }

    private func circleRect(for row: RowLayout) -> NSRect {
        NSRect(x: NoteTheme.leftInset - 4,
               y: row.y + max(0, (lineHeight - NoteTheme.circleSize) / 2) - 3,
               width: NoteTheme.circleSize + 8,
               height: NoteTheme.circleSize + 8)
    }

    private func textRect(for row: RowLayout) -> NSRect {
        NSRect(x: NoteTheme.textLeft,
               y: row.y - 2,
               width: row.textWidth + 4,
               height: row.textHeight + 4)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)

        if let (id, row) = row(at: point), editingID != id, circleRect(for: row).contains(point) {
            store.toggle(id: id)
            store.flush()
            reflow()
            needsDisplay = true
            return
        }

        if let (id, _) = row(at: point), editingID != id {
            beginEditing(id)
            return
        }

        dragStartScreen = NSEvent.mouseLocation
        lastDragScreen = dragStartScreen
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartScreen, let last = lastDragScreen, let window = window else { return }
        let location = NSEvent.mouseLocation
        if !didDrag {
            guard hypot(location.x - start.x, location.y - start.y) > 3 else { return }
            didDrag = true
        }
        var origin = window.frame.origin
        origin.x += location.x - last.x
        origin.y += location.y - last.y
        window.setFrameOrigin(origin)
        lastDragScreen = location
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartScreen = nil
            lastDragScreen = nil
            didDrag = false
        }
        guard !didDrag else { return }
        createNewItem()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hideDateBubble()
        if hoveredRow != nil {
            hoveredRow = nil
            needsDisplay = true
        }
    }

    /// 滚动时行位置变了，气泡跟着收起，避免气泡飘在错误的位置
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipViewDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: clip)
    }

    @objc private func clipViewDidScroll() {
        hideDateBubble()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateHover(with point: NSPoint) {
        let newValue = row(at: point)?.0
        if newValue != hoveredRow {
            hoveredRow = newValue
            needsDisplay = true
        }

        // 鼠标压在圆圈上时，在圆圈左侧弹日期气泡
        var circleRow: UUID?
        if let (id, row) = row(at: point), circleHitRect(for: row).contains(point) {
            circleRow = id
        }
        hoveredCircleRow = circleRow
        if let id = circleRow, let item = store.item(id: id), let row = rows[id] {
            dateBubble.show(date: item.createdAt, anchorInScreen: screenRect(for: circleRect(for: row)))
        } else {
            dateBubble.hide()
        }
    }

    /// 画布坐标 → 屏幕坐标（气泡是独立窗口，必须换算）
    private func screenRect(for rect: NSRect) -> NSRect {
        let inWindow = convert(rect, to: nil)
        guard let window = window else { return inWindow }
        return window.convertToScreen(inWindow)
    }

    /// 圆圈的可点击外扩区域（比绘制圆略大，方便悬停命中）
    private func circleHitRect(for row: RowLayout) -> NSRect {
        circleRect(for: row).insetBy(dx: -4, dy: -4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

import AppKit

/// 翻转坐标的 clip view：让列表从顶部开始滚动
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// 浮窗内容根视图：负责圆角底板、滚动列表和悬停浮层的组装。
final class TodoContentView: NSView {
    let canvas: TodoCanvasView
    let chrome: ChromeOverlayView
    private let scrollView = NSScrollView()
    private let resizeEdges = ResizeEdgeView()
    private var hoverInside = false
    private var editing = false

    var onClose: (() -> Void)?
    /// 设置页切换「允许调整大小」后，通知控制器同步窗口样式
    var onResizePolicyChange: (() -> Void)?

    /// 是否允许鼠标拖拽改变浮窗大小
    var resizingEnabled: Bool {
        get { resizeEdges.resizingEnabled }
        set { resizeEdges.resizingEnabled = newValue }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    init(store: TodoStore) {
        // 默认「今日」；用户切过视图就记住，下次打开接着上次的视图
        canvas = TodoCanvasView(store: store, tab: AppSettings.shared.lastTab)
        chrome = ChromeOverlayView()
        super.init(frame: NSRect(origin: .zero, size: TodoPanelController.defaultSize))
        setup()
    }

    private func setup() {
        scrollView.frame = listFrame
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed

        let clip = FlippedClipView()
        clip.frame = scrollView.bounds
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas

        addSubview(scrollView)

        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)

        // 边缘缩放层放最上层：只在贴近窗口边缘 7pt 时接管鼠标，其余位置事件照常下传
        resizeEdges.frame = bounds
        resizeEdges.autoresizingMask = [.width, .height]
        addSubview(resizeEdges)

        chrome.selectedTab = canvas.tab

        canvas.onEditingChanged = { [weak self] isEditing in
            guard let self = self else { return }
            self.editing = isEditing
            self.refreshChrome()
        }
        canvas.onEscape = { [weak self] in self?.onClose?() }
        canvas.onRequestTab = { [weak self] tab in self?.setTab(tab) }
        chrome.onSelect = { [weak self] tab in self?.setTab(tab) }
        chrome.onClose = { [weak self] in self?.onClose?() }
        chrome.onHover = { [weak self] inside in
            guard let self = self else { return }
            self.hoverInside = inside
            self.refreshChrome()
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsChanged),
                                               name: AppSettings.didChange,
                                               object: nil)
        applySettings()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var listFrame: NSRect {
        NSRect(x: 0,
               y: NoteTheme.topInset,
               width: bounds.width,
               height: max(0, bounds.height - NoteTheme.topInset))
    }

    override func layout() {
        super.layout()
        scrollView.frame = listFrame
        let clipSize = scrollView.contentSize
        if abs(canvas.frame.width - clipSize.width) > 0.5 {
            canvas.setFrameSize(NSSize(width: clipSize.width, height: max(canvas.frame.height, clipSize.height)))
        }
        if abs(canvas.frame.height - max(canvas.contentHeight, clipSize.height)) > 0.5 {
            canvas.reflow()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let settings = AppSettings.shared
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        settings.backgroundColor.setFill()
        path.fill()
        settings.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func setTab(_ tab: TodoTab) {
        canvas.setTab(tab)
        chrome.selectedTab = tab
        // 记住用户的选择，下次打开浮窗沿用
        AppSettings.shared.lastTab = tab
        refreshChrome()
    }

    func refreshChrome() {
        chrome.isActive = hoverInside || editing
    }

    /// 供离屏快照强制展示浮层
    func setChromeActive(_ active: Bool) {
        hoverInside = active
        refreshChrome()
    }

    func focus() {
        window?.makeFirstResponder(canvas)
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    func applySettings() {
        let settings = AppSettings.shared
        // 「允许调整大小」开关变化时，通知控制器更新窗口 styleMask
        if settings.resizablePanel != resizingEnabled {
            onResizePolicyChange?()
        }
        window?.alphaValue = settings.opacity
        canvas.reflow()
        canvas.needsDisplay = true
        chrome.needsDisplay = true
        needsDisplay = true
    }
}

import AppKit

/// 浮窗顶部的 tab / 关闭按钮。默认隐藏，鼠标进入时出现。（透明度已移到设置页）
final class ChromeOverlayView: NSView {
    var selectedTab: TodoTab = .pending {
        didSet { needsDisplay = true }
    }

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            alphaValue = isActive ? 1 : 0
            needsDisplay = true
        }
    }

    var onSelect: ((TodoTab) -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var tabRects: [(TodoTab, NSRect)] = []
    private var barRect: NSRect = .zero
    private var closeRect: NSRect = .zero
    private var hoveringClose = false
    private var hoverTracking: NSTrackingArea?
    private var laidOutWidth: CGFloat = -1

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        recomputeLayout()
    }

    private func recomputeLayout() {
        let width = bounds.width
        guard width > 40, laidOutWidth != width else { return }
        laidOutWidth = width

        barRect = NSRect(x: 8, y: 6, width: max(0, width - 16), height: 32)

        tabRects = []
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        var x = barRect.minX + 8
        for tab in TodoTab.allCases {
            let textWidth = ceil((tab.title as NSString).size(withAttributes: [.font: font]).width)
            let itemWidth = textWidth + 16
            tabRects.append((tab, NSRect(x: x, y: barRect.minY + 3, width: itemWidth, height: barRect.height - 6)))
            x += itemWidth + 1
        }

        closeRect = NSRect(x: barRect.maxX - 26, y: barRect.midY - 9, width: 18, height: 18)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        recomputeLayout()
        guard bounds.width > 40 else { return }
        let settings = AppSettings.shared
        let textColor = settings.textColor

        // 顶部条
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 11, yRadius: 11)
        settings.chromeFillColor.setFill()
        barPath.fill()

        for (tab, rect) in tabRects {
            let selected = tab == selectedTab
            if selected {
                let pill = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                textColor.withAlphaComponent(0.12).setFill()
                pill.fill()
            }
            let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
            let color = selected ? textColor : textColor.withAlphaComponent(0.5)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (tab.title as NSString).size(withAttributes: attrs)
            (tab.title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                        withAttributes: attrs)
        }

        // 关闭按钮
        if hoveringClose {
            let bg = NSBezierPath(roundedRect: closeRect, xRadius: 6, yRadius: 6)
            textColor.withAlphaComponent(0.10).setFill()
            bg.fill()
        }
        drawCloseGlyph(color: textColor.withAlphaComponent(hoveringClose ? 0.9 : 0.5))
    }

    private func drawCloseGlyph(color: NSColor) {
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.4
        glyph.lineCapStyle = .round
        let r = closeRect.insetBy(dx: 5.5, dy: 5.5)
        glyph.move(to: NSPoint(x: r.minX, y: r.minY))
        glyph.line(to: NSPoint(x: r.maxX, y: r.maxY))
        glyph.move(to: NSPoint(x: r.maxX, y: r.minY))
        glyph.line(to: NSPoint(x: r.minX, y: r.maxY))
        color.setStroke()
        glyph.stroke()
    }

    // MARK: - 命中

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, alphaValue > 0.01, !isHidden else { return nil }
        recomputeLayout()
        let local = convert(point, from: superview)
        if barRect.contains(local) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        recomputeLayout()
        let point = convert(event.locationInWindow, from: nil)

        for (tab, rect) in tabRects where rect.contains(point) {
            onSelect?(tab)
            return
        }
        if closeRect.insetBy(dx: -4, dy: -4).contains(point) {
            onClose?()
            return
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovering = closeRect.insetBy(dx: -4, dy: -4).contains(point)
        if hovering != hoveringClose {
            hoveringClose = hovering
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveringClose {
            hoveringClose = false
            needsDisplay = true
        }
        onHover?(false)
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
}

import AppKit

final class DateBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 气泡本体：圆角底 + 等宽数字的日期文本
final class DateBubbleView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    static func attributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: AppSettings.shared.secondaryTextColor
        ]
    }

    func fittingSize() -> NSSize {
        let size = (text as NSString).size(withAttributes: DateBubbleView.attributes())
        return NSSize(width: ceil(size.width) + 18, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let settings = AppSettings.shared
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        // 气泡浮在卡片之外，需要比卡片底色略深一点才看得清
        settings.backgroundColor.blended(over: settings.textColor, fraction: 0.92).setFill()
        path.fill()
        settings.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs = DateBubbleView.attributes()
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}

/// 鼠标停在圆形勾选框上时，在圆圈左侧弹出的日期气泡（独立小窗口，可画到浮窗之外）
final class DateBubbleController {
    private let panel: DateBubblePanel
    private let view: DateBubbleView
    private var shownDate: Date?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init() {
        panel = DateBubblePanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 22),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        view = DateBubbleView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
    }

    var isVisible: Bool { panel.isVisible }

    /// anchor 是圆圈的屏幕坐标矩形
    func show(date: Date, anchorInScreen anchor: NSRect) {
        let text = formatter.string(from: date)
        if view.text != text || view.frame.size != view.fittingSize() {
            view.text = text
            view.frame = NSRect(origin: .zero, size: view.fittingSize())
        }
        shownDate = date
        let size = view.fittingSize()

        var origin = NSPoint(x: anchor.minX - 8 - size.width,
                             y: anchor.midY - size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame, origin.x < visible.minX + 4 {
            // 左边放不下就改到圆圈右侧
            origin.x = anchor.maxX + 8
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            // 应用不在前台时 orderFront 可能不显示，非激活浮窗必须用 orderFrontRegardless
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        shownDate = nil
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

import AppKit

/// 浮窗边缘缩放层：只在贴近窗口边缘的一圈接管鼠标，其余位置把事件透给下层视图。
/// borderless 窗口没有系统边框拖拽区，缩放必须自己接管。
final class ResizeEdgeView: NSView {
    private enum Edge {
        case left, right, bottom, top
    }

    var resizingEnabled: Bool = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private let grabZone: CGFloat = 7
    private var activeEdges: [Edge] = []
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard resizingEnabled, !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), !edges(at: local).isEmpty else { return nil }
        return self
    }

    private func edges(at point: NSPoint) -> [Edge] {
        var result: [Edge] = []
        if point.x <= grabZone { result.append(.left) }
        if point.x >= bounds.maxX - grabZone { result.append(.right) }
        if point.y <= grabZone { result.append(.top) }
        if point.y >= bounds.maxY - grabZone { result.append(.bottom) }
        return result
    }

    override func resetCursorRects() {
        guard resizingEnabled else { return }
        let left = NSRect(x: 0, y: 0, width: grabZone, height: bounds.height)
        let right = NSRect(x: bounds.maxX - grabZone, y: 0, width: grabZone, height: bounds.height)
        let top = NSRect(x: 0, y: 0, width: bounds.width, height: grabZone)
        let bottom = NSRect(x: 0, y: bounds.maxY - grabZone, width: bounds.width, height: grabZone)
        addCursorRect(left, cursor: .resizeLeftRight)
        addCursorRect(right, cursor: .resizeLeftRight)
        addCursorRect(top, cursor: .resizeUpDown)
        addCursorRect(bottom, cursor: .resizeUpDown)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, !activeEdges.isEmpty else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        let minSize = TodoPanelController.minSize

        var frame = startFrame
        if activeEdges.contains(.left) {
            let width = max(minSize.width, startFrame.width - dx)
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
        }
        if activeEdges.contains(.right) {
            frame.size.width = max(minSize.width, startFrame.width + dx)
        }
        if activeEdges.contains(.bottom) {
            let height = max(minSize.height, startFrame.height - dy)
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }
        if activeEdges.contains(.top) {
            frame.size.height = max(minSize.height, startFrame.height + dy)
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }
}

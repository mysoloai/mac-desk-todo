import AppKit

final class SettingsWindowController: NSWindowController {
    private let content: SettingsContentView

    static let contentSize = NSSize(width: 460, height: 818)

    init() {
        content = SettingsContentView(frame: NSRect(origin: .zero, size: SettingsWindowController.contentSize))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: AppSettings.shared.themePrefersDark ? .darkAqua : .aqua)
        super.init(window: window)
        window.delegate = self
        content.onDone = { [weak self] in self?.window?.close() }
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.window?.appearance = NSAppearance(named: AppSettings.shared.themePrefersDark ? .darkAqua : .aqua)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.orderOut(nil)
    }
}

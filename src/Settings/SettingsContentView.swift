import AppKit

/// 10 个预设色球，点击选取
final class ColorPaletteView: NSView {
    var selectedIndex: Int = 0 {
        didSet { needsDisplay = true }
    }
    var onPick: ((Int, NSColor) -> Void)?

    private let colors = AppSettings.presetColors
    private let diameter: CGFloat = 26
    private let gap: CGFloat = 12

    override var isFlipped: Bool { true }

    private func rect(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (diameter + gap),
               y: (bounds.height - diameter) / 2,
               width: diameter,
               height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in colors.enumerated() {
            let r = rect(at: index)
            let path = NSBezierPath(ovalIn: r)
            color.setFill()
            path.fill()

            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 1
            path.stroke()

            if index == selectedIndex {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3))
                let ringColor: NSColor = ColorPaletteView.isLight(color)
                    ? NSColor.black.withAlphaComponent(0.5)
                    : NSColor.white.withAlphaComponent(0.85)
                ringColor.setStroke()
                ring.lineWidth = 2.5
                ring.stroke()
            }
        }
    }

    static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.5
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for index in colors.indices where rect(at: index).insetBy(dx: -4, dy: -4).contains(point) {
            selectedIndex = index
            onPick?(index, colors[index])
            return
        }
    }
}

/// 字号实时预览框
final class SamplePreviewView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let settings = AppSettings.shared
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        settings.backgroundColor.setFill()
        path.fill()
        settings.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: settings.fontSize),
            .foregroundColor: settings.textColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: "这是一条字体大小测试文字", attributes: attrs)
        let inset: CGFloat = 24
        let available = NSSize(width: max(40, bounds.width - inset * 2), height: .greatestFiniteMagnitude)
        let bounding = attributed.boundingRect(with: available, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = ceil(bounding.height)
        attributed.draw(with: NSRect(x: inset, y: (bounds.height - height) / 2,
                                     width: bounds.width - inset * 2, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// 设置页：浮窗颜色（10 个预设 + 自定义圆盘取色）与字号（滑条 + 实时样例）
final class SettingsContentView: NSView {
    private let settings = AppSettings.shared
    private let palette = ColorPaletteView()
    private let colorWell = NSColorWell()
    private let slider = NSSlider()
    /// 由代码同步控件状态时置位，避免 AppKit 的控件回调把默认值反写进配置
    private var isSyncing = false
    private let sizeLabel = NSTextField(labelWithString: "15 pt")
    private let sample = SamplePreviewView()
    private let titleLabel = NSTextField(labelWithString: "设置")
    private let subtitleLabel = NSTextField(labelWithString: "主题、底色、透明度、字号与窗口行为，修改即时生效")
    private let themeSection = NSTextField(labelWithString: "主题")
    private let themeSegmented = NSSegmentedControl(labels: ["跟随系统", "浅色", "深色"],
                                                    trackingMode: .selectOne,
                                                    target: nil,
                                                    action: nil)
    private let dividerTheme = NSBox()
    private let opacitySection = NSTextField(labelWithString: "透明度")
    private let opacityValueLabel = NSTextField(labelWithString: "97%")
    private let opacitySlider = NSSlider()
    private let dividerOpacity = NSBox()
    private let colorSection = NSTextField(labelWithString: "浮窗颜色")
    private let customLabel = NSTextField(labelWithString: "自定义颜色")
    private let sizeSection = NSTextField(labelWithString: "字号")
    private let divider = NSBox()
    private let windowSection = NSTextField(labelWithString: "浮窗显示")
    private let resizeCheckbox = NSButton(checkboxWithTitle: "允许用鼠标拖拽调整浮窗大小", target: nil, action: nil)
    private let topmostCheckbox = NSButton(checkboxWithTitle: "浮窗始终置顶（悬浮在其他窗口之上）", target: nil, action: nil)
    private let divider2 = NSBox()
    private let divider3 = NSBox()
    private let launchSection = NSTextField(labelWithString: "启动与程序坞")
    private let launchCheckbox = NSButton(checkboxWithTitle: "开机自动启动（登录时自动运行速签）", target: nil, action: nil)
    private let dockCheckbox = NSButton(checkboxWithTitle: "在程序坞（Dock）中常驻图标", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "滑条可点选或拖拽，透明度与字号都会立刻反映到浮窗")
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    var onDone: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        NSColorPanel.shared.mode = .wheel

        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        for label in [colorSection, sizeSection, windowSection, themeSection, opacitySection, launchSection] {
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }

        customLabel.font = NSFont.systemFont(ofSize: 12)
        customLabel.textColor = .secondaryLabelColor

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .labelColor
        sizeLabel.alignment = .right

        themeSegmented.target = self
        themeSegmented.action = #selector(themeChanged)

        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        opacityValueLabel.textColor = .labelColor
        opacityValueLabel.alignment = .right

        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = Double(settings.opacity)
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)

        dividerTheme.boxType = .separator
        dividerOpacity.boxType = .separator

        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor

        palette.onPick = { [weak self] index, color in
            guard let self = self else { return }
            self.settings.backgroundColor = color
            self.colorWell.color = color
        }

        // 先赋初值再挂 action：避免 NSColorWell 与 NSColorPanel 同步时把旧色反写进配置
        colorWell.color = settings.backgroundColor
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)
        colorWell.isContinuous = true

        slider.minValue = 12
        slider.maxValue = 30
        slider.doubleValue = Double(settings.fontSize)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        resizeCheckbox.font = NSFont.systemFont(ofSize: 12)
        resizeCheckbox.contentTintColor = .labelColor
        resizeCheckbox.target = self
        resizeCheckbox.action = #selector(resizeToggleChanged)

        topmostCheckbox.font = NSFont.systemFont(ofSize: 12)
        topmostCheckbox.contentTintColor = .labelColor
        topmostCheckbox.target = self
        topmostCheckbox.action = #selector(topmostToggleChanged)

        launchCheckbox.font = NSFont.systemFont(ofSize: 12)
        launchCheckbox.contentTintColor = .labelColor
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchToggleChanged)

        dockCheckbox.font = NSFont.systemFont(ofSize: 12)
        dockCheckbox.contentTintColor = .labelColor
        dockCheckbox.target = self
        dockCheckbox.action = #selector(dockToggleChanged)

        divider.boxType = .separator
        divider2.boxType = .separator
        divider3.boxType = .separator

        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        for view in [titleLabel, subtitleLabel, themeSection, themeSegmented, dividerTheme,
                     colorSection, palette, customLabel, colorWell, divider,
                     opacitySection, opacityValueLabel, opacitySlider, dividerOpacity,
                     windowSection, resizeCheckbox, topmostCheckbox, divider2,
                     sizeSection, sizeLabel, slider, sample,
                     divider3, launchSection, launchCheckbox, dockCheckbox,
                     footerLabel, doneButton] {
            addSubview(view)
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsChanged),
                                               name: AppSettings.didChange,
                                               object: nil)
        syncControls()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let inset: CGFloat = 28
        let contentWidth = width - inset * 2

        titleLabel.frame = NSRect(x: inset, y: 22, width: contentWidth, height: 26)
        subtitleLabel.frame = NSRect(x: inset, y: 52, width: contentWidth, height: 16)

        themeSection.frame = NSRect(x: inset, y: 88, width: contentWidth, height: 16)
        themeSegmented.frame = NSRect(x: inset, y: 110, width: 240, height: 24)

        dividerTheme.frame = NSRect(x: inset, y: 150, width: contentWidth, height: 1)

        colorSection.frame = NSRect(x: inset, y: 164, width: contentWidth, height: 16)
        palette.frame = NSRect(x: inset, y: 186, width: 10 * 26 + 9 * 12, height: 28)
        customLabel.frame = NSRect(x: inset, y: 228, width: 100, height: 16)
        colorWell.frame = NSRect(x: inset + 84, y: 222, width: 54, height: 26)

        divider.frame = NSRect(x: inset, y: 262, width: contentWidth, height: 1)

        opacitySection.frame = NSRect(x: inset, y: 276, width: 80, height: 16)
        opacityValueLabel.frame = NSRect(x: width - inset - 120, y: 274, width: 120, height: 18)
        opacitySlider.frame = NSRect(x: inset, y: 302, width: contentWidth, height: 24)

        dividerOpacity.frame = NSRect(x: inset, y: 342, width: contentWidth, height: 1)

        windowSection.frame = NSRect(x: inset, y: 356, width: contentWidth, height: 16)
        resizeCheckbox.frame = NSRect(x: inset, y: 378, width: contentWidth, height: 20)
        topmostCheckbox.frame = NSRect(x: inset, y: 400, width: contentWidth, height: 20)

        divider2.frame = NSRect(x: inset, y: 428, width: contentWidth, height: 1)

        sizeSection.frame = NSRect(x: inset, y: 444, width: 80, height: 16)
        sizeLabel.frame = NSRect(x: width - inset - 120, y: 442, width: 120, height: 18)

        slider.frame = NSRect(x: inset, y: 470, width: contentWidth, height: 24)
        sample.frame = NSRect(x: inset, y: 506, width: contentWidth, height: 132)

        divider3.frame = NSRect(x: inset, y: 650, width: contentWidth, height: 1)
        launchSection.frame = NSRect(x: inset, y: 664, width: contentWidth, height: 16)
        launchCheckbox.frame = NSRect(x: inset, y: 688, width: contentWidth, height: 20)
        dockCheckbox.frame = NSRect(x: inset, y: 714, width: contentWidth, height: 20)

        footerLabel.frame = NSRect(x: inset, y: 744, width: contentWidth, height: 16)
        doneButton.frame = NSRect(x: width - inset - 84, y: 770, width: 84, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    private func syncControls() {
        isSyncing = true
        defer { isSyncing = false }
        resizeCheckbox.state = settings.resizablePanel ? .on : .off
        topmostCheckbox.state = settings.alwaysOnTopPanel ? .on : .off
        launchCheckbox.state = settings.launchAtLogin ? .on : .off
        dockCheckbox.state = settings.dockIconEnabled ? .on : .off
        if settings.hasExplicitColor {
            // 挑过自定义底色时主题是「都不选」状态，点任一主题会回到该主题底色
            themeSegmented.selectedSegment = -1
        } else {
            switch settings.themeMode {
            case .system: themeSegmented.selectedSegment = 0
            case .light: themeSegmented.selectedSegment = 1
            case .dark: themeSegmented.selectedSegment = 2
            }
        }
        opacitySlider.doubleValue = Double(settings.opacity)
        opacityValueLabel.stringValue = "\(Int(round(settings.opacity * 100)))%"
        slider.doubleValue = Double(settings.fontSize)
        sizeLabel.stringValue = "\(Int(round(settings.fontSize))) pt"
        colorWell.color = settings.backgroundColor

        if settings.hasExplicitColor,
           let index = AppSettings.presetColors.firstIndex(where: { $0.hexString == settings.backgroundColor.hexString }) {
            palette.selectedIndex = index
        } else {
            palette.selectedIndex = -1
        }
        sample.needsDisplay = true
        palette.needsDisplay = true
    }

    @objc private func themeChanged() {
        guard !isSyncing else { return }
        switch themeSegmented.selectedSegment {
        case 1: settings.themeMode = .light
        case 2: settings.themeMode = .dark
        default: settings.themeMode = .system
        }
    }

    @objc private func opacityChanged() {
        guard !isSyncing else { return }
        settings.opacity = CGFloat(opacitySlider.doubleValue)
        opacityValueLabel.stringValue = "\(Int(round(opacitySlider.doubleValue * 100)))%"
    }

    @objc private func resizeToggleChanged() {
        guard !isSyncing else { return }
        settings.resizablePanel = (resizeCheckbox.state == .on)
    }

    @objc private func topmostToggleChanged() {
        guard !isSyncing else { return }
        settings.alwaysOnTopPanel = (topmostCheckbox.state == .on)
    }

    @objc private func launchToggleChanged() {
        guard !isSyncing else { return }
        settings.launchAtLogin = (launchCheckbox.state == .on)
    }

    @objc private func dockToggleChanged() {
        guard !isSyncing else { return }
        settings.dockIconEnabled = (dockCheckbox.state == .on)
    }

    @objc private func sliderChanged() {
        guard !isSyncing else { return }
        let value = CGFloat(round(slider.doubleValue))
        settings.fontSize = value
        sizeLabel.stringValue = "\(Int(value)) pt"
    }

    @objc private func colorWellChanged() {
        guard !isSyncing else { return }
        settings.backgroundColor = colorWell.color
        if let index = AppSettings.presetColors.firstIndex(where: { $0.hexString == colorWell.color.hexString }) {
            palette.selectedIndex = index
        } else {
            palette.selectedIndex = -1
        }
    }

    @objc private func doneTapped() {
        onDone?()
    }

    @objc private func settingsChanged() {
        syncControls()
    }
}

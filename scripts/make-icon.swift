import AppKit

// 用法: swift scripts/make-icon.swift <输出 1024x1024 PNG 路径>
// 生成 Dock 图标源图：暖白圆角板 + 三行待办（首行已完成用强调橙）。

guard CommandLine.arguments.count >= 2 else {
    print("用法: swift make-icon.swift <output.png>")
    exit(2)
}
let outputPath = CommandLine.arguments[1]

let canvas: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                                bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    print("创建绘图上下文失败")
    exit(3)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

// 圆角底板（macOS 图标习惯：四周留白约 8.6%）
let margin: CGFloat = 88
let board = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let boardPath = NSBezierPath(roundedRect: board, xRadius: 176, yRadius: 176)
NSColor(srgbRed: 0.972, green: 0.960, blue: 0.945, alpha: 1).setFill()
boardPath.fill()
NSColor(white: 0, alpha: 0.06).setStroke()
boardPath.lineWidth = 6
boardPath.stroke()

let graphite = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
let accent = NSColor(srgbRed: 0.957, green: 0.318, blue: 0.118, alpha: 1)

// 三行待办：首行已完成（橙色实心圆 + 白色对勾）
let rowCenters: [CGFloat] = [canvas * 0.655, canvas * 0.500, canvas * 0.345]
let circleX: CGFloat = margin + 152
let circleRadius: CGFloat = 56
let lineLeft: CGFloat = circleX + circleRadius + 58
let lineRight: CGFloat = canvas - margin - 132
let lineWidths: [CGFloat] = [1.0, 0.82, 0.58]

for (index, y) in rowCenters.enumerated() {
    let circleRect = NSRect(x: circleX - circleRadius, y: y - circleRadius,
                            width: circleRadius * 2, height: circleRadius * 2)
    if index == 0 {
        accent.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let check = NSBezierPath()
        check.move(to: NSPoint(x: circleX - 27, y: y + 2))
        check.line(to: NSPoint(x: circleX - 8, y: y - 21))
        check.line(to: NSPoint(x: circleX + 29, y: y + 25))
        NSColor.white.setStroke()
        check.lineWidth = 20
        check.lineCapStyle = .round
        check.stroke()
    } else {
        graphite.withAlphaComponent(0.55).setStroke()
        let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 9, dy: 9))
        ring.lineWidth = 18
        ring.stroke()
    }

    let barWidth = (lineRight - lineLeft) * lineWidths[index]
    let barRect = NSRect(x: lineLeft, y: y - 15, width: barWidth, height: 30)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: 15, yRadius: 15)
    (index == 0 ? graphite : graphite.withAlphaComponent(0.42)).setFill()
    bar.fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("PNG 编码失败")
    exit(4)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("icon written: \(outputPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
} catch {
    print("写入失败: \(error)")
    exit(5)
}

// 生成 AppIcon.icns。用法：swift Tools/make_icon.swift <输出目录>
import Cocoa

// MARK: - 工具

extension NSImage {
    /// 用目标颜色替换图像（保留 alpha）。
    func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        color.setFill()
        rect.fill()
        self.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}

func drawIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 以 1024 逻辑坐标绘制
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixelSize) / 1024.0)
    transform.concat()

    // 背景：深蓝渐变圆角矩形
    let inset: CGFloat = 62
    let bgRect = NSRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 196, yRadius: 196)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.30, blue: 0.55, alpha: 1.0),
        NSColor(srgbRed: 0.07, green: 0.10, blue: 0.22, alpha: 1.0),
    ])!
    gradient.draw(in: bgPath, angle: -90)

    // 内发光高光
    let sheen = NSBezierPath(roundedRect: bgRect.insetBy(dx: 8, dy: 8), xRadius: 188, yRadius: 188)
    NSColor.white.withAlphaComponent(0.06).setStroke()
    sheen.lineWidth = 6
    sheen.stroke()

    // 笔记本符号（白色）
    let laptopConfig = NSImage.SymbolConfiguration(pointSize: 450, weight: .regular)
    if let laptop = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
        .withSymbolConfiguration(laptopConfig) {
        let size = laptop.size
        let target = NSRect(
            x: (1024 - size.width) / 2,
            y: (1024 - size.height) / 2 - 42,
            width: size.width,
            height: size.height
        )
        laptop.tinted(.white).draw(in: target)
    }

    // 右上角小闪电（暖黄色），表示「持续运行」
    let boltConfig = NSImage.SymbolConfiguration(pointSize: 168, weight: .semibold)
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(boltConfig) {
        let size = bolt.size
        let target = NSRect(x: 1024 - size.width - 196, y: 1024 - size.height - 196,
                            width: size.width, height: size.height)
        bolt.tinted(NSColor(srgbRed: 1.0, green: 0.80, blue: 0.32, alpha: 1.0)).draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    return png
}

// MARK: - 输出

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("LidAwake.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    let data = drawIcon(pixelSize: size)
    try! data.write(to: iconset.appendingPathComponent(name))
    print("  \(name) — \(size)px")
}

print("iconset: \(iconset.path)")

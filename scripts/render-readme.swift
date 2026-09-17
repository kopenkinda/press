#!/usr/bin/env swift
import AppKit

// Run from the repository root: xcrun swift scripts/render-readme.swift
// Uses the real Icon Composer asset and native macOS typography.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Artwork/readme/banner.png")
let temporary = root.appendingPathComponent(".build/readme")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconURL = temporary.appendingPathComponent("Press-dark.png")
let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
let export = Process()
export.executableURL = URL(fileURLWithPath: developer).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
export.arguments = ["Artwork/Press.icon", "--export-image", "--output-file", iconURL.path,
                    "--platform", "macOS", "--rendition", "Dark", "--width", "512",
                    "--height", "512", "--scale", "1", "--design-generation", "27"]
try export.run()
export.waitUntilExit()
precondition(export.terminationStatus == 0, "Icon export failed")
let icon = NSImage(contentsOf: iconURL)!
let width = 2048, height = 1012
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.translateBy(x: 0, y: CGFloat(height))
context.cgContext.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: UInt32, stroke: UInt32? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color(fill).setFill(); path.fill()
    if let stroke { color(stroke).setStroke(); path.lineWidth = 2; path.stroke() }
}
func text(_ value: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          fill: UInt32 = 0xf5f6f7, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(fill), .paragraphStyle: style]
    // NSString drawing uses an unflipped graphics context.
    context.saveGraphicsState()
    context.cgContext.translateBy(x: rect.minX, y: rect.minY + rect.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    (value as NSString).draw(in: NSRect(x: 0, y: 0, width: rect.width, height: rect.height),
                            withAttributes: attributes)
    context.restoreGraphicsState()
}
func drawIcon(_ rect: NSRect) {
    context.saveGraphicsState()
    context.cgContext.translateBy(x: rect.minX, y: rect.maxY)
    context.cgContext.scaleBy(x: 1, y: -1)
    icon.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero,
              operation: .sourceOver, fraction: 1)
    context.restoreGraphicsState()
}
func line(_ points: [NSPoint], stroke: UInt32, width: CGFloat = 2) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    color(stroke).setStroke(); path.stroke()
}
func arrow(_ x: CGFloat) {
    line([NSPoint(x: x, y: 632), NSPoint(x: x + 34, y: 632)], stroke: 0x6a737e, width: 3.5)
    line([NSPoint(x: x + 23, y: 621), NSPoint(x: x + 34, y: 632),
          NSPoint(x: x + 23, y: 643)], stroke: 0x6a737e, width: 3.5)
}
func document(_ ext: String, x: CGFloat, y: CGFloat, angle: CGFloat = 0, front: Bool = false) {
    context.saveGraphicsState()
    context.cgContext.translateBy(x: x + 55, y: y + 68)
    context.cgContext.rotate(by: angle * .pi / 180)
    context.cgContext.translateBy(x: -55, y: -68)
    let shape = NSBezierPath()
    shape.move(to: NSPoint(x: 14, y: 0))
    shape.line(to: NSPoint(x: 75, y: 0)); shape.line(to: NSPoint(x: 110, y: 35))
    shape.line(to: NSPoint(x: 110, y: 122))
    shape.curve(to: NSPoint(x: 96, y: 136), controlPoint1: NSPoint(x: 110, y: 132), controlPoint2: NSPoint(x: 106, y: 136))
    shape.line(to: NSPoint(x: 14, y: 136))
    shape.curve(to: NSPoint(x: 0, y: 122), controlPoint1: NSPoint(x: 4, y: 136), controlPoint2: NSPoint(x: 0, y: 132))
    shape.line(to: NSPoint(x: 0, y: 14))
    shape.curve(to: NSPoint(x: 14, y: 0), controlPoint1: NSPoint(x: 0, y: 4), controlPoint2: NSPoint(x: 4, y: 0))
    shape.close()
    color(front ? 0x313741 : 0x24292f).setFill(); shape.fill()
    color(front ? 0x727c89 : 0x48515c).setStroke(); shape.lineWidth = 2; shape.stroke()
    line([NSPoint(x: 75, y: 2), NSPoint(x: 75, y: 35), NSPoint(x: 108, y: 35)], stroke: 0x66707d)
    text(ext, NSRect(x: 4, y: 74, width: 102, height: 40), size: 28, weight: .semibold,
         fill: front ? 0xf1f3f6 : 0xb4bdc7, alignment: .center)
    context.restoreGraphicsState()
}
func folder(x: CGFloat, y: CGFloat, scale: CGFloat = 1, fill: UInt32) {
    context.saveGraphicsState()
    context.cgContext.translateBy(x: x, y: y); context.cgContext.scaleBy(x: scale, y: scale)
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 12, y: 0)); back.line(to: NSPoint(x: 60, y: 0))
    back.line(to: NSPoint(x: 77, y: 16)); back.line(to: NSPoint(x: 168, y: 16))
    back.curve(to: NSPoint(x: 180, y: 28), controlPoint1: NSPoint(x: 177, y: 16), controlPoint2: NSPoint(x: 180, y: 20))
    back.line(to: NSPoint(x: 180, y: 126)); back.line(to: NSPoint(x: 0, y: 126))
    back.line(to: NSPoint(x: 0, y: 12))
    back.curve(to: NSPoint(x: 12, y: 0), controlPoint1: NSPoint(x: 0, y: 3), controlPoint2: NSPoint(x: 3, y: 0)); back.close()
    color(0x3e819c).setFill(); back.fill()
    rounded(NSRect(x: 0, y: 35, width: 180, height: 102), radius: 12, fill: fill, stroke: 0x77b8d0)
    line([NSPoint(x: 13, y: 39), NSPoint(x: 167, y: 39)], stroke: 0x9bd0e1)
    context.restoreGraphicsState()
}

color(0x0e1418).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
drawIcon(NSRect(x: 102, y: 87, width: 205, height: 205))
text("Press", NSRect(x: 350, y: 94, width: 1200, height: 112), size: 86, weight: .semibold)
text("Your archives, unpacked.", NSRect(x: 353, y: 218, width: 1300, height: 52),
     size: 36, weight: .medium, fill: 0xa0a2a6)
for (x, label) in [(102.0, "1  OPEN AN ARCHIVE"), (742.0, "2  UNARCHIVE"), (1382.0, "3  GET YOUR FILES")] {
    rounded(NSRect(x: x, y: 376, width: 564, height: 502), radius: 34, fill: 0x191918)
    text(label, NSRect(x: x + 36, y: 411, width: 492, height: 36), size: 23, weight: .semibold, fill: 0x929497)
}
// A loose, balanced cloud, keeping every extension readable.
document(".tar", x: 182, y: 518, angle: -12)
document(".gz", x: 466, y: 522, angle: 12)
document(".zip", x: 330, y: 484, angle: 2)
document(".7z", x: 236, y: 627, angle: -7)
document(".xz", x: 437, y: 631, angle: 9)
document(".rar", x: 337, y: 604, front: true)
text("RAR, 7z, ZIP, TAR + more", NSRect(x: 126, y: 787, width: 516, height: 40),
     size: 28, fill: 0xa0a2a6, alignment: .center)
arrow(686)
drawIcon(NSRect(x: 916, y: 522, width: 216, height: 216))
text("Preview, then extract.", NSRect(x: 766, y: 787, width: 516, height: 40),
     size: 28, fill: 0xa0a2a6, alignment: .center)
arrow(1326)
folder(x: 1474, y: 524, scale: 0.9, fill: 0x4f94b0)
folder(x: 1678, y: 546, scale: 0.9, fill: 0x539ab6)
folder(x: 1562, y: 617, scale: 1.08, fill: 0x64aac5)
text("Ready in Finder.", NSRect(x: 1406, y: 787, width: 516, height: 40),
     size: 28, fill: 0xa0a2a6, alignment: .center)
text("Native Swift · macOS 27", NSRect(x: 102, y: 938, width: 1600, height: 38),
     size: 26, fill: 0x777c80)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Rendered \(output.path)")

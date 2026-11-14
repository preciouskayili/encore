// Draws Encore's app icon and writes Support/AppIcon.icns and AppIcon.png.
// Run from the project folder: swift scripts/make-icon.swift
//
// The mark is the repeat sign from sheet music: two dots, a thin bar and a
// thick bar, which tells the player to go back and play it again. An encore.
// It's flat: one solid colour, a white mark, nothing else.
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

// macOS's icon shape: a rounded square inset from the canvas, with the
// standard soft shadow under it.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: tile).cgPath

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
context.addPath(shape)
context.setFillColor(color(0x2B59FF))
context.fillPath()
context.restoreGState()

// The repeat sign, centred.
let height: CGFloat = 392
let dot: CGFloat = 84
let thin: CGFloat = 30
let thick: CGFloat = 84
let gapAfterDots: CGFloat = 58
let gapBetweenBars: CGFloat = 40
let width = dot + gapAfterDots + thin + gapBetweenBars + thick
let left = tile.midX - width / 2
let bottom = tile.midY - height / 2

func bar(x: CGFloat, width: CGFloat) {
    let rect = CGRect(x: x, y: bottom, width: width, height: height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    context.fillPath()
}

context.setFillColor(color(0xFFFFFF))
bar(x: left + dot + gapAfterDots, width: thin)
bar(x: left + dot + gapAfterDots + thin + gapBetweenBars, width: thick)

context.setFillColor(color(0xAABDFF))
for offset in [-86.0, 86.0] {
    context.fillEllipse(in: CGRect(x: left, y: tile.midY + offset - dot / 2, width: dot, height: dot))
}

NSGraphicsContext.current = nil

// Write every size macOS asks for, then pack them.
let work = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.addRepresentation(bitmap)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let small = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.current = nil
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try small.representation(using: .png, properties: [:])!.write(to: work.appendingPathComponent(name))
}

let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", work.path, "-o", "Support/AppIcon.icns"]
try pack.run()
pack.waitUntilExit()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Support/AppIcon.png"))
print(pack.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")

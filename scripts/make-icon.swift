// Draws Encore's app icon and writes Support/AppIcon.icns.
// Run from the project folder: swift scripts/make-icon.swift
//
// The icon is the player itself: a pane of glass holding a play button and a
// song's progress, over the soft wash of colour the full-screen view makes
// from a cover.
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
let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func glow(_ hex: UInt32, at center: CGPoint, radius: CGFloat, strength: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: [color(hex, strength), color(hex, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// macOS's icon shape: a rounded square inset from the canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: tile).cgPath

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
context.addPath(shape)
context.setFillColor(color(0x0C0B10))
context.fillPath()
context.restoreGState()

// The colour wash.
context.saveGState()
context.addPath(shape)
context.clip()
glow(0xFF5A36, at: CGPoint(x: 300, y: 760), radius: 520, strength: 0.95)
glow(0x8A3CFF, at: CGPoint(x: 800, y: 300), radius: 540, strength: 0.85)
glow(0xFFB23C, at: CGPoint(x: 760, y: 820), radius: 320, strength: 0.55)
glow(0x1F6BFF, at: CGPoint(x: 220, y: 240), radius: 380, strength: 0.5)
context.setFillColor(color(0x000000, 0.22))
context.fill(tile)
context.restoreGState()

// The pane of glass.
let pane = CGRect(x: 232, y: 332, width: 560, height: 360)
let paneShape = RoundedRectangle(cornerRadius: 84, style: .continuous).path(in: pane).cgPath

context.saveGState()
context.addPath(paneShape)
context.clip()
context.setFillColor(color(0xFFFFFF, 0.13))
context.fill(pane)
let sheen = CGGradient(
    colorsSpace: space,
    colors: [color(0xFFFFFF, 0.26), color(0xFFFFFF, 0.02), color(0xFFFFFF, 0.08)] as CFArray,
    locations: [0, 0.55, 1]
)!
context.drawLinearGradient(sheen, start: CGPoint(x: pane.midX, y: pane.maxY), end: CGPoint(x: pane.midX, y: pane.minY), options: [])
context.restoreGState()

context.addPath(paneShape)
context.setStrokeColor(color(0xFFFFFF, 0.62))
context.setLineWidth(5)
context.strokePath()

// Play.
let play = CGMutablePath()
let center = CGPoint(x: pane.midX + 10, y: pane.midY + 46)
play.move(to: CGPoint(x: center.x - 52, y: center.y + 70))
play.addLine(to: CGPoint(x: center.x + 66, y: center.y))
play.addLine(to: CGPoint(x: center.x - 52, y: center.y - 70))
play.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.25))
context.setLineJoin(.round)
context.setLineWidth(22)
context.setStrokeColor(color(0xFFFFFF))
context.setFillColor(color(0xFFFFFF))
context.addPath(play)
context.drawPath(using: .fillStroke)
context.restoreGState()
context.setFillColor(color(0xFFFFFF))
context.addPath(play)
context.fillPath()

// Progress.
let track = CGRect(x: pane.minX + 78, y: pane.minY + 74, width: pane.width - 156, height: 18)
context.addPath(CGPath(roundedRect: track, cornerWidth: 9, cornerHeight: 9, transform: nil))
context.setFillColor(color(0xFFFFFF, 0.32))
context.fillPath()
let played = CGRect(x: track.minX, y: track.minY, width: track.width * 0.58, height: track.height)
context.addPath(CGPath(roundedRect: played, cornerWidth: 9, cornerHeight: 9, transform: nil))
context.setFillColor(color(0xFFFFFF))
context.fillPath()

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

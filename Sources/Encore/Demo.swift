import AppKit
import SwiftUI

/// Two ways to show Encore off without locking the Mac, both over a stand-in
/// lock screen that hides the desktop:
///
/// - `Encore --tour` uses the song that's really playing and runs the player
///   through its paces by itself. `scripts/record-demo.sh` records it.
/// - `Encore --demo` shows a made-up song, cover and lyrics instead, for
///   pictures with nothing in them that belongs to anyone else.
enum Demo {
    static var track: Track {
        Track(
            title: "Afterglow", artist: "The Encores", album: "One More Time",
            duration: 214, anchorElapsed: 73.4, anchorDate: Date(), rate: 1, isPlaying: true, bundleID: nil
        )
    }

    static let lines: [LyricLine] = {
        let words = [
            "We left the city lights behind",
            "Windows down, the radio low",
            "Every mile a little lighter",
            "Nothing here we need to know",
            "Hold the night a little longer",
            "Let the morning take its time",
            "If the road keeps going, so will we",
            "One more song before the sun",
            "Play it back, play it again",
            "I can hear it in the afterglow",
            "Stay until the last note fades",
            "Then one more time for the road",
        ]
        return words.enumerated().map { index, text in
            let start = 40.0 + Double(index) * 4.6
            let parts = text.split(separator: " ")
            let timed = parts.enumerated().map { offset, part in
                LyricWord(
                    text: String(part) + (offset == parts.count - 1 ? "" : " "),
                    start: start + Double(offset) * 4.2 / Double(parts.count)
                )
            }
            return LyricLine(id: index, text: text, start: start, words: timed)
        }
    }()

    /// A dusk sky over three ridgelines, drawn here so it's nobody's artwork.
    static let cover: NSImage = {
        let side: CGFloat = 768
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
                CGColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
                )
            }
            let sky = CGGradient(
                colorsSpace: space,
                colors: [color(0x1A1640), color(0x6A2C70), color(0xE8563F), color(0xFFB45C)] as CFArray,
                locations: [0, 0.42, 0.74, 1]
            )!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: side * 0.18), options: [.drawsAfterEndLocation])

            let sun = CGPoint(x: side * 0.62, y: side * 0.4)
            let glow = CGGradient(colorsSpace: space, colors: [color(0xFFE2A8, 0.9), color(0xFFE2A8, 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: side * 0.42, options: [])
            context.setFillColor(color(0xFFF1D6))
            context.fillEllipse(in: CGRect(x: sun.x - 62, y: sun.y - 62, width: 124, height: 124))

            for (height, hex, phase) in [(0.36, 0x7A2F5E as UInt32, 0.0), (0.27, 0x43204F as UInt32, 1.7), (0.17, 0x1B1230 as UInt32, 3.1)] {
                let ridge = CGMutablePath()
                ridge.move(to: CGPoint(x: 0, y: 0))
                for step in stride(from: 0.0, through: Double(side), by: 8) {
                    let wave = sin(step / 96 + phase) * 26 + sin(step / 41 + phase * 2) * 11
                    ridge.addLine(to: CGPoint(x: step, y: Double(side) * height + wave))
                }
                ridge.addLine(to: CGPoint(x: side, y: 0))
                ridge.closeSubpath()
                context.addPath(ridge)
                context.setFillColor(color(hex))
                context.fillPath()
            }
            return true
        }
    }()

    /// A stand-in lock screen behind the player: the wallpaper and the clock,
    /// so the player can be shown in something like its real setting. With
    /// `realWallpaper` it uses the Mac's own wallpaper, as the lock screen does.
    static func makeStage(realWallpaper: Bool = false) -> NSPanel {
        let panel = PlayerPanel()
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        var wallpaper: NSImage?
        if realWallpaper, let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            wallpaper = NSImage(contentsOf: url)
        }
        let host = NSHostingView(rootView: StageView(wallpaper: wallpaper))
        host.safeAreaRegions = []
        panel.contentView = host
        if let screen = NSScreen.screens.first { panel.setFrame(screen.frame, display: true) }
        panel.orderFrontRegardless()
        return panel
    }
}

private struct StageView: View {
    var wallpaper: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if let wallpaper {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    paintedSky(in: geometry.size)
                }
                ClockLabel(screenHeight: geometry.size.height)
                    .padding(.top, geometry.size.height * 0.055)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private func paintedSky(in size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.09, blue: 0.2), Color(red: 0.22, green: 0.2, blue: 0.42),
                        Color(red: 0.62, green: 0.36, blue: 0.46), Color(red: 0.93, green: 0.62, blue: 0.45),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            Circle()
                .fill(Color(red: 1, green: 0.8, blue: 0.6).opacity(0.5))
                .frame(width: size.width * 0.5)
                .blur(radius: 160)
                .offset(y: size.height * 0.62)
        }
    }
}

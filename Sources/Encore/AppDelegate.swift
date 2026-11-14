import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let nowPlaying = NowPlaying()
    private lazy var lyrics = LyricsStore(nowPlaying: nowPlaying)
    private var lockScreen: PlayerWindowController?
    private var preview: PlayerWindowController?
    private var statusItem: NSStatusItem?
    private var demoStage: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let isDemo = arguments.contains("--demo") || arguments.contains("--demo-tour")
        if isDemo {
            nowPlaying.loadDemo(track: Demo.track, cover: Demo.cover)
            lyrics.loadDemo(Demo.lines)
            demoStage = Demo.makeStage()
        } else {
            nowPlaying.start()
            _ = lyrics
            if arguments.contains("--tour") { demoStage = Demo.makeStage(realWallpaper: true) }
        }

        for (flag, expanded) in [("--snapshot", false), ("--snapshot-full", true)] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                snapshot(to: arguments[index + 1], expanded: expanded)
                return
            }
        }

        lockScreen = PlayerWindowController(placement: .lockScreen, nowPlaying: nowPlaying, lyrics: lyrics)
        if arguments.contains("--demo-tour") || arguments.contains("--tour") { lockScreen?.runDemoTour() }
        installStatusItem()
        Log.write("encore: started")
        turnOnOpenAtLoginOnce()
    }

    /// The lock screen player is only useful if it's running, so Encore
    /// turns on Open at login the first time it runs from an Applications
    /// folder. It does this once: switching it off in the menu sticks.
    private func turnOnOpenAtLoginOnce() {
        let key = "openAtLoginSetUp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = Bundle.main.bundlePath
        let applications = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        guard applications.contains(where: { path.hasPrefix($0) }) else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: key)
            Log.write("open at login: turned on")
        } catch {
            Log.write("open at login: \(error.localizedDescription)")
        }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Encore")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: Selector, on: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }

        add("Show on lock screen", #selector(toggleLockScreen), on: lockScreen?.isEnabled == true)
        add("Open full screen when locked", #selector(toggleExpandOnLock), on: lockScreen?.expandsOnLock == true)
        add("Show lyrics", #selector(toggleLyrics), on: lyrics.isEnabled)
        menu.addItem(.separator())
        add("Preview player", #selector(togglePreview), on: preview?.isPreviewing == true)
        menu.addItem(.separator())
        add("Open at login", #selector(toggleOpenAtLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Encore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleLockScreen() {
        guard let lockScreen else { return }
        lockScreen.isEnabled.toggle()
    }

    @objc private func toggleExpandOnLock() {
        guard let lockScreen else { return }
        lockScreen.expandsOnLock.toggle()
    }

    @objc private func toggleLyrics() {
        lyrics.isEnabled.toggle()
    }

    /// Shows the same player on the desktop, so it can be seen and tried
    /// without locking the Mac. Click the cover there to try full screen.
    @objc private func togglePreview() {
        let controller = preview ?? PlayerWindowController(placement: .desktop, nowPlaying: nowPlaying, lyrics: lyrics)
        preview = controller
        controller.isPreviewing.toggle()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("open at login: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Open at login"
            alert.informativeText = "Move Encore to your Applications folder, open it from there, then try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Snapshot

    /// `Encore --snapshot file.png` draws the small card to an image and
    /// quits; `--snapshot-full file.png` draws the full-screen view. Used to
    /// check the design without opening a window.
    private func snapshot(to path: String, expanded: Bool) {
        // Give the song, cover and lyrics a moment to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + (expanded ? 5 : 1.5)) { [nowPlaying, lyrics] in
            let model = PlayerSceneModel()
            model.isVisible = true
            model.isExpanded = expanded

            let size = expanded ? CGSize(width: 1512, height: 982) : CGSize(width: 452, height: 340)
            let content: AnyView = expanded
                ? AnyView(PlayerScene(model: model, nowPlaying: nowPlaying, lyrics: lyrics, solid: true))
                : AnyView(PlayerCard(nowPlaying: nowPlaying))
            let view = content
                .frame(width: size.width, height: size.height)
                .background(Color(red: 0.24, green: 0.3, blue: 0.4))

            let renderer = ImageRenderer(content: view)
            renderer.scale = expanded ? 1 : 2
            guard
                let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("encore: could not draw the player\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("track: \(nowPlaying.track?.title ?? "none") | cover: \(nowPlaying.artwork != nil) | lyric lines: \(lyrics.lines.count) | word timing: \(lyrics.lines.contains { !$0.words.isEmpty })")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("encore: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

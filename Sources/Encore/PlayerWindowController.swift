import AppKit
import Combine
import SwiftUI

/// A window that never takes keyboard focus, so typing your password on the
/// lock screen still goes to the password field.
final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

/// Lets the first click on the player press a button, instead of being spent
/// on selecting the window.
final class ClickThroughHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the player's window: on the lock screen while something is playing,
/// or on the desktop as a preview.
///
/// The SwiftUI scene inside is always laid out at the size of the whole
/// screen. The window is a porthole onto it: just big enough for the small
/// card, so clicks around it still reach the lock screen, and the size of the
/// screen once the cover is expanded.
final class PlayerWindowController {
    enum Placement {
        case lockScreen
        case desktop
    }

    static let enabledKey = "showOnLockScreen"
    static let expandOnLockKey = "expandOnLock"

    private let placement: Placement
    private let nowPlaying: NowPlaying
    private let panel = PlayerPanel()
    private let host: ClickThroughHostingView
    private let model = PlayerSceneModel()
    private var isLocked = false
    private var wantsPreview = false
    private(set) var isShown = false
    private var cancellables = Set<AnyCancellable>()

    /// The cover's spring, or a short fade when Reduce Motion is on.
    private static var expandSpring: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.2) : PlayerScene.coverSpring
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            update()
        }
    }

    /// Whether the cover should fill the screen by itself each time the Mac locks.
    var expandsOnLock: Bool {
        get { UserDefaults.standard.bool(forKey: Self.expandOnLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.expandOnLockKey) }
    }

    /// Shows or hides the desktop preview.
    var isPreviewing: Bool {
        get { wantsPreview }
        set {
            wantsPreview = newValue
            update()
        }
    }

    init(placement: Placement, nowPlaying: NowPlaying, lyrics: LyricsStore) {
        self.placement = placement
        self.nowPlaying = nowPlaying
        host = ClickThroughHostingView(
            rootView: AnyView(PlayerScene(model: model, nowPlaying: nowPlaying, lyrics: lyrics))
        )
        host.sizingOptions = []
        host.autoresizingMask = []
        // The scene is placed by hand and often reaches past the window's
        // edges, so the window's safe areas mustn't push it around.
        host.safeAreaRegions = []

        let container = NSView()
        container.autoresizesSubviews = false
        container.addSubview(host)
        panel.contentView = container
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        model.setExpanded = { [weak self] expanded in self?.setExpanded(expanded) }

        switch placement {
        case .lockScreen:
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            applyPorthole(expanded: false)
            panel.orderFrontRegardless()
            let moved = SkyLight.moveToLockScreen(panel)
            Log.write("lock screen: window \(panel.windowNumber) moved to lock screen layer: \(moved)")

            let center = DistributedNotificationCenter.default()
            center.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
            center.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        case .desktop:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        nowPlaying.$track
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    // MARK: Showing and hiding

    @objc private func screenLocked() {
        isLocked = true
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logVisibility() }
    }

    @objc private func screenUnlocked() {
        isLocked = false
        update()
    }

    @objc private func screensChanged() {
        if isShown { applyPorthole(expanded: model.isExpanded) }
    }

    private func update() {
        let hasTrack = nowPlaying.track != nil
        let show: Bool
        switch placement {
        case .lockScreen:
            let forced = UserDefaults.standard.bool(forKey: "debugAlwaysShow")
            show = isEnabled && hasTrack && (isLocked || forced)
        case .desktop:
            show = wantsPreview
        }

        // Nothing left to fill the screen with.
        if !hasTrack, model.isExpanded { setExpanded(false) }

        guard show != isShown else { return }
        isShown = show
        panel.ignoresMouseEvents = !show

        if show {
            model.isExpanded = false
            applyPorthole(expanded: false)
            if placement == .desktop { panel.orderFrontRegardless() }
            panel.alphaValue = 1
            // Let the lock screen settle first, then bring the player in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isShown else { return }
                self.model.isVisible = true
            }
            if placement == .lockScreen, expandsOnLock {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                    guard let self, self.isShown else { return }
                    self.setExpanded(true)
                }
            }
        } else {
            model.isVisible = false
            // Put the window away once the player has finished fading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.isShown else { return }
                self.panel.alphaValue = 0
                self.model.isExpanded = false
                self.applyPorthole(expanded: false)
                if self.placement == .desktop { self.panel.orderOut(nil) }
            }
        }
    }

    // MARK: Full screen

    private func setExpanded(_ expanded: Bool) {
        guard expanded != model.isExpanded else { return }
        if expanded {
            guard isShown, nowPlaying.track != nil else { return }
            // Open the window to the whole screen first; nothing moves on
            // screen, because the scene inside is already screen-sized.
            applyPorthole(expanded: true)
            withAnimation(Self.expandSpring) { model.isExpanded = true }
        } else {
            withAnimation(Self.expandSpring) { model.isExpanded = false }
            // Shrink the window back around the card once the cover has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.model.isExpanded else { return }
                self.applyPorthole(expanded: false)
            }
        }
    }

    /// Sizes the window, and slides the screen-sized scene inside it so that
    /// every view stays exactly where it was on the screen.
    private func applyPorthole(expanded: Bool) {
        let screen = placement == .desktop ? (NSScreen.main ?? NSScreen.screens.first) : NSScreen.screens.first
        guard let screen else { return }
        let full = screen.frame

        let frame: CGRect
        if expanded {
            frame = full
        } else {
            // Room for the tallest card and its shadow around the anchor point.
            let anchorY = full.maxY - full.height * PlayerScene.cardAnchor
            frame = CGRect(x: full.midX - 226, y: anchorY - 170, width: 452, height: 340).integral
        }

        panel.setFrame(frame, display: true)
        host.frame = CGRect(
            x: full.minX - frame.minX,
            y: full.minY - frame.minY,
            width: full.width,
            height: full.height
        )
    }

    /// Writes down whether the window server is really drawing the player over
    /// the lock screen, so a failed test can be told apart from a hidden card.
    private func logVisibility() {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = windows.contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        Log.write(
            "lock screen: locked, playing=\(nowPlaying.track != nil) shown=\(isShown) "
                + "onScreen=\(onScreen) expanded=\(model.isExpanded) frame=\(panel.frame)"
        )
    }
}

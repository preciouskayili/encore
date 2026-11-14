import SwiftUI

/// The small player: cover, song, position and controls
/// on one Liquid Glass card.
///
/// Motion follows Apple's own players: springs, not timed fades; the cover
/// settles back when paused; the song title blurs across to the next one; the
/// play button morphs into pause. Reduce Motion swaps movement for fades.
struct PlayerCard: View {
    @ObservedObject var nowPlaying: NowPlaying
    /// When set, the card leaves an empty slot where its cover goes. The
    /// scene draws one cover for the whole player and parks it in whichever
    /// slot is live, so it can grow out of this card into the full-screen
    /// view and back as a single image.
    var coverSlot: Namespace.ID?
    /// Whether the cover is parked in this card's slot right now.
    var holdsCover = true
    /// Called when the cover is clicked. Nil hides the option.
    var onExpand: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 372
    static let radius: CGFloat = 22

    var body: some View {
        Group {
            if let track = nowPlaying.track {
                player(track)
            } else {
                emptyState
            }
        }
        .legibleOnGlass()
        .padding(16)
        .frame(width: Self.width)
        .background(AppleGlass(radius: Self.radius))
        .environment(\.colorScheme, .dark)
    }

    private func player(_ track: Track) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                cover(track)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title.isEmpty ? "Unknown title" : track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .id(track.identity)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))

                if let icon = nowPlaying.sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
            }
            .animation(.smooth(duration: 0.45), value: track.identity)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ProgressRow(track: track, now: context.date) { nowPlaying.seek(to: $0) }
            }

            PlayerControls(nowPlaying: nowPlaying, track: track)
        }
    }

    @ViewBuilder
    private func cover(_ track: Track) -> some View {
        let slot = Group {
            if let coverSlot {
                Color.clear
                    .frame(width: 56, height: 56)
                    .matchedGeometryEffect(id: "cover", in: coverSlot, isSource: holdsCover)
            } else {
                Artwork(image: nowPlaying.artwork, version: nowPlaying.artworkVersion, isPlaying: track.isPlaying)
                    .frame(width: 56, height: 56)
            }
        }
        if let onExpand {
            Button(action: onExpand) { slot.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Show full screen")
        } else {
            slot
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Artwork(image: nil)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Play something in Spotify, Music or your browser.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared pieces

/// The cover. It fills whatever frame it's given, so the same view can be a
/// thumbnail on the card or the large cover in the full-screen view, and can
/// be resized smoothly between the two.
struct Artwork: View {
    let image: NSImage?
    /// Goes up each time the cover changes, so the old one can fade into the new.
    var version = 0
    var isPlaying = true
    var radius: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .font(.system(size: geometry.size.width * 0.36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(version)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // The cover sits back a little while paused, as in Apple's own player.
            .scaleEffect(isPlaying || reduceMotion ? 1 : 0.86)
            .animation(.spring(response: 0.45, dampingFraction: 0.68), value: isPlaying)
            .animation(.smooth(duration: 0.45), value: version)
        }
        .accessibilityHidden(true)
    }
}

struct PlayerControls: View {
    let nowPlaying: NowPlaying
    let track: Track
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 18 * scale) {
            ControlButton(symbol: "backward.fill", label: "Previous track", size: 19 * scale, bounces: true) {
                nowPlaying.previous()
            }
            ControlButton(
                symbol: track.isPlaying ? "pause.fill" : "play.fill",
                label: track.isPlaying ? "Pause" : "Play",
                size: 27 * scale
            ) { nowPlaying.togglePlayPause() }
            ControlButton(symbol: "forward.fill", label: "Next track", size: 19 * scale, bounces: true) {
                nowPlaying.next()
            }
        }
    }
}

struct ProgressRow: View {
    let track: Track
    let now: Date
    let onSeek: (Double) -> Void

    /// Where the pointer is while dragging, from 0 to 1.
    @State private var scrub: Double?
    @State private var isHovering = false

    var body: some View {
        // A song's length can arrive after its title, and live streams have
        // none. The row stays either way, empty, so nothing below it moves.
        let hasLength = track.duration > 0
        let elapsed = scrub.map { $0 * track.duration } ?? track.elapsed(at: now)
        let fraction = hasLength ? min(max(elapsed / track.duration, 0), 1) : 0
        let isActive = hasLength && (scrub != nil || isHovering)

        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.24)
                    // The fill slides in from the left rather than changing
                    // width, so it can glide between ticks.
                    Color.white
                        .offset(x: -geometry.size.width * (1 - fraction))
                        .animation(scrub == nil ? .linear(duration: 0.5) : nil, value: fraction)
                }
                .frame(height: 4)
                .clipShape(Capsule())
                // Thickens under the pointer, like the scrubber on iPhone.
                .scaleEffect(y: isActive ? 1.9 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isActive)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrub = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let end = min(max(value.location.x / geometry.size.width, 0), 1)
                            onSeek(end * track.duration)
                            scrub = nil
                        }
                )
            }
            .frame(height: 20)
            .allowsHitTesting(hasLength)

            HStack {
                Text(hasLength ? Self.clock(elapsed) : "–:––")
                Spacer()
                Text(hasLength ? "−" + Self.clock(track.duration - elapsed) : "–:––")
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .opacity(isActive ? 0.95 : 0.62)
            .animation(.easeOut(duration: 0.2), value: isActive)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position in song")
        .accessibilityValue("\(Self.clock(elapsed)) of \(Self.clock(track.duration))")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 10 : -10
            onSeek(min(max(track.elapsed() + step, 0), track.duration))
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let duration = Duration.seconds(max(0, seconds.rounded(.down)))
        return duration.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct ControlButton: View {
    let symbol: String
    let label: String
    let size: CGFloat
    /// Skip buttons give a small bounce on each press.
    var bounces = false
    let action: () -> Void

    @State private var presses = 0

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                // Play morphs into pause instead of swapping.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounces ? presses : 0)
                .frame(width: max(52, size * 2.4), height: max(44, size * 1.9))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .animation(.snappy(duration: 0.25), value: symbol)
        .accessibilityLabel(label)
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .padding(-2)
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Apple's Liquid Glass, the real thing (`NSGlassEffectView`), with its blur
/// switched off so it reads as clear glass, like the Dock.
struct AppleGlass: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> ClearGlassView {
        ClearGlassView(radius: radius)
    }

    func updateNSView(_ view: ClearGlassView, context: Context) {
        view.radius = radius
    }
}

/// Holds Apple's glass view and keeps it clear.
///
/// The glass is Apple's own: its refraction at the edges, its highlights, its
/// response to light and dark. Left alone it also blurs whatever is behind
/// the window, in both public styles. That blur is one number inside the
/// filter the glass puts on its backdrop (`inputBlurRadius`, 10 by default),
/// and this sets it to zero. The system rewrites the filter now and then, so
/// it's watched and put back the moment that happens.
///
/// The filter is undocumented. If a macOS update renames it, nothing here
/// matches and the glass simply shows with Apple's default blur.
final class ClearGlassView: NSView {
    var radius: CGFloat {
        didSet { if #available(macOS 26.0, *) { (glass as? NSGlassEffectView)?.cornerRadius = radius } }
    }

    private var glass: NSView?
    private var timer: Timer?
    private var watched: CALayer?
    private var watch: NSKeyValueObservation?

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)

        let surface: NSView
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .clear
            view.cornerRadius = radius
            surface = view
        } else {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
            surface = view
        }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        glass = surface
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        removeBlur()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.removeBlur() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.removeBlur() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.removeBlur() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func removeBlur() {
        guard let layer = glass?.layer, let backdrop = Self.backdrop(in: layer) else { return }
        if backdrop !== watched {
            // Catch the system's rewrites as they happen, so the blur never
            // gets a frame on screen (it used to flash back on song changes).
            watched = backdrop
            watch = backdrop.observe(\.filters) { [weak self] _, _ in self?.removeBlur() }
        }
        guard
            let filter = backdrop.filters?.first as? NSObject,
            let keys = filter.value(forKey: "inputKeys") as? [String],
            keys.contains("inputBlurRadius"),
            (filter.value(forKey: "inputBlurRadius") as? Double ?? 0) != 0,
            let clear = filter.copy() as? NSObject
        else { return }
        clear.setValue(0, forKey: "inputBlurRadius")
        CATransaction.begin()
        CATransaction.setDisableActions(true) // Snap, don't ease the blur away.
        backdrop.filters = [clear] + (backdrop.filters?.dropFirst() ?? [])
        CATransaction.commit()
    }

    private static func backdrop(in layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == "CABackdropLayer" { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let found = backdrop(in: sublayer) { return found }
        }
        return nil
    }
}

extension View {
    /// A soft shadow that keeps white text and icons readable on clear glass.
    func legibleOnGlass() -> some View {
        shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }
}

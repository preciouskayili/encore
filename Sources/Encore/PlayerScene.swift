import SwiftUI

/// What the player window is showing. The views animate themselves when
/// these change.
final class PlayerSceneModel: ObservableObject {
    /// Whether the player is in view at all.
    @Published var isVisible = false
    /// Whether the cover has grown to fill the screen.
    @Published var isExpanded = false
    /// Whether the full-screen view has its lyrics open. Off, it's just the
    /// cover over its colours. Remembered between launches.
    @Published var showsLyrics = UserDefaults.standard.bool(forKey: "lyricsOpenInFullScreen") {
        didSet { UserDefaults.standard.set(showsLyrics, forKey: "lyricsOpenInFullScreen") }
    }
    /// Set by the window controller, which has to resize the window around
    /// the change.
    var setExpanded: (Bool) -> Void = { _ in }
}

/// Everything the player window can show, laid out in whole-screen
/// coordinates: the small card and the full-screen view. The window is only a
/// porthole onto this, small around the card and screen-sized when expanded.
///
/// There is one cover for the whole player. The card and the full-screen view
/// each leave an empty slot for it, and it sits in whichever slot is live, so
/// expanding is that one image growing and travelling to its new place rather
/// than one picture fading into another. Everything else is choreographed
/// around it: the card lets go first, the cover moves, then the panel, lyrics
/// and close button arrive a beat apart. Collapsing runs the other way, with
/// the full-screen parts leaving quickly so the cover has a clear path home.
struct PlayerScene: View {
    @ObservedObject var model: PlayerSceneModel
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var lyrics: LyricsStore
    /// Draws flat backgrounds instead of glass, for rendering to an image.
    var solid = false

    @Namespace private var coverSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the small card's centre sits, as a fraction of the screen's
    /// height from the top: a little below the middle, clear of the clock and
    /// the password field.
    static let cardAnchor: CGFloat = 0.56

    /// The spring the cover travels on. The window controller starts it.
    static let coverSpring = Animation.spring(response: 0.58, dampingFraction: 0.82)

    var body: some View {
        let expanded = model.isExpanded && nowPlaying.track != nil

        GeometryReader { geometry in
            ZStack {
                if let track = nowPlaying.track {
                    FullScreenPlayer(
                        nowPlaying: nowPlaying,
                        lyrics: lyrics,
                        track: track,
                        isShown: expanded,
                        solid: solid,
                        showsLyrics: model.showsLyrics,
                        coverSlot: coverSpace,
                        onToggleLyrics: {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.coverSpring) {
                                model.showsLyrics.toggle()
                            }
                        },
                        onClose: { model.setExpanded(false) }
                    )
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                }

                PlayerCard(
                    nowPlaying: nowPlaying,
                    coverSlot: coverSpace,
                    holdsCover: !expanded,
                    onExpand: nowPlaying.track == nil ? nil : { model.setExpanded(true) }
                )
                // The card lets go of the cover at once, and comes back to
                // meet it just as it lands.
                .opacity(expanded ? 0 : 1)
                .scaleEffect(expanded && !reduceMotion ? 0.94 : 1)
                .animation(
                    expanded
                        ? .easeOut(duration: 0.16)
                        : .spring(response: 0.45, dampingFraction: 0.86).delay(0.2),
                    value: expanded
                )
                .position(x: geometry.size.width / 2, y: geometry.size.height * Self.cardAnchor)
                .allowsHitTesting(!expanded)
                .accessibilityHidden(expanded)

                if let track = nowPlaying.track {
                    // The one cover, parked in whichever slot is live.
                    Artwork(
                        image: nowPlaying.artwork,
                        version: nowPlaying.artworkVersion,
                        isPlaying: track.isPlaying,
                        radius: expanded ? 18 : 10
                    )
                    .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 40, y: 22)
                    .matchedGeometryEffect(id: "cover", in: coverSpace, properties: .frame, isSource: false)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // The entrance: the player rises into place on a spring when the Mac
        // locks, and fades away quickly on unlock.
        .scaleEffect(
            model.isVisible || reduceMotion ? 1 : 0.9,
            anchor: UnitPoint(x: 0.5, y: Self.cardAnchor)
        )
        .offset(y: model.isVisible || reduceMotion ? 0 : 14)
        .opacity(model.isVisible ? 1 : 0)
        .animation(
            model.isVisible ? .spring(response: 0.55, dampingFraction: 0.78) : .easeOut(duration: 0.18),
            value: model.isVisible
        )
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

// MARK: - Full screen

/// Everything in the full-screen view except the cover itself: a soft wash of
/// the cover's colours, the song and controls on glass, and the lyrics. It is
/// always laid out, so the cover knows where it's headed, and shows or hides
/// its parts one after another as `isShown` changes.
private struct FullScreenPlayer: View {
    let nowPlaying: NowPlaying
    @ObservedObject var lyrics: LyricsStore
    let track: Track
    let isShown: Bool
    var solid = false
    let showsLyrics: Bool
    let coverSlot: Namespace.ID
    let onToggleLyrics: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let coverSize = min(geometry.size.height * 0.34, 420)
            let lyricsOpen = showsLyrics && !lyrics.lines.isEmpty

            ZStack {
                Backdrop(image: nowPlaying.artwork, version: nowPlaying.artworkVersion)
                    .opacity(isShown ? 1 : 0)
                    .animation(.smooth(duration: isShown ? 0.6 : 0.3), value: isShown)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    ClockLabel(screenHeight: geometry.size.height)
                        .padding(.top, geometry.size.height * 0.055)
                        .arrives(isShown, after: 0.1, from: CGSize(width: 0, height: -12), still: reduceMotion)

                    Spacer(minLength: 24)

                    HStack(alignment: .center, spacing: geometry.size.width * 0.06) {
                        VStack(spacing: 16) {
                            // Where the cover lands.
                            Color.clear
                                .frame(width: coverSize, height: coverSize)
                                .matchedGeometryEffect(id: "cover", in: coverSlot, isSource: isShown)

                            controlPanel
                                .arrives(isShown, after: 0.14, from: CGSize(width: 0, height: 20), still: reduceMotion)
                        }
                        .frame(width: coverSize)

                        if lyricsOpen {
                            // The column keeps its place while the view is
                            // closed, so the cover's landing spot doesn't
                            // shift as it opens.
                            ZStack {
                                if isShown {
                                    LyricsColumn(nowPlaying: nowPlaying, track: track, lines: lyrics.lines)
                                        .transition(
                                            .asymmetric(
                                                insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(x: 28)))
                                                    .animation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.2)),
                                                removal: .opacity.animation(.easeOut(duration: 0.14))
                                            )
                                        )
                                }
                            }
                            .frame(width: min(geometry.size.width * 0.36, 600), height: coverSize + 170)
                            // Opened with the mic: slides in beside the cover
                            // as the cover makes room for it.
                            .transition(
                                .asymmetric(
                                    insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(x: 28)))
                                        .animation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.1)),
                                    removal: .opacity.animation(.easeOut(duration: 0.14))
                                )
                            )
                        }
                    }

                    Spacer(minLength: 24)

                    CloseButton(solid: solid, action: onClose)
                        .padding(.bottom, geometry.size.height * 0.04)
                        .arrives(isShown, after: 0.26, from: CGSize(width: 0, height: 12), still: reduceMotion)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// The song and its controls on a glass panel under the cover: the small
    /// card's job, carried over into the full-screen view.
    private var controlPanel: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(track.title.isEmpty ? "Unknown title" : track.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .id(track.identity)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))

            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    ProgressRow(track: track, now: context.date) { nowPlaying.seek(to: $0) }
                }
            }

            PlayerControls(nowPlaying: nowPlaying, track: track)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if !lyrics.lines.isEmpty {
                        LyricsToggle(isOn: showsLyrics, action: onToggleLyrics)
                            .offset(x: 8)
                            .transition(.opacity)
                    }
                }
        }
        .legibleOnGlass()
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(AppleGlass(radius: 22))
        .animation(.smooth(duration: 0.45), value: track.identity)
    }
}

/// The mic on the control panel. It opens and closes the lyrics, and shows a
/// small dot under itself while they're open.
private struct LyricsToggle: View {
    let isOn: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "music.mic")
                .font(.system(size: 16, weight: .semibold))
                .opacity(isOn ? 1 : 0.62)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                        .scaleEffect(isOn || reduceMotion ? 1 : 0.2)
                        .opacity(isOn ? 1 : 0)
                        .offset(y: -4)
                }
                .contentShape(Rectangle())
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Lyrics")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private extension View {
    /// Brings a part of the full-screen view in on a spring, a set time after
    /// the cover starts moving and from a little way off, and takes it out
    /// quickly when the view closes.
    func arrives(_ shown: Bool, after delay: Double, from offset: CGSize, still: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(shown || still ? .zero : offset)
            .animation(
                shown
                    ? .spring(response: 0.5, dampingFraction: 0.84).delay(delay)
                    : .easeOut(duration: 0.14),
                value: shown
            )
    }
}

/// The cover, blown up and blurred until only its colours are left.
struct Backdrop: View {
    let image: NSImage?
    let version: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 70, opaque: true)
                        .saturation(1.25)
                        .id(version)
                        .transition(.opacity)
                }
                Color.black.opacity(0.42)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(.smooth(duration: 0.9), value: version)
        }
    }
}

/// Lyrics the way Apple Music shows them: one long column that glides up as
/// the song moves on, the line being sung bright and sharp near the top, and
/// the rest dimmer and softer the further away they are. Lines below the
/// current one follow it up a beat late, one after another. Clicking a line
/// jumps the song to it.
private struct LyricsColumn: View {
    let nowPlaying: NowPlaying
    let track: Track
    let lines: [LyricLine]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = track.elapsed(at: context.date) + 0.15
            let index = LyricLine.index(in: lines, at: time)
            LyricsList(
                lines: lines,
                index: index,
                activeWords: index >= 0 ? lines[index].activeWords(at: time) : 0,
                onSeek: { nowPlaying.seek(to: $0) }
            )
            .equatable()
        }
        .accessibilityLabel("Lyrics")
    }
}

/// Where each line's top edge sits in the column, so the column can be slid
/// to bring any line to the reading position.
private struct LineTops: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LyricsList: View, Equatable {
    let lines: [LyricLine]
    let index: Int
    let activeWords: Int
    let onSeek: (Double) -> Void

    @State private var tops: [Int: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (old: LyricsList, new: LyricsList) -> Bool {
        old.index == new.index && old.activeWords == new.activeWords && old.lines == new.lines
    }

    var body: some View {
        GeometryReader { geometry in
            // The current line rests about a third of the way down.
            let scroll = geometry.size.height * 0.3 - (tops[max(index, 0)] ?? 0)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(lines) { line in
                    let distance = line.id - index
                    LyricRow(line: line, isCurrent: distance == 0, activeWords: activeWords)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(opacity(at: distance))
                        .blur(radius: blur(at: distance))
                        .scaleEffect(distance == 0 || reduceMotion ? 1 : 0.97, anchor: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(line.start) }
                        .offset(y: scroll)
                        .animation(animation(at: distance), value: index)
                        .animation(animation(at: distance), value: tops.isEmpty)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LineTops.self,
                                    value: [line.id: proxy.frame(in: .named("lyrics")).minY]
                                )
                            }
                        )
                }
            }
            .frame(width: geometry.size.width, alignment: .topLeading)
            .coordinateSpace(name: "lyrics")
            .onPreferenceChange(LineTops.self) { tops = $0 }
        }
        // Lines dissolve at the top and bottom instead of being cut off.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func opacity(at distance: Int) -> Double {
        switch distance {
        case 0: 1
        case 1: 0.5
        case 2: 0.38
        case 3...9: 0.28
        case -2 ... -1: 0.24
        default: 0
        }
    }

    private func blur(at distance: Int) -> CGFloat {
        guard !reduceMotion, distance != 0, abs(distance) <= 9 else { return 0 }
        return min(CGFloat(abs(distance)) * 1.3, 6)
    }

    /// The current line and everything above it move together; each line
    /// below starts a little after the one before it.
    private func animation(at distance: Int) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.25) }
        let lag = Double(min(max(distance, 0), 7)) * 0.035
        return .spring(response: 0.62, dampingFraction: 0.84).delay(lag)
    }
}

private struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let activeWords: Int

    var body: some View {
        if line.text.isEmpty {
            InstrumentalDots(isCurrent: isCurrent)
        } else {
            text
                .font(.system(size: 34, weight: .bold))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.3), value: activeWords)
        }
    }

    private var text: Text {
        guard isCurrent, !line.words.isEmpty else { return Text(line.text).foregroundColor(.white) }
        // Words already sung are bright; the rest of the line waits, dimmer.
        return line.words.enumerated().reduce(Text("")) { partial, word in
            partial + Text(word.element.text)
                .foregroundColor(.white.opacity(word.offset < activeWords ? 1 : 0.42))
        }
    }
}

/// Three dots for a stretch with no singing. They breathe while it lasts.
private struct InstrumentalDots: View {
    let isCurrent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { dot in
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .scaleEffect(isCurrent && breathing && !reduceMotion ? 1.25 : 1)
                    .opacity(isCurrent && breathing ? 1 : 0.6)
                    .animation(
                        isCurrent
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(dot) * 0.18)
                            : .easeOut(duration: 0.2),
                        value: breathing
                    )
            }
        }
        .frame(height: 34)
        .onAppear { breathing = isCurrent }
        .onChange(of: isCurrent) { _, now in breathing = now }
        .accessibilityHidden(true)
    }
}

/// The clock at the top of the full-screen view. It stands in for the lock
/// screen's own clock, which the view covers, so it's set in the same font
/// and weight the lock screen is using. The style is read again whenever the
/// view opens and every minute after, so changing the lock screen clock in
/// System Settings changes this one too.
struct ClockLabel: View {
    /// The screen's height; the clock is sized from it, as the real one is.
    let screenHeight: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let size = screenHeight * 0.115
            VStack(spacing: size * -0.06) {
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: max(15, screenHeight * 0.021), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(Font(LockClock.font(size: size)))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 2)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct CloseButton: View {
    var solid = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                Text("Show less")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(AppleGlass(radius: 18))
            .contentShape(Capsule())
        }
        .buttonStyle(SinkStyle())
    }
}

/// A plain press: the button sinks a little and springs back.
private struct SinkStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

import AppKit
import Combine

/// The song the Mac is playing right now, whichever app it comes from.
struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// Position in the song at `anchorDate`. The live position is worked out
    /// from these two, so nothing has to tick once a second.
    var anchorElapsed: Double
    var anchorDate: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String?

    var identity: String { [title, artist, album].joined(separator: "\u{1F}") }

    func elapsed(at now: Date = Date()) -> Double {
        var value = anchorElapsed
        if isPlaying { value += now.timeIntervalSince(anchorDate) * rate }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }
}

/// Reads Now Playing from macOS through the helper in `Helper/`, and sends
/// play, pause, skip and seek back through it.
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage? {
        didSet { if artwork !== oldValue { artworkVersion += 1 } }
    }
    /// Goes up each time the cover changes, so views can fade between covers.
    @Published private(set) var artworkVersion = 0
    @Published private(set) var sourceIcon: NSImage?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var retryDelay: TimeInterval = 2
    private var shownArtworkKey = ""
    private var pendingClear: DispatchWorkItem?
    private var pendingArtworkClear: DispatchWorkItem?
    private let queue = DispatchQueue(label: "encore.now-playing")

    /// Shows a made-up song instead of reading the system's. See `Demo`.
    func loadDemo(track: Track, cover: NSImage) {
        self.track = track
        artwork = cover
        sourceIcon = nil
    }

    // MARK: Helper process

    func start() {
        guard process == nil else { return }
        guard let helper = Self.helperPaths() else {
            Log.write("now playing: helper files are missing from the app")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [helper.script, helper.library]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            Log.write("now playing: helper stopped (status \(finished.terminationStatus))")
            DispatchQueue.main.async { self?.helperStopped() }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
        } catch {
            Log.write("now playing: could not start helper: \(error.localizedDescription)")
            helperStopped()
        }
    }

    private func helperStopped() {
        process = nil
        input = nil
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    private static func helperPaths() -> (script: String, library: String)? {
        var folders: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["ENCORE_HELPER_DIR"] {
            folders.append(URL(fileURLWithPath: custom))
        }
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        for folder in folders {
            let script = folder.appendingPathComponent("bridge.pl").path
            let library = folder.appendingPathComponent("bridge.dylib").path
            if FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: library) {
                return (script, library)
            }
        }
        return nil
    }

    // MARK: Reading updates

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            var image: NSImage?
            if let encoded = message["artwork"] as? String, let bytes = Data(base64Encoded: encoded) {
                image = NSImage(data: bytes)
            }
            DispatchQueue.main.async { [weak self] in self?.apply(message, image: image) }
        }
    }

    private func apply(_ message: [String: Any], image: NSImage?) {
        retryDelay = 2

        let title = message["title"] as? String ?? ""
        let artist = message["artist"] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else {
            // Players report nothing for a moment between songs. Believing it
            // straight away would blank the player and then bring it back.
            clearSoon()
            return
        }
        pendingClear?.cancel()
        pendingClear = nil

        let bundleID = (message["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updated = Track(
            title: title,
            artist: artist,
            album: message["album"] as? String ?? "",
            duration: message["duration"] as? Double ?? 0,
            anchorElapsed: message["elapsed"] as? Double ?? 0,
            anchorDate: (message["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date(),
            rate: message["rate"] as? Double ?? 0,
            isPlaying: message["playing"] as? Bool ?? false,
            bundleID: bundleID
        )

        let artworkKey = message["artworkKey"] as? String ?? ""
        let songChanged = updated.identity != track?.identity
        if let image {
            // The helper re-sends a cover it has sent before; only a cover
            // that's actually different replaces the one on screen.
            if artworkKey != shownArtworkKey || artwork == nil {
                artwork = image
                shownArtworkKey = artworkKey
            }
            pendingArtworkClear?.cancel()
            pendingArtworkClear = nil
        } else if songChanged {
            if !artworkKey.isEmpty, artworkKey == shownArtworkKey {
                pendingArtworkClear?.cancel() // Same cover as the last song.
                pendingArtworkClear = nil
            } else {
                // The new song's cover usually arrives a moment after its
                // title. Keep the old cover up until it does, so the player
                // goes from one cover to the next without an empty frame in
                // between, and only show "no cover" if none ever comes.
                clearArtworkSoon(unlessReplaced: shownArtworkKey, for: updated.identity)
            }
        }

        if bundleID != track?.bundleID || sourceIcon == nil {
            sourceIcon = bundleID.flatMap(Self.icon(for:))
        }
        if updated != track { track = updated }
    }

    private func clearSoon() {
        guard pendingClear == nil, track != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClear = nil
            self.pendingArtworkClear?.cancel()
            self.pendingArtworkClear = nil
            self.track = nil
            self.artwork = nil
            self.sourceIcon = nil
            self.shownArtworkKey = ""
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func clearArtworkSoon(unlessReplaced key: String, for song: String) {
        pendingArtworkClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingArtworkClear = nil
            guard self.track?.identity == song, self.shownArtworkKey == key else { return }
            self.artwork = nil
            self.shownArtworkKey = ""
        }
        pendingArtworkClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Controls

    func togglePlayPause() {
        send("toggle")
        // Flip straight away so the button answers the click; the helper's
        // next update confirms or corrects it.
        guard var current = track else { return }
        let now = Date()
        current.anchorElapsed = current.elapsed(at: now)
        current.anchorDate = now
        current.isPlaying.toggle()
        current.rate = current.isPlaying ? 1 : 0
        track = current
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        send("seek \(seconds)")
        guard var current = track else { return }
        current.anchorElapsed = seconds
        current.anchorDate = Date()
        track = current
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }
}

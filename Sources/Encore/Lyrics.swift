import Combine
import Foundation

struct LyricWord: Equatable {
    let text: String
    let start: Double
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let start: Double
    /// Per-word timing, when the lyrics have it. Empty means line timing only.
    let words: [LyricWord]

    /// The line being sung at `time`, or -1 before the first one.
    static func index(in lines: [LyricLine], at time: Double) -> Int {
        var found = -1
        for line in lines {
            if line.start <= time { found = line.id } else { break }
        }
        return found
    }

    /// How many of this line's words have been sung by `time`.
    func activeWords(at time: Double) -> Int {
        words.prefix { $0.start <= time }.count
    }
}

/// Finds time-synced lyrics for the song that's playing, from LRCLIB
/// (lrclib.net), a free, open lyrics database. Only the song's title, artist,
/// album and length are sent.
final class LyricsStore: ObservableObject {
    static let enabledKey = "showLyrics"

    @Published private(set) var lines: [LyricLine] = []
    /// True from the moment a new song starts until its lyrics are found or
    /// ruled out, so views can hold their place instead of collapsing.
    @Published private(set) var isLoading = false

    private struct Request: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Int
        var key: String { [title, artist, album].joined(separator: "\u{1F}") }
    }

    private var cache: [String: [LyricLine]] = [:]
    private var current: Request?
    private var task: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private var songChange: AnyCancellable?
    private var isDemo = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            load(current)
        }
    }

    init(nowPlaying: NowPlaying) {
        // The lookup below waits for a new song's details to settle. This
        // doesn't: the old song's lyrics go, and loading starts, at once.
        songChange = nowPlaying.$track
            .map { track -> String? in
                guard let track, !track.title.isEmpty else { return nil }
                return [track.title, track.artist, track.album].joined(separator: "\u{1F}")
            }
            .removeDuplicates()
            .sink { [weak self] key in self?.songChanged(to: key) }

        cancellable = nowPlaying.$track
            .map { track -> Request? in
                guard let track, !track.title.isEmpty else { return nil }
                return Request(
                    title: track.title, artist: track.artist, album: track.album,
                    duration: Int(track.duration.rounded())
                )
            }
            .removeDuplicates()
            // A new song's details arrive in pieces; wait for them to settle.
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.load($0) }
    }

    private func songChanged(to key: String?) {
        guard !isDemo else { return }
        if let key, isEnabled {
            if let cached = cache[key] {
                lines = cached
                isLoading = false
            } else {
                lines = []
                isLoading = true
            }
        } else {
            lines = []
            isLoading = false
        }
    }

    /// Shows made-up lyrics and stops looking any up. See `Demo`.
    func loadDemo(_ demo: [LyricLine]) {
        isDemo = true
        task?.cancel()
        lines = demo
    }

    private func load(_ request: Request?) {
        guard !isDemo else { return }
        task?.cancel()
        current = request
        guard let request, isEnabled else {
            if !lines.isEmpty { lines = [] }
            isLoading = false
            return
        }
        if let cached = cache[request.key] {
            if lines != cached { lines = cached }
            isLoading = false
            return
        }
        if !lines.isEmpty { lines = [] }
        isLoading = true

        task = Task { [weak self] in
            let found = await Self.fetch(request)
            await MainActor.run {
                guard let self, self.current == request, !Task.isCancelled else { return }
                self.isLoading = false
                // A failed request isn't remembered, so the next play retries.
                guard let found else { return }
                self.cache[request.key] = found
                self.lines = found
                Log.write("lyrics: \(found.count) lines, word timing: \(found.contains { !$0.words.isEmpty })")
            }
        }
    }

    // MARK: Fetching

    /// Returns the lyrics, an empty list if there are none, or nil if the
    /// request itself failed.
    private static func fetch(_ request: Request) async -> [LyricLine]? {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: request.title),
            URLQueryItem(name: "artist_name", value: request.artist),
        ]
        if !request.album.isEmpty { exact.queryItems?.append(URLQueryItem(name: "album_name", value: request.album)) }
        if request.duration > 0 { exact.queryItems?.append(URLQueryItem(name: "duration", value: String(request.duration))) }

        let first = await get(exact.url!)
        if let record = first.json as? [String: Any] {
            let lines = parse(record)
            if !lines.isEmpty { return lines }
        }

        // No exact match: search with the title stripped of "(feat. …)" and
        // similar, and take the closest length.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: simplified(request.title)),
            URLQueryItem(name: "artist_name", value: request.artist),
        ]
        let second = await get(search.url!)
        guard let results = second.json as? [[String: Any]] else {
            return first.reached || second.reached ? [] : nil
        }

        let candidates = results
            .map { (record: $0, gap: abs(($0["duration"] as? Double ?? 0) - Double(request.duration))) }
            .filter { request.duration == 0 || $0.gap <= 3 }
            .sorted { $0.gap < $1.gap }
        for candidate in candidates {
            let lines = parse(candidate.record)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    private static func get(_ url: URL) async -> (json: Any?, reached: Bool) {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Encore (personal build)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, false) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (nil, true) }
        return (try? JSONSerialization.jsonObject(with: data), true)
    }

    private static func simplified(_ title: String) -> String {
        var result = title
        for pattern in [
            #"\s*[\(\[][^\)\]]*(feat|ft\.|with|remaster|version|edit|live|mix)[^\)\]]*[\)\]]"#,
            #"\s+-\s+.*(remaster|version|edit|live|mix).*$"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Parsing

    private static func parse(_ record: [String: Any]) -> [LyricLine] {
        if let file = record["lyricsfile"] as? String {
            let lines = parseLyricsFile(file)
            if !lines.isEmpty { return lines }
        }
        if let synced = record["syncedLyrics"] as? String { return parseLRC(synced) }
        return []
    }

    /// The classic format: one `[mm:ss.xx] words` per line.
    static func parseLRC(_ text: String) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        var entries: [(start: Double, text: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = stamp.matches(in: raw, range: range)
            guard let last = matches.last, let end = Range(last.range, in: raw) else { continue }
            let words = raw[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard
                    let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                    let seconds = Range(match.range(at: 2), in: raw).flatMap({ Double(raw[$0]) })
                else { continue }
                entries.append((minutes * 60 + seconds, words))
            }
        }
        return entries
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { LyricLine(id: $0.offset, text: $0.element.text, start: $0.element.start, words: []) }
    }

    /// LRCLIB's richer format, which adds a start time for every word. It's a
    /// small, regular subset of YAML, so it's read line by line here rather
    /// than pulling in a YAML library.
    static func parseLyricsFile(_ file: String) -> [LyricLine] {
        struct Draft {
            var text = ""
            var start: Double = 0
            var words: [(text: String, start: Double)] = []
        }
        enum Target { case none, line, word }

        var drafts: [Draft] = []
        var pendingWord: String?
        var target = Target.none
        var inLines = false

        func value(_ line: String, after prefix: String) -> String {
            String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        func milliseconds(_ line: String, after prefix: String) -> Double {
            (Double(value(line, after: prefix)) ?? 0) / 1000
        }

        for raw in file.components(separatedBy: "\n") {
            if !inLines {
                if raw.hasPrefix("lines:") { inLines = true }
                continue
            }
            if raw.hasPrefix("- text:") {
                drafts.append(Draft(text: value(raw, after: "- text:")))
                pendingWord = nil
                target = .line
            } else if raw.hasPrefix("  start_ms:"), !drafts.isEmpty {
                drafts[drafts.count - 1].start = milliseconds(raw, after: "  start_ms:")
                target = .none
            } else if raw.hasPrefix("  end_ms:") || raw.hasPrefix("  words:") || raw.hasPrefix("    end_ms:") {
                target = .none
            } else if raw.hasPrefix("  - text:") {
                pendingWord = value(raw, after: "  - text:")
                target = .word
            } else if raw.hasPrefix("    start_ms:"), let word = pendingWord, !drafts.isEmpty {
                drafts[drafts.count - 1].words.append((unquote(word), milliseconds(raw, after: "    start_ms:")))
                pendingWord = nil
                target = .none
            } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty, raw.hasPrefix(" ") {
                // Long text wraps onto the next line; join it back on.
                let more = raw.trimmingCharacters(in: .whitespaces)
                switch target {
                case .line where !drafts.isEmpty: drafts[drafts.count - 1].text += " " + more
                case .word: pendingWord = (pendingWord ?? "") + " " + more
                default: break
                }
            }
        }

        return drafts
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { index, draft in
                LyricLine(
                    id: index,
                    text: unquote(draft.text),
                    start: draft.start,
                    words: draft.words.map { LyricWord(text: $0.text, start: $0.start) }
                )
            }
    }

    private static func unquote(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            if let data = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return decoded
            }
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

import Foundation
import SwiftUI
import MusicKit
import iTunesLibrary

struct LibrarySong: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let availability: Availability
    var duration: TimeInterval = 0
    var trackNumber = 0
    var hasCloudCopy = false

    var canStream: Bool {
        switch availability {
        case .cloud, .protected: return true
        case .local: return hasCloudCopy
        case .unavailable: return false
        }
    }

    enum Availability: Sendable {
        case local(URL)
        case cloud
        case protected
        case unavailable

        var url: URL? {
            if case .local(let url) = self { return url }
            return nil
        }

        var label: String {
            switch self {
            case .local: return "On this Mac"
            case .cloud: return "Cloud only"
            case .protected: return "Protected"
            case .unavailable: return "File unavailable"
            }
        }
    }

    static func readLibrary() throws -> [Self] {
        let library = try ITLibrary(apiVersion: "1.0")
        return library.allMediaItems.compactMap { item -> Self? in
            guard item.mediaKind == .kindSong else { return nil }
            let hasCloudCopy = item.isCloud || item.isPurchased
            let availability: Availability
            if item.isDRMProtected {
                availability = .protected
            } else if let url = item.location, url.isFileURL, isReadableLocalFile(url) {
                // Preserve the scoped URL supplied by iTunesLibrary for playback.
                availability = .local(url)
            } else {
                availability = hasCloudCopy ? .cloud : .unavailable
            }
            return Self(id: item.persistentID.stringValue,
                        title: item.title.isEmpty ? "Untitled Song" : item.title,
                        artist: item.artist?.name ?? "",
                        album: item.album.title ?? "",
                        availability: availability,
                        duration: Double(item.totalTime) / 1000,
                        trackNumber: item.trackNumber,
                        hasCloudCopy: hasCloudCopy)
        }
        .sorted(by: localFilesFirst)
    }

    static func isReadableLocalFile(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]) else { return false }
        return values.isRegularFile == true && values.isReadable == true
    }

    static func localFilesFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsIsLocal = lhs.availability.url != nil
        let rhsIsLocal = rhs.availability.url != nil
        if lhsIsLocal != rhsIsLocal { return lhsIsLocal }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func matches(_ query: String, showCloudSongs: Bool = true) -> Bool {
        guard showCloudSongs || availability.url != nil else { return false }
        return query.isEmpty || [title, artist, album].contains { $0.localizedStandardContains(query) }
    }

    func identifies(title: String, artist: String, album: String, duration: TimeInterval?) -> Bool {
        func equal(_ lhs: String, _ rhs: String) -> Bool {
            lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
        }
        guard equal(self.title, title),
              self.artist.isEmpty || equal(self.artist, artist),
              self.album.isEmpty || equal(self.album, album) else { return false }
        if self.duration > 0, let duration, duration > 0 {
            return abs(self.duration - duration) <= 2
        }
        return true
    }
}

struct MusicLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playback: MusicPlayback
    @ObservedObject var cloud: CloudMusicPlayback
    @Binding var showCloudSongs: Bool
    @State private var startingCloudSong = false
    @State private var songs: [LibrarySong] = []
    @State private var query = ""
    @State private var selection: LibrarySong.ID?
    @State private var loading = true
    @State private var loadError: String?
    @State private var playbackError: String?
    @State private var revision = 0

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = songs.filter { $0.matches(search, showCloudSongs: showCloudSongs) }
        let selected = visible.first { $0.id == selection }

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Music Library").font(.title2.bold())
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { revision += 1 }
                    .disabled(loading || startingCloudSong)
            }
            HStack(spacing: 16) {
                TextField("Search title, artist, or album", text: $query)
                    .disabled(songs.isEmpty)
                Toggle("Show cloud songs", isOn: $showCloudSongs)
                    .toggleStyle(.checkbox)
                    .disabled(startingCloudSong)
            }

            if loading {
                ProgressView("Reading Music library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 8) {
                    Text("Music library unavailable").font(.headline)
                    Text(loadError).foregroundStyle(.secondary)
                    Text("Check Media & Apple Music access in System Settings, or choose a file with Open Audio.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                Text(songs.isEmpty ? "The Music library has no songs to display."
                     : (showCloudSongs ? "No songs match your search." : "No local songs match. Check Show cloud songs to see more."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visible, selection: $selection) {
                    TableColumn("Title", value: \LibrarySong.title)
                    TableColumn("Artist", value: \LibrarySong.artist)
                    TableColumn("Album", value: \LibrarySong.album)
                    TableColumn("Availability") { song in
                        Text(song.availability.label).foregroundStyle(.secondary)
                    }
                    .width(min: 112, ideal: 125)
                }
            }

            if let playbackError {
                Text(playbackError).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                let total = songs.count
                let count = visible.count
                Text(search.isEmpty && showCloudSongs ? "\(total) songs" : "\(count) of \(total) songs")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(startingCloudSong)
                Button(startingCloudSong ? "Starting…" : "Play Song") {
                    guard let selected else { return }
                    play(selected)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || startingCloudSong || !canChoose(selected))
            }
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 820, minHeight: 390, idealHeight: 550)
        .interactiveDismissDisabled(startingCloudSong)
        .task(id: revision) {
            loading = true
            loadError = nil
            playbackError = nil
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LibrarySong.readLibrary() }
            }.value
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let songs):
                self.songs = songs
            case .failure(let error):
                self.songs = []
                selection = nil
                loadError = error.localizedDescription
            }
        }
    }

    private func canChoose(_ song: LibrarySong?) -> Bool {
        guard let song else { return false }
        if song.availability.url != nil { return true }
        guard #available(macOS 14.0, *) else { return false }
        return song.canStream
    }

    private func play(_ song: LibrarySong) {
        if let url = song.availability.url, playback.open(url, displayTitle: song.title) {
            cloud.stop()
            playback.play()
            dismiss()
        } else if #available(macOS 14.0, *), showCloudSongs, song.canStream {
            playCloud(song)
        } else {
            playbackError = playback.error
        }
    }

    @available(macOS 14.0, *)
    private func playCloud(_ selected: LibrarySong) {
        startingCloudSong = true
        playbackError = nil
        Task { @MainActor in
            defer { startingCloudSong = false }
            do {
                try await CloudMusicPlayback.withDeadline(seconds: 25) {
                    try await CloudMusicPlayback.retryAfterRefreshingToken {
                        let song = try await CloudMusicPlayback.findSong(selected)
                        try Task.checkCancellation()
                        playback.pause()
                        try await cloud.start(song)
                    }
                }
                playback.clearError()
                dismiss()
            } catch {
                cloud.cancelPendingStart()
                if case MusicTokenRequestError.developerTokenRequestFailed = error {
                    playbackError = "Apple Music couldn’t authorize this build after refreshing its token. Quit Trackpad Music and open the latest signed copy."
                } else {
                    playbackError = "Couldn’t play this cloud song. \(error.localizedDescription)"
                }
            }
        }
    }

}

// Apple provides the stream and transport. Audio samples remain inside MusicKit.
@MainActor
final class CloudMusicPlayback: ObservableObject {
    @Published private(set) var song: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var error: String?
    private var resuming = false
    private var pendingStart: UUID?

    var duration: TimeInterval {
        guard let duration = song?.duration, duration.isFinite else { return 0 }
        return max(0, duration)
    }

    static func retryAfterRefreshingToken<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch MusicTokenRequestError.developerTokenRequestFailed {
            try Task.checkCancellation()
            _ = try await MusicDataRequest.tokenProvider.developerToken(options: .ignoreCache)
            try Task.checkCancellation()
            return try await operation()
        }
    }

    @available(macOS 14.0, *)
    static func findSong(_ selected: LibrarySong) async throws -> Song {
        try await authorize()
        let librarySongs: [Song]
        do {
            librarySongs = try await withDeadline(seconds: 5) {
                var request = MusicLibraryRequest<Song>()
                request.filter(matching: \.title, equalTo: selected.title)
                return try await readSongs(request)
            }
        } catch MusicTokenRequestError.developerTokenRequestFailed {
            throw MusicTokenRequestError.developerTokenRequestFailed
        } catch {
            try Task.checkCancellation()
            librarySongs = []
        }
        if let song = selectVersion(librarySongs, for: selected) { return song }

        // Some tracks visible to iTunesLibrary have no playable library item in
        // MusicKit. Look up the selected release in the account's catalog.
        let catalogSongs = try await catalogVersions(of: selected)
        if let song = selectVersion(catalogSongs, for: selected) { return song }
        let candidates = catalogSongs.filter { matchesRelease($0, selected) }
        guard !candidates.isEmpty else { throw LibraryAccessError.songUnavailable }
        throw LibraryAccessError.ambiguous
    }

    private static func matchesRelease(_ song: Song, _ selected: LibrarySong) -> Bool {
        song.playParameters != nil && selected.identifies(
            title: song.title, artist: song.artistName,
            album: song.albumTitle ?? "", duration: nil
        )
    }

    private static func selectVersion(_ songs: [Song], for selected: LibrarySong) -> Song? {
        let candidates = songs.filter { matchesRelease($0, selected) }
        let numbered = candidates.filter { selected.trackNumber > 0 && $0.trackNumber == selected.trackNumber }
        let versions = numbered.isEmpty ? candidates : numbered
        let near = versions.filter {
            selected.identifies(title: $0.title, artist: $0.artistName,
                                album: $0.albumTitle ?? "", duration: $0.duration)
        }
        if near.count == 1 { return near.first }
        // The Mac and catalog metadata sometimes give the same release different
        // durations. A unique matching track number still identifies the release.
        if numbered.count == 1, !selected.album.isEmpty { return numbered.first }
        if let recording = near.first?.isrc, !recording.isEmpty,
           near.allSatisfy({ $0.isrc == recording }) { return near.first }
        return nil
    }

    private static func catalogVersions(of selected: LibrarySong) async throws -> [Song] {
        let term = [selected.title, selected.artist, selected.album]
            .filter { !$0.isEmpty }.joined(separator: " ")
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let songs = Array(try await request.response().songs)
        if selectVersion(songs, for: selected) != nil || selected.album.isEmpty { return songs }

        let release = [selected.album, selected.artist].filter { !$0.isEmpty }.joined(separator: " ")
        var albums = MusicCatalogSearchRequest(term: release, types: [Album.self])
        albums.limit = 10
        var result = songs
        for album in try await albums.response().albums
            where album.title.caseInsensitiveCompare(selected.album) == .orderedSame {
            try Task.checkCancellation()
            let expanded = try await album.with([.tracks])
            for track in expanded.tracks ?? [] {
                if case .song(let song) = track { result.append(song) }
            }
        }
        var seen = Set<MusicItemID>()
        return result.filter { seen.insert($0.id).inserted }
    }

    private static func authorize() async throws {
        guard await MusicAuthorization.request() == .authorized else {
            throw LibraryAccessError.denied
        }
        try Task.checkCancellation()
    }

    @available(macOS 14.0, *)
    private static func readSongs(_ request: MusicLibraryRequest<Song>) async throws -> [Song] {
        var request = request
        request.includeOnlyDownloadedContent = false
        request.limit = 100
        var batch = try await request.response().items
        var songs = Array(batch)
        while batch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await batch.nextBatch() else { break }
            songs.append(contentsOf: next)
            batch = next
        }
        var seen = Set<MusicItemID>()
        return songs.filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @available(macOS 14.0, *)
    func start(_ song: Song) async throws {
        try Task.checkCancellation()
        stop()
        let attempt = UUID()
        pendingStart = attempt
        defer { if pendingStart == attempt { pendingStart = nil } }
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        do {
            try await player.play()
            try Task.checkCancellation()
        } catch {
            if pendingStart == attempt || (pendingStart == nil && self.song == nil) { player.stop() }
            throw error
        }
        guard pendingStart == attempt else { throw CancellationError() }
        self.song = song
        error = nil
        refresh()
    }

    func cancelPendingStart() {
        guard #available(macOS 14.0, *), pendingStart != nil else { return }
        pendingStart = nil
        ApplicationMusicPlayer.shared.stop()
    }

    // A MusicKit request can outlive cancellation. The deadline returns control to
    // the UI immediately and the stream discards any result that arrives afterward.
    static func withDeadline<Value: Sendable>(
        seconds: Double = 15, operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let results = AsyncThrowingStream<Value, Error> { continuation in
            let request = Task { @MainActor in
                do {
                    continuation.yield(try await operation())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let deadline = Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    continuation.finish(throwing: LibraryAccessError.timedOut)
                } catch {}
            }
            continuation.onTermination = { _ in
                request.cancel()
                deadline.cancel()
            }
        }
        var iterator = results.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        return value
    }

    func togglePlayback() async {
        guard #available(macOS 14.0, *), song != nil, !resuming else { return }
        let player = ApplicationMusicPlayer.shared
        if player.state.playbackStatus == .playing {
            player.pause()
        } else {
            resuming = true
            defer { resuming = false }
            do {
                try await player.play()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        refresh()
    }

    func seek(to time: TimeInterval) {
        guard #available(macOS 14.0, *), song != nil, duration > 0, time.isFinite else { return }
        position = min(duration, max(0, time))
        ApplicationMusicPlayer.shared.playbackTime = position
    }

    func refresh() {
        guard #available(macOS 14.0, *), song != nil else { return }
        let player = ApplicationMusicPlayer.shared
        let playing = player.state.playbackStatus == .playing
        if isPlaying != playing { isPlaying = playing }
        let time = player.playbackTime
        if time.isFinite, position != max(0, time) { position = max(0, time) }
    }

    func stop() {
        guard #available(macOS 14.0, *), song != nil else { return }
        ApplicationMusicPlayer.shared.stop()
        song = nil
        isPlaying = false
        position = 0
        error = nil
    }

    private enum LibraryAccessError: LocalizedError {
        case denied, songUnavailable, ambiguous, timedOut

        var errorDescription: String? {
            switch self {
            case .denied: return "Allow Media & Apple Music access in System Settings to play cloud songs."
            case .songUnavailable: return "Apple Music didn’t return a playable match for this version of the song."
            case .ambiguous: return "More than one version of this song matched in Apple Music."
            case .timedOut: return "Apple Music didn’t respond. Check that Music is signed in and try again."
            }
        }
    }
}

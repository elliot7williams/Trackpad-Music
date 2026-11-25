import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class TrackpadMusicAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
    }
}

@main
struct TrackpadMusicApp: App {
    @NSApplicationDelegateAdaptor(TrackpadMusicAppDelegate.self) private var appDelegate
    @StateObject private var engine: HapticEngine
    @StateObject private var playback: MusicPlayback
    @StateObject private var cloud = CloudMusicPlayback()

    init() {
        let engine = HapticEngine()
        _engine = StateObject(wrappedValue: engine)
        _playback = StateObject(wrappedValue: MusicPlayback(engine: engine))
    }

    var body: some Scene {
        Window("Trackpad Music", id: "player") {
            PlayerView(engine: engine, playback: playback, cloud: cloud)
                .frame(minWidth: 540, minHeight: 520)
        }
        .defaultSize(width: 680, height: 730)
        .windowResizability(.contentMinSize)

        Settings {
            AccessibilitySettingsView(playback: playback)
        }
    }
}

private enum PlayerAccessibility {
    static let announcePlayback = "accessibility.announcePlayback"
    static let numericLevels = "accessibility.numericLevels"
    private static let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter
    }()

    static func announce(_ message: String) {
        guard NSApp.isActive, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func position(_ seconds: Double, of duration: Double) -> String {
        let elapsed = timeFormatter.string(from: seconds.isFinite ? max(0, seconds) : 0) ?? "0 seconds"
        let total = timeFormatter.string(from: duration.isFinite ? max(0, duration) : 0) ?? "0 seconds"
        return "\(elapsed) of \(total)"
    }
}

private struct AccessibilitySettingsView: View {
    @ObservedObject var playback: MusicPlayback
    @AppStorage(PlayerAccessibility.announcePlayback) private var announcePlayback = true
    @AppStorage(PlayerAccessibility.numericLevels) private var numericLevels = false

    var body: some View {
        Form {
            Section("VoiceOver") {
                Toggle("Announce playback changes", isOn: $announcePlayback)
                Text("VoiceOver announces the song title when playback starts or pauses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Visual feedback") {
                Toggle("Show numeric audio levels", isOn: $numericLevels)
                Text("Show percentages for bass, mids, and highs during local playback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
#if !APP_STORE
            Section("Trackpad feedback") {
                Picker("Trackpad output", selection: $playback.mode) {
                    ForEach(MusicHaptics.allCases) { Text($0.rawValue).tag($0) }
                }
                Slider(value: $playback.intensity, in: 0...1, step: 0.05) { Text("Haptic intensity") }
                    .accessibilityValue(playback.intensity.formatted(.percent.precision(.fractionLength(0))))
                    .disabled(playback.mode == .off)
                Text("Choose Bass Boost to feel low frequencies or Third Speaker for a wider range. Cloud playback can use the optional microphone feedback switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
#endif
        }
        .formStyle(.grouped)
        .frame(width: 490)
        .padding(.vertical, 12)
    }
}

private struct PlayerView: View {
    @ObservedObject var engine: HapticEngine
    @ObservedObject var playback: MusicPlayback
    @ObservedObject var cloud: CloudMusicPlayback
    @AppStorage(PlayerAccessibility.announcePlayback) private var announcePlayback = true
    @AppStorage(PlayerAccessibility.numericLevels) private var numericLevels = false
    @State private var importing = false
    @State private var showingLibrary = false
    @State private var showCloudSongs = true
    @State private var connectedOnLaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let song = cloud.song {
                    cloudTransport(title: song.title, artist: song.artistName)
#if !APP_STORE
                    microphoneFeedback
#endif
                } else {
                    transport
                    liveAudio
                    synth
#if !APP_STORE
                    haptics
                    connection
#endif
                }
                if let error = playback.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 740)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !connectedOnLaunch else { return }
            connectedOnLaunch = true
#if !APP_STORE
            playback.connectTrackpad()
#endif
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                if playback.open(url) { cloud.stop() }
            case .failure(let error): playback.reportImportFailure(error)
            }
        }
        .sheet(isPresented: $showingLibrary) {
            MusicLibraryView(playback: playback, cloud: cloud, showCloudSongs: $showCloudSongs)
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            cloud.refresh()
        }
        .onChange(of: playbackAnnouncement) { message in
            if announcePlayback, let message { PlayerAccessibility.announce(message) }
        }
#if !APP_STORE
        .onReceive(cloud.$isPlaying.removeDuplicates()) { playback.setCloudPlaying($0) }
        .onDisappear { playback.setMicrophoneEnabled(false) }
#endif
    }

    private var playbackAnnouncement: String? {
        if let song = cloud.song {
            return cloud.isPlaying ? "Playing \(song.title)." : "Paused \(song.title)."
        }
        guard !playback.title.isEmpty else { return nil }
        if playback.isPlaying { return "Playing \(playback.title)." }
        if playback.position >= playback.duration { return "Finished \(playback.title)." }
        return playback.position > 0 ? "Paused \(playback.title)." : nil
    }

    private func cloudTransport(title: String, artist: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    Task { await cloud.togglePlayback() }
                } label: {
                    Image(systemName: cloud.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(cloud.isPlaying ? "Pause" : "Play")
                VStack(alignment: .leading) {
                    Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(artist).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Stop") { cloud.stop() }
            }
            if cloud.duration > 0 {
                Slider(value: Binding(get: { min(cloud.position, cloud.duration) },
                                      set: { cloud.seek(to: $0) }), in: 0...cloud.duration) {
                    Text("Cloud playback position")
                }
                .labelsHidden()
                .accessibilityValue(PlayerAccessibility.position(min(cloud.position, cloud.duration), of: cloud.duration))
                HStack {
                    Text(timestamp(cloud.position))
                    Spacer()
                    Text(timestamp(cloud.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Label(cloud.isPlaying ? "Cloud playback · Playing" : "Cloud playback · Paused", systemImage: "icloud")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = cloud.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack {
            Text("Trackpad Music")
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showingLibrary = true } label: {
                Label("Music Library", systemImage: "music.note.list")
            }
            .keyboardShortcut("l", modifiers: .command)
            .controlSize(.large)
            Button { importing = true } label: {
                Label("Open Audio…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if playback.isPlaying { playback.pause() } else { playback.play() }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])
                .disabled(playback.duration == 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.title.isEmpty ? "Choose a song to play" : playback.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if playback.analyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing audio")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Speakers", isOn: $playback.speakersEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    #if APP_STORE
                    .help("Mute the song and reactive synth.")
#else
                    .help("Turn off this app’s normal audio output to hear the trackpad on its own.")
#endif
            }

            Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                   in: 0...max(0.001, playback.duration)) {
                Text("Playback position")
            }
            .labelsHidden()
            .accessibilityValue(PlayerAccessibility.position(playback.position, of: playback.duration))
            .disabled(playback.duration == 0)
            HStack {
                Text(timestamp(playback.position))
                Spacer()
                Text(timestamp(playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var liveAudio: some View {
        let frame = playback.liveFrame
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live audio").font(.headline)
                Spacer()
                Text(playback.isPlaying ? "Playing" : "Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let middle = size.height / 2
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: middle))
                axis.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(axis, with: .color(.teal.opacity(0.35)))
                guard let samples = frame?.waveform, samples.count > 1 else { return }
                var trace = Path()
                for (index, sample) in samples.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                    let y = middle - CGFloat(sample) * middle * 0.92
                    if index == 0 { trace.move(to: CGPoint(x: x, y: y)) }
                    else { trace.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(trace, with: .color(Color(red: 0.41, green: 0.97, blue: 0.83)),
                               style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            .padding(10)
            .frame(height: 88)
            .background(Color(red: 0.035, green: 0.09, blue: 0.13), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                bandMeter("Bass", tone: frame?.bass, tint: .teal)
                bandMeter("Mids", tone: frame?.mids, tint: .blue)
                bandMeter("Highs", tone: frame?.highs, tint: .indigo)
            }
        }
    }

    private func bandMeter(_ label: String, tone: MusicFrame.Tone?, tint: Color) -> some View {
        let level = min(1, sqrt(tone?.strength ?? 0))
        let percent = level.formatted(.percent.precision(.fractionLength(0)))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                if numericLevels {
                    Spacer()
                    Text(percent).monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            ProgressView(value: level)
                .tint(tint)
                .accessibilityLabel("\(label) level")
                .accessibilityValue(percent)
        }
    }

    private var synth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Reactive bass synth", isOn: $playback.synthEnabled)
                .toggleStyle(.switch)
                .font(.headline)
            if playback.synthEnabled {
                HStack {
                    Text("Synth mix")
                    Slider(value: $playback.synthMix, in: 0...1) { Text("Synth mix") }
                        .labelsHidden()
                    Text(playback.synthMix, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                if playback.analyzing || playback.preparingSynth {
                    Text("Preparing synth").font(.caption).foregroundStyle(.secondary)
                } else if !playback.speakersEnabled {
                    Text("Synth audio is muted with Speakers off.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if playback.synthIsPlaying && playback.synthMix > 0 {
                    Label("Synth playing", systemImage: "waveform")
                        .font(.caption).foregroundStyle(.teal)
                }
            }
        }
    }

#if !APP_STORE
    private var microphoneFeedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Microphone feedback", isOn: Binding(get: { playback.microphoneEnabled },
                                                       set: { playback.setMicrophoneEnabled($0) }))
                .toggleStyle(.switch)
            Text("Use nearby sound to drive the trackpad. Microphone audio is processed live on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = playback.microphoneError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if playback.microphoneEnabled {
                Text(playback.microphoneListening ? "Listening" : (cloud.isPlaying ? "Starting microphone…" : "Waiting for playback"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                haptics
                connection
            }
        }
    }

    private var haptics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trackpad output").font(.headline)
            Picker("Trackpad output", selection: $playback.mode) {
                ForEach(MusicHaptics.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(playback.mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("Intensity")
                Slider(value: $playback.intensity, in: 0...1) { Text("Haptic intensity") }
                    .labelsHidden()
                    .disabled(playback.mode == .off)
                Text(playback.intensity, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            ProgressView(value: playback.outputLevel)
                .accessibilityLabel("Trackpad signal")
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Image(systemName: "trackpad")
                    .foregroundStyle(engine.isConnected ? Color.accentColor : Color.secondary)
                Text(playback.connecting ? "Connecting…" : engine.motorInfo)
                Spacer()
                Picker("Device", selection: $playback.preferExternal) {
                    Text("Automatic").tag(false)
                    Text("Magic Trackpad").tag(true)
                }
                .fixedSize()
                .disabled(playback.connecting)
                .onChange(of: playback.preferExternal) { _ in playback.connectTrackpad() }
                Button("Reconnect") { playback.connectTrackpad() }
                    .disabled(playback.connecting)
            }
            .font(.callout)
            if !engine.statusMessage.isEmpty && !playback.connecting {
                Text(engine.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

#endif

    private func timestamp(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

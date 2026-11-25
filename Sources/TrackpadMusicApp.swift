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

    init() {
        let engine = HapticEngine()
        _engine = StateObject(wrappedValue: engine)
        _playback = StateObject(wrappedValue: MusicPlayback(engine: engine))
    }

    var body: some Scene {
        Window("Trackpad Music", id: "player") {
            PlayerView(engine: engine, playback: playback)
                .frame(minWidth: 540, minHeight: 520)
        }
        .defaultSize(width: 680, height: 730)
        .windowResizability(.contentMinSize)
    }
}

private struct PlayerView: View {
    @ObservedObject var engine: HapticEngine
    @ObservedObject var playback: MusicPlayback
    @State private var importing = false
    @State private var connectedOnLaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                transport
                liveAudio
                synth
#if !APP_STORE
                haptics
                connection
#endif
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
            case .success(let url): playback.open(url)
            case .failure(let error): playback.reportImportFailure(error)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Trackpad Music")
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
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
        let strength = tone?.strength ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ProgressView(value: min(1, sqrt(strength)))
                .tint(tint)
                .accessibilityLabel("\(label) level")
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

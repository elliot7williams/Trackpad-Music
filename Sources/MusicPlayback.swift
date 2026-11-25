import Accelerate
import AVFoundation
import Combine
import Foundation

enum MusicHaptics: String, CaseIterable, Identifiable {
    case off = "Off"
    case bass = "Bass Boost"
    case wide = "Third Speaker"

    var id: Self { self }

    var detail: String {
        switch self {
        case .off: return "Play through your normal audio output."
        case .bass: return "Feel bass notes and kick drums through the trackpad."
        case .wide: return "Play a simplified mix of bass, mids, and highs through the trackpad."
        }
    }
}

struct MusicFrame {
    struct Tone {
        let hz: Double
        let strength: Double
    }

    let bass: Tone
    let mids: Tone
    let highs: Tone
    let waveform: [Float]

    // One tone per band keeps the motor workload bounded.
    func output(for mode: MusicHaptics) -> [(hz: Double, amp: Double)] {
        let tones: [(Tone, Double)]
        switch mode {
        case .off: return []
        case .bass: tones = [(bass, 1.25)]
        case .wide: tones = [(bass, 0.95), (mids, 0.75), (highs, 0.55)]
        }
        return tones.compactMap { tone, weight in
            let amp = tone.strength * weight
            return amp >= 0.008 ? (tone.hz, amp) : nil
        }
    }
}

enum MusicAnalysis {
    struct Result {
        let frameDuration: Double
        let frames: [MusicFrame]
    }

    private static let targetFrameDuration = 0.032

    // Window each frame and measure stereo channels independently so
    // instruments panned left or right, or out of phase, still contribute.
    static func read(_ url: URL, cancel: StopFlag) throws -> Result {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = min(2, Int(format.channelCount))
        guard rate.isFinite, (1...768_000).contains(rate), channels > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let stride = max(1, Int(rate / 12_000))
        let count = max(2, Int(rate * targetFrameDuration) / stride)
        let frameSize = count * stride
        // Zero padding makes the frequency grid finer without lengthening the frame.
        let logSize = vDSP_Length(ceil(log2(Double(2 * count))))
        let fftSize = 1 << logSize
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)),
              let fft = vDSP_create_fftsetupD(logSize, FFTRadix(kFFTRadix2)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { vDSP_destroy_fftsetupD(fft) }

        let binWidth = rate / Double(stride * fftSize)
        let bands: [Range<Double>] = [28..<180, 180..<1800, 1800..<4000]
        let bins = bands.map { band in
            let begin = Int(ceil(band.lowerBound / binWidth))
            let end = min(fftSize / 2, Int(ceil(band.upperBound / binWidth)))
            return begin..<max(begin, end)
        }
        let window = (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count - 1)) }
        let windowGain = max(1, window.reduce(0, +))
        var real = [Double](repeating: 0, count: fftSize)
        var imag = real
        var power = [Double](repeating: 0, count: fftSize / 2)
        var frames: [MusicFrame] = []
        let fileLength = file.length
        while !cancel.isSet, file.framePosition < fileLength {
            let remaining = fileLength - file.framePosition
            let requested = AVAudioFrameCount(min(Int64(frameSize), remaining))
            try file.read(into: buffer, frameCount: requested)
            let length = Int(buffer.frameLength)
            guard length > 0, let data = buffer.floatChannelData else { break }
            for i in power.indices { power[i] = 0 }
            for channel in 0..<channels {
                let source = data[channel]
                for i in 0..<count {
                    let begin = i * stride
                    var sum = 0.0
                    if begin < length {
                        for j in begin..<min(begin + stride, length) { sum += Double(source[j]) }
                    }
                    real[i] = sum * window[i] / Double(stride)
                }
                for i in count..<fftSize { real[i] = 0 }
                for i in imag.indices { imag[i] = 0 }
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imag.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                        vDSP_fft_zipD(fft, &split, 1, logSize, FFTDirection(FFT_FORWARD))
                    }
                }
                for i in power.indices {
                    power[i] += real[i] * real[i] + imag[i] * imag[i]
                }
            }

            func peak(in band: Range<Int>) -> MusicFrame.Tone {
                guard let index = band.max(by: { power[$0] < power[$1] }), power[index].isFinite else {
                    return .init(hz: 0, strength: 0)
                }
                let strength = sqrt(power[index] / Double(channels)) * 2 / windowGain
                return .init(hz: Double(index) * binWidth, strength: strength)
            }
            let waveform = (0..<96).map { i -> Float in
                let sample = i * frameSize / 96
                guard sample < length else { return 0 }
                let left = data[0][sample]
                let right = channels > 1 ? data[1][sample] : left
                let value = abs(left) >= abs(right) ? left : right
                return value.isFinite ? min(1, max(-1, value)) : 0
            }
            frames.append(.init(bass: peak(in: bins[0]), mids: peak(in: bins[1]),
                                highs: peak(in: bins[2]), waveform: waveform))
        }
        return Result(frameDuration: Double(frameSize) / rate, frames: frames)
    }
}

final class MusicPlayback: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var analyzing = false
    @Published private(set) var outputLevel = 0.0
    @Published private(set) var error: String?
    @Published private(set) var liveFrame: MusicFrame?
    @Published private(set) var preparingSynth = false
    @Published var synthEnabled = false {
        didSet {
            updateSpeakerLevels()
            if synthEnabled { prepareSynth() } else { synthPlayer?.pause() }
        }
    }
    @Published var synthMix = 0.35 {
        didSet { updateSpeakerLevels() }
    }
    @Published var mode = MusicHaptics.bass {
        didSet {
            invalidateMotorFrame()
            outputLevel = 0
        }
    }
    @Published var intensity = 0.55 {
        didSet {
            if intensity == 0 {
                invalidateMotorFrame()
                outputLevel = 0
            }
        }
    }
    @Published var speakersEnabled = true {
        didSet { updateSpeakerLevels() }
    }

    private let engine: HapticEngine
    private let analysisQueue = DispatchQueue(label: "TrackpadMusic.analysis", qos: .userInitiated)
    private let motorQueue = DispatchQueue(label: "TrackpadMusic.haptics", qos: .userInteractive)
    private var player: AVAudioPlayer?
    private var synthPlayer: AVAudioPlayer?
    private var synthURL: URL?
    private var scopedURL: URL?
    private var spectrum: MusicAnalysis.Result?
    private var analysis = StopFlag()
    private var motorSession = StopFlag()
    private var timer: Timer?
    private var lastFrame: Int?
    private var lastVisualFrame: Int?
    private var motorBusy = false
    @Published private(set) var connecting = false
    @Published var preferExternal = false
    var synthIsPlaying: Bool { synthEnabled && speakersEnabled && synthPlayer?.isPlaying == true }

    init(engine: HapticEngine) {
        self.engine = engine
    }

#if !APP_STORE
    func connectTrackpad() {
        guard !connecting else { return }
        connecting = true
        let preference = preferExternal
        let engine = engine
        motorQueue.async { [weak self] in
            engine.connect(preferExternal: preference)
            DispatchQueue.main.async { [weak self] in self?.connecting = false }
        }
    }

#endif

    deinit {
        timer?.invalidate()
        analysis.set()
        motorSession.set()
        if let synthURL { try? FileManager.default.removeItem(at: synthURL) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        let next: AVAudioPlayer
        do {
            next = try AVAudioPlayer(contentsOf: url)
            guard next.duration.isFinite, next.duration > 0, next.prepareToPlay() else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            self.error = "Couldn’t open \(url.lastPathComponent). Choose a local audio file that macOS can play."
            return
        }

        pause()
        player = next
        synthPlayer = nil
        if let synthURL { try? FileManager.default.removeItem(at: synthURL) }
        synthURL = nil
        preparingSynth = false
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = access ? url : nil
        updateSpeakerLevels()
        title = url.deletingPathExtension().lastPathComponent
        duration = next.duration
        position = 0
        error = nil
        spectrum = nil
        liveFrame = nil
        lastVisualFrame = nil
        analysis.set()
        let cancel = StopFlag()
        analysis = cancel
        analyzing = true

        // Keep the analysis read authorized even if a new file replaces this one.
        let analysisAccess = url.startAccessingSecurityScopedResource()
        analysisQueue.async { [weak self] in
            defer { if analysisAccess { url.stopAccessingSecurityScopedResource() } }
            guard !cancel.isSet else { return }
            let result = Result { try MusicAnalysis.read(url, cancel: cancel) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.analysis === cancel else { return }
                self.analyzing = false
                switch result {
                case .success(let spectrum) where !spectrum.frames.isEmpty:
                    self.spectrum = spectrum
                    if self.synthEnabled { self.prepareSynth() }
                default:
                    self.error = "Trackpad analysis failed. Speaker playback is still available."
                }
            }
        }
    }

    func reportImportFailure(_ error: Error) {
        self.error = error.localizedDescription
    }

    func play() {
        guard let player, !isPlaying else { return }
        motorSession = StopFlag()
        lastFrame = nil
        if position >= duration { seek(to: 0) }
        guard player.play() else {
            error = "Couldn’t start audio playback."
            return
        }
        isPlaying = true
        startSynthAlongsideSong()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        synthPlayer?.pause()
        position = player?.currentTime ?? position
        endPlayback()
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        invalidateMotorFrame()
        position = min(duration, max(0, seconds))
        player.currentTime = position
        lastVisualFrame = nil
        liveFrame = nil
        startSynthAlongsideSong()
    }

    private func invalidateMotorFrame() {
        motorSession.set()
        motorSession = StopFlag()
        lastFrame = nil
    }

    private func endPlayback() {
        timer?.invalidate()
        timer = nil
        motorSession.set()
        synthPlayer?.pause()
        isPlaying = false
        outputLevel = 0
        liveFrame = nil
        lastVisualFrame = nil
    }

    private func tick() {
        guard let player, player.isPlaying else {
            position = duration
            endPlayback()
            return
        }
        let time = player.currentTime
        guard time.isFinite, time >= 0 else { return }
        if abs(position - time) >= 0.05 { position = time }
        guard let spectrum else { return }
        let index = Int(time / spectrum.frameDuration)
        guard spectrum.frames.indices.contains(index) else { return }
        let frame = spectrum.frames[index]
        if lastVisualFrame != index {
            lastVisualFrame = index
            liveFrame = frame
        }
#if !APP_STORE
        guard engine.isConnected, !connecting, mode != .off, intensity > 0 else {
            outputLevel = 0
            return
        }
        guard lastFrame != index, !motorBusy else { return }
        lastFrame = index
        let tones = frame.output(for: mode)
        let level = min(1, sqrt(tones.reduce(0) { $0 + $1.amp }) * intensity)
        outputLevel = level
        guard !tones.isEmpty else { return }

        let session = motorSession
        let engine = engine
        // Shorten a late frame so its actuation ends near the next audio frame.
        let remaining = Double(index + 1) * spectrum.frameDuration - time
        guard remaining > 0.005 else { return }
        motorBusy = true
        motorQueue.async { [weak self] in
            if !session.isSet {
                engine.play(tones, ms: remaining * 1000, level: Float(level))
            }
            DispatchQueue.main.async { [weak self] in self?.motorBusy = false }
        }
#endif
    }

    private func updateSpeakerLevels() {
        let mix = synthEnabled && synthPlayer != nil && speakersEnabled ? Float(synthMix) : 0
        // Leave headroom for the synth's bounded oscillator output.
        player?.volume = speakersEnabled ? 1 - 0.48 * mix : 0
        synthPlayer?.volume = mix
    }

    private func prepareSynth() {
        if synthPlayer != nil {
            startSynthAlongsideSong()
            return
        }
        guard let spectrum, !preparingSynth else { return }
        preparingSynth = true
        let token = analysis
        let duration = duration
        analysisQueue.async { [weak self] in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("trackpad-synth-\(UUID().uuidString).caf")
            let result = Result { try ReactiveSynth.render(spectrum, duration: duration, to: url, cancel: token) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.analysis === token else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.preparingSynth = false
                do {
                    try result.get()
                    let synth = try AVAudioPlayer(contentsOf: url)
                    guard synth.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                    self.synthURL = url
                    self.synthPlayer = synth
                    self.updateSpeakerLevels()
                    self.startSynthAlongsideSong()
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    self.synthEnabled = false
                    self.error = "Couldn’t prepare the reactive synth."
                }
            }
        }
    }

    private func startSynthAlongsideSong() {
        guard synthEnabled, isPlaying, let synth = synthPlayer, let player else { return }
        synth.pause()
        let lead = 0.04
        let start = player.deviceCurrentTime + lead
        let offset = player.currentTime + lead
        guard offset < synth.duration else { return }
        synth.currentTime = offset
        if !synth.play(atTime: start) {
            synthEnabled = false
            error = "Couldn’t start the reactive synth."
        }
    }
}

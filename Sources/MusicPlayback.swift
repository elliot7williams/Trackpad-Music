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
    func output(for mode: MusicHaptics, gain: Double = 1) -> [(hz: Double, amp: Double)] {
        let tones: [(Tone, Double)]
        switch mode {
        case .off: return []
        case .bass: tones = [(bass, 1.25)]
        case .wide: tones = [(bass, 0.95), (mids, 0.75), (highs, 0.55)]
        }
        return tones.compactMap { tone, weight in
            let amp = tone.strength * weight * gain
            return amp >= 0.008 ? (tone.hz, amp) : nil
        }
    }
}

enum MusicAnalysis {
    struct Result {
        let frameDuration: Double
        let frames: [MusicFrame]
    }

    static func read(_ url: URL, cancel: StopFlag) throws -> Result {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard let analyzer = MusicFrameAnalyzer(format: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(analyzer.frameSize)) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var frames: [MusicFrame] = []
        let fileLength = file.length
        while !cancel.isSet, file.framePosition < fileLength {
            let remaining = fileLength - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(analyzer.frameSize), remaining)))
            guard let frame = analyzer.analyze(buffer) else { break }
            frames.append(frame)
        }
        return Result(frameDuration: analyzer.frameDuration, frames: frames)
    }
}

// A single consumer owns each analyzer and its reusable FFT buffers.
final class MusicFrameAnalyzer {
    let frameSize: Int
    let frameDuration: Double
    private let channels: Int
    private let stride: Int
    private let count: Int
    private let logSize: vDSP_Length
    private let fft: FFTSetupD
    private let binWidth: Double
    private let bins: [Range<Int>]
    private let window: [Double]
    private let windowGain: Double
    private var real: [Double]
    private var imag: [Double]
    private var power: [Double]

    init?(format: AVAudioFormat) {
        let rate = format.sampleRate
        channels = min(2, Int(format.channelCount))
        guard rate.isFinite, (1...768_000).contains(rate), channels > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return nil }

        let stride = max(1, Int(rate / 12_000))
        let count = max(2, Int(rate * 0.032) / stride)
        self.stride = stride
        self.count = count
        frameSize = count * stride
        frameDuration = Double(frameSize) / rate
        // Zero padding makes the frequency grid finer without lengthening the frame.
        logSize = vDSP_Length(ceil(log2(Double(2 * count))))
        let fftSize = 1 << logSize
        guard let fft = vDSP_create_fftsetupD(logSize, FFTRadix(kFFTRadix2)) else { return nil }
        self.fft = fft

        let binWidth = rate / Double(stride * fftSize)
        self.binWidth = binWidth
        let bands: [Range<Double>] = [28..<180, 180..<1800, 1800..<4000]
        bins = bands.map { band in
            let begin = Int(ceil(band.lowerBound / binWidth))
            let end = min(fftSize / 2, Int(ceil(band.upperBound / binWidth)))
            return begin..<max(begin, end)
        }
        let window = (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count - 1)) }
        self.window = window
        windowGain = max(1, window.reduce(0, +))
        real = [Double](repeating: 0, count: fftSize)
        imag = [Double](repeating: 0, count: fftSize)
        power = [Double](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetupD(fft) }

    func analyze(_ buffer: AVAudioPCMBuffer) -> MusicFrame? {
        let length = min(frameSize, Int(buffer.frameLength))
        guard length > 0, let data = buffer.floatChannelData else { return nil }
        for i in power.indices { power[i] = 0 }
        // Analyze channels separately so out-of-phase stereo does not cancel out.
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
            for i in count..<real.count { real[i] = 0 }
            for i in imag.indices { imag[i] = 0 }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zipD(fft, &split, 1, logSize, FFTDirection(FFT_FORWARD))
                }
            }
            for i in power.indices { power[i] += real[i] * real[i] + imag[i] * imag[i] }
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
        return .init(bass: peak(in: bins[0]), mids: peak(in: bins[1]),
                     highs: peak(in: bins[2]), waveform: waveform)
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
#if !APP_STORE
    @Published private(set) var microphoneEnabled = false
    @Published private(set) var microphoneListening = false
    @Published private(set) var microphoneError: String?
    private var cloudPlaying = false
    private var microphoneRequest: Task<Void, Never>?
    private var microphoneInput: MicrophoneHapticsInput?
    private var microphoneTimer: Timer?
#endif
    @Published private(set) var connecting = false
    @Published var preferExternal = false
    var synthIsPlaying: Bool { synthEnabled && speakersEnabled && synthPlayer?.isPlaying == true }

    init(engine: HapticEngine) {
        self.engine = engine
    }

#if !APP_STORE
    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
        microphoneError = nil
        updateMicrophone()
    }

    func setCloudPlaying(_ playing: Bool) {
        guard playing != cloudPlaying else { return }
        cloudPlaying = playing
        updateMicrophone()
    }

    private func updateMicrophone() {
        guard microphoneEnabled, cloudPlaying else {
            stopMicrophone()
            return
        }
        guard microphoneInput == nil, microphoneRequest == nil else { return }
        microphoneRequest = Task { @MainActor [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self, !Task.isCancelled else { return }
            microphoneRequest = nil
            guard allowed else {
                microphoneEnabled = false
                microphoneError = "Allow microphone access in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                microphoneInput = try MicrophoneHapticsInput()
                invalidateMotorFrame()
                microphoneListening = true
                startMicrophonePolling()
            } catch {
                microphoneEnabled = false
                microphoneError = "Couldn’t start the microphone. \(error.localizedDescription)"
            }
        }
    }

    private func startMicrophonePolling() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.readMicrophone() }
        microphoneTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMicrophone() {
        microphoneRequest?.cancel()
        microphoneRequest = nil
        microphoneTimer?.invalidate()
        microphoneTimer = nil
        if let microphoneInput {
            microphoneInput.stop()
            self.microphoneInput = nil
            invalidateMotorFrame()
            outputLevel = 0
        }
        microphoneListening = false
    }

    private func readMicrophone() {
        guard let microphoneInput else { return }
        guard microphoneInput.isRunning else {
            setMicrophoneEnabled(false)
            microphoneError = "The audio input changed or stopped. Turn Microphone feedback on to reconnect."
            return
        }
        guard let frame = microphoneInput.takeFrame() else { return }
        // Limit motor strength because the microphone can also hear the trackpad.
        sendHaptics(frame, duration: microphoneInput.frameDuration, gain: 3, maximumLevel: 0.45)
    }

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
#if !APP_STORE
        microphoneRequest?.cancel()
        microphoneTimer?.invalidate()
        microphoneInput?.stop()
#endif
        timer?.invalidate()
        analysis.set()
        motorSession.set()
        if let synthURL { try? FileManager.default.removeItem(at: synthURL) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    @discardableResult
    func open(_ url: URL, displayTitle: String? = nil) -> Bool {
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
            return false
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
        title = displayTitle ?? url.deletingPathExtension().lastPathComponent
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
        return true
    }

    func reportImportFailure(_ error: Error) {
        self.error = error.localizedDescription
    }

    func clearError() {
        error = nil
    }

    func play() {
        guard let player, !isPlaying else { return }
#if !APP_STORE
        setCloudPlaying(false)
#endif
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
        guard lastFrame != index else { return }
        lastFrame = index
        // Shorten a late frame so its actuation ends near the next audio frame.
        let remaining = Double(index + 1) * spectrum.frameDuration - time
        sendHaptics(frame, duration: remaining)
#endif
    }

#if !APP_STORE
    private func sendHaptics(_ frame: MusicFrame, duration: Double, gain: Double = 1, maximumLevel: Double = 1) {
        guard engine.isConnected, !connecting, mode != .off, intensity > 0 else {
            outputLevel = 0
            return
        }
        let tones = frame.output(for: mode, gain: gain)
        let level = min(maximumLevel, sqrt(tones.reduce(0) { $0 + $1.amp }) * intensity)
        outputLevel = level
        guard !tones.isEmpty, duration > 0.005, !motorBusy else { return }

        let session = motorSession
        let engine = engine
        motorBusy = true
        motorQueue.async { [weak self] in
            if !session.isSet {
                engine.play(tones, ms: duration * 1000, level: Float(level))
            }
            DispatchQueue.main.async { [weak self] in self?.motorBusy = false }
        }
    }
#endif

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

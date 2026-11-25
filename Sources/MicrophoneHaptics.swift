#if !APP_STORE
import AVFoundation
import Foundation

// The tap keeps only one analyzed frame, so neither PCM nor callbacks accumulate.
final class MicrophoneHapticsInput {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var latest: MusicFrame?
    let frameDuration: Double

    var isRunning: Bool { engine.isRunning }

    init() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let analyzer = MusicFrameAnalyzer(format: format),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(analyzer.frameSize)) else {
            throw InputError.unavailable
        }

        frameDuration = analyzer.frameDuration
        let channels = min(2, Int(format.channelCount))
        var filled = 0
        input.installTap(onBus: 0, bufferSize: scratch.frameCapacity, format: nil) { [weak self] buffer, _ in
            guard let self, buffer.format.sampleRate == format.sampleRate,
                  Int(buffer.format.channelCount) >= channels,
                  let source = buffer.floatChannelData, let destination = scratch.floatChannelData else { return }
            let length = Int(buffer.frameLength)
            var offset = 0
            while offset < length {
                let count = min(analyzer.frameSize - filled, length - offset)
                for channel in 0..<channels {
                    destination[channel].advanced(by: filled).update(from: source[channel].advanced(by: offset), count: count)
                }
                offset += count
                filled += count
                if filled == analyzer.frameSize {
                    scratch.frameLength = scratch.frameCapacity
                    if let frame = analyzer.analyze(scratch), self.lock.try() {
                        self.latest = frame
                        self.lock.unlock()
                    }
                    filled = 0
                }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func takeFrame() -> MusicFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = latest
        latest = nil
        return frame
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        _ = takeFrame()
    }

    enum InputError: LocalizedError {
        case unavailable

        var errorDescription: String? { "No usable microphone input is available." }
    }
}
#endif

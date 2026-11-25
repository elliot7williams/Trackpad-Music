import AVFoundation
import Foundation

enum ReactiveSynth {
    static func render(_ spectrum: MusicAnalysis.Result, duration: Double, to url: URL, cancel: StopFlag) throws {
        let rate = 24_000.0
        let totalSamples = Int((duration * rate).rounded())
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }

        let tau = 2 * Double.pi
        let attack = 1 - exp(-1 / (rate * 0.008))
        let release = 1 - exp(-1 / (rate * 0.035))
        let glide = 1 - exp(-1 / (rate * 0.012))
        var phase = 0.0, pitch = 55.0, amplitude = 0.0
        var targetPitch = pitch, targetAmplitude = 0.0
        var sample = 0, currentFrame = -1
        while sample < totalSamples {
            if cancel.isSet { throw CancellationError() }
            let count = min(Int(buffer.frameCapacity), totalSamples - sample)
            for i in 0..<count {
                let time = Double(sample + i) / rate
                let index = Int(time / spectrum.frameDuration)
                if index != currentFrame {
                    currentFrame = index
                    targetAmplitude = 0
                    if spectrum.frames.indices.contains(index) {
                        let bass = spectrum.frames[index].bass
                        if bass.strength >= 0.012 {
                            targetPitch = min(110, max(34, bass.hz > 110 ? bass.hz * 0.5 : bass.hz))
                            targetAmplitude = min(0.36, bass.strength * 0.75)
                        }
                    }
                }
                pitch += (targetPitch - pitch) * glide
                amplitude += (targetAmplitude - amplitude) * (targetAmplitude > amplitude ? attack : release)
                phase += tau * pitch / rate
                if phase >= tau { phase -= tau }
                let fadeOut = min(1, max(0, (duration - time) / 0.015))
                output[i] = Float((sin(phase) + 0.24 * sin(phase * 2) + 0.09 * sin(phase * 3))
                                  * amplitude * fadeOut)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            sample += count
        }
    }
}

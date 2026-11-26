import Foundation
import AVFoundation

/// Plays raw PCM (s16le, 48 kHz, stereo) forwarded by the bridge.
/// Ring buffer feeds an AVAudioSourceNode — near-instant start, tiny latency.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()
    private var fifo: [Int16] = []          // interleaved s16le samples
    private let maxSamples = 48000 * 2 / 2  // 0.5 s of stereo
    private var started = false
    var muted = false

    func enqueue(_ pcm: Data) {
        var samples = [Int16](repeating: 0, count: pcm.count / 2)
        _ = samples.withUnsafeMutableBytes { dst in
            pcm.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!, min(dst.count, src.count))
            }
        }
        lock.lock()
        fifo.append(contentsOf: samples)
        if fifo.count > maxSamples {
            fifo.removeFirst(fifo.count - maxSamples)
        }
        lock.unlock()
    }

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default,
                                 options: [.allowBluetoothA2DP])
        try? session.setActive(true)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48000, channels: 2,
                                         interleaved: false) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            self.lock.lock()
            let muted = self.muted
            var outL = [Float](repeating: 0, count: n)
            var outR = [Float](repeating: 0, count: n)
            if !muted {
                var i = 0
                while i < n && self.fifo.count >= 2 {
                    outL[i] = Float(self.fifo.removeFirst()) / 32768.0
                    outR[i] = Float(self.fifo.removeFirst()) / 32768.0
                    i += 1
                }
            } else {
                self.fifo.removeAll(keepingCapacity: true)
            }
            self.lock.unlock()
            if buffers.count >= 2 {
                outL.withUnsafeBufferPointer { l in
                    outR.withUnsafeBufferPointer { r in
                        if let dstL = buffers[0].mData, let dstR = buffers[1].mData {
                            memcpy(dstL, l.baseAddress!, n * MemoryLayout<Float>.size)
                            memcpy(dstR, r.baseAddress!, n * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
        } catch {
            started = false
        }
    }

    func stop() {
        guard started else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        started = false
        lock.lock()
        fifo.removeAll()
        lock.unlock()
    }

    func setMuted(_ m: Bool) {
        lock.lock()
        muted = m
        lock.unlock()
    }
}

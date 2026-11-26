import Foundation
import Combine

/// WebSocket transport speaking the WayLink bridge protocol.
///
/// server -> client:
///   binary 0x00 | tag(1) | pts(8 BE) | size(4 BE) | nal   (H.264 NAL)
///   binary 0x01 | pcm bytes                                (s16le 48k stereo)
///   text   JSON meta (session/stats/pong/quality_applied/…)
/// client -> server: JSON commands (touch/key/text/scroll/nav/quality/…)
@MainActor
final class StreamClient: ObservableObject {
    @Published var state: ConnectionState = .idle
    @Published var stats: StreamStats = .zero
    @Published var lastLog: String = ""

    let decoder = VideoDecoder()
    let audioPlayer = AudioPlayer()

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var adaptiveTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var manuallyClosed = false

    private(set) var profile: ConnectionProfile = ConnectionProfile()
    private var activeQuality: QualityPreset = .balanced
    private var stableChecks = 0
    private var decodedFrames = 0
    private var decodedWindowStart = Date()
    private var rttSamples: [Double] = []

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        decoder.onDecodedFrame = { [weak self] in
            Task { @MainActor in self?.noteDecodedFrame() }
        }
    }

    // ------------------------------------------------------------ lifecycle

    func connect(profile: ConnectionProfile) {
        self.profile = profile
        self.activeQuality = QualityPreset.byId(profile.qualityId)
        manuallyClosed = false
        guard let url = profile.wsURL else {
            state = .failed("Invalid server address")
            return
        }
        state = .connecting
        open(url: url)
    }

    private func open(url: URL) {
        let ws = session.webSocketTask(with: url)
        self.ws = ws
        ws.resume()
        receiveTask = Task { await receiveLoop() }
        pingTask = Task { await pingLoop() }
        if profile.adaptiveQuality {
            adaptiveTask = Task { await adaptiveLoop() }
        }
    }

    func disconnect() {
        manuallyClosed = true
        receiveTask?.cancel()
        pingTask?.cancel()
        adaptiveTask?.cancel()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        decoder.flush()
        audioPlayer.stop()
        state = .idle
    }

    // ----------------------------------------------------------- receive

    private func receiveLoop() async {
        guard let ws else { return }
        do {
            while !Task.isCancelled {
                let msg = try await ws.receive()
                switch msg {
                case .data(let data):
                    handleBinary(data)
                case .string(let text):
                    handleJSON(text)
                @unknown default:
                    break
                }
            }
        } catch {
            if !manuallyClosed {
                scheduleReconnect(error: error)
            }
        }
    }

    private func handleBinary(_ data: Data) {
        guard !data.isEmpty else { return }
        switch data[data.startIndex] {
        case 0x00: // video NAL: tag(1) pts(8) size(4) nal
            guard data.count >= 14 else { return }
            let tag = Int(data[data.startIndex + 1])
            var pts: UInt64 = 0
            for i in 0..<8 { pts = (pts << 8) | UInt64(data[data.startIndex + 2 + i]) }
            var size: UInt32 = 0
            for i in 0..<4 { size = (size << 8) | UInt32(data[data.startIndex + 10 + i]) }
            let nal = data[(data.startIndex + 14)...]
            guard nal.count == Int(size) else { return }
            decoder.submit(tag: tag, ptsUs: pts, nal: Data(nal))
        case 0x01: // audio PCM
            let pcm = data[(data.startIndex + 1)...]
            if profile.audio, !pcm.isEmpty {
                audioPlayer.enqueue(Data(pcm))
            }
        default:
            break
        }
    }

    private func handleJSON(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let m = obj as? [String: Any],
              let type = m["type"] as? String else { return }
        switch type {
        case "session":
            stats.width = m["width"] as? Int ?? 0
            stats.height = m["height"] as? Int ?? 0
            decoder.reset()
        case "stats":
            stats.fps = m["fps"] as? Double ?? 0
            stats.kbps = m["kbps"] as? Double ?? 0
        case "pong":
            if let t = m["t"] as? Double {
                let rtt = (Date().timeIntervalSince1970 - t) * 1000
                rttSamples.append(rtt)
                if rttSamples.count > 10 { rttSamples.removeFirst() }
                stats.latencyMs = rttSamples.reduce(0, +) / Double(rttSamples.count)
            }
            if state == .connecting || {
                if case .reconnecting = state { return true }
                return false
            }() {
                state = .live
                reconnectAttempt = 0
                sendResetVideo()
            }
        case "quality_applied":
            lastLog = "Quality: \(m["max_size"] as? Int ?? 0)px " +
                      "\(m["bitrate_kbps"] as? Int ?? 0)kbps " +
                      "\(m["max_fps"] as? Int ?? 0)fps"
        case "stream_ended":
            lastLog = "Stream ended"
            decoder.reset()
        case "error":
            lastLog = (m["message"] as? String) ?? "bridge error"
        case "log":
            break
        case "hello":
            state = .live
            reconnectAttempt = 0
            // (re)assert desired quality and force an IDR
            sendQuality(preset: activeQuality, force: true)
            sendResetVideo()
            if profile.audio { audioPlayer.start() }
        default:
            break
        }
    }

    private func scheduleReconnect(error: Error) {
        reconnectAttempt += 1
        if reconnectAttempt > 5 {
            state = .failed(error.localizedDescription)
            return
        }
        state = .reconnecting(attempt: reconnectAttempt)
        decoder.flush()
        let delay = Double(min(8, 1 << (reconnectAttempt - 1)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.manuallyClosed else { return }
            if let url = self.profile.wsURL { self.open(url: url) }
        }
    }

    // -------------------------------------------------------------- ping

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            sendJSON(["type": "ping", "t": Date().timeIntervalSince1970])
            // rolling decoded-fps measurement
            let now = Date()
            let dt = now.timeIntervalSince(decodedWindowStart)
            if dt >= 1.0 {
                stats.decodedFps = Double(decodedFrames) / dt
                decodedFrames = 0
                decodedWindowStart = now
            }
        }
    }

    private func noteDecodedFrame() {
        decodedFrames += 1
    }

    // ------------------------------------------------- adaptive quality

    private func adaptiveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard state == .live else { continue }
            let target = Double(activeQuality.maxFps)
            let struggling = stats.latencyMs > 320 || stats.decodedFps < target * 0.55
            let healthy = stats.latencyMs < 140 && stats.decodedFps > target * 0.85
            if struggling, let lower = stepDown() {
                stableChecks = 0
                activeQuality = lower
                sendQuality(preset: lower, force: false)
                lastLog = "Adaptive: dropped to \(lower.label)"
            } else if healthy {
                stableChecks += 1
                if stableChecks >= 6, let higher = stepUp() {
                    stableChecks = 0
                    activeQuality = higher
                    sendQuality(preset: higher, force: false)
                    lastLog = "Adaptive: raised to \(higher.label)"
                }
            } else {
                stableChecks = 0
            }
        }
    }

    private func stepDown() -> QualityPreset? {
        let ladder = QualityPreset.all
        guard let idx = ladder.firstIndex(where: { $0.id == activeQuality.id }),
              idx > 0 else { return nil }
        return ladder[idx - 1]
    }

    private func stepUp() -> QualityPreset? {
        let ladder = QualityPreset.all
        let cap = QualityPreset.byId(profile.qualityId)   // never exceed user's pick
        guard let idx = ladder.firstIndex(where: { $0.id == activeQuality.id }),
              let capIdx = ladder.firstIndex(where: { $0.id == cap.id }),
              idx < capIdx else { return nil }
        return ladder[idx + 1]
    }

    // ------------------------------------------------------------ sending

    private func sendJSON(_ obj: [String: Any]) {
        guard let ws, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await ws.send(.string(text)) }
    }

    func sendTouch(_ e: TouchEvent) {
        sendJSON(["type": "touch", "action": e.action.rawValue,
                  "id": e.pointerId, "x": e.x, "y": e.y, "pressure": e.pressure])
    }

    func sendKey(_ key: AndroidKey, down: Bool, meta: Int = 0) {
        sendJSON(["type": "key", "action": down ? "down" : "up",
                  "code": key.rawValue, "meta": meta])
    }

    func sendText(_ text: String) {
        // bridge truncates to scrcpy's 300-byte inject limit; chunk to be safe
        var rest = text
        while !rest.isEmpty {
            let chunk = String(rest.prefix(250))
            sendJSON(["type": "text", "text": chunk])
            rest = String(rest.dropFirst(chunk.count))
        }
    }

    func sendScroll(x: Double, y: Double, dx: Double, dy: Double) {
        sendJSON(["type": "scroll", "x": x, "y": y, "dx": dx, "dy": dy])
    }

    func sendNav(_ button: String) {
        sendJSON(["type": "nav", "button": button])
    }

    func sendResetVideo() {
        sendJSON(["type": "reset_video"])
    }

    func sendClipboard(_ text: String, paste: Bool) {
        sendJSON(["type": "clipboard", "text": text, "paste": paste])
    }

    func sendQuality(preset: QualityPreset, force: Bool) {
        sendJSON(["type": "quality", "preset": preset.id,
                  "max_size": preset.maxSize,
                  "bitrate_kbps": preset.bitrateKbps,
                  "max_fps": preset.maxFps])
    }

    func sendUHID(_ obj: [String: Any]) {
        sendJSON(obj)
    }
}

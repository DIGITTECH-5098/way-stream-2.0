import Foundation
import UIKit

// MARK: - Run modes

enum RunMode: String, CaseIterable, Identifiable, Codable {
    case regular   // portrait/landscape, pinch-zoom, keyboard, nav bar
    case gaming    // landscape-locked, immersive, gamepad overlay, max quality

    var id: String { rawValue }
    var label: String { self == .regular ? "Regular" : "Gaming" }
}

// MARK: - Quality

struct QualityPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let maxSize: Int        // long edge, px
    let bitrateKbps: Int
    let maxFps: Int
    let note: String

    static let smooth   = QualityPreset(id: "smooth",   label: "Smooth",
                                        maxSize: 960,  bitrateKbps: 4000,  maxFps: 30,
                                        note: "Cellular / weak network")
    static let balanced = QualityPreset(id: "balanced", label: "Balanced",
                                        maxSize: 1280, bitrateKbps: 8000,  maxFps: 60,
                                        note: "Daily use")
    static let hd       = QualityPreset(id: "hd",       label: "HD",
                                        maxSize: 1920, bitrateKbps: 12000, maxFps: 60,
                                        note: "Wi-Fi / fast cellular")
    static let ultra    = QualityPreset(id: "ultra",    label: "Ultra",
                                        maxSize: 2560, bitrateKbps: 16000, maxFps: 60,
                                        note: "Wi-Fi 6 / LAN")

    static let all: [QualityPreset] = [.smooth, .balanced, .hd, .ultra]
    static func byId(_ id: String) -> QualityPreset {
        all.first { $0.id == id } ?? .balanced
    }
}

// MARK: - Connection profile (persisted)

struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "My Waydroid"
    var host: String = ""
    var port: Int = 8787
    var token: String = ""
    var useTLS: Bool = false
    var mode: RunMode = .regular
    var qualityId: String = QualityPreset.balanced.id
    var adaptiveQuality: Bool = true
    var audio: Bool = true
    var showTouches: Bool = false
    var fillScreen: Bool = true      // aspect-fill crop instead of letterbox
    var gamepadMode: GamepadMode = .touchMap

    var wsURL: URL? {
        var comps = URLComponents()
        comps.scheme = useTLS ? "wss" : "ws"
        comps.host = host
        comps.port = port
        comps.path = "/ws"
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "controller", value: "1"),
        ]
        return comps.url
    }

    static let storeKey = "waylink.profiles"
    static let lastKey = "waylink.lastProfile"

    static func loadAll() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else { return [] }
        return list
    }

    static func saveAll(_ list: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}

enum GamepadMode: String, CaseIterable, Identifiable, Codable {
    case touchMap   // virtual buttons inject touches at mapped screen positions
    case uhid       // real HID gamepad (games with gamepad support)

    var id: String { rawValue }
    var label: String { self == .touchMap ? "Touch mapper" : "Gamepad (UHID)" }
}

// MARK: - Stream stats

struct StreamStats: Equatable {
    var fps: Double = 0            // server-side encode rate
    var kbps: Double = 0
    var width: Int = 0
    var height: Int = 0
    var latencyMs: Double = 0      // WS round trip
    var decodedFps: Double = 0     // client-side decode rate

    static let zero = StreamStats()
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .reconnecting(let n): return "Reconnecting (attempt \(n))…"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

// MARK: - Android keycodes (android.view.KeyEvent)

enum AndroidKey: Int {
    case home = 3, back = 4
    case dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22, dpadCenter = 23
    case volumeUp = 24, volumeDown = 25, power = 26
    case tab = 61, space = 62, enter = 66, del = 67
    case menu = 82, search = 84
    case pageUp = 92, pageDown = 93
    case escape = 111, forwardDel = 112
    case moveHome = 122, moveEnd = 123
    case appSwitch = 187
}

// MARK: - Touch events sent to the bridge

enum TouchAction: String, Codable {
    case down, up, move, cancel, pointer_down, pointer_up
}

struct TouchEvent {
    let action: TouchAction
    let pointerId: Int64
    let x: Double          // normalized 0..1 in stream space
    let y: Double
    let pressure: Double
}

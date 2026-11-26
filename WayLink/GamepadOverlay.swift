import Foundation
import SwiftUI

// MARK: - Gamepad configuration (persisted per profile name)

struct GamepadConfig: Codable {
    /// Normalized stream coordinates (0..1) each virtual control maps to.
    var anchors: [String: CGPoint2D] = [:]
    /// How far the virtual stick drags from its anchor (stream units).
    var stickRadius: Double = 0.05

    static let controlIds = ["stick", "a", "b", "x", "y", "l1", "r1", "l2", "r2",
                             "du", "dd", "dl", "dr", "select", "start"]

    static func load(profileName: String) -> GamepadConfig {
        let key = "waylink.gamepad.\(profileName)"
        if let data = UserDefaults.standard.data(forKey: key),
           let cfg = try? JSONDecoder().decode(GamepadConfig.self, from: data) {
            return cfg
        }
        // sensible defaults: stick lower-left, buttons lower-right
        var cfg = GamepadConfig()
        cfg.anchors["stick"] = CGPoint2D(x: 0.22, y: 0.72)
        cfg.anchors["a"] = CGPoint2D(x: 0.82, y: 0.72)
        cfg.anchors["b"] = CGPoint2D(x: 0.90, y: 0.66)
        cfg.anchors["x"] = CGPoint2D(x: 0.74, y: 0.66)
        cfg.anchors["y"] = CGPoint2D(x: 0.82, y: 0.60)
        cfg.anchors["l1"] = CGPoint2D(x: 0.12, y: 0.10)
        cfg.anchors["r1"] = CGPoint2D(x: 0.88, y: 0.10)
        return cfg
    }

    func save(profileName: String) {
        let key = "waylink.gamepad.\(profileName)"
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct CGPoint2D: Codable, Equatable {
    var x: Double
    var y: Double
}

// MARK: - UHID gamepad (real HID device for games with gamepad support)

/// Self-consistent HID gamepad: 11 buttons + hat + 4 axes + 2 triggers.
/// Report (9 bytes): buttons16 LE | hat+pad | LX LY RX Rz (s8) | LT RT (u8)
final class UHIDGamepad {
    static let descriptorHex =
        "05010905A101" +
        "05091901290B150025017501950B8102" +
        "750595018103" +
        "05010939150025073500463B016514750495018142" +
        "750495018103" +
        "09300931093209351581257F750895048102" +
        "09330934150026FF00750895028102" +
        "C0"

    private let deviceId = 1
    private unowned let client: StreamClient
    private var created = false

    // logical state
    private var buttons: UInt16 = 0          // bit0=A .. bit10=Mode
    private var hat: UInt8 = 8               // 8 = released
    private var lx: Int8 = 0, ly: Int8 = 0, rx: Int8 = 0, rz: Int8 = 0
    private var lt: UInt8 = 0, rt: UInt8 = 0

    init(client: StreamClient) {
        self.client = client
    }

    func ensureCreated() {
        guard !created else { return }
        created = true
        client.sendUHID(["type": "uhid", "action": "create",
                         "id": deviceId, "vendor_id": 0x045E,
                         "product_id": 0x028E, "name": "WayLink Pad",
                         "desc_hex": Self.descriptorHex])
    }

    func destroy() {
        guard created else { return }
        created = false
        client.sendUHID(["type": "uhid", "action": "destroy", "id": deviceId])
    }

    enum Button: UInt16 {
        case a = 0, b, x, y, l1, r1, l3, r3, select, start, mode
    }

    func set(button: Button, pressed: Bool) {
        if pressed { buttons |= (1 << button.rawValue) }
        else { buttons &= ~(1 << button.rawValue) }
        send()
    }

    func setHat(_ h: UInt8) {
        hat = h
        send()
    }

    func setSticks(lx: Double, ly: Double, rx: Double, rz: Double) {
        self.lx = Int8(clamping: Int(lx * 127))
        self.ly = Int8(clamping: Int(ly * 127))
        self.rx = Int8(clamping: Int(rx * 127))
        self.rz = Int8(clamping: Int(rz * 127))
        send()
    }

    func setTriggers(lt: Double, rt: Double) {
        self.lt = UInt8(clamping: Int(lt * 255))
        self.rt = UInt8(clamping: Int(rt * 255))
        send()
    }

    private func send() {
        guard created else { return }
        var report = Data(count: 9)
        report[0] = UInt8(truncatingIfNeeded: buttons)
        report[1] = UInt8(truncatingIfNeeded: buttons >> 8)
        report[2] = hat
        report[3] = UInt8(bitPattern: lx)
        report[4] = UInt8(bitPattern: ly)
        report[5] = UInt8(bitPattern: rx)
        report[6] = UInt8(bitPattern: rz)
        report[7] = lt
        report[8] = rt
        client.sendUHID(["type": "uhid", "action": "input",
                         "id": deviceId, "data_hex": report.hexString])
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Virtual control overlay (SwiftUI)

/// Draws the virtual joystick + buttons and injects input either as
/// mapped touches (works with every game) or UHID gamepad events.
struct GamepadOverlay: View {
    @ObservedObject var client: StreamClient
    let mode: GamepadMode
    @Binding var config: GamepadConfig
    @Binding var isMapping: Bool
    var onMapRequest: (String) -> Void

    @State private var stickOffset: CGSize = .zero
    @State private var pressed: Set<String> = []
    @State private var pad: UHIDGamepad?
    private let stickTouchId: Int64 = 900

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // left: virtual stick
                stickView(size: geo.size)
                    .position(x: geo.size.width * 0.16, y: geo.size.height * 0.72)

                // right: face buttons
                faceButtons(size: geo.size)

                // shoulders / misc
                miscButtons(size: geo.size)
            }
        }
        .allowsHitTesting(true)
        .onAppear {
            if mode == .uhid {
                let p = UHIDGamepad(client: client)
                p.ensureCreated()
                pad = p
            }
        }
        .onDisappear {
            pad?.destroy()
            pad = nil
        }
    }

    // ------------------------------------------------------------- stick

    private func stickView(size: CGSize) -> some View {
        let base: CGFloat = 110
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 3)
                .frame(width: base, height: base)
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: base * 0.45, height: base * 0.45)
                .offset(stickOffset)
        }
        .frame(width: base, height: base)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.translation.width / (base / 2)
                    let dy = v.translation.height / (base / 2)
                    let clamped = CGSize(
                        width: max(-1, min(1, dx)),
                        height: max(-1, min(1, dy)))
                    stickOffset = CGSize(width: clamped.width * base / 2.2,
                                         height: clamped.height * base / 2.2)
                    handleStick(dx: Double(clamped.width),
                                dy: Double(clamped.height), active: true)
                }
                .onEnded { _ in
                    stickOffset = .zero
                    handleStick(dx: 0, dy: 0, active: false)
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                if isMapping { onMapRequest("stick") }
            })
    }

    private func handleStick(dx: Double, dy: Double, active: Bool) {
        switch mode {
        case .touchMap:
            guard let anchor = config.anchors["stick"] else { return }
            if active {
                if pressed.insert("stick").inserted {
                    client.sendTouch(TouchEvent(
                        action: .down, pointerId: stickTouchId,
                        x: anchor.x, y: anchor.y, pressure: 1))
                }
                let r = config.stickRadius
                client.sendTouch(TouchEvent(
                    action: .move, pointerId: stickTouchId,
                    x: max(0, min(1, anchor.x + dx * r)),
                    y: max(0, min(1, anchor.y + dy * r)),
                    pressure: 1))
            } else {
                pressed.remove("stick")
                client.sendTouch(TouchEvent(
                    action: .up, pointerId: stickTouchId,
                    x: anchor.x, y: anchor.y, pressure: 0))
            }
        case .uhid:
            pad?.ensureCreated()
            pad?.setSticks(lx: dx, ly: dy, rx: 0, rz: 0)
        }
    }

    // ------------------------------------------------------------ buttons

    private func faceButtons(size: CGSize) -> some View {
        let layout: [(String, CGFloat, CGFloat)] = [
            ("a", 0.90, 0.72), ("b", 0.96, 0.65),
            ("x", 0.84, 0.65), ("y", 0.90, 0.58),
        ]
        return ForEach(layout, id: \.0) { item in
            buttonView(id: item.0, label: item.0.uppercased())
                .position(x: size.width * item.1, y: size.height * item.2)
        }
    }

    private func miscButtons(size: CGSize) -> some View {
        let layout: [(String, String, CGFloat, CGFloat)] = [
            ("l1", "L1", 0.10, 0.08), ("r1", "R1", 0.90, 0.08),
            ("l2", "L2", 0.10, 0.16), ("r2", "R2", 0.90, 0.16),
            ("dl", "◀", 0.08, 0.55), ("dr", "▶", 0.20, 0.55),
            ("du", "▲", 0.14, 0.49), ("dd", "▼", 0.14, 0.61),
            ("select", "SEL", 0.42, 0.92), ("start", "START", 0.58, 0.92),
        ]
        return ForEach(layout, id: \.0) { item in
            buttonView(id: item.0, label: item.1)
                .position(x: size.width * item.2, y: size.height * item.3)
        }
    }

    private func buttonView(id: String, label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 52, height: 52)
            .background(
                Circle().fill(pressed.contains(id)
                              ? Color.orange.opacity(0.85)
                              : Color.white.opacity(0.18)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if isMapping {
                            onMapRequest(id)
                            return
                        }
                        if pressed.insert(id).inserted {
                            handleButton(id: id, down: true)
                        }
                    }
                    .onEnded { _ in
                        if pressed.remove(id) != nil {
                            handleButton(id: id, down: false)
                        }
                    })
    }

    private func handleButton(id: String, down: Bool) {
        switch mode {
        case .touchMap:
            guard let anchor = config.anchors[id] else { return }
            let pid: Int64 = 901 + Int64(GamepadConfig.controlIds.firstIndex(of: id) ?? 0)
            client.sendTouch(TouchEvent(
                action: down ? .down : .up, pointerId: pid,
                x: anchor.x, y: anchor.y, pressure: down ? 1 : 0))
        case .uhid:
            pad?.ensureCreated()
            switch id {
            case "a": pad?.set(button: .a, pressed: down)
            case "b": pad?.set(button: .b, pressed: down)
            case "x": pad?.set(button: .x, pressed: down)
            case "y": pad?.set(button: .y, pressed: down)
            case "l1": pad?.set(button: .l1, pressed: down)
            case "r1": pad?.set(button: .r1, pressed: down)
            case "l2": pad?.setTriggers(lt: down ? 1 : 0, rt: 0)
            case "r2": pad?.setTriggers(lt: 0, rt: down ? 1 : 0)
            case "select": pad?.set(button: .select, pressed: down)
            case "start": pad?.set(button: .start, pressed: down)
            case "du": pad?.setHat(down ? 0 : 8)
            case "dr": pad?.setHat(down ? 2 : 8)
            case "dd": pad?.setHat(down ? 4 : 8)
            case "dl": pad?.setHat(down ? 6 : 8)
            default: break
            }
        }
    }
}

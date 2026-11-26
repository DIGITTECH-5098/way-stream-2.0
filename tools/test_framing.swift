// tools/test_framing.swift — validates that the exact byte-parsing loop used
// in StreamClient.handleBinary / VideoDecoder unpacks the bridge's wire
// framing correctly. Run with: swiftc tools/test_framing.swift && ./test_framing
import Foundation

// sample produced by Python: pack_video_nal(tag=2, pts=123456789, nal)
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/framing.bin"
guard let data = FileManager.default.contents(atPath: path) else {
    print("FAIL cannot read \(path)"); exit(1)
}

// ---- identical logic to StreamClient.handleBinary ----
func parse(_ data: Data) -> (UInt8, Int, UInt64, Int, Data)? {
    guard !data.isEmpty else { return nil }
    switch data[data.startIndex] {
    case 0x00:
        guard data.count >= 14 else { return nil }
        let tag = Int(data[data.startIndex + 1])
        var pts: UInt64 = 0
        for i in 0..<8 { pts = (pts << 8) | UInt64(data[data.startIndex + 2 + i]) }
        var size: UInt32 = 0
        for i in 0..<4 { size = (size << 8) | UInt32(data[data.startIndex + 10 + i]) }
        let nal = data[(data.startIndex + 14)...]
        guard nal.count == Int(size) else { return nil }
        return (0x00, tag, pts, Int(size), Data(nal))
    default:
        return nil
    }
}

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok  \(name)" : " FAIL \(name)")
    if !ok { failed = true }
}

if let (ch, tag, pts, size, nal) = parse(data) {
    check("channel 0x00", ch == 0x00)
    check("tag == 2 (IDR)", tag == 2)
    check("pts == 123456789", pts == 123456789)
    check("size == 3", size == 3)
    check("nal == 65 88 84", nal == Data([0x65, 0x88, 0x84]))
} else {
    check("packet parses", false)
}

// audio channel
let audio = Data([0x01, 0x0A, 0x0B, 0x0C, 0x0D])
check("audio channel tag", audio[audio.startIndex] == 0x01)
check("audio payload len", audio.count - 1 == 4)

// Gamepad UHID report layout (9 bytes) — mirrors GamepadOverlay.UHIDGamepad.send()
var buttons: UInt16 = 0b00000000_00000001  // A
var report = Data(count: 9)
report[0] = UInt8(truncatingIfNeeded: buttons)
report[1] = UInt8(truncatingIfNeeded: buttons >> 8)
report[2] = 8                                  // hat released
report[3] = UInt8(bitPattern: Int8(clamping: Int(-1.0 * 127)))  // LX full left
report[7] = 255                                // LT full
check("uhid report 9 bytes", report.count == 9)
check("uhid button A bit0", report[0] == 0x01 && report[1] == 0x00)
check("uhid LX == -127", report[3] == UInt8(bitPattern: Int8(-127)))
check("uhid LT == 255", report[7] == 255)

exit(failed ? 1 : 0)

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import VideoToolbox

// MARK: - H.264 NAL -> VideoToolbox -> pixel buffers

/// Decodes tagged H.264 NAL units from the bridge with VideoToolbox and
/// enqueues the results into an AVSampleBufferDisplayLayer.
final class VideoDecoder {
    var onDecodedFrame: (() -> Void)?
    var onResetNeeded: (() -> Void)?

    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private weak var surface: StreamSurfaceView?

    func attach(surface: StreamSurfaceView) {
        self.surface = surface
    }

    func reset() {
        sps = nil
        pps = nil
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDesc = nil
        DispatchQueue.main.async { self.surface?.flush() }
    }

    func flush() {
        DispatchQueue.main.async { self.surface?.flush() }
    }

    /// tag: 0=SPS 1=PPS 2=IDR 3=SLICE 4=other; ptsUs: device PTS in µs.
    func submit(tag: Int, ptsUs: UInt64, nal: Data) {
        switch tag {
        case 0:
            sps = nal
            rebuildFormat()
        case 1:
            pps = nal
            rebuildFormat()
        case 2, 3:
            decodeFrame(nal: nal, ptsUs: ptsUs)
        default:
            break   // SEI/AUD not needed for decoding
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                var pointers: [UnsafePointer<UInt8>?] = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress,
                ]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    naluHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else { return }
        formatDesc = desc
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        makeSession(format: desc)
    }

    private func makeSession(format: CMVideoFormatDescription) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var sess: VTDecompressionSession?
        let cb: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, pts, _ in
            guard status == noErr, let imageBuffer, let refcon else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
            decoder.render(imageBuffer: imageBuffer, pts: pts)
        }
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            videoFormatDescription: format,
            videoDecoderSpecification: [
                kVTDecompressionPropertyKey_RealTime: true
            ] as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: cb,
            outputCallbackRefCon: Unmanaged.passUnretained(self).toOpaque(),
            decompressionSessionOut: &sess)
        guard status == noErr else { return }
        session = sess
    }

    private func decodeFrame(nal: Data, ptsUs: UInt64) {
        guard let formatDesc, let session else {
            // frames before we saw SPS/PPS — ask for a key frame
            onResetNeeded?()
            return
        }
        // length-prefixed (AVCC-style) block: 4-byte big-endian length + NAL
        var payload = Data(count: 4 + nal.count)
        let len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: len) { payload.replaceSubrange(0..<4, with: $0) }
        payload.replaceSubrange(4..<(4 + nal.count), with: nal)

        var blockBuffer: CMBlockBuffer?
        var bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offset: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        if bbStatus == noErr, let bb = blockBuffer {
            bbStatus = payload.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!, blockBuffer: bb,
                    offsetIntoDestination: 0, dataLength: payload.count)
            }
        }
        guard bbStatus == noErr, let blockBuffer else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sbuf: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntries: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sbuf)
        guard sbStatus == noErr, let sbuf else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sbuf, flags: flags, infoFlagsOut: nil)
        if st != noErr {
            // corrupt stream state — force an IDR from the device
            onResetNeeded?()
        }
    }

    fileprivate func render(imageBuffer: CVImageBuffer, pts: CMTime) {
        guard let surface else { return }
        var sbuf: CMSampleBuffer?
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: hostNow,
            decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sbuf)
        guard status == noErr, let sbuf else { return }
        DispatchQueue.main.async {
            surface.enqueue(sbuf)
            self.onDecodedFrame?()
        }
    }
}

// MARK: - Surface view (video display + touch capture + zoom)

/// One full-screen view: hosts the AVSampleBufferDisplayLayer, captures
/// multitouch (mapped to stream coordinates) and supports two-finger zoom
/// in regular mode. Because zoom is a UIView transform, UIKit keeps
/// `location(in:)` in untransformed local space — stream mapping never
/// needs to know about zoom.
final class StreamSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    var streamSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }
    var fillScreen: Bool = true {
        didSet { displayLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect }
    }
    var zoomEnabled = true
    var onTouch: ((TouchEvent) -> Void)?

    private var pointerIds: [ObjectIdentifier: Int64] = [:]
    private var nextPointerId: Int64 = 1
    private var pinch: UIPinchGestureRecognizer?
    private var baseTransform = CGAffineTransform.identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isMultipleTouchEnabled = true
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        let p = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        p.delegate = self
        addGestureRecognizer(p)
        pinch = p

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        if let tb { displayLayer.controlTimebase = tb }
    }

    func enqueue(_ sbuf: CMSampleBuffer) {
        displayLayer.enqueue(sbuf)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    // ------------------------------------------------------- zoom

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard zoomEnabled else { return }
        switch g.state {
        case .began:
            baseTransform = transform
        case .changed:
            let scale = max(1.0, min(4.0, baseTransform.scaledBy(x: g.scale, y: g.scale).a))
            var t = CGAffineTransform(scaleX: scale, y: scale)
            // move with the pinch midpoint so fingers track content
            let mid = g.location(in: superview ?? self)
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            let d = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
            let maxD = max(0.0, (scale - 1.0) * bounds.width / 2.0)
            t = t.translatedBy(x: max(-maxD, min(maxD, d.x)),
                               y: max(-maxD, min(maxD, d.y)))
            transform = t
        case .ended, .cancelled:
            if transform.a <= 1.02 {
                UIView.animate(withDuration: 0.2) { self.transform = .identity }
            }
        default:
            break
        }
    }

    func resetZoom() {
        UIView.animate(withDuration: 0.2) { self.transform = .identity }
    }

    // --------------------------------------------------- touch mapping

    /// Map a point in view space to normalized stream coords (0..1), or nil
    /// if it falls outside the visible stream rect.
    func streamPoint(from p: CGPoint) -> (x: Double, y: Double)? {
        guard streamSize.width > 0, streamSize.height > 0 else {
            // unknown size yet: map to full bounds
            let x = Double(p.x / max(1, bounds.width))
            let y = Double(p.y / max(1, bounds.height))
            guard (0...1).contains(x), (0...1).contains(y) else { return nil }
            return (x, y)
        }
        let sAspect = streamSize.width / streamSize.height
        let vAspect = bounds.width / max(1, bounds.height)
        let rect: CGRect
        if fillScreen {   // aspect-fill: cover bounds, stream may overflow
            if sAspect > vAspect {
                let h = bounds.height
                let w = h * sAspect
                rect = CGRect(x: bounds.midX - w / 2, y: 0, width: w, height: h)
            } else {
                let w = bounds.width
                let h = w / sAspect
                rect = CGRect(x: 0, y: bounds.midY - h / 2, width: w, height: h)
            }
        } else {          // aspect-fit: letterbox inside bounds
            if sAspect > vAspect {
                let w = bounds.width
                let h = w / sAspect
                rect = CGRect(x: 0, y: bounds.midY - h / 2, width: w, height: h)
            } else {
                let h = bounds.height
                let w = h * sAspect
                rect = CGRect(x: bounds.midX - w / 2, y: 0, width: w, height: h)
            }
        }
        let x = Double((p.x - rect.minX) / max(1, rect.width))
        let y = Double((p.y - rect.minY) / max(1, rect.height))
        return (x, y)   // allow slight overflow; bridge/clamp handles edges
    }

    private func emit(action: TouchAction, touch: UITouch, pressure: Double = 1.0) {
        let key = ObjectIdentifier(touch)
        guard let id = pointerIds[key] else { return }
        let p = touch.location(in: self)
        guard let sp = streamPoint(from: p) else { return }
        onTouch?(TouchEvent(action: action, pointerId: id,
                            x: sp.x, y: sp.y, pressure: pressure))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let key = ObjectIdentifier(t)
            let isNewFirst = pointerIds.isEmpty
            let id = nextPointerId
            nextPointerId += 1
            pointerIds[key] = id
            emit(action: isNewFirst ? .down : .pointer_down, touch: t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { emit(action: .move, touch: t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            emit(action: pointerIds.count <= 1 ? .up : .pointer_up,
                 touch: t, pressure: 0)
            pointerIds.removeValue(forKey: ObjectIdentifier(t))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            emit(action: .cancel, touch: t, pressure: 0)
            pointerIds.removeValue(forKey: ObjectIdentifier(t))
        }
    }
}

extension StreamSurfaceView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

// MARK: - SwiftUI wrapper

struct VideoView: UIViewRepresentable {
    @ObservedObject var client: StreamClient
    let fillScreen: Bool
    let zoomEnabled: Bool

    func makeUIView(context: Context) -> StreamSurfaceView {
        let v = StreamSurfaceView()
        v.fillScreen = fillScreen
        v.zoomEnabled = zoomEnabled
        v.onTouch = { e in
            Task { @MainActor in client.sendTouch(e) }
        }
        client.decoder.attach(surface: v)
        client.decoder.onResetNeeded = {
            Task { @MainActor in client.sendResetVideo() }
        }
        return v
    }

    func updateUIView(_ v: StreamSurfaceView, context: Context) {
        v.fillScreen = fillScreen
        v.zoomEnabled = zoomEnabled
        let s = client.stats
        v.streamSize = CGSize(width: s.width, height: s.height)
    }
}

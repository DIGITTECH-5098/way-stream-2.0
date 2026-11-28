import SwiftUI

/// The live session screen: fullscreen video, auto-hiding chrome, HUD,
/// gamepad overlay (gaming), keyboard bar (regular), control mapping.
struct StreamView: View {
    @EnvironmentObject var client: StreamClient
    @Binding var profile: ConnectionProfile
    @Binding var isLive: Bool

    @State private var mode: RunMode
    @State private var showChrome = true
    @State private var showKeyboard = false
    @State private var showGamepad = false
    @State private var muted = false
    @State private var mappingTarget: String?
    @State private var gamepadConfig: GamepadConfig
    @State private var chromeTask: Task<Void, Never>?

    init(profile: Binding<ConnectionProfile>, isLive: Binding<Bool>) {
        self._profile = profile
        self._isLive = isLive
        self._mode = State(initialValue: profile.wrappedValue.mode)
        self._gamepadConfig = State(initialValue:
            GamepadConfig.load(profileName: profile.wrappedValue.name))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoView(client: client,
                      fillScreen: profile.fillScreen,
                      zoomEnabled: mode == .regular)
                .ignoresSafeArea()

            if mappingTarget != nil {
                mappingCaptureLayer
            }

            VStack(spacing: 0) {
                if showChrome { topBar }
                Spacer()
                if showChrome {
                    if showKeyboard && mode == .regular {
                        KeyboardBar(client: client, isPresented: $showKeyboard)
                    }
                    bottomBar
                }
            }

            if mode == .gaming || showGamepad {
                GamepadOverlay(
                    client: client,
                    mode: profile.gamepadMode,
                    config: $gamepadConfig,
                    isMapping: Binding(
                        get: { mappingTarget != nil },
                        set: { if !$0 { mappingTarget = nil } }),
                    onMapRequest: { id in mappingTarget = id })
                    .ignoresSafeArea()
            }

            // slim chrome toggle — never steals game touches
            VStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
                    scheduleChromeHide()
                } label: {
                    Image(systemName: showChrome ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(height: 28)
                }
                Spacer()
            }
        }
        .statusBarHidden(mode == .gaming)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            applyMode()
            scheduleChromeHide()
        }
        .onDisappear {
            OrientationLock.lock(to: .allButUpsideDown)
            client.disconnect()
        }
    }

    // ------------------------------------------------------------ chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                isLive = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(client.state.label)
                    .font(.caption.weight(.semibold))
                if client.lastLog.isEmpty == false {
                    Text(client.lastLog).font(.caption2).lineLimit(1)
                }
            }
            Spacer()
            statsChip
            Menu {
                ForEach(QualityPreset.all) { q in
                    Button("\(q.label) — \(q.maxSize)px \(q.maxFps)fps") {
                        client.sendQuality(preset: q, force: true)
                        profile.qualityId = q.id
                    }
                }
                Divider()
                Button(muted ? "Unmute audio" : "Mute audio") {
                    muted.toggle()
                    client.audioPlayer.setMuted(muted)
                }
                Button(showGamepad ? "Hide gamepad" : "Show gamepad") {
                    showGamepad.toggle()
                }
                if mode == .gaming || showGamepad {
                    Button(mappingTarget == nil ? "Map gamepad buttons…" : "Cancel mapping") {
                        mappingTarget = mappingTarget == nil ? "a" : nil
                    }
                }
                Button("Resend key frame") { client.sendResetVideo() }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            Button {
                mode = (mode == .gaming) ? .regular : .gaming
                profile.mode = mode
                applyMode()
            } label: {
                Image(systemName: mode == .gaming ? "rectangle.portrait" : "gamecontroller.fill")
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private var statsChip: some View {
        let s = client.stats
        return Text("\(Int(s.decodedFps))fps · \(Int(s.kbps))kbps · \(Int(s.latencyMs))ms · \(s.width)×\(s.height)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            navButton("arrow.uturn.backward", "back")
            navButton("house", "home")
            navButton("square.stack.3d.up", "recents")
            navButton("bell", "notifications")
            navButton("arrow.down.circle", "collapse")
            navButton("rotate.right", "rotate")
            navButton("power", "power")
            if mode == .regular {
                Button {
                    showKeyboard.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
            }
        }
        .foregroundColor(.white)
        .font(.system(size: 18))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.9))
        .clipShape(Capsule())
        .padding(.bottom, 8)
    }

    private func navButton(_ symbol: String, _ action: String) -> some View {
        Button {
            client.sendNav(action)
        } label: {
            Image(systemName: symbol)
        }
    }

    // -------------------------------------------------------- mapping mode

    private var mappingCaptureLayer: some View {
        GeometryReader { geo in
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 10) {
                        Text("Tap where “\(mappingTarget ?? "")” should touch")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Tap = single tap. Press & hold = hold. Tap the button again to cancel.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    })
                .background(
                    TapCaptureView { pt in
                        let x = pt.x / max(1, geo.size.width)
                        let y = pt.y / max(1, geo.size.height)
                        if let target = mappingTarget {
                            gamepadConfig.anchors[target] = CGPoint2D(
                                x: Double(min(1, max(0, x))),
                                y: Double(min(1, max(0, y))))
                            gamepadConfig.save(profileName: profile.name)
                        }
                        mappingTarget = nil
                    })
        }
    }

    // ------------------------------------------------------------ helpers

    private func applyMode() {
        switch mode {
        case .gaming:
            OrientationLock.lock(to: .landscape, rotateTo: .landscapeRight)
            showKeyboard = false
        case .regular:
            OrientationLock.lock(to: .allButUpsideDown)
        }
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        chromeTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    if showKeyboard == false && mappingTarget == nil {
                        withAnimation { showChrome = false }
                    }
                }
            }
        }
    }
}

/// UIKit tap capture (unambiguous location API for the mapping mode).
struct TapCaptureView: UIViewRepresentable {
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = true
        let t = UITapGestureRecognizer(target: context.coordinator,
                                       action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(t)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        let onTap: (CGPoint) -> Void
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            onTap(g.location(in: view))
        }
    }
}

/// Global orientation gate (used via UIApplicationDelegate hook).
final class OrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func lock(to mask: UIInterfaceOrientationMask,
                     rotateTo: UIInterfaceOrientation? = nil) {
        self.mask = mask
        if let rotateTo {
            UIDevice.current.setValue(rotateTo.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

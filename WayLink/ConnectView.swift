import SwiftUI

/// Connection setup: server address, mode, quality, saved profiles.
struct ConnectView: View {
    @EnvironmentObject var client: StreamClient
    @Binding var activeProfile: ConnectionProfile
    @Binding var isLive: Bool

    @State private var profiles = ConnectionProfile.loadAll()
    @State private var profileName = ""
    @State private var showAdvanced = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host (IP or domain)", text: $activeProfile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("8787", value: $activeProfile.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    SecureField("Access token", text: $activeProfile.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Use TLS (wss://)", isOn: $activeProfile.useTLS)
                }

                Section("Mode") {
                    Picker("Mode", selection: $activeProfile.mode) {
                        ForEach(RunMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(activeProfile.mode == .gaming
                         ? "Gaming: landscape lock, immersive, gamepad overlay, all touches pass through."
                         : "Regular: free rotation, pinch-zoom, keyboard, one-finger touch pass-through.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Quality") {
                    Picker("Preset", selection: $activeProfile.qualityId) {
                        ForEach(QualityPreset.all) { q in
                            Text("\(q.label) — \(q.note)").tag(q.id)
                        }
                    }
                    Toggle("Adaptive quality (auto step down/up)", isOn: $activeProfile.adaptiveQuality)
                    Toggle("Fill screen (crop instead of letterbox)", isOn: $activeProfile.fillScreen)
                    Toggle("Stream audio", isOn: $activeProfile.audio)
                }

                Section {
                    Toggle("Show Android touch indicators", isOn: $activeProfile.showTouches)
                    Picker("Gamepad input", selection: $activeProfile.gamepadMode) {
                        ForEach(GamepadMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                } header: {
                    Text("Advanced")
                }

                Section("Profiles") {
                    ForEach(profiles) { p in
                        Button {
                            activeProfile = p
                            profileName = p.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundColor(.primary)
                                    Text("\(p.host):\(p.port) · \(p.mode.label)")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if p == activeProfile {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        profiles.remove(atOffsets: idx)
                        ConnectionProfile.saveAll(profiles)
                    }
                    HStack {
                        TextField("Profile name", text: $profileName)
                        Button("Save") { saveProfile() }
                            .disabled(profileName.isEmpty || activeProfile.host.isEmpty)
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        Label("Test connection", systemImage: "network")
                    }
                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                }

                Section {
                    Button {
                        client.connect(profile: activeProfile)
                        isLive = true
                    } label: {
                        Label("Connect", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(activeProfile.host.isEmpty)
                } footer: {
                    Text("Connects to ws(s)://\(activeProfile.host):\(activeProfile.port)/ws — works over Wi-Fi and cellular as long as the bridge is reachable.")
                }
            }
            .navigationTitle("WayLink")
        }
    }

    private func saveProfile() {
        var p = activeProfile
        p.name = profileName
        if let idx = profiles.firstIndex(where: { $0.name == p.name }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
        ConnectionProfile.saveAll(profiles)
    }

    private func testConnection() async {
        guard let url = activeProfile.wsURL else {
            testResult = "Invalid URL"
            return
        }
        testResult = "Testing…"
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.scheme = activeProfile.useTLS ? "https" : "http"
        comps.path = "/health"
        comps.queryItems = nil
        guard let healthURL = comps.url else { return }
        do {
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 6
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                let txt = String(data: data.prefix(200), encoding: .utf8) ?? ""
                testResult = "Bridge reachable ✓ \(txt)"
            } else {
                testResult = "Unexpected response"
            }
        } catch {
            testResult = "Unreachable: \(error.localizedDescription)"
        }
    }
}

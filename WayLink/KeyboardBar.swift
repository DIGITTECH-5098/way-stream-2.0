import SwiftUI

/// On-screen keyboard row + text injection bar (regular mode).
struct KeyboardBar: View {
    @ObservedObject var client: StreamClient
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var ctrlHeld = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // special key row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    keyChip("Esc", .escape)
                    keyChip("Tab", .tab)
                    keyChip("Enter", .enter)
                    keyChip("Del", .del)
                    keyChip("Fwd-Del", .forwardDel)
                    keyChip("◀", .dpadLeft)
                    keyChip("▲", .dpadUp)
                    keyChip("▼", .dpadDown)
                    keyChip("▶", .dpadRight)
                    keyChip("Home", .moveHome)
                    keyChip("End", .moveEnd)
                    keyChip("PgUp", .pageUp)
                    keyChip("PgDn", .pageDown)
                    ToggleChip(label: "Ctrl", isOn: $ctrlHeld)
                }
                .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                TextField("Type to Android…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onAppear { focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        client.sendText(text)
        text = ""
    }

    private func keyChip(_ label: String, _ key: AndroidKey) -> some View {
        Button(label) {
            if ctrlHeld {
                // Ctrl+key -> metaState META_CTRL_ON = 0x1000
                client.sendKey(key, down: true, meta: 0x1000)
                client.sendKey(key, down: false, meta: 0x1000)
            } else {
                client.sendKey(key, down: true)
                client.sendKey(key, down: false)
            }
        }
        .buttonStyle(.bordered)
        .font(.system(size: 12, weight: .medium))
    }
}

private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Button(label) { isOn.toggle() }
            .buttonStyle(.bordered)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isOn ? .orange : .primary)
    }
}

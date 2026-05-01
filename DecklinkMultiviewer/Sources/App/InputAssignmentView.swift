import SwiftUI

struct InputAssignmentView: View {

    @ObservedObject var settings: AppSettings

    let availableDevices: [SDIDeckLinkDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input assignment")
                .font(.headline)
                .padding(.bottom, 12)

            ForEach(0..<4, id: \.self) { slot in
                InputRow(
                    slot:             slot,
                    config:           $settings.inputs[slot],
                    availableDevices: availableDevices
                )
                if slot < 3 { Divider().padding(.vertical, 4) }
            }
        }
        .padding()
    }
}

private struct InputRow: View {

    let slot:             Int
    @Binding var config:  InputConfig
    let availableDevices: [SDIDeckLinkDevice]

    var body: some View {
        HStack(spacing: 12) {

            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.15))
                Text("\(slot + 1)")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Label")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("CAM \(slot + 1)", text: $config.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DeckLink port")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $config.physicalDeviceIndex) {
                    Text("— unassigned —").tag(-1)
                    ForEach(availableDevices, id: \.deviceIndex) { dev in
                        Text(dev.displayName).tag(Int(dev.deviceIndex))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text("LUT")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Toggle("", isOn: $config.lutEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(config.lutURL == nil)
                    Button(config.lutURL?.lastPathComponent ?? "Choose…") {
                        chooseLUT(for: slot)
                    }
                    .font(.caption)
                    if config.lutURL != nil {
                        Button {
                            config.lutURL    = nil
                            config.lutEnabled = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func chooseLUT(for slot: Int) {
        let panel = NSOpenPanel()
        panel.title               = "Choose LUT for Input \(slot + 1)"
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            config.lutURL    = panel.url
            config.lutEnabled = true
        }
    }
}

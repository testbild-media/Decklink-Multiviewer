import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {

    convenience init(settings: AppSettings,
                     devices:  [SDIDeckLinkDevice],
                     onApply:  @escaping () -> Void) {

        let panel = SettingsPanel(settings: settings,
                                  devices:  devices,
                                  onApply:  onApply)
        let host  = NSHostingController(rootView: panel)

        let win = NSWindow(contentViewController: host)
        win.title               = "Decklink Multiviewer — Settings"
        win.styleMask           = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 680, height: 640))
        win.center()

        self.init(window: win)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsPanel: View {

    @ObservedObject var settings: AppSettings
    let devices:  [SDIDeckLinkDevice]
    let onApply:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                InputAssignmentView(settings: settings,
                                    availableDevices: devices)
                    .tabItem { Label("Inputs", systemImage: "video.fill") }

                TallySettingsView(settings: settings)
                    .tabItem { Label("Tally", systemImage: "dot.radiowaves.left.and.right") }

                ControlSettingsView(settings: settings)
                    .tabItem { Label("Control", systemImage: "keyboard") }
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Apply & Restart Capture") {
                    settings.save()
                    onApply()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct TallySettingsView: View {
    @ObservedObject var settings: AppSettings

    var isTSL: Bool {
        settings.tallyMode == .tslUDP || settings.tallyMode == .tslTCP
    }

    var body: some View {
        Form {
            Picker("Source", selection: $settings.tallyMode) {
                ForEach(AppSettings.TallyMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if settings.tallyMode == .rest || settings.tallyMode == .webSocket {
                TextField("URL / Endpoint", text: $settings.tallyURL)
                    .textFieldStyle(.roundedBorder)
            }

            if settings.tallyMode == .rest {
                HStack {
                    Text("Poll interval")
                    Stepper("\(settings.tallyPollMs) ms",
                            value: $settings.tallyPollMs,
                            in: 10...500, step: 10)
                }
            }

            if isTSL {
                Divider()
                Text("TSL 5.0 Settings").font(.headline)

                HStack {
                    TextField("Listen Port", text: Binding(
                        get: { String(settings.tslPort) },
                        set: { if let v = Int($0), v >= 0, v <= 65535 { settings.tslPort = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 156)
                    Stepper("", value: $settings.tslPort, in: 0...65535, step: 1)
                        .labelsHidden()
                }

                Text("TSL Address mapping (0-based)")
                    .font(.caption).foregroundColor(.secondary)

                ForEach(0..<4, id: \.self) { i in
                    HStack {
                        Text("Input \(i+1) ← TSL Address")
                        TextField("", value: $settings.tslAddresses[i], format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }

                Divider()

                Toggle("Override UMD labels from TSL", isOn: $settings.tslOverrideUMD)
                    .help("When enabled, TSL UMD text replaces the label for each input")

                if settings.tslOverrideUMD {
                    Text("TSL UMD text will override camera labels in the Settings → Inputs tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !isTSL && settings.tallyMode != .disabled {
                GroupBox("Expected JSON format") {
                    Text("{ \"program\": [1, 3], \"preview\": [1, 3] }\n1-based input numbers on PGM/PVW bus\nInput 1 = 1\nInput 2 = 2\nInput 3 = 3\nInput 4 = 4")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if isTSL {
                GroupBox("TSL 5.0 Protocol Info") {
                    Text("Listening on 0.0.0.0:\(String(settings.tslPort)) for TSL UMD v5 packets.\n\nTally evaluation:\nTXT, LH and RH are evaluated using OR logic.\nIf any of TXT, LH or RH is RED, Program Tally is set.\n\nSupported states:\nRED, GREEN and AMBER (derived from RED + GREEN) and UMD Text.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

private struct ControlSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                GroupBox("Keyboard Hotkeys") {
                    VStack(spacing: 0) {
                        HotkeyRow(label: "Input 1 fullscreen",  key: $settings.hotkeyInput1)
                        Divider()
                        HotkeyRow(label: "Input 2 fullscreen",  key: $settings.hotkeyInput2)
                        Divider()
                        HotkeyRow(label: "Input 3 fullscreen",  key: $settings.hotkeyInput3)
                        Divider()
                        HotkeyRow(label: "Input 4 fullscreen",  key: $settings.hotkeyInput4)
                        Divider()
                        HotkeyRow(label: "Multiview",           key: $settings.hotkeyMultiview)
                    }
                    .padding(.top, 4)

                    Text("Single character keys. Case-insensitive for multiview.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }

                GroupBox("OSC Remote Control (UDP)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Listen port:", systemImage: "network")
                            TextField("Port", text: Binding(
                                get: { String(settings.oscPort) },
                                set: { if let v = Int($0), v >= 0, v <= 65535 { settings.oscPort = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            Stepper("", value: $settings.tslPort, in: 0...65535, step: 1)
                                .labelsHidden()
                        }

                        Divider()

                        Text("Supported OSC messages:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            OSCRow(msg: "/monitor/layout 0",       desc: "→ Multiview (brings window to front)")
                            OSCRow(msg: "/monitor/layout 1",       desc: "→ Input 1 fullscreen (brings window to front)")
                            OSCRow(msg: "/monitor/layout 2",       desc: "→ Input 2 fullscreen (brings window to front)")
                            OSCRow(msg: "/monitor/layout 3",       desc: "→ Input 3 fullscreen (brings window to front)")
                            OSCRow(msg: "/monitor/layout 4",       desc: "→ Input 4 fullscreen (brings window to front)")
                            OSCRow(msg: "/monitor/window 0",       desc: "→ Minimize window")
                            OSCRow(msg: "/monitor/window 1",       desc: "→ Show / unminimize window")
                        }

                        Divider()

                        Text("Compatible with: TouchOSC, QLab, Bitfocus Companion, custom scripts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }
}

private struct HotkeyRow: View {
    let label: String
    @Binding var key: String

    var body: some View {
        HStack {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onChange(of: key) { newVal in
                    if newVal.count > 1 {
                        key = String(newVal.suffix(1))
                    } else if newVal.isEmpty {
                        key = " "
                    }
                }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

private struct OSCRow: View {
    let msg:  String
    let desc: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(msg)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 210, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct MenuShortcutRow: View {
    let key:  String
    let desc: String
    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 60, alignment: .leading)
            Text(desc)
                .foregroundColor(.secondary)
        }
    }
}

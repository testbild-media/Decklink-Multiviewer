import Foundation

final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private init() { load() }

    @Published var captureFormat: CaptureFormatOption = .p1080_50

    @Published var inputs: [InputConfig] = [
        InputConfig(label: "INPUT 1", physicalDeviceIndex: 0),
        InputConfig(label: "INPUT 2", physicalDeviceIndex: 1),
        InputConfig(label: "INPUT 3", physicalDeviceIndex: 2),
        InputConfig(label: "INPUT 4", physicalDeviceIndex: 3),
    ]

    @Published var tallyMode: TallyMode   = .disabled
    @Published var tallyURL:  String      = "http://127.0.0.1:8080/tally"

    @Published var oscPort: Int = 8765

    @Published var hotkeyInput1:    String = "1"
    @Published var hotkeyInput2:    String = "2"
    @Published var hotkeyInput3:    String = "3"
    @Published var hotkeyInput4:    String = "4"
    @Published var hotkeyMultiview: String = "m"
    @Published var tallyPollMs: Int       = 50

    enum TallyMode: Int, CaseIterable, Identifiable {
        case rest, webSocket, tslUDP, tslTCP, disabled
        var id: Int { rawValue }
        var displayName: String {
            switch self {
            case .rest:      return "REST polling"
            case .webSocket: return "WebSocket"
            case .tslUDP:    return "TSL 5.0 UDP"
            case .tslTCP:    return "TSL 5.0 TCP"
            case .disabled:  return "Disabled"
            }
        }
    }

    @Published var tslPort:     Int    = 8900
    @Published var tslOverrideUMD: Bool = true
    @Published var tslAddresses: [Int] = [0, 1, 2, 3]

    private let defaults = UserDefaults.standard

    func save() {
        defaults.set(captureFormat.rawValue, forKey: "captureFormat")
        defaults.set(tallyMode.rawValue,     forKey: "tallyMode")
        defaults.set(tallyURL,               forKey: "tallyURL")
        defaults.set(tallyPollMs,            forKey: "tallyPollMs")
        defaults.set(oscPort,         forKey: "oscPort")
        defaults.set(hotkeyInput1,    forKey: "hotkeyInput1")
        defaults.set(hotkeyInput2,    forKey: "hotkeyInput2")
        defaults.set(hotkeyInput3,    forKey: "hotkeyInput3")
        defaults.set(hotkeyInput4,    forKey: "hotkeyInput4")
        defaults.set(hotkeyMultiview, forKey: "hotkeyMultiview")
        defaults.set(tslPort,                forKey: "tslPort")
        defaults.set(tslOverrideUMD,         forKey: "tslOverrideUMD")
        defaults.set(tslAddresses,           forKey: "tslAddresses")

        for (i, cfg) in inputs.enumerated() {
            defaults.set(cfg.label,               forKey: "input\(i).label")
            defaults.set(cfg.physicalDeviceIndex, forKey: "input\(i).deviceIdx")
            defaults.set(cfg.lutEnabled, forKey: "input\(i).lutEnabled")
            if let url = cfg.lutURL {
                defaults.set(url.path, forKey: "input\(i).lutPath")
            } else {
                defaults.removeObject(forKey: "input\(i).lutPath")
            }
        }
    }

    func load() {
        if let v = defaults.object(forKey: "captureFormat") as? Int,
           let f = CaptureFormatOption(rawValue: v) {
            captureFormat = f
        }
        if let v = defaults.object(forKey: "tallyMode") as? Int,
           let m = TallyMode(rawValue: v) {
            tallyMode = m
        }
        if let v = defaults.string(forKey: "tallyURL")  { tallyURL    = v }
        if let v = defaults.object(forKey: "tallyPollMs") as? Int { tallyPollMs = v }
        if let v = defaults.object(forKey: "oscPort") as? Int { oscPort = v }
        if let v = defaults.string(forKey: "hotkeyInput1")    { hotkeyInput1    = v }
        if let v = defaults.string(forKey: "hotkeyInput2")    { hotkeyInput2    = v }
        if let v = defaults.string(forKey: "hotkeyInput3")    { hotkeyInput3    = v }
        if let v = defaults.string(forKey: "hotkeyInput4")    { hotkeyInput4    = v }
        if let v = defaults.string(forKey: "hotkeyMultiview") { hotkeyMultiview = v }
        if let v = defaults.object(forKey: "tslPort")    as? Int  { tslPort     = v }
        tslOverrideUMD = defaults.object(forKey: "tslOverrideUMD") as? Bool ?? true
        if let v = defaults.array(forKey: "tslAddresses") as? [Int] { tslAddresses = v }

        for i in 0..<4 {
            if let label = defaults.string(forKey: "input\(i).label") {
                inputs[i].label = label
            }
            let devIdx = defaults.integer(forKey: "input\(i).deviceIdx")
            inputs[i].physicalDeviceIndex = devIdx == 0 &&
                defaults.object(forKey: "input\(i).deviceIdx") == nil ? i : devIdx
            inputs[i].lutEnabled = defaults.bool(forKey: "input\(i).lutEnabled")
            if let path = defaults.string(forKey: "input\(i).lutPath") {
                inputs[i].lutURL = URL(fileURLWithPath: path)
            }
        }
    }
}

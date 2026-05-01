import AppKit
import Network
import Darwin

final class ControlPlane {

    var onLayoutChange:    ((DisplayLayout) -> Void)?
    var onSettingsRequest: (() -> Void)?
    var onWindowControl:   ((Bool) -> Void)?

    private var oscListener: NWListener?
    private var keyMonitor:  Any?

    var isSettingsOpen: Bool = false

    func startKeyMonitoring() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isSettingsOpen { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func stopKeyMonitoring() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let ch = event.charactersIgnoringModifiers, !ch.isEmpty else { return false }
        let key = ch.lowercased()

        let s = AppSettings.shared

        let h1  = s.hotkeyInput1.lowercased().trimmingCharacters(in: .whitespaces)
        let h2  = s.hotkeyInput2.lowercased().trimmingCharacters(in: .whitespaces)
        let h3  = s.hotkeyInput3.lowercased().trimmingCharacters(in: .whitespaces)
        let h4  = s.hotkeyInput4.lowercased().trimmingCharacters(in: .whitespaces)
        let hmv = s.hotkeyMultiview.lowercased().trimmingCharacters(in: .whitespaces)

        if !h1.isEmpty  && key == h1  { fire(.single(0)); return true }
        if !h2.isEmpty  && key == h2  { fire(.single(1)); return true }
        if !h3.isEmpty  && key == h3  { fire(.single(2)); return true }
        if !h4.isEmpty  && key == h4  { fire(.single(3)); return true }
        if !hmv.isEmpty && key == hmv { fire(.multiview); return true }
        if key == "," {
            DispatchQueue.main.async { self.onSettingsRequest?() }
            return true
        }
        return false
    }

    private func fire(_ layout: DisplayLayout) {
        DispatchQueue.main.async {
            self.onWindowControl?(true)
            self.onLayoutChange?(layout)
        }
    }

    private var oscSocket: Int32 = -1
    private var oscQueue:  DispatchQueue?

    func startOSC(port: UInt16 = 8765) {
        stopOSC()
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            NSLog("[OSC] socket() failed")
            return
        }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            NSLog("[OSC] bind() failed on port \(port) — errno \(errno)")
            close(sock)
            return
        }

        oscSocket = sock
        NSLog("[OSC] Listening on UDP :\(port)")

        let q = DispatchQueue(label: "osc.receive", qos: .userInteractive)
        oscQueue = q
        q.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while let self, self.oscSocket >= 0 {
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    self.parseOSCPacket(data)
                } else if n < 0 && errno != EINTR {
                    break
                }
            }
        }
    }

    func stopOSC() {
        if oscSocket >= 0 {
            close(oscSocket)
            oscSocket = -1
        }
        oscQueue = nil
        oscListener?.cancel()
        oscListener = nil
    }

    private func parseOSCPacket(_ data: Data) {
        guard let nullIdx = data.firstIndex(of: 0) else { return }
        let address = String(data: data[..<nullIdx], encoding: .utf8) ?? ""
        guard address == "/monitor/layout" || address == "/monitor/window" else { return }

        let addrPadded = (nullIdx + 4) & ~3
        guard addrPadded < data.count else { return }

        let tagStart = addrPadded + 1
        let tagEnd   = data[addrPadded...].firstIndex(of: 0) ?? data.endIndex
        let typeTag  = String(data: data[tagStart..<tagEnd], encoding: .utf8) ?? ""
        let argStart = (tagEnd + 4) & ~3

        if address == "/monitor/window", typeTag.hasPrefix("i"), argStart + 4 <= data.count {
            let v = data[argStart..<argStart+4].withUnsafeBytes {
                Int32(bigEndian: $0.load(as: Int32.self))
            }
            DispatchQueue.main.async { self.onWindowControl?(v != 0) }
            return
        }

        if typeTag.hasPrefix("i"), argStart + 4 <= data.count {
            let v = data[argStart..<argStart+4].withUnsafeBytes {
                Int32(bigEndian: $0.load(as: Int32.self))
            }
            switch v {
            case 0:       fire(.multiview)
            case 1...4:   fire(.single(Int(v) - 1))
            default:      break
            }
        } else if typeTag.hasPrefix("s") {
            if let s = String(data: data[argStart...], encoding: .utf8)?
                .prefix(while: { $0 != "\0" }) {
                switch s {
                case "0", "multi", "m": fire(.multiview)
                case "1":               fire(.single(0))
                case "2":               fire(.single(1))
                case "3":               fire(.single(2))
                case "4":               fire(.single(3))
                default:                break
                }
            }
        }
    }
}

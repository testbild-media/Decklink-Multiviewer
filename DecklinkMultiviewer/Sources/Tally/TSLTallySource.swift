import Foundation
import Network
import Darwin

typealias TSLUpdateCallback = (_ pgm: [Bool], _ pvw: [Bool], _ labels: [String?]) -> Void

final class TSLTallySource: TallySource {

    var onUpdate:    (([Bool], [Bool]) -> Void)?
    var onTSLUpdate: TSLUpdateCallback?

    enum Transport { case udp, tcp }

    private let transport:  Transport
    private let port:       UInt16
    private let addresses:  [Int]

    private var udpSocket:  Int32 = -1
    private var listener:   NWListener?
    private var running = false

    private var pgmState:    [Bool]
    private var pvwState:    [Bool]
    private var labelsState: [String?]

    init(transport: Transport, host: String = "0.0.0.0",
         port: UInt16 = 8900, addresses: [Int] = [0,1,2,3]) {
        self.transport = transport
        self.port      = port
        self.addresses = addresses
        self.pgmState    = Array(repeating: false, count: addresses.count)
        self.pvwState    = Array(repeating: false, count: addresses.count)
        self.labelsState = Array(repeating: Optional<String>.none, count: addresses.count)
    }

    func start() async throws {
        running = true
        switch transport {
        case .udp: startUDP()
        case .tcp: await startTCP()
        }
        while running && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func stop() {
        running = false
        if udpSocket >= 0 { close(udpSocket); udpSocket = -1 }
        listener?.cancel()
    }

    private func startUDP() {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { NSLog("[TSL] socket() failed"); return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

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
            NSLog("[TSL] bind() failed errno \(errno)"); close(sock); return
        }
        udpSocket = sock
        NSLog("[TSL] UDP listening on :\(port)")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while let self, self.udpSocket >= 0 {
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    let hex = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
                    NSLog("[TSL] UDP recv %d bytes: %@", n, hex)
                    self.parse(data: data)
                } else if n < 0 && errno != EINTR { break }
            }
        }
    }

    private func startTCP() async {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else {
            NSLog("[TSL] Failed to bind TCP :\(port)"); return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            self?.receiveTCP(connection: conn, buffer: Data())
        }
        l.start(queue: .global(qos: .userInteractive))
        listener = l
        NSLog("[TSL] TCP listening on :\(port)")
    }

    private func receiveTCP(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buf = buffer
            if let data { buf.append(data) }

            let hex = buf.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("[TSL] TCP buffer %d bytes: %@", buf.count, hex)

            var pos = buf.startIndex

            while pos < buf.endIndex {
                guard pos + 4 <= buf.endIndex else { break }

                if buf[pos] == 0xFE && buf[pos + 1] == 0x02 {
                    let packetLen = Int(buf[pos + 2]) | (Int(buf[pos + 3]) << 8)
                    let totalLen = 4 + packetLen

                    guard packetLen >= 2 else {
                        NSLog("[TSL] TCP invalid FE02 packetLen=%d at pos=%d", packetLen, pos)
                        pos = buf.index(after: pos)
                        continue
                    }

                    guard totalLen <= 4096 else {
                        NSLog("[TSL] TCP unrealistic FE02 packetLen=%d at pos=%d", packetLen, pos)
                        pos = buf.index(after: pos)
                        continue
                    }

                    guard pos + totalLen <= buf.endIndex else {
                        break
                    }

                    let packet = Data(buf[(pos + 2)..<(pos + totalLen)])
                    self.parse(data: packet)

                    pos += totalLen
                    continue
                }

                let packetLen = Int(buf[pos]) | (Int(buf[pos + 1]) << 8)
                let totalLen = 2 + packetLen

                guard packetLen >= 2 else {
                    NSLog("[TSL] TCP invalid packetLen=%d at pos=%d", packetLen, pos)
                    pos = buf.index(after: pos)
                    continue
                }

                guard totalLen <= 4096 else {
                    NSLog("[TSL] TCP unrealistic packetLen=%d at pos=%d", packetLen, pos)
                    pos = buf.index(after: pos)
                    continue
                }

                guard pos + totalLen <= buf.endIndex else {
                    break
                }

                self.parse(data: Data(buf[pos..<(pos + totalLen)]))
                pos += totalLen
            }

            let remaining = pos < buf.endIndex ? Data(buf[pos..<buf.endIndex]) : Data()

            if !isComplete && error == nil {
                self.receiveTCP(connection: connection, buffer: remaining)
            } else {
                NSLog("[TSL] TCP closed isComplete=%d error=%@",
                      isComplete ? 1 : 0,
                      String(describing: error))
            }
        }
    }

    private func parse(data: Data) {
        guard data.count >= 4 else { return }

        let base = data.startIndex

        let packetLen = Int(data[base]) | (Int(data[base + 1]) << 8)
        let screen    = Int(data[base + 2]) | (Int(data[base + 3]) << 8)

        NSLog("[TSL] packetLen=%d screen=%d totalData=%d", packetLen, screen, data.count)

        guard data.count >= 2 + packetLen else {
            NSLog("[TSL] Truncated packet")
            return
        }

        var offset = base + 4
        let end = base + 2 + packetLen

        while offset + 8 <= end {
            let tslAddr = Int(data[offset]) | (Int(data[offset + 1]) << 8)

            let control =
                UInt32(data[offset + 2]) |
                (UInt32(data[offset + 3]) << 8) |
                (UInt32(data[offset + 4]) << 16) |
                (UInt32(data[offset + 5]) << 24)

            let textLen = Int(data[offset + 6]) | (Int(data[offset + 7]) << 8)

            offset += 8

            guard offset + textLen <= end else {
                NSLog("[TSL] Bad textLen=%d at addr=%d control=0x%08X", textLen, tslAddr, control)
                return
            }

            let umdText: String?
            if textLen > 0 {
                umdText = String(data: data[offset..<offset + textLen], encoding: .utf8)
                offset += textLen
            } else {
                umdText = nil
            }

            let tallyId = Int(control & 0xFF)
            let tallyStatus = Int((control >> 16) & 0xFF)

            let rightIsRed = (tallyStatus & 0x01) != 0
            let textIsRed  = (tallyStatus & 0x04) != 0
            let leftIsRed  = (tallyStatus & 0x10) != 0

            let rightIsGreen = (tallyStatus & 0x02) != 0
            let textIsGreen  = (tallyStatus & 0x08) != 0
            let leftIsGreen  = (tallyStatus & 0x20) != 0

            let isPGM = rightIsRed || textIsRed || leftIsRed
            let isPVW = rightIsGreen || textIsGreen || leftIsGreen

            let rhTally: Int
            if rightIsRed && rightIsGreen {
                rhTally = 3
            } else if rightIsRed {
                rhTally = 1
            } else if rightIsGreen {
                rhTally = 2
            } else {
                rhTally = 0
            }

            let txtTally: Int
            if textIsRed && textIsGreen {
                txtTally = 3
            } else if textIsRed {
                txtTally = 1
            } else if textIsGreen {
                txtTally = 2
            } else {
                txtTally = 0
            }

            let lhTally: Int
            if leftIsRed && leftIsGreen {
                lhTally = 3
            } else if leftIsRed {
                lhTally = 1
            } else if leftIsGreen {
                lhTally = 2
            } else {
                lhTally = 0
            }

            NSLog("[TSL] addr=%d tallyId=%d control=0x%08X status=0x%02X RH=%d TXT=%d LH=%d pgm=%d pvw=%d text='%@'",
                  tslAddr,
                  tallyId,
                  control,
                  tallyStatus,
                  rhTally,
                  txtTally,
                  lhTally,
                  isPGM ? 1 : 0,
                  isPVW ? 1 : 0,
                  umdText ?? "")

            for (inputIdx, addr) in addresses.enumerated() {
                if addr == tallyId {
                    pgmState[inputIdx] = isPGM
                    pvwState[inputIdx] = isPVW
                    labelsState[inputIdx] = umdText
                }
            }
        }

        onUpdate?(pgmState, pvwState)
        onTSLUpdate?(pgmState, pvwState, labelsState)
    }
}

import Foundation

protocol TallySource: AnyObject {
    var onUpdate: (([Bool], [Bool]) -> Void)? { get set }
    func start() async throws
    func stop()
}

final class TallyManager {

    var onTallyUpdate: (([TallyState]) -> Void)?
    var onLabelUpdate: (([String?]) -> Void)?

    private let tslStoredUMDKey = "tslStoredUMDLabels"

    private var source: (any TallySource)?
    private var task:   Task<Void, Never>?

    func configure(settings: AppSettings) {
        stop()

        let storedLabels = loadStoredUMDLabels()
        if settings.tslOverrideUMD && !storedLabels.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onLabelUpdate?(storedLabels)
            }
        }

        switch settings.tallyMode {
        case .rest:
            guard let url = URL(string: settings.tallyURL) else { return }
            let s = RESTTallySource(endpoint: url,
                                    pollInterval: .milliseconds(settings.tallyPollMs))
            attachSource(s)

        case .webSocket:
            guard let url = URL(string: settings.tallyURL) else { return }
            let s = WebSocketTallySource(endpoint: url)
            attachSource(s)

        case .tslUDP:
            let s = TSLTallySource(transport: .udp,
                                   port: UInt16(settings.tslPort),
                                   addresses: settings.tslAddresses)
            attachTSL(s, settings: settings)

        case .tslTCP:
            let s = TSLTallySource(transport: .tcp,
                                   port: UInt16(settings.tslPort),
                                   addresses: settings.tslAddresses)
            attachTSL(s, settings: settings)

        case .disabled:
            break
        }
    }

    private func makeStates(pgm: [Bool], pvw: [Bool]) -> [TallyState] {
        let count = max(pgm.count, pvw.count)

        return (0..<count).map { index in
            let program = index < pgm.count ? pgm[index] : false
            let preview = index < pvw.count ? pvw[index] : false

            return TallyState(program: program, preview: preview)
        }
    }

    private func loadStoredUMDLabels() -> [String?] {
        guard let stored = UserDefaults.standard.array(forKey: tslStoredUMDKey) as? [String] else {
            return []
        }

        return stored.map { $0.isEmpty ? nil : $0 }
    }

    private func saveStoredUMDLabels(_ labels: [String?]) {
        let stored = labels.map { $0 ?? "" }
        UserDefaults.standard.set(stored, forKey: tslStoredUMDKey)
    }

    private func attachSource(_ src: any TallySource) {
        src.onUpdate = { [weak self] pgm, pvw in
            let states = self?.makeStates(pgm: pgm, pvw: pvw) ?? []
            DispatchQueue.main.async {
                self?.onTallyUpdate?(states)
            }
        }

        source = src
        task = Task {
            do { try await src.start() }
            catch { NSLog("[Tally] Source error: \(error)") }
        }
    }

    private func attachTSL(_ tsl: TSLTallySource, settings: AppSettings) {
        tsl.onUpdate = { [weak self] pgm, pvw in
            let states = self?.makeStates(pgm: pgm, pvw: pvw) ?? []
            DispatchQueue.main.async {
                self?.onTallyUpdate?(states)
            }
        }

        tsl.onTSLUpdate = { [weak self] pgm, pvw, labels in
            guard let self else { return }

            let states = self.makeStates(pgm: pgm, pvw: pvw)

            DispatchQueue.main.async {
                self.onTallyUpdate?(states)

                if settings.tslOverrideUMD {
                    self.saveStoredUMDLabels(labels)
                    self.onLabelUpdate?(labels)
                }
            }
        }

        source = tsl
        task = Task {
            do { try await tsl.start() }
            catch { NSLog("[TSL] Error: \(error)") }
        }
    }

    func stop() {
        task?.cancel()
        source?.stop()
        source = nil
    }
}

final class RESTTallySource: TallySource {

    var onUpdate: (([Bool], [Bool]) -> Void)?

    private let endpoint:     URL
    private let pollInterval: Duration
    private var running = false

    private struct TallyResponse: Decodable {
        let program: [Int]
        let preview: [Int]?
    }

    init(endpoint: URL, pollInterval: Duration = .milliseconds(50)) {
        self.endpoint     = endpoint
        self.pollInterval = pollInterval
    }

    func start() async throws {
        running = true

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5

        let session = URLSession(configuration: config)

        while running && !Task.isCancelled {
            do {
                let (data, _) = try await session.data(from: endpoint)
                let resp = try JSONDecoder().decode(TallyResponse.self, from: data)

                var pgm = Array(repeating: false, count: 4)
                var pvw = Array(repeating: false, count: 4)

                for i in resp.program where i >= 1 && i <= 4 {
                    pgm[i - 1] = true
                }

                for i in resp.preview ?? [] where i >= 1 && i <= 4 {
                    pvw[i - 1] = true
                }

                onUpdate?(pgm, pvw)

            } catch let err as URLError where
                err.code == .timedOut ||
                err.code == .networkConnectionLost ||
                err.code == .notConnectedToInternet {
            } catch { }

            try await Task.sleep(for: pollInterval)
        }
    }

    func stop() {
        running = false
    }
}

final class WebSocketTallySource: TallySource {

    var onUpdate: (([Bool], [Bool]) -> Void)?

    private let endpoint: URL
    private var wsTask:   URLSessionWebSocketTask?
    private var running = false

    private struct TallyMessage: Decodable {
        let program: [Int]
        let preview: [Int]?
    }

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func start() async throws {
        running = true

        let session = URLSession(configuration: .ephemeral)

        while running && !Task.isCancelled {
            wsTask = session.webSocketTask(with: endpoint)
            wsTask?.resume()

            await receiveLoop()

            if running {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func receiveLoop() async {
        guard let ws = wsTask else { return }

        while running {
            do {
                let msg = try await ws.receive()
                var data: Data?

                switch msg {
                case .string(let s):
                    data = s.data(using: .utf8)

                case .data(let d):
                    data = d

                @unknown default:
                    break
                }

                if let d = data,
                   let t = try? JSONDecoder().decode(TallyMessage.self, from: d) {
                    var pgm = Array(repeating: false, count: 4)
                    var pvw = Array(repeating: false, count: 4)

                    for i in t.program where i >= 1 && i <= 4 {
                        pgm[i - 1] = true
                    }

                    for i in t.preview ?? [] where i >= 1 && i <= 4 {
                        pvw[i - 1] = true
                    }

                    onUpdate?(pgm, pvw)
                }

            } catch {
                break
            }
        }
    }

    func stop() {
        running = false
        wsTask?.cancel(with: .normalClosure, reason: nil)
    }
}

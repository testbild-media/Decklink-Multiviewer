import AppKit
import MetalKit

final class MainWindowController: NSWindowController {

    private var bridge:    SDIDeckLinkBridge?
    private var layout:    DisplayLayout = .multiview
    private var renderer:  MetalRenderer?
    private var tally:     TallyManager!
    private var control:   ControlPlane!
    private var status:    StatusBarController?
    private var settings:  AppSettings { AppSettings.shared }

    private(set) var availableDevices: [SDIDeckLinkDevice] = []
    private var connections: [Bool] = Array(repeating: false, count: 4)

    private var connectionTimer: Timer?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false)
        win.title           = "SDI Monitor"
        win.backgroundColor = .black
        win.collectionBehavior = [.fullScreenPrimary]

        self.init(window: win)

        availableDevices = SDIDeckLinkBridge.enumerateDevices()

        setupMetal()
        setupCapture()
        setupTally()
        setupControl()
        startConnectionPolling()

        status = StatusBarController(window: win)
        win.contentAspectRatio = NSSize(width: 16, height: 9)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutNotification(_:)),
            name: .sdiLayoutDidChange,
            object: nil)
    }

    deinit {
        connectionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device.")
        }

        let mtkView = ClickableMTKView(frame: window!.contentView!.bounds, device: device)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor       = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.framebufferOnly  = false
        mtkView.wantsLayer       = true
        window!.contentView      = mtkView

        mtkView.onMouseDown = { [weak self] point in
            self?.handleViewClick(at: point, in: mtkView)
        }

        do {
            let r = try MetalRenderer(view: mtkView)
            renderer = r
            r.bridge = bridge
            loadLUTs()
        } catch {
            NSLog("[Metal] Renderer init failed: \(error)")
        }
    }

    private func setupCapture() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let b = SDIDeckLinkBridge(device: device)
        bridge = b
        renderer?.bridge = b

        for (slot, cfg) in settings.inputs.enumerated() {
            if cfg.physicalDeviceIndex >= 0 {
                b?.assignDevice(cfg.physicalDeviceIndex, toInput: slot)
            }
        }
        startCapture()
    }

    private func startCapture() {
        guard let b = bridge else { return }
        do {
            try b.startCapture(with: settings.captureFormat.sdkValue)
        } catch {
            NSLog("[Capture] Start failed: \(error.localizedDescription)")
        }
    }

    func restartCapture() {
        bridge?.stopCapture()
        for (slot, cfg) in settings.inputs.enumerated() {
            if cfg.physicalDeviceIndex >= 0 {
                bridge?.assignDevice(cfg.physicalDeviceIndex, toInput: slot)
            }
        }
        renderer?.configs = settings.inputs
        loadLUTs()
        startCapture()
    }

    private func startConnectionPolling() {
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let b = self.bridge else { return }
            self.connections = [b.input0Connected, b.input1Connected,
                                b.input2Connected, b.input3Connected]

            let formats = [b.input0Format, b.input1Format,
                           b.input2Format, b.input3Format]
            for (i, fmt) in formats.enumerated() {
                let newFmt = fmt as String
                if newFmt != self.renderer?.detectedFormats[i] {
                    self.renderer?.detectedFormats[i]  = newFmt
                    self.renderer?.formatTimestamps[i] = Date()
                }
            }

            self.updateStatus()
        }
    }


    private func setupTally() {
        tally = TallyManager()
        tally.onTallyUpdate = { [weak self] states in
            guard let self else { return }
            self.renderer?.tallies = states
            self.updateStatus()
        }
        tally.onLabelUpdate = { [weak self] labels in
            guard let self else { return }
            for (i, label) in labels.enumerated() where i < 4 {
                if let text = label, !text.isEmpty {
                    self.renderer?.configs[i].label = text
                }
            }
        }
        tally.configure(settings: settings)
    }

    private func setupControl() {
        control = ControlPlane()
        control.onLayoutChange = { [weak self] layout in
            self?.layout           = layout
            self?.renderer?.layout = layout
            self?.updateStatus()
        }
        control.onWindowControl = { [weak self] show in
            guard let win = self?.window else { return }
            if show {
                if win.isMiniaturized { win.deminiaturize(nil) }
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                win.miniaturize(nil)
            }
        }
        control.onSettingsRequest = { [weak self] in self?.openSettings() }
        control.startKeyMonitoring()
        control.startOSC(port: UInt16(settings.oscPort))
    }

    @objc private func handleLayoutNotification(_ note: Notification) {
        if let layout = note.object as? DisplayLayout {
            self.layout      = layout
            renderer?.layout = layout
            updateStatus()
        }
    }

    private func loadLUTs() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for (i, cfg) in settings.inputs.enumerated() {
            guard let url = cfg.lutURL else { renderer?.luts[i] = nil; continue }
            do {
                renderer?.luts[i] = try LUTLoader.load(url: url, device: device)
            } catch {
                NSLog("[LUT] Input \(i+1): \(error)")
                renderer?.luts[i] = nil
            }
        }
        renderer?.configs = settings.inputs
    }

    private var settingsController: SettingsWindowController?

    private func handleViewClick(at point: NSPoint, in view: NSView) {
        if point.x < 0 {
            control.onLayoutChange?(.multiview)
            return
        }

        let size = view.bounds.size
        switch layout {
        case .multiview:
            let gap: CGFloat   = 2.0
            let cellW: CGFloat = (size.width  - gap * 3) / 2
            let cellH: CGFloat = (size.height - gap * 3) / 2
            let col   = point.x < (gap + cellW) ? 0 : 1
            let row   = point.y > (gap + cellH) ? 0 : 1
            let index = row * 2 + col
            if index >= 0 && index < 4 {
                control.onLayoutChange?(.single(index))
            }

        case .single:
            control.onLayoutChange?(.multiview)
        }
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                settings: settings,
                devices:  availableDevices,
                onApply: { [weak self] in
                    self?.settingsController = nil
                    self?.control.isSettingsOpen = false
                    self?.restartCapture()
                    self?.tally.configure(settings: AppSettings.shared)
                    self?.control.stopOSC()
                    self?.control.startOSC(port: UInt16(AppSettings.shared.oscPort))
                    DispatchQueue.main.async {
                        self?.window?.makeKeyAndOrderFront(nil)
                    }
                })
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object:  settingsController?.window,
                queue:   .main) { [weak self] _ in
                    self?.control.isSettingsOpen = false
                    self?.settingsController = nil
                    self?.window?.makeKeyAndOrderFront(nil)
                }
        }
        control.isSettingsOpen = true
        settingsController?.show()
    }

    private func updateStatus() {
        status?.update(
            connections: connections,
            tallies:     renderer?.tallies ?? [],
            layout:      renderer?.layout  ?? .multiview)
    }
}

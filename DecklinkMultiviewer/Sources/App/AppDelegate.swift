
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        buildMenuBar()
        mainWindowController = MainWindowController()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSettings.shared.save()
    }

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Decklink Multiviewer",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings",
                                   action: #selector(openSettings),
                                   keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Decklink Multiviewer",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(item("Input 1",    key: "", action: #selector(showInput1)))
        viewMenu.addItem(item("Input 2",    key: "", action: #selector(showInput2)))
        viewMenu.addItem(item("Input 3",    key: "", action: #selector(showInput3)))
        viewMenu.addItem(item("Input 4",    key: "", action: #selector(showInput4)))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Multiview",  key: "", action: #selector(showMultiview)))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Fullscreen", key: "f", action: #selector(toggleFullscreen),
                              modifiers: .command))

        NSApp.mainMenu = mainMenu
    }

    private func item(_ title: String, key: String,
                      action: Selector, modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.keyEquivalentModifierMask = modifiers
        return m
    }

    @objc private func openSettings() {
        mainWindowController?.openSettings()
    }
    @objc private func showInput1()    { setLayout(.single(0)) }
    @objc private func showInput2()    { setLayout(.single(1)) }
    @objc private func showInput3()    { setLayout(.single(2)) }
    @objc private func showInput4()    { setLayout(.single(3)) }
    @objc private func showMultiview() { setLayout(.multiview) }

    @objc private func toggleFullscreen() {
        mainWindowController?.window?.toggleFullScreen(nil)
    }

    private func setLayout(_ layout: DisplayLayout) {
        NotificationCenter.default.post(
            name: .sdiLayoutDidChange, object: layout)
    }
}

extension Notification.Name {
    static let sdiLayoutDidChange = Notification.Name("sdiLayoutDidChange")
}

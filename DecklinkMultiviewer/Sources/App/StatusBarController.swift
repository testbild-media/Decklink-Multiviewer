import AppKit

final class StatusBarController {

    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }

    func update(connections: [Bool], tallies: [TallyState], layout: DisplayLayout) {
        var parts: [String] = []

        let dots = connections.enumerated().map { i, on in
            on ? "●" : "○"
        }.joined()
        parts.append(dots)

        switch layout {
        case .single(let i): parts.append("INPUT \(i+1)            ")
        case .multiview:     parts.append("MULTIVIEWER")
        }

        window?.title = "Decklink Multiviewer — \(parts.joined(separator: " "))"
    }
}

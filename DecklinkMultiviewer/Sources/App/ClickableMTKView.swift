import MetalKit
import AppKit

final class ClickableMTKView: MTKView {

    var onMouseDown: ((NSPoint) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseDown?(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMouseDown?(NSPoint(x: -1, y: -1))
    }
}

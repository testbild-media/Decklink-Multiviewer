import AppKit

final class AspectRatioView: NSView {

    var mtkView: NSView?
    private let ratio: CGFloat = 16.0 / 9.0

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let v = mtkView else { return }

        let w = bounds.width
        let h = bounds.height

        var fw = w
        var fh = w / ratio

        if fh > h {
            fh = h
            fw = h * ratio
        }

        let x = (w - fw) / 2
        let y = (h - fh) / 2
        v.frame = NSRect(x: x, y: y, width: fw, height: fh)
    }
}

import Metal
import CoreGraphics

struct MultiviewLayoutEngine {

    static func multiviewViewports(drawableSize: CGSize,
                                   gapPixels: Double = 2.0) -> [MTLViewport] {
        let w  = (drawableSize.width  - gapPixels) / 2
        let h  = (drawableSize.height - gapPixels) / 2
        let g  = gapPixels

        return [
            MTLViewport(originX: 0,     originY: 0,     width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: w + g, originY: 0,     width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: 0,     originY: h + g, width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: w + g, originY: h + g, width: w, height: h, znear: 0, zfar: 1),
        ]
    }

    static func fullscreenViewport(drawableSize: CGSize) -> MTLViewport {
        MTLViewport(originX: 0, originY: 0,
                    width:  drawableSize.width,
                    height: drawableSize.height,
                    znear: 0, zfar: 1)
    }

    static func labelOrigin(for inputIndex: Int,
                             drawableSize: CGSize,
                             layout: DisplayLayout) -> CGPoint {
        let vp: MTLViewport
        switch layout {
        case .single:
            vp = fullscreenViewport(drawableSize: drawableSize)
        case .multiview:
            vp = multiviewViewports(drawableSize: drawableSize)[inputIndex]
        }

        let margin: Double = 12
        let pillH:  Double = 26
        return CGPoint(x: vp.originX + margin,
                       y: vp.originY + vp.height - pillH - margin)
    }
}

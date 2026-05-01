import Metal
import CoreText
import CoreGraphics

final class OverlayRenderer {

    private let device: MTLDevice
    init(device: MTLDevice) { self.device = device }

    func texture(for label: String, tally: TallyState,
                 widthPx: Int, heightPx: Int) -> MTLTexture? {

        let w = max(widthPx, 8)
        let h = max(heightPx, 8)

        guard let ctx = CGContext(
            data:             nil,
            width:            w,
            height:           h,
            bitsPerComponent: 8,
            bytesPerRow:      w * 4,
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        let fontSize = CGFloat(h) * 0.72
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)

        let attrStr = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0),
                                        label as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attrStr))
        CFAttributedStringSetAttribute(attrStr, range,
                                       kCTFontAttributeName, font)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        CFAttributedStringSetAttribute(attrStr, range,
                                       kCTForegroundColorAttributeName, white)

        let line = CTLineCreateWithAttributedString(attrStr)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        let x = max(2, (CGFloat(w) - textW) / 2.0)
        let y = (CGFloat(h) - (ascent + descent)) / 2.0 + descent

        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage       = .shaderRead
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region:      MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0,
                    withBytes:   ctx.data!,
                    bytesPerRow: ctx.bytesPerRow)
        return tex
    }

    func invalidateCache() {}
}

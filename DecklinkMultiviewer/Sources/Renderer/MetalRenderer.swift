import Metal
import MetalKit
import AppKit
import simd

final class MetalRenderer: NSObject, MTKViewDelegate {

    var layout:     DisplayLayout       = .multiview
    var tallies:    [TallyState]        = Array(repeating: .init(), count: 4)
    var configs:    [InputConfig]       = Array(repeating: .init(), count: 4)
    var luts:       [MTLTexture?]       = Array(repeating: nil,     count: 4)

    var overlayRenderer: OverlayRenderer?

    var detectedFormats: [String]     = Array(repeating: "", count: 4)
    var formatTimestamps: [Date]      = Array(repeating: .distantPast, count: 4)
    static let formatDisplayDuration: TimeInterval = 10.0

    var bridge: SDIDeckLinkBridge?

    let device:        MTLDevice
    let commandQueue:  MTLCommandQueue
    private let videoPSO:    MTLRenderPipelineState
    private let overlayPSO:  MTLRenderPipelineState
    private let labelBgPSO:  MTLRenderPipelineState
    private let blitPSO:     MTLRenderPipelineState
    private let fillPSO:     MTLRenderPipelineState

    private let blackLuma:   MTLTexture
    private let blackChroma: MTLTexture
    private let blackLUT:    MTLTexture

    private var labelTextureCache: [String: MTLTexture] = [:]

    init(view: MTKView) throws {
        guard let dev = view.device else {
            throw NSError(domain: "DecklinkMultiviewer", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }
        device       = dev
        commandQueue = device.makeCommandQueue()!

        let lib = device.makeDefaultLibrary()!

        func pso(frag: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label                              = frag
            d.vertexFunction                     = lib.makeFunction(name: "vs_quad")!
            d.fragmentFunction                   = lib.makeFunction(name: frag)!
            d.colorAttachments[0].pixelFormat    = view.colorPixelFormat
            if frag != "fs_video" {
                d.colorAttachments[0].isBlendingEnabled           = true
                d.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor      = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try dev.makeRenderPipelineState(descriptor: d)
        }

        videoPSO   = try pso(frag: "fs_video")
        overlayPSO = try pso(frag: "fs_overlay")
        labelBgPSO = try pso(frag: "fs_label_bg")
        blitPSO    = try pso(frag: "fs_blit")
        fillPSO    = try pso(frag: "fs_fill")

        func makeBlack(_ format: MTLPixelFormat, w: Int = 2, h: Int = 2) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .private
            if let t = dev.makeTexture(descriptor: d) { return t }
            d.storageMode = .managed
            if let t = dev.makeTexture(descriptor: d) { return t }
            d.storageMode = .managed
            return dev.makeTexture(descriptor: d)!
        }
        blackLuma   = makeBlack(.r16Unorm,  w: 2, h: 2)
        blackChroma = makeBlack(.rg16Unorm, w: 2, h: 2)
        blackLUT    = MetalRenderer.makeIdentityLUT(device: dev)

        overlayRenderer = OverlayRenderer(device: device)
        super.init()
        view.delegate                  = self
        view.preferredFramesPerSecond  = 50
        view.enableSetNeedsDisplay     = false
        view.isPaused                  = false
    }

    private var lastDrawableSize: CGSize = .zero

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        overlayRenderer?.invalidateCache()
        lastDrawableSize = size
    }

    func draw(in view: MTKView) {
        let ds = view.drawableSize
        if ds != lastDrawableSize {
            overlayRenderer?.invalidateCache()
            lastDrawableSize = ds
        }
        guard let drawable = view.currentDrawable,
              let rpd      = view.currentRenderPassDescriptor,
              let cb        = commandQueue.makeCommandBuffer() else { return }

        cb.label = "DecklinkMultiviewer.frame"
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.label = "DecklinkMultiviewer.enc"

        switch layout {
        case .single(let i):
            let vp = fullViewport(view)
            enc.setViewport(vp)
            drawVideo(enc, inputIndex: i)
            drawOverlay(enc, inputIndex: i, view: view, viewport: vp, scale: 0.5)

        case .multiview:
            let vps = multiviewViewports(view)
            for i in 0..<4 {
                enc.setViewport(vps[i])
                drawVideo(enc, inputIndex: i)
                drawOverlay(enc, inputIndex: i, view: view, viewport: vps[i], scale: 1.0)
            }
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func drawVideo(_ enc: MTLRenderCommandEncoder, inputIndex i: Int) {
        let frame  = bridge?.latestFrame(forInput: i)
        let luma   = frame?.lumaTexture   ?? blackLuma
        let chroma = frame?.chromaTexture ?? blackChroma
        let lut    = luts[i]              ?? blackLUT
        let lutOn  = configs[i].lutEnabled && luts[i] != nil

        enc.setRenderPipelineState(videoPSO)

        var uni = VideoUniforms(lutEnabled: lutOn ? 1.0 : 0.0,
                                _pad0: 0, _pad1: 0, _pad2: 0)
        enc.setFragmentBytes(&uni, length: MemoryLayout<VideoUniforms>.size, index: 0)
        enc.setFragmentTexture(luma,   index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentTexture(lut,    index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawOverlay(_ enc: MTLRenderCommandEncoder,
                              inputIndex i: Int,
                              view: MTKView,
                              viewport: MTLViewport,
                              scale: Double = 1.0) {
        let tally = tallies[i]
        let active = tally.active
        let color = tallyColor(tally)

        let borderFrac: Double = 0.015 * scale
        let borderX = active ? Float(borderFrac * viewport.height / viewport.width)  : 0.0
        let borderY = active ? Float(borderFrac) : 0.0

        enc.setRenderPipelineState(overlayPSO)
        enc.setFragmentTexture(blackLuma, index: 0)

        var ov = OverlayUniforms(
            borderColor: color,
            borderWidth: borderX,
            tallyActive: active ? 1.0 : 0.0,
            _pad0: borderY,
            _pad1: 0
        )
        enc.setFragmentBytes(&ov, length: MemoryLayout<OverlayUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        drawLabel(enc, inputIndex: i, viewport: viewport, tallyActive: active, scale: scale)

        let age = Date().timeIntervalSince(formatTimestamps[i])
        if age < MetalRenderer.formatDisplayDuration && !detectedFormats[i].isEmpty {
            drawFormatBadge(enc, inputIndex: i, viewport: viewport, scale: scale)
        }
    }

    private func tallyColor(_ tally: TallyState, alpha: Float = 1.0) -> SIMD4<Float> {
        if tally.program && tally.preview {
            return SIMD4<Float>(1.0, 0.72, 0.0, alpha)
        } else if tally.program {
            return SIMD4<Float>(0.85, 0.0, 0.0, alpha)
        } else if tally.preview {
            return SIMD4<Float>(0.0, 0.75, 0.0, alpha)
        } else {
            return SIMD4<Float>(0.0, 0.0, 0.0, alpha)
        }
    }

    private func drawLabel(_ enc: MTLRenderCommandEncoder,
                            inputIndex i: Int,
                            viewport: MTLViewport,
                            tallyActive: Bool = false,
                            scale: Double = 1.0) {
        let label = configs[i].label.isEmpty ? "CAM \(i+1)" : configs[i].label

        let cellW = viewport.width
        let cellH = viewport.height
        let barH  = cellH * 0.07 * scale
        let barW  = cellW / 3.0 * scale
        let barX  = viewport.originX + (cellW - barW) / 2.0

        guard let labelTex = overlayRenderer?.texture(
            for: label, tally: tallies[i],
            widthPx:  Int(barW),
            heightPx: Int(barH)) else { return }

        let barVP = MTLViewport(
            originX: barX,
            originY: viewport.originY + cellH - barH,
            width:   barW,
            height:  barH,
            znear: 0, zfar: 1)

        enc.setViewport(barVP)

        enc.setRenderPipelineState(fillPSO)
        let bgColor: SIMD4<Float> = tallyActive
            ? tallyColor(tallies[i], alpha: 0.50)
            : SIMD4<Float>(0, 0, 0, 0.30)
        var fill = FillUniforms(color: bgColor)
        enc.setFragmentBytes(&fill, length: MemoryLayout<FillUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        enc.setRenderPipelineState(blitPSO)
        enc.setFragmentTexture(labelTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        enc.setViewport(viewport)
    }

    private func drawFormatBadge(_ enc: MTLRenderCommandEncoder,
                                   inputIndex i: Int,
                                   viewport: MTLViewport,
                                   scale: Double = 1.0) {
        let fmt = detectedFormats[i]
        guard !fmt.isEmpty else { return }

        let cellW  = viewport.width
        let cellH  = viewport.height
        let badgeH = cellH * 0.035 * scale
        let badgeW = cellW * 0.20  * scale
        let margin = max(4.0, cellH * 0.02)

        guard let tex = overlayRenderer?.texture(
            for: fmt, tally: TallyState(),
            widthPx: Int(badgeW), heightPx: Int(badgeH)) else { return }

        let badgeVP = MTLViewport(
            originX: viewport.originX + margin,
            originY: viewport.originY + margin,
            width:   badgeW, height: badgeH, znear: 0, zfar: 1)

        enc.setViewport(badgeVP)
        enc.setRenderPipelineState(fillPSO)
        var fill = FillUniforms(color: SIMD4<Float>(0, 0, 0, 0.30))
        enc.setFragmentBytes(&fill, length: MemoryLayout<FillUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        enc.setRenderPipelineState(blitPSO)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.setViewport(viewport)
    }

    private func fullViewport(_ view: MTKView) -> MTLViewport {
        MTLViewport(originX: 0, originY: 0,
                    width:  view.drawableSize.width,
                    height: view.drawableSize.height,
                    znear: 0, zfar: 1)
    }

    private func multiviewViewports(_ view: MTKView) -> [MTLViewport] {
        let gap: Double = 2.0
        let totalW = view.drawableSize.width
        let totalH = view.drawableSize.height
        let w = (totalW - gap * 3) / 2
        let h = (totalH - gap * 3) / 2

        let x0 = gap
        let x1 = gap * 2 + w
        let y0 = gap
        let y1 = gap * 2 + h

        return [
            MTLViewport(originX: x0, originY: y0, width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: x1, originY: y0, width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: x0, originY: y1, width: w, height: h, znear: 0, zfar: 1),
            MTLViewport(originX: x1, originY: y1, width: w, height: h, znear: 0, zfar: 1),
        ]
    }

    static func makeIdentityLUT(device: MTLDevice) -> MTLTexture {
        let size = 2
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width  = size; desc.height = size; desc.depth = size
        desc.usage  = .shaderRead
        desc.storageMode = .managed
        var tex: MTLTexture?
        tex = device.makeTexture(descriptor: desc)
        if tex == nil { desc.storageMode = .managed; tex = device.makeTexture(descriptor: desc) }
        guard let tex else { fatalError("Failed to create identity LUT texture") }
        var data = [UInt16]()
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let rv = Float(r) / Float(size - 1)
            let gv = Float(g) / Float(size - 1)
            let bv = Float(b) / Float(size - 1)
            data.append(toFloat16(rv))
            data.append(toFloat16(gv))
            data.append(toFloat16(bv))
            data.append(toFloat16(1.0))
        }}}
        data.withUnsafeBytes { ptr in
            tex.replace(region: MTLRegionMake3D(0,0,0,size,size,size),
                        mipmapLevel: 0, slice: 0,
                        withBytes: ptr.baseAddress!,
                        bytesPerRow:   size * 4 * 2,
                        bytesPerImage: size * size * 4 * 2)
        }
        return tex
    }
}

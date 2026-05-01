import Metal
import CoreFoundation

enum LUTLoaderError: Error {
    case fileReadFailed
    case missingSize
    case insufficientData(expected: Int, got: Int)
    case metalAllocationFailed
}

struct LUTLoader {

    static func load(url: URL, device: MTLDevice) throws -> MTLTexture {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw LUTLoaderError.fileReadFailed
        }

        var size  = 0
        var table = [Float]()
        table.reserveCapacity(33 * 33 * 33 * 3)

        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.uppercased().hasPrefix("LUT_3D_SIZE") {
                size = Int(t.split(separator: " ").last ?? "33") ?? 33
                continue
            }
            if t.hasPrefix("DOMAIN") || t.hasPrefix("TITLE") ||
               t.hasPrefix("LUT_1D") { continue }
            let vals = t.split(separator: " ").compactMap { Float($0) }
            if vals.count >= 3 {
                table.append(vals[0]); table.append(vals[1]); table.append(vals[2])
            }
        }

        guard size > 0 else { throw LUTLoaderError.missingSize }
        let expected = size * size * size
        guard table.count / 3 >= expected else {
            throw LUTLoaderError.insufficientData(expected: expected, got: table.count / 3)
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width  = size; desc.height = size; desc.depth = size
        desc.usage  = .shaderRead
        desc.storageMode = .managed

        guard let tex = device.makeTexture(descriptor: desc) else {
            throw LUTLoaderError.metalAllocationFailed
        }

        var packed = [UInt16]()
        packed.reserveCapacity(expected * 4)
        for i in 0..<expected {
            packed.append(toFloat16(table[i * 3 + 0]))
            packed.append(toFloat16(table[i * 3 + 1]))
            packed.append(toFloat16(table[i * 3 + 2]))
            packed.append(toFloat16(1.0))
        }

        let bytesPerRow   = size * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = size * bytesPerRow

        packed.withUnsafeBytes { ptr in
            tex.replace(
                region:        MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel:   0,
                slice:         0,
                withBytes:     ptr.baseAddress!,
                bytesPerRow:   bytesPerRow,
                bytesPerImage: bytesPerImage)
        }
        return tex
    }
}

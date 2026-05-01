import Metal
import simd

enum DisplayLayout: Equatable {
    case single(Int)
    case multiview
}

struct TallyState {
    var program: Bool = false
    var preview: Bool = false

    var active: Bool { program || preview }
    var amber: Bool { program && preview }
}

struct InputConfig {
    var label:             String  = "CAM"
    var physicalDeviceIndex: Int   = -1
    var lutEnabled:        Bool    = false
    var lutURL:            URL?    = nil
}

struct VideoUniforms {
    var lutEnabled: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
}

struct OverlayUniforms {
    var borderColor:  SIMD4<Float>
    var borderWidth:  Float
    var tallyActive:  Float
    var _pad0: Float = 0
    var _pad1: Float = 0
}

struct FillUniforms {
    var color: SIMD4<Float>
}

enum CaptureFormatOption: Int, CaseIterable, Identifiable {
    case p1080_50   = 0
    case p1080_25   = 1
    case p1080_2997 = 2
    case i1080_50   = 3
    case i1080_5994 = 4
    case p720_50    = 5
    case p720_5994  = 6

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .p1080_50:   return "1080p50"
        case .p1080_25:   return "1080p25"
        case .p1080_2997: return "1080p29.97"
        case .i1080_50:   return "1080i50"
        case .i1080_5994: return "1080i59.94"
        case .p720_50:    return "720p50"
        case .p720_5994:  return "720p59.94"
        }
    }

    var sdkValue: SDICaptureFormat {
        SDICaptureFormat(rawValue: rawValue)!
    }
}

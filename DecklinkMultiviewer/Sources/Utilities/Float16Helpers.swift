func toFloat16(_ f: Float) -> UInt16 {
    var input = f
    var output: UInt16 = 0
    withUnsafeBytes(of: &input) { src in
        let bits     = src.load(as: UInt32.self)
        let sign     = UInt16((bits >> 31) & 0x1) << 15
        let exp32    = Int32((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7FFFFF

        if exp32 <= 0 {
            output = sign
        } else if exp32 >= 31 {
            output = sign | 0x7C00
        } else {
            output = sign | UInt16(exp32 << 10) | UInt16(mantissa >> 13)
        }
    }
    return output
}

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vs_quad(uint vid [[vertex_id]]) {
    const float2 pos[6] = {
        {-1,-1},{1,-1},{-1,1},
        {-1, 1},{1,-1},{ 1,1}
    };
    // UV: (0,0) = top-left in Metal texture space
    const float2 uv[6] = {
        {0,1},{1,1},{0,0},
        {0,0},{1,1},{1,0}
    };
    VertexOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv       = uv[vid];
    return o;
}

inline float3 ycbcr709_to_rgb(float y, float cb, float cr) {
    float Y  = (y  - 64.0/1023.0) * (1023.0 / (940.0 - 64.0));
    float Cb = cb - 512.0/1023.0;
    float Cr = cr - 512.0/1023.0;

    float r = Y                  + 1.5748 * Cr;
    float g = Y - 0.1873 * Cb   - 0.4681 * Cr;
    float b = Y + 1.8556 * Cb;

    return float3(r, g, b);
}

struct VideoUniforms {
    float lutEnabled;
    float _pad0, _pad1, _pad2;
};

fragment float4 fs_video(
    VertexOut           in      [[stage_in]],
    texture2d<float>    luma    [[texture(0)]],
    texture2d<float>    chroma  [[texture(1)]],
    texture3d<float>    lut3d   [[texture(2)]],
    constant VideoUniforms &uni [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float y = luma.sample(s, in.uv).r;

    float2 cbcr = chroma.sample(s, in.uv).rg;

    float3 rgb = saturate(ycbcr709_to_rgb(y, cbcr.r, cbcr.g));

    if (uni.lutEnabled > 0.5) {
        constexpr sampler lutS(filter::linear, address::clamp_to_edge);
        rgb = lut3d.sample(lutS, rgb).rgb;
    }

    return float4(rgb, 1.0);
}

struct OverlayUniforms {
    float4 borderColor;
    float  borderWidth;
    float  tallyActive;
    float  _pad0, _pad1;
};

fragment float4 fs_overlay(
    VertexOut                 in  [[stage_in]],
    texture2d<float>          vid [[texture(0)]],
    constant OverlayUniforms &uni [[buffer(0)]])
{
    float2 uv = in.uv;
    float bw  = uni.borderWidth;

    if (uni.tallyActive < 0.5 || bw <= 0.0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float minDist = min(min(uv.x, 1.0 - uv.x),
                        min(uv.y, 1.0 - uv.y));

    float alpha = (1.0 - smoothstep(bw * 0.5, bw, minDist)) * 0.88;

    return float4(uni.borderColor.rgb, alpha);
}
fragment float4 fs_label_bg(VertexOut in [[stage_in]]) {
    float2 uv  = in.uv * 2.0 - 1.0;
    float  r   = 0.35;
    float  dist = length(float2(max(abs(uv.x) - (1.0 - r), 0.0),
                                max(abs(uv.y) - (1.0 - r), 0.0)));
    float  mask = 1.0 - smoothstep(r - 0.05, r, dist);
    return float4(0.0, 0.0, 0.0, 0.62 * mask);
}

fragment float4 fs_blit(
    VertexOut        in  [[stage_in]],
    texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

struct FillUniforms {
    float4 color;
};

fragment float4 fs_fill(
    VertexOut             in  [[stage_in]],
    constant FillUniforms &uni [[buffer(0)]])
{
    return uni.color;
}

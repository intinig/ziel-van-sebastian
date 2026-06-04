#include <metal_stdlib>
using namespace metal;

struct V2F {
    float4 position [[position]];
    float2 uv;
};

// --- Flat colored geometry (face rects, sweep band) ---

vertex V2F flat_vertex(const device float2 *verts [[buffer(0)]],
                       uint vid [[vertex_id]]) {
    V2F out;
    out.position = float4(verts[vid], 0, 1);
    out.uv = float2(0, 0);
    return out;
}

fragment float4 flat_fragment(V2F in [[stage_in]],
                              constant float4 &color [[buffer(0)]]) {
    return color;
}

// --- Textured quad (glyph textures; r8 alpha mask × tint) ---

struct TexQuadVertexIn {
    float2 position;
    float2 uv;
};

vertex V2F texquad_vertex(const device TexQuadVertexIn *verts [[buffer(0)]],
                          uint vid [[vertex_id]]) {
    V2F out;
    out.position = float4(verts[vid].position, 0, 1);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 texquad_fragment(V2F in [[stage_in]],
                                 texture2d<float> glyph [[texture(0)]],
                                 constant float4 &tint [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float a = glyph.sample(s, in.uv).r;
    return float4(tint.rgb, tint.a * a);
}

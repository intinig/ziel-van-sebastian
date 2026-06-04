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

// ============================ CRT pipeline ============================

struct CRTParams {
    float scanlineIntensity;
    float maskIntensity;
    float bloomStrength;
    float curvature;
    float vignette;
    float flicker;
    float noise;
    float persistence;
    float time;
    float pad0;                // keep float2 aligned identically in Swift+MSL
    float2 resolution;
};

// Fullscreen triangle — no vertex buffer needed.
vertex V2F fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    V2F out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = pos[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// Phosphor persistence: new = max(scene, previous * decay).
fragment float4 persist_fragment(V2F in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> previous [[texture(1)]],
                                 constant CRTParams &p [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float3 cur = scene.sample(s, in.uv).rgb;
    float3 prev = previous.sample(s, in.uv).rgb * p.persistence;
    return float4(max(cur, prev), 1);
}

fragment float4 bright_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    return float4(c * smoothstep(0.35, 0.75, lum), 1);
}

constant float blurWeights[5] = { 0.227027, 0.194594, 0.121622, 0.054054, 0.016216 };

fragment float4 blur_h_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float texel = 1.0 / src.get_width();
    float3 acc = src.sample(s, in.uv).rgb * blurWeights[0];
    for (int i = 1; i < 5; i++) {
        acc += src.sample(s, in.uv + float2(texel * i, 0)).rgb * blurWeights[i];
        acc += src.sample(s, in.uv - float2(texel * i, 0)).rgb * blurWeights[i];
    }
    return float4(acc, 1);
}

fragment float4 blur_v_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float texel = 1.0 / src.get_height();
    float3 acc = src.sample(s, in.uv).rgb * blurWeights[0];
    for (int i = 1; i < 5; i++) {
        acc += src.sample(s, in.uv + float2(0, texel * i)).rgb * blurWeights[i];
        acc += src.sample(s, in.uv - float2(0, texel * i)).rgb * blurWeights[i];
    }
    return float4(acc, 1);
}

static float2 barrel(float2 uv, float k) {
    float2 c = uv - 0.5;
    float r2 = dot(c, c);
    return 0.5 + c * (1.0 + k * r2);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

fragment float4 composite_fragment(V2F in [[stage_in]],
                                   texture2d<float> phosphor [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   constant CRTParams &p [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = barrel(in.uv, p.curvature);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    float3 color = phosphor.sample(s, uv).rgb;
    color += bloom.sample(s, uv).rgb * p.bloomStrength;

    // Scanlines: one dark line per ~3 output pixels.
    float line = sin(uv.y * p.resolution.y * 1.047);
    color *= 1.0 - p.scanlineIntensity * (0.5 + 0.5 * line);

    // Aperture grille: RGB triads across x.
    int px = int(uv.x * p.resolution.x);
    float3 mask = float3(1.0 - p.maskIntensity);
    mask[px % 3] = 1.0;
    color *= mask;

    // Vignette.
    float2 d = uv - 0.5;
    color *= 1.0 - p.vignette * dot(d, d) * 2.5;

    // Flicker + noise.
    color *= 1.0 - p.flicker * (0.5 + 0.5 * sin(p.time * 120.0));
    color += (hash21(uv * p.resolution + p.time) - 0.5) * p.noise;

    return float4(max(color, 0.0), 1);
}

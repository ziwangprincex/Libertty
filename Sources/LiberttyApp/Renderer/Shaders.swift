/// Metal shaders, compiled at launch with `MTLDevice.makeLibrary(source:)`
/// (the Command Line Tools have no offline `metal` compiler). Layouts must
/// match `RectInstance`, `GlyphInstance` and `Uniforms` in TerminalRenderer.swift.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;   // drawable size, px
    float2 atlasSize;  // glyph atlas size, px
    float2 offset;     // moves everything (smooth scrolling), px
};

struct RectInstance {
    float4 rect;       // x, y, w, h in px from the top-left
    uint color;        // RGBA8, R in the low byte
    uint pad0, pad1, pad2;
};

struct GlyphInstance {
    float4 rect;       // destination, px
    float4 uv;         // atlas region, px
    uint color;        // tint for mask glyphs
    uint flags;        // bit 0: color glyph
    uint pad0, pad1;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint flags [[flat]];
};

static float4 to_clip(float2 px, float2 viewport) {
    return float4(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0, 0.0, 1.0);
}

// Four vertices per instance, drawn as a triangle strip.
static float2 corner(uint vid) { return float2(vid & 1, vid >> 1); }

vertex VertexOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant RectInstance *rects [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    RectInstance r = rects[iid];
    VertexOut out;
    out.position = to_clip(r.rect.xy + u.offset + corner(vid) * r.rect.zw, u.viewport);
    out.uv = float2(0);
    out.color = unpack_unorm4x8_to_float(r.color);
    out.flags = 0;
    return out;
}

fragment float4 rect_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);  // premultiplied
}

vertex VertexOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant GlyphInstance *glyphs [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    GlyphInstance g = glyphs[iid];
    float2 c = corner(vid);
    VertexOut out;
    out.position = to_clip(g.rect.xy + u.offset + c * g.rect.zw, u.viewport);
    out.uv = (g.uv.xy + c * g.uv.zw) / u.atlasSize;
    out.color = unpack_unorm4x8_to_float(g.color);
    out.flags = g.flags;
    return out;
}

// Kitty graphics images: one textured quad each.
struct ImageInstance {
    float4 rect;       // destination, px
    float4 uv;         // source region, normalized
};

vertex VertexOut image_vertex(uint vid [[vertex_id]],
                              constant ImageInstance &img [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    float2 c = corner(vid);
    VertexOut out;
    out.position = to_clip(img.rect.xy + u.offset + c * img.rect.zw, u.viewport);
    out.uv = img.uv.xy + c * img.uv.zw;
    out.color = float4(1);
    out.flags = 0;
    return out;
}

fragment float4 image_fragment(VertexOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 c = image.sample(s, in.uv);  // straight RGBA
    return float4(c.rgb * c.a, c.a);
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    float4 texel = atlas.sample(s, in.uv);  // premultiplied BGRA, swizzled to RGBA
    if (in.flags & 1u) {
        return texel * in.color.a;
    }
    float coverage = texel.a * in.color.a;
    return float4(in.color.rgb * coverage, coverage);
}
"""

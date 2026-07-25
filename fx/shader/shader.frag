#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(set = 0, binding = 0) uniform sampler2D textures[];

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec2 in_sdf_pos;
layout(location = 3) in vec2 in_half_size;
layout(location = 4) in flat float in_radius;
layout(location = 5) in flat uint in_kind;
layout(location = 6) in flat uint in_tex_idx;

layout(location = 0) out vec4 out_color;

#define KIND_RECT  0u
#define KIND_TEX2D 1u
#define KIND_MSDF  2u

#define MSDF_PXRANGE  8.0
#define MSDF_TEXSIZE  548.0
#define TEXT_THICKNESS 0.6

float rect_sdf(vec2 pos, vec2 half_size, float r) {
    vec2 q = abs(pos) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float msdf_median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

void main() {
    float alpha = 1.0;
    vec4 tex_color = vec4(1.0);

    if (in_kind == KIND_TEX2D || in_kind == KIND_MSDF) {
        tex_color = texture(textures[nonuniformEXT(in_tex_idx)], in_uv);
    }

    if (in_kind == KIND_MSDF) {
        float sd = msdf_median(tex_color.r, tex_color.g, tex_color.b) - 0.5;

        vec2 unit_range = vec2(MSDF_PXRANGE) / vec2(MSDF_TEXSIZE);
        vec2 screen_tex_size = vec2(1.0) / fwidth(in_uv);
        float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);

        float screen_px_dist = screen_px_range * sd;
        float opacity = clamp(screen_px_dist + TEXT_THICKNESS, 0.0, 1.0);

        tex_color = vec4(1.0, 1.0, 1.0, opacity);
    }

    // SDF rect clipping for rect and textured quads with radius
    if (in_kind == KIND_RECT || (in_kind == KIND_TEX2D && in_radius > 0.0)) {
        if (in_radius > 0.0) {
            float safe_radius = min(in_radius, min(in_half_size.x, in_half_size.y));
            float dist = rect_sdf(in_sdf_pos, in_half_size, safe_radius);
            float aa = fwidth(dist);
            float feather = aa * 0.5;
            alpha = 1.0 - smoothstep(-feather, feather, dist);
        }
    }

    out_color = in_color * tex_color;
    out_color.a *= alpha;
}

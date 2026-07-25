#version 450

layout(push_constant) uniform PushConstants {
    vec2 screen_size;
};

struct Instance {
    vec4 dst;        // x0, y0, x1, y1 in pixels
    vec4 src;        // u0, v0, u1, v1 in UV
    uvec4 colors;    // TL, TR, BL, BR
    float radius;
    uint kind;
    uint tex_idx;
};

layout(std430, set = 0, binding = 1) readonly buffer InstanceBuffer {
    Instance instances[];
};

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec2 out_sdf_pos;
layout(location = 3) out vec2 out_half_size;
layout(location = 4) out flat float out_radius;
layout(location = 5) out flat uint out_kind;
layout(location = 6) out flat uint out_tex_idx;

vec4 unpack_color(uint packed) {
    return vec4(
        float(packed & 0xFFu) / 255.0,
        float((packed >> 8u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >> 24u) & 0xFFu) / 255.0
    );
}

void main() {
    Instance inst = instances[gl_InstanceIndex];
    uint vid = gl_VertexIndex & 3u;

    // Corner: TL, TR, BL, BR
    vec2 corner = vec2(
        (vid & 1u) != 0u ? 1.0 : 0.0,
        (vid & 2u) != 0u ? 1.0 : 0.0
    );

    vec2 half_size = (inst.dst.zw - inst.dst.xy) * 0.5;
    vec2 center = inst.dst.xy + half_size;

    vec2 local = corner * 2.0 - 1.0;  // -1 to +1
    vec2 pixel_pos = local * half_size + center;

    gl_Position = vec4(
        pixel_pos.x / screen_size.x * 2.0 - 1.0,
        pixel_pos.y / screen_size.y * 2.0 - 1.0,
        0.0, 1.0
    );

    out_uv = mix(inst.src.xy, inst.src.zw, corner);
    out_color = unpack_color(inst.colors[vid]);
    out_sdf_pos = local * half_size;
    out_half_size = half_size;
    out_radius = inst.radius;
    out_kind = inst.kind;
    out_tex_idx = inst.tex_idx;
}

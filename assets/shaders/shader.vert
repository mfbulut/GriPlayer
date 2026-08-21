#version 450

layout(push_constant) uniform PushConstants {
    vec2 screen_size;
};

struct Instance {
    vec4 dest;
    vec4 src;
    vec4 clip;
    uvec4 colors;
    float radius;
    uint index;
    uint kind;
    uint _pad;
};

layout(std430, set = 0, binding = 1) readonly buffer InstanceBuffer {
    Instance instances[];
};

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec2 out_sdf_pos;
layout(location = 3) out vec2 out_half_size;
layout(location = 4) out flat float out_radius;
layout(location = 6) out flat uint out_tex_idx;
layout(location = 5) out flat uint out_kind;

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

    vec2 corner = vec2(
        (vid & 1u) != 0u ? 1.0 : 0.0,
        (vid & 2u) != 0u ? 1.0 : 0.0
    );

    vec2 pixel_pos;
    vec2 half_size;
    vec2 sdf_pos;

    if (inst.kind == 3u) {
        pixel_pos = (vid == 0u) ? inst.dest.xy : ((vid == 1u) ? inst.dest.zw : ((vid == 2u) ? inst.src.xy : inst.src.zw));
        out_uv = corner;
    } else {
        vec2 d0 = inst.dest.xy;
        vec2 d1 = inst.dest.zw;

        vec2 cd0 = clamp(d0, inst.clip.xy, inst.clip.zw);
        vec2 cd1 = clamp(d1, inst.clip.xy, inst.clip.zw);

        pixel_pos = mix(cd0, cd1, corner);

        vec2 orig_size = max(d1 - d0, vec2(1e-5));
        vec2 t = (pixel_pos - d0) / orig_size;
        out_uv = mix(inst.src.xy, inst.src.zw, t);

        half_size = (d1 - d0) * 0.5;
        vec2 orig_center = (d0 + d1) * 0.5;
        sdf_pos = pixel_pos - orig_center;
    }

    gl_Position = vec4(
        pixel_pos / screen_size * 2.0 - 1.0,
        0.0, 1.0
    );

    out_color = unpack_color(inst.colors[vid]);
    out_sdf_pos = sdf_pos;
    out_half_size = half_size;
    out_radius = inst.radius;
    out_tex_idx = inst.index;
    out_kind = inst.kind;
}

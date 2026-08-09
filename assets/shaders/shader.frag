#version 450
#extension GL_EXT_nonuniform_qualifier : enable
#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require
#extension GL_EXT_shader_16bit_storage : require

layout(set = 0, binding = 0) uniform sampler2D textures[];

struct Curve {
    f16vec2 p0;
    f16vec2 p1;
    f16vec2 p2;
};

layout(std430, set = 0, binding = 2) readonly buffer CurveBuffer {
    Curve curves[];
};

struct Stripe {
    uint curve_start;
    uint curve_count;
};

layout(std430, set = 0, binding = 3) readonly buffer StripeBuffer {
    Stripe stripes[];
};

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec2 in_sdf_pos;
layout(location = 3) in vec2 in_half_size;
layout(location = 4) in flat float in_radius;
layout(location = 5) in flat uint in_kind;
layout(location = 6) in flat uint in_index;

layout(location = 0) out vec4 out_color;

#define KIND_RECT    0u
#define KIND_TEXTURE 1u
#define KIND_SDF     2u
#define KIND_QUAD    3u
#define KIND_TEXT    4u

float rect_sdf(vec2 pos, vec2 half_size, float r) {
    vec2 q = abs(pos) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 evaluate_bezier(vec2 p0, vec2 p1, vec2 p2, float t) {
    vec2 a = mix(p0, p1, t);
    vec2 b = mix(p1, p2, t);
    return mix(a, b, t);
}

float intersect_monotonic(float qa, float c0, float c1, float c2, float target) {
    if (abs(qa) < 1e-6) {
        return (target - c0) / (c2 - c0);
    }
    float qb = fma(2.0, c1, -2.0 * c0);
    float qc = c0 - target;
    float d = fma(qb, qb, -4.0 * qa * qc);
    float sqrt_d = d < 0.0 ? 0.0 : sqrt(d);
    float inv_2a = 0.5 / qa;
    return fma(-qb, inv_2a, sign(c2 - c0) * sqrt_d * inv_2a);
}

float scanline_sweep(vec2 size, vec2 offset, vec2 p0, vec2 p1, vec2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y) {
        return 0.0;
    }

    vec2 delta = p2 - p0;

    p0 -= offset;
    p1 -= offset;
    p2 -= offset;

    float qa = fma(-2.0, p1.y, p0.y + p2.y);
    float bt = intersect_monotonic(qa, p0.y, p1.y, p2.y, 0.0);
    float tt = intersect_monotonic(qa, p0.y, p1.y, p2.y, size.y);

    float v_min_t = delta.y > 0.0 ? bt : tt;
    float v_max_t = delta.y > 0.0 ? tt : bt;

    vec2 v_min = evaluate_bezier(p0, p1, p2, clamp(v_min_t, 0.0, 1.0));
    vec2 v_max = evaluate_bezier(p0, p1, p2, clamp(v_max_t, 0.0, 1.0));

    if (max(v_min.x, v_max.x) <= 0.0) {
        return (v_max.y - v_min.y) * size.x;
    }

    if (min(v_min.x, v_max.x) >= size.x) {
        return 0.0;
    }

    qa = fma(-2.0, p1.x, p0.x + p2.x);

    float h_min_t;
    float h_max_t;

    vec4 h_check = delta.x > 0.0 ? vec4(p0.x, p2.x, 0.0, 0.0) : vec4(p2.x, p0.x, size.x, 1.0);

    if (h_check.x >= h_check.z) {
        h_min_t = h_check.w;
    } else if (h_check.y <= h_check.z) {
        h_min_t = 1.0 - h_check.w;
    } else {
        h_min_t = intersect_monotonic(qa, p0.x, p1.x, p2.x, h_check.z);
    }

    h_check.z = size.x - h_check.z;

    if (h_check.x >= h_check.z) {
        h_max_t = h_check.w;
    } else if (h_check.y <= h_check.z) {
        h_max_t = 1.0 - h_check.w;
    } else {
        h_max_t = intersect_monotonic(qa, p0.x, p1.x, p2.x, h_check.z);
    }

    float min_t = clamp(max(v_min_t, h_min_t), 0.0, 1.0);
    float max_t = clamp(min(v_max_t, h_max_t), 0.0, 1.0);

    vec2 q0 = v_min_t >= h_min_t ? v_min : evaluate_bezier(p0, p1, p2, min_t);
    vec2 q1 = v_max_t <= h_max_t ? v_max : evaluate_bezier(p0, p1, p2, max_t);

    float coverage = 0.0;

    if (min_t > 0.0 && delta.x > 0.0) {
        float h = delta.y > 0.0 ? q0.y - max(0.0, p0.y) : min(size.y, p0.y) - q0.y;
        coverage = sign(delta.y) * h * size.x;
    }

    if (max_t < 1.0 && delta.x < 0.0) {
        float h = delta.y > 0.0 ? min(size.y, p2.y) - q1.y : q1.y - max(0.0, p2.y);
        coverage += sign(delta.y) * h * size.x;
    }

    float h = q1.y - q0.y;
    float b = fma(-0.5, q0.x + q1.x, size.x);
    coverage += b * h;

    return coverage;
}

void main() {
    float alpha = 1.0;
    vec4 tex_color = vec4(1.0);

    if (in_kind == KIND_TEXTURE || in_kind == KIND_SDF) {
        tex_color = texture(textures[nonuniformEXT(in_index)], in_uv);
    }

    if (in_kind == KIND_SDF) {
        float sd = tex_color.r - 0.5;
        float afwidth = length(vec2(dFdx(sd), dFdy(sd)));
        if (afwidth < 1e-5) afwidth = 1e-5;
        float opacity = clamp(sd / afwidth + 0.5, 0.0, 1.0);

        tex_color = vec4(1.0, 1.0, 1.0, opacity);
    }

    if (in_kind == KIND_RECT || in_kind == KIND_TEXTURE) {
        float safe_radius = min(in_radius, min(in_half_size.x, in_half_size.y));
        float dist = rect_sdf(in_sdf_pos, in_half_size, safe_radius);
        float feather = fwidth(dist) * 0.5;
        alpha = 1.0 - smoothstep(-feather, feather, dist);
    } else if (in_kind == KIND_QUAD) {
        float edge_dist = min(in_uv.y, 1.0 - in_uv.y);
        float aa_width = fwidth(in_uv.y);
        alpha *= smoothstep(0.0, aa_width * 1.5, edge_dist);
    }

    #define NUM_STRIPES 8u

    if (in_kind == KIND_TEXT) {
        vec2 pixel_size = fwidth(in_uv);
        vec2 pixel_offset = in_uv - 0.5 * pixel_size;

        float clamped_y = clamp(in_uv.y, 0.0, 0.9999);
        uint stripe_idx = uint(clamped_y * float(NUM_STRIPES));
        stripe_idx = min(stripe_idx, NUM_STRIPES - 1u);

        Stripe s = stripes[in_index + stripe_idx];

        float total_coverage = 0.0;
        float max_y = pixel_offset.y + pixel_size.y;
        for (uint i = 0u; i < s.curve_count; i++) {
            Curve c = curves[s.curve_start + i];
            total_coverage += scanline_sweep(pixel_size, pixel_offset, vec2(c.p0), vec2(c.p1), vec2(c.p2));
        }

        float area = pixel_size.x * pixel_size.y;
        alpha = clamp(abs(total_coverage) / area, 0.0, 1.0);
    }

    out_color = in_color * tex_color;
    out_color.a *= alpha;
}

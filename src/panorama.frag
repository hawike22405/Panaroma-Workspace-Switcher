#version 440

// Panorama carousel: the camera sits inside a ring of workspace cards.
// Every pixel casts a ray, hits the (bendable) strip analytically, and samples
// the card under it. kappa = 0 is a flat, pixel-exact picture of one card, so
// the effect starts and ends seamlessly over the real desktop.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 resolution;
    vec4 backdrop;
    vec4 placeholder;
    float scroll;     // camera position along the strip, in px
    float kappa;      // strip curvature (1 / radius); 0 = flat
    float dist;       // distance to the strip's front point
    float zoom;       // 1 = card is 1:1, <1 pulls the camera back
    float cardW;
    float cardH;
    float pitch;      // card spacing along the strip
    float count;      // number of cards in the ring
    float radius;     // card corner radius
    float depthFade;
} ubuf;

layout(binding = 1) uniform sampler2D src0;
layout(binding = 2) uniform sampler2D src1;
layout(binding = 3) uniform sampler2D src2;
layout(binding = 4) uniform sampler2D src3;
layout(binding = 5) uniform sampler2D src4;
layout(binding = 6) uniform sampler2D src5;
layout(binding = 7) uniform sampler2D src6;
layout(binding = 8) uniform sampler2D src7;
layout(binding = 9) uniform sampler2D src8;
layout(binding = 10) uniform sampler2D src9;

vec4 pick(int i, vec2 uv) {
    if (i == 0) return texture(src0, uv);
    if (i == 1) return texture(src1, uv);
    if (i == 2) return texture(src2, uv);
    if (i == 3) return texture(src3, uv);
    if (i == 4) return texture(src4, uv);
    if (i == 5) return texture(src5, uv);
    if (i == 6) return texture(src6, uv);
    if (i == 7) return texture(src7, uv);
    if (i == 8) return texture(src8, uv);
    return texture(src9, uv);
}

void main() {
    vec2 px = qt_TexCoord0 * ubuf.resolution - 0.5 * ubuf.resolution;
    float D = max(ubuf.dist, 0.001);
    float f = max(D * ubuf.zoom, 0.001);
    float dx = px.x / f;
    float dy = px.y / f;
    float k = ubuf.kappa;

    // Ray (dx, 1) from the camera vs. the concave circle of radius 1/k whose
    // nearest point is at depth D. Numerically stable down to k = 0.
    float a = k * (1.0 + dx * dx);
    float b = 2.0 * (1.0 - k * D);
    float c = -D * (2.0 - k * D);
    float disc = max(b * b - 4.0 * a * c, 0.0);
    float t = -2.0 * c / max(b + sqrt(disc), 0.000001);

    float Px = t * dx;
    float Py = t * dy;

    float ang = 0.0;
    float s = Px;
    if (k > 0.00001) {
        ang = atan(k * Px, 1.0 + k * (t - D));
        s = ang / k;
    }

    float us = s + ubuf.scroll;
    float idx = floor(us / max(ubuf.pitch, 1.0) + 0.5);
    float lx = us - idx * ubuf.pitch;

    vec2 hs = vec2(ubuf.cardW, ubuf.cardH) * 0.5 + vec2(1.0);
    float r = min(ubuf.radius, min(hs.x, hs.y));
    vec2 qd = abs(vec2(lx, Py)) - hs + vec2(r);
    float d = length(max(qd, vec2(0.0))) + min(max(qd.x, qd.y), 0.0) - r;
    float aa = max(t / f, 0.5);
    float cover = 1.0 - smoothstep(-aa, aa, d);

    vec2 uv = clamp(vec2(lx / ubuf.cardW + 0.5, Py / ubuf.cardH + 0.5), 0.0, 1.0);
    int slot = int(floor(mod(idx, clamp(ubuf.count, 1.0, 10.0)) + 0.5));
    vec4 tex = pick(slot, uv);
    vec3 col = mix(ubuf.placeholder.rgb, tex.rgb, tex.a);

    float fade = ubuf.depthFade * pow(clamp((1.0 - cos(ang)) * 0.5, 0.0, 1.0), 1.25);
    col = mix(col, ubuf.backdrop.rgb, fade);

    vec3 outc = mix(ubuf.backdrop.rgb, col, cover);
    fragColor = vec4(outc, 1.0) * ubuf.qt_Opacity;
}

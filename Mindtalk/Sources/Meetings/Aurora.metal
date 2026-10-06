#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The room's light (VoiceScanner): a slow aurora, one glow per voice in its colour,
// brighter while someone speaks. Drawn on the GPU, so it costs the Mac nothing.

static float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * noise2(p); p *= 2.02; a *= 0.5; }
    return v;
}

/// `voices`: x, y (0…1 of the scene), glow (0…1) and r, g, b for each voice — the light
/// rises from where that voice sits, in its colour; `level`: how loud the room is (0…1).
[[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time, float level,
                              device const float *voices, int count) {
    float2 uv = position / size;
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y);

    // Warped twice, so the light flows rather than drifts.
    float2 q = float2(fbm(p * 1.6 + time * 0.05), fbm(p * 1.6 - time * 0.04 + 3.1));
    float2 r = float2(fbm(p * 1.3 + q * 1.8 + time * 0.03), fbm(p * 1.3 + q * 1.8 + 5.2 - time * 0.02));
    float2 warp = (r - 0.5) * 0.55;

    float3 col = float3(0.010, 0.012, 0.020);
    int n = count / 6;
    if (n == 0) {
        // No one yet: a faint cool light in the middle, breathing with the room.
        float d = length(p + warp - float2(aspect * 0.5, 0.48));
        col += float3(0.20, 0.42, 0.40) * exp(-d * d * 6.0) * (0.10 + 0.30 * level);
    }
    for (int i = 0; i < 8; i++) {
        if (i >= n) break;
        int k = i * 6;
        float2 home = float2(voices[k] * aspect, voices[k + 1]);
        float glow = voices[k + 2];
        float3 c = float3(voices[k + 3], voices[k + 4], voices[k + 5]);
        // Each light leans a little with the flow, never far from its voice.
        float2 drift = 0.05 * float2(sin(time * 0.21 + float(i) * 2.3), cos(time * 0.17 + float(i) * 1.9));
        float d = length(p + warp - home - drift);
        col += c * exp(-d * d * (9.0 - 3.0 * glow)) * (0.16 + 0.55 * glow);
        // A long, thin veil from each voice, like the curtain of an aurora.
        float veil = smoothstep(0.62, 0.95, fbm(float2(p.x * 2.4 + float(i) * 7.0, p.y * 0.7 - time * 0.06) + r * 1.6));
        col += c * veil * exp(-d * d * 2.2) * (0.05 + 0.18 * glow);
    }
    // Soft highlights; strong light saturates gently instead of clipping to white.
    col = 1.0 - exp(-col * 1.35);
    col *= smoothstep(1.25, 0.2, length(uv - 0.5) * 1.5);
    return half4(half3(col), 1.0);
}

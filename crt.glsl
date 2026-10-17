// ============================================================================
// CRT Emulation Shader
// ============================================================================

// ============================================================================
// FEATURE FLAGS
// ============================================================================

#define ENABLE_CURVATURE        // Curved screen distortion + corner stretch
#define ENABLE_BEAM             // Horizontal/vertical electron beam blur
#define ENABLE_MASK             // RGB phosphor mask (aperture grille or shadow mask)
#define LOCK_MASK_TO_PIXEL_GRID // Snap mask pitch to integer pixels for moire reduction
#define ENABLE_BLOOM            // Soft glow around bright areas
// #define ENABLE_NOISE            // Static-style grain (darkens content, lifts blacks)

// ============================================================================
// CONSTANTS & TWEAKABLE PARAMETERS
// ============================================================================

const float BRIGHTNESS_BOOST = 1.3;
const float EFFECTS_BRIGHTNESS_FLOOR = 0.1;

const float BARREL_DISTORTION = 0.03;
const float CORNER_STRETCH_X = 0.3;
const float CORNER_STRETCH_Y = 0.3;
const float CURVATURE_ZOOM = 1.0;

const int   MASK_TYPE      = 1;
const float MASK_CONTRAST  = 0.3;
const float MASK_STRIPE_PX = 2.0;

const float BLOOM_THRESHOLD    = 0.30;
const float BLOOM_SOFTNESS     = 0.10;
const float BLOOM_STRENGTH     = 0.10;
const float MAX_BLOOM_FRACTION = 0.9;

const float BEAM_STRENGTH       = 0.15;
const float BEAM_SPREAD_BASE    = 0.3;
const float BEAM_SPREAD_GAIN    = 0.5;
const float BEAM_VERT_SHARPNESS = 0.8;

const float NOISE_CONTENT_STRENGTH = 0.25; // [0,1] grain darkening on filled areas
const float NOISE_UNIFORM_STRENGTH = 0.25; // [0,1] grain added everywhere
const float NOISE_SPEED            = 0.001; // Seed drift rate (higher = faster-changing grain)

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

float luma(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

struct CRTParams {
    vec2 invRes;
    float aspect;
};

CRTParams setupParams() {
    CRTParams p;
    p.invRes = 1.0 / iResolution.xy;
    p.aspect = iResolution.x / iResolution.y;
    return p;
}

vec2 applyCurvature(vec2 uv, float aspect) {
    vec2 c = uv - 0.5;
    vec2 ca = vec2(c.x * aspect, c.y);
    float r2 = dot(ca, ca);

    vec2 warpedA = ca + ca * r2 * BARREL_DISTORTION;
    vec2 warped = vec2(warpedA.x / aspect, warpedA.y) + 0.5;

    vec2 a = abs(c);
    warped.x = 0.5 + (warped.x - 0.5) * (1.0 + CORNER_STRETCH_X * (a.y * a.y));
    warped.y = 0.5 + (warped.y - 0.5) * (1.0 + CORNER_STRETCH_Y * (a.x * a.x));

    return 0.5 + (warped - 0.5) * CURVATURE_ZOOM;
}

// ============================================================================
// MAIN SHADER
// ============================================================================

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // --- GLOBAL FEATURE CHECK (Zero-cost when effects are disabled) ---------
    #if !defined(ENABLE_CURVATURE) && !defined(ENABLE_BEAM) && \
        !defined(ENABLE_MASK) && !defined(ENABLE_BLOOM) && !defined(ENABLE_NOISE)
        fragColor = textureLod(iChannel0, fragCoord / iResolution.xy, 0.0);
        return;
    #endif

    // --- Setup --------------------------------------------------------------
    CRTParams params = setupParams();
    vec2 uv = fragCoord * params.invRes;
    vec2 curvedUV = uv;

    // --- Curvature ----------------------------------------------------------
#ifdef ENABLE_CURVATURE
    curvedUV = applyCurvature(uv, params.aspect);
#endif

    vec2 sampleUV = clamp(curvedUV, 0.0, 1.0);
    vec4 source_color = textureLod(iChannel0, sampleUV, 0.0);
    vec3 processed_color = source_color.rgb;

    // --- Electron Beam Blur -------------------------------------------------
#ifdef ENABLE_BEAM
    float beamLuma = luma(processed_color);
    float sX = max(0.25, BEAM_SPREAD_BASE + BEAM_SPREAD_GAIN * beamLuma);

    float invSx2 = 1.0 / (sX * sX);
    float w1 = exp(-0.5 * invSx2);
    float w2 = exp(-2.0 * invSx2);
    float normH = 1.0 / max(1e-4, (w1 * 2.0 + w2 * 2.0));

    vec2 dx = vec2(params.invRes.x, 0.0);
    vec2 dx2 = dx * 2.0;

    vec3 beamH = (
        textureLod(iChannel0, clamp(sampleUV + dx, 0.0, 1.0), 0.0).rgb +
        textureLod(iChannel0, clamp(sampleUV - dx, 0.0, 1.0), 0.0).rgb
    ) * w1 + (
        textureLod(iChannel0, clamp(sampleUV + dx2, 0.0, 1.0), 0.0).rgb +
        textureLod(iChannel0, clamp(sampleUV - dx2, 0.0, 1.0), 0.0).rgb
    ) * w2;
    beamH *= normH;

    vec2 dy = vec2(0.0, params.invRes.y * 0.5);
    float lv = 1.0 / (1.0 + 0.25 / (BEAM_VERT_SHARPNESS * BEAM_VERT_SHARPNESS));
    vec3 beamV = (
        textureLod(iChannel0, clamp(sampleUV + dy, 0.0, 1.0), 0.0).rgb +
        textureLod(iChannel0, clamp(sampleUV - dy, 0.0, 1.0), 0.0).rgb
    ) * (0.5 * lv);

    processed_color = mix(processed_color, beamH * 0.8 + beamV * 0.2, clamp(BEAM_STRENGTH, 0.0, 1.0));
#endif

    // --- Bloom --------------------------------------------------------------
#ifdef ENABLE_BLOOM
    float bloomLuma = luma(processed_color);
    float bloomMask = smoothstep(BLOOM_THRESHOLD - BLOOM_SOFTNESS, BLOOM_THRESHOLD + BLOOM_SOFTNESS, bloomLuma);
    if (bloomMask > 0.0) {
        vec3 glow = vec3(0.0);
        vec2 bx1 = vec2(params.invRes.x, 0.0);
        vec2 bx2 = bx1 * 2.0;
        vec2 bx3 = bx1 * 3.0;

        glow += (textureLod(iChannel0, clamp(sampleUV + bx1, 0.0, 1.0), 0.0).rgb +
                 textureLod(iChannel0, clamp(sampleUV - bx1, 0.0, 1.0), 0.0).rgb) * 0.194594;
        glow += (textureLod(iChannel0, clamp(sampleUV + bx2, 0.0, 1.0), 0.0).rgb +
                 textureLod(iChannel0, clamp(sampleUV - bx2, 0.0, 1.0), 0.0).rgb) * 0.121621;
        glow += (textureLod(iChannel0, clamp(sampleUV + bx3, 0.0, 1.0), 0.0).rgb +
                 textureLod(iChannel0, clamp(sampleUV - bx3, 0.0, 1.0), 0.0).rgb) * 0.054054;

        glow *= (BLOOM_STRENGTH * bloomMask);
        float glowL = luma(glow);
        float maxGlow = MAX_BLOOM_FRACTION * max(1e-4, bloomLuma);
        if (glowL > maxGlow) {
            glow *= maxGlow / (glowL + 1e-6);
        }
        processed_color += glow;
    }
#endif

    processed_color *= BRIGHTNESS_BOOST;
    float brightness = luma(processed_color);

    // --- Phosphor Mask ------------------------------------------------------
    vec3 mask_multiplier = vec3(1.0);
#ifdef ENABLE_MASK
    float stripePx = MASK_STRIPE_PX;
#ifdef LOCK_MASK_TO_PIXEL_GRID
    stripePx = max(1.0, floor(stripePx + 0.5));
#endif
    float maskFade = mix(1.0, 0.55, smoothstep(0.25, 0.85, brightness));

    if (MASK_TYPE == 1) {
        float pos = fract(fragCoord.x / (stripePx * 3.0)) * 3.0;
        float sigma = 0.38 * stripePx + fwidth(fragCoord.x) * 0.5;

        float invSig2 = -0.575 * (stripePx * stripePx) / (sigma * sigma);
        vec3 t = pos - vec3(0.5, 1.5, 2.5);
        vec3 phosphor = exp(t * t * invSig2);

        mask_multiplier = vec3(1.0 - MASK_CONTRAST) + phosphor * MASK_CONTRAST;

        float wirePeriod = iResolution.y * 0.333333;
        float wy = mod(fragCoord.y, wirePeriod);
        float wd = min(wy, wirePeriod - wy) / 1.3;
        mask_multiplier *= (1.0 - 0.14 * exp(-(wd * wd)));

    } else {
        float pitch = stripePx;
        float cellH = pitch * 1.7320508;
        float cellW = pitch * 3.0;

        float row = floor(fragCoord.y / cellH);
        float y = mod(fragCoord.y, cellH);
        float xShift = mod(row, 2.0) * 1.5 * pitch;
        vec2 p = vec2(mod(fragCoord.x + xShift, cellW), y);

        vec2 cR = vec2(0.75 * pitch, 0.288675 * cellH);
        vec2 cG = vec2(2.25 * pitch, 0.288675 * cellH);
        vec2 cB = vec2(1.5  * pitch, 0.866025 * cellH);

        float sigma = 0.35 * pitch + fwidth(fragCoord.x);
        float invSig2 = -0.5 / (sigma * sigma);

        vec2 dR = p - cR, dG = p - cG, dB = p - cB;
        vec3 phosphor = exp(vec3(dot(dR, dR), dot(dG, dG), dot(dB, dB)) * invSig2);

        mask_multiplier = vec3(1.0 - MASK_CONTRAST) + phosphor * MASK_CONTRAST;
    }
    mask_multiplier = mix(vec3(1.0), mask_multiplier, maskFade);
#endif

    // --- Combine & Clamp ----------------------------------------------------
    vec3 final_color = processed_color * mask_multiplier;
    final_color = max(final_color, processed_color * EFFECTS_BRIGHTNESS_FLOOR);

    // --- Color Grading ------------------------------------------------------
    final_color *= vec3(0.98, 0.99, 1.01);
    float final_luma = luma(final_color);
    final_color = mix(final_color, vec3(final_luma), 0.05);

    // --- Noise --------------------------------------------------------------
#ifdef ENABLE_NOISE
    float n = hash21(fragCoord + fract(iTime * NOISE_SPEED) * 1000.0);
    n = smoothstep(0.4, 0.6, n);

    final_color *= min(n + (1.0 - NOISE_CONTENT_STRENGTH), 1.0);
    final_color += n * (NOISE_UNIFORM_STRENGTH * 0.01);
#endif

    fragColor = vec4(clamp(final_color, 0.0, 1.0), source_color.a);
}

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

namespace {
// Те же базисы и tan-развёртка, что в CubeSphere/PlanetSurface. Координаты
// привязаны к телу: не плывут при смене LOD, вращении и переносе floating origin.
float3 surfaceDirection(float2 uv, float faceSize, float gutter) {
    float tile = faceSize + 2.0f * gutter;
    float2 pixel = float2(uv.x * 3.0f, (1.0f - uv.y) * 2.0f) * tile;
    int2 cell = clamp(int2(floor(pixel / tile)), int2(0), int2(2, 1));
    float2 ab = (pixel - float2(cell) * tile - gutter) / faceSize * 2.0f - 1.0f;
    ab.y = -ab.y;
    float2 q = tan(ab * (M_PI_F / 4.0f));
    switch (cell.y * 3 + cell.x) {
        case 0: return normalize(float3( 1, q.x, q.y));
        case 1: return normalize(float3(-1, q.y, q.x));
        case 2: return normalize(float3(q.y,  1, q.x));
        case 3: return normalize(float3(q.x, -1, q.y));
        case 4: return normalize(float3(q.x, q.y,  1));
        default:return normalize(float3(q.y, q.x, -1));
    }
}

float hashCell(int3 cell) {
    uint3 p = uint3(cell);
    uint h = p.x * 1597334677u ^ p.y * 3812015801u ^ p.z * 2798796415u;
    h = (h ^ (h >> 16)) * 2246822519u;
    h = (h ^ (h >> 13)) * 3266489917u;
    h ^= h >> 16;
    return float(h >> 8) * (2.0f / 16777215.0f) - 1.0f;
}

// Значение + аналитический градиент: для normal mapping не нужны повторные
// выборки шума или дополнительные текстуры. Производная равна нулю на границах ячеек.
float4 noiseGradient(float3 p) {
    int3 cell = int3(floor(p));
    float3 f = fract(p);
    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float3 du = 30.0f * f * f * (f - 1.0f) * (f - 1.0f);
    float a = hashCell(cell), b = hashCell(cell + int3(1, 0, 0));
    float c = hashCell(cell + int3(0, 1, 0)), d = hashCell(cell + int3(1, 1, 0));
    float e = hashCell(cell + int3(0, 0, 1)), f1 = hashCell(cell + int3(1, 0, 1));
    float g = hashCell(cell + int3(0, 1, 1)), h = hashCell(cell + int3(1, 1, 1));
    float x0 = mix(a, b, u.x), x1 = mix(c, d, u.x);
    float x2 = mix(e, f1, u.x), x3 = mix(g, h, u.x);
    float y0 = mix(x0, x1, u.y), y1 = mix(x2, x3, u.y);
    float3 gradient = float3(
        mix(mix(b-a, d-c, u.y), mix(f1-e, h-g, u.y), u.z) * du.x,
        mix(x1-x0, x3-x2, u.z) * du.y,
        (y1-y0) * du.z);
    return float4(gradient, mix(y0, y1, u.z));
}

float4 detailBand(float3 p, float wavelength, float footprint) {
    float fade = 1.0f - smoothstep(0.25f * wavelength, wavelength, footprint);
    if (fade <= 0.0f) return float4(0);
    float4 n = noiseGradient(p / wavelength);
    return float4(n.xyz / wavelength, n.w) * fade;
}
}

[[visible]]
void terrainSurface(realitykit::surface_parameters params) {
    float2 uv = params.geometry().uv0();
    constexpr sampler atlasSampler(address::clamp_to_edge, filter::linear, mip_filter::linear,
                                    max_anisotropy(8));
    float3 color = float3(params.textures().base_color().sample(atlasSampler, uv).rgb);
    float4 config = params.uniforms().custom_parameter();
    bool lunar = config.y > 0.5f;
    float3 direction = surfaceDirection(uv, config.z, config.w);
    float3 p = direction * config.x;
    // Экранный размер в физических метрах, включая масштаб карты/импосторов.
    // Все производные берутся до ветвления. Неразличимые детали исчезают без мерцания.
    float footprint = max(length(dfdx(p)), length(dfdy(p)));
    auto surface = params.surface();
    surface.set_metallic(0.0h);
    surface.set_specular(0.0h);
    surface.set_roughness(lunar ? 1.0h : 0.93h);
    if (footprint >= 256.0f) {
        surface.set_base_color(half3(color));
        return;
    }

    float4 broad = detailBand(p + float3(81, 12, 37), 256.0f, footprint);
    float4 stone = detailBand(p + float3(17, 91, 53), 32.0f, footprint);
    float4 gravel = detailBand(p + float3(23, 47, 11), 4.0f, footprint);
    float4 grain = detailBand(p, 0.8f, footprint);
    float3 gradient;
    float gain;
    // Море определяется цветом исходного атласа; ледяной океан остаётся матовым.
    bool water = !lunar && color.b > color.r * 1.35f && color.b > color.g * 1.08f;
    if (water) {
        gain = 1.0f + 0.025f * stone.w + 0.015f * gravel.w;
        gradient = 0.05f * gravel.xyz;
        surface.set_roughness(0.78h);
    } else if (lunar) {
        // Мелкая крошка, пылевой слой и неглубокие ямки с более светлой кромкой.
        float pit = smoothstep(0.34f, 0.72f, gravel.w);
        float rim = smoothstep(0.18f, 0.34f, gravel.w) * (1.0f - pit);
        gain = 1.0f + 0.13f * broad.w + 0.20f * stone.w + 0.13f * gravel.w
                        + 0.10f * grain.w - 0.18f * pit + 0.06f * rim;
        gradient = 1.6f * stone.xyz + 0.48f * gravel.xyz + 0.09f * grain.xyz;
    } else {
        // Не перекрашиваем биомы: зелёные участки получают зерно растительности,
        // скалы — более контрастные прожилки, снег — мягкую мелкую фактуру.
        float green = smoothstep(0.02f, 0.16f, color.g - max(color.r, color.b));
        float snow = smoothstep(0.5f, 0.85f, min(color.r, min(color.g, color.b)));
        float rock = (1.0f - green) * (1.0f - snow);
        float vein = 1.0f - smoothstep(0.015f, 0.11f, abs(stone.w));
        float veinFade = 1.0f - smoothstep(1.0f, 6.0f, footprint);
        gain = 1.0f + 0.12f * broad.w + 0.14f * stone.w + 0.13f * gravel.w
                        + 0.08f * grain.w - 0.09f * rock * vein * veinFade;
        gain = mix(gain, 1.0f + 0.045f * gravel.w + 0.04f * grain.w, snow);
        gradient = (1.2f + rock) * stone.xyz + (0.3f + 0.25f * rock) * gravel.xyz
                        + 0.07f * grain.xyz;
        gradient *= 1.0f - 0.65f * snow;
    }
    surface.set_base_color(half3(clamp(color * gain, 0.0f, 1.0f)));

    // Геометрические нормали/касательные патча находятся в связанной с телом
    // системе. Проекция 3D-градиента в TBN сохраняет швы кубосферы и наклон гор.
    float3 tangent = params.geometry().tangent();
    float3 bitangent = params.geometry().bitangent();
    if (dot(tangent, tangent) > 0.01f && dot(bitangent, bitangent) > 0.01f) {
        float2 bump = float2(dot(gradient, normalize(tangent)), dot(gradient, normalize(bitangent)));
        surface.set_normal(normalize(float3(-bump, 1.0f)));
    }
}

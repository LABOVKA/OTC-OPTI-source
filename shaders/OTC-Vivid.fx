#include "ReShade.fxh"

uniform float Saturation
<
    ui_type = "slider";
    ui_label = "Saturation";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 1.35;

uniform float Vibrance
<
    ui_type = "slider";
    ui_label = "Selective vibrance";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.35;

uniform float Hue
<
    ui_type = "slider";
    ui_label = "Hue rotation";
    ui_min = -180.0;
    ui_max = 180.0;
    ui_step = 1.0;
> = 0.0;

uniform float Contrast
<
    ui_type = "slider";
    ui_label = "Contrast";
    ui_min = 0.75;
    ui_max = 1.35;
    ui_step = 0.01;
> = 1.05;

uniform float Strength
<
    ui_type = "slider";
    ui_label = "Effect strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 1.0;

float3 RGBToYIQ(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.299, 0.587, 0.114)),
        dot(rgb, float3(0.596, -0.274, -0.322)),
        dot(rgb, float3(0.211, -0.523, 0.312)));
}

float3 YIQToRGB(float3 yiq)
{
    return float3(
        yiq.x + 0.956 * yiq.y + 0.621 * yiq.z,
        yiq.x - 0.272 * yiq.y - 0.647 * yiq.z,
        yiq.x - 1.106 * yiq.y + 1.703 * yiq.z);
}

float4 OTCVividPS(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 source = tex2D(ReShade::BackBuffer, texcoord);
    float3 yiq = RGBToYIQ(source.rgb);

    float angle = radians(Hue);
    float sine = sin(angle);
    float cosine = cos(angle);
    float rotatedI = yiq.y * cosine - yiq.z * sine;
    float rotatedQ = yiq.y * sine + yiq.z * cosine;
    yiq.y = rotatedI;
    yiq.z = rotatedQ;

    float chroma = length(yiq.yz);
    float selectiveBoost = 1.0 + Vibrance * saturate(1.0 - chroma);
    yiq.yz *= Saturation * selectiveBoost;

    float3 adjusted = YIQToRGB(yiq);
    adjusted = (adjusted - 0.5) * Contrast + 0.5;
    float3 result = lerp(source.rgb, saturate(adjusted), Strength);
    return float4(result, source.a);
}

technique OTCVivid
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = OTCVividPS;
    }
}

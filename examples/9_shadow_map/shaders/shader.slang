
import "../../shared.slang";

struct VertexData
{
    float4* positions;
    float4* normals;
    float4x4 model_to_world;
    float4x4 model_to_world_normal;
    float4x4 world_to_view;
    float4x4 world_to_light;
    float4x4 view_to_proj;
}

struct VertexOutput
{
    float4 pos : SV_Position;
    float4 color : TEXCOORD0;
    float4 light_pos : TEXCOORD1;
}

[shader("vertex")]
VertexOutput vertexMain(uint vert_id : SV_VertexID, GraphicsPipelineData<VertexData> data)
{
    float4 model_pos = float4(data.vert.positions[vert_id].xyz, 1.0);
    float4 world_pos = mul(data.vert.model_to_world, model_pos);
    float4 light_pos = mul(data.vert.world_to_light, world_pos);
    float4 view_pos = mul(data.vert.world_to_view, world_pos);
    float4 clip_pos = mul(data.vert.view_to_proj, view_pos);
    clip_pos.y = -clip_pos.y;
    light_pos.y = -light_pos.y;

    float4 world_normal = mul(data.vert.model_to_world_normal, data.vert.normals[vert_id]);

    VertexOutput vert_out;
    vert_out.pos = clip_pos;
    vert_out.color = world_normal;
    vert_out.light_pos = light_pos;
    return vert_out;
}

struct FragmentData {
    uint shadow_texture;
    uint shadow_sampler;
    float3 light_dir;
}

[shader("fragment")]
float4 fragmentMain(float4 normal_vert: TEXCOORD0, float4 input_light_pos: TEXCOORD1, GraphicsPipelineData<void, FragmentData> data) : SV_Target
{
    float3 light_pos = input_light_pos.xyz / input_light_pos.w;
    float3 normal = normalize(normal_vert.xyz);
    float factor = dot(normal, normalize(data.frag.light_dir));
    factor = max(0, factor);

    light_pos.xy = light_pos.xy * 0.5 + 0.5;
    light_pos.z -= 0.0000005;
    
    // This is the important line: Shadow maps are sampled with getCompareSampler to use PCF
    float light = getTexture2D(data.frag.shadow_texture).SampleCmp(getCompareSampler(data.frag.shadow_sampler), light_pos.xy, light_pos.z);
    if (light_pos.x < 0 || light_pos.y < 0 || light_pos.x > 1 || light_pos.y > 1 || light_pos.z < 0.0)
    {
        light = 0.0;
    }
    light = max(light, 0.2);
    float3 sun_colour = float3(0.9, 0.8, 0.7);
    float3 ambient_colour = float3(0.5, 0.7, 0.9);
    return float4(
        (0.1 + factor * 0.1) * ambient_colour
        + sun_colour * factor * light * 0.8,
        1.0);
}

[shader("fragment")]
void shadowFragmentMain() : SV_Target
{
}

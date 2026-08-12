
import "../../shared.slang";

struct VertexData
{
    float4* positions;
    float4* normals;
    float4x4 model_to_world;
    float4x4 model_to_world_normal;
    float4x4 world_to_view;
    float4x4 view_to_proj;
}

struct VertexOutput
{
    float4 pos : SV_Position;
    float4 color : TEXCOORD0;
}

[shader("vertex")]
VertexOutput vertexMain(uint vert_id : SV_VertexID, GraphicsPipelineData<VertexData> data)
{
    float4 clip_pos = float4(data.vert.positions[vert_id].xyz, 1.0);
    clip_pos = mul(data.vert.model_to_world, clip_pos);
    clip_pos = mul(data.vert.world_to_view, clip_pos);
    clip_pos = mul(data.vert.view_to_proj, clip_pos);
    clip_pos.y = -clip_pos.y;

    float4 world_normal = mul(data.vert.model_to_world_normal, data.vert.normals[vert_id]);

    VertexOutput vert_out;
    vert_out.pos = clip_pos;
    vert_out.color = world_normal;
    return vert_out;
}

[shader("fragment")]
float4 fragmentMain(float4 normal_vert : TEXCOORD0) : SV_Target
{
    float3 normal = normalize(normal_vert.xyz);
    return float4(normal * 0.5 + 0.5, 1.0);
}

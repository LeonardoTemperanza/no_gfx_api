
#version 460

#extension GL_EXT_buffer_reference : require

layout(location = 0) out vec4 out_color;

struct Vertex
{
    vec3 pos;
};

layout(buffer_reference, std140) readonly buffer _res_slice_Vertex
{
    Vertex _res_[];
};

struct Data
{
    _res_slice_Vertex verts;
};

layout(buffer_reference, std140) readonly buffer _res_ptr_Data
{
    Data _res_;
};

layout(push_constant, std140) uniform Push
{
    _res_ptr_Data data;
    _res_ptr_Data frag_data;
};

void main()
{
    uint id = gl_VertexIndex;

    vec2 verts[] = {
        vec2(-0.5, -0.5),
        vec2( 0.0,  0.5),
        vec2( 0.5, -0.5),
    };

    out_color = vec4(1.0f, 0.0f, 0.0f, 1.0f);
    // gl_Position = vec4(data._res_.verts._res_[id].pos, 0.0f);
    gl_Position = vec4(verts[id], 0.0f, 0.0f);
}

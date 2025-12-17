
#version 460

#extension GL_EXT_buffer_reference : require

layout(location = 0) out vec4 out_color;

layout(buffer_reference, std140) readonly buffer Verts
{
    vec3 pos;
};

layout(buffer_reference, std140) readonly buffer Data
{
    Verts verts;
};

layout(push_constant, std140) uniform Push
{
    Data data;
};

void main()
{
    uint id = gl_VertexIndex;
    gl_Position = vec4(data.verts.pos, 0.0f);
}

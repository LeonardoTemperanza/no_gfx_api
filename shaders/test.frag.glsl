
#version 460

#extension GL_EXT_buffer_reference : require

layout(location = 0) out vec4 out_color;

layout(buffer_reference, std140) readonly buffer Ptr
{
    vec4 tris[3];
};

layout(push_constant, std140) uniform Push
{
    Ptr ptr;
};

void main()
{
    out_color = vec4(0.0f);
}

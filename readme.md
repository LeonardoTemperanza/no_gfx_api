# no_gfx: A Low-Level API for Sane Graphics Programming

**Warning:** This project is still in development, so expect some breaking changes.

It isn't controversial to say this: graphics APIs are a mess. "Modern" graphics APIs – which are a decade old at this point – all present numerous concepts that are completely useless on today's hardware. They are extremely bloated, often adding new extensions to cover for past missteps in the design. It can all be massively simplified.

**no_gfx**'s goal is to implement an ideal "API of the future" on top of Vulkan, greatly simplifying graphics programming without sacrificing modern features like indirect rendering and raytracing. It initially started as a 1:1 recreation of the theoretical API outlined in Sebastian Aaltonen's ["No Graphics API"](https://www.sebastianaaltonen.com/blog/no-graphics-api) blog post; there are now a few divergences – partly due to the limitations of current APIs – but the overall design and core philosophy is still the same.

## API Usage

Third-party binaries are already included, so it's sufficient to copy the `gpu` directory and add `import "gpu"` to your files.

The API is straightforward to use:

```odin
// --- Initialization
ok := gpu.init()
ensure(ok)
defer gpu.cleanup()
gpu.swapchain_init(/* surface */, Frames_In_Flight)

// --- Create shaders
vert_shader := gpu.shader_create(/* spirv_binary */, .Vertex)
frag_shader := gpu.shader_create(/* spirv_binary */, .Fragment)
defer {
    gpu.shader_destroy(vert_shader)
    gpu.shader_destroy(frag_shader)
}

// --- Create arenas and allocate memory
arena := gpu.arena_create()
defer gpu.arena_destroy(&arena)

verts := gpu.arena_alloc(&arena, Vertex, 3)
// verts.cpu[0].pos = ...

indices := gpu.arena_alloc(&arena, u32, 3)
// indices.cpu[0] = ...

verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)
defer {
    gpu.mem_free(verts_local)
    gpu.mem_free(indices_local)
}

// --- Issue copy commands to GPU local memory
upload_cmd_buf := gpu.commands_begin(.Main)
gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
// ...
gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
gpu.queue_submit(.Main, { upload_cmd_buf })

// --- Frame resources
frame_arenas: [Frames_In_Flight]gpu.Arena
for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
defer {
    for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
}
next_frame := u64(1)
frame_sem := gpu.semaphore_create(0)
defer gpu.semaphore_destroy(frame_sem)
for true
{
    proceed := handle_window_events(window)
    if !proceed do break

    if next_frame > Frames_In_Flight {
        gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
    }
    swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

    frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
    gpu.arena_free_all(frame_arena)

    // --- Render frame

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = swapchain, clear_color = { 1.0, 0.0, 0.0, 1.0 } }
            // Other optional settings...
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    Vert_Data :: struct {
        verts: rawptr,
        // Uniforms...
    }
    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
    verts_data.cpu.verts = verts_local.gpu.ptr

    // Just pass pointers to your data!
    gpu.cmd_draw_indexed(cmd_buf, verts_data, {}, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf }, frame_sem, next_frame)

    gpu.swapchain_present(.Main, frame_sem, next_frame)
    next_frame += 1
}

gpu.wait_idle()  // Wait until the end of execution for resource destruction
```

There are many examples you can find in the `examples` directory.

## Disadvantages

Like most things in life, this is not without its tradeoffs:

1. It assumes relatively recent hardware. It requires Vulkan 1.3 with the VK_EXT_shader_object extension. It can use more extensions for optional features such as raytracing.
2. Shader arguments are all passed via a single pointer. This is very flexible and easy to work with, but it can also prevent some prefetching/optimizations that drivers usually implement with standard bindings and vertex buffers. This will probably make shaders in general slightly slower. How much impact this will have, I can't say for sure right now. On the other hand, working with a nicer and better API can make optimization easier and quicker.
3. It currently only targets Vulkan, so it's not fully cross-platform. Mac support is best-effort, through MoltenVK/KosmicKrisp only. Developing on Mac is probably doable, but if shipping to Mac is desired I'd consider the option of writing a separate Metal backend for your application.

## Shaders

I think people should be able to use whichever shading language they want, but there are a few limitations due to the nature of this project. **no_gfx** uses pointers as the main way to pass data to shaders, so shading languages that don't support pointers at all are sadly disqualified – this includes HLSL. Other than that, any shading language can be used as long as a `.spirv` binary is produced with the following format (pseudocode, GLSL-like):

```glsl
layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 0) uniform image2D textures_rw[];
layout(set = 2, binding = 0) uniform sampler samplers[];
layout(set = 3, binding = 0) uniform accelerationStructureEXT bvhs[];  // Optional, for raytracing.

// For vertex and fragment shaders:
layout(push_constant) uniform Push
{
    void* vert_data;
    void* frag_data;
    void* indirect_data;
};

// For compute shaders:
layout(push_constant) uniform Push
{
    void* compute_data
};
```

All examples provide [Slang](https://shader-slang.org/) variants of their shaders so you can get an idea of how to use an existing shading language with **no_gfx**.

With that said – much like graphics APIs, shading languages also carry a lot of historical baggage and cruft. For this reason, I think it's valuable to work on a shading language that is tailor-made to these assumptions and that doesn't require any boilerplate. Here's a small sample of `nosl`:

```jai
Vertex :: struct
{
    pos: vec3,
    color: vec3
}

Vert_Data :: struct
{
    verts: []Vertex,
}

Vert_Output :: struct
{
    pos: vec4 @position,
    color: vec4 @io(0),
}

vert :: #vertex (vert_id: uint @vert_id, data: ^Vert_Data @data) -> Vert_Output
{
    out: Vert_Output;
    out.pos = vec4(data.verts[vert_id].pos, 1.0);
    out.color = vec4(data.verts[vert_id].color, 1.0);
    return out;
}

frag :: #fragment (input: Vert_Output) -> vec4 @io(0)
{
    return input.color;
}
```

## Building

Importing **no_gfx** into your own project mostly just involves copying the `gpu/` directory, but to build this project you will need:

- [Odin >= 2026-03](https://odin-lang.org/)
- [Vulkan SDK](https://vulkan.lunarg.com/) (not required, but recommended for low-level Vulkan validation)

Binaries for dependencies are included.

- `odin run build`: builds all examples.
- `odin run build -- build_all_with_slang`: builds all examples using the Slang shaders.
- `odin run build -- compiler`: builds the NOSL compiler.
- `odin run build -- shaders_nosl`: produces SPIR-V for all NOSL shaders.
- `odin run build -- shaders_slang`: produces SPIR-V for all Slang shaders.

See [build.odin](build/build.odin) for all available commands.

## Related Projects
- [no_gfx OpenXR bindings](https://github.com/zeozeozeo/odin-openxr-sample) (by zeozeozeo)

Feel free to [contact me on discord](https://discord.com/users/leon2058) for any questions.


#+feature dynamic-literals

package main

import "core:image"
import "core:image/bmp"
import "core:log"
import "core:os"
import "core:fmt"
import "../examples/shared"
import "../examples/shared/gltf2"
import "core:math"
import "core:math/linalg"
import intr "base:intrinsics"
import "core:slice"
import "base:runtime"

import "../gpu"

Target_Size :: 1024

Test :: struct
{
    name: string,
    test_proc: proc(target: Render_Target),
    required_features: gpu.Features,
}

tests := []Test {
    { "triangle", test_triangle, {} },
    { "texture", test_texture, {} },
    { "texture_advanced", test_texture_advanced, {}},
    { "indirect", test_indirect, { .Draw_Indirect_Multi }},
    { "compute", test_compute, {}},
    { "comparison_sampler", test_comparison_sampler, {}},
    { "sw_pathtracing", test_sw_pathtracing, {}},  // Test a complex shader. Scene is hardcoded in the shader, HW RT is not used.
                                                   // This is useful because CPU implementations of Vulkan usually don't support HW RT.
    { "hw_pathtracing", test_hw_pathtracing, { .Raytracing }},
}

Operation_Mode :: enum
{
    Gen_Local_Goldens, // Will be put into "goldens_local" (in addition to "output")
    Compare_To_Local,  // Will compare with "goldens_local"
    Compare_To_Global, // Will compare with "goldens". This should only be done with the same CPU Vulkan implementation
                       // used to generate them in the first place.
}

main :: proc()
{
    cmd_args := os.args

    op_mode := Operation_Mode.Compare_To_Global
    is_gh_actions := false
    if len(cmd_args) > 1
    {
        for cmd_arg in cmd_args
        {
            if cmd_arg == "gen_local_goldens" {
                op_mode = .Gen_Local_Goldens
            } else if cmd_arg == "compare_to_local" {
                op_mode = .Compare_To_Local
            } else if cmd_arg == "compare_to_global" {
                op_mode = .Compare_To_Global
            } else if cmd_arg == "is_gh_actions" {
                is_gh_actions = true
            }
        }
    }

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    target := create_render_target()
    defer destroy_render_target(&target)

    program_return := 0
    for test, idx in tests
    {
        test_id := idx + 1

        // Clear render target
        {
            cmd_buf := gpu.commands_begin(.Main)
            gpu.cmd_begin_render_pass(cmd_buf, {
                color_attachments = {
                    { texture = target.color, clear_color = { 0, 0, 0, 1 } }
                }
            })
            gpu.cmd_end_render_pass(cmd_buf)
            gpu.queue_submit(.Main, { cmd_buf })
            gpu.wait_idle()
        }

        // NOTE: Lavapipe claims to support RT but segfaults, sooo.....
        if is_gh_actions && .Raytracing in test.required_features
        {
            fmt.printfln("Using CPU Vulkan Implementation and test requires HW RT. Skipping.")
            continue
        }

        if test.required_features & gpu.features_available() != test.required_features
        {
            fmt.printfln("Test %v_%v: the following features are not supported: %v. Skipping.",
                         test_id, test.name,
                         test.required_features - gpu.features_available())
            continue
        }

        test.test_proc(target)
        gpu.wait_idle()

        output_path := fmt.tprintf("tests/output/%v_%v.bmp", test_id, test.name)
        compare_path_local := fmt.tprintf("tests/goldens_local/%v_%v.bmp", test_id, test.name)
        compare_path_global := fmt.tprintf("tests/goldens/%v_%v.bmp", test_id, test.name)

        save_target_color(target, output_path)

        switch op_mode
        {
            case .Gen_Local_Goldens:
            {
                save_target_color(target, compare_path_local)
                fmt.printfln("Generated %v.", test.name)
            }
            case .Compare_To_Local:
            {
                matches := compare_to_golden(target, compare_path_local)
                if matches {
                    fmt.printfln("%v - Ok.", test.name)
                } else {
                    fmt.printfln("%v - Fail!", test.name)
                    program_return = 1
                }
            }
            case .Compare_To_Global:
            {
                matches := compare_to_golden(target, compare_path_global)
                if matches {
                    fmt.printfln("%v - Ok.", test.name)
                } else {
                    fmt.printfln("%v - Fail!", test.name)
                    program_return = 1
                }
            }
        }
        gpu.wait_idle()
    }

    if program_return != 0 do os.exit(1)
}

test_triangle :: proc(target: Render_Target)
{
    vert_shader := gpu.shader_create(#load("shaders/triangle.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/triangle.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    Vertex :: struct { pos: [3]f32, color: [3]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0 }
    verts.cpu[0].color = { 1.0, 0.0, 0.0 }
    verts.cpu[1].color = { 0.0, 1.0, 0.0 }
    verts.cpu[2].color = { 0.0, 0.0, 1.0 }

    indices := gpu.arena_alloc(&arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1

    verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(&arena, Vert_Data)
    verts_data.cpu^ = { verts = verts_local.gpu.ptr }

    gpu.cmd_draw_indexed(cmd_buf, verts_data, {}, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_texture :: proc(target: Render_Target)
{
    load_texture :: proc(bytes: []byte, upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
    {
        options := image.Options {
            .alpha_add_if_missing,
        }
        img, err := image.load_from_bytes(bytes, options)
        ensure(err == nil, "Could not load texture.")
        defer image.destroy(img)

        staging := gpu.arena_alloc_raw(upload_arena, u64(len(img.pixels.buf)), 1)
        runtime.mem_copy(staging.cpu, raw_data(img.pixels.buf), len(img.pixels.buf))

        texture := gpu.texture_alloc_and_create({
            dimensions = { u32(img.width), u32(img.height), 1 },
            format = .RGBA8_Unorm,
            usage = { .Sampled },
        })
        gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
        return texture
    }

    Mona_Lisa_Texture :: #load("assets/monalisa.jpg")

    vert_shader := gpu.shader_create(#load("shaders/sample_texture.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/sample_texture.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -0.5,  0.5 * 1.48, 0.0 }
    verts.cpu[1].pos = {  0.5, -0.5 * 1.48, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5 * 1.48, 0.0 }
    verts.cpu[3].pos = { -0.5, -0.5 * 1.48, 0.0 }
    verts.cpu[0].uv  = {  0.0,  1.0 }
    verts.cpu[1].uv  = {  1.0,  0.0 }
    verts.cpu[2].uv  = {  1.0,  1.0 }
    verts.cpu[3].uv  = {  0.0,  0.0 }

    indices := gpu.arena_alloc(&arena, u32, 6)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1
    indices.cpu[3] = 0
    indices.cpu[4] = 1
    indices.cpu[5] = 3

    verts_local := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    tex := load_texture(Mona_Lisa_Texture, &upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&tex)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})

    gpu.queue_submit(.Main, { upload_cmd_buf })

    tex_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(tex, {}))
    linear_sampler := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    frame_arena := &upload_arena

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0, 0, 0, 1 } }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
    verts_data.cpu.verts = verts_local.gpu.ptr
    Frag_Data :: struct {
        texture: u32,
        sampler: u32,
    }
    frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
    frag_data.cpu.texture = tex_id
    frag_data.cpu.sampler = linear_sampler

    gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_texture_advanced :: proc(target: Render_Target)
{
    shared.CAM_POS = {-1.3, -1.7, -1.3}
    shared.CAM_ANGLE = {math.PI * 0.25, math.PI * 0.25}

    build_sky_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> (gpu.slice_t([3]f32), gpu.slice_t(u32))
    {
        verts, indices := shared.build_sphere()
        defer {
            delete(verts)
            delete(indices)
        }

        verts_staging := gpu.arena_alloc(upload_arena, [3]f32, len(verts))
        indices_staging := gpu.arena_alloc(upload_arena, u32, len(indices))
        copy(verts_staging.cpu, verts[:])
        copy(indices_staging.cpu, indices[:])

        verts_local := gpu.mem_alloc([3]f32, len(verts))
        indices_local := gpu.mem_alloc(u32, len(indices))
        gpu.cmd_mem_copy(cmd_buf, verts_local, verts_staging)
        gpu.cmd_mem_copy(cmd_buf, indices_local, indices_staging)
        return verts_local, indices_local
    }

    build_cloud_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> (gpu.slice_t([3]f32), gpu.slice_t(u32))
    {
        verts := shared.UNIT_CUBE_VERTS[:]
        indices := shared.CUBE_INDICES[:]
        verts_staging := gpu.arena_alloc(upload_arena, [3]f32, len(verts))
        indices_staging := gpu.arena_alloc(upload_arena, u32, len(indices))
        copy(verts_staging.cpu, verts[:])
        copy(indices_staging.cpu, indices[:])

        verts_local := gpu.mem_alloc([3]f32, len(verts))
        indices_local := gpu.mem_alloc(u32, len(indices))
        gpu.cmd_mem_copy(cmd_buf, verts_local, verts_staging)
        gpu.cmd_mem_copy(cmd_buf, indices_local, indices_staging)
        return verts_local, indices_local
    }

    build_sky_cubemap :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
    {
        Sky_Textures: [gpu.Cubemap_Side][]u8 = {
            .PX = #load("assets/px.png"),
            .NX = #load("assets/nx.png"),
            .PY = #load("assets/py.png"),
            .NY = #load("assets/ny.png"),
            .PZ = #load("assets/pz.png"),
            .NZ = #load("assets/nz.png"),
        }
        texture: gpu.Owned_Texture

        for side in gpu.Cubemap_Side
        {
            options := image.Options {
                .alpha_add_if_missing,
            }
            img, err := image.load_from_bytes(Sky_Textures[side], options)
            ensure(err == nil, "Could not load texture.")
            defer image.destroy(img)

            if texture == {}
            {
                texture = gpu.texture_alloc_and_create({
                    type = .Cube,
                    dimensions = { u32(img.width), u32(img.height), 1 },
                    format = .RGBA8_Unorm,
                    usage = { .Sampled },
                    layer_count = 6,
                })
            }

            staging := gpu.arena_alloc(upload_arena, u8, len(img.pixels.buf))
            copy(staging.cpu, img.pixels.buf[:])
            gpu.cmd_copy_to_texture(cmd_buf, texture, staging, region = { base_layer = u32(side) })
        }
        return texture
    }

    generate_volume :: proc(size: int) -> [][4]u8
    {
        data := make([][4]u8, size*size*size)

        inv := 1.0 / f32(size - 1)

        for z in 0..<size
        {
            for y in 0..<size
            {
                for x in 0..<size
                {
                    idx := x + y*size + z*size*size
                    data[idx] = [4]u8 {
                        u8(f32(x) / f32(size) * f32(255)),
                        u8(f32(y) / f32(size) * f32(255)),
                        u8(f32(z) / f32(size) * f32(255)),
                        u8(math.trunc(f32(1.0) * f32(255.0))),
                    }
                }
            }
        }

        return data
    }

    build_3d_texture :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
    {
        volume_res :: 128
        texture := gpu.texture_alloc_and_create({
            type = .D3,
            dimensions = { volume_res, volume_res, volume_res },
            format = .RGBA8_Unorm,
            usage = { .Sampled },
        })

        volume := generate_volume(volume_res)

        staging := gpu.arena_alloc(upload_arena, [4]u8, len(volume))
        copy(staging.cpu, volume)
        gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
        return texture
    }

    sky_vert_shader := gpu.shader_create(#load("shaders/sky.vert.spv", []u32), .Vertex)
    sky_frag_shader := gpu.shader_create(#load("shaders/sky.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(sky_vert_shader)
        gpu.shader_destroy(sky_frag_shader)
    }

    volume_vert_shader := gpu.shader_create(#load("shaders/volume.vert.spv", []u32), .Vertex)
    volume_frag_shader := gpu.shader_create(#load("shaders/volume.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(volume_vert_shader)
        gpu.shader_destroy(volume_frag_shader)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    upload_cmd_buf := gpu.commands_begin(.Main)

    sky_cubemap := build_sky_cubemap(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&sky_cubemap)

    texture_3d := build_3d_texture(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&texture_3d)

    sky_verts, sky_indices := build_sky_mesh(&upload_arena, upload_cmd_buf)
    defer {
        gpu.mem_free(sky_verts)
        gpu.mem_free(sky_indices)
    }

    cloud_verts, cloud_indices := build_cloud_mesh(&upload_arena, upload_cmd_buf)
    defer {
        gpu.mem_free(cloud_verts)
        gpu.mem_free(cloud_indices)
    }

    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    sky_cubemap_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(sky_cubemap, {}))
    texture_3d_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(texture_3d, {}))
    linear_sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    frame_arena := &upload_arena

    world_to_view := shared.first_person_camera_view(0.0)
    aspect_ratio := f32(Target_Size) / f32(Target_Size)
    view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
        },
        depth_attachment = gpu.Render_Attachment {
            texture = target.depth, clear_color = 1.0
        },
    })

    gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

    // Draw skysphere
    {
        gpu.cmd_set_shaders(cmd_buf, sky_vert_shader, sky_frag_shader)
        gpu.cmd_set_depth_state(cmd_buf, { compare = .Always })
        // Render the skysphere inside out
        gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .Cull_CCW })

        Vert_Data :: struct #all_or_none {
            positions: rawptr,
            world_to_view: [16]f32,
            view_to_proj: [16]f32,
        }
        verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
        verts_data.cpu^ = {
            positions = sky_verts.gpu.ptr,
            world_to_view = intr.matrix_flatten(world_to_view),
            view_to_proj = intr.matrix_flatten(view_to_proj),
        }

        Frag_Data :: struct #all_or_none {
            sky_texture: u32,
            sky_sampler: u32,
        }
        frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
        frag_data.cpu^ = {
            sky_texture = sky_cubemap_id,
            sky_sampler = linear_sampler_id,
        }

        gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, sky_indices)
    }

    // Draw cloud
    {
        gpu.cmd_set_shaders(cmd_buf, volume_vert_shader, volume_frag_shader)
        gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })
        gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .Cull_CW })
        gpu.cmd_set_blend_state(cmd_buf, {
            enable = true,
            color_op = .Add,
            src_color_factor = .Src_Alpha,
            dst_color_factor = .One_Minus_Src_Alpha,
            alpha_op = .Add,
            src_alpha_factor = .One,
            dst_alpha_factor = .One_Minus_Src_Alpha,
            color_write_mask = gpu.Color_Components_All,
        })

        Vert_Data :: struct #all_or_none {
            positions: rawptr,
            model_to_world: [16]f32,
            world_to_view: [16]f32,
            view_to_proj: [16]f32,
        }
        verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
        verts_data.cpu^ = {
            positions = cloud_verts.gpu.ptr,
            model_to_world = intr.matrix_flatten(cast(matrix[4, 4]f32) 1),
            world_to_view = intr.matrix_flatten(world_to_view),
            view_to_proj = intr.matrix_flatten(view_to_proj),
        }

        Frag_Data :: struct #all_or_none {
            cloud_texture: u32,
            cloud_sampler: u32,
            camera_pos: [3]f32,
        }
        frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
        frag_data.cpu^ = {
            cloud_texture = texture_3d_id,
            cloud_sampler = linear_sampler_id,
            camera_pos = shared.CAM_POS
        }
        gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, cloud_indices)
    }

    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_indirect :: proc(target: Render_Target)
{
    Num_Triangles :: 32

    hsl_to_rgb :: proc(h: f32, s: f32, l: f32) -> linalg.Vector3f32
    {
        c := (1.0 - abs(2.0 * l - 1.0)) * s
        x := c * (1.0 - abs(math.mod(h * 6.0, 2.0) - 1.0))
        m := l - c / 2.0

        r, g, b: f32

        if h < 1.0/6.0 {
            r, g, b = c, x, 0.0
        } else if h < 2.0/6.0 {
            r, g, b = x, c, 0.0
        } else if h < 3.0/6.0 {
            r, g, b = 0.0, c, x
        } else if h < 4.0/6.0 {
            r, g, b = 0.0, x, c
        } else if h < 5.0/6.0 {
            r, g, b = x, 0.0, c
        } else {
            r, g, b = c, 0.0, x
        }

        return { r + m, g + m, b + m }
    }

    vert_shader := gpu.shader_create(#load("shaders/indirect_triangles.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/indirect_triangles.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    Vertex :: struct { pos: [3]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0 }

    indices := gpu.arena_alloc(&arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1

    verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)

    // Unified indirect data struct that extends Draw_Indexed_Indirect_Command
    Indirect_Data :: struct {
        using cmd: gpu.Draw_Indexed_Indirect_Command,
        color: [3]f32,
        pos: [3]f32,
        size: f32,
    }

    indirect_data := gpu.mem_alloc(Indirect_Data, Num_Triangles)
    defer gpu.mem_free(indirect_data)

    count := gpu.arena_alloc(&arena, u32)
    count.cpu^ = Num_Triangles

    count_local := gpu.mem_alloc(u32, mem_type = gpu.Memory.GPU)

    // Arrange triangles in a circle
    circle_radius: f32 = 0.6
    for i in 0..<Num_Triangles {
        angle := f32(i) / f32(Num_Triangles) * math.PI * 2.0

        // Position on circle
        x := math.cos(angle) * circle_radius
        y := math.sin(angle) * circle_radius

        // HSL color: hue varies around the circle (0-360 degrees), saturation and lightness fixed
        hue := angle / (math.PI * 2.0)  // 0.0 to 1.0
        saturation: f32 = 1.0
        lightness: f32 = 0.5

        // Convert HSL to RGB
        rgb := hsl_to_rgb(hue, saturation, lightness)

        // Fill unified indirect data struct with both command and user data
        indirect_data.cpu[i] = Indirect_Data {
            cmd = gpu.Draw_Indexed_Indirect_Command {
                index_count = 3,
                instance_count = 1,
                first_index = 0,
                vertex_offset = 0,
                first_instance = 0,
            },
            color = { rgb.x, rgb.y, rgb.z },
            pos = { x, y, 0.0 },
            size = 0.1,
        }
    }

    indirect_data_local := gpu.mem_alloc(Indirect_Data, Num_Triangles, gpu.Memory.GPU)

    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
        gpu.mem_free(count_local)
        gpu.mem_free(indirect_data_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_mem_copy(upload_cmd_buf, count_local, count)
    gpu.cmd_mem_copy(upload_cmd_buf, indirect_data_local, indirect_data)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    frame_arena := &arena

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0, 0, 0, 1 } }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    Vert_Data :: struct {
        verts: rawptr,
    }
    shared_vert_data := gpu.arena_alloc(frame_arena, Vert_Data)
    shared_vert_data.cpu.verts = verts_local.gpu.ptr

    Use_Indirect_Multi :: true
    when Use_Indirect_Multi {
        gpu.cmd_draw_indexed_indirect_multi(cmd_buf, shared_vert_data, {}, indices_local, indirect_data_local, count_local)
    } else {
        gpu.cmd_draw_indexed_indirect(cmd_buf, shared_vert_data, {}, indices_local, gpu.slice_to_ptr(indirect_data_local))
    }

    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_compute :: proc(target: Render_Target)
{
    group_size_x := u32(8)
    group_size_y := u32(8)
    compute_shader := gpu.shader_create_compute(#load("shaders/shadertoy.comp.spv", []u32), group_size_x, group_size_y, 1)
    vert_shader := gpu.shader_create(#load("shaders/fullscreen_quad.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/fullscreen_quad.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(compute_shader)
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    // Indirect dispatch command (group counts)
    indirect_dispatch_command := gpu.mem_alloc(gpu.Dispatch_Indirect_Command)
    defer gpu.mem_free(indirect_dispatch_command)

    Compute_Data :: struct {
        output_texture_id: u32,
        time: f32,
    }

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    // Create fullscreen quad
    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -1.0,  1.0, 0.0 }  // Top-left
    verts.cpu[1].pos = {  1.0, -1.0, 0.0 }  // Bottom-right
    verts.cpu[2].pos = {  1.0,  1.0, 0.0 }  // Top-right
    verts.cpu[3].pos = { -1.0, -1.0, 0.0 }  // Bottom-left
    verts.cpu[0].uv  = {  0.0,  0.0 }
    verts.cpu[1].uv  = {  1.0,  1.0 }
    verts.cpu[2].uv  = {  1.0,  0.0 }
    verts.cpu[3].uv  = {  0.0,  1.0 }

    indices := gpu.arena_alloc(&arena, u32, 6)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1
    indices.cpu[3] = 0
    indices.cpu[4] = 1
    indices.cpu[5] = 3

    verts_local := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        dimensions = { u32(Target_Size), u32(Target_Size), 1 },
        format = .RGBA8_Unorm,
        usage = { .Storage, .Sampled },
    }
    output_texture := gpu.texture_alloc_and_create(output_desc)
    defer gpu.texture_free_and_destroy(&output_texture)

    // Create texture descriptor for sampled access (fragment shader)
    texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(output_texture, {}))
    // Create texture descriptor for RW access (compute shader)
    texture_rw_id := gpu.desc_pool_alloc_texture_rw(&desc_pool, gpu.texture_rw_view_descriptor(output_texture, {}))
    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    frame_arena := &arena

    // Allocate compute data for this frame with current time and resolution
    compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
    compute_data.cpu.output_texture_id = texture_rw_id
    compute_data.cpu.time = 0.0

    cmd_buf := gpu.commands_begin(.Main)

    gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

    // Dispatch compute shader to write to texture
    gpu.cmd_set_compute_shader(cmd_buf, compute_shader)

    num_groups_x := (u32(Target_Size) + group_size_x - 1) / group_size_x
    num_groups_y := (u32(Target_Size) + group_size_y - 1) / group_size_y
    num_groups_z := u32(1)

    Use_Indirect :: true
    if Use_Indirect {
        indirect_dispatch_command.cpu^ = gpu.Dispatch_Indirect_Command {
            num_groups_x,
            num_groups_y,
            num_groups_z,
        }

        gpu.cmd_dispatch_indirect(cmd_buf, compute_data, indirect_dispatch_command)
    } else {
        gpu.cmd_dispatch(cmd_buf, compute_data, num_groups_x, num_groups_y, num_groups_z)
    }

    // Barrier to ensure compute shader finishes before rendering
    gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})

    // Render the texture to the swapchain using a fullscreen quad
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
    verts_data.cpu.verts = verts_local.gpu.ptr

    Frag_Data :: struct {
        texture_id: u32,
        sampler_id: u32,
    }
    frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
    frag_data.cpu.texture_id = texture_id
    frag_data.cpu.sampler_id = sampler_id

    gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

// NOTE: This is not only to test comparison samplers but by default this will
// also lead to pointers that are not 16B aligned, which leads to problems on NVidia (due to a driver bug?).
// So this test checks that arena allocations are all explicitly aligned to 16B.
test_comparison_sampler :: proc(target: Render_Target)
{
    shared.CAM_POS = { -7.581631, 1.1906259, 0.25928685 }
	shared.CAM_ANGLE = { 1.570796, 0.3665192 }

    Mesh_GPU :: struct
    {
        pos: gpu.slice_t([4]f32),
        normals: gpu.slice_t([4]f32),
        uvs: gpu.slice_t([2]f32),
        indices: gpu.slice_t(u32),
    }

    mesh_destroy :: proc(mesh: ^Mesh_GPU)
    {
        gpu.mem_free(mesh.pos)
        gpu.mem_free(mesh.normals)
        gpu.mem_free(mesh.uvs)
        gpu.mem_free(mesh.indices)
        mesh^ = {}
    }

    upload_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, mesh: shared.Mesh) -> Mesh_GPU
    {
        assert(len(mesh.pos) == len(mesh.normals))
        assert(len(mesh.pos) == len(mesh.uvs))

        positions_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.pos))
        normals_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.normals))
        uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.uvs))
        indices_staging := gpu.arena_alloc(upload_arena, u32, len(mesh.indices))
        copy(positions_staging.cpu, mesh.pos[:])
        copy(normals_staging.cpu, mesh.normals[:])
        copy(uvs_staging.cpu, mesh.uvs[:])
        copy(indices_staging.cpu, mesh.indices[:])

        res: Mesh_GPU
        res.pos = gpu.mem_alloc([4]f32, len(mesh.pos), gpu.Memory.GPU)
        res.normals = gpu.mem_alloc([4]f32, len(mesh.normals), gpu.Memory.GPU)
        res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), gpu.Memory.GPU)
        res.indices = gpu.mem_alloc(u32, len(mesh.indices), gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.pos, positions_staging)
        gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging)
        gpu.cmd_mem_copy(cmd_buf, res.uvs, uvs_staging)
        gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging)
        return res
    }

    Sponza_Scene :: #load("assets/sponza.glb")

    // Shadow texture
    shadow_depth_desc := gpu.Texture_Desc {
        dimensions = { 1024*4, 1024*4, 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment, .Sampled },
    }
    shadow_depth_texture := gpu.texture_alloc_and_create(shadow_depth_desc)
    defer gpu.texture_free_and_destroy(&shadow_depth_texture)

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    shadow_tex_id  := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(shadow_depth_texture, {}))
    shadow_sampler := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({compare_op = .Less}))

    vert_shader := gpu.shader_create(#load("shaders/shadowmap.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shadowmap.frag.spv", []u32), .Fragment)
    shadow_frag_shader := gpu.shader_create(#load("shaders/shadowmap.shadow_frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(shadow_frag_shader)
    }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    old_logger := context.logger
    context.logger = {}
    scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&scene)
        gltf2.unload(gltf_data)
    }
    context.logger = old_logger

    meshes_gpu: [dynamic]Mesh_GPU
    defer {
        for &mesh_gpu in meshes_gpu do mesh_destroy(&mesh_gpu)
        delete(meshes_gpu)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    for mesh in scene.meshes {
        append(&meshes_gpu, upload_mesh(&arena, upload_cmd_buf, mesh))
    }
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    // Wrap CAM_ANGLE.x
    LIGHT_POS: [3]f32 = {0,0,0};
    LIGHT_ANGLE: [2]f32 = {math.RAD_PER_DEG * 45, math.RAD_PER_DEG * -80};
    LIGHT_ANGLE.y = clamp(LIGHT_ANGLE.y, math.to_radians_f32(-90), math.to_radians_f32(90))
    y_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.y, [3]f32{-1, 0, 0})
    x_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.x, [3]f32{0, 1, 0})
    light_rot: = x_rot * y_rot
    world_to_light := shared.world_to_view_mat(LIGHT_POS, light_rot);

    world_to_view := shared.first_person_camera_view(0.0)
    aspect_ratio := f32(Target_Size) / f32(Target_Size)
    view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)
    light_to_proj := linalg.matrix_ortho3d_f32(-25,25, 18,-18, -40, 9, false)

    cmd_buf := gpu.commands_begin(.Main)

    frame_arena := &arena

    // ShadowPass
    {
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {},
            depth_attachment = gpu.Render_Attachment {
                texture = shadow_depth_texture, clear_color = 1.0
            },
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, shadow_frag_shader)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
        gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })

        for instance in scene.instances
        {
            mesh := meshes_gpu[instance.mesh_idx]

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                normals: rawptr,
                model_to_world: [16]f32,
                model_to_world_normal: [16]f32,
                world_to_view: [16]f32,
                world_to_light: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = mesh.pos.gpu.ptr,
                normals = mesh.normals.gpu.ptr,
                model_to_world = intr.matrix_flatten(instance.transform),
                model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                world_to_view = intr.matrix_flatten(world_to_light),
                world_to_light = intr.matrix_flatten(light_to_proj * world_to_light),
                view_to_proj = intr.matrix_flatten(light_to_proj),
            }

            gpu.cmd_draw_indexed(cmd_buf, verts_data, {}, mesh.indices)
        }

        gpu.cmd_end_render_pass(cmd_buf)
    }

    // Render Pass
    {
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = target.color, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
            },
            depth_attachment = gpu.Render_Attachment {
                texture = target.depth, clear_color = 1.0
            },
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
        gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })

        for instance in scene.instances
        {
            mesh := meshes_gpu[instance.mesh_idx]

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                normals: rawptr,
                model_to_world: [16]f32,
                model_to_world_normal: [16]f32,
                world_to_view: [16]f32,
                world_to_light: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = mesh.pos.gpu.ptr,
                normals = mesh.normals.gpu.ptr,
                model_to_world = intr.matrix_flatten(instance.transform),
                model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                world_to_view = intr.matrix_flatten(world_to_view),
                world_to_light = intr.matrix_flatten(light_to_proj * world_to_light),
                view_to_proj = intr.matrix_flatten(view_to_proj),
            }

            Frag_Data :: struct {
                shadow_map: u32,
                shadow_sampler: u32,
                light_dir: [3]f32,
            }
            base_light_dir : [4]f32 = {0,0,1, 1}
            frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
            frag_data.cpu^ = {
                shadow_map = shadow_tex_id,
                shadow_sampler = shadow_sampler,
                light_dir = (linalg.transpose(linalg.inverse(world_to_light)) * base_light_dir).xyz,
            }

            gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, mesh.indices)
        }

        gpu.cmd_end_render_pass(cmd_buf)
    }

    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_sw_pathtracing :: proc(target: Render_Target)
{
    Sponza_Scene :: #load("assets/sponza.glb")
    shared.CAM_POS = { 0, 0.5, -2.0 }
    shared.CAM_ANGLE = { 0, 0 }

    group_size_x := u32(8)
    group_size_y := u32(8)
    vert_shader := gpu.shader_create(#load("shaders/sample_texture.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/sample_texture.frag.spv", []u32), .Fragment)
    pathtrace_shader := gpu.shader_create_compute(#load("shaders/sw_pathtrace.comp.spv", []u32), group_size_x, group_size_y, 1)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(pathtrace_shader)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)
    bvh_scratch_arena := gpu.arena_create(mem_type = .GPU)
    defer gpu.arena_destroy(&bvh_scratch_arena)

    old_logger := context.logger
    context.logger = {}
    gltf_scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&gltf_scene)
        gltf2.unload(gltf_data)
    }
    context.logger = old_logger

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        type = .D2,
        dimensions = { u32(Target_Size), u32(Target_Size), 1 },
        format = .RGBA16_Float,
        usage = { .Storage, .Sampled },
    }
    output_texture := gpu.texture_alloc_and_create(output_desc)
    defer gpu.texture_free_and_destroy(&output_texture)

    Compute_Data :: struct {
        output_texture_id: u32,
        accum_counter: u32,
        camera_to_world: [16]f32,
    }

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    // Create fullscreen quad
    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -1.0,  1.0, 0.0 }  // Top-left
    verts.cpu[1].pos = {  1.0, -1.0, 0.0 }  // Bottom-right
    verts.cpu[2].pos = {  1.0,  1.0, 0.0 }  // Top-right
    verts.cpu[3].pos = { -1.0, -1.0, 0.0 }  // Bottom-left
    verts.cpu[0].uv  = {  0.0,  0.0 }
    verts.cpu[1].uv  = {  1.0,  1.0 }
    verts.cpu[2].uv  = {  1.0,  0.0 }
    verts.cpu[3].uv  = {  0.0,  1.0 }

    indices := gpu.arena_alloc(&arena, u32, 6)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1
    indices.cpu[3] = 0
    indices.cpu[4] = 1
    indices.cpu[5] = 3

    verts_local := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(output_texture, {}))
    texture_rw_id := gpu.desc_pool_alloc_texture_rw(&desc_pool, gpu.texture_rw_view_descriptor(output_texture, {}))
    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    frame_arena := &arena

    camera_to_world := linalg.inverse(shared.first_person_camera_view(0.0))

    cmd_buf := gpu.commands_begin(.Main)

    for accum_counter in 0..<10
    {
        // Allocate compute data for this frame with current time and resolution
        compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
        compute_data.cpu.output_texture_id = texture_rw_id
        compute_data.cpu.accum_counter = u32(accum_counter)
        compute_data.cpu.camera_to_world = intr.matrix_flatten(camera_to_world)

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        // Dispatch compute shader to write to texture
        gpu.cmd_set_compute_shader(cmd_buf, pathtrace_shader)

        num_groups_x := (u32(Target_Size) + group_size_x - 1) / group_size_x
        num_groups_y := (u32(Target_Size) + group_size_y - 1) / group_size_y
        num_groups_z := u32(1)

        // Reads and writes into texture_rw_id (allowed if each thread only reads a texel and then writes to that same texel)
        gpu.cmd_dispatch(cmd_buf, compute_data, num_groups_x, num_groups_y, num_groups_z)

        // Barrier to ensure compute shader finishes before rendering
        gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})
        // Next frame's pathtrace invocation will read this frame's output texture
        gpu.cmd_barrier(cmd_buf, .Compute, .Compute, {})
    }

    // Render the texture to the swapchain using a fullscreen quad
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
    verts_data.cpu.verts = verts_local.gpu.ptr

    Frag_Data :: struct {
        texture_id: u32,
        sampler_id: u32,
    }
    frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
    frag_data.cpu.texture_id = texture_id
    frag_data.cpu.sampler_id = sampler_id

    gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_hw_pathtracing :: proc(target: Render_Target)
{
    Sponza_Scene :: #load("assets/sponza.glb")

    Mesh_GPU :: struct
    {
        pos: gpu.slice_t([4]f32),
        normals: gpu.slice_t([4]f32),
        indices: gpu.slice_t(u32),
        idx_count: u32,
        vert_count: u32,
        bvh: gpu.Owned_BVH,
    }

    Mesh_Shader :: struct
    {
        pos: rawptr,
        normals: rawptr,
        indices: rawptr,
    }

    upload_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, mesh: shared.Mesh) -> Mesh_GPU
    {
        assert(len(mesh.pos) == len(mesh.normals))
        assert(len(mesh.pos) == len(mesh.uvs))

        positions_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.pos))
        normals_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.normals))
        uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.uvs))
        indices_staging := gpu.arena_alloc(upload_arena, u32, len(mesh.indices))
        copy(positions_staging.cpu, mesh.pos[:])
        copy(normals_staging.cpu, mesh.normals[:])
        copy(uvs_staging.cpu, mesh.uvs[:])
        copy(indices_staging.cpu, mesh.indices[:])

        res: Mesh_GPU
        res.pos = gpu.mem_alloc([4]f32, len(mesh.pos), mem_type = gpu.Memory.GPU)
        res.normals = gpu.mem_alloc([4]f32, len(mesh.normals), mem_type = gpu.Memory.GPU)
        //res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), mem_type = gpu.Memory.GPU)
        res.indices = gpu.mem_alloc(u32, len(mesh.indices), mem_type = gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.pos, positions_staging)
        gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging)
        //gpu.cmd_mem_copy(cmd_buf, res.uvs, uvs_staging)
        gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging)

        res.idx_count = u32(len(mesh.indices))
        res.vert_count = u32(len(mesh.pos))
        return res
    }

    mesh_destroy :: proc(mesh: ^Mesh_GPU)
    {
        gpu.bvh_free_and_destroy(&mesh.bvh)
        gpu.mem_free(mesh.pos)
        gpu.mem_free(mesh.normals)
        gpu.mem_free(mesh.indices)
        mesh^ = {}
    }

    build_blas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, positions: gpu.slice_t([4]f32), indices: gpu.slice_t(u32), idx_count: u32, vert_count: u32) -> gpu.Owned_BVH
    {
        assert(idx_count % 3 == 0)

        desc := gpu.BLAS_Desc {
            hint = .Prefer_Fast_Trace,
            shapes = {
                gpu.BVH_Mesh_Desc {
                    vertex_stride = 16,
                    max_vertex = vert_count - 1,
                    tri_count = idx_count / 3,
                }
            }
        }
        bvh := gpu.bvh_alloc_and_create(desc)
        scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
        gpu.cmd_build_blas(cmd_buf, bvh, scratch, { gpu.BVH_Mesh { verts = positions.gpu.ptr, indices = indices.gpu.ptr } })
        return bvh
    }

    build_tlas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: gpu.gpuptr, instance_count: u32) -> gpu.Owned_BVH
    {
        desc := gpu.TLAS_Desc {
            hint = .Prefer_Fast_Trace,
            instance_count = instance_count
        }
        bvh := gpu.bvh_alloc_and_create(desc)
        scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
        gpu.cmd_build_tlas(cmd_buf, bvh, scratch, instances)
        return bvh
    }

    upload_bvh_instances :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: []shared.Instance, meshes: []Mesh_GPU) -> gpu.slice_t(gpu.BVH_Instance)
    {
        instances_staging := gpu.arena_alloc(upload_arena, gpu.BVH_Instance, len(instances))
        for &instance, i in instances_staging.cpu
        {
            instance = {
                transform = shared.transform_to_gpu_transform(instances[i].transform),
                blas_root = gpu.bvh_root_ptr(meshes[instances[i].mesh_idx].bvh),
                disable_culling = true,
                flip_facing = true,
                mask = 1,
            }
        }
        instances_local := gpu.mem_alloc(gpu.BVH_Instance, len(instances), mem_type = gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, instances_local, instances_staging)
        return instances_local
    }

    Scene_GPU :: struct
    {
        bvh: gpu.Owned_BVH,
        meshes: [dynamic]Mesh_GPU,
        instances_bvh: gpu.slice_t(gpu.BVH_Instance),

        // Shader view
        instances: gpu.slice_t(Instance_Shader),
        meshes_shader: gpu.slice_t(Mesh_Shader),
    }

    Scene_Shader :: struct
    {
        instances: rawptr,
        meshes: rawptr,
    }

    Instance_Shader :: struct
    {
        mesh_idx: u32,
    }

    upload_scene :: proc(scene: shared.Scene, upload_arena: ^gpu.Arena, bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> Scene_GPU
    {
        res: Scene_GPU

        // Upload meshes
        for mesh in scene.meshes
        {
            to_add := upload_mesh(upload_arena, cmd_buf, mesh)
            append(&res.meshes, to_add)
        }

        // Construct structures used by the shader
        instances_gpu := gpu.arena_alloc(upload_arena, Instance_Shader, len(scene.instances))
        for &instance, i in instances_gpu.cpu {
            instance = { mesh_idx = scene.instances[i].mesh_idx }
        }
        res.instances = gpu.mem_alloc(Instance_Shader, len(scene.instances), gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.instances, instances_gpu)

        meshes_gpu := gpu.arena_alloc(upload_arena, Mesh_Shader, len(scene.meshes))
        for &mesh, i in meshes_gpu.cpu {
            mesh.pos = res.meshes[i].pos.gpu.ptr
            mesh.normals = res.meshes[i].normals.gpu.ptr
            mesh.indices = res.meshes[i].indices.gpu.ptr
        }
        res.meshes_shader = gpu.mem_alloc(Mesh_Shader, len(scene.meshes), gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.meshes_shader, meshes_gpu)

        // Build BVHs
        gpu.cmd_barrier(cmd_buf, .Transfer, .Build_BVH)
        for &mesh in res.meshes {
            mesh.bvh = build_blas(bvh_scratch_arena, cmd_buf, mesh.pos, mesh.indices, mesh.idx_count, mesh.vert_count)
        }

        res.instances_bvh = upload_bvh_instances(upload_arena, cmd_buf, scene.instances[:], res.meshes[:])
        gpu.cmd_barrier(cmd_buf, .Transfer, .Build_BVH)

        res.bvh = build_tlas(upload_arena, cmd_buf, res.instances_bvh, u32(len(scene.instances)))
        gpu.cmd_barrier(cmd_buf, .Build_BVH, .All)

        return res
    }

    scene_destroy :: proc(scene: ^Scene_GPU)
    {
        gpu.bvh_free_and_destroy(&scene.bvh)
        gpu.mem_free(scene.instances)
        gpu.mem_free(scene.meshes_shader)
        gpu.mem_free(scene.instances_bvh)
        for &mesh in scene.meshes {
            mesh_destroy(&mesh)
        }
        delete(scene.meshes)
        scene^ = {}
    }

    shared.CAM_POS = {-7.581631, 1.1906259, 0.25928685}
    shared.CAM_ANGLE = {1.570796, 0.3665192}

    ensure(.Raytracing in gpu.features_available())

    group_size_x := u32(8)
    group_size_y := u32(8)
    vert_shader := gpu.shader_create(#load("shaders/sample_texture.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/sample_texture.frag.spv", []u32), .Fragment)
    pathtrace_shader := gpu.shader_create_compute(#load("shaders/hw_pathtrace.comp.spv", []u32), group_size_x, group_size_y, 1)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(pathtrace_shader)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)
    bvh_scratch_arena := gpu.arena_create(mem_type = .GPU)
    defer gpu.arena_destroy(&bvh_scratch_arena)

    old_logger := context.logger
    context.logger = {}
    gltf_scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&gltf_scene)
        gltf2.unload(gltf_data)
    }
    context.logger = old_logger

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        type = .D2,
        dimensions = { u32(Target_Size), u32(Target_Size), 1 },
        format = .RGBA16_Float,
        usage = { .Storage, .Sampled },
    }
    output_texture := gpu.texture_alloc_and_create(output_desc)
    defer gpu.texture_free_and_destroy(&output_texture)

    Compute_Data :: struct {
        output_texture_id: u32,
        tlas_id: u32,
        scene: Scene_Shader,
        accum_counter: u32,
        camera_to_world: [16]f32,
    }

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    // Create fullscreen quad
    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -1.0,  1.0, 0.0 }  // Top-left
    verts.cpu[1].pos = {  1.0, -1.0, 0.0 }  // Bottom-right
    verts.cpu[2].pos = {  1.0,  1.0, 0.0 }  // Top-right
    verts.cpu[3].pos = { -1.0, -1.0, 0.0 }  // Bottom-left
    verts.cpu[0].uv  = {  0.0,  0.0 }
    verts.cpu[1].uv  = {  1.0,  1.0 }
    verts.cpu[2].uv  = {  1.0,  0.0 }
    verts.cpu[3].uv  = {  0.0,  1.0 }

    indices := gpu.arena_alloc(&arena, u32, 6)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1
    indices.cpu[3] = 0
    indices.cpu[4] = 1
    indices.cpu[5] = 3

    verts_local := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)

    scene := upload_scene(gltf_scene, &upload_arena, &bvh_scratch_arena, upload_cmd_buf)
    defer {
        scene_destroy(&scene)
    }

    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(output_texture, {}))
    texture_rw_id := gpu.desc_pool_alloc_texture_rw(&desc_pool, gpu.texture_rw_view_descriptor(output_texture, {}))
    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))
    bvh_id := gpu.desc_pool_alloc_bvh(&desc_pool, scene.bvh)

    frame_arena := &arena

    camera_to_world := linalg.inverse(shared.first_person_camera_view(0.0))

    cmd_buf := gpu.commands_begin(.Main)

    for accum_counter in 0..<10
    {
        // Allocate compute data for this frame with current time and resolution
        compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
        compute_data.cpu.output_texture_id = texture_rw_id
        compute_data.cpu.tlas_id = bvh_id
        compute_data.cpu.scene = { instances = scene.instances.gpu.ptr, meshes = scene.meshes_shader.gpu.ptr }
        compute_data.cpu.accum_counter = u32(accum_counter)
        compute_data.cpu.camera_to_world = intr.matrix_flatten(camera_to_world)

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        // Dispatch compute shader to write to texture
        gpu.cmd_set_compute_shader(cmd_buf, pathtrace_shader)

        num_groups_x := (u32(Target_Size) + group_size_x - 1) / group_size_x
        num_groups_y := (u32(Target_Size) + group_size_y - 1) / group_size_y
        num_groups_z := u32(1)

        // Reads and writes into texture_rw_id (allowed if each thread only reads a texel and then writes to that same texel)
        gpu.cmd_dispatch(cmd_buf, compute_data, num_groups_x, num_groups_y, num_groups_z)

        // Barrier to ensure compute shader finishes before rendering
        gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})
        // Next frame's pathtrace invocation will read this frame's output texture
        gpu.cmd_barrier(cmd_buf, .Compute, .Compute, {})
    }

    // Render the texture to the swapchain using a fullscreen quad
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
    verts_data.cpu.verts = verts_local.gpu.ptr

    Frag_Data :: struct {
        texture_id: u32,
        sampler_id: u32,
    }
    frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
    frag_data.cpu.texture_id = texture_id
    frag_data.cpu.sampler_id = sampler_id

    gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

Render_Target :: struct
{
    color: gpu.Owned_Texture,
    depth: gpu.Owned_Texture,
}

create_render_target :: proc() -> Render_Target
{
    res: Render_Target
    res.color = gpu.texture_alloc_and_create({
        dimensions = { Target_Size, Target_Size, 1 },
        format = .RGBA8_Unorm,
        usage = { .Color_Attachment, .Transfer_Src }
    })
    res.depth = gpu.texture_alloc_and_create({
        dimensions = { Target_Size, Target_Size, 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment },
    })
    return res
}

destroy_render_target :: proc(target: ^Render_Target)
{
    gpu.texture_free_and_destroy(&target.color)
    gpu.texture_free_and_destroy(&target.depth)
}

save_target_color :: proc(target: Render_Target, path: string)
{
    cmd_buf := gpu.commands_begin(.Main)

    readback := gpu.mem_alloc([4]u8, Target_Size * Target_Size, gpu.Memory.Readback)
    defer gpu.mem_free(readback)

    gpu.cmd_copy_from_texture(cmd_buf, readback, target.color, {})
    gpu.queue_submit(.Main, { cmd_buf })

    gpu.wait_idle()

    // Save to disk
    img, ok_i := image.pixels_to_image(readback.cpu, Target_Size, Target_Size)
    ensure(ok_i)
    err := bmp.save(path, &img)
    if err != nil do log.error("Failed to save golden:", err)
    ensure(err == nil)
}

compare_to_golden :: proc(target: Render_Target, path: string) -> bool
{
    golden_file_content, err := os.read_entire_file_from_path(path, allocator = context.allocator)
    if err != nil do return false
    defer delete(golden_file_content)

    options := image.Options {
        .alpha_add_if_missing,
    }
    golden, err_l := image.load_from_bytes(golden_file_content, options)
    ensure(err_l == nil, "Could not load texture.")
    defer image.destroy(golden)

    readback := gpu.mem_alloc(u8, Target_Size * Target_Size * 4, gpu.Memory.Readback)
    defer gpu.mem_free(readback)
    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_copy_from_texture(cmd_buf, readback, target.color, {})
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()

    // NOTE: For some reason the alpha is dropped for bmp files.
    is_same := true
    for i := 0; i < len(readback.cpu); i += 4
    {
        j := i / 4 * 3
        is_same &= readback.cpu[i+0] == golden.pixels.buf[j+0]
        is_same &= readback.cpu[i+1] == golden.pixels.buf[j+1]
        is_same &= readback.cpu[i+2] == golden.pixels.buf[j+2]
    }
    return is_same
}

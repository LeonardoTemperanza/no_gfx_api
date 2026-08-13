
#+feature dynamic-literals

package main

import "core:image"
import "core:image/bmp"
import "core:log"
import "core:os"
import "core:strings"

import "../gpu"

Target_Size :: 256

tests: map[string]proc(target: Render_Target) = {
    "test_triangle" = test_triangle,
    //"test_texture" = test_texture,
    //test_texture_advanced,
    //test_compute
}

main :: proc()
{
    cmd_args := os.args

    gen_goldens := false
    if len(cmd_args) > 1 && cmd_args[1] == "gen_goldens" {
        gen_goldens = true
    }

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    target := create_render_target()
    defer destroy_render_target(&target)

    for name, test in tests
    {
        test(target)
        gpu.wait_idle()

        output_path := strings.concatenate({"tests/goldens/", name, ".bmp"})

        if gen_goldens {
            save_target_color(target, output_path)
        } else {
            compare_to_golden(target, output_path)
        }
        gpu.wait_idle()
    }
}

test_triangle :: proc(target: Render_Target)
{
    vert_shader := gpu.shader_create(#load("../examples/1_triangle/shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("../examples/1_triangle/shaders/shader.frag.spv", []u32), .Fragment)
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

}

test_texture_advanced :: proc(target: Render_Target)
{

}

test_compute :: proc(target: Render_Target)
{

}

// TODO: Add this shadowmap test. This is not only to test comparison samplers but this will also
// have non-16B-aligned allocations by default, which NVidia doesn't like.
/*
package main

import log "core:log"
import "../../gpu"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import intr "base:intrinsics"

import sdl "vendor:sdl3"

import shared "../shared"
import gltf2 "../shared/gltf2"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Shadow"

Sponza_Scene :: #load("../shared/assets/sponza.glb")

main :: proc()
{
    shared.CAM_POS = {-7.581631, 1.1906259, 0.25928685}
	shared.CAM_ANGLE = {1.570796, 0.3665192}
    fmt.println("Right-click + WASD for first-person controls.")

    shared.sdl_init()

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0  // 10fps

    window_flags :: sdl.WindowFlags {
        .HIGH_PIXEL_DENSITY,
        .VULKAN,
        .RESIZABLE,
    }
    window := sdl.CreateWindow(Example_Name, Start_Window_Size_X, Start_Window_Size_Y, window_flags)
    ensure(window != nil)

    display_scale: f32 = sdl.GetWindowDisplayScale(window)

    window_size_x := i32(Start_Window_Size_X * display_scale)
    window_size_y := i32(Start_Window_Size_Y * display_scale)

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    depth_desc := gpu.Texture_Desc {
        dimensions = { u32(window_size_x), u32(window_size_y), 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment },
    }
    depth_texture := gpu.texture_alloc_and_create(depth_desc)
    defer gpu.texture_free_and_destroy(&depth_texture)

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

    vert_shader := gpu.shader_create(#load("shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shader.frag.spv", []u32), .Fragment)
    shadow_frag_shader := gpu.shader_create(#load("shaders/shader.shadow_frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(shadow_frag_shader)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&scene)
        gltf2.unload(gltf_data)
    }

    meshes_gpu: [dynamic]Mesh_GPU
    defer {
        for &mesh_gpu in meshes_gpu do mesh_destroy(&mesh_gpu)
        delete(meshes_gpu)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    for mesh in scene.meshes {
        append(&meshes_gpu, upload_mesh(&upload_arena, upload_cmd_buf, mesh))
    }
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    now_ts := sdl.GetPerformanceCounter()

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    // Wrap CAM_ANGLE.x
    LIGHT_POS :[3]f32 = {0,0,0};
    LIGHT_ANGLE :[2]f32 = {math.RAD_PER_DEG * 45, math.RAD_PER_DEG * -80};
    for true
    {
        proceed := shared.handle_window_events(window)
        if !proceed do break

        old_window_size_x := window_size_x
        old_window_size_y := window_size_y
        sdl.GetWindowSizeInPixels(window, &window_size_x, &window_size_y)
        if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0
        {
            sdl.Delay(16)
            continue
        }

        if next_frame > Frames_In_Flight {
            gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
        }
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y
        {
            gpu.queue_wait_idle(.Main)
            gpu.swapchain_resize({ u32(max(0, window_size_x)), u32(max(0, window_size_y)) })
            depth_desc.dimensions.x = u32(window_size_x)
            depth_desc.dimensions.y = u32(window_size_y)
            gpu.texture_free_and_destroy(&depth_texture)
            depth_texture = gpu.texture_alloc_and_create(depth_desc)
        }

        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)
        for LIGHT_ANGLE.x < 0 do LIGHT_ANGLE.x += 2 * math.PI
        for LIGHT_ANGLE.x > 2 * math.PI do LIGHT_ANGLE.x -= 2 * math.PI

        LIGHT_ANGLE.y = clamp(LIGHT_ANGLE.y, math.to_radians_f32(-90), math.to_radians_f32(90))
        y_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.y, [3]f32{-1, 0, 0})
        x_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.x, [3]f32{0, 1, 0})
        light_rot: = x_rot * y_rot
        world_to_light := shared.world_to_view_mat(LIGHT_POS, light_rot);

        world_to_view := shared.first_person_camera_view(delta_time)
        aspect_ratio := f32(window_size_x) / f32(window_size_y)
        view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)
        light_to_proj := linalg.matrix_ortho3d_f32(-25,25, 18,-18, -40, 9, false)

        cmd_buf := gpu.commands_begin(.Main)
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
                    { texture = swapchain, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
                },
                depth_attachment = gpu.Render_Attachment {
                    texture = depth_texture, clear_color = 1.0
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
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1
    }

    gpu.wait_idle()
}

Mesh_GPU :: struct
{
    pos: gpu.slice_t([4]f32),
    normals: gpu.slice_t([4]f32),
    uvs: gpu.slice_t([2]f32),
    indices: gpu.slice_t(u32),
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

mesh_destroy :: proc(mesh: ^Mesh_GPU)
{
    gpu.mem_free(mesh.pos)
    gpu.mem_free(mesh.normals)
    gpu.mem_free(mesh.uvs)
    gpu.mem_free(mesh.indices)
    mesh^ = {}
}
*/

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
    return res
}

destroy_render_target :: proc(target: ^Render_Target)
{
    gpu.texture_free_and_destroy(&target.color)
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

compare_to_golden :: proc(target: Render_Target, path: string)
{

}

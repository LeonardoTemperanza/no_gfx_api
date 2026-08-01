
package main

import log "core:log"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "../shared"

import "../../gpu"

import sdl "vendor:sdl3"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Compute Shader"

// Whether to use indirect dispatch (group counts) or direct dispatch (thread counts)
Use_Indirect :: true

main :: proc()
{
    fmt.println("CREDITS: Shader \"Clearly a bug\" by Glow on https://www.shadertoy.com/view/33cGDj")

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

    group_size_x := u32(8)
    group_size_y := u32(8)
    compute_shader := gpu.shader_create_compute(#load("shaders/shadertoy.comp.spv", []u32), group_size_x, group_size_y, 1)
    vert_shader := gpu.shader_create(#load("shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shader.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(compute_shader)
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        dimensions = { u32(window_size_x), u32(window_size_y), 1 },
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

    now_ts := sdl.GetPerformanceCounter()
    total_time: f32 = 0.0

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    for true
    {
        proceed := handle_window_events(window)
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

            output_desc.dimensions.x = u32(window_size_x)
            output_desc.dimensions.y = u32(window_size_y)
            gpu.texture_free_and_destroy(&output_texture)
            output_texture = gpu.texture_alloc_and_create(output_desc)

            // Update descriptor for new texture
            gpu.desc_heap_set_textures(&desc_pool, texture_id, { gpu.texture_view_descriptor(output_texture, {}) })
            gpu.desc_heap_set_textures_rw(&desc_pool, texture_rw_id, { gpu.texture_rw_view_descriptor(output_texture, {}) })
        }

        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)
        total_time += delta_time

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        // Allocate compute data for this frame with current time and resolution
        compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
        compute_data.cpu.output_texture_id = texture_rw_id
        compute_data.cpu.time = total_time

        cmd_buf := gpu.commands_begin(.Main)

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        // Dispatch compute shader to write to texture
        gpu.cmd_set_compute_shader(cmd_buf, compute_shader)

        num_groups_x := (u32(window_size_x) + group_size_x - 1) / group_size_x
        num_groups_y := (u32(window_size_y) + group_size_y - 1) / group_size_y
        num_groups_z := u32(1)

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
                { texture = swapchain, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
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
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1
    }

    gpu.wait_idle()
}

handle_window_events :: proc(window: ^sdl.Window) -> (proceed: bool)
{
    event: sdl.Event
    proceed = true
    for sdl.PollEvent(&event)
    {
        #partial switch event.type
        {
            case .QUIT:
                proceed = false
            case .WINDOW_CLOSE_REQUESTED:
            {
                if event.window.windowID == sdl.GetWindowID(window) {
                    proceed = false
                }
            }
        }
    }

    return
}

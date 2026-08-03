
package main

import log "core:log"
import vk "vendor:vulkan"

import "../../../gpu"

import sdl "vendor:sdl3"
import imgui "odin-imgui"
import imgui_impl_sdl3 "odin-imgui/imgui_impl_sdl3"
import imgui_impl_nogfx "odin-imgui/imgui_impl_nogfx"

// NOTE: This example uses the no_gfx backend for Dear Imgui.
// This makes some things simpler, like using custom textures in Dear ImGui windows.
// Alternatively, for a more maintained and up to date renderer the
// Vulkan backend can be used alongside the no_gfx escape hatch procedures
// (e.g. get_vulkan_instance(), get_vulkan_device(), etc.), but that
// will make advanced features a lot more awkward to use.

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "ImGUI"

main :: proc()
{
    ok_i := sdl.Init({ .VIDEO })
    assert(ok_i)

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0

    window_flags :: sdl.WindowFlags {
        .HIGH_PIXEL_DENSITY,
        .VULKAN,
        .RESIZABLE,
    }
    window := sdl.CreateWindow(Example_Name, Start_Window_Size_X, Start_Window_Size_Y, window_flags)
    ensure(window != nil)

    window_size_x := i32(Start_Window_Size_X)
    window_size_y := i32(Start_Window_Size_Y)

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    vert_shader := gpu.shader_create(#load("shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shader.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    Vertex :: struct { pos: [4]f32, color: [4]f32 }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    verts := gpu.arena_alloc(&upload_arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0, 0.0 }
    verts.cpu[0].color = { 1.0, 0.0, 0.0, 0.0 }
    verts.cpu[1].color = { 0.0, 1.0, 0.0, 0.0 }
    verts.cpu[2].color = { 0.0, 0.0, 1.0, 0.0 }

    indices := gpu.arena_alloc(&upload_arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1

    verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    imgui_ctx := init_imgui(window, &desc_pool)
    defer {
        imgui_impl_nogfx.shutdown()
        imgui_impl_sdl3.shutdown()
        imgui.destroy_context(imgui_ctx)
    }

    now_ts := sdl.GetPerformanceCounter()

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
        sdl.GetWindowSize(window, &window_size_x, &window_size_y)
        if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0
        {
            sdl.Delay(16)
            continue
        }

        if next_frame > Frames_In_Flight {
            gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
        }
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y {
            gpu.swapchain_resize({ u32(max(0, window_size_x)), u32(max(0, window_size_y)) })
        }

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]

        imgui_impl_sdl3.new_frame()
        imgui.new_frame()

        imgui.show_demo_window()

        @(static) background_color := [4]f32 { 0.45, 0.55, 0.60, 1.0 }
        if imgui.begin("Background Color", nil, {
            .Always_Auto_Resize,
        })
        {
            imgui.color_picker4("Background", &background_color, {})
            imgui.end()
        }

        imgui.render()

        swapchain := gpu.swapchain_acquire_next()

        cmd_buf := gpu.commands_begin(.Main)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = swapchain, clear_color = background_color }
            }
        })

        // Render triangle
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        Vert_Data :: struct {
            verts: rawptr,
        }
        verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
        verts_data.cpu.verts = verts_local.gpu.ptr
        gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, {}, indices_local)

        // Render ImGui on top
        draw_data := imgui.get_draw_data()
        if draw_data != nil && draw_data.cmd_lists_count > 0 {
            imgui_impl_nogfx.render_draw_data(draw_data, cmd_buf)
        }

        gpu.cmd_end_render_pass(cmd_buf)
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1

        gpu.arena_free_all(frame_arena)
    }

    gpu.wait_idle()
}

handle_window_events :: proc(window: ^sdl.Window) -> (proceed: bool)
{
    event: sdl.Event
    proceed = true
    for sdl.PollEvent(&event)
    {
        imgui_impl_sdl3.process_event(&event)

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

init_imgui :: proc(window: ^sdl.Window, desc_pool: ^gpu.Descriptor_Pool) -> ^imgui.Context
{
    imgui.CHECKVERSION()
    ctx := imgui.create_context(nil)
    io := imgui.get_io()
    io.config_flags += {.Nav_Enable_Keyboard, .Nav_Enable_Gamepad}
    io.display_size = {Start_Window_Size_X, Start_Window_Size_Y}

    imgui_impl_sdl3.init_for_vulkan(window)

    result := imgui_impl_nogfx.init({
        frames_in_flight = Frames_In_Flight
    }, desc_pool)
    assert(result, "Failed to initialize imgui vulkan backend")

    imgui_impl_nogfx.create_fonts_texture(desc_pool)
    return ctx
}
